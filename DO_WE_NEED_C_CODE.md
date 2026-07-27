# Do we need `cbits/wsl_global_wall.c`?

**Question raised:** Can we eliminate the C code in
`core/hostbootstrap-core/cbits/wsl_global_wall.c` and solve the same problem the
idiomatic Haskell way? Is there a way to *circumvent* the need for it at all?

**Short answer:**

- **You cannot remove the low-level Win32 calls while keeping the guarantee the
  code exists to provide.** That guarantee — identity-authoritative ownership
  with a strong, crash-durable cleanup receipt — is exactly what forces
  `FILE_ID` binding, no-replace rename, handle-bound delete, delete-on-close
  staging, an NTFS hard-link handoff, and a flushed Registry journal. No release
  of the `Win32` package and no other Hackage package binds that combination.
  "Do it in Haskell instead" **relocates** the FFI boundary into Haskell
  `foreign import` declarations; it does not remove it.
- **You *can* delete the C, all FFI, and all struct marshalling entirely — but
  only by opting this wall *out* of the project's ownership doctrine**, down to
  pathname-based ownership (a backup file + a lock + an atomic rename + an
  idempotent re-merge). That is small, cross-platform, and idiomatic, but it is
  precisely the weakening that this repository's own design docs consider and
  reject as non-authoritative.

So "do we *need* it" is not a technical question with a single answer — it is a
decision about whether the Windows `.wslconfig` wall must satisfy the same
"strong receipt" ownership contract the rest of the codebase is being built to.

---

## 1. What the C code actually does

`wsl_global_wall.c` is a narrow, stateless Win32 shim (~1170 lines, mostly
comments) that supplies the platform mechanisms for one job: **atomically and
reversibly edit the current user's `%USERPROFILE%\.wslconfig`, safely against
concurrent hostbootstrap processes and survivably across a process crash.** The
policy and state machine live in Haskell
(`src/HostBootstrap/Wsl2/GlobalWall.hs`, a pure model; `.../GlobalWall/Windows.hs`,
the adapter; `.../GlobalWall/ConfigBytes.hs`, the byte merge). The C layer only
provides the primitives Haskell cannot express through its current dependencies:

| Primitive | Win32 call(s) | Purpose |
|---|---|---|
| Per-user cross-process lock | `CreateMutexW` / `WaitForSingleObject` / `ReleaseMutex`, name = `Global\…\<SID>` from `OpenProcessToken`→`GetTokenInformation`→`ConvertSidToStringSidW` | Serialize competing writers |
| Authoritative target path | `SHGetKnownFolderPath(FOLDERID_Profile)` + `\.wslconfig` | Not redirectable via `%USERPROFILE%` |
| Exclusive, symlink-safe open | `CreateFileW` (share 0, `GENERIC_READ\|DELETE`, `FILE_FLAG_OPEN_REPARSE_POINT`) + reject directory/reparse | Lock the real object, refuse junction/symlink |
| Stable file identity | `GetFileInformationByHandleEx(FileIdInfo)` → 24-byte `FILE_ID_INFO` (128-bit id + volume serial) | Bind every later op to the object actually verified |
| Armed staging | `CREATE_NEW` + `FILE_FLAG_WRITE_THROUGH` + `FlushFileBuffers` + `FILE_FLAG_DELETE_ON_CLOSE` | Durable bytes; a crash removes the uncommitted stage |
| Crash-safe handoff | `CreateHardLinkW` (no-replace) then close the armed handle | Give the flushed bytes a durable second name under the same `FILE_ID` |
| No-replace handle rename | `SetFileInformationByHandle(FileRenameInfo, ReplaceIfExists=FALSE)` (variable-length struct) | Publish/retain by identity, never clobber a surprise |
| Handle-bound delete | `SetFileInformationByHandle(FileDispositionInfo)` | Delete the verified object, not a possibly-substituted name |
| NTFS gate | `GetVolumeInformationByHandleW` | Hard-link/delete-on-close semantics validated only on NTFS |
| Durable journal + fence | `RegCreateKeyExW` / `RegQueryValueExW` / `RegSetValueExW` / `RegDeleteValueW` / `RegFlushKey` under a fixed HKCU key | Recover which on-disk file is user-original vs. staged vs. installed after a crash |

