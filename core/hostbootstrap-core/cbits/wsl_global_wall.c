/*
 * Native support for the Windows/WSL global resource wall.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 *
 * WSL 2 reads several VM-wide settings from one per-user file:
 *     %USERPROFILE%\.wslconfig
 *
 * That file is shared mutable state.  Two hostbootstrap processes must not
 * independently read it, derive different replacements, and then overwrite
 * each other.  A process crash must also leave enough durable evidence to
 * distinguish the user's original file from a hostbootstrap-owned staged or
 * installed file.  Path strings alone are not sufficient evidence: between
 * two path-based operations another process can rename, replace, or redirect
 * the name.
 *
 * The Haskell layer owns the policy and state machine.  It parses and merges
 * configuration bytes, serializes the recovery record, checks receipt/fence
 * transitions, and decides which primitive should run next.  The narrow C
 * layer below supplies only the Windows mechanisms needed to make those
 * decisions true at the filesystem and Registry boundaries:
 *
 *   * a per-user, cross-process Win32 mutex;
 *   * exclusive opens that reject directories and reparse points;
 *   * FILE_ID_INFO observations tied to an already-open handle;
 *   * write-through, delete-on-close staging files;
 *   * an NTFS hard-link handoff that preserves the staged file's FILE_ID;
 *   * handle-bound source rename and deletion with no replacement;
 *   * and explicitly flushed HKCU recovery/fence values.
 *
 * This is not a claim that the Haskell language is inherently unable to call
 * Windows.  Rather, hostbootstrap-core's selected Haskell dependencies do not
 * expose the exact low-level combination of Win32 handles, FILE_ID_INFO,
 * no-replace rename, delete-on-close staging, hard-link creation, and Registry
 * flush calls required by this protocol.  Reimplementing partial bindings in
 * Haskell would still require an FFI boundary and would make ownership rules
 * harder to audit.  Keeping the boundary here makes it small, explicit, and
 * testable.
 *
 * CRASH-SAFETY SHAPE
 * ------------------
 *
 * The caller serializes a complete operation with the named mutex.  Original
 * bytes and file identity are observed through an exclusive handle.  New
 * bytes are written and flushed to a CREATE_NEW file whose handle has
 * FILE_FLAG_DELETE_ON_CLOSE.  Thus a crash before handoff removes the armed
 * staging name.  On NTFS, CreateHardLinkW gives the same file a bound recovery
 * name without replacing anything; closing the delete-on-close handle then
 * removes only the armed name while the bound link and FILE_ID survive a
 * modeled process termination.
 * Subsequent install/restore steps rename or delete the object through its
 * already-validated handle.  The Registry record and monotonically increasing
 * fence are flushed at protocol boundaries so recovery can conservatively
 * classify the on-disk layout.
 *
 * Those guarantees are scoped to the state machine's process-crash/retry
 * model.  FlushFileBuffers and RegFlushKey establish the strongest boundaries
 * used here, but CreateHardLinkW has no accompanying Windows API for flushing
 * parent-directory metadata.  This shim therefore does not claim that a bound
 * hard-link name survives arbitrary sudden power loss at every possible
 * instant.
 *
 * "No replace" is deliberate throughout.  Encountering an unexpected
 * destination is evidence of interference or an incomplete prior operation;
 * silently overwriting it would destroy user data and erase the evidence
 * needed for recovery.
 *
 * API CONVENTIONS
 * ---------------
 *
 * Exported functions return ERROR_SUCCESS (zero) on success and otherwise a
 * Win32 LONG/DWORD-style error encoded as uint32_t.  Unless a function says
 * otherwise, input buffers are borrowed only for the duration of the call.
 * Memory returned through a uint8_t ** or WCHAR ** is allocated by this
 * translation unit's C runtime and must be released with hb_wsl_free.  HANDLE
 * values returned as void * remain owned by the caller until the matching
 * close/release function is called.
 *
 * The helpers have no mutable process-global state.  Cooperative serialization
 * comes from hb_wsl_mutex_acquire, not from implicit locking in each primitive.
 * Win32 mutex ownership is associated with the acquiring operating-system
 * thread.  The caller must therefore keep mutex acquire and release on that
 * same OS thread (for example, by using a bound Haskell thread); ordinary file
 * and Registry handles do not carry that mutex-owner thread affinity.
 *
 * Successfully changing this file only changes the persisted .wslconfig
 * bytes.  It does not prove that WSL has been shut down, restarted, or has
 * observed the requested limits; that runtime evidence belongs above this
 * FFI layer.
 */

#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0602
#endif

#include <windows.h>
#include <objbase.h>
#include <sddl.h>
#include <shlobj.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/*
 * FILE_ID_INFO is serialized as the eight-byte volume serial number followed
 * by the sixteen-byte FILE_ID_128.  Keeping the size fixed makes identities
 * opaque, byte-comparable values in Haskell without copying a compiler-specific
 * C struct layout across the FFI.
 */
#define HB_WSL_FILE_ID_BYTES 24u

/*
 * A .wslconfig or recovery record larger than 16 MiB is not credible input for
 * this subsystem.  Bounding reads prevents a corrupted or adversarial file
 * from turning an exclusive lock into unbounded allocation.
 */
#define HB_WSL_MAX_FILE_BYTES (16u * 1024u * 1024u)

/*
 * A stuck peer must not block the bootstrapper forever.  Timeout is surfaced
 * as ERROR_BUSY so the Haskell layer can report contention distinctly from a
 * malformed journal or filesystem failure.
 */
#define HB_WSL_MUTEX_WAIT_MILLISECONDS 30000u

/*
 * Recovery state is per Windows user, just like .wslconfig itself.  The key is
 * fixed rather than caller-supplied so this shim cannot be repurposed as a
 * generic Registry writer.
 */
static const WCHAR HB_WSL_REGISTRY_KEY[] =
    L"Software\\HostBootstrap\\WslGlobalWall\\v1";
static const WCHAR HB_WSL_ACTIVE_VALUE[] = L"ActiveRecord";
static const WCHAR HB_WSL_FENCE_VALUE[] = L"LastFence";

/*
 * This local GUID definition avoids depending on an SDK-provided address for
 * FOLDERID_Profile while still asking the Known Folder API for the authoritative
 * current-user profile location.
 */
static const GUID HB_WSL_FOLDERID_PROFILE = {
    0x5E6C858F,
    0x0E22,
    0x4760,
    {0x9A, 0xFE, 0xEA, 0x33, 0x17, 0xB6, 0x71, 0x73}};

