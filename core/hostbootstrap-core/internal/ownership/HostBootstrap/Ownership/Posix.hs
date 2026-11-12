{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}
#if defined(mingw32_HOST_OS)
{-# LANGUAGE EmptyCase #-}
#endif
{-# LANGUAGE OverloadedStrings #-}

{- | The primitives a POSIX kernel supplies to the ownership seam, once.

@development_plan_standards.md § LL@ makes a platform a __row__ of one frame
table rather than a module of parallel logic. The four clauses
(@development_plan_standards.md § EE@) are written once, in
"HostBootstrap.Ownership.Primitive"; what a POSIX kernel contributes is the set
of primitives beneath them, and this module is that set and nothing else. There
is no workflow here, no pathname policy, and no command runner — a caller that
wants an effect between the origin record and the identity binding describes it
as a @HostCommand@ (§ KK).

Each primitive is one syscall family reached through the @unix@ binding rather
than through a front-end process:

  * identity is @lstat@'s @(st_dev, st_ino)@ pair, encoded through the
    vocabulary's one kernel-identity producer — the encoding the Windows row
    writes too — so a driver comparing two identities means the same thing
    whichever row read them;
  * the exclusive open is @open(2)@ with @O_NOFOLLOW@ and @O_CLOEXEC@ followed
    by an @fcntl@ write lock over the whole file, so the exclusion is one the
    kernel releases when the holding process dies rather than a pathname a
    survivor has to clean up. This classic lock belongs to the (process, inode)
    pair, and closing any descriptor for that inode releases it, so callers
    never hold two handles to one inode in a process;
  * a directory is created with @mkdir(2)@ and a file with @O_CREAT|O_EXCL@ plus
    @fsync@, so neither adopts an object that is already there;
  * publication is @link(2)@, which refuses rather than replaces, followed by
    unlinking the staging name;
  * the parent's own change is made durable by @fsync@ on a descriptor for the
    parent directory.

Two refusals are deliberate rather than incidental. A symbolic link or any
non-regular object at a target is refused instead of followed, because clause 3
binds what the kernel knows about an object and a link is a different object.
And errno is compared against the platform's own symbolic constants rather than
a hard-coded number, so the same name means the same thing on a Linux and on an
Apple host.

The module is compiled on every gate host and answers a total 'OwnershipUnsupported'
where it cannot apply, so no package-description stanza excludes it from a build
and the cases that cover it assert that refusal instead of disappearing (§ JJ).
-}
module HostBootstrap.Ownership.Posix (
    posixOwnershipRow,
    posixOwnershipCapabilities,
    posixOwnershipSupported,
    posixObserveOwnershipManifest,
    posixObserveOwnershipManifestAt,
    posixReleaseManifestEntry,
)
where

import System.Posix.Types (Fd (..))
import HostBootstrap.Ownership.Object (ObjectIdentity, OwnershipFault (OwnershipUnsupported))
import HostBootstrap.Ownership.Primitive (
    OwnershipCapabilities (..),
    OwnershipPrimitive (..),
    OwnershipRow,
    ownershipRow,
    withOwnershipRow,
 )

#if !defined(mingw32_HOST_OS)
import Control.Exception (bracket, mask, onException)
import Control.Monad (void)
import HostBootstrap.Ownership.Manifest
    ( OwnershipManifest
    , OwnershipManifestEntry
    , ManifestEntryKind (..)
    , manifestEntryPath
    , manifestEntryIdentity
    , manifestEntryMode
    , manifestEntryKind
    , directoryManifestEntry
    , immutableManifestEntry
    , mkOwnershipManifest
    , mutableManifestEntry
    , socketManifestEntry
    , symbolicLinkManifestEntry
    )
import HostBootstrap.Ownership.Object
    ( OwnershipFault (OwnershipOccupied, OwnershipProbeFailed)
    , mkKernelObjectIdentity
    , mkPayload
    , payloadDigest
    )
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Data.List (sortOn)
import Data.Char (chr)
import Numeric (showHex)
import Foreign.C.Error
    ( Errno (Errno)
    , eACCES
    , eAGAIN
    , eBUSY
    , eEXIST
    , eISDIR
    , eLOOP
    , eMLINK
    , eNOTDIR
    , eNOTSUP
    , ePERM
    , eXDEV
    , throwErrnoIfMinus1Retry
    , throwErrnoIfMinus1Retry_
    )
import Foreign.C.String (CString)
import Foreign.C.Types (CChar, CInt (..), CSize (..))
import Foreign.ForeignPtr (mallocForeignPtrBytes, withForeignPtr)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import GHC.IO.Exception (IOException (ioe_errno))
import System.FilePath (dropTrailingPathSeparator, isAbsolute, isPathSeparator, splitDirectories, takeDirectory, takeFileName, (</>))
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Error (isDoesNotExistError, tryIOError)
import System.Posix.Directory (closeDirStream)
import qualified System.Posix.Directory.ByteString as RawDirectory
import qualified System.Posix.IO.ByteString as RawIO
import System.Posix.Directory.Fd (unsafeOpenDirStreamFd)
import System.Posix.Files
    ( FileStatus (..)
    , deviceID
    , fileMode
    , fileID
    , fileOwner
    , fileSize
    , getFdStatus
    , isDirectory
    , isRegularFile
    , isSocket
    , isSymbolicLink
    , linkCount
    , groupWriteMode
    , otherWriteMode
    , intersectFileModes
    , unionFileModes
    )
import System.Posix.IO
    ( LockRequest (Unlock, WriteLock)
    , OpenFileFlags (cloexec, creat, directory, exclusive, nofollow, nonBlock)
    , OpenMode (ReadOnly, ReadWrite)
    , closeFd
    , defaultFileFlags
    , fdReadBuf
    , fdWriteBuf
    , openFd
    , openFdAt
    , setLock
    )
import System.Posix.Types (CMode (..), CSsize (..), UserID)
import System.Posix.Internals (CStat, sizeof_stat, withFilePath)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
#else
import qualified Data.Text as Text
import HostBootstrap.Ownership.Manifest (OwnershipManifest, OwnershipManifestEntry)
#endif

{- | What this row declares it can hold, read off the row itself.

Derived rather than restated, so a case asking what this gate host supports is
asking the subject rather than repeating a build symbol beside it (§ JJ).
-}
posixOwnershipCapabilities :: OwnershipCapabilities
posixOwnershipCapabilities = withOwnershipRow posixOwnershipRow rowCapabilities

{- | Whether this gate host's kernel can hold the row's obligations at all.

One derived answer, so the suite's conditional expectations and the coverage
manifest read the same fact the row itself declares.
-}
posixOwnershipSupported :: Bool
posixOwnershipSupported = holdsStableIdentity posixOwnershipCapabilities

#if !defined(mingw32_HOST_OS)

-- | Snapshot every descendant of an already-owned namespace without following
-- a directory or file link. Immutable mode hashes regular-file bytes; mutable
-- mode retains their identity/mode only. Directory descriptors, rather than
-- ambient path traversal, drive recursive opens and listings.
posixObserveOwnershipManifest :: Bool -> FilePath -> IO (Either OwnershipFault OwnershipManifest)
posixObserveOwnershipManifest mutable root = do
    attempted <-
        tryIOError
            ( withPathParent root $ \parent name -> bracket
                (openFdAt (Just parent) name ReadOnly defaultFileFlags{cloexec = True, nofollow = True, directory = True})
                closeFd
                (posixObserveOwnershipManifestAt mutable root)
            )
    pure $ case attempted of
        Left failure -> Left (posixFault "observe the ownership manifest below" root failure)
        Right outcome -> outcome

-- | Observe the namespace held by the descriptor. The path is diagnostic only;
-- neither metadata nor link-target lookup resolves it again during the walk.
posixObserveOwnershipManifestAt :: Bool -> FilePath -> Fd -> IO (Either OwnershipFault OwnershipManifest)
posixObserveOwnershipManifestAt mutable root rootFd = do
    effectiveUser <- getEffectiveUserID
    attempted <- tryIOError $ do
        rootStatus <- getFdStatus rootFd
        case validateDirectoryStatus effectiveUser root rootStatus of
            Left fault -> pure (Left fault)
            Right () -> do
                walked <- walk effectiveUser rootFd root ""
                pure (walked >>= mkOwnershipManifest)
    pure $ case attempted of
        Left failure -> Left (posixFault "observe the ownership manifest below" root failure)
        Right outcome -> outcome
  where
    walk effectiveUser parentFd absolute prefix = do
        names <- directoryNames parentFd
        observed <- mapM (observeEntry effectiveUser parentFd absolute prefix) names
        pure (concat <$> sequence observed)

    observeEntry effectiveUser parentFd absolute prefix name = do
        let target = absolute </> displayManifestName name
            relative = if ByteString.null prefix then name else prefix <> "/" <> name
        before <- manifestEntryStatusAt parentFd name
        identityResult <- pure (identityOfStatus before)
        case identityResult of
            Left fault -> pure (Left fault)
            Right identity
                | fileOwner before /= effectiveUser -> pure (Left (OwnershipOccupied (Text.pack target <> " has a foreign owner")))
                | isDirectory before ->
                    bracket
                        (RawIO.openFdAt (Just parentFd) name ReadOnly defaultFileFlags{cloexec = True, nofollow = True, directory = True})
                        closeFd
                        (\childFd -> do
                            opened <- getFdStatus childFd
                            case (validateDirectoryStatus effectiveUser target opened, identityOfStatus opened) of
                                (Left fault, _) -> pure (Left fault)
                                (_, Left fault) -> pure (Left fault)
                                (Right (), Right openedIdentity)
                                    | openedIdentity /= identity -> pure (Left (OwnershipOccupied (Text.pack target <> " changed during manifest observation")))
                                    | otherwise -> do
                                        descendants <- walk effectiveUser childFd target relative
                                        pure $ do
                                            directoryEntry <- directoryManifestEntry relative identity (permissionMode before)
                                            rest <- descendants
                                            Right (directoryEntry : rest)
                        )
                | isRegularFile before ->
                    bracket
                        (RawIO.openFdAt (Just parentFd) name ReadOnly defaultFileFlags{cloexec = True, nofollow = True, nonBlock = True})
                        closeFd
                        (\childFd -> do
                            opened <- getFdStatus childFd
                            case identityOfStatus opened of
                                Left fault -> pure (Left fault)
                                Right openedIdentity
                                    | openedIdentity /= identity || not (isRegularFile opened) || linkCount opened /= 1 || writableByOthers opened ->
                                        pure (Left (OwnershipOccupied (Text.pack target <> " is not an exact owned manifest file")))
                                    | mutable -> pure (fmap (: []) (mutableManifestEntry relative identity (permissionMode opened)))
                                    | fileSize opened > manifestPayloadCeiling -> pure (Left (OwnershipUnsupported (Text.pack target <> " exceeds the immutable manifest payload bound")))
                                    | otherwise -> do
                                        bytes <- readWholeFd childFd (fromIntegral (fileSize opened))
                                        pure (fmap (: []) (immutableManifestEntry relative identity (permissionMode opened) (payloadDigest (mkPayload bytes))))
                        )
                | isSymbolicLink before -> do
                    linkTarget <- manifestLinkTargetAt parentFd name
                    after <- manifestEntryStatusAt parentFd name
                    case identityOfStatus after of
                        Right afterIdentity | afterIdentity == identity ->
                            pure (fmap (: []) (symbolicLinkManifestEntry relative identity (permissionMode before) linkTarget))
                        _ -> pure (Left (OwnershipOccupied (Text.pack target <> " changed during link observation")))
                | isSocket before -> pure (fmap (: []) (socketManifestEntry relative identity (permissionMode before)))
                | otherwise -> pure (Left (OwnershipOccupied (Text.pack target <> " has an unsupported manifest object kind")))

    directoryNames fd =
        bracket
            (do
                -- dup shares the directory offset with its source. A fresh
                -- open of dot keeps repeated walks independent of that offset.
                streamFd <- openFdAt (Just fd) "." ReadOnly defaultFileFlags{cloexec = True, nofollow = True, directory = True}
                unsafeOpenDirStreamFd streamFd `onException` closeFd streamFd
            )
            closeDirStream
            (\stream -> collect stream [])
      where
        collect stream accumulated = do
            next <- RawDirectory.readDirStreamMaybe stream
            case next of
                Nothing -> pure (sortOn id accumulated)
                Just name
                    | name == "." || name == ".." -> collect stream accumulated
                    | otherwise -> collect stream (name : accumulated)

    permissionMode = fromIntegral . (`intersectFileModes` 0o7777) . fileMode

    manifestPayloadCeiling = 4 * 1024 * 1024


-- Only diagnostics decode a name; namespace operations and manifests keep bytes.
displayManifestName :: ByteString -> String
displayManifestName = concatMap byteLabel . ByteString.unpack
  where
    byteLabel byte
        | byte >= 32 && byte < 127 && byte /= 92 = [chr (fromIntegral byte)]
        | otherwise = let hex = showHex byte "" in "\\x" <> replicate (2 - length hex) '0' <> hex

validateDirectoryStatus :: UserID -> FilePath -> FileStatus -> Either OwnershipFault ()
validateDirectoryStatus effectiveUser target status
    | not (isDirectory status) = Left (OwnershipOccupied (Text.pack target <> " is not a directory"))
    | fileOwner status /= effectiveUser = Left (OwnershipOccupied (Text.pack target <> " has a foreign owner"))
    | writableByOthers status = Left (OwnershipOccupied (Text.pack target <> " is group/other writable"))
    | otherwise = Right ()

writableByOthers :: FileStatus -> Bool
writableByOthers status =
    intersectFileModes (fileMode status) (unionFileModes groupWriteMode otherWriteMode) /= 0

-- | Release one observed entry through its bound root and raw components.
-- The expected root identity comes from the caller's retained ownership binding.
posixReleaseManifestEntry :: FilePath -> ObjectIdentity -> OwnershipManifestEntry -> IO (Either OwnershipFault ())
posixReleaseManifestEntry root expectedRoot entry =
    case mutableManifestEntry path (manifestEntryIdentity entry) (manifestEntryMode entry) of
        Left fault -> pure (Left fault)
        Right _ -> do
            effectiveUser <- getEffectiveUserID
            attempted <- tryIOError $
                withPathParent root $ \parent name -> bracket
                    (openFdAt (Just parent) name ReadOnly defaultFileFlags{cloexec = True, nofollow = True, directory = True})
                    closeFd $ \rootFd -> do
                        status <- getFdStatus rootFd
                        case (validateDirectoryStatus effectiveUser root status, identityOfStatus status) of
                            (Left fault, _) -> pure (Left fault)
                            (_, Left fault) -> pure (Left fault)
                            (Right (), Right identity)
                                | identity /= expectedRoot -> pure (occupied " changed before manifest removal")
                                | otherwise -> descend effectiveUser rootFd (ByteString.split 47 path)
            pure $ either (Left . posixFault "remove the manifest entry below" root) id attempted
  where
    path = manifestEntryPath entry
    label = Text.pack (root </> displayManifestName path)
    occupied reason = Left (OwnershipOccupied (label <> reason))
    descend effectiveUser parentFd [name] = do
        present <- tryIOError (manifestEntryStatusAt parentFd name)
        case present of
            Left failure | isDoesNotExistError failure -> pure (Right ())
            Left failure -> pure (Left (posixFault "observe the manifest remainder below" root failure))
            Right status -> removePresent effectiveUser parentFd name status
    descend effectiveUser parentFd (name : rest) =
        bracket
            (tryIOError (RawIO.openFdAt (Just parentFd) name ReadOnly defaultFileFlags{cloexec = True, nofollow = True, directory = True}))
            (either (const (pure ())) closeFd) $ \opened ->
                case opened of
                    Left failure | isDoesNotExistError failure -> pure (Right ())
                    Left failure -> pure (Left (posixFault "open the manifest remainder parent below" root failure))
                    Right childFd -> do
                        status <- getFdStatus childFd
                        case validateDirectoryStatus effectiveUser (root </> displayManifestName name) status of
                            Left fault -> pure (Left fault)
                            Right () -> descend effectiveUser childFd rest
    descend _ _ [] = pure (occupied " has no relative component")
    removePresent effectiveUser parentFd name status =
        case identityOfStatus status of
            Left fault -> pure (Left fault)
            Right identity
                | identity /= manifestEntryIdentity entry || not (kindMatches status) ->
                    pure (occupied " changed before manifest removal")
                | fileOwner status /= effectiveUser -> pure (occupied " has a foreign owner")
                | (isDirectory status || isRegularFile status) && writableByOthers status ->
                    pure (occupied " is group/other writable")
                | otherwise -> do
                    let Fd descriptor = parentFd
                        flags = if isDirectory status then c_manifestRemoveDirectory else 0
                    ByteString.useAsCString name $ \nativeName ->
                        throwErrnoIfMinus1Retry_ "unlinkat ownership manifest entry" $
                            c_manifestUnlinkAt descriptor nativeName flags
                    fileSynchronise parentFd
                    after <- tryIOError (manifestEntryStatusAt parentFd name)
                    pure $ case after of
                        Left failure | isDoesNotExistError failure -> Right ()
                        Left failure -> Left (posixFault "read back the removed manifest entry below" root failure)
                        Right _ -> occupied " is present after manifest removal"
    kindMatches status = case manifestEntryKind entry of
        ManifestMutableFile -> isRegularFile status
        ManifestImmutableFile _ -> isRegularFile status
        ManifestDirectory -> isDirectory status
        ManifestSymbolicLink _ -> isSymbolicLink status
        ManifestSocket -> isSocket status

-- The unix FileStatus storage and the C header agree on this gate host's
-- struct stat layout. Both lookups name an entry relative to its held parent.
manifestEntryStatusAt :: Fd -> ByteString -> IO FileStatus
manifestEntryStatusAt (Fd descriptor) name = do
    storage <- mallocForeignPtrBytes sizeof_stat
    withForeignPtr storage $ \status ->
        ByteString.useAsCString name $ \path ->
            throwErrnoIfMinus1Retry_ "fstatat ownership manifest entry" $
                c_manifestFstatAt descriptor path status c_manifestNoFollow
    pure (FileStatus storage)

manifestLinkTargetAt :: Fd -> ByteString -> IO ByteString
manifestLinkTargetAt (Fd descriptor) name =
    -- One byte beyond the manifest bound prevents accepting a truncated target.
    allocaBytes 4097 $ \buffer ->
        ByteString.useAsCString name $ \path -> do
            count <- throwErrnoIfMinus1Retry "readlinkat ownership manifest entry" $
                c_manifestReadlinkAt descriptor path buffer 4097
            ByteString.packCStringLen (buffer, fromIntegral count)

foreign import capi unsafe "unistd.h unlinkat"
    c_manifestUnlinkAt :: CInt -> CString -> CInt -> IO CInt

foreign import capi unsafe "fcntl.h value AT_REMOVEDIR"
    c_manifestRemoveDirectory :: CInt

foreign import capi unsafe "sys/stat.h fstatat"
    c_manifestFstatAt :: CInt -> CString -> Ptr CStat -> CInt -> IO CInt

foreign import capi unsafe "fcntl.h value AT_SYMLINK_NOFOLLOW"
    c_manifestNoFollow :: CInt

foreign import capi unsafe "unistd.h readlinkat"
    c_manifestReadlinkAt :: CInt -> CString -> Ptr CChar -> CSize -> IO CSsize

-- | Encode one POSIX status through the shared kernel-identity contract.
identityOfStatus :: FileStatus -> Either OwnershipFault ObjectIdentity
identityOfStatus status =
    mkKernelObjectIdentity
        (fromIntegral (deviceID status))
        (LazyByteString.toStrict (Builder.toLazyByteString (Builder.word64LE (fromIntegral (fileID status)))))

-- ---------------------------------------------------------------------------
-- The row

{- | One object this row holds open, exclusively.

The descriptor is the representation, but the classic fcntl lock belongs to the
(process, inode) pair. Closing any descriptor for that inode releases the lock,
so a caller never holds two handles to one inode at once. Process death releases
it as well.
-}
newtype PosixOwnedHandle = PosixOwnedHandle Fd

{- | The POSIX row.

Every clause this kernel can hold is declared here, and the seam applies that
declaration before it reaches any field below.
-}
posixOwnershipRow :: OwnershipRow
posixOwnershipRow =
    ownershipRow
        OwnershipPrimitive
            { rowCapabilities =
                OwnershipCapabilities
                    { holdsStableIdentity = True
                    , holdsNoReplacePublication = True
                    , holdsDurableParentSync = True
                    }
            , rowObserveIdentity = posixObserveIdentity
            , rowOpenExclusive = posixOpenExclusive
            , rowCreateDirectory = posixCreateDirectory
            , rowCreateFile = posixCreateFile
            , rowLinkNoReplace = posixLinkNoReplace
            , rowReadObject = posixReadObject
            , rowRemoveObject = posixRemoveObject
            , rowCloseHandle = posixCloseHandle
            , rowSyncParent = posixSyncParent
            }

-- ---------------------------------------------------------------------------
-- The primitives

-- Hold the actual ancestor chain until the primitive finishes. Opening each
-- component relative to its already-held parent prevents an intermediate link
-- from selecting another namespace; dot/dot-dot retain their kernel meaning.
withPathParent :: FilePath -> (Fd -> FilePath -> IO value) -> IO value
withPathParent target action =
    bracket (openFd anchor ReadOnly parentFlags) closeFd $ \anchorFd ->
        descend anchorFd components
  where
    stripped = dropTrailingPathSeparator target
    parent = takeDirectory stripped
    anchor = if isAbsolute parent then "/" else "."
    name = if not (null stripped) && all isPathSeparator stripped then "." else takeFileName stripped
    components = filter (not . all isPathSeparator) (splitDirectories parent)
    parentFlags = defaultFileFlags{cloexec = True, nofollow = True, directory = True}
    descend parentFd [] = action parentFd name
    descend parentFd (component : rest) =
        bracket
            (openFdAt (Just parentFd) component ReadOnly parentFlags)
            closeFd
            (\childFd -> descend childFd rest)

withPathParentResult ::
    Text ->
    FilePath ->
    (Fd -> FilePath -> IO (Either OwnershipFault value)) ->
    IO (Either OwnershipFault value)
withPathParentResult operation target action = do
    attempted <- tryIOError (withPathParent target action)
    pure (either (Left . posixFault operation target) id attempted)

pathStatusAt :: Fd -> FilePath -> IO FileStatus
pathStatusAt (Fd descriptor) name = do
    storage <- mallocForeignPtrBytes sizeof_stat
    withForeignPtr storage $ \status ->
        withFilePath name $ \nativeName ->
            throwErrnoIfMinus1Retry_ "fstatat owned path" $
                c_manifestFstatAt descriptor nativeName status c_manifestNoFollow
    pure (FileStatus storage)

foreign import capi unsafe "unistd.h linkat"
    c_parentLinkAt :: CInt -> CString -> CInt -> CString -> CInt -> IO CInt

foreign import capi unsafe "sys/stat.h mkdirat"
    c_parentMkdirAt :: CInt -> CString -> CMode -> IO CInt

{- | @lstat@'s @(st_dev, st_ino)@, without following a link.

An authoritative absence is @Right Nothing@; every other failure is a fault, so
a probe that could not answer is never read as "nothing is there" (§ CC).
-}
posixObserveIdentity :: FilePath -> IO (Either OwnershipFault (Maybe ObjectIdentity))
posixObserveIdentity target = do
    observed <- tryIOError (withPathParent target pathStatusAt)
    case observed of
        Left failure
            | isDoesNotExistError failure -> pure (Right Nothing)
            | otherwise ->
                pure (Left (posixFault "observe the identity of" target failure))
        Right status -> pure (Just <$> identityOfStatus status)

{- | Open one already-existing named object exclusively.

Three refusals in order: a link is not followed, a non-regular object is not
opened as though it were a file, and an object another owner already holds is
occupied rather than shared. The lock is taken through @fcntl@, so the kernel
releases it when this process ends however it ends.
-}
posixOpenExclusive :: FilePath -> IO (Either OwnershipFault PosixOwnedHandle)
posixOpenExclusive target = withPathParentResult "open" target $ \parent name -> mask $ \restore -> do
    opened <-
        tryIOError
            (openFdAt (Just parent) name ReadWrite defaultFileFlags{nofollow = True, cloexec = True})
    case opened of
        Left failure -> pure (Left (posixFault "open" target failure))
        Right fd -> do
            described <- onException (tryIOError (restore (getFdStatus fd))) (closeFd fd)
            case described of
                Left failure ->
                    closingFd fd (posixFault "describe" target failure)
                Right status
                    | not (isRegularFile status) ->
                        closingFd
                            fd
                            ( OwnershipOccupied
                                (subjectOf target <> " is not a regular file")
                            )
                    | otherwise -> do
                        locked <- onException (tryIOError (restore (setLock fd (WriteLock, AbsoluteSeek, 0, 0)))) (closeFd fd)
                        case locked of
                            Left failure ->
                                closingFd fd (posixLockFault target failure)
                            Right () -> pure (Right (PosixOwnedHandle fd))

-- | @mkdir(2)@, which refuses an object that is already there.
posixCreateDirectory :: FilePath -> IO (Either OwnershipFault ())
posixCreateDirectory target =
    faultOr "create the directory" target <$> tryIOError
        (withPathParent target $ \(Fd parent) name ->
            withFilePath name $ \nativeName ->
                throwErrnoIfMinus1Retry_ "mkdirat owned directory" $
                    c_parentMkdirAt parent nativeName 0o700)

{- | Write one whole file at a name nothing else holds, and sync it.

@O_CREAT|O_EXCL|O_NOFOLLOW@, so a target that exists — including one that is a
link — is refused rather than truncated.
-}
posixCreateFile :: FilePath -> ByteString -> IO (Either OwnershipFault ())
posixCreateFile target bytes = withPathParentResult "create the file" target $ \parent name -> mask $ \restore -> do
    opened <-
        tryIOError
            ( openFdAt
                (Just parent)
                name
                ReadWrite
                defaultFileFlags
                    { creat = Just 0o600
                    , exclusive = True
                    , nofollow = True
                    , cloexec = True
                    }
            )
    case opened of
        Left failure -> pure (Left (posixFault "create the file" target failure))
        Right fd -> do
            written <- onException (tryIOError (restore (writeWholeFd fd bytes))) (closeFd fd)
            closed <- tryIOError (closeFd fd)
            pure $ case (written, closed) of
                (Left failure, _) -> Left (posixFault "write" target failure)
                (_, Left failure) -> Left (posixFault "close" target failure)
                _ -> Right ()

{- | @linkat(2)@, which is the atomic no-replace publication.

A filesystem that cannot hard-link at all is a host that cannot hold clause 3's
publication, so it is 'OwnershipUnsupported' rather than a probe failure. The
source name survives, because the kernel primitive is a link: withdrawing the
staging name is the composing caller's step, and an owner that needs both names
to exist keeps both.
-}
posixLinkNoReplace :: FilePath -> FilePath -> IO (Either OwnershipFault ())
posixLinkNoReplace source target = do
    linked <- tryIOError $
        withPathParent source $ \(Fd sourceParent) sourceName ->
            withPathParent target $ \(Fd targetParent) targetName ->
                withFilePath sourceName $ \nativeSource ->
                    withFilePath targetName $ \nativeTarget ->
                        throwErrnoIfMinus1Retry_ "linkat owned publication" $
                            c_parentLinkAt sourceParent nativeSource targetParent nativeTarget 0
    pure $ case linked of
        Left failure
            | unsupportedLink failure ->
                Left
                    ( OwnershipUnsupported
                        ( "this host cannot publish "
                            <> subjectOf target
                            <> " without replacing it: it supplies no hard link"
                        )
                    )
            | isErrno (nativeErrno failure) eXDEV ->
                Left (OwnershipProbeFailed ("publish " <> subjectOf target) "staging and target are on different mounts")
            | isErrno (nativeErrno failure) eMLINK ->
                Left (OwnershipProbeFailed ("publish " <> subjectOf target) "the filesystem link-count limit was reached")
            | otherwise -> Left (posixFault "publish" target failure)
        Right () -> Right ()

-- | Read the whole object behind an open handle.
posixReadObject :: PosixOwnedHandle -> IO (Either OwnershipFault ByteString)
posixReadObject (PosixOwnedHandle fd) = do
    described <- tryIOError (getFdStatus fd)
    case described of
        Left failure -> pure (Left (posixFault "describe" "an open handle" failure))
        Right status -> do
            contents <- tryIOError (readWholeFd fd (fromIntegral (fileSize status)))
            pure $ case contents of
                Left failure -> Left (posixFault "read" "an open handle" failure)
                Right bytes -> Right bytes

{- | Remove exactly the named object.

The kind is read through the retained parent rather than assumed, and a symbolic link is
refused: the object this transaction bound was one it created, so a link at the
target is something else standing where it used to be.
-}
posixRemoveObject :: FilePath -> IO (Either OwnershipFault ())
posixRemoveObject target = withPathParentResult "remove" target $ \parent@(Fd descriptor) name -> do
    observed <- tryIOError (pathStatusAt parent name)
    case observed of
        Left failure -> pure (Left (posixFault "observe" target failure))
        Right status
            | isSymbolicLink status ->
                pure
                    ( Left
                        ( OwnershipOccupied
                            (subjectOf target <> " is a symbolic link, which is a different object")
                        )
                    )
            | otherwise ->
                faultOr "remove" target <$> tryIOError
                    (withFilePath name $ \nativeName ->
                        throwErrnoIfMinus1Retry_ "unlinkat owned object" $
                            c_manifestUnlinkAt descriptor nativeName
                                (if isDirectory status then c_manifestRemoveDirectory else 0))

-- | Release one handle, and with it the exclusion the kernel was holding.
posixCloseHandle :: PosixOwnedHandle -> IO (Either OwnershipFault ())
posixCloseHandle (PosixOwnedHandle fd) = do
    unlocked <- tryIOError (setLock fd (Unlock, AbsoluteSeek, 0, 0))
    closed <- tryIOError (closeFd fd)
    pure $ case (unlocked, closed) of
        (Left failure, _) -> Left (posixFault "release the exclusion on" "an open handle" failure)
        (_, Left failure) -> Left (posixFault "close" "an open handle" failure)
        _ -> Right ()

{- | @fsync@ the parent directory, so the name change itself is durable.

Syncing the object is not enough: a crash after a create can otherwise leave a
directory entry that never reached the disk, which is exactly the window clause
2's record exists to make resolvable.
-}
posixSyncParent :: FilePath -> IO (Either OwnershipFault ())
posixSyncParent target =
    faultOr "sync the parent of" target <$> tryIOError
        (withPathParent target $ \parent _name -> fileSynchronise parent)

-- ---------------------------------------------------------------------------
-- Identity, faults, and raw descriptors

{- | Classify one platform failure into the closed fault sum.

Symbolic, so the same name means the same thing on Linux and on an Apple host,
and no raw status number ever reaches a driver. An object already there, a link
where a regular object was expected, and an object another owner holds are all
'OwnershipOccupied' — each is a target this owner does not adopt — and anything
else is the probe failing rather than answering.
-}
posixFault :: Text -> FilePath -> IOException -> OwnershipFault
posixFault operation target failure
    | matches [eEXIST] = occupied "is already there"
    | matches [eLOOP] = occupied "is a symbolic link, which is a different object"
    | matches [eNOTDIR, eISDIR] = occupied "is not the kind of object this clause names"
    | otherwise =
        OwnershipProbeFailed
            (operation <> " " <> subjectOf target)
            (Text.pack (show failure))
  where
    matches = any (isErrno (nativeErrno failure))
    occupied reason = OwnershipOccupied (subjectOf target <> " " <> reason)

-- | Only a lock request can report that another owner holds the object.
posixLockFault :: FilePath -> IOException -> OwnershipFault
posixLockFault target failure
    | any (isErrno (nativeErrno failure)) [eACCES, eAGAIN, eBUSY] =
        OwnershipOccupied (subjectOf target <> " is held by another owner")
    | otherwise = posixFault "exclusively hold" target failure

-- | A filesystem that cannot hard-link cannot hold the no-replace publication.
unsupportedLink :: IOException -> Bool
unsupportedLink failure =
    any (isErrno (nativeErrno failure)) [ePERM, eNOTSUP]

faultOr :: Text -> FilePath -> Either IOException () -> Either OwnershipFault ()
faultOr operation target = either (Left . posixFault operation target) Right

closingFd :: Fd -> OwnershipFault -> IO (Either OwnershipFault result)
closingFd fd fault = do
    void (tryIOError (closeFd fd))
    pure (Left fault)

subjectOf :: FilePath -> Text
subjectOf = Text.pack

nativeErrno :: IOException -> Word32
nativeErrno failure = maybe 0 fromIntegral (ioe_errno failure)

{- | Compare a captured @errno@ against a platform-supplied constant.

Never a hard-coded number: @ENOTSUP@ and its neighbours have different values on
Linux and on Apple hosts, so a numeric comparison would classify one host's
failure as another host's meaning.
-}
isErrno :: Word32 -> Errno -> Bool
isErrno status (Errno value) = status == fromIntegral value

readWholeFd :: Fd -> Int -> IO ByteString
readWholeFd _ size | size <= 0 = pure ByteString.empty
readWholeFd fd size =
    allocaBytes size $ \buffer ->
        let go offset
                | offset >= size = ByteString.packCStringLen (castPtr buffer, size)
                | otherwise = do
                    taken <- fdReadBuf fd (buffer `plusPtr` offset) (fromIntegral (size - offset))
                    if taken == 0
                        then ByteString.packCStringLen (castPtr buffer, offset)
                        else go (offset + fromIntegral taken)
         in go 0

writeWholeFd :: Fd -> ByteString -> IO ()
writeWholeFd fd bytes =
    ByteString.useAsCStringLen bytes $ \(pointer, size) ->
        let go offset
                | offset >= size = fileSynchronise fd
                | otherwise = do
                    written <-
                        fdWriteBuf fd (castPtr pointer `plusPtr` offset) (fromIntegral (size - offset))
                    if written == 0
                        then ioError (userError "a whole-file write made no progress")
                        else go (offset + fromIntegral written)
         in go 0

#else

posixObserveOwnershipManifest :: Bool -> FilePath -> IO (Either OwnershipFault OwnershipManifest)
posixObserveOwnershipManifest _mutable _root =
    pure (Left (OwnershipUnsupported "the POSIX ownership manifest row is unavailable on this host"))

posixObserveOwnershipManifestAt :: Bool -> FilePath -> Fd -> IO (Either OwnershipFault OwnershipManifest)
posixObserveOwnershipManifestAt _mutable _root _descriptor =
    pure (Left (OwnershipUnsupported "the POSIX ownership manifest row is unavailable on this host"))

posixReleaseManifestEntry :: FilePath -> ObjectIdentity -> OwnershipManifestEntry -> IO (Either OwnershipFault ())
posixReleaseManifestEntry _root _expectedRoot _entry =
    pure (Left (OwnershipUnsupported "the POSIX ownership manifest row is unavailable on this host"))

{- | The row in its refusing form.

Every field answers 'OwnershipUnsupported', including the identity read, so the
seam's declaration-driven refusal and the row's own primitives agree: a host that
cannot hold a clause mints no receipt at all rather than a weaker one. The row is
still a value here, because a caller naming a row is not yet a caller acting
through one — which is what keeps the cases about it in the suite (§ JJ).
-}
posixOwnershipRow :: OwnershipRow
posixOwnershipRow = ownershipRow refusingPrimitives

{- | The refusing primitives, named so the handle type is written down.

An empty type has no inhabitant, so a case over one needs the type to be known
rather than inferred from the record field it fills; naming the row's type here
is what makes each unreachable primitive a total function rather than an
ambiguous one.
-}
refusingPrimitives :: OwnershipPrimitive PosixOwnedHandle
refusingPrimitives =
    OwnershipPrimitive
        { rowCapabilities =
            OwnershipCapabilities
                { holdsStableIdentity = False
                , holdsNoReplacePublication = False
                , holdsDurableParentSync = False
                }
        , rowObserveIdentity = \_target -> refuse
        , rowOpenExclusive = \_target -> refuse
        , rowCreateDirectory = \_target -> refuse
        , rowCreateFile = \_target _bytes -> refuse
        , rowLinkNoReplace = \_source _target -> refuse
        , rowReadObject = \handle -> case handle of {}
        , rowRemoveObject = \_target -> refuse
        , rowCloseHandle = \handle -> case handle of {}
        , rowSyncParent = \_target -> refuse
        }
  where
    refuse :: IO (Either OwnershipFault result)
    refuse =
        pure
            ( Left
                ( OwnershipUnsupported
                    ( Text.pack
                        ( "the POSIX ownership row needs lstat identity, O_NOFOLLOW opens,"
                            <> " fcntl record locks, and link(2), none of which this host supplies"
                        )
                    )
                )
            )

{- | A row that opens nothing has no open object.

The handle therefore has no representation here, which is what makes the empty
type unreachable rather than merely unused: every primitive that would produce
one refuses first.
-}
data PosixOwnedHandle

#endif
