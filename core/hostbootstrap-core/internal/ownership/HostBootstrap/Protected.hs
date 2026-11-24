{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | The protected, versioned record store the lifecycle authority machinery
compare-and-swaps against.

Every durable decision the lifecycle makes — which mode a project is in, which
broker generation is live, which invocation has already been consumed, which
operation session is open — is a record in this store.  The store is the
mechanism § EE calls "one protected compare-and-swap": it does not interpret
any of those records, it only guarantees that

* no read or write happens outside an OS-released exclusive entry (clause 1 —
  a 'ProtectedSession' is the only key to 'readProtectedRecord' /
  'compareAndSwapProtectedRecord', and every operation checks that its entry
  remains live in the owning thread);
* a write syncs a complete temporary before atomic rename, uses write-through
  replacement on Windows, and syncs the parent directory on POSIX, so after
  process death, an OS crash, or power loss a
  record is the old one or the complete new one, provided storage honors the
  requested flushes. Darwin requests the drive flush with @F_FULLFSYNC@;
* a write lands only against the exact version the caller observed, so two
  cooperating runs cannot both win, and the successor version is returned to
  the winner (this is the "sole successor state/permit pair" the callers
  thread);
* the store itself has a durable generative identity, so a retained proof from
  a store that was deleted and recreated cannot be replayed against the new
  one.

The exclusive entry is @base@'s portable 'hLock', which is @flock@/@fcntl@ on
POSIX and @LockFileEx@ on Windows and is released by the kernel when the
holding process dies.  An in-process 'MVar' is held with it because POSIX
record locks are per-process rather than per-thread.

What this buys is exactly what
[ownership_invariant](../documents/architecture/ownership_invariant.md) states:
it excludes crash/retry and concurrent cooperating runs and it detects rather
than silently overwrites foreign mutation.  It does not exclude a hostile
same-privilege process.
-}
module HostBootstrap.Protected (
    -- * The store
    ProtectedStore,
    openProtectedStore,
    openExistingProtectedStore,
    protectedStoreRoot,
    ProtectedStoreIdentity,
    protectedStoreIdentity,
    protectedStoreIdentityText,

    -- * Exclusive entry
    ProtectedSession,
    withProtectedEntry,
    tryProtectedEntry,
    verifyProtectedSession,

    -- * Run liveness
    withRunLiveness,
    sessionStoreIdentity,
    sessionStoreRoot,
    verifyProtectedStoreWritable,

    -- * Records
    RecordKey,
    mkRecordKey,
    recordKeyText,
    mkRecordName,
    mkRecordSegment,
    recordNameIdentity,
    recordTupleSeparator,
    RecordVersion,
    recordVersionWord,
    ProtectedRecord (..),
    Expectation (..),
    readProtectedRecord,
    listProtectedRecords,
    compareAndSwapProtectedRecord,
    compareAndDeleteProtectedRecord,

    -- * Failures
    ProtectedError (..),
    protectedErrorMessage,
    classifyProtectedException,
) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, putMVar, tryTakeMVar, withMVar)
import Control.Exception (Handler (Handler), IOException, SomeException, bracket, catches, displayException, finally, fromException, mask, onException, toException)
import Control.Exception.Safe (try)
import qualified Control.Exception.Safe as Safe
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Char (isAsciiLower, isAsciiUpper, isControl, isSpace, toLower, toUpper)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isSuffixOf, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Protected.Publication (
    syncPublishedFile, renamePublishedFile, syncPublishedParent,
#if defined(mingw32_HOST_OS)
    windowsPublishedPath,
#endif
 )
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Handle.Lock (FileLockingNotSupported, LockMode (ExclusiveLock), hLock, hTryLock)
import GHC.IO.Exception (IOErrorType (UnsupportedOperation))
import System.Directory (
    canonicalizePath,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    makeAbsolute,
    removeFile,
 )
import System.FilePath ((<.>), (</>))
import System.IO (
    BufferMode (NoBuffering),
    hClose,
    hFlush,
    hSetBuffering,
    withFile,
 )
import qualified System.IO as IO
import System.IO.Error (ioeGetErrorType, isDoesNotExistError, isPermissionError)
import System.IO.Unsafe (unsafePerformIO)
#if !defined(mingw32_HOST_OS)
import System.Posix.Files (deviceID, fileID, getFdStatus, getFileStatus)
import System.Posix.IO (
    OpenFileFlags (cloexec, creat),
    OpenMode (ReadWrite),
    closeFd,
    defaultFileFlags,
    fdToHandle,
    openFd,
 )
#else
import System.IO (IOMode (ReadWriteMode), openFile)
import Data.Bits ((.|.))
import Data.Word (Word32)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (allocaArray)
import Foreign.Ptr (Ptr, castPtr, nullPtr, plusPtr)
import Foreign.Storable (peekByteOff)
import System.Win32.File (closeHandle, createFile, fILE_ATTRIBUTE_NORMAL, fILE_SHARE_READ, fILE_SHARE_WRITE, gENERIC_READ, gENERIC_WRITE, oPEN_EXISTING)
import System.Win32.Types (HANDLE, LPCTSTR, hANDLEToHandle, peekTString)
#endif

-- The store --------------------------------------------------------------------

{- | An opened protected store rooted at one directory. The constructor is
private: a store value exists only after its root, lock file, and durable
identity have been established.
-}
data ProtectedStore = ProtectedStore
    { storeRoot :: FilePath
    , storeIdentity :: ProtectedStoreIdentity
    , storeMutex :: MVar ()
    , storeHolder :: IORef (Maybe ThreadId)
    , storeLockIdentity :: Maybe (Word64, ByteString)
    }

-- | The store's durable generative identity, written once when it is created.
newtype ProtectedStoreIdentity = ProtectedStoreIdentity Text
    deriving (Eq, Ord)