/*
 * Read the stable filesystem identity of an already-open object.
 *
 * Inputs:
 *   handle       - a valid file HANDLE kept open by the caller.
 *   identity_out - writable storage for exactly HB_WSL_FILE_ID_BYTES bytes.
 *
 * On success, identity_out contains VolumeSerialNumber followed by FileId.
 * Both components are required: a file ID is meaningful only within its
 * volume.  The helper allocates nothing and neither closes nor otherwise
 * changes handle.  It intentionally queries the handle, rather than reopening
 * a pathname, so the identity describes the object the caller actually locked.
 *
 * Failure is the exact GetLastError value from
 * GetFileInformationByHandleEx.  No mutex-specific thread affinity applies.
 */
static uint32_t hb_wsl_copy_file_id(HANDLE handle, uint8_t *identity_out) {
  FILE_ID_INFO info;

  if (!GetFileInformationByHandleEx(
          handle, FileIdInfo, &info, (DWORD)sizeof(info))) {
    return (uint32_t)GetLastError();
  }

  memcpy(identity_out, &info.VolumeSerialNumber, sizeof(info.VolumeSerialNumber));
  memcpy(identity_out + sizeof(info.VolumeSerialNumber),
         &info.FileId,
         sizeof(info.FileId));
  return ERROR_SUCCESS;
}

/*
 * Verify that an opened object is a regular, non-reparse-point file.
 *
 * The wall must never follow a junction, symbolic link, mount point, or other
 * reparse object supplied at .wslconfig or one of its private staging names.
 * The caller opens with FILE_FLAG_OPEN_REPARSE_POINT and passes that same
 * handle here, making this check apply to the directory entry itself rather
 * than to its target.
 *
 * The function borrows handle, allocates nothing, and returns
 * ERROR_NOT_SUPPORTED for directories or reparse points.  Query failures are
 * returned as their Win32 error code.  The handle remains open in all cases.
 */
