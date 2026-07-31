{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Windows backend for the portable host wall
('HostBootstrap.Wsl2.GlobalWall.Host').

This is the production WSL lane: it is the only substrate on which
@%UserProfile%\\.wslconfig@ exists.  It supplies platform primitives only — the
complete recovery driver, the durable record codec, and the ownership
arithmetic live in the portable module and are exercised on every host by the
POSIX backend.

The four ownership clauses are held with the @Win32@ package's existing
bindings; no C shim, no @c-sources@ block, and no threaded-RTS carve-out are
needed:

* clause 1 — @LockFileEx@ with @LOCKFILE_EXCLUSIVE_LOCK@ on a byte range of a
  per-user lock file.  A Windows byte-range lock conflicts between handles even
  inside one process and is released by the kernel when the process dies;
* clause 2 — the durable origin record is a journal file beside the lock,
  replaced atomically before the first mutation;
* clause 3 — identity is @GetFileInformationByHandle@'s volume serial number
  and file index, encoded volume-word first;
* clause 4 — every namespace operation re-observes the path's identity under
  the same lock and refuses a replacement.

Staging still uses a volatile armed link (@FILE_FLAG_DELETE_ON_CLOSE@), so the
driver keeps the strict Windows reading of an armed object observed before its
identity was journalled: it cannot be ours, and it is refused rather than
removed.
-}
module HostBootstrap.Wsl2.GlobalWall.Windows
  ( windowsGlobalWallSupported,
    applyCurrentUserGlobalWall,
    restoreCurrentUserGlobalWall,
  )
where

import HostBootstrap.Wsl2.GlobalWall.Host