instance Show ProtectedStoreIdentity where
    show (ProtectedStoreIdentity value) = "ProtectedStoreIdentity " <> show value

protectedStoreIdentityText :: ProtectedStoreIdentity -> Text
protectedStoreIdentityText (ProtectedStoreIdentity value) = value

protectedStoreRoot :: ProtectedStore -> FilePath
protectedStoreRoot = storeRoot

protectedStoreIdentity :: ProtectedStore -> ProtectedStoreIdentity
protectedStoreIdentity = storeIdentity

-- Independent handles to one directory must share the in-process
-- lock: POSIX record locks alone do not exclude threads in the same process.
-- The registry keeps each lock for the process lifetime so a waiter can never
-- race replacement of the exclusion domain.
{-# NOINLINE processStoreLocks #-}
processStoreLocks :: MVar [(FilePath, (MVar (), IORef (Maybe ThreadId)))]
processStoreLocks = unsafePerformIO (newMVar [])

storeProcessLock :: FilePath -> IO (MVar (), IORef (Maybe ThreadId))
storeProcessLock rawKey = modifyMVar processStoreLocks $ \locks ->
    case lookup key locks of
        Just existing -> pure (locks, existing)
        Nothing -> do
            mutex <- newMVar ()
            holder <- newIORef Nothing
            let entry = (mutex, holder)
            pure ((key, entry) : locks, entry)
  where
#if defined(mingw32_HOST_OS)
    key = map toLower rawKey
#else
    key = rawKey
#endif

-- On POSIX, directory identity also covers aliases introduced by bind mounts.
directoryLockKey :: FilePath -> IO String
#if defined(mingw32_HOST_OS)
directoryLockKey root = map toLower <$> canonicalizePath root
#else
directoryLockKey root = do
    canonicalRoot <- canonicalizePath root
    status <- getFileStatus canonicalRoot
    pure (show (deviceID status) <> ":" <> show (fileID status))
#endif

{- | Open (creating if necessary) the protected store under an absolute
directory. The identity file is created exactly once and read thereafter, so
every later process observes the same store identity — and a store that was
removed and recreated presents a different one. Its envelope also names the
record-name encoding; an incompatible envelope or identity-less populated
store is refused without interpreting its records.
-}
openProtectedStore :: FilePath -> IO (Either ProtectedError ProtectedStore)
openProtectedStore rawRoot
    | null rawRoot = pure (Left (ProtectedInvalid "the protected store root must not be empty"))
    | otherwise = do
        outcome <- tryProtectedIO $ do
            root <- makeAbsolute rawRoot
            createDirectoryIfMissing True (root </> recordsDirectory)
            rootKey <- directoryLockKey root
            (mutex, holder) <- storeProcessLock ("store:" <> rootKey)
            identity <- establishIdentity root mutex holder
            pure (fmap (\value -> ProtectedStore root value mutex holder Nothing) identity)
        pure (either (Left . classifyProtectedException "open the protected store") id outcome)

-- | Open only an established store. Neither this open nor its entries create
-- a missing root, records directory, identity envelope, or lock file.
openExistingProtectedStore :: FilePath -> IO (Either ProtectedError ProtectedStore)
openExistingProtectedStore rawRoot
    | null rawRoot = pure (Left (ProtectedInvalid "the protected store root must not be empty"))
    | otherwise = do
        outcome <- tryProtectedIO $ do
            root <- makeAbsolute rawRoot
            recordsPresent <- doesDirectoryExist (root </> recordsDirectory)
            if not recordsPresent
                then pure (Left (ProtectedInvalid "the existing protected store records directory is absent"))
                else do
                    identity <- readIdentity (root </> identityFileName)
                    case identity of
                        Left failure -> pure (Left failure)
                        Right Nothing -> pure (Left (ProtectedInvalid "the existing protected store identity is absent"))
                        Right (Just value) -> do
                            lockIdentity <- existingLockIdentityAtPath (root </> lockFileName)
                            rootKey <- directoryLockKey root
                            (mutex, holder) <- storeProcessLock ("store:" <> rootKey)
                            pure (Right (ProtectedStore root value mutex holder (Just lockIdentity)))
        pure (either (Left . classifyProtectedException "open the existing protected store") id outcome)

recordsDirectory :: FilePath
recordsDirectory = "records"

lockFileName :: FilePath
lockFileName = "store.lock"

identityFileName :: FilePath
identityFileName = "store.identity"

{- | Read the store's durable identity, creating it exactly once.

The already-established case deliberately does **not** take the exclusive
entry: opening a store must not block behind whatever transaction another
process is currently running, and the identity is immutable once written. Only
first creation takes the lock, and it re-reads under it so two racing creators
still agree on one identity.
-}
establishIdentity ::
    FilePath ->
    MVar () ->
    IORef (Maybe ThreadId) ->
    IO (Either ProtectedError ProtectedStoreIdentity)
establishIdentity root mutex holder = do
    existing <- readIdentity path
    case existing of
        Left failure -> pure (Left failure)
        Right (Just identity) -> pure (Right identity)
        Right Nothing -> withStoreLock root mutex holder $ do
            raced <- readIdentity path
            case raced of
                Left failure -> pure (Left failure)
                Right (Just identity) -> pure (Right identity)
                Right Nothing -> do
                    entries <- listDirectory (root </> recordsDirectory)
                    if null entries
                        then do
                            nonce <- freshNonce
                            publishBytes path (TextEncoding.encodeUtf8 ("hbps2 " <> nonce <> "\n"))
                            pure (Right (ProtectedStoreIdentity nonce))
                        else
                            pure
                                (Left (ProtectedInvalid "the protected store identity envelope is missing from a populated store"))
  where
    path = root </> identityFileName

readIdentity :: FilePath -> IO (Either ProtectedError (Maybe ProtectedStoreIdentity))
readIdentity path = do
    present <- doesFileExist path
    if not present
        then pure (Right Nothing)
        else do
            raw <- ByteString.readFile path
            pure $ case TextEncoding.decodeUtf8' raw of
                Right envelope
                    | Just terminated <- Text.stripPrefix "hbps2 " envelope
                    , Just nonce <- Text.stripSuffix "\n" terminated
                    , not (Text.null nonce)
                    , Text.all (\character -> not (isSpace character || isControl character)) nonce ->
                        Right (Just (ProtectedStoreIdentity nonce))
                _ ->
                    Left
                        (ProtectedInvalid "the protected store identity envelope is incompatible with record-name encoding hbps2")

{- | A generative nonce for one store. It is durable after the first write, so
its only requirement is that two stores created on one host do not collide.
-}
freshNonce :: IO Text
freshNonce = do
    stamp <- getMonotonicTimeNSec
    pure (Text.pack ("hbps-" <> showHex64 stamp))

showHex64 :: Word64 -> String
showHex64 value = go value ""
  where
    go remaining acc
        | remaining < 16 = digit remaining : acc
        | otherwise = go (remaining `div` 16) (digit (remaining `mod` 16) : acc)
    digit d
        | d < 10 = toEnum (fromEnum '0' + fromIntegral d)
        | otherwise = toEnum (fromEnum 'a' + fromIntegral d - 10)

-- Exclusive entry ---------------------------------------------------------------

{- | Entry-bound authority for record operations. The nominal @session@ index
is bound by the entry bracket. Ordinary IO can retain a session in a closure,
so each effectful operation also checks its private live token and owner thread.
The token is revoked before the bracket releases the store lock.
-}
type role ProtectedSession nominal
data ProtectedSession session = ProtectedSession ProtectedStore ThreadId (IORef Bool)

sessionStoreIdentity :: ProtectedSession session -> ProtectedStoreIdentity
sessionStoreIdentity (ProtectedSession store _ _) = storeIdentity store

-- | The store's absolute root, for the operator check that must inspect it.
sessionStoreRoot :: ProtectedSession session -> FilePath
sessionStoreRoot (ProtectedSession store _ _) = storeRoot store

withFreshProtectedSession ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO result) ->
    IO result