static uint32_t hb_wsl_validate_regular_file(HANDLE handle) {
  FILE_ATTRIBUTE_TAG_INFO info;

  if (!GetFileInformationByHandleEx(
          handle, FileAttributeTagInfo, &info, (DWORD)sizeof(info))) {
    return (uint32_t)GetLastError();
  }
  if ((info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
      (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return ERROR_NOT_SUPPORTED;
  }
  return ERROR_SUCCESS;
}

/*
 * Ask Windows to delete a staging object when its last handle is closed.
 *
 * This helper is used only while unwinding an earlier staging failure.
 * FILE_FLAG_DELETE_ON_CLOSE already arms handles created by
 * hb_wsl_create_stage; setting FileDispositionInfo again is a defensive
 * cleanup request.  There is no useful error to return without hiding the
 * original failure, so SetFileInformationByHandle's result is deliberately
 * ignored.  The helper does not close the borrowed handle.
 */
static void hb_wsl_mark_delete_best_effort(HANDLE handle) {
  FILE_DISPOSITION_INFO disposition;
  disposition.DeleteFile = TRUE;
  (void)SetFileInformationByHandle(
      handle, FileDispositionInfo, &disposition, (DWORD)sizeof(disposition));
}

/*
 * Resolve the one .wslconfig path this subsystem is allowed to manage.
 *
 * path_out must be non-NULL.  It is cleared before any fallible operation.
 * On success, *path_out is a NUL-terminated, malloc-allocated WCHAR string
 * containing the current user's Known Folder profile plus "\\.wslconfig".
 * The path uses the "\\?\" form (or "\\?\UNC\" for a UNC profile) so later
 * Win32 calls do not reinterpret it through legacy MAX_PATH parsing.  The
 * caller owns the returned allocation and must pass it to hb_wsl_free.
 *
 * Resolving FOLDERID_Profile here is a security and correctness boundary:
 * Haskell does not supply an arbitrary mutation target, and environment
 * variables such as USERPROFILE cannot redirect the operation.  This function
 * only constructs the path; it neither opens nor validates the eventual file.
 *
 * Known Folder resolution is a COM API.  The shim initializes COM on the
 * calling OS thread for the duration of this function and balances every
 * successful CoInitializeEx (including S_FALSE) with CoUninitialize.
 * RPC_E_CHANGED_MODE is not fatal: it means the embedding process already
 * initialized that thread in a different apartment, and SHGetKnownFolderPath
 * is valid from that existing apartment.  A failed CoInitializeEx must not be
 * balanced with CoUninitialize.
 *
 * SHGetKnownFolderPath and CoInitializeEx failures are returned in their
 * 32-bit HRESULT form.  Allocation and overflow failures use the corresponding
 * Win32 error value.  A non-NULL PWSTR from the shell is released with
 * CoTaskMemFree on every success and failure path, including a defensive
 * cleanup if the shell reports failure after assigning it.
 */
uint32_t hb_wsl_get_target_path(WCHAR **path_out) {
  PWSTR profile = NULL;
  WCHAR *result = NULL;
  const WCHAR suffix[] = L"\\.wslconfig";
  const WCHAR drive_prefix[] = L"\\\\?\\";
  const WCHAR unc_prefix[] = L"\\\\?\\UNC\\";
  const WCHAR *prefix = drive_prefix;
  const WCHAR *profile_tail;
  size_t prefix_length;
  size_t profile_length;
  size_t suffix_length;
  size_t total_length;
  uint32_t status = ERROR_SUCCESS;
  HRESULT initialize_hr;
  HRESULT hr;
  BOOL uninitialize = FALSE;

  if (path_out == NULL) {
    return ERROR_INVALID_PARAMETER;
  }
  *path_out = NULL;

  /*
   * MTA is sufficient for this non-UI Known Folder query and avoids imposing a
   * message-pump requirement.  The Haskell adapter keeps the enclosing mutex
   * bracket on a bound thread, so initialization and uninitialization also
   * necessarily occur on the same OS thread.  RPC_E_CHANGED_MODE indicates an
   * already initialized (typically STA) caller thread; retain that apartment
   * and continue without claiming an initialization reference.
   */
  initialize_hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  if (SUCCEEDED(initialize_hr)) {
    uninitialize = TRUE;
  } else if (initialize_hr != RPC_E_CHANGED_MODE) {
    return (uint32_t)initialize_hr;
  }

  hr = SHGetKnownFolderPath(&HB_WSL_FOLDERID_PROFILE, KF_FLAG_DEFAULT, NULL, &profile);
  if (FAILED(hr)) {
    status = (uint32_t)hr;
    goto cleanup;
  }
  if (profile == NULL) {
    status = ERROR_INVALID_DATA;
    goto cleanup;
  }

  profile_tail = profile;
  if (profile[0] == L'\\' && profile[1] == L'\\') {
    prefix = unc_prefix;
    profile_tail = profile + 2;
  }
  prefix_length = wcslen(prefix);
  profile_length = wcslen(profile_tail);
  suffix_length = wcslen(suffix);
  if (prefix_length > SIZE_MAX - profile_length ||
      prefix_length + profile_length > SIZE_MAX - suffix_length - 1u) {
    status = ERROR_ARITHMETIC_OVERFLOW;
    goto cleanup;
  }
  total_length = prefix_length + profile_length + suffix_length + 1u;
  if (total_length > SIZE_MAX / sizeof(WCHAR)) {
    status = ERROR_ARITHMETIC_OVERFLOW;
    goto cleanup;
  }
  result = (WCHAR *)malloc(total_length * sizeof(WCHAR));
  if (result == NULL) {
    status = ERROR_NOT_ENOUGH_MEMORY;
    goto cleanup;
  }

  memcpy(result, prefix, prefix_length * sizeof(WCHAR));
  memcpy(result + prefix_length,
         profile_tail,
         profile_length * sizeof(WCHAR));
  memcpy(result + prefix_length + profile_length,
         suffix,
         (suffix_length + 1u) * sizeof(WCHAR));
  *path_out = result;
  result = NULL;

cleanup:
  /*
   * CoTaskMemFree(NULL) and free(NULL) are both permitted.  Keeping cleanup
   * centralized makes later edits much less likely to leak a shell allocation
   * on an added overflow or validation branch.
   */
  CoTaskMemFree(profile);
  free(result);
  if (uninitialize) {
    CoUninitialize();
  }
  return status;
}

/*
 * Release memory allocated by this C translation unit.
 *
 * Haskell must use this function for strings and byte buffers returned by the
 * shim so allocation and deallocation occur in the same C runtime.  Passing
 * NULL is permitted by free(3).  This function does not close HANDLE or HKEY
 * values and imposes no thread affinity.
 */
void hb_wsl_free(void *allocation) {
  free(allocation);
}

/*
 * Acquire the cross-process lock for the current user's WSL global wall.
 *
 * mutex_out and abandoned_out must both be non-NULL.  Outputs are initialized
 * to NULL and zero before work begins.  The function derives the current
 * process token's textual SID and creates/opens:
 *
 *   Global\HostBootstrap.WslGlobalWall.v1.<SID>
 *
 * The Global namespace coordinates processes across Windows sessions, while
 * the SID suffix prevents unrelated users from sharing one wall.  The default
 * security descriptor is supplied by Windows for the creating process; no
 * caller-controlled name or security descriptor crosses the FFI.
 *
 * Success transfers one owned mutex HANDLE through *mutex_out.  The caller
 * must eventually pass it to hb_wsl_mutex_release.  WAIT_ABANDONED is also a
 * successful acquisition because Windows has transferred ownership, but
 * *abandoned_out is set to one so the caller can request conservative
 * recovery.  A 30-second wait expiry is returned as ERROR_BUSY.  All temporary
 * token, SID, and name allocations are released before return.
 *
 * IMPORTANT: Win32 mutex ownership is thread-affine.  ReleaseMutex must run on
 * the same operating-system thread that successfully waited here.  A Haskell
 * caller must keep the bracket on a bound OS thread; retaining only the HANDLE
 * is not sufficient to transfer mutex ownership to another thread.
 */
uint32_t hb_wsl_mutex_acquire(void **mutex_out, int *abandoned_out) {
  HANDLE token = NULL;
  TOKEN_USER *token_user = NULL;
  LPWSTR sid_text = NULL;
  WCHAR *mutex_name = NULL;
  HANDLE mutex = NULL;
  DWORD token_length = 0;
  DWORD wait_result;
  DWORD error = ERROR_SUCCESS;
  const WCHAR prefix[] = L"Global\\HostBootstrap.WslGlobalWall.v1.";
  size_t prefix_length;
  size_t sid_length;

  if (mutex_out == NULL || abandoned_out == NULL) {
    return ERROR_INVALID_PARAMETER;
  }
  *mutex_out = NULL;
  *abandoned_out = 0;

  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return (uint32_t)GetLastError();
  }
  (void)GetTokenInformation(token, TokenUser, NULL, 0, &token_length);
  error = GetLastError();
  if (error != ERROR_INSUFFICIENT_BUFFER) {
    CloseHandle(token);
    return (uint32_t)error;
  }
  /*
   * ERROR_INSUFFICIENT_BUFFER is the expected result of the sizing query, not
   * the operation's eventual return status.  Clear it before proceeding so a
   * successful acquisition cannot transfer a live owned mutex HANDLE while
   * also reporting error 122 to Haskell.
   */
  error = ERROR_SUCCESS;
  token_user = (TOKEN_USER *)malloc(token_length);
  if (token_user == NULL) {
    CloseHandle(token);
    return ERROR_NOT_ENOUGH_MEMORY;
  }
  if (!GetTokenInformation(
          token, TokenUser, token_user, token_length, &token_length)) {
    error = GetLastError();
    free(token_user);
    CloseHandle(token);
    return (uint32_t)error;
  }
  if (!ConvertSidToStringSidW(token_user->User.Sid, &sid_text)) {
    error = GetLastError();
    free(token_user);
    CloseHandle(token);
    return (uint32_t)error;
  }

  prefix_length = wcslen(prefix);
  sid_length = wcslen(sid_text);
  if (prefix_length > SIZE_MAX - sid_length - 1u) {
    error = ERROR_ARITHMETIC_OVERFLOW;
    goto cleanup;
  }
  mutex_name =
      (WCHAR *)malloc((prefix_length + sid_length + 1u) * sizeof(WCHAR));
  if (mutex_name == NULL) {
    error = ERROR_NOT_ENOUGH_MEMORY;
    goto cleanup;
  }
  memcpy(mutex_name, prefix, prefix_length * sizeof(WCHAR));
  memcpy(mutex_name + prefix_length,
         sid_text,
         (sid_length + 1u) * sizeof(WCHAR));

  mutex = CreateMutexW(NULL, FALSE, mutex_name);
  if (mutex == NULL) {
    error = GetLastError();
    goto cleanup;
  }
  wait_result =
      WaitForSingleObject(mutex, HB_WSL_MUTEX_WAIT_MILLISECONDS);
  if (wait_result == WAIT_ABANDONED) {
    *abandoned_out = 1;
  } else if (wait_result == WAIT_TIMEOUT) {
    error = ERROR_BUSY;
    CloseHandle(mutex);
    mutex = NULL;
    goto cleanup;
  } else if (wait_result != WAIT_OBJECT_0) {
    error = wait_result == WAIT_FAILED ? GetLastError() : ERROR_GEN_FAILURE;
    CloseHandle(mutex);
    mutex = NULL;
    goto cleanup;
  }

  *mutex_out = mutex;
  mutex = NULL;

cleanup:
  if (mutex != NULL) {
    CloseHandle(mutex);
  }
  free(mutex_name);
  LocalFree(sid_text);
  free(token_user);
  CloseHandle(token);
  return (uint32_t)error;
}

/*
 * Release and close a mutex returned by hb_wsl_mutex_acquire.
 *
 * mutex_value must be a live acquired mutex HANDLE.  ReleaseMutex is attempted
 * first, then CloseHandle is attempted even if release failed so the native
 * handle is not leaked.  A release error takes precedence over a later close
 * error; otherwise a close error is returned.  Callers must treat the handle as
 * consumed after this call regardless of the result.
 *
 * This call must execute on the same Windows thread that acquired the mutex.
 * Calling it from another Haskell capability/worker can produce
 * ERROR_NOT_OWNER even though the numeric HANDLE value is valid.
 */
uint32_t hb_wsl_mutex_release(void *mutex_value) {
  HANDLE mutex = (HANDLE)mutex_value;
  DWORD error = ERROR_SUCCESS;

  if (mutex == NULL) {
    return ERROR_INVALID_HANDLE;
  }
  if (!ReleaseMutex(mutex)) {
    error = GetLastError();
  }
  if (!CloseHandle(mutex) && error == ERROR_SUCCESS) {
    error = GetLastError();
  }
  return (uint32_t)error;
}

/*
 * Open and snapshot an existing wall file without following reparse points.
 *
 * Inputs and outputs:
 *   path         - borrowed NUL-terminated extended-length Windows path.
 *   handle_out   - receives an owned HANDLE when the file is present.
 *   identity_out - caller-provided HB_WSL_FILE_ID_BYTES buffer, written only
 *                  for a present file.
 *   bytes_out    - receives a malloc-allocated exact byte snapshot, or NULL.
 *   length_out   - receives the byte count.
 *   present_out  - receives one for an opened file and zero for absence.
 *
 * ERROR_FILE_NOT_FOUND and ERROR_PATH_NOT_FOUND are represented as successful
 * absence.  Every other open error remains significant.  For a present path,
 * CreateFileW requests read and delete access with share mode zero and
 * FILE_FLAG_OPEN_REPARSE_POINT.  A successful open therefore establishes the
 * strongest cooperative exclusion available to this protocol, and validation
 * rejects a directory or reparse object before any bytes are trusted.
 *
 * Identity, size, and contents are all read through that single HANDLE.  This
 * is crucial: reopening path between those observations would permit a
 * pathname substitution race.  Files larger than HB_WSL_MAX_FILE_BYTES are
 * refused.  On success the HANDLE stays open so the Haskell state machine can
 * perform a later handle-bound rename/delete against the exact object it
 * observed.  The caller must close it with hb_wsl_close_handle and free a
 * non-NULL byte buffer with hb_wsl_free.
 *
 * On failure all allocations and the opened handle are cleaned up locally;
 * handle_out, bytes_out, length_out, and present_out retain their initialized
 * empty values.  identity_out is unspecified after failure because identity
 * collection may have succeeded before a later size/read operation failed.
 * File handles are not thread-affine, although the encompassing wall
 * transaction is expected to remain under the global mutex.
 */
uint32_t hb_wsl_open_exclusive(const WCHAR *path,
                               void **handle_out,
                               uint8_t *identity_out,
                               uint8_t **bytes_out,
                               size_t *length_out,
                               int *present_out) {
  HANDLE handle;
  FILE_STANDARD_INFO standard_info;
  uint8_t *bytes = NULL;
  size_t length;
  size_t offset = 0;
  DWORD error;

  if (path == NULL || handle_out == NULL || identity_out == NULL ||
      bytes_out == NULL || length_out == NULL || present_out == NULL) {
    return ERROR_INVALID_PARAMETER;
  }
  *handle_out = NULL;
  *bytes_out = NULL;
  *length_out = 0;
  *present_out = 0;

  handle = CreateFileW(path,
                       GENERIC_READ | DELETE,
                       0,
                       NULL,
                       OPEN_EXISTING,
                       FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                       NULL);
  if (handle == INVALID_HANDLE_VALUE) {
    error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
      return ERROR_SUCCESS;
    }
    return (uint32_t)error;
  }

  error = hb_wsl_validate_regular_file(handle);
  if (error != ERROR_SUCCESS) {
    CloseHandle(handle);
    return error;
  }
  error = hb_wsl_copy_file_id(handle, identity_out);
  if (error != ERROR_SUCCESS) {
    CloseHandle(handle);
    return error;
  }
  if (!GetFileInformationByHandleEx(handle,
                                    FileStandardInfo,
                                    &standard_info,
                                    (DWORD)sizeof(standard_info))) {
    error = GetLastError();
    CloseHandle(handle);
    return (uint32_t)error;
  }
  if (standard_info.EndOfFile.QuadPart < 0 ||
      (uint64_t)standard_info.EndOfFile.QuadPart > HB_WSL_MAX_FILE_BYTES) {
    CloseHandle(handle);
    return ERROR_FILE_TOO_LARGE;
  }
  length = (size_t)standard_info.EndOfFile.QuadPart;
  if (length != 0) {
    bytes = (uint8_t *)malloc(length);
    if (bytes == NULL) {
      CloseHandle(handle);
      return ERROR_NOT_ENOUGH_MEMORY;
    }
  }
  while (offset < length) {
    DWORD chunk = (DWORD)(length - offset);
    DWORD read_count = 0;
    if (!ReadFile(handle, bytes + offset, chunk, &read_count, NULL)) {
      error = GetLastError();
      free(bytes);
      CloseHandle(handle);
      return (uint32_t)error;
    }
    if (read_count == 0) {
      free(bytes);
      CloseHandle(handle);
      return ERROR_HANDLE_EOF;
    }
    offset += read_count;
  }

  *handle_out = handle;
  *bytes_out = bytes;
  *length_out = length;
  *present_out = 1;
  return ERROR_SUCCESS;
}