The C header's own thesis (lines 7–16): **"Path strings alone are not
sufficient evidence: between two path-based operations another process can
rename, replace, or redirect the name."** Every mechanism above is a direct
consequence of refusing to trust a pathname.

---

## 2. What "idiomatic Haskell" can and cannot supply

Verified against the **installed** toolchain: `Win32-2.14.2.1`, bundled with
GHC 9.12.4 (so using it adds **no new dependency**). The relevant modules were
checked function-by-function against the Hackage docs for that exact version.

**Already bound by the `Win32` package (~half the calls):**

| Need | Binding |
|---|---|
| open / close / flush handle | `System.Win32.File`: `createFile`, `closeHandle`, `flushFileBuffers` |
| NTFS hard link | `System.Win32.HardLink.createHardLink` |
| Registry + flush | `System.Win32.Registry`: `regCreateKeyEx`, `regQueryValueEx`, `regSetValueEx`, `regDeleteValue`, `regFlushKey` |
| bounded wait | `System.Win32.Event.waitForSingleObject` + `wAIT_ABANDONED/TIMEOUT/OBJECT_0/FAILED` |
| profile folder | `System.Win32.Shell.sHGetFolderPath` + `cSIDL_PROFILE` — the *older* CSIDL API, **not** the modern `SHGetKnownFolderPath` the C deliberately uses |

**NOT bound by any `Win32` release, and not bound by any other Hackage package —
would require raw `foreign import ccall` + hand-written `Storable` instances:**

- `GetFileInformationByHandleEx` with `FileIdInfo` / `FileAttributeTagInfo` /
  `FileStandardInfo`. `Win32` exposes only the **legacy** 64-bit
  `getFileInformationByHandle` (`BY_HANDLE_FILE_INFORMATION`), not the 128-bit
  `FILE_ID_INFO`. **This is the identity foundation of the whole protocol.**
- `SetFileInformationByHandle` with `FileRenameInfo` (a **variable-length**
  struct; no-replace) and `FileDispositionInfo`. Not exposed at all.
- `CreateMutexW` / `ReleaseMutex`. `System.Win32.Event` binds the *wait* but not
  mutex create/release.
- `GetVolumeInformationByHandleW`. Not exposed.
- Token/SID for the per-SID mutex name: `OpenProcessToken`,
  `GetTokenInformation(TokenUser)`, `ConvertSidToStringSidW`.
  `System.Win32.Security` exposes only `SID`/`ACL` types + `getFileSecurity`.
- `SHGetKnownFolderPath` (if you want to preserve the exact authoritative
  behavior rather than fall back to CSIDL).

**Conclusion for this section:** the C file's header claim (lines 32–39) is
factually correct. A Haskell reimplementation *"would still require an FFI
boundary"* — you would be replacing ~1170 lines of audited C with a comparable
body of Haskell `foreign import` declarations plus manual `poke`/`peek`
marshalling of Win32 info-class structs, the trickiest of which
(`FILE_RENAME_INFO`) is variable-length. **There is no library that hands you
identity-authoritative file ownership on Windows.** That is not a gap you can
shop around; it is inherent to the guarantee.

---

## 3. Why the machinery exists — it is a codebase-wide doctrine, not a one-off

This is the decisive context. The heavy protocol is **not** incidental
complexity around one config file. It is the Windows-filesystem instantiation of
an ownership doctrine applied throughout the repository.

`documents/architecture/durable_state.md` states the doctrine directly:

- Of an ordinary shared pathname (lines 74–75): *"…create/check/remove logic
  **cannot exclude a same-privilege process replacing it between operations, so
  it is not an identity-authoritative ownership backend and cannot honestly mint
  a strong cleanup receipt.**"*
- The general rule (lines 128–131): *"Strong … reconciliation is available only
  when the substrate supplies a **protected namespace plus an identity-bound
  conditional mutation/delete** … Otherwise it returns `Unsupported`; an
  explicitly named cooperative pathname guard … **cannot mint the strong
  receipt**."*

Every piece of the wall maps onto that requirement:

- `FILE_ID` binding + no-replace rename + handle-bound delete → *"identity-bound
  conditional mutation/delete."*
- per-SID mutex + reparse-point rejection → *"protected namespace."*
- HKCU journal + monotonic fence → *"strong, durable cleanup receipt"* that
  survives a crash.

### The documented threat model

Stated in prose, in terms of a **generic same-privilege process**, plus one
concrete crash/retry data-loss narrative:

- `documents/engineering/wsl2.md` (lines 59–66): *"If a run crashes after its
  first write, retry can save generated content as the 'original'; concurrent
  runs can also overwrite the global setting. … A pathname sidecar or
  process-local lock is explicitly insufficient."*
- `documents/engineering/applied_cordon.md` (lines 183–193): *"If the original
  was absent and the first run crashes after writing, no absence receipt exists;
  retry can back up the generated file as if it were the original, so teardown
  restores generated content rather than absence. … concurrent projects can race
  the file."*

### The simpler alternatives were already considered and rejected

The exact circumventions one would reach for are named and refused in the plan
docs:

- `DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md` (lines 742–745):
  *"**bare exclusive create/rename, content comparison, and compare-then-unlink
  do not exclude a same-privilege replacement.** Only an OS-protected namespace
  plus a conditional identity-bound mutation/delete may mint a strong receipt;
  otherwise return `Unsupported`."*
- `DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md` (lines 497–501):
  *"…only a protected namespace with an identity-bound kernel operation may mint
  a strong receipt. **A local sidecar/cooperative lock remains a weaker mode.**"*
- `documents/engineering/wsl2.md` (line 65): *"**A pathname sidecar or
  process-local lock is explicitly insufficient.**"*

### The merge is idempotent and content-preserving (this is what makes a simpler design even possible)

`ConfigBytes.hs` (module header, lines 3–8): *"Strict, byte-preserving merge …
Only five keys are controlled. Unknown keys, comments, whitespace, section
spelling, BOM, and every unrelated byte are retained."* Idempotence is enforced
by `WslGlobalWallConfigBytesSpec.hs` (`assertExactIdempotent`,
`assertUtf16Idempotent`, including UTF-16 LE/BE BOM cases).

---

## 4. The critical status caveat

Three facts materially affect whether the machinery is *needed today*:

1. **It is uncommitted work-in-progress.** `cbits/` and
   `src/HostBootstrap/Wsl2/` are **untracked** (`?? …` in `git status`). There is
   no commit history and no commit-message rationale — everything is in code
   comments and design docs.
2. **It is the *target* design, not yet the live path.** `wsl2.md` (lines
   60–66) and `applied_cordon.md` (lines 190–227) describe the exclusive-owner
   protocol as the goal, with **Sprint 11.10 / 5.7 still open**. The live
   provider path does not yet mint the strong lease/receipt.
3. **It is architecture-mandated, not incident-driven.** The only concrete
   data-loss story is the internal crash/retry "back up generated content as the
   original" sequence — a *modeled* failure of the ownership contract, not a
   reported real-world incident with a **named** third-party writer. Notably, **no
   document names Docker Desktop, WSL itself, or the user's editor** as a racing
   writer; the modeled adversary is generically "another same-privilege
   process."

This is the honest crux for the evaluation: the strong protocol is being built
to satisfy a self-imposed formal ownership contract, driven by a modeled threat,
for a file that in practice is the current user's own home-directory config.