withFreshProtectedSession store action = mask $ \restore -> do
    owner <- myThreadId
    live <- newIORef True
    restore (action (ProtectedSession store owner live))
        `finally` writeIORef live False

-- Existing-only callers recheck the store envelope while holding the same
-- exclusive lock as ordinary entries, before handing out a live session.
withCurrentProtectedSession ::
    ProtectedStore -> (forall session. ProtectedSession session -> IO (Either ProtectedError result)) ->
    IO (Either ProtectedError result)
withCurrentProtectedSession store action
    | storeLockIdentity store == Nothing = withFreshProtectedSession store action
    | otherwise = do
        recordsPresent <- doesDirectoryExist (storeRoot store </> recordsDirectory)
        identity <- readIdentity (storeRoot store </> identityFileName)
        currentLock <- existingLockIdentityAtPath (storeRoot store </> lockFileName)
        case identity of
            Left failure -> pure (Left failure)
            Right (Just current)
                | recordsPresent && current == storeIdentity store && Just currentLock == storeLockIdentity store ->
                    withFreshProtectedSession store action
            _ -> pure (Left (ProtectedInvalid "the existing protected store identity, lock, or records directory changed"))

-- | Check this entry's existing live token and owner thread, without filesystem effects.
verifyProtectedSession :: ProtectedSession session -> IO (Either ProtectedError ())
verifyProtectedSession session =
    withActiveProtectedSession session (const (pure (Right ())))

withActiveProtectedSession ::
    ProtectedSession session ->
    (ProtectedStore -> IO (Either ProtectedError result)) ->
    IO (Either ProtectedError result)
withActiveProtectedSession (ProtectedSession store owner live) action = do
    active <- readIORef live
    self <- myThreadId
    if not active
        then pure (Left (ProtectedInvalid "the protected session is no longer live"))
        else
            if self /= owner
                then pure (Left (ProtectedInvalid "the protected session belongs to another thread"))
                else action store

{- | Ask the operating system whether the current principal can create and
remove a file in the exact records directory this session protects.

The probe runs inside the store's exclusive entry, uses an exclusive temporary
name, and removes it on normal and catchable-exceptional exit. Opening the
directory or inspecting a portable permissions record is not equivalent on
Windows, where the effective ACL decision is made only by the attempted file
operation.
-}
verifyProtectedStoreWritable ::
    ProtectedSession session ->
    IO (Either ProtectedError ())
verifyProtectedStoreWritable session = withActiveProtectedSession session $ \store -> do
    let recordsRoot = storeRoot store </> recordsDirectory
    outcome <-
        try $
            bracket
                (IO.openBinaryTempFile recordsRoot ".hostbootstrap-write-probe")
                (\(path, handle) -> hClose handle `finally` removeFile path)
                (const (pure ()))
    pure (either (Left . mutationFailure "verify write access to the protected record store") Right outcome)

{- | Run an action under the store's OS-released exclusive lock (clause 1). The
lock spans the whole observe/mutate/settle bracket, and the kernel releases it
if this process dies mid-bracket.

Re-entry by the holding thread is refused: use its existing session instead.
-}
withProtectedEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either ProtectedError result)) ->
    IO (Either ProtectedError result)
withProtectedEntry store action = do
    self <- myThreadId
    holder <- readIORef (storeHolder store)
    if holder == Just self
        then
            pure
                ( Left
                    ( ProtectedInvalid
                        "the protected store entry is not re-entrant: use the session already held"
                    )
                )
        else do
            outcome <-
                tryProtectedIO
                    ( withStoreLockUsing (storeLockOpener store)
                        (storeRoot store)
                        (storeMutex store)
                        (storeHolder store)
                        (withCurrentProtectedSession store action)
                    )
            pure (either (Left . classifyProtectedException "enter the protected store") id outcome)