/*
 * Conservatively probe a path's identity without acquiring file authority.
 *
 * path is a borrowed NUL-terminated extended-length path.  identity_out points
 * to HB_WSL_FILE_ID_BYTES of caller-owned storage, and present_out must point
 * to an int.  present_out is cleared before the open.  Missing paths are
 * successful absence; a present regular, non-reparse file writes its
 * volume-qualified FILE_ID and sets present_out to one.
 *
 * This deliberately requests zero data/delete access and shares read, write,
 * and delete.  That unusual combination lets recovery inspect a second hard
 * link while hostbootstrap already holds another link to the same object with
 * share mode zero: the new handle requests no access that the first handle
 * must share, while its own permissive share mask accepts the first handle's
 * access.  It also often permits conservative classification while an
 * unrelated process has the destination open.
 *
 * The result is observation only.  This handle is closed before return, cannot
 * authorize rename/delete, and must never replace the exclusive handle used
 * by mutation paths.  Haskell uses it only after a sharing or no-replace race:
 * an identity matching an already-open object proves a hard-link alias;
 * anything else causes a Busy/conflict refusal.  Since refusal is
 * non-mutating, a path replacement after this probe cannot grant stale
 * authority.
 *
 * FILE_FLAG_OPEN_REPARSE_POINT prevents following links, and
 * FILE_FLAG_BACKUP_SEMANTICS allows directories to be opened only so
 * hb_wsl_validate_regular_file can reject them uniformly.  Every opened handle
 * is closed locally.  identity_out is unspecified unless present_out is one.
 */