#if defined(mingw32_HOST_OS)
import Control.Monad (void)
import Data.Bits ((.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Word (Word32, Word64)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (castPtr, nullPtr, plusPtr)
import Foreign.Storable (peek)
import GHC.Clock (getMonotonicTime)
import Control.Concurrent (threadDelay)
import Control.Exception (onException)
import HostBootstrap.Wsl2.GlobalWall
  ( FileIdentity,
    WallConflict (TargetReplaced, UnexpectedTargetAbsent, UnexpectedTargetPresent),
    mkFileIdentity,
  )
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Win32.File
  ( BY_HANDLE_FILE_INFORMATION (bhfiFileAttributes, bhfiFileIndex, bhfiSize, bhfiVolumeSerialNumber),
    OVERLAPPED (OVERLAPPED),
    cREATE_NEW,
    dELETE,
    fILE_ATTRIBUTE_DIRECTORY,
    fILE_ATTRIBUTE_NORMAL,
    fILE_ATTRIBUTE_REPARSE_POINT,
    fILE_BEGIN,
    fILE_FLAG_DELETE_ON_CLOSE,
    fILE_FLAG_OPEN_REPARSE_POINT,
    fILE_SHARE_DELETE,
    fILE_SHARE_READ,
    fILE_SHARE_WRITE,
    gENERIC_READ,
    gENERIC_WRITE,
    lOCKFILE_EXCLUSIVE_LOCK,
    lOCKFILE_FAIL_IMMEDIATELY,
    oPEN_ALWAYS,
    oPEN_EXISTING,
  )
import System.Win32.File.Internal
  ( c_CloseHandle,
    c_CreateFile,
    c_DeleteFile,
    c_FlushFileBuffers,
    c_GetFileInformationByHandle,
    c_LockFileEx,
    c_MoveFileEx,
    c_ReadFile,
    c_SetFilePointerEx,
    c_UnlockFileEx,
    c_WriteFile,
  )
import System.Win32.HardLink.Internal (c_CreateHardLink)
import System.Win32.String (withTString)
import System.Win32.Types (HANDLE, getLastError, iNVALID_HANDLE_VALUE)
#endif

#if !defined(mingw32_HOST_OS)

windowsGlobalWallSupported :: Bool
windowsGlobalWallSupported = False

applyCurrentUserGlobalWall ::
  CurrentUserWallRequest ->
  IO (Either HostWallError AppliedWslConfigFile)
applyCurrentUserGlobalWall _ =
  pure
    ( Left
        (HostWallUnsupported "the WSL global wall requires Windows")
    )

restoreCurrentUserGlobalWall ::
  CurrentUserWallRequest ->
  IO (Either HostWallError ())
restoreCurrentUserGlobalWall _ =
  pure
    ( Left
        (HostWallUnsupported "the WSL global wall requires Windows")
    )

#else

windowsGlobalWallSupported :: Bool
windowsGlobalWallSupported = True

applyCurrentUserGlobalWall ::
  CurrentUserWallRequest ->
  IO (Either HostWallError AppliedWslConfigFile)
applyCurrentUserGlobalWall request = do
  prepared <- newWindowsHostWallBackend
  case prepared of
    Left err -> pure (Left err)
    Right backend -> applyGlobalWall backend request

restoreCurrentUserGlobalWall ::
  CurrentUserWallRequest ->
  IO (Either HostWallError ())
restoreCurrentUserGlobalWall request = do
  prepared <- newWindowsHostWallBackend
  case prepared of
    Left err -> pure (Left err)
    Right backend -> restoreGlobalWall backend request

-- | An open Windows object. The path is retained because Windows namespace
-- operations are path-based; every one of them re-checks the recorded identity
-- before it acts.
data WindowsWallHandle = WindowsWallHandle
  { windowsHandle :: HANDLE,
    windowsHandlePath :: FilePath
  }

data WindowsWallLocation = WindowsWallLocation
  { windowsWallTargetPath :: FilePath,
    windowsWallStateDirectory :: FilePath
  }

-- | Derive @%UserProfile%\\.wslconfig@ and the sibling state directory. No
-- caller input reaches either path.
currentUserWallLocation :: IO (Either HostWallError WindowsWallLocation)
currentUserWallLocation = do
  profile <- lookupEnv "USERPROFILE"
  case profile of
    Nothing ->
      pure
        ( Left
            ( HostWallUnsupported
                "USERPROFILE is not set, so the per-user .wslconfig cannot be derived"
            )
        )
    Just home
      | null home ->
          pure
            ( Left
                ( HostWallUnsupported
                    "USERPROFILE is empty, so the per-user .wslconfig cannot be derived"
                )
            )
      | otherwise ->
          pure
            ( Right
                WindowsWallLocation
                  { windowsWallTargetPath = home </> ".wslconfig",
                    windowsWallStateDirectory = home </> ".hostbootstrap"
                  }
            )

newWindowsHostWallBackend ::
  IO (Either HostWallError (HostWallBackend WindowsWallHandle))
newWindowsHostWallBackend = do
  located <- currentUserWallLocation
  case located of
    Left err -> pure (Left err)
    Right location -> do
      createDirectoryIfMissing True (windowsWallStateDirectory location)
      pure
        ( Right
            HostWallBackend
              { wallBackendName = "windows",
                wallTargetPath = pure (Right (windowsWallTargetPath location)),
                wallWithExclusiveEntry =
                  windowsExclusiveEntry (lockPath location),
                wallOpenExclusive = windowsOpenExclusive,
                wallProbeIdentity = windowsProbeIdentity,
                wallCreateArmedStage = windowsCreateArmedStage,
                wallLinkArmedStage = windowsLinkArmedStage,
                wallRenameNoReplace = windowsRenameNoReplace,
                wallDeleteObject = windowsDeleteObject,
                wallCloseObject = windowsCloseObject,
                wallArmedStageIsVolatile = True,
                wallIsSharingFailure = windowsIsSharingFailure,
                wallIsRaceFailure = windowsIsRaceFailure,
                wallIsHardLinkUnsupported = windowsIsHardLinkUnsupported,
                wallJournalLoad = windowsJournalLoad (recordPath location),
                wallJournalAllocateFence =
                  windowsAllocateFence (fencePath location),
                wallJournalStore = windowsJournalStore (recordPath location),
                wallJournalDeleteIfEqual =
                  windowsJournalDeleteIfEqual (recordPath location)
              }
        )

lockPath :: WindowsWallLocation -> FilePath
lockPath location = windowsWallStateDirectory location </> "global-wall.lock"

recordPath :: WindowsWallLocation -> FilePath
recordPath location =
  windowsWallStateDirectory location </> "global-wall.record"

fencePath :: WindowsWallLocation -> FilePath
fencePath location = windowsWallStateDirectory location </> "global-wall.fence"

-- Clause 1 -------------------------------------------------------------------

lockWaitSeconds :: Double
lockWaitSeconds = 30

{- | A @LockFileEx@ byte-range lock conflicts between handles even inside one
process, so it needs no in-process companion mutex, and it is not affine to the
acquiring OS thread the way a Win32 named mutex is.  That is why the test
executable no longer needs the threaded RTS.
-}
windowsExclusiveEntry ::
  FilePath ->
  IO (Either HostWallError result) ->
  IO (Either HostWallError result)
windowsExclusiveEntry path action = do
  opened <-
    openHandle
      path
      (gENERIC_READ .|. gENERIC_WRITE)
      (fILE_SHARE_READ .|. fILE_SHARE_WRITE)
      oPEN_ALWAYS
      fILE_ATTRIBUTE_NORMAL
  case opened of
    Left err -> pure (Left err)
    Right Nothing ->
      pure
        ( Left
            ( HostWallNativeFailure
                ("open the global wall lock " ++ path)
                errorFileNotFound
            )
        )
    Right (Just handle) -> do
      acquired <- acquireExclusiveRange handle
      case acquired of
        Left err -> do
          void (c_CloseHandle handle)
          pure (Left err)
        Right () -> do
          result <- action `onException` releaseRange handle
          released <- releaseRange handle
          pure $
            case (result, released) of
              (Left err, _) -> Left err
              (Right _, Left err) -> Left err
              (Right value, Right ()) -> Right value

acquireExclusiveRange :: HANDLE -> IO (Either HostWallError ())
acquireExclusiveRange handle = do
  started <- getMonotonicTime
  go started
  where
    go started =
      with (OVERLAPPED 0 0 0 0 nullPtr) $ \overlapped -> do
        locked <-
          c_LockFileEx
            handle
            (lOCKFILE_EXCLUSIVE_LOCK .|. lOCKFILE_FAIL_IMMEDIATELY)
            0
            1
            0
            overlapped
        if locked
          then pure (Right ())
          else do
            status <- getLastError
            now <- getMonotonicTime
            if not (windowsIsContendedFailure status)
              then
                pure
                  ( Left
                      ( HostWallNativeFailure
                          "acquire the per-user global wall lock"
                          status
                      )
                  )
              else
                if now - started >= lockWaitSeconds
                  then
                    pure
                      ( Left
                          ( HostWallBusy
                              "the per-user global wall lock was not acquired within 30 seconds"
                          )
                      )
                  else threadDelay 50000 >> go started

releaseRange :: HANDLE -> IO (Either HostWallError ())
releaseRange handle = do
  unlocked <-
    with (OVERLAPPED 0 0 0 0 nullPtr) $ \overlapped ->
      c_UnlockFileEx handle 0 1 0 overlapped
  closed <- c_CloseHandle handle
  pure $
    if not unlocked
      then
        Left
          ( HostWallNativeFailure
              "release the per-user global wall lock"
              errorInvalidData
          )
      else
        if closed
          then Right ()
          else
            Left
              ( HostWallNativeFailure
                  "close the per-user global wall lock"
                  errorInvalidData
              )

-- Clause 3: exact observation ------------------------------------------------

{- | The observation share mode admits concurrent readers and deletes: mutual
exclusion is the global lock's job, and @DeleteFile@/@MoveFileEx@ must be able
to act on a name this process still holds open.
-}
observationShareMode :: Word32
observationShareMode = fILE_SHARE_READ .|. fILE_SHARE_DELETE

windowsOpenExclusive ::
  FilePath ->
  IO (Either HostWallError (Maybe (WallObject WindowsWallHandle)))
windowsOpenExclusive path = do
  opened <-
    openHandle
      path
      (gENERIC_READ .|. dELETE)
      observationShareMode
      oPEN_EXISTING
      (fILE_ATTRIBUTE_NORMAL .|. fILE_FLAG_OPEN_REPARSE_POINT)
  case opened of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right Nothing)
    Right (Just handle) -> do
      described <- handleInformation path handle
      case described of
        Left err -> do
          void (c_CloseHandle handle)
          pure (Left err)
        Right information
          | isNonRegular information -> do
              void (c_CloseHandle handle)
              pure
                ( Left
                    ( HostWallUnsupported
                        ( "refusing to observe the directory or reparse point at "
                            ++ path
                        )
                    )
                )
          | bhfiSize information > fromIntegral maximumWallBytes -> do
              void (c_CloseHandle handle)
              pure
                ( Left
                    ( HostWallUnsupported
                        (path ++ " exceeds the 16 MiB adapter limit")
                    )
                )
          | otherwise -> do
              contents <-
                readWholeHandle path handle (fromIntegral (bhfiSize information))
              case contents of
                Left err -> do
                  void (c_CloseHandle handle)
                  pure (Left err)
                Right bytes ->
                  case identityOf information of
                    Left err -> do
                      void (c_CloseHandle handle)
                      pure (Left err)
                    Right identity ->
                      pure
                        ( Right
                            ( Just
                                WallObject
                                  { wallObjectHandle =
                                      WindowsWallHandle
                                        { windowsHandle = handle,
                                          windowsHandlePath = path
                                        },
                                    wallObjectIdentity = identity,
                                    wallObjectBytes = bytes
                                  }
                            )
                        )

windowsProbeIdentity ::
  FilePath ->
  IO (Either HostWallError (Maybe FileIdentity))
windowsProbeIdentity path = do
  opened <-
    openHandle
      path
      gENERIC_READ
      (fILE_SHARE_READ .|. fILE_SHARE_WRITE .|. fILE_SHARE_DELETE)
      oPEN_EXISTING
      (fILE_ATTRIBUTE_NORMAL .|. fILE_FLAG_OPEN_REPARSE_POINT)
  case opened of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right Nothing)
    Right (Just handle) -> do
      described <- handleInformation path handle
      void (c_CloseHandle handle)
      pure $
        case described of
          Left err -> Left err
          Right information
            | isNonRegular information ->
                Left
                  ( HostWallUnsupported
                      ( "identity probing refused a directory or reparse point at "
                          ++ path
                      )
                  )
            | otherwise -> Just <$> identityOf information