{- | Attempt the exclusive entry without blocking. 'Nothing' means another
process (or another thread of this one) holds it right now; the caller decides
whether that is contention to wait on or a live peer to report.

The holding thread's own re-entry is a 'ProtectedInvalid' refusal rather than
contention, because it must keep using the session it already holds.
-}
tryProtectedEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either ProtectedError result)) ->
    IO (Either ProtectedError (Maybe result))
tryProtectedEntry store action = do
    self <- myThreadId
    holder <- readIORef (storeHolder store)
    if holder == Just self
        then
            pure
                ( Left
                    ( ProtectedInvalid
                        "the protected store entry is not re-entrant: use the session already held"
                    )
                )
        else do
            outcome <-
                tryProtectedIO
                    ( tryStoreLock (storeLockOpener store)
                        (storeRoot store)
                        (storeMutex store)
                        (storeHolder store)
                        (withCurrentProtectedSession store action)
                    )
            pure $ case outcome of
                Left failure -> Left (classifyProtectedException "enter the protected store" failure)
                Right Nothing -> Right Nothing
                Right (Just inner) -> fmap Just inner

tryStoreLock ::
    (FilePath -> IO IO.Handle) ->
    FilePath ->
    MVar () ->
    IORef (Maybe ThreadId) ->
    IO result ->
    IO (Maybe result)
tryStoreLock openHandle root mutex holder action = Safe.mask $ \restore ->
    bracket (tryTakeMVar mutex) restoreMutex $ \acquired ->
        case acquired of
            Nothing -> pure Nothing
            Just () -> bracket open closeIfHeld (run restore)
  where
    restoreMutex Nothing = pure ()
    restoreMutex (Just ()) = putMVar mutex ()
    open = do
        handle <- openHandle (root </> lockFileName)
        taken <-
            (hSetBuffering handle NoBuffering >> hTryLock handle ExclusiveLock)
                `onException` hClose handle
        pure (handle, taken)
    closeIfHeld (handle, _) = do
        writeIORef holder Nothing
        hClose handle
    run _ (_, False) = pure Nothing
    run restore (_, True) = do
        self <- myThreadId
        writeIORef holder (Just self)
        Just <$> restore action

{- | Hold a named liveness lock for the whole of @body@, or report that another
process holds it.

This is the § EE clause-1 primitive applied to a /run/ rather than to a single
transaction. The store's own entry is taken and released per transaction, so it
cannot answer "is the run that owns this project still alive?" — and without
that answer an abandoned-run sweep cannot tell a dead predecessor from a live
peer. This lock is held from before the sweep until the run ends, and the kernel
releases it if the process dies, so the question has a truthful answer at every
instant.

@Nothing@ means another process holds it right now. That is deliberately not an
error here: the caller decides whether a live peer is contention or a refusal.
The name is validated as a 'RecordKey' before any directory or file is opened.
Acquisition is masked, and the caller's body runs with its original masking state.
-}
withRunLiveness ::
    ProtectedStore ->
    -- | the lock's stable name, e.g. the installed project name
    Text ->
    IO result ->
    IO (Either ProtectedError (Maybe result))
withRunLiveness store name body = case mkRecordKey name of
    Left refusal -> pure (Left refusal)
    Right key -> mask $ \restore -> do
        -- The process lock closes the gap in POSIX record locks between two
        -- independently opened handles in this process.
        prepared <- tryProtectedIO (claim key)
        case prepared of
            Left failure -> pure (Left (classifyProtectedException "take the run liveness lock" failure))
            Right Nothing -> pure (Right Nothing)
            Right (Just (mutex, handle, False)) -> do
                hClose handle `finally` putMVar mutex ()
                pure (Right Nothing)
            Right (Just (mutex, handle, True)) ->
                (Right . Just <$> restore body) `finally` (hClose handle `finally` putMVar mutex ())
  where
    claim key = do
        let directory = protectedStoreRoot store </> livenessDirectoryName
            file = Text.unpack (recordKeyText key) <.> "lock"
        createDirectoryIfMissing True directory
        directoryKey <- directoryLockKey directory
        (mutex, _) <- storeProcessLock ("liveness:" <> directoryKey <> ":" <> file)
        token <- tryTakeMVar mutex
        case token of
            Nothing -> pure Nothing
            Just () -> do
                (handle, taken) <- acquire directory file `onException` putMVar mutex ()
                pure (Just (mutex, handle, taken))
    acquire directory file = do
        handle <- openLockHandle (directory </> file)
        (do
            hSetBuffering handle NoBuffering
            taken <- hTryLock handle ExclusiveLock
            pure (handle, taken)
            ) `onException` hClose handle

livenessDirectoryName :: FilePath
livenessDirectoryName = "liveness"

{- | Hold the exclusive entry: the process-wide mutex (POSIX record locks are
per-process), the kernel lock, and the holder marker that turns an accidental
re-entry into an explicit refusal rather than a deadlock.
-}
withStoreLock :: FilePath -> MVar () -> IORef (Maybe ThreadId) -> IO result -> IO result
withStoreLock = withStoreLockUsing openLockHandle

storeLockOpener :: ProtectedStore -> FilePath -> IO IO.Handle
storeLockOpener store path = case storeLockIdentity store of
    Nothing -> openLockHandle path
    Just expected -> do
        (handle, actual) <- openExistingLockHandle path
        if actual == expected
            then pure handle
            else hClose handle >> ioError (userError "the existing protected store lock was replaced")