uint32_t hb_wsl_probe_identity(const WCHAR *path,
                               uint8_t *identity_out,
                               int *present_out) {
  HANDLE handle;
  DWORD error;

  if (path == NULL || identity_out == NULL || present_out == NULL) {
    return ERROR_INVALID_PARAMETER;
  }
  *present_out = 0;

  handle = CreateFileW(path,
                       0,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       NULL,
                       OPEN_EXISTING,
                       FILE_FLAG_OPEN_REPARSE_POINT |
                           FILE_FLAG_BACKUP_SEMANTICS,
                       NULL);
  if (handle == INVALID_HANDLE_VALUE) {
    error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
      return ERROR_SUCCESS;
    }
    return (uint32_t)error;
  }

  error = hb_wsl_validate_regular_file(handle);
  if (error == ERROR_SUCCESS) {
    error = hb_wsl_copy_file_id(handle, identity_out);
  }
  if (!CloseHandle(handle) && error == ERROR_SUCCESS) {
    error = GetLastError();
  }
  if (error != ERROR_SUCCESS) {
    return (uint32_t)error;
  }

  *present_out = 1;
  return ERROR_SUCCESS;
}

/*
 * Create, populate, flush, and identify an armed staging file.
 *
 * path is a borrowed NUL-terminated private staging path.  bytes is borrowed
 * and may be NULL only when length is zero.  handle_out receives an owned
 * HANDLE; identity_out points to HB_WSL_FILE_ID_BYTES of caller-owned storage.
 * The function refuses inputs over HB_WSL_MAX_FILE_BYTES.
 *
 * CREATE_NEW is the first no-replace guard: an existing path is evidence to
 * classify, never something this primitive may overwrite.  Share mode zero
 * keeps the staged object exclusively held.  FILE_FLAG_WRITE_THROUGH plus
 * FlushFileBuffers establishes the file-data durability boundary before its
 * identity is recorded.  FILE_FLAG_DELETE_ON_CLOSE "arms" the temporary name,
 * so process termination or ordinary error cleanup removes an uncommitted
 * stage rather than leaving ambiguous bytes behind.
 *
 * On success the caller owns the still-open, delete-on-close HANDLE.  It must
 * either hand the object off with hb_wsl_link_armed_stage and close the armed
 * handle, or simply close the handle to abandon it.  On every failure after a
 * HANDLE has been created, this function requests deletion, closes the handle,
 * and returns the originating Win32 error.  Once input validation has
 * completed, handle_out is initialized to NULL and remains NULL on failure.
 */
uint32_t hb_wsl_create_stage(const WCHAR *path,
                             const uint8_t *bytes,
                             size_t length,
                             void **handle_out,
                             uint8_t *identity_out) {
  HANDLE handle;
  size_t offset = 0;
  DWORD error;

  if (path == NULL || handle_out == NULL || identity_out == NULL ||
      (bytes == NULL && length != 0)) {
    return ERROR_INVALID_PARAMETER;
  }
  if (length > HB_WSL_MAX_FILE_BYTES) {
    return ERROR_FILE_TOO_LARGE;
  }
  *handle_out = NULL;

  handle = CreateFileW(path,
                       GENERIC_READ | GENERIC_WRITE | DELETE,
                       0,
                       NULL,
                       CREATE_NEW,
                       FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH |
                           FILE_FLAG_DELETE_ON_CLOSE,
                       NULL);
  if (handle == INVALID_HANDLE_VALUE) {
    return (uint32_t)GetLastError();
  }
  while (offset < length) {
    DWORD chunk = (DWORD)(length - offset);
    DWORD write_count = 0;
    if (!WriteFile(handle, bytes + offset, chunk, &write_count, NULL)) {
      error = GetLastError();
      hb_wsl_mark_delete_best_effort(handle);
      CloseHandle(handle);
      return (uint32_t)error;
    }
    if (write_count == 0) {
      hb_wsl_mark_delete_best_effort(handle);
      CloseHandle(handle);
      return ERROR_WRITE_FAULT;
    }
    offset += write_count;
  }
  if (!FlushFileBuffers(handle)) {
    error = GetLastError();
    hb_wsl_mark_delete_best_effort(handle);
    CloseHandle(handle);
    return (uint32_t)error;
  }
  error = hb_wsl_copy_file_id(handle, identity_out);
  if (error != ERROR_SUCCESS) {
    hb_wsl_mark_delete_best_effort(handle);
    CloseHandle(handle);
    return error;
  }

  *handle_out = handle;
  return ERROR_SUCCESS;
}