windowsCreateArmedStage ::
  FilePath ->
  ByteString ->
  IO (Either HostWallError (WallObject WindowsWallHandle))
windowsCreateArmedStage path bytes = do
  opened <-
    openHandle
      path
      (gENERIC_READ .|. gENERIC_WRITE .|. dELETE)
      observationShareMode
      cREATE_NEW
      (fILE_ATTRIBUTE_NORMAL .|. fILE_FLAG_DELETE_ON_CLOSE)
  case opened of
    Left err -> pure (Left err)
    Right Nothing ->
      pure
        ( Left
            ( HostWallNativeFailure
                ("create armed stage " ++ path)
                errorFileExists
            )
        )
    Right (Just handle) -> do
      written <- writeWholeHandle path handle bytes
      case written of
        Left err -> do
          void (c_CloseHandle handle)
          pure (Left err)
        Right () -> do
          described <- handleInformation path handle
          case described of
            Left err -> do
              void (c_CloseHandle handle)
              pure (Left err)
            Right information ->
              case identityOf information of
                Left err -> do
                  void (c_CloseHandle handle)
                  pure (Left err)
                Right identity ->
                  pure
                    ( Right
                        WallObject
                          { wallObjectHandle =
                              WindowsWallHandle
                                { windowsHandle = handle,
                                  windowsHandlePath = path
                                },
                            wallObjectIdentity = identity,
                            wallObjectBytes = bytes
                          }
                    )