withStoreLockUsing :: (FilePath -> IO IO.Handle) -> FilePath -> MVar () -> IORef (Maybe ThreadId) -> IO result -> IO result
withStoreLockUsing openHandle root mutex holder action =
    withMVar mutex $ \() ->
        bracket acquire release (const action)
  where
    acquire = do
        handle <- openHandle (root </> lockFileName)
        (hSetBuffering handle NoBuffering >> hLock handle ExclusiveLock)
            `onException` hClose handle
        self <- myThreadId
        writeIORef holder (Just self)
        pure handle
    release handle = do
        writeIORef holder Nothing
        hClose handle

{- | Open a kernel-lock handle that cannot escape into a launched child.

POSIX file descriptors are inherited across @exec@ unless @FD_CLOEXEC@ is set.
A long-lived provider daemon that inherited the run-liveness descriptor would
therefore keep the lock alive after the owning Harness process exited, making
the exact abandoned-run recovery guarded by that lock permanently unreachable.
Windows @openFile@ handles are non-inheritable; its row is deliberately a total
no-op rather than a missing platform definition.
-}
openLockHandle :: FilePath -> IO IO.Handle
#if defined(mingw32_HOST_OS)
openLockHandle path = openFile path ReadWriteMode
#else
-- The open itself carries O_CLOEXEC. Setting it afterwards leaves a window in
-- which a child forked by another thread inherits the descriptor and keeps the
-- kernel lock alive after its owner releases it.
openLockHandle path = do
    descriptor <- openFd path ReadWrite defaultFileFlags{cloexec = True, creat = Just 0o666}
    fdToHandle descriptor `onException` closeFd descriptor
#endif

-- Open the same lock for read/write without the create flag. An exclusive
-- Linux OFD lock requires a writable descriptor even for a read-only probe.
openExistingLockHandle :: FilePath -> IO (IO.Handle, (Word64, ByteString))
#if defined(mingw32_HOST_OS)
openExistingLockHandle path = do
    native <- openExistingWindowsLock path
    (do
        identity <- existingWindowsLockIdentity native
        handle <- hANDLEToHandle native
        pure (handle, identity)) `onException` closeHandle native

openExistingWindowsLock :: FilePath -> IO HANDLE
openExistingWindowsLock path = do
    nativePath <- windowsPublishedPath path
    createFile nativePath (gENERIC_READ .|. gENERIC_WRITE) (fILE_SHARE_READ .|. fILE_SHARE_WRITE)
        Nothing oPEN_EXISTING fILE_ATTRIBUTE_NORMAL Nothing

existingLockIdentityAtPath :: FilePath -> IO (Word64, ByteString)
existingLockIdentityAtPath path = bracket (openExistingWindowsLock path) closeHandle existingWindowsLockIdentity

existingWindowsLockIdentity :: HANDLE -> IO (Word64, ByteString)
existingWindowsLockIdentity native = allocaArray 261 $ \filesystemBuffer -> do
    available <- existingLockVolumeInfo native nullPtr 0 nullPtr nullPtr nullPtr filesystemBuffer 261
    if not available
        then ioError (userError "the existing lock filesystem could not be identified")
        else do
            filesystem <- peekTString filesystemBuffer
            if filesystem /= "NTFS" && filesystem /= "ReFS"
                then ioError (userError "the existing lock filesystem has no admitted stable identity")
                else allocaBytes 24 $ \buffer -> do
                    described <- existingLockFileInfo native 0x12 buffer 24
                    if not described
                        then ioError (userError "the existing lock identity could not be read")
                        else do
                            volume <- peekByteOff buffer 0
                            object <- ByteString.packCStringLen (castPtr (plusPtr buffer 8), 16)
                            pure (volume, object)

foreign import capi unsafe "windows.h GetVolumeInformationByHandleW"
    existingLockVolumeInfo :: HANDLE -> LPCTSTR -> Word32 -> Ptr () -> Ptr () -> Ptr () -> LPCTSTR -> Word32 -> IO Bool

foreign import capi unsafe "windows.h GetFileInformationByHandleEx"
    existingLockFileInfo :: HANDLE -> Word32 -> Ptr () -> Word32 -> IO Bool
#else
openExistingLockHandle path = do
    descriptor <- openFd path ReadWrite defaultFileFlags{cloexec = True}
    (do
        status <- getFdStatus descriptor
        handle <- fdToHandle descriptor
        pure (handle, (fromIntegral (deviceID status), ByteStringChar8.pack (show (fileID status))))) `onException` closeFd descriptor

-- A path stat avoids opening and closing a second descriptor while a
-- process-scoped POSIX record lock is held.
existingLockIdentityAtPath :: FilePath -> IO (Word64, ByteString)
existingLockIdentityAtPath path = do
    status <- getFileStatus path
    pure (fromIntegral (deviceID status), ByteStringChar8.pack (show (fileID status)))
#endif

-- Records -------------------------------------------------------------------------

{- | A validated record name. Keys are restricted to characters that are safe as
a single path segment on every supported host, so a key can never traverse out
of the store or alias another key through ASCII case folding or trailing dots.
-}
newtype RecordKey = RecordKey Text
    deriving (Eq, Ord)

instance Show RecordKey where
    show (RecordKey value) = "RecordKey " <> show value

recordKeyText :: RecordKey -> Text
recordKeyText (RecordKey value) = value

