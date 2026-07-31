{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | POSIX backend for the portable host wall
('HostBootstrap.Wsl2.GlobalWall.Host').

WSL itself only exists on Windows, so this backend is not a production WSL
lane.  It is the portable implementation of the same four ownership clauses,
which makes the complete recovery driver — every phase, conflict, and
crash-resume branch — executable against a real kernel on every POSIX host the
suite runs on, rather than only on a native Windows gate.

Clause mapping:

* clause 1 — an @fcntl@ write lock on a state-directory lock file, released by
  the kernel when the holding process dies, plus an in-process 'MVar' because
  POSIX record locks are per-process rather than per-thread;
* clause 2 — the durable origin record is a journal file replaced atomically
  (write temporary, @fsync@, rename) before the first mutation, alongside a
  strictly monotonic fence counter that is never reused;
* clause 3 — identity is @device:inode@ read from the open descriptor, encoded
  volume-word first so the driver's shared-volume check works unchanged;
* clause 4 — every removal re-observes the path's identity under the same lock
  and refuses a replacement.
-}
module HostBootstrap.Wsl2.GlobalWall.Posix
  ( PosixWallLocation (..),
    PosixWallHandle,
    newPosixHostWallBackend,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (onException)
import Control.Monad (void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Word (Word32, Word64)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (castPtr, plusPtr)
import GHC.Clock (getMonotonicTime)
import Foreign.C.Error
  ( Errno (Errno),
    eACCES,
    eAGAIN,
    eBUSY,
    eEXIST,
    eLOOP,
    eMLINK,
    eNOENT,
    eNOTSUP,
    ePERM,
    eXDEV,
  )
import GHC.IO.Exception (IOException (ioe_errno))
import HostBootstrap.Wsl2.GlobalWall
  ( FileIdentity,
    WallConflict (TargetReplaced, UnexpectedTargetAbsent, UnexpectedTargetPresent),
    mkFileIdentity,
  )
import HostBootstrap.Wsl2.GlobalWall.Host
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Error (isDoesNotExistError, tryIOError)
import System.Posix.Files
  ( createLink,
    deviceID,
    fileID,
    fileSize,
    getFdStatus,
    getSymbolicLinkStatus,
    isDirectory,
    isRegularFile,
    isSymbolicLink,
    removeLink,
    rename,
  )
import System.Posix.IO
  ( LockRequest (Unlock, WriteLock),
    OpenFileFlags (cloexec, creat, exclusive, nofollow),
    OpenMode (ReadOnly, ReadWrite),
    closeFd,
    defaultFileFlags,
    fdReadBuf,
    fdWriteBuf,
    openFd,
    setLock,
  )
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)

-- | Where the POSIX lane keeps the managed target and its durable state. The
-- target is supplied by the caller that constructed the backend, never by the
-- wall request.
data PosixWallLocation = PosixWallLocation
  { posixWallTargetPath :: FilePath,
    posixWallStateDirectory :: FilePath
  }
  deriving (Eq, Show)

-- | An open POSIX object. The path is retained because POSIX namespace
-- operations are path-based; every one of them re-checks the recorded identity
-- before it acts.
data PosixWallHandle = PosixWallHandle
  { posixHandleFd :: Fd,
    posixHandlePath :: FilePath
  }

-- | Build the POSIX backend and create its state directory. The returned
-- backend owns a private in-process mutex, so two backends over the same
-- location still exclude one another only through the kernel lock.
newPosixHostWallBackend ::
  PosixWallLocation ->
  IO (HostWallBackend PosixWallHandle)
newPosixHostWallBackend location = do
  createDirectoryIfMissing True (posixWallStateDirectory location)
  guard <- newMVar ()
  pure
    HostWallBackend
      { wallBackendName = "posix",
        wallTargetPath = pure (Right (posixWallTargetPath location)),
        wallWithExclusiveEntry = posixExclusiveEntry guard (lockPath location),
        wallOpenExclusive = posixOpenExclusive,
        wallProbeIdentity = posixProbeIdentity,
        wallCreateArmedStage = posixCreateArmedStage,
        wallLinkArmedStage = posixLinkArmedStage,
        wallRenameNoReplace = posixRenameNoReplace,
        wallDeleteObject = posixDeleteObject,
        wallCloseObject = posixCloseObject,
        wallArmedStageIsVolatile = False,
        wallIsSharingFailure = const False,
        wallIsRaceFailure = posixIsRaceFailure,
        wallIsHardLinkUnsupported = posixIsHardLinkUnsupported,
        wallJournalLoad = posixJournalLoad (recordPath location),
        wallJournalAllocateFence = posixAllocateFence (fencePath location),
        wallJournalStore = posixJournalStore (recordPath location),
        wallJournalDeleteIfEqual = posixJournalDeleteIfEqual (recordPath location)
      }

lockPath :: PosixWallLocation -> FilePath
lockPath location = posixWallStateDirectory location </> "global-wall.lock"

recordPath :: PosixWallLocation -> FilePath
recordPath location = posixWallStateDirectory location </> "global-wall.record"

fencePath :: PosixWallLocation -> FilePath
fencePath location = posixWallStateDirectory location </> "global-wall.fence"

-- Clause 1 -------------------------------------------------------------------

{- | POSIX record locks are owned by the process, not the thread, so two
threads in one process would not exclude each other.  The in-process mutex
closes that gap; the kernel lock closes the cross-process one and is released
by the kernel on abnormal termination.
-}
posixExclusiveEntry ::
  MVar () ->
  FilePath ->
  IO (Either HostWallError result) ->
  IO (Either HostWallError result)
posixExclusiveEntry guard path action =
  withMVar guard $ \() -> do
    opened <-
      tryIOError
        ( openFd
            path
            ReadWrite
            defaultFileFlags {creat = Just 0o600, cloexec = True}
        )
    case opened of
      Left err ->
        pure (Left (nativeFailure ("open the global wall lock " ++ path) err))
      Right fd -> do
        acquired <- acquireWriteLock fd
        case acquired of
          Left err -> do
            void (tryIOError (closeFd fd))
            pure (Left err)
          Right () -> do
            result <- action `onException` releaseLock fd
            released <- releaseLock fd
            pure $
              case (result, released) of
                (Left err, _) -> Left err
                (Right _, Left err) -> Left err
                (Right value, Right ()) -> Right value

lockWaitSeconds :: Double
lockWaitSeconds = 30

acquireWriteLock :: Fd -> IO (Either HostWallError ())
acquireWriteLock fd = do
  started <- getMonotonicTime
  go started
  where
    go started = do
      attempt <- tryIOError (setLock fd (WriteLock, AbsoluteSeek, 0, 0))
      case attempt of
        Right () -> pure (Right ())
        Left err -> do
          now <- getMonotonicTime
          if not (posixIsContendedFailure (nativeErrno err))
            then
              pure
                ( Left
                    (nativeFailure "acquire the per-user global wall lock" err)
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

releaseLock :: Fd -> IO (Either HostWallError ())
releaseLock fd = do
  unlocked <- tryIOError (setLock fd (Unlock, AbsoluteSeek, 0, 0))
  closed <- tryIOError (closeFd fd)
  pure $
    case (unlocked, closed) of
      (Left err, _) ->
        Left (nativeFailure "release the per-user global wall lock" err)
      (_, Left err) ->
        Left (nativeFailure "close the per-user global wall lock" err)
      _ -> Right ()

-- Clause 3: exact observation ------------------------------------------------

posixOpenExclusive ::
  FilePath ->
  IO (Either HostWallError (Maybe (WallObject PosixWallHandle)))
posixOpenExclusive path = do
  opened <-
    tryIOError
      ( openFd
          path
          ReadOnly
          defaultFileFlags {nofollow = True, cloexec = True}
      )
  case opened of
    Left err
      | isDoesNotExistError err -> pure (Right Nothing)
      | isErrno (nativeErrno err) eLOOP ->
          pure
            ( Left
                ( HostWallUnsupported
                    ("refusing to observe the symbolic link at " ++ path)
                )
            )
      | otherwise -> pure (Left (nativeFailure ("open " ++ path) err))
    Right fd -> do
      described <- tryIOError (getFdStatus fd)
      case described of
        Left err -> do
          void (tryIOError (closeFd fd))
          pure (Left (nativeFailure ("stat " ++ path) err))
        Right status
          | isDirectory status -> do
              void (tryIOError (closeFd fd))
              pure
                ( Left
                    ( HostWallUnsupported
                        ("refusing to observe the directory at " ++ path)
                    )
                )
          | not (isRegularFile status) -> do
              void (tryIOError (closeFd fd))
              pure
                ( Left
                    ( HostWallUnsupported
                        ("refusing to observe the non-regular file at " ++ path)
                    )
                )
          | fromIntegral (fileSize status) > maximumWallBytes -> do
              void (tryIOError (closeFd fd))
              pure
                ( Left
                    ( HostWallUnsupported
                        (path ++ " exceeds the 16 MiB adapter limit")
                    )
                )
          | otherwise -> do
              contents <- readWholeFd fd (fromIntegral (fileSize status))
              case contents of
                Left err -> do
                  void (tryIOError (closeFd fd))
                  pure (Left (nativeFailure ("read " ++ path) err))
                Right bytes ->
                  case identityOf (deviceID status) (fileID status) of
                    Left err -> do
                      void (tryIOError (closeFd fd))
                      pure (Left err)
                    Right identity ->
                      pure
                        ( Right
                            ( Just
                                WallObject
                                  { wallObjectHandle =
                                      PosixWallHandle
                                        { posixHandleFd = fd,
                                          posixHandlePath = path
                                        },
                                    wallObjectIdentity = identity,
                                    wallObjectBytes = bytes
                                  }
                            )
                        )

posixProbeIdentity ::
  FilePath ->
  IO (Either HostWallError (Maybe FileIdentity))
posixProbeIdentity path = do
  described <- tryIOError (getSymbolicLinkStatus path)
  pure $
    case described of
      Left err
        | isDoesNotExistError err -> Right Nothing
        | otherwise -> Left (nativeFailure ("probe identity of " ++ path) err)
      Right status
        | isSymbolicLink status || isDirectory status ->
            Left
              ( HostWallUnsupported
                  ( "identity probing refused a directory or symbolic link at "
                      ++ path
                  )
              )
        | otherwise ->
            Just <$> identityOf (deviceID status) (fileID status)

posixCreateArmedStage ::
  FilePath ->
  ByteString ->
  IO (Either HostWallError (WallObject PosixWallHandle))
posixCreateArmedStage path bytes = do
  opened <-
    tryIOError
      ( openFd
          path
          ReadWrite
          defaultFileFlags
            { creat = Just 0o600,
              exclusive = True,
              nofollow = True,
              cloexec = True
            }
      )
  case opened of
    Left err ->
      pure (Left (nativeFailure ("create armed stage " ++ path) err))
    Right fd -> do
      written <- writeWholeFd fd bytes
      case written of
        Left err -> do
          void (tryIOError (closeFd fd))
          pure (Left (nativeFailure ("write armed stage " ++ path) err))
        Right () -> do
          described <- tryIOError (getFdStatus fd)
          case described of
            Left err -> do
              void (tryIOError (closeFd fd))
              pure (Left (nativeFailure ("stat armed stage " ++ path) err))
            Right status ->
              case identityOf (deviceID status) (fileID status) of
                Left err -> do
                  void (tryIOError (closeFd fd))
                  pure (Left err)
                Right identity ->
                  pure
                    ( Right
                        WallObject
                          { wallObjectHandle =
                              PosixWallHandle
                                { posixHandleFd = fd,
                                  posixHandlePath = path
                                },
                            wallObjectIdentity = identity,
                            wallObjectBytes = bytes
                          }
                    )

-- Clause 4: identity-conditional namespace operations ------------------------

{- | @link(2)@ fails when the destination exists, so it is the no-replace
publication primitive on POSIX. The source is re-observed first: a link from a
replaced source would publish someone else's bytes under our journalled
identity.
-}
posixLinkArmedStage ::
  WallObject PosixWallHandle ->
  FilePath ->
  FilePath ->
  IO (Either HostWallError ())
posixLinkArmedStage object armed bound = do
  confirmed <- confirmPathIdentity object armed
  case confirmed of
    Left err -> pure (Left err)
    Right () -> do
      linked <- tryIOError (createLink armed bound)
      pure $
        case linked of
          Left err ->
            Left (nativeFailure ("hard link " ++ armed ++ " to " ++ bound) err)
          Right () -> Right ()

{- | A no-replace move is @link@ then identity-conditional @unlink@ of the
source. A bare @rename(2)@ would silently replace the destination, which the
driver's ownership arithmetic must never do.
-}
posixRenameNoReplace ::
  WallObject PosixWallHandle ->
  FilePath ->
  IO (Either HostWallError ())
posixRenameNoReplace object destination = do
  let source = posixHandlePath (wallObjectHandle object)
  confirmed <- confirmPathIdentity object source
  case confirmed of
    Left err -> pure (Left err)
    Right () -> do
      linked <- tryIOError (createLink source destination)
      case linked of
        Left err ->
          pure
            ( Left
                (nativeFailure ("no-replace rename to " ++ destination) err)
            )
        Right () -> do
          published <- posixProbeIdentity destination
          case published of
            Left err -> pure (Left err)
            Right (Just identity)
              | identity /= wallObjectIdentity object ->
                  pure
                    ( Left
                        (HostWallConflict (UnexpectedTargetPresent identity))
                    )
            Right _ -> do
              unlinked <- tryIOError (removeLink source)
              pure $
                case unlinked of
                  Left err
                    | isDoesNotExistError err -> Right ()
                    | otherwise ->
                        Left (nativeFailure ("unlink " ++ source) err)
                  Right () -> Right ()

posixDeleteObject ::
  WallObject PosixWallHandle ->
  IO (Either HostWallError ())
posixDeleteObject object = do
  let path = posixHandlePath (wallObjectHandle object)
  confirmed <- confirmPathIdentity object path
  case confirmed of
    Left err -> pure (Left err)
    Right () -> do
      unlinked <- tryIOError (removeLink path)
      pure $
        case unlinked of
          Left err
            | isDoesNotExistError err -> Right ()
            | otherwise -> Left (nativeFailure ("unlink " ++ path) err)
          Right () -> Right ()

posixCloseObject :: WallObject PosixWallHandle -> IO (Either HostWallError ())
posixCloseObject object = do
  closed <- tryIOError (closeFd (posixHandleFd (wallObjectHandle object)))
  pure $
    case closed of
      Left err -> Left (nativeFailure "close an exact file handle" err)
      Right () -> Right ()

{- | Clause 4 in one place: a namespace operation acts only while the name
still denotes the exact object that was observed under this lock.
-}
confirmPathIdentity ::
  WallObject PosixWallHandle ->
  FilePath ->
  IO (Either HostWallError ())
confirmPathIdentity object path = do
  observed <- posixProbeIdentity path
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

posixJournalLoad :: FilePath -> IO (Either HostWallError (Maybe ByteString))
posixJournalLoad path = do
  loaded <- readFileBytes path
  pure $
    case loaded of
      Left err -> Left err
      Right Nothing -> Right Nothing
      Right (Just bytes)
        | ByteString.null bytes -> Right Nothing
        | otherwise -> Right (Just bytes)

posixJournalStore :: FilePath -> ByteString -> IO (Either HostWallError ())
posixJournalStore path = replaceFileBytes path

posixJournalDeleteIfEqual ::
  FilePath ->
  ByteString ->
  IO (Either HostWallError Bool)
posixJournalDeleteIfEqual path expected = do
  loaded <- posixJournalLoad path
  case loaded of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right False)
    Right (Just bytes)
      | bytes /= expected -> pure (Right False)
      | otherwise -> do
          removed <- tryIOError (removeLink path)
          pure $
            case removed of
              Left err
                | isDoesNotExistError err -> Right True
                | otherwise ->
                    Left (nativeFailure ("clear the wall journal " ++ path) err)
              Right () -> Right True

{- | A strictly monotonic, never-reused fence. It is flushed before it is
returned, so a crash can only skip values, never repeat one.
-}
posixAllocateFence :: FilePath -> IO (Either HostWallError Word64)
posixAllocateFence path = do
  loaded <- readFileBytes path
  case loaded of
    Left err -> pure (Left err)
    Right existing ->
      case decodeFence existing of
        Left err -> pure (Left err)
        Right current -> do
          let next = current + 1
          stored <-
            replaceFileBytes path (ByteStringChar8.pack (show next))
          pure (stored >> Right next)

decodeFence :: Maybe ByteString -> Either HostWallError Word64
decodeFence Nothing = Right 0
decodeFence (Just bytes)
  | ByteString.null trimmed = Right 0
  | otherwise =
      case ByteStringChar8.readInteger trimmed of
        Just (value, rest)
          | ByteString.null rest && value >= 0 && value <= fromIntegral (maxBound :: Word64) ->
              Right (fromIntegral value)
        _ ->
          Left
            (HostWallJournalFailure "the wall fence counter is not a decimal integer")
  where
    trimmed = ByteStringChar8.takeWhile (/= '\n') bytes

readFileBytes :: FilePath -> IO (Either HostWallError (Maybe ByteString))
readFileBytes path = do
  opened <-
    tryIOError
      (openFd path ReadOnly defaultFileFlags {nofollow = True, cloexec = True})
  case opened of
    Left err
      | isDoesNotExistError err -> pure (Right Nothing)
      | otherwise -> pure (Left (nativeFailure ("open " ++ path) err))
    Right fd -> do
      described <- tryIOError (getFdStatus fd)
      case described of
        Left err -> do
          void (tryIOError (closeFd fd))
          pure (Left (nativeFailure ("stat " ++ path) err))
        Right status
          | fromIntegral (fileSize status) > maximumWallBytes -> do
              void (tryIOError (closeFd fd))
              pure
                ( Left
                    ( HostWallUnsupported
                        (path ++ " exceeds the 16 MiB adapter limit")
                    )
                )
          | otherwise -> do
              contents <- readWholeFd fd (fromIntegral (fileSize status))
              void (tryIOError (closeFd fd))
              pure $
                case contents of
                  Left err -> Left (nativeFailure ("read " ++ path) err)
                  Right bytes -> Right (Just bytes)

{- | Replace a state file atomically: write a private temporary, flush it, then
rename it over the destination. @rename(2)@ is the intended replacement here —
this is our own journal name, not the ownership-sensitive @.wslconfig@
namespace.
-}
replaceFileBytes :: FilePath -> ByteString -> IO (Either HostWallError ())
replaceFileBytes path bytes = do
  let staging = path ++ ".writing"
  void (tryIOError (removeLink staging))
  opened <-
    tryIOError
      ( openFd
          staging
          ReadWrite
          defaultFileFlags
            { creat = Just 0o600,
              exclusive = True,
              nofollow = True,
              cloexec = True
            }
      )
  case opened of
    Left err ->
      pure (Left (nativeFailure ("create " ++ staging) err))
    Right fd -> do
      written <- writeWholeFd fd bytes
      closed <- tryIOError (closeFd fd)
      case (written, closed) of
        (Left err, _) ->
          pure (Left (nativeFailure ("write " ++ staging) err))
        (_, Left err) ->
          pure (Left (nativeFailure ("close " ++ staging) err))
        (Right (), Right ()) -> do
          renamed <- tryIOError (rename staging path)
          pure $
            case renamed of
              Left err -> Left (nativeFailure ("publish " ++ path) err)
              Right () -> Right ()

-- Raw descriptor helpers ------------------------------------------------------

readWholeFd :: Fd -> Int -> IO (Either IOException ByteString)
readWholeFd _ size
  | size <= 0 = pure (Right ByteString.empty)
readWholeFd fd size =
  tryIOError
    ( allocaBytes size $ \buffer ->
        let go offset
              | offset >= size =
                  ByteString.packCStringLen (castPtr buffer, size)
              | otherwise = do
                  read' <-
                    fdReadBuf
                      fd
                      (buffer `plusPtr` offset)
                      (fromIntegral (size - offset))
                  if read' == 0
                    then ByteString.packCStringLen (castPtr buffer, offset)
                    else go (offset + fromIntegral read')
         in go 0
    )

writeWholeFd :: Fd -> ByteString -> IO (Either IOException ())
writeWholeFd fd bytes =
  tryIOError
    ( ByteString.useAsCStringLen bytes $ \(pointer, size) ->
        let go offset
              | offset >= size = fileSynchronise fd
              | otherwise = do
                  written <-
                    fdWriteBuf
                      fd
                      (castPtr pointer `plusPtr` offset)
                      (fromIntegral (size - offset))
                  if written == 0
                    then
                      ioErrorShortWrite
                    else go (offset + fromIntegral written)
         in go 0
    )

ioErrorShortWrite :: IO ()
ioErrorShortWrite = ioError (userError "short write to a wall state file")

-- Identity and status classification -----------------------------------------

{- | @device:inode@ with the device word first, matching the volume-first
layout of Windows @FILE_ID_INFO@ so the driver's shared-volume check is
platform-neutral.
-}
identityOf ::
  (Integral device, Integral inode) =>
  device ->
  inode ->
  Either HostWallError FileIdentity
identityOf device inode =
  case mkFileIdentity encoded of
    Left err -> Left (HostWallModelFailure err)
    Right identity -> Right identity
  where
    encoded =
      LazyByteString.toStrict . Builder.toLazyByteString $
        Builder.word64LE (fromIntegral device)
          <> Builder.word64LE (fromIntegral inode)

nativeFailure :: String -> IOException -> HostWallError
nativeFailure operation err = HostWallNativeFailure operation (nativeErrno err)

nativeErrno :: IOException -> Word32
nativeErrno err = maybe 0 fromIntegral (ioe_errno err)

posixIsContendedFailure :: Word32 -> Bool
posixIsContendedFailure status = any (isErrno status) [eACCES, eAGAIN]

posixIsRaceFailure :: Word32 -> Bool
posixIsRaceFailure status =
  any (isErrno status) [eEXIST, eNOENT, eAGAIN, eBUSY]

posixIsHardLinkUnsupported :: Word32 -> Bool
posixIsHardLinkUnsupported status =
  any (isErrno status) [ePERM, eXDEV, eMLINK, eNOTSUP]

-- | Compare a captured @errno@ against a platform-supplied constant rather
-- than a hard-coded Linux number, because the same name has different values
-- on Linux and Apple hosts.
isErrno :: Word32 -> Errno -> Bool
isErrno status (Errno value) = status == fromIntegral value