-- Clause 4: identity-conditional namespace operations ------------------------

windowsLinkArmedStage ::
  WallObject WindowsWallHandle ->
  FilePath ->
  FilePath ->
  IO (Either HostWallError ())
windowsLinkArmedStage object armed bound = do
  confirmed <- confirmPathIdentity object armed
  case confirmed of
    Left err -> pure (Left err)
    Right () -> do
      linked <-
        withTString bound $ \wideBound ->
          withTString armed $ \wideArmed ->
            c_CreateHardLink wideBound wideArmed nullPtr
      if linked
        then pure (Right ())
        else do
          status <- getLastError
          pure
            ( Left
                ( HostWallNativeFailure
                    ("hard link " ++ armed ++ " to " ++ bound)
                    status
                )
            )

windowsRenameNoReplace ::
  WallObject WindowsWallHandle ->
  FilePath ->
  IO (Either HostWallError ())
windowsRenameNoReplace object destination = do
  let source = windowsHandlePath (wallObjectHandle object)
  confirmed <- confirmPathIdentity object source
  case confirmed of
    Left err -> pure (Left err)
    Right () -> do
      -- No @MOVEFILE_REPLACE_EXISTING@: a present destination must fail rather
      -- than be overwritten.
      moved <-
        withTString source $ \wideSource ->
          withTString destination $ \wideDestination ->
            c_MoveFileEx wideSource wideDestination 0
      if moved
        then pure (Right ())
        else do
          status <- getLastError
          pure
            ( Left
                ( HostWallNativeFailure
                    ("no-replace rename to " ++ destination)
                    status
                )
            )