/*
 * Give an armed delete-on-close stage a recovery-visible second name.
 *
 * handle_value is the live HANDLE returned by hb_wsl_create_stage.
 * armed_path is the path used to create that handle, and bound_path is the
 * new private recovery name.  All three inputs are borrowed; ownership of the
 * HANDLE remains with the caller.
 *
 * Windows does not provide a portable operation for cancelling the original
 * FILE_FLAG_DELETE_ON_CLOSE contract.  On NTFS, a hard link supplies the needed
 * handoff: CreateHardLinkW creates bound_path as another name for the same
 * file.  Closing the armed handle then removes armed_path, while bound_path
 * continues to name the flushed bytes under the exact same FILE_ID for the
 * modeled process-crash/retry protocol.  This does not add a sudden-power-loss
 * guarantee: CreateHardLinkW exposes no parent-directory metadata flush.
 *
 * The identity query first verifies that handle_value is still a queryable
 * file handle, and the filesystem check deliberately fails closed outside
 * NTFS because this protocol has been validated only against NTFS hard-link
 * and delete-on-close semantics.  CreateHardLinkW is no-replace: if bound_path
 * exists, the call fails instead of destroying or adopting it.  The source
 * argument to CreateHardLinkW is necessarily path-based, so the caller must
 * keep the global mutex, exclusive stage handle, and exact armed_path together;
 * later recovery compares the persisted FILE_ID rather than trusting names.
 *
 * Success creates the link but does not close handle_value.  Failure creates
 * no usable handoff and leaves cleanup to the caller's handle bracket.  No
 * thread affinity applies to this file HANDLE.
 */
uint32_t hb_wsl_link_armed_stage(void *handle_value,
                                 const WCHAR *armed_path,
                                 const WCHAR *bound_path) {
  HANDLE handle = (HANDLE)handle_value;
  uint8_t ignored_identity[HB_WSL_FILE_ID_BYTES];
  WCHAR file_system_name[32];

  if (handle == NULL || armed_path == NULL || bound_path == NULL) {
    return ERROR_INVALID_PARAMETER;
  }
  /*
   * Query through the live handle before performing the path-based hard-link
   * call.  Recovery uses the identity returned by stage creation; this local
   * query is a liveness/type guard and deliberately does not mint a new
   * identity value.
   */
  {
    uint32_t status = hb_wsl_copy_file_id(handle, ignored_identity);
    if (status != ERROR_SUCCESS) {
      return status;
    }
  }
  if (!GetVolumeInformationByHandleW(handle,
                                     NULL,
                                     0,
                                     NULL,
                                     NULL,
                                     NULL,
                                     file_system_name,
                                     (DWORD)(sizeof(file_system_name) /
                                             sizeof(file_system_name[0])))) {
    return (uint32_t)GetLastError();
  }
  if (_wcsicmp(file_system_name, L"NTFS") != 0) {
    return ERROR_NOT_SUPPORTED;
  }
  if (!CreateHardLinkW(bound_path, armed_path, NULL)) {
    return (uint32_t)GetLastError();
  }
  return ERROR_SUCCESS;
}

/*
 * Rename an already-open object without replacing the destination.
 *
 * handle_value is a borrowed file HANDLE opened with DELETE access.
 * destination is a borrowed NUL-terminated Windows path.  The function builds
 * the variable-length FILE_RENAME_INFO buffer with checked arithmetic and
 * calls SetFileInformationByHandle(FileRenameInfo).
 *
 * Binding the source operation to a HANDLE is central to the wall protocol:
 * even if a pathname has changed since discovery, Windows applies the rename
 * to the exact object whose FILE_ID the caller validated.  ReplaceIfExists is
 * FALSE, so an unexpected destination becomes a recoverable conflict rather
 * than a silent clobber.  RootDirectory is NULL because destination carries
 * the complete name selected by the fixed-path Haskell adapter.
 *
 * The temporary FILE_RENAME_INFO allocation is always freed.  On success the
 * same HANDLE remains open and now refers to the renamed object; on failure it
 * also remains open and ownership stays with the caller.  This file operation
 * has no OS-thread affinity.
 */
uint32_t hb_wsl_rename_handle_noreplace(void *handle_value,
                                        const WCHAR *destination) {
  HANDLE handle = (HANDLE)handle_value;
  FILE_RENAME_INFO *rename_info;
  size_t destination_length;
  size_t destination_bytes;
  size_t info_size;
  DWORD error;

  if (handle == NULL || destination == NULL) {
    return ERROR_INVALID_PARAMETER;
  }
  destination_length = wcslen(destination);
  if (destination_length > (size_t)(UINT32_MAX / sizeof(WCHAR))) {
    return ERROR_FILENAME_EXCED_RANGE;
  }
  destination_bytes = destination_length * sizeof(WCHAR);
  if (offsetof(FILE_RENAME_INFO, FileName) >
      SIZE_MAX - destination_bytes) {
    return ERROR_ARITHMETIC_OVERFLOW;
  }
  info_size = offsetof(FILE_RENAME_INFO, FileName) + destination_bytes;
  if (info_size > UINT32_MAX) {
    return ERROR_ARITHMETIC_OVERFLOW;
  }
  rename_info = (FILE_RENAME_INFO *)calloc(1, info_size);
  if (rename_info == NULL) {
    return ERROR_NOT_ENOUGH_MEMORY;
  }
  rename_info->ReplaceIfExists = FALSE;
  rename_info->RootDirectory = NULL;
  rename_info->FileNameLength = (DWORD)destination_bytes;
  memcpy(rename_info->FileName, destination, destination_bytes);

  if (!SetFileInformationByHandle(
          handle, FileRenameInfo, rename_info, (DWORD)info_size)) {
    error = GetLastError();
    free(rename_info);
    return (uint32_t)error;
  }
  free(rename_info);
  return ERROR_SUCCESS;
}

/*
 * Mark an already-open object for deletion.
 *
 * handle_value is a borrowed HANDLE opened with DELETE access.  Using
 * FileDispositionInfo binds deletion to that exact object instead of
 * resolving a possibly substituted path.  Windows may defer final namespace
 * removal until all compatible handles are closed; success means the delete
 * disposition was accepted, not that every name is already unobservable.
 *
 * The function never closes the HANDLE, even on failure.  The caller retains
 * ownership and must close it separately.  There is no thread affinity for
 * ordinary file handles.
 */
