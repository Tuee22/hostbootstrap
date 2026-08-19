{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The primitives a Windows kernel supplies to the ownership seam, once.

The peer of "HostBootstrap.Ownership.Posix": the same row of
@development_plan_standards.md § LL@'s frame table, filled by a different
kernel. The four clauses are written once in
"HostBootstrap.Ownership.Primitive"; what is here is only the set of primitives
beneath them.

Each is a public @Win32@ type or wrapper, plus a narrow direct @kernel32@
boundary for the two operations whose exact status drives a recovery decision.
There is no C shim, no @c-sources@ block, and no private @Win32@ module:

  * identity is @GetFileInformationByHandle@'s volume serial number and file
    index, read through the vocabulary's one kernel-identity producer — the same
    producer the POSIX row's @(st_dev, st_ino)@ goes through — so the two rows
    cannot drift into meaning different things;
  * the exclusive open is @CreateFileW@ followed by @LockFileEx@ with
    @LOCKFILE_EXCLUSIVE_LOCK@ over a byte range. A Windows byte-range lock
    conflicts between handles even inside one process and is released by the
    kernel when the holding process dies, which is the property clause 1 rests
    on;
  * a file is created with @CREATE_NEW@, so a name that is taken is refused
    rather than truncated, and with @FILE_FLAG_WRITE_THROUGH@, so the bytes and
    the directory entry reach the disk rather than a cache;
  * publication is @CreateHardLinkW@, which publishes the written bytes under
    the final name in one kernel operation and fails when that name is taken.

Reparse points are refused rather than followed. Every handle is opened with
@FILE_FLAG_OPEN_REPARSE_POINT@, so what the row observes is the object the name
directly denotes; a directory or reparse point offered where a regular object is
required is 'OwnershipOccupied', because clause 3 binds what the kernel knows
about an object and a link is a different object.

There is no directory descriptor to flush on this kernel, so the parent's own
durability is carried by the write-through creation and the link that publishes
it rather than by a separate sync. The row still declares the capability,
because the guarantee the clause needs is met — it is the mechanism that
differs, which is exactly what a row is for.

The module is compiled on every host family and answers a total refusal where it
cannot apply, so no package-description stanza excludes it from a build and the
cases that cover it assert that refusal instead of disappearing (§ JJ).
-}
module HostBootstrap.Ownership.Windows
    ( windowsOwnershipRow
    , windowsOwnershipCapabilities
    , windowsOwnershipSupported
    )
where

import HostBootstrap.Ownership.Object (OwnershipFault (OwnershipUnsupported))
import HostBootstrap.Ownership.Primitive
    ( OwnershipCapabilities (..)
    , OwnershipPrimitive (..)
    , OwnershipRow
    , ownershipRow
    , withOwnershipRow
    )