---

## 5. The options

### Option A — Simplify by relaxing the ownership model  *(the real "circumvent it all")*

Delete the C, all FFI, and all `Storable` marshalling. Replace with three
ordinary building blocks, leaning on properties the system already has
(idempotent merge; restore needs only original bytes):

- **Backup file** next to `.wslconfig`, created only if absent — it *is* the
  recovery record, replacing the HKCU journal + fences + `FILE_ID` origin +
  delete-on-close/hard-link handoff.
- **`filelock` package** (`LockFileEx` on Windows, `flock` elsewhere) for the
  cross-process lock — replacing the per-SID mutex and all token/SID FFI.
- **`atomic-write`** (or a temp file + `System.Directory.renamePath`, which maps
  to `MoveFileEx` replace) for the swap.

Crash recovery becomes: *re-run the idempotent merge; restore = copy the backup
back.* Zero C, zero FFI, cross-platform, a fraction of the code.

- **Pros:** dramatically simpler; one language; no `Storable` structs; portable;
  reuses the pure `ConfigBytes` merge unchanged.
- **Cons:** pathname-based ownership — **exactly** the "ordinary shared pathname
  … cannot honestly mint a strong cleanup receipt" mode that `durable_state.md`
  and the phase-9/10 plans reject. Weak against a same-privilege process racing
  between steps, and against a symlink planted at `.wslconfig` (you could write
  through a redirect). Makes the Windows wall **inconsistent** with how the rest
  of the codebase defines ownership.

### Option B — Keep the doctrine, trim the FFI only

Keep the identity-authoritative guarantees. Delete the `.c` file, move the ~half
`Win32` binds into the `Win32` package, and reimplement the crash-safety half as
raw `foreign import ccall` + hand-written `Storable` structs in an internal
Haskell module.

- **Pros:** removes the separate C translation unit; single-language source.
- **Cons:** does **not** remove the FFI boundary — it relocates it. The
  variable-length `FILE_RENAME_INFO` marshalling and byte-exact `FILE_ID`
  handling move from audited C `memcpy`/`offsetof` into Haskell `poke`/`peek`,
  which the C header argues (lines 36–39) is *harder to audit*. Net complexity is
  roughly unchanged; net risk arguably rises during the port. Mutex thread
  affinity now needs explicit bound-thread management (`runInBoundThread`).

### Option C — Keep the C as-is

- **Pros:** the research confirms it is the deliberate Windows realization of a
  codebase-wide ownership doctrine, and no simpler form preserves its
  guarantees. The narrow, heavily-commented C is a reasonable place to keep
  fiddly struct layout and no-replace semantics.
- **Cons:** none technical; it is a C file in an otherwise Haskell/Python repo,
  and it is still unproven (Sprint 11.10 open, untracked).

### Option D — Return `Unsupported` on Windows  *(doctrine-consistent way to avoid the work)*

The plans explicitly sanction this: *"otherwise return `Unsupported`."* Don't
fake a strong wall — do on Windows what the off-Windows adapter already does, and
require the user to set `.wslconfig` manually (or offer a clearly-labelled,
non-authoritative best-effort edit).

- **Pros:** honest per the doctrine; deletes everything; no weak-mode pretense.
- **Cons:** drops the automatic WSL global-limit feature on Windows — the
  primary platform this feature targets.

---

## 6. Recommendation

There is no "free" elimination. Pick based on how load-bearing the strong
ownership guarantee actually is **for this file**:

- **If the guarantee is real and intended to stay** (i.e., you still believe the
  phase-9/10 doctrine should govern `.wslconfig`): **keep the C (Option C).**
  Option B buys single-language purity at the cost of relocating — and arguably
  obscuring — the most safety-critical marshalling. That is a poor trade for a
  crash-recovery protocol.