{- | Validate a record key.

The ASCII lowercase alphabet makes the length cap a byte cap, independent of
locale. Reserved Windows device prefixes and trailing dots are refused. The
cap is derived from the filesystem, which is what a key ultimately names: a record is written as @\<key\>.rec@ and published from
@\<key\>.rec.tmp-\<16 hex\>@, so the on-disk component is the key plus 25 bytes,
against the 255-byte component limit APFS and ext4 both impose. 200 leaves
headroom for that suffix and for the longest key the lifecycle actually forms —
an operation key carries the plan digest (@\<specDigest\>:\<planBytesDigest\>@,
81 characters encoded), a session identifier, and the operation's own name.
-}
mkRecordKey :: Text -> Either ProtectedError RecordKey
mkRecordKey raw
    | Text.null raw = Left (ProtectedInvalid "a record key must not be empty")
    | Text.length raw > 200 =
        Left
            ( ProtectedInvalid
                ( "a record key must be at most 200 ASCII bytes (observed "
                    <> Text.pack (show (Text.length raw))
                    <> ", namespace "
                    <> Text.takeWhile (/= '.') raw
                    <> ")"
                )
            )
    | not (Text.all legal raw) =
        Left
            ( ProtectedInvalid
                ("a record key may contain only ASCII lowercase letters, digits, '-', '_', and '.': " <> raw)
            )
    | Text.isPrefixOf "." raw = Left (ProtectedInvalid "a record key must not start with '.'")
    | Text.isSuffixOf "." raw = Left (ProtectedInvalid "a record key must not end with '.'")
    | Text.takeWhile (/= '.') raw `elem` reservedDevices =
        Left (ProtectedInvalid "a record key must not name a reserved Windows device")
    | otherwise = Right (RecordKey raw)
  where
    legal character =
        isAsciiLower character || ('0' <= character && character <= '9') || character `elem` ("-_." :: String)
    reservedDevices =
        ["con", "prn", "aux", "nul"]
            <> [prefix <> Text.pack (show number) | prefix <- ["com", "lpt"], number <- [(1 :: Int) .. 9]]

{- | Encode one **namespaced identity**, or a path of them, as a record-name
component.

The store's key alphabet is alphanumerics, @-@, @_@, and @.@ — deliberately
narrow, because a key is a filesystem name. Several identities above this module
are namespaced with a colon: a plan operation key (@core:deploy-kind@,
@project:build-image@) and a plan digest (@\<specDigest\>:\<planBytesDigest\>@).
Neither could name a record at all, so the identities the lifecycle actually
wants to key by were unreachable and a caller had to invent a lossy sanitizer.

A plan operation may also be a __relation__ between operations, whose identity is
a @\/@-separated path of them
(@core:deploy-vm\/core:copy-source\/guest-alias@, § CC). A @\/@ can never reach a
filesystem name, so the path is encoded here too rather than sanitized away.

This is the one encoding, and it is **injective**:

* a plain segment (no colon) may contain no @.@, and therefore collides with no
  encoded one;
* an encoded segment's namespace may contain no @.@, so the first @.@ is always
  the separator and @ns.token@ determines @(ns, token)@ uniquely;
* a namespaced token may neither begin nor end with @.@, and no raw segment may
  contain @..@, so an encoded segment holds no adjacent dots and does not end in
  a dot; @..@ therefore unambiguously separates path segments;
* ASCII uppercase @C@ becomes @_c@ and a literal @_@ becomes @__@ in every
  component, so case folding cannot merge distinct ASCII identities and the
  escapes themselves remain unambiguous.

At most one colon per segment is admitted; a second would make the namespace
separator ambiguous. Two distinct identities can therefore never share one
durable record — which a character-replacing sanitizer does not guarantee.
-}
mkRecordName :: Text -> Either ProtectedError Text
mkRecordName raw
    | Text.null raw = refuse raw "must not be empty"
    | otherwise =
        Text.intercalate ".." <$> traverse (recordNameSegment raw) (Text.splitOn "/" raw)

{- | Encode one identity segment with the same codec as 'mkRecordName'. A
runtime name offered as one component cannot introduce another path segment.
-}
mkRecordSegment :: Text -> Either ProtectedError Text
mkRecordSegment raw
    | Text.any (== '/') raw = refuse raw "a single record segment may not contain '/'"
    | otherwise = recordNameSegment raw raw

recordNameSegment :: Text -> Text -> Either ProtectedError Text
recordNameSegment raw segment
    | Text.null segment = refuse raw "must not contain an empty path segment"
    | not (Text.all admitted segment) =
        refuse raw "may contain only ASCII alphanumerics, '-', '_', '.', '/', and one ':' per segment"
    | Text.isInfixOf ".." segment =
        refuse raw "a path segment may not contain '..'"
    | otherwise = case Text.splitOn ":" segment of
        [plain]
            | Text.any (== '.') plain ->
                refuse raw "a segment with no namespace may not contain '.'"
            | otherwise -> Right (encodeRecordCase plain)
        [namespace, token]
            | Text.null namespace -> refuse raw "a namespaced segment needs a namespace"
            | Text.null token -> refuse raw "a namespaced segment needs a token"
            | Text.any (== '.') namespace ->
                refuse raw "a segment's namespace may not contain '.'"
            | Text.isPrefixOf "." token || Text.isSuffixOf "." token ->
                refuse raw "a namespaced token may neither begin nor end with '.'"
            | otherwise -> Right (encodeRecordCase namespace <> "." <> encodeRecordCase token)
        _ -> refuse raw "a segment has at most one namespace"
  where
    admitted character = legal character || character == ':'
    legal character =
        isAsciiLower character || isAsciiUpper character || ('0' <= character && character <= '9') || character `elem` ("-_." :: String)

encodeRecordCase :: Text -> Text
encodeRecordCase = Text.concatMap escape
  where
    escape '_' = "__"
    escape character
        | isAsciiUpper character = Text.pack ['_', toLower character]
        | otherwise = Text.singleton character

decodeRecordCase :: Text -> Text
decodeRecordCase = Text.pack . decode . Text.unpack
  where
    decode ('_' : '_' : rest) = '_' : decode rest
    decode ('_' : character : rest)
        | isAsciiLower character = toUpper character : decode rest
    decode (character : rest) = character : decode rest
    decode [] = []

refuse :: Text -> Text -> Either ProtectedError result
refuse raw reason = Left (ProtectedInvalid ("record name " <> raw <> " " <> reason))