windowsDeleteObject ::
  WallObject WindowsWallHandle ->
  IO (Either HostWallError ())
windowsDeleteObject object = do
  let path = windowsHandlePath (wallObjectHandle object)
  confirmed <- confirmPathIdentity object path
  case confirmed of
    Left err -> pure (Left err)
    Right () -> do
      deleted <- withTString path c_DeleteFile
      if deleted
        then pure (Right ())
        else do
          status <- getLastError
          pure $
            if status == errorFileNotFound
              then Right ()
              else
                Left
                  ( HostWallNativeFailure
                      ("delete " ++ path)
                      status
                  )

windowsCloseObject ::
  WallObject WindowsWallHandle ->
  IO (Either HostWallError ())
windowsCloseObject object = do
  closed <- c_CloseHandle (windowsHandle (wallObjectHandle object))
  pure $
    if closed
      then Right ()
      else
        Left
          ( HostWallNativeFailure
              "close an exact file handle"
              errorInvalidData
          )

{- | Clause 4 in one place: a namespace operation acts only while the name
still denotes the exact object that was observed under this lock.
-}
confirmPathIdentity ::
  WallObject WindowsWallHandle ->
  FilePath ->
  IO (Either HostWallError ())
confirmPathIdentity object path = do
  observed <- windowsProbeIdentity path
  pure $
    case observed of
      Left err -> Left err
      Right Nothing ->
        Left
          ( HostWallConflict
              (UnexpectedTargetAbsent (wallObjectIdentity object))
          )
      Right (Just identity)
        | identity == wallObjectIdentity object -> Right ()
        | otherwise ->
            Left
              ( HostWallConflict
                  (TargetReplaced (wallObjectIdentity object) identity)
              )

-- Clause 2: the durable journal ----------------------------------------------

windowsJournalLoad :: FilePath -> IO (Either HostWallError (Maybe ByteString))
windowsJournalLoad path = do
  loaded <- readFileBytes path
  pure $
    case loaded of
      Left err -> Left err
      Right Nothing -> Right Nothing
      Right (Just bytes)
        | ByteString.null bytes -> Right Nothing
        | otherwise -> Right (Just bytes)

windowsJournalStore :: FilePath -> ByteString -> IO (Either HostWallError ())
windowsJournalStore = replaceFileBytes

windowsJournalDeleteIfEqual ::
  FilePath ->
  ByteString ->
  IO (Either HostWallError Bool)
windowsJournalDeleteIfEqual path expected = do
  loaded <- windowsJournalLoad path
  case loaded of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right False)
    Right (Just bytes)
      | bytes /= expected -> pure (Right False)
      | otherwise -> do
          deleted <- withTString path c_DeleteFile
          if deleted
            then pure (Right True)
            else do
              status <- getLastError
              pure $
                if status == errorFileNotFound
                  then Right True
                  else
                    Left
                      ( HostWallNativeFailure
                          ("clear the wall journal " ++ path)
                          status
                      )

windowsAllocateFence :: FilePath -> IO (Either HostWallError Word64)
windowsAllocateFence path = do
  loaded <- readFileBytes path
  case loaded of
    Left err -> pure (Left err)
    Right existing ->
      case decodeFence existing of
        Left err -> pure (Left err)
        Right current -> do
          let next = current + 1
          stored <- replaceFileBytes path (encodeDecimal next)
          pure (stored >> Right next)

encodeDecimal :: Word64 -> ByteString
encodeDecimal =
  LazyByteString.toStrict . Builder.toLazyByteString . Builder.word64Dec

