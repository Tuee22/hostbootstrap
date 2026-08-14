module HostBootstrap.Ensure.Colima.Backend.Internal
  ( AcquireBackendRequest (..),
    AcquireBackendCrashPoint (..),
    AcquireBackendResult (..),
    BackendNamespace (..),
    BackendIdentity (..),
    BackendDirectoryChain (..),
    BoundedToolResult (..),
    runBoundedTool,
    runAcquireBackend,
    CleanupBackendRequest (..),
    CleanupBackendCrashPoint (..),
    CleanupBackendResult (..),
    runCleanupBackend,
    LiveDockerBackendRequest (..),
    LiveDockerBackendResult (..),
    runLiveDockerBackend,
  )
where

import Data.List (intercalate, stripPrefix)
import Data.Word (Word64)
import HostBootstrap.Ensure.Colima.Backend.Runner
  ( BackendNamespace (..),
    BoundedProcessResult (..),
    BoundedToolResult (..),
    runBoundedPython,
    runBoundedTool,
    validNamespace,
  )
import HostBootstrap.Ensure.Colima.Backend.Program.Acquire (acquireProgram)
import HostBootstrap.Ensure.Colima.Backend.Program.Cleanup (cleanupProgram)
import HostBootstrap.Ensure.Colima.Backend.Program.LiveDocker
  ( liveDockerProgram,
    validLiveDockerArguments,
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

data AcquireBackendRequest = AcquireBackendRequest
  { acquirePythonPath :: FilePath,
    acquireColimaPath :: FilePath,
    acquireDockerPath :: FilePath,
    acquireLimaPath :: FilePath,
    acquireProfileName :: String,
    acquireLockPath :: FilePath,
    acquireStateRoot :: FilePath,
    acquireRecordPath :: FilePath,
    acquireNamespace :: BackendNamespace,
    acquireExpectedOwner :: String,
    acquireInvocationDigest :: String,
    acquireExpectedCpu :: Integer,
    acquireExpectedMemory :: Integer,
    acquireExpectedDisk :: Integer,
    acquireExpectedRootDisk :: Integer,
    acquireCommandTimeoutSeconds :: Int,
    acquireTestingCrashPoint :: Maybe AcquireBackendCrashPoint,
    acquireStartArgs :: [String]
  }

-- This fault seam is Cabal-private and has no public adapter projection.  It
-- exists solely to kill the owning backend at exact durable transition edges.
data AcquireBackendCrashPoint
  = CrashAfterHomeStageCreation
  | CrashAfterContextStageCreation
  | CrashWhileStartRunning
  | CrashAfterStartBeforeSettlement
  deriving (Eq, Show)

data AcquireBackendResult
  = AcquireApplied String String String String Word64 BackendIdentity BackendIdentity BackendIdentity BackendIdentity BackendIdentity BackendDirectoryChain
  | AcquireExact String String String String Word64 BackendIdentity BackendIdentity BackendIdentity BackendIdentity BackendIdentity BackendDirectoryChain
  | AcquireForeign Word64
  | AcquireConflict String
  | AcquireUnsupported String
  | AcquireFailed String
  deriving (Eq, Show)

runAcquireBackend :: AcquireBackendRequest -> IO AcquireBackendResult
runAcquireBackend request
  | not (validNamespace (acquireNamespace request)) =
      pure (AcquireUnsupported "namespace")
  | not (validOwner (acquireExpectedOwner request)) =
      pure (AcquireUnsupported "owner-token")
  | not (validNonce (acquireInvocationDigest request)) =
      pure (AcquireUnsupported "invocation-digest")
  | not (validCommandTimeout (acquireCommandTimeoutSeconds request)) =
      pure (AcquireUnsupported "command-timeout")
  | not
      ( all
          validPositiveInteger
          [ acquireExpectedCpu request,
            acquireExpectedMemory request,
            acquireExpectedDisk request,
            acquireExpectedRootDisk request
          ]
      ) =
      pure (AcquireUnsupported "wall")
  | otherwise = do
      raw <-
        runBoundedPython
          (acquireCommandTimeoutSeconds request)
          (acquireNamespace request)
          (acquirePythonPath request)
          ( [ "-c",
              acquireProgram,
              acquireColimaPath request,
              acquireDockerPath request,
              acquireLimaPath request,
              acquireProfileName request,
              acquireLockPath request,
              acquireStateRoot request,
              acquireRecordPath request,
              acquireExpectedOwner request,
              acquireInvocationDigest request,
              show (acquireExpectedCpu request),
              show (acquireExpectedMemory request),
              show (acquireExpectedDisk request),
              show (acquireExpectedRootDisk request),
              show (acquireCommandTimeoutSeconds request),
              renderAcquireCrashPoint (acquireTestingCrashPoint request)
            ]
              ++ acquireStartArgs request
          )
      pure (parseAcquireResult (acquireExpectedOwner request) raw)

renderAcquireCrashPoint :: Maybe AcquireBackendCrashPoint -> String
renderAcquireCrashPoint Nothing = "none"
renderAcquireCrashPoint (Just CrashAfterHomeStageCreation) = "after-home-stage"
renderAcquireCrashPoint (Just CrashAfterContextStageCreation) = "after-context-stage"
renderAcquireCrashPoint (Just CrashWhileStartRunning) = "during-start"
renderAcquireCrashPoint (Just CrashAfterStartBeforeSettlement) = "after-start"

data CleanupBackendRequest = CleanupBackendRequest
  { cleanupPythonPath :: FilePath,
    cleanupColimaPath :: FilePath,
    cleanupDockerPath :: FilePath,
    cleanupLimaPath :: FilePath,
    cleanupProfileName :: String,
    cleanupLockPath :: FilePath,
    cleanupStateRoot :: FilePath,
    cleanupRecordPath :: FilePath,
    cleanupNamespace :: BackendNamespace,
    cleanupExpectedOwner :: String,
    cleanupAcquireInvocationDigest :: String,
    cleanupInvocationDigest :: String,
    cleanupNonce :: String,
    cleanupExpectedMachineId :: String,
    cleanupExpectedContextDigest :: String,
    cleanupExpectedCpu :: Integer,
    cleanupExpectedMemory :: Integer,
    cleanupExpectedDisk :: Integer,
    cleanupExpectedRootDisk :: Integer,
    cleanupExpectedLockIdentity :: BackendIdentity,
    cleanupExpectedRecordIdentity :: BackendIdentity,
    cleanupExpectedDockerIdentity :: BackendIdentity,
    cleanupExpectedColimaIdentity :: BackendIdentity,
    cleanupExpectedDiskIdentity :: BackendIdentity,
    cleanupExpectedDirectoryChain :: BackendDirectoryChain,
    cleanupCommandTimeoutSeconds :: Int,
    cleanupExpectedEpoch :: Word64,
    cleanupTestingCrashPoint :: Maybe CleanupBackendCrashPoint
  }

data CleanupBackendCrashPoint
  = CrashAfterReleasedMarkerPublication
  deriving (Eq, Show)

data CleanupBackendResult
  = CleanupDeleted
  | CleanupReleased
  | CleanupConflict String
  | CleanupUnsupported String
  | CleanupFailed String
  deriving (Eq, Show)

runCleanupBackend :: CleanupBackendRequest -> IO CleanupBackendResult
runCleanupBackend request
  | not (validNamespace (cleanupNamespace request)) =
      pure (CleanupUnsupported "namespace")
  | not (validOwner (cleanupExpectedOwner request)) =
      pure (CleanupUnsupported "owner-token")
  | not (validNonce (cleanupAcquireInvocationDigest request))
      || not (validNonce (cleanupInvocationDigest request)) =
      pure (CleanupConflict "invocation-digest")
  | not (validNonce (directoryChainArtifactDigest (cleanupExpectedDirectoryChain request))) =
      pure (CleanupConflict "artifact-digest")
  | not (validNonce (cleanupNonce request))
      || not (validMachineId (cleanupExpectedMachineId request))
      || not (validNonce (cleanupExpectedContextDigest request)) =
      pure (CleanupConflict "authority-format")
  | not (validCommandTimeout (cleanupCommandTimeoutSeconds request)) =
      pure (CleanupUnsupported "command-timeout")
  | not
      ( all
          validPositiveInteger
          [ cleanupExpectedCpu request,
            cleanupExpectedMemory request,
            cleanupExpectedDisk request,
            cleanupExpectedRootDisk request
          ]
      ) =
      pure (CleanupConflict "wall")
  | otherwise = do
      raw <-
        runBoundedPython
          (cleanupCommandTimeoutSeconds request)
          (cleanupNamespace request)
          (cleanupPythonPath request)
          [ "-c",
            cleanupProgram,
            cleanupColimaPath request,
            cleanupDockerPath request,
            cleanupLimaPath request,
            cleanupProfileName request,
            cleanupLockPath request,
            cleanupStateRoot request,
            cleanupRecordPath request,
            cleanupExpectedOwner request,
            cleanupAcquireInvocationDigest request,
            cleanupInvocationDigest request,
            cleanupNonce request,
            cleanupExpectedMachineId request,
            cleanupExpectedContextDigest request,
            show (cleanupExpectedEpoch request),
            show (cleanupExpectedCpu request),
            show (cleanupExpectedMemory request),
            show (cleanupExpectedDisk request),
            show (cleanupExpectedRootDisk request),
            directoryChainArtifactDigest (cleanupExpectedDirectoryChain request),
            show (identityDevice (cleanupExpectedLockIdentity request)),
            show (identityInode (cleanupExpectedLockIdentity request)),
            show (identityDevice (cleanupExpectedRecordIdentity request)),
            show (identityInode (cleanupExpectedRecordIdentity request)),
            show (identityDevice (cleanupExpectedDockerIdentity request)),
            show (identityInode (cleanupExpectedDockerIdentity request)),
            show (identityDevice (cleanupExpectedColimaIdentity request)),
            show (identityInode (cleanupExpectedColimaIdentity request)),
            show (identityDevice (cleanupExpectedDiskIdentity request)),
            show (identityInode (cleanupExpectedDiskIdentity request)),
            renderDirectoryChain (cleanupExpectedDirectoryChain request),
            show (cleanupCommandTimeoutSeconds request),
            renderCleanupCrashPoint (cleanupTestingCrashPoint request)
          ]
      pure (parseCleanupResult raw)

renderCleanupCrashPoint :: Maybe CleanupBackendCrashPoint -> String
renderCleanupCrashPoint Nothing = "none"
renderCleanupCrashPoint (Just CrashAfterReleasedMarkerPublication) = "after-released-marker"

data LiveDockerBackendRequest = LiveDockerBackendRequest
  { liveDockerPythonPath :: FilePath,
    liveDockerColimaPath :: FilePath,
    liveDockerExecutablePath :: FilePath,
    liveDockerLimaPath :: FilePath,
    liveDockerProfileName :: String,
    liveDockerLockPath :: FilePath,
    liveDockerStateRoot :: FilePath,
    liveDockerRecordPath :: FilePath,
    liveDockerNamespace :: BackendNamespace,
    liveDockerExpectedOwner :: String,
    liveDockerInvocationDigest :: String,
    liveDockerNonce :: String,
    liveDockerExpectedMachineId :: String,
    liveDockerExpectedContextDigest :: String,
    liveDockerExpectedCpu :: Integer,
    liveDockerExpectedMemory :: Integer,
    liveDockerExpectedDisk :: Integer,
    liveDockerExpectedRootDisk :: Integer,
    liveDockerExpectedLockIdentity :: BackendIdentity,
    liveDockerExpectedRecordIdentity :: BackendIdentity,
    liveDockerExpectedDockerIdentity :: BackendIdentity,
    liveDockerExpectedColimaIdentity :: BackendIdentity,
    liveDockerExpectedDiskIdentity :: BackendIdentity,
    liveDockerExpectedDirectoryChain :: BackendDirectoryChain,
    liveDockerCommandTimeoutSeconds :: Int,
    liveDockerExpectedEpoch :: Word64,
    liveDockerArgs :: [String]
  }

data LiveDockerBackendResult
  = LiveDockerCompleted ExitCode String String
  | LiveDockerConflict String
  | LiveDockerUnsupported String
  | LiveDockerFailed String
  deriving (Eq, Show)

runLiveDockerBackend :: LiveDockerBackendRequest -> IO LiveDockerBackendResult
runLiveDockerBackend request
  | not (validNamespace (liveDockerNamespace request)) = pure (LiveDockerUnsupported "namespace")
  | not (validOwner (liveDockerExpectedOwner request)) = pure (LiveDockerUnsupported "owner-token")
  | not (validNonce (liveDockerInvocationDigest request)) = pure (LiveDockerConflict "invocation-digest")
  | not (validNonce (directoryChainArtifactDigest (liveDockerExpectedDirectoryChain request))) = pure (LiveDockerConflict "artifact-digest")
  | not (validNonce (liveDockerNonce request))
      || not (validMachineId (liveDockerExpectedMachineId request))
      || not (validNonce (liveDockerExpectedContextDigest request)) =
      pure (LiveDockerConflict "authority-format")
  | not (validLiveDockerArguments (liveDockerArgs request)) = pure (LiveDockerConflict "docker-routing-argument")
  | not (validCommandTimeout (liveDockerCommandTimeoutSeconds request)) = pure (LiveDockerUnsupported "command-timeout")
  | not
      ( all
          validPositiveInteger
          [ liveDockerExpectedCpu request,
            liveDockerExpectedMemory request,
            liveDockerExpectedDisk request,
            liveDockerExpectedRootDisk request
          ]
      ) =
      pure (LiveDockerConflict "wall")
  | otherwise = do
      raw <-
        runBoundedPython
          (liveDockerCommandTimeoutSeconds request)
          (liveDockerNamespace request)
          (liveDockerPythonPath request)
          ( [ "-c",
              liveDockerProgram,
              liveDockerColimaPath request,
              liveDockerExecutablePath request,
              liveDockerLimaPath request,
              liveDockerProfileName request,
              liveDockerLockPath request,
              liveDockerStateRoot request,
              liveDockerRecordPath request,
              liveDockerExpectedOwner request,
              liveDockerInvocationDigest request,
              liveDockerNonce request,
              liveDockerExpectedMachineId request,
              liveDockerExpectedContextDigest request,
              show (liveDockerExpectedEpoch request),
              show (liveDockerExpectedCpu request),
              show (liveDockerExpectedMemory request),
              show (liveDockerExpectedDisk request),
              show (liveDockerExpectedRootDisk request),
              directoryChainArtifactDigest (liveDockerExpectedDirectoryChain request),
              show (identityDevice (liveDockerExpectedLockIdentity request)),
              show (identityInode (liveDockerExpectedLockIdentity request)),
              show (identityDevice (liveDockerExpectedRecordIdentity request)),
              show (identityInode (liveDockerExpectedRecordIdentity request)),
              show (identityDevice (liveDockerExpectedDockerIdentity request)),
              show (identityInode (liveDockerExpectedDockerIdentity request)),
              show (identityDevice (liveDockerExpectedColimaIdentity request)),
              show (identityInode (liveDockerExpectedColimaIdentity request)),
              show (identityDevice (liveDockerExpectedDiskIdentity request)),
              show (identityInode (liveDockerExpectedDiskIdentity request)),
              renderDirectoryChain (liveDockerExpectedDirectoryChain request),
              show (liveDockerCommandTimeoutSeconds request)
            ]
              ++ liveDockerArgs request
          )
      pure (parseLiveDockerResult raw)

validCommandTimeout :: Int -> Bool
validCommandTimeout seconds = seconds > 0 && seconds <= maximumCommandTimeoutSeconds

maximumCommandTimeoutSeconds :: Int
maximumCommandTimeoutSeconds = 120

data BackendIdentity = BackendIdentity
  { identityDevice :: Word64,
    identityInode :: Word64
  }
  deriving (Eq, Show)

data BackendDirectoryChain = BackendDirectoryChain
  { directoryChainIdentities :: [BackendIdentity],
    directoryChainArtifactDigest :: String
  }
  deriving (Eq, Show)

renderDirectoryChain :: BackendDirectoryChain -> String
renderDirectoryChain (BackendDirectoryChain values _) =
  intercalate "," [show (identityDevice value) ++ ":" ++ show (identityInode value) | value <- values]

validOwner :: String -> Bool
validOwner value =
  length value <= 4096
    && case stripPrefix "v2-" value of
      Just fields ->
        case splitOwnerFields fields of
          [profile, project, lifecycle, digest, resource, frame, fence, colimaHome, dockerConfig, executablePath, toolProvenance] ->
            all validHex [profile, project, lifecycle, digest, resource, frame, colimaHome, dockerConfig, executablePath, toolProvenance]
              && maybe False (const True) (positiveWord64 fence)
          _ -> False
      Nothing -> False

splitOwnerFields :: String -> [String]
splitOwnerFields raw =
  case break (== '-') raw of
    (field, []) -> [field]
    (field, _separator : rest) -> field : splitOwnerFields rest

validHex :: String -> Bool
validHex value = not (null value) && all validHexCharacter value

validHexCharacter :: Char -> Bool
validHexCharacter character =
  (character >= '0' && character <= '9')
    || (character >= 'a' && character <= 'f')

parseAcquireResult :: String -> BoundedProcessResult -> AcquireBackendResult
parseAcquireResult owner raw =
  case strictProcessLine raw of
    Right line -> case words line of
      ["APPLIED", nonce, machineId, contextDigest, epochRaw, lockDeviceRaw, lockInodeRaw, recordDeviceRaw, recordInodeRaw, dockerDeviceRaw, dockerInodeRaw, colimaDeviceRaw, colimaInodeRaw, diskDeviceRaw, diskInodeRaw, artifactDigest, chainRaw]
        | validNonce nonce,
          validMachineId machineId,
          validNonce contextDigest,
          Just epoch <- positiveWord64 epochRaw,
          Just lockDevice <- word64 lockDeviceRaw,
          Just lockInode <- positiveWord64 lockInodeRaw,
          Just recordDevice <- word64 recordDeviceRaw,
          Just recordInode <- positiveWord64 recordInodeRaw,
          Just dockerDevice <- word64 dockerDeviceRaw,
          Just dockerInode <- positiveWord64 dockerInodeRaw,
          Just colimaDevice <- word64 colimaDeviceRaw,
          Just colimaInode <- positiveWord64 colimaInodeRaw,
          Just diskDevice <- word64 diskDeviceRaw,
          Just diskInode <- positiveWord64 diskInodeRaw,
          validNonce artifactDigest,
          Just directoryChain <- parseDirectoryChain artifactDigest chainRaw ->
            AcquireApplied
              owner
              nonce
              machineId
              contextDigest
              epoch
              (BackendIdentity lockDevice lockInode)
              (BackendIdentity recordDevice recordInode)
              (BackendIdentity dockerDevice dockerInode)
              (BackendIdentity colimaDevice colimaInode)
              (BackendIdentity diskDevice diskInode)
              directoryChain
      ["EXACT", nonce, machineId, contextDigest, epochRaw, lockDeviceRaw, lockInodeRaw, recordDeviceRaw, recordInodeRaw, dockerDeviceRaw, dockerInodeRaw, colimaDeviceRaw, colimaInodeRaw, diskDeviceRaw, diskInodeRaw, artifactDigest, chainRaw]
        | validNonce nonce,
          validMachineId machineId,
          validNonce contextDigest,
          Just epoch <- positiveWord64 epochRaw,
          Just lockDevice <- word64 lockDeviceRaw,
          Just lockInode <- positiveWord64 lockInodeRaw,
          Just recordDevice <- word64 recordDeviceRaw,
          Just recordInode <- positiveWord64 recordInodeRaw,
          Just dockerDevice <- word64 dockerDeviceRaw,
          Just dockerInode <- positiveWord64 dockerInodeRaw,
          Just colimaDevice <- word64 colimaDeviceRaw,
          Just colimaInode <- positiveWord64 colimaInodeRaw,
          Just diskDevice <- word64 diskDeviceRaw,
          Just diskInode <- positiveWord64 diskInodeRaw,
          validNonce artifactDigest,
          Just directoryChain <- parseDirectoryChain artifactDigest chainRaw ->
            AcquireExact
              owner
              nonce
              machineId
              contextDigest
              epoch
              (BackendIdentity lockDevice lockInode)
              (BackendIdentity recordDevice recordInode)
              (BackendIdentity dockerDevice dockerInode)
              (BackendIdentity colimaDevice colimaInode)
              (BackendIdentity diskDevice diskInode)
              directoryChain
      ["FOREIGN", epochRaw]
        | Just epoch <- positiveWord64 epochRaw -> AcquireForeign epoch
      ["CONFLICT", reason] -> AcquireConflict reason
      ["UNSUPPORTED", reason] -> AcquireUnsupported reason
      ["FAILED", stage] -> AcquireFailed stage
      _ -> malformed
    Left detail -> AcquireFailed detail
  where
    malformed = AcquireFailed "malformed-report"

parseCleanupResult :: BoundedProcessResult -> CleanupBackendResult
parseCleanupResult raw =
  case strictProcessLine raw of
    Right "DELETED" -> CleanupDeleted
    Right "RELEASED" -> CleanupReleased
    Right line -> case words line of
      ["CONFLICT", reason] -> CleanupConflict reason
      ["UNSUPPORTED", reason] -> CleanupUnsupported reason
      ["FAILED", stage] -> CleanupFailed stage
      _ -> CleanupFailed "malformed-report"
    Left detail -> CleanupFailed detail

parseLiveDockerResult :: BoundedProcessResult -> LiveDockerBackendResult
parseLiveDockerResult raw =
  case raw of
    BoundedProcessCompleted ExitSuccess out "" ->
      case break (== '\n') out of
        (header, _newline : payload) -> case words header of
          ["DOCKER", exitRaw, outLengthRaw, errLengthRaw]
            | Just exitCode <- processExitCode exitRaw,
              Just outLength <- naturalInt outLengthRaw,
              Just errLength <- naturalInt errLengthRaw,
              let (commandOut, remainder) = splitAt outLength payload,
              let (commandErr, extra) = splitAt errLength remainder,
              length commandOut == outLength,
              length commandErr == errLength,
              null extra -> LiveDockerCompleted exitCode commandOut commandErr
          ["CONFLICT", reason] | null payload -> LiveDockerConflict reason
          ["UNSUPPORTED", reason] | null payload -> LiveDockerUnsupported reason
          ["FAILED", stage] | null payload -> LiveDockerFailed stage
          _ -> LiveDockerFailed "malformed-report"
        _ -> LiveDockerFailed "malformed-report"
    BoundedProcessTimedOut -> LiveDockerFailed "backend-timeout"
    BoundedProcessOutputLimit -> LiveDockerFailed "backend-output-limit"
    BoundedProcessException _ -> LiveDockerFailed "backend-exception"
    BoundedProcessCompleted _ _ _ -> LiveDockerFailed "backend-process"

processExitCode :: String -> Maybe ExitCode
processExitCode raw = case (reads raw :: [(Int, String)]) of
  [(0, "")] -> Just ExitSuccess
  [(value, "")] | value /= 0 -> Just (ExitFailure value)
  _ -> Nothing

naturalInt :: String -> Maybe Int
naturalInt raw = case reads raw of
  [(value, "")] | value >= 0 -> Just value
  _ -> Nothing

parseDirectoryChain :: String -> String -> Maybe BackendDirectoryChain
parseDirectoryChain artifactDigest raw =
  case splitOnComma raw of
    [] -> Nothing
    parts -> BackendDirectoryChain <$> traverse parseIdentity parts <*> pure artifactDigest
  where
    parseIdentity value = case break (== ':') value of
      (deviceRaw, ':' : inodeRaw) ->
        BackendIdentity <$> word64 deviceRaw <*> positiveWord64 inodeRaw
      _ -> Nothing

splitOnComma :: String -> [String]
splitOnComma "" = []
splitOnComma value =
  case break (== ',') value of
    (part, []) -> [part]
    (part, _comma : rest) -> part : splitOnComma rest

strictProcessLine :: BoundedProcessResult -> Either String String
strictProcessLine raw = case raw of
  BoundedProcessTimedOut -> Left "backend-timeout"
  BoundedProcessOutputLimit -> Left "backend-output-limit"
  BoundedProcessException _ -> Left "backend-exception"
  BoundedProcessCompleted ExitSuccess out "" ->
    case break (== '\n') out of
      (line, "\n")
        | not (null line), not (any (== '\r') line) -> Right line
      _ -> Left "malformed-report"
  BoundedProcessCompleted _ _ _ -> Left "backend-process"

positiveWord64 :: String -> Maybe Word64
positiveWord64 raw = case reads raw of
  [(value, "")] | value > 0 -> Just value
  _ -> Nothing

word64 :: String -> Maybe Word64
word64 raw = case reads raw of
  [(value, "")] -> Just value
  _ -> Nothing

validNonce :: String -> Bool
validNonce value =
  length value == 64 && all validHexCharacter value

validMachineId :: String -> Bool
validMachineId value =
  length value == 32 && all validHexCharacter value

validPositiveInteger :: Integer -> Bool
validPositiveInteger value = value > 0 && value < 2 ^ (64 :: Integer)