- **If the guarantee is over-scoped for this file** — which is defensible: the
  threat is a *modeled* generic same-privilege racer with **no documented
  third-party writer**, on the current user's own home-directory config, and the
  merge is idempotent — then **Option A** is the genuinely idiomatic Haskell
  outcome and removes the C honestly. It should be adopted as a **conscious
  doctrine decision**, with `durable_state.md` / `wsl2.md` / the phase-9/10 plans
  updated to record that the `.wslconfig` wall intentionally uses the weaker,
  pathname-based mode (and why), so the codebase does not silently contradict its
  own stated ownership contract.

My suggested path: **decide the doctrine question first.** If you want the strong
guarantee, keep the C. If you're willing to relax it for this file, take
Option A and update the docs to match — do not take Option B (it is the worst of
both: same guarantee, same FFI, harder to audit, more porting risk).

---

## 7. Blast radius (whichever direction is chosen)

- **Tests:** only the Windows-gated branch of
  `core/hostbootstrap-core/test/WslGlobalWallWindowsSpec.hs` calls the
  `hb_wsl_*` symbols directly (7 of them, via its own `foreign import`s inside
  `#if defined(mingw32_HOST_OS)`). It would need rewriting for Options A/B/D.
  `WslGlobalWallSpec.hs` (pure model) and `WslGlobalWallConfigBytesSpec.hs` (pure
  merge) are insulated and unaffected.
- **Cabal:** `hostbootstrap-core.cabal` (lines 91–97) has the `if os(windows)`
  block with `c-sources: cbits/wsl_global_wall.c` and
  `extra-libraries: advapi32, ole32, shell32`. Option A removes that block and
  adds `filelock` (and optionally `atomic-write`) + `Win32` to `build-depends`.
  Option B keeps `extra-libraries` (raw FFI still links them) and adds `Win32`.
- **Pure model:** Option A can drastically shrink or largely retire
  `GlobalWall.hs`'s journal/fence/phase machinery (the pure state machine exists
  to drive the strong protocol); `ConfigBytes.hs` is reused unchanged in every
  option.

---

## Appendix — verification evidence

- Win32 coverage checked against Hackage docs for the **installed**
  `Win32-2.14.2.1` (GHC 9.12.4): `System.Win32.File` exports `createFile`,
  `closeHandle`, `flushFileBuffers`, `getFileInformationByHandle` (legacy),
  `setFileAttributes` — **not** `getFileInformationByHandleEx` /
  `setFileInformationByHandle` and **no** `FILE_ID_INFO` / `FILE_RENAME_INFO` /
  `FILE_DISPOSITION_INFO`. `System.Win32.Shell` exports `sHGetFolderPath` +
  `cSIDL_PROFILE`, not `sHGetKnownFolderPath`. `System.Win32.Event` exports
  `waitForSingleObject` + wait constants, not `createMutex`/`releaseMutex`.
  `System.Win32.Security` exports `SID`/`ACL` + `getFileSecurity`, not
  `openProcessToken`/`getTokenInformation`/`ConvertSidToStringSid`.
- `System.Directory.renamePath` maps to `MoveFileEx` with
  `MOVEFILE_REPLACE_EXISTING` (replace-in-place; documented "not guaranteed to be
  atomic" on Windows — the temp-write-then-rename + backup pattern is the
  standard mitigation).
- Source files: `cbits/wsl_global_wall.c`;
  `src/HostBootstrap/Wsl2/GlobalWall.hs`, `.../GlobalWall/Windows.hs`,
  `.../GlobalWall/ConfigBytes.hs`; tests under `test/WslGlobalWall*.hs`.
- Rationale docs: `documents/architecture/durable_state.md`;
  `documents/engineering/wsl2.md`; `documents/engineering/applied_cordon.md`;
  `DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md`;
  `DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md`;
  `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.
- Git state: `cbits/` and `src/HostBootstrap/Wsl2/` are untracked; no commit
  history exists for the wall.