decodeFence :: Maybe ByteString -> Either HostWallError Word64
decodeFence Nothing = Right 0
decodeFence (Just bytes)
  | ByteString.null digits = Right 0
  | ByteString.all isDigitByte digits =
      Right (ByteString.foldl' accumulate 0 digits)
  | otherwise =
      Left
        (HostWallJournalFailure "the wall fence counter is not a decimal integer")
  where
    digits = ByteString.takeWhile (/= 10) bytes
    isDigitByte byte = byte >= 48 && byte <= 57
    accumulate total byte = total * 10 + fromIntegral (byte - 48)

readFileBytes :: FilePath -> IO (Either HostWallError (Maybe ByteString))
readFileBytes path = do
  opened <-
    openHandle
      path
      gENERIC_READ
      (fILE_SHARE_READ .|. fILE_SHARE_DELETE)
      oPEN_EXISTING
      fILE_ATTRIBUTE_NORMAL
  case opened of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right Nothing)
    Right (Just handle) -> do
      described <- handleInformation path handle
      case described of
        Left err -> do
          void (c_CloseHandle handle)
          pure (Left err)
        Right information
          | bhfiSize information > fromIntegral maximumWallBytes -> do
              void (c_CloseHandle handle)
              pure
                ( Left
                    ( HostWallUnsupported
                        (path ++ " exceeds the 16 MiB adapter limit")
                    )
                )
          | otherwise -> do
              contents <-
                readWholeHandle path handle (fromIntegral (bhfiSize information))
              void (c_CloseHandle handle)
              pure (Just <$> contents)

replaceFileBytes :: FilePath -> ByteString -> IO (Either HostWallError ())
replaceFileBytes path bytes = do
  let staging = path ++ ".writing"
  void (withTString staging c_DeleteFile)
  opened <-
    openHandle
      staging
      (gENERIC_READ .|. gENERIC_WRITE .|. dELETE)
      (fILE_SHARE_READ .|. fILE_SHARE_DELETE)
      cREATE_NEW
      fILE_ATTRIBUTE_NORMAL
  case opened of
    Left err -> pure (Left err)
    Right Nothing ->
      pure
        ( Left
            ( HostWallNativeFailure
                ("create " ++ staging)
                errorFileExists
            )
        )
    Right (Just handle) -> do
      written <- writeWholeHandle staging handle bytes
      closed <- c_CloseHandle handle
      case written of
        Left err -> pure (Left err)
        Right ()
          | not closed ->
              pure
                ( Left
                    ( HostWallNativeFailure
                        ("close " ++ staging)
                        errorInvalidData
                    )
                )
          | otherwise -> do
              -- The journal name is ours, so a replacing move is correct here;
              -- only the .wslconfig namespace requires no-replace semantics.
              moved <-
                withTString staging $ \wideStaging ->
                  withTString path $ \widePath ->
                    c_MoveFileEx
                      wideStaging
                      widePath
                      (mOVEFILE_REPLACE_EXISTING .|. mOVEFILE_WRITE_THROUGH)
              if moved
                then pure (Right ())
                else do
                  status <- getLastError
                  pure
                    ( Left
                        ( HostWallNativeFailure
                            ("publish " ++ path)
                            status
                        )
                    )

-- Raw handle helpers ----------------------------------------------------------

openHandle ::
  FilePath ->
  Word32 ->
  Word32 ->
  Word32 ->
  Word32 ->
  IO (Either HostWallError (Maybe HANDLE))
openHandle path access share creation flags = do
  handle <-
    withTString path $ \widePath ->
      c_CreateFile
        widePath
        access
        share
        nullPtr
        creation
        flags
        nullPtr
  if handle /= iNVALID_HANDLE_VALUE
    then pure (Right (Just handle))
    else do
      status <- getLastError
      pure $
        if status == errorFileNotFound || status == errorPathNotFound
          then Right Nothing
          else Left (HostWallNativeFailure ("open " ++ path) status)

handleInformation ::
  FilePath ->
  HANDLE ->
  IO (Either HostWallError BY_HANDLE_FILE_INFORMATION)
handleInformation path handle =
  alloca $ \buffer -> do
    described <- c_GetFileInformationByHandle handle buffer
    if described
      then Right <$> peek buffer
      else do
        status <- getLastError
        pure (Left (HostWallNativeFailure ("stat " ++ path) status))

isNonRegular :: BY_HANDLE_FILE_INFORMATION -> Bool
isNonRegular information =
  bhfiFileAttributes information
    .&. (fILE_ATTRIBUTE_DIRECTORY .|. fILE_ATTRIBUTE_REPARSE_POINT)
    /= 0

readWholeHandle ::
  FilePath ->
  HANDLE ->
  Int ->
  IO (Either HostWallError ByteString)
readWholeHandle _ _ size
  | size <= 0 = pure (Right ByteString.empty)