{- | The identity a record-name component denotes. Total inverse of
'mkRecordName' on its image: @..@ separates path segments, the first @.@ of a
segment is the namespace separator, and a segment with no @.@ was never
namespaced. @__@ denotes a literal underscore and @_c@ denotes ASCII uppercase
@C@; their decoding does not alter the namespace or path separators.
-}
recordNameIdentity :: Text -> Text
recordNameIdentity name =
    decodeRecordCase (Text.intercalate "/" (map segmentIdentity (Text.splitOn ".." name)))
  where
    segmentIdentity segment = case Text.breakOn "." segment of
        (_, rest) | Text.null rest -> segment
        (namespace, rest) -> namespace <> ":" <> Text.drop 1 rest

{- | Separate complete encoded identities in a tuple. This delimiter is absent
from the image of 'mkRecordName': a component has no adjacent or edge dots, and
path separators contain exactly two dots between non-dot component edges.
Callers therefore split the tuple here before decoding each identity.
-}
recordTupleSeparator :: Text
recordTupleSeparator = "..."

{- | A record's monotonic version. Version 1 is the first published value; a
record that has never existed has no version at all, which is why 'Expectation'
distinguishes absence from a version rather than using zero.
-}
newtype RecordVersion = RecordVersion Word64
    deriving (Eq, Ord)

instance Show RecordVersion where
    show (RecordVersion value) = "RecordVersion " <> show value

recordVersionWord :: RecordVersion -> Word64
recordVersionWord (RecordVersion value) = value

data ProtectedRecord = ProtectedRecord
    { protectedRecordVersion :: RecordVersion
    , protectedRecordBytes :: ByteString
    }
    deriving (Eq, Show)

-- | What the caller observed, and therefore what the write must still find.
data Expectation
    = ExpectAbsent
    | ExpectVersion RecordVersion
    deriving (Eq, Show)

recordPath :: ProtectedStore -> RecordKey -> FilePath
recordPath store (RecordKey key) =
    storeRoot store </> recordsDirectory </> Text.unpack key <.> "rec"

-- | Read a record, or observe its absence. Total: a decode failure is an error.
readProtectedRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either ProtectedError (Maybe ProtectedRecord))
readProtectedRecord session key = withActiveProtectedSession session $ \store -> do
    outcome <- try (ByteString.readFile (recordPath store key))
    case outcome of
        Left failure
            | isDoesNotExistError failure -> pure (Right Nothing)
            | otherwise -> pure (Left (ioFailure "read a protected record" failure))
        Right raw -> pure (fmap Just (decodeRecord (recordKeyText key) raw))

-- | Every record key currently present, sorted. Used by the recovery sweeps.
listProtectedRecords ::
    ProtectedSession session ->
    IO (Either ProtectedError [RecordKey])
listProtectedRecords session = withActiveProtectedSession session $ \store -> do
    outcome <- try (listDirectory (storeRoot store </> recordsDirectory))
    case outcome of
        Left failure
            | isDoesNotExistError failure -> pure (Right [])
            | otherwise -> pure (Left (ioFailure "list protected records" failure))
        Right entries ->
            pure
                ( traverse
                    (mkRecordKey . Text.pack)
                    (sort [dropSuffix ".rec" entry | entry <- entries, ".rec" `isSuffixOf` entry])
                )

dropSuffix :: String -> String -> String
dropSuffix suffix value = take (length value - length suffix) value

{- | Publish @bytes@ only if the record still matches @expectation@, returning
the sole successor version. A mismatch is 'ProtectedVersionMismatch' and nothing
is written, so exactly one of two racing cooperating writers wins.
-}
compareAndSwapProtectedRecord ::
    ProtectedSession session ->
    RecordKey ->
    Expectation ->
    ByteString ->
    IO (Either ProtectedError RecordVersion)
compareAndSwapProtectedRecord session key expectation bytes = withActiveProtectedSession session $ \store -> do
    observed <- readProtectedRecord session key
    case observed of
        Left failure -> pure (Left failure)
        Right current -> case reconcileExpectation key expectation current of
            Left failure -> pure (Left failure)
            Right () -> case successorVersion current of
                Nothing -> pure (Left (ProtectedInvalid "protected record version is exhausted"))
                Just nextVersion -> do
                    let next = RecordVersion nextVersion
                    outcome <-
                        try
                            ( publishBytes
                                (recordPath store key)
                                (encodeRecord next bytes)
                            )
                    pure
                        ( either
                            (Left . mutationFailure "publish a protected record")
                            (const (Right next))
                            outcome
                        )