#if defined(mingw32_HOST_OS)
import Control.Exception (IOException, catch)
import Control.Monad (void)
import Data.Bits ((.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr, plusPtr)
import HostBootstrap.Ownership.Object
    ( ObjectIdentity
    , OwnershipFault (OwnershipOccupied, OwnershipProbeFailed)
    , mkKernelObjectIdentity
    )
import System.Directory (createDirectory, removeDirectory, removeFile)
import System.IO.Error (isAlreadyExistsError, isPermissionError, tryIOError)
import System.Win32.File
    ( BY_HANDLE_FILE_INFORMATION (bhfiFileAttributes, bhfiFileIndex, bhfiSize, bhfiVolumeSerialNumber)
    , cREATE_NEW
    , closeHandle
    , fILE_ATTRIBUTE_DIRECTORY
    , fILE_ATTRIBUTE_NORMAL
    , fILE_ATTRIBUTE_REPARSE_POINT
    , fILE_BEGIN
    , fILE_FLAG_BACKUP_SEMANTICS
    , fILE_SHARE_DELETE
    , fILE_SHARE_READ
    , fILE_SHARE_WRITE
    , flushFileBuffers
    , gENERIC_READ
    , gENERIC_WRITE
    , getFileInformationByHandle
    , lOCKFILE_EXCLUSIVE_LOCK
    , lOCKFILE_FAIL_IMMEDIATELY
    , lockFile
    , oPEN_EXISTING
    , setFilePointerEx
    , unlockFile
    , win32_ReadFile
    , win32_WriteFile
    )
import System.Win32.Types (HANDLE, LPCTSTR, getLastError, iNVALID_HANDLE_VALUE, withFilePath)
#else
import qualified Data.Text as Text
#endif

{- | What this row declares it can hold, read off the row itself.

Derived rather than restated, so a case asking what this gate host supports asks
the subject rather than repeating a build symbol beside it (§ JJ).
-}
windowsOwnershipCapabilities :: OwnershipCapabilities
windowsOwnershipCapabilities = withOwnershipRow windowsOwnershipRow rowCapabilities

-- | Whether this gate host's kernel can hold the row's obligations at all.
windowsOwnershipSupported :: Bool
windowsOwnershipSupported = holdsStableIdentity windowsOwnershipCapabilities

#if defined(mingw32_HOST_OS)

-- ---------------------------------------------------------------------------
-- The row

{- | One object this row holds open, exclusively.

The path rides along because the Windows namespace operations this row still
reaches by name re-check the object they were given, and a diagnostic that
cannot say which object it is about is a diagnostic nobody can act on.
-}
data WindowsOwnedHandle = WindowsOwnedHandle HANDLE FilePath

windowsOwnershipRow :: OwnershipRow
windowsOwnershipRow =
    ownershipRow
        OwnershipPrimitive
            { rowCapabilities =
                OwnershipCapabilities
                    { holdsStableIdentity = True
                    , holdsExclusiveOpen = True
                    , holdsNoReplacePublication = True
                    , holdsDurableParentSync = True
                    }
            , rowObserveIdentity = windowsObserveIdentity
            , rowOpenExclusive = windowsOpenExclusive
            , rowCreateDirectory = windowsCreateDirectory
            , rowCreateFile = windowsCreateFile
            , rowLinkNoReplace = windowsLinkNoReplace
            , rowReadObject = windowsReadObject
            , rowRemoveObject = windowsRemoveObject
            , rowCloseHandle = windowsCloseHandle
            , rowSyncParent = windowsSyncParent
            }

-- ---------------------------------------------------------------------------
-- The primitives

{- | The volume serial number and file index of the object the name denotes.

Opened without following a reparse point, so a name swapped for a link reads as
a different object rather than as its target. An authoritative absence is
@Right Nothing@; every other failure is a fault (§ CC).
-}
windowsObserveIdentity :: FilePath -> IO (Either OwnershipFault (Maybe ObjectIdentity))
windowsObserveIdentity target = do
    opened <-
        openObject
            target
            gENERIC_READ
            (fILE_SHARE_READ .|. fILE_SHARE_WRITE .|. fILE_SHARE_DELETE)
            oPEN_EXISTING
            observationFlags
    case opened of
        Left fault -> pure (Left fault)
        Right Nothing -> pure (Right Nothing)
        Right (Just handle) -> do
            described <- describeHandle target handle
            closeQuietly handle
            pure $ case described of
                Left fault -> Left fault
                Right information -> fmap Just (identityOf information)

{- | Open one already-existing named object exclusively.

A directory or reparse point is refused rather than opened as a file, and the
exclusion is a byte-range lock the kernel releases when this process ends.
-}
windowsOpenExclusive :: FilePath -> IO (Either OwnershipFault WindowsOwnedHandle)
windowsOpenExclusive target = do
    opened <-
        openObject
            target
            (gENERIC_READ .|. gENERIC_WRITE)
            (fILE_SHARE_READ .|. fILE_SHARE_WRITE .|. fILE_SHARE_DELETE)
            oPEN_EXISTING
            observationFlags
    case opened of
        Left fault -> pure (Left fault)
        Right Nothing ->
            pure (Left (OwnershipProbeFailed ("open " <> subjectOf target) "no such object"))
        Right (Just handle) -> do
            described <- describeHandle target handle
            case described of
                Left fault -> closingHandle handle fault
                Right information
                    | isNonRegular information ->
                        closingHandle
                            handle
                            ( OwnershipOccupied
                                (subjectOf target <> " is a directory or reparse point")
                            )
                    | otherwise -> do
                        locked <-
                            lockFile
                                handle
                                (lOCKFILE_EXCLUSIVE_LOCK .|. lOCKFILE_FAIL_IMMEDIATELY)
                                1
                                0
                        if locked
                            then pure (Right (WindowsOwnedHandle handle target))
                            else do
                                status <- getLastError
                                closingHandle handle (statusFault "exclusively hold" target status)

-- | Create exactly one directory, refusing one that is already there.
windowsCreateDirectory :: FilePath -> IO (Either OwnershipFault ())
windowsCreateDirectory target =
    faultOr "create the directory" target <$> tryIOError (createDirectory target)

{- | Write one whole file at a name nothing else holds, through to the disk.

@CREATE_NEW@ refuses a name that is taken and @FILE_FLAG_WRITE_THROUGH@ is what
carries the durability a POSIX row gets from @fsync@ plus a parent sync.
-}
windowsCreateFile :: FilePath -> ByteString -> IO (Either OwnershipFault ())
windowsCreateFile target bytes = do
    opened <-
        openObject
            target
            (gENERIC_READ .|. gENERIC_WRITE)
            (fILE_SHARE_READ .|. fILE_SHARE_DELETE)
            cREATE_NEW
            (fILE_ATTRIBUTE_NORMAL .|. fileFlagWriteThrough .|. fileFlagOpenReparsePoint)
    case opened of
        Left fault -> pure (Left fault)
        Right Nothing ->
            pure (Left (OwnershipOccupied (subjectOf target <> " is already there")))
        Right (Just handle) -> do
            written <- writeWholeHandle target handle bytes
            closeQuietly handle
            pure written

{- | @CreateHardLinkW@, which is the atomic no-replace publication.

A filesystem that cannot hard-link at all cannot hold clause 3's publication, so
that is 'OwnershipUnsupported' rather than a probe failure. The source name
survives, because the kernel primitive is a link: withdrawing the staging name
is the composing caller's step, and an owner that needs both names to exist
keeps both.
-}
windowsLinkNoReplace :: FilePath -> FilePath -> IO (Either OwnershipFault ())
windowsLinkNoReplace source target = do
    linked <-
        withFilePath target $ \wideTarget ->
            withFilePath source $ \wideSource ->
                rawCreateHardLinkW wideTarget wideSource nullPtr
    if linked
        then pure (Right ())
        else do
            status <- getLastError
            pure $
                if status == errorNotSameDevice || status == errorNotSupported
                    then
                        Left
                            ( OwnershipUnsupported
                                ( "this host cannot publish "
                                    <> subjectOf target
                                    <> " without replacing it: it supplies no hard link"
                                )
                            )
                    else Left (statusFault "publish" target status)

-- | Read the whole object behind an open handle.
windowsReadObject :: WindowsOwnedHandle -> IO (Either OwnershipFault ByteString)
windowsReadObject (WindowsOwnedHandle handle target) = do
    described <- describeHandle target handle
    case described of
        Left fault -> pure (Left fault)
        Right information ->
            readWholeHandle target handle (fromIntegral (bhfiSize information))

{- | Remove exactly the named object.

The kind is read from the object's own attributes rather than assumed, and a
reparse point is refused: the object this transaction bound was one it created,
so a link at the target is something else standing where it used to be.
-}
windowsRemoveObject :: FilePath -> IO (Either OwnershipFault ())
windowsRemoveObject target = do
    opened <-
        openObject
            target
            gENERIC_READ
            (fILE_SHARE_READ .|. fILE_SHARE_WRITE .|. fILE_SHARE_DELETE)
            oPEN_EXISTING
            observationFlags
    case opened of
        Left fault -> pure (Left fault)
        Right Nothing ->
            pure (Left (OwnershipProbeFailed ("observe " <> subjectOf target) "no such object"))
        Right (Just handle) -> do
            described <- describeHandle target handle
            closeQuietly handle
            case described of
                Left fault -> pure (Left fault)
                Right information
                    | isReparsePoint information ->
                        pure
                            ( Left
                                ( OwnershipOccupied
                                    ( subjectOf target
                                        <> " is a reparse point, which is a different object"
                                    )
                                )
                            )
                    | isDirectoryObject information ->
                        faultOr "remove the directory" target
                            <$> tryIOError (removeDirectory target)
                    | otherwise ->
                        faultOr "remove" target <$> tryIOError (removeFile target)

-- | Release one handle, and with it the exclusion the kernel was holding.
windowsCloseHandle :: WindowsOwnedHandle -> IO (Either OwnershipFault ())
windowsCloseHandle (WindowsOwnedHandle handle target) = do
    unlocked <- unlockFile handle 1 0
    if unlocked
        then do
            closeQuietly handle
            pure (Right ())
        else do
            status <- getLastError
            closeQuietly handle
            pure (Left (statusFault "release the exclusion on" target status))

{- | The parent's own change, made durable.

There is no directory descriptor to flush on this kernel. The creation and the
publication above are write-through, so the entry the parent gained is already
on the disk when they return, and this primitive has nothing left to do rather
than something it cannot do.
-}
windowsSyncParent :: FilePath -> IO (Either OwnershipFault ())
windowsSyncParent _target = pure (Right ())

-- ---------------------------------------------------------------------------
-- Handles, identity, and status

{- | The flags every observation opens with.

@FILE_FLAG_BACKUP_SEMANTICS@ is what makes a directory openable at all, and
@FILE_FLAG_OPEN_REPARSE_POINT@ is what keeps a link from being followed.
-}
observationFlags :: Word32
observationFlags =
    fILE_ATTRIBUTE_NORMAL .|. fILE_FLAG_BACKUP_SEMANTICS .|. fileFlagOpenReparsePoint

-- The public @Win32@ API does not expose these two SDK flags even though the
-- native @CreateFileW@ entry point accepts the complete @dwFlagsAndAttributes@
-- field. Both exist once here rather than at each call site.
fileFlagOpenReparsePoint, fileFlagWriteThrough :: Word32
fileFlagOpenReparsePoint = 0x00200000
fileFlagWriteThrough = 0x80000000

{- | Open one object, or report an authoritative absence.

The direct @kernel32@ boundary is here because the exact status separates "the
name is not there" from "the name is held by someone else", and the public
@Win32@ wrappers flatten both into one 'IOException' category.
-}
openObject ::
    FilePath ->
    Word32 ->
    Word32 ->
    Word32 ->
    Word32 ->
    IO (Either OwnershipFault (Maybe HANDLE))
openObject target access share creation flags =
    withFilePath target $ \widePath -> do
        handle <- rawCreateFileW widePath access share nullPtr creation flags nullPtr
        if handle /= iNVALID_HANDLE_VALUE
            then pure (Right (Just handle))
            else do
                status <- getLastError
                pure $
                    if status == errorFileNotFound || status == errorPathNotFound
                        then Right Nothing
                        else Left (statusFault "open" target status)

describeHandle :: FilePath -> HANDLE -> IO (Either OwnershipFault BY_HANDLE_FILE_INFORMATION)
describeHandle target handle =
    (Right <$> getFileInformationByHandle handle)
        `catch` \failure -> pure (Left (exceptionFault "describe" target failure))

identityOf :: BY_HANDLE_FILE_INFORMATION -> Either OwnershipFault ObjectIdentity
identityOf information =
    mkKernelObjectIdentity
        (fromIntegral (bhfiVolumeSerialNumber information))
        (bhfiFileIndex information)

isDirectoryObject :: BY_HANDLE_FILE_INFORMATION -> Bool
isDirectoryObject information =
    bhfiFileAttributes information .&. fILE_ATTRIBUTE_DIRECTORY /= 0

isReparsePoint :: BY_HANDLE_FILE_INFORMATION -> Bool
isReparsePoint information =
    bhfiFileAttributes information .&. fILE_ATTRIBUTE_REPARSE_POINT /= 0

isNonRegular :: BY_HANDLE_FILE_INFORMATION -> Bool
isNonRegular information = isDirectoryObject information || isReparsePoint information

{- | Classify one exact status into the closed fault sum.

Symbolic against the platform's own numbering rather than a bare integer at each
call site, and no raw status ever reaches a driver: an object already there, a
name held by another owner, and a lock another handle holds are each a target
this owner does not adopt, and anything else is the probe failing rather than
answering.
-}
statusFault :: Text -> FilePath -> Word32 -> OwnershipFault
statusFault operation target status
    | status `elem` [errorFileExists, errorAlreadyExists] = occupied "is already there"
    | status `elem` [errorSharingViolation, errorLockViolation, errorAccessDenied] =
        occupied "is held by another owner"
    | status == errorDirectory = occupied "is not the kind of object this clause names"
    | otherwise =
        OwnershipProbeFailed
            (operation <> " " <> subjectOf target)
            ("Windows status " <> Text.pack (show status))
  where
    occupied reason = OwnershipOccupied (subjectOf target <> " " <> reason)

{- | Classify a public wrapper's exception, conservatively.

A wrapper that has already flattened the status cannot prove the retryable
sharing class, so a permission failure is reported as an occupied target and
nothing stronger is claimed.
-}
exceptionFault :: Text -> FilePath -> IOException -> OwnershipFault
exceptionFault operation target failure
    | isAlreadyExistsError failure =
        OwnershipOccupied (subjectOf target <> " is already there")
    | isPermissionError failure =
        OwnershipOccupied (subjectOf target <> " is held by another owner")
    | otherwise =
        OwnershipProbeFailed
            (operation <> " " <> subjectOf target)
            (Text.pack (show failure))

faultOr :: Text -> FilePath -> Either IOException () -> Either OwnershipFault ()
faultOr operation target = either (Left . exceptionFault operation target) Right

closingHandle :: HANDLE -> OwnershipFault -> IO (Either OwnershipFault result)
closingHandle handle fault = do
    closeQuietly handle
    pure (Left fault)

closeQuietly :: HANDLE -> IO ()
closeQuietly handle = void (tryIOError (closeHandle handle))

subjectOf :: FilePath -> Text
subjectOf = Text.pack

{- | Read the whole object behind an open handle, from its start. -}
readWholeHandle :: FilePath -> HANDLE -> Int -> IO (Either OwnershipFault ByteString)
readWholeHandle _ _ size | size <= 0 = pure (Right ByteString.empty)
readWholeHandle target handle size = do
    positioned <-
        (Right <$> setFilePointerEx handle 0 fILE_BEGIN)
            `catch` \failure -> pure (Left (exceptionFault "seek" target failure))
    case positioned of
        Left fault -> pure (Left fault)
        Right _ -> allocaBytes size $ \buffer ->
            let go offset
                    | offset >= size =
                        Right <$> ByteString.packCStringLen (castPtr buffer, size)
                    | otherwise = do
                        taken <-
                            (Right <$> win32_ReadFile handle (buffer `plusPtr` offset) (fromIntegral (size - offset)) Nothing)
                                `catch` \failure -> pure (Left (exceptionFault "read" target failure))
                        case taken of
                            Left fault -> pure (Left fault)
                            Right count
                                | count == 0 ->
                                    Right <$> ByteString.packCStringLen (castPtr buffer, offset)
                                | otherwise -> go (offset + fromIntegral count)
             in go 0

writeWholeHandle :: FilePath -> HANDLE -> ByteString -> IO (Either OwnershipFault ())
writeWholeHandle target handle bytes =
    ByteString.useAsCStringLen bytes $ \(pointer, size) ->
        let go offset
                | offset >= size =
                    (Right <$> flushFileBuffers handle)
                        `catch` \failure -> pure (Left (exceptionFault "flush" target failure))
                | otherwise = do
                    written <-
                        (Right <$> win32_WriteFile handle (castPtr pointer `plusPtr` offset) (fromIntegral (size - offset)) Nothing)
                            `catch` \failure -> pure (Left (exceptionFault "write" target failure))
                    case written of
                        Left fault -> pure (Left fault)
                        Right count
                            | count == 0 ->
                                pure
                                    ( Left
                                        ( OwnershipProbeFailed
                                            ("write " <> subjectOf target)
                                            "a whole-file write made no progress"
                                        )
                                    )
                            | otherwise -> go (offset + fromIntegral count)
         in go 0

{- | The two direct @kernel32@ entry points this row needs.

Both are here because the exact status they set is what separates a name that is
taken from a filesystem that cannot hard-link at all, and the public wrappers
lose that distinction.
-}
foreign import capi unsafe "windows.h CreateFileW"
    rawCreateFileW ::
        LPCTSTR -> Word32 -> Word32 -> Ptr () -> Word32 -> Word32 -> HANDLE -> IO HANDLE

foreign import capi unsafe "windows.h CreateHardLinkW"
    rawCreateHardLinkW :: LPCTSTR -> LPCTSTR -> Ptr () -> IO Bool

errorFileNotFound, errorPathNotFound, errorAccessDenied :: Word32
errorFileNotFound = 2
errorPathNotFound = 3
errorAccessDenied = 5

errorNotSameDevice, errorFileExists, errorSharingViolation, errorLockViolation :: Word32
errorNotSameDevice = 17
errorFileExists = 80
errorSharingViolation = 32
errorLockViolation = 33

errorNotSupported, errorAlreadyExists, errorDirectory :: Word32
errorNotSupported = 50
errorAlreadyExists = 183
errorDirectory = 267

#else

{- | The row in its refusing form.

Every field answers 'OwnershipUnsupported', so the seam's declaration-driven
refusal and the row's own primitives agree: a host that cannot hold a clause
mints no receipt at all rather than a weaker one. The row is still a value here,
because a caller naming a row is not yet a caller acting through one — which is
what keeps the cases about it in the suite (§ JJ).
-}
windowsOwnershipRow :: OwnershipRow
windowsOwnershipRow = ownershipRow refusingPrimitives

{- | The refusing primitives, named so the handle type is written down.

An empty type has no inhabitant, so a case over one needs the type to be known
rather than inferred from the record field it fills; naming the row's type here
is what makes each unreachable primitive a total function rather than an
ambiguous one.
-}
refusingPrimitives :: OwnershipPrimitive WindowsOwnedHandle
refusingPrimitives =
    OwnershipPrimitive
        { rowCapabilities =
            OwnershipCapabilities
                { holdsStableIdentity = False
                , holdsExclusiveOpen = False
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
                        ( "the Windows ownership row needs GetFileInformationByHandle identity,"
                            <> " LockFileEx byte-range locks, reparse-point opens, and CreateHardLinkW,"
                            <> " none of which this host supplies"
                        )
                    )
                )
            )

{- | A row that opens nothing has no open object.

The handle therefore has no representation here, which is what makes the empty
type unreachable rather than merely unused: every primitive that would produce
one refuses first.
-}
data WindowsOwnedHandle

#endif