readWholeHandle path handle size = do
  positioned <-
    alloca $ \position ->
      c_SetFilePointerEx handle 0 position fILE_BEGIN
  if not positioned
    then do
      status <- getLastError
      pure (Left (HostWallNativeFailure ("seek " ++ path) status))
    else allocaBytes size $ \buffer ->
      let go offset
            | offset >= size =
                Right <$> ByteString.packCStringLen (castPtr buffer, size)
            | otherwise =
                alloca $ \counted -> do
                  ok <-
                    c_ReadFile
                      handle
                      (buffer `plusPtr` offset)
                      (fromIntegral (size - offset))
                      counted
                      nullPtr
                  if not ok
                    then do
                      status <- getLastError
                      pure
                        (Left (HostWallNativeFailure ("read " ++ path) status))
                    else do
                      read' <- peek counted
                      if read' == 0
                        then
                          Right
                            <$> ByteString.packCStringLen (castPtr buffer, offset)
                        else go (offset + fromIntegral read')
       in go 0

writeWholeHandle ::
  FilePath ->
  HANDLE ->
  ByteString ->
  IO (Either HostWallError ())
writeWholeHandle path handle bytes =
  ByteString.useAsCStringLen bytes $ \(pointer, size) ->
    let go offset
          | offset >= size = do
              flushed <- c_FlushFileBuffers handle
              if flushed
                then pure (Right ())
                else do
                  status <- getLastError
                  pure (Left (HostWallNativeFailure ("flush " ++ path) status))
          | otherwise =
              alloca $ \counted -> do
                ok <-
                  c_WriteFile
                    handle
                    (castPtr pointer `plusPtr` offset)
                    (fromIntegral (size - offset))
                    counted
                    nullPtr
                if not ok
                  then do
                    status <- getLastError
                    pure
                      (Left (HostWallNativeFailure ("write " ++ path) status))
                  else do
                    written <- peek counted
                    if written == 0
                      then
                        pure
                          ( Left
                              ( HostWallNativeFailure
                                  ("write " ++ path)
                                  errorWriteFault
                              )
                          )
                      else go (offset + fromIntegral written)
     in go 0

-- Identity and status classification -----------------------------------------

{- | The volume serial number first, then the file index, matching the
volume-first layout the POSIX lane produces so the driver's shared-volume check
is platform-neutral.
-}
identityOf ::
  BY_HANDLE_FILE_INFORMATION ->
  Either HostWallError FileIdentity
identityOf information =
  case mkFileIdentity encoded of
    Left err -> Left (HostWallModelFailure err)
    Right identity -> Right identity
  where
    encoded =
      LazyByteString.toStrict . Builder.toLazyByteString $
        Builder.word64LE (fromIntegral (bhfiVolumeSerialNumber information))
          <> Builder.word64LE (bhfiFileIndex information)

windowsIsContendedFailure :: Word32 -> Bool
windowsIsContendedFailure status =
  status
    `elem` [ errorLockViolation,
             errorSharingViolation,
             errorBusy,
             errorIoPending
           ]

windowsIsSharingFailure :: Word32 -> Bool
windowsIsSharingFailure status =
  status `elem` [errorSharingViolation, errorLockViolation]

windowsIsRaceFailure :: Word32 -> Bool
windowsIsRaceFailure status =
  windowsIsSharingFailure status
    || status
      `elem` [errorBusy, errorFileExists, errorAlreadyExists, errorFileNotFound]

windowsIsHardLinkUnsupported :: Word32 -> Bool
windowsIsHardLinkUnsupported status =
  status
    `elem` [ errorInvalidFunction,
             errorNotSameDevice,
             errorNotSupported
           ]

errorInvalidFunction, errorFileNotFound, errorPathNotFound :: Word32
errorInvalidFunction = 1
errorFileNotFound = 2
errorPathNotFound = 3

errorInvalidData, errorBusy, errorSharingViolation :: Word32
errorInvalidData = 13
errorBusy = 170
errorSharingViolation = 32

errorLockViolation, errorNotSameDevice, errorWriteFault :: Word32
errorLockViolation = 33
errorNotSameDevice = 17
errorWriteFault = 29

errorNotSupported, errorFileExists, errorAlreadyExists, errorIoPending :: Word32
errorNotSupported = 50
errorFileExists = 80
errorAlreadyExists = 183
errorIoPending = 997

mOVEFILE_REPLACE_EXISTING, mOVEFILE_WRITE_THROUGH :: Word32
mOVEFILE_REPLACE_EXISTING = 0x1
mOVEFILE_WRITE_THROUGH = 0x8

#endif