uint32_t hb_wsl_delete_handle(void *handle_value) {
  HANDLE handle = (HANDLE)handle_value;
  FILE_DISPOSITION_INFO disposition;

  if (handle == NULL) {
    return ERROR_INVALID_HANDLE;
  }
  disposition.DeleteFile = TRUE;
  if (!SetFileInformationByHandle(
          handle, FileDispositionInfo, &disposition, (DWORD)sizeof(disposition))) {
    return (uint32_t)GetLastError();
  }
  return ERROR_SUCCESS;
}

/*
 * Close a file/staging HANDLE returned by this shim.
 *
 * This is the ownership terminator used by Haskell brackets around
 * hb_wsl_open_exclusive and hb_wsl_create_stage.  Closing an armed staging
 * handle is itself a protocol step: FILE_FLAG_DELETE_ON_CLOSE removes the
 * armed link, while a successfully created hard-linked bound name survives.
 *
 * The caller must not reuse handle_value after this call, including after a
 * reported CloseHandle failure.  This wrapper is intended for file handles;
 * acquired mutexes require hb_wsl_mutex_release so ReleaseMutex runs first.
 * Ordinary file close has no owner-thread requirement.
 */
uint32_t hb_wsl_close_handle(void *handle_value) {
  HANDLE handle = (HANDLE)handle_value;
  if (handle == NULL) {
    return ERROR_INVALID_HANDLE;
  }
  if (!CloseHandle(handle)) {
    return (uint32_t)GetLastError();
  }
  return ERROR_SUCCESS;
}

/*
 * Open (or create) the fixed per-user recovery key.
 *
 * key_out must point to writable HKEY storage.  Success transfers an open key
 * handle with query/set rights to the caller, which must call RegCloseKey.
 * The key is non-volatile so receipts and fences survive process and machine
 * restarts.  No arbitrary hive or subkey is accepted from Haskell.
 *
 * This helper does not flush and does not provide transaction isolation.
 * Callers perform RegFlushKey at the exact durability boundary, and the
 * Haskell adapter holds the per-user global mutex across compound
 * read/compare/write operations.  Registry key handles themselves are not
 * owner-thread-affine.  In the Registry helpers below, "durable" means that
 * RegFlushKey completed for the protocol's modeled process-crash/retry
 * boundary; it is not an unconditional promise about arbitrary hardware or
 * sudden-power-loss failures below Windows.
 */
static LONG hb_wsl_open_registry(HKEY *key_out) {
  DWORD disposition;
  return RegCreateKeyExW(HKEY_CURRENT_USER,
                         HB_WSL_REGISTRY_KEY,
                         0,
                         NULL,
                         REG_OPTION_NON_VOLATILE,
                         KEY_QUERY_VALUE | KEY_SET_VALUE,
                         NULL,
                         key_out,
                         &disposition);
}

/*
 * Load the durable active recovery record, if one exists.
 *
 * bytes_out, length_out, and present_out must be non-NULL and are cleared
 * before the Registry is touched.  A missing ActiveRecord is successful
 * absence.  A present value must be a non-empty REG_BINARY no larger than
 * HB_WSL_MAX_FILE_BYTES; malformed type/size is returned as
 * ERROR_INVALID_DATA rather than being treated as no active operation.
 *
 * The value is queried for size, allocated with malloc, and queried again for
 * bytes.  On success, ownership of *bytes_out transfers to the caller, which
 * must use hb_wsl_free.  All failure paths free the buffer and close the key.
 * This function does not reinterpret or validate the serialized state-machine
 * payload; that remains Haskell's responsibility.
 *
 * The caller is expected to hold the global mutex across load and any
 * following transition.  Without that cooperative lock, the Registry's two
 * queries are not a transactional snapshot.  There is no additional
 * thread-affinity requirement for the HKEY.
 */
uint32_t hb_wsl_registry_load_active(uint8_t **bytes_out,
                                     size_t *length_out,
                                     int *present_out) {
  HKEY key = NULL;
  DWORD value_type = 0;
  DWORD value_length = 0;
  uint8_t *bytes = NULL;
  LONG status;

  if (bytes_out == NULL || length_out == NULL || present_out == NULL) {
    return ERROR_INVALID_PARAMETER;
  }
  *bytes_out = NULL;
  *length_out = 0;
  *present_out = 0;

  status = hb_wsl_open_registry(&key);
  if (status != ERROR_SUCCESS) {
    return (uint32_t)status;
  }
  status = RegQueryValueExW(key,
                            HB_WSL_ACTIVE_VALUE,
                            NULL,
                            &value_type,
                            NULL,
                            &value_length);
  if (status == ERROR_FILE_NOT_FOUND) {
    RegCloseKey(key);
    return ERROR_SUCCESS;
  }
  if (status != ERROR_SUCCESS) {
    RegCloseKey(key);
    return (uint32_t)status;
  }
  if (value_type != REG_BINARY || value_length == 0 ||
      value_length > HB_WSL_MAX_FILE_BYTES) {
    RegCloseKey(key);
    return ERROR_INVALID_DATA;
  }
  bytes = (uint8_t *)malloc(value_length);
  if (bytes == NULL) {
    RegCloseKey(key);
    return ERROR_NOT_ENOUGH_MEMORY;
  }
  status = RegQueryValueExW(key,
                            HB_WSL_ACTIVE_VALUE,
                            NULL,
                            &value_type,
                            bytes,
                            &value_length);
  RegCloseKey(key);
  if (status != ERROR_SUCCESS) {
    free(bytes);
    return (uint32_t)status;
  }

  *bytes_out = bytes;
  *length_out = value_length;
  *present_out = 1;
  return ERROR_SUCCESS;
}

/*
 * Allocate and durably publish the next per-user fencing number.
 *
 * fence_out must be non-NULL and is initialized to zero.  LastFence is either
 * absent (treated as zero) or an exact REG_QWORD.  The function refuses
 * UINT64_MAX rather than wrapping, writes previous + 1, and calls RegFlushKey
 * before returning the new value to Haskell.
 *
 * Fences prevent an older receipt from being mistaken for a newer operation
 * after crash recovery.  The read/increment/write sequence is intentionally
 * small but is not a Registry transaction: callers must hold the named global
 * mutex for uniqueness among cooperating hostbootstrap processes.  If setting
 * or flushing fails, no fence is returned; the durable state may conservatively
 * be ahead on retry, which is safe because fence values need not be contiguous.
 */