-- | Delete a record only if it still matches @expectation@ (clause 4's shape).
compareAndDeleteProtectedRecord ::
    ProtectedSession session ->
    RecordKey ->
    Expectation ->
    IO (Either ProtectedError ())
compareAndDeleteProtectedRecord session key expectation = withActiveProtectedSession session $ \store -> do
    observed <- readProtectedRecord session key
    case observed of
        Left failure -> pure (Left failure)
        Right current -> case reconcileExpectation key expectation current of
            Left failure -> pure (Left failure)
            Right () -> case current of
                Nothing -> pure (Right ())
                Just _ -> do
                    outcome <- try (removeFile (recordPath store key))
                    pure
                        ( either
                            (Left . mutationFailure "delete a protected record")
                            Right
                            outcome
                        )

reconcileExpectation ::
    RecordKey ->
    Expectation ->
    Maybe ProtectedRecord ->
    Either ProtectedError ()
reconcileExpectation key expectation current =
    case (expectation, current) of
        (ExpectAbsent, Nothing) -> Right ()
        (ExpectAbsent, Just record) ->
            Left
                ( ProtectedVersionMismatch
                    (recordKeyText key)
                    Nothing
                    (Just (protectedRecordVersion record))
                )
        (ExpectVersion expected, Just record)
            | protectedRecordVersion record == expected -> Right ()
            | otherwise ->
                Left
                    ( ProtectedVersionMismatch
                        (recordKeyText key)
                        (Just expected)
                        (Just (protectedRecordVersion record))
                    )
        (ExpectVersion expected, Nothing) ->
            Left (ProtectedVersionMismatch (recordKeyText key) (Just expected) Nothing)

successorVersion :: Maybe ProtectedRecord -> Maybe Word64
successorVersion Nothing = Just 1
successorVersion (Just record)
    | version == maxBound = Nothing
    | otherwise = Just (version + 1)
  where
    version = recordVersionWord (protectedRecordVersion record)

-- The on-disk record shape --------------------------------------------------------

recordMagic :: ByteString
recordMagic = "hbps1"

encodeRecord :: RecordVersion -> ByteString -> ByteString
encodeRecord (RecordVersion version) bytes =
    ByteString.concat
        [ recordMagic
        , " "
        , ByteStringChar8.pack (show version)
        , "\n"
        , bytes
        ]

decodeRecord :: Text -> ByteString -> Either ProtectedError ProtectedRecord
decodeRecord key raw =
    case ByteStringChar8.break (== '\n') raw of
        (header, rest)
            | ByteString.null rest -> malformed "the record has no header terminator"
            | otherwise -> case ByteStringChar8.words header of
                [magic, version]
                    | magic /= recordMagic -> malformed "unknown record magic"
                    | otherwise -> case ByteStringChar8.readInteger version of
                        Just (parsed, remainder)
                            | ByteString.null remainder && parsed > 0 && parsed <= toInteger (maxBound :: Word64) ->
                                Right
                                    ( ProtectedRecord
                                        (RecordVersion (fromIntegral parsed))
                                        (ByteString.drop 1 rest)
                                    )
                        _ -> malformed "the record version is not a positive integer"
                _ -> malformed "the record header is not <magic> <version>"
  where
    malformed reason = Left (ProtectedMalformedRecord key reason)

{- | Write and sync an invocation-indexed temporary in the destination's own
directory, atomically rename it with write-through replacement on Windows, and
sync the POSIX parent directory. The
temporary is removed on any failure during writing, closing, syncing, or
publication; a reader sees either the old record or the complete new one.
-}
publishBytes :: FilePath -> ByteString -> IO ()
publishBytes destination bytes = do
    stamp <- getMonotonicTimeNSec
    let temporary = destination <.> ("tmp-" <> showHex64 stamp)
    ( do
        withFile temporary IO.WriteMode $ \handle -> do
            ByteString.hPut handle bytes
            hFlush handle
        syncPublishedFile temporary
        renamePublishedFile temporary destination
        syncPublishedParent destination
        )
        `onException` Safe.catchIO (removeFile temporary) (const (pure ()))

-- Failures --------------------------------------------------------------------------

data ProtectedError
    = -- | The store or a key was rejected before any IO.
      ProtectedInvalid Text
    | -- | The observed version was not the expected one; nothing was written.
      ProtectedVersionMismatch Text (Maybe RecordVersion) (Maybe RecordVersion)
    | -- | A record exists but could not be decoded. Never silently ignored.
      ProtectedMalformedRecord Text Text
    | -- | The host cannot supply the required lock or accessible durable store.
      ProtectedUnsupported Text Text
    | -- | The underlying filesystem operation failed.
      ProtectedIOFailure Text Text
    deriving (Eq, Show)

protectedErrorMessage :: ProtectedError -> Text
protectedErrorMessage failure = case failure of
    ProtectedInvalid reason -> reason
    ProtectedVersionMismatch key expected observed ->
        "protected record "
            <> key
            <> " changed under us (expected "
            <> renderVersion expected
            <> ", observed "
            <> renderVersion observed
            <> ")"
    ProtectedMalformedRecord key reason ->
        "protected record " <> key <> " is malformed: " <> reason
    ProtectedUnsupported operation reason ->
        "cannot " <> operation <> ": " <> reason
    ProtectedIOFailure operation reason ->
        "could not " <> operation <> ": " <> reason
  where
    renderVersion Nothing = "absent"
    renderVersion (Just version) = Text.pack (show (recordVersionWord version))

{- | Classify a supported store failure without collapsing an unavailable clause
into an ordinary probe failure. This function is pure; catching is restricted
separately to IO errors and the lock implementation's unsupported exception.
-}
classifyProtectedException :: Text -> SomeException -> ProtectedError
classifyProtectedException operation failure =
    case fromException failure :: Maybe FileLockingNotSupported of
        Just _ -> unsupported
        Nothing -> case fromException failure :: Maybe IOError of
            Just ioFailureValue
                | isPermissionError ioFailureValue || ioeGetErrorType ioFailureValue == UnsupportedOperation -> unsupported
            _ -> ProtectedIOFailure operation reason
  where
    reason = Text.pack (displayException failure)
    unsupported = ProtectedUnsupported operation reason

-- | Catch only the two synchronous failure families the store classifies.
-- Unrelated exceptions and asynchronous cancellation retain their propagation.
tryProtectedIO :: IO result -> IO (Either SomeException result)
tryProtectedIO action =
    catches
        (Right <$> action)
        [ Handler (\failure -> pure (Left (toException (failure :: IOException))))
        , Handler (\failure -> pure (Left (toException (failure :: FileLockingNotSupported))))
        ]

-- | Ordinary read/list failures remain probes. In particular, Windows can
-- report a non-file record path as permission denied rather than a type error.
ioFailure :: Text -> IOError -> ProtectedError
ioFailure operation failure =
    ProtectedIOFailure operation (Text.pack (show failure))

-- | Permission denial makes a required store mutation unavailable.
mutationFailure :: Text -> IOError -> ProtectedError
mutationFailure operation = classifyProtectedException operation . toException