uint32_t hb_wsl_registry_allocate_fence(uint64_t *fence_out) {
  HKEY key = NULL;
  DWORD value_type = 0;
  DWORD value_length = (DWORD)sizeof(uint64_t);
  uint64_t previous = 0;
  uint64_t next;
  LONG status;

  if (fence_out == NULL) {
    return ERROR_INVALID_PARAMETER;
  }
  *fence_out = 0;
  status = hb_wsl_open_registry(&key);
  if (status != ERROR_SUCCESS) {
    return (uint32_t)status;
  }
  status = RegQueryValueExW(key,
                            HB_WSL_FENCE_VALUE,
                            NULL,
                            &value_type,
                            (LPBYTE)&previous,
                            &value_length);
  if (status == ERROR_FILE_NOT_FOUND) {
    previous = 0;
  } else if (status != ERROR_SUCCESS) {
    RegCloseKey(key);
    return (uint32_t)status;
  } else if (value_type != REG_QWORD ||
             value_length != (DWORD)sizeof(uint64_t)) {
    RegCloseKey(key);
    return ERROR_INVALID_DATA;
  }
  if (previous == UINT64_MAX) {
    RegCloseKey(key);
    return ERROR_ARITHMETIC_OVERFLOW;
  }
  next = previous + 1u;
  status = RegSetValueExW(key,
                          HB_WSL_FENCE_VALUE,
                          0,
                          REG_QWORD,
                          (const BYTE *)&next,
                          (DWORD)sizeof(next));
  if (status == ERROR_SUCCESS) {
    status = RegFlushKey(key);
  }
  RegCloseKey(key);
  if (status != ERROR_SUCCESS) {
    return (uint32_t)status;
  }
  *fence_out = next;
  return ERROR_SUCCESS;
}

/*
 * Replace and durably flush the active recovery record.
 *
 * bytes is a borrowed, non-empty serialized record and length must fit the
 * Registry API's DWORD size.  The payload is deliberately opaque here: the
 * Haskell state machine owns its schema, integrity checks, and legal phase
 * transitions.  RegSetValueExW replaces only the fixed ActiveRecord value
 * under the fixed HKCU key, and RegFlushKey is required before success is
 * reported.
 *
 * This is a recovery ordering boundary.  The caller does not advance to the
 * next filesystem step until the record describing the preceding state is
 * known to have been submitted for durable storage.  If setting or flushing
 * fails, the returned error forces recovery to re-observe durable state.
 * Callers must hold the global mutex; this function supplies durability, not
 * independent compare-and-swap isolation.
 */
uint32_t hb_wsl_registry_store_active(const uint8_t *bytes, size_t length) {
  HKEY key = NULL;
  LONG status;

  if (bytes == NULL || length == 0 || length > UINT32_MAX) {
    return ERROR_INVALID_PARAMETER;
  }
  status = hb_wsl_open_registry(&key);
  if (status != ERROR_SUCCESS) {
    return (uint32_t)status;
  }
  status = RegSetValueExW(key,
                          HB_WSL_ACTIVE_VALUE,
                          0,
                          REG_BINARY,
                          bytes,
                          (DWORD)length);
  if (status == ERROR_SUCCESS) {
    status = RegFlushKey(key);
  }
  RegCloseKey(key);
  return (uint32_t)status;
}

/*
 * Conditionally retire exactly the active record the caller completed.
 *
 * expected is a borrowed, non-empty serialized record.  deleted_out must be
 * non-NULL and is initialized to zero.  Missing ActiveRecord, a different
 * value type/length, or different bytes are all successful "not deleted"
 * results.  Only an exact byte-for-byte match is deleted and flushed, after
 * which *deleted_out is set to one.
 *
 * The equality guard prevents cleanup for an old receipt from erasing a newer
 * recovery record.  It is intentionally stronger than checking only an owner
 * or fence field and keeps record parsing out of the C boundary.  The observed
 * value is malloc-allocated internally and freed on every path; no allocation
 * escapes this function.
 *
 * Query/compare/delete is cooperative compare-and-delete, not a Registry
 * transaction.  The caller must retain the global mutex throughout.  A flush
 * error is returned even if RegDeleteValueW already succeeded; recovery must
 * then reload rather than assume either durable outcome.
 */
uint32_t hb_wsl_registry_delete_active_if_equal(const uint8_t *expected,
                                                 size_t expected_length,
                                                 int *deleted_out) {
  HKEY key = NULL;
  DWORD value_type = 0;
  DWORD value_length = 0;
  uint8_t *observed = NULL;
  LONG status;

  if (expected == NULL || expected_length == 0 || deleted_out == NULL) {
    return ERROR_INVALID_PARAMETER;
  }
  *deleted_out = 0;
  status = hb_wsl_open_registry(&key);
  if (status != ERROR_SUCCESS) {
    return (uint32_t)status;
  }
  status = RegQueryValueExW(key,
                            HB_WSL_ACTIVE_VALUE,
                            NULL,
                            &value_type,
                            NULL,
                            &value_length);
  if (status == ERROR_FILE_NOT_FOUND) {
    RegCloseKey(key);
    return ERROR_SUCCESS;
  }
  if (status != ERROR_SUCCESS) {
    RegCloseKey(key);
    return (uint32_t)status;
  }
  if (value_type != REG_BINARY || value_length != expected_length) {
    RegCloseKey(key);
    return ERROR_SUCCESS;
  }
  observed = (uint8_t *)malloc(value_length);
  if (observed == NULL) {
    RegCloseKey(key);
    return ERROR_NOT_ENOUGH_MEMORY;
  }
  status = RegQueryValueExW(key,
                            HB_WSL_ACTIVE_VALUE,
                            NULL,
                            &value_type,
                            observed,
                            &value_length);
  if (status != ERROR_SUCCESS) {
    free(observed);
    RegCloseKey(key);
    return (uint32_t)status;
  }
  if (memcmp(observed, expected, expected_length) != 0) {
    free(observed);
    RegCloseKey(key);
    return ERROR_SUCCESS;
  }
  free(observed);
  status = RegDeleteValueW(key, HB_WSL_ACTIVE_VALUE);
  if (status == ERROR_SUCCESS) {
    status = RegFlushKey(key);
  }
  RegCloseKey(key);
  if (status != ERROR_SUCCESS) {
    return (uint32_t)status;
  }
  *deleted_out = 1;
  return ERROR_SUCCESS;
}
