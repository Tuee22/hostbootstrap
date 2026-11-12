{-# LANGUAGE OverloadedStrings #-}

{- | Total classifications for answers produced by the direct-Colima command
row. No function here performs an effect.
-}
module HostBootstrap.Ensure.Colima.Report (
    ColimaInstance (..),
    ColimaReportFault (..),
    ColimaDockerRun (..),
    colimaDockerRunResult,
    ColimaInstallPolicy (..),
    ColimaResolutionChoice (..),
    colimaResolutionChoice,
    colimaCleanupCompletion,
    LimaDisk (..),
    classifyColimaListing,
    classifyLimaDiskListing,
    classifyDockerContextListing,
    classifyDockerContextInspect,
    dockerContextFingerprint,
    classifyMachineIdentity,
)
where

import qualified Crypto.Hash as Hash
import qualified Data.Aeson as Aeson
import Data.Bits (xor)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (nub)
import Data.Word (Word64)
import qualified Data.Text as Text
import HostBootstrap.Ensure.Colima.Backend.Resolver (TrustedAppleToolchain, TrustedAppleBrew, TrustedResolverResult (..))
import HostBootstrap.Reconcile.Error (ReconcileError (Failure, Unsupported), FailureDetail (FailureDetail), UnsupportedDetail (UnsupportedDetail), RecoveryDisposition (ReprobeBeforeRetry))
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.Ownership.Object (ObjectIdentity, objectIdentityBytes)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (isAbsolute, normalise, splitDirectories)
import qualified System.FilePath.Posix as Posix

-- | Only acquisition may install a missing tool after trusted discovery.
data ColimaInstallPolicy = ColimaMayInstall | ColimaMustExist deriving (Eq, Show)

-- | Descriptive dispatch retaining the resolver's actual opaque evidence.
data ColimaResolutionChoice
    = ColimaUseResolved TrustedAppleToolchain
    | ColimaInstallResolved TrustedAppleBrew

colimaResolutionChoice :: ColimaInstallPolicy -> TrustedResolverResult -> Either ReconcileError ColimaResolutionChoice
colimaResolutionChoice policy resolved = case resolved of
    TrustedResolverReady toolchain -> Right (ColimaUseResolved toolchain)
    TrustedResolverUnsupported reason -> Left (Unsupported (UnsupportedDetail "resolve direct-Colima toolchain" (Text.pack reason)))
    TrustedResolverMissingColima brew -> case policy of
        ColimaMayInstall -> Right (ColimaInstallResolved brew)
        ColimaMustExist -> Left (Failure (FailureDetail "resolve direct-Colima toolchain" "Colima is missing and this operation cannot install it" ReprobeBeforeRetry))

-- | A committed release completes even when its subsequent standing check fails.
colimaCleanupCompletion :: Either failure () -> Either diagnostic () -> Either failure (Maybe diagnostic)
colimaCleanupCompletion released checked = case released of
    Left fault -> Left fault
    Right () -> Right (either Just (const Nothing) checked)

-- | A command that ran retains its complete capture even if standing changes.
-- The optional refusal describes post-call ownership/toolchain revalidation.
data ColimaDockerRun = ColimaDockerRun
    { colimaDockerCapturedRun :: CapturedRun
    , colimaDockerPostFailure :: Maybe String
    }
    deriving (Eq, Show)

colimaDockerRunResult :: Either String (CapturedRun, Maybe String) -> Either String () -> Either String ColimaDockerRun
colimaDockerRunResult result toolchainCheck = case result of
    Left refusal -> Left refusal
    Right (captured, standingFailure) ->
        Right (ColimaDockerRun captured (combine standingFailure toolchainFailure))
  where
    toolchainFailure = case toolchainCheck of
        Right () -> Nothing
        Left reason -> Just ("live Docker toolchain changed after execution: " ++ reason)
    combine Nothing other = other
    combine original Nothing = original
    combine (Just standing) (Just toolchain) = Just (standing ++ "; " ++ toolchain)

data ColimaInstance = ColimaInstance
    { ciName :: String
    , ciStatus :: String
    , ciCpus :: Integer
    , ciMemoryBytes :: Integer
    , ciDiskBytes :: Integer
    , ciRuntime :: String
    }
    deriving (Eq, Show)

instance Aeson.FromJSON ColimaInstance where
    parseJSON =
        Aeson.withObject "ColimaInstance" $ \object ->
            ColimaInstance
                <$> object Aeson..: "name"
                <*> object Aeson..: "status"
                <*> object Aeson..: "cpus"
                <*> object Aeson..: "memory"
                <*> object Aeson..: "disk"
                <*> object Aeson..: "runtime"

data ColimaReportFault
    = ColimaToolExit
    | ColimaToolStderr
    | ColimaReportFraming
    | ColimaReportDecode
    | ColimaReportShape
    | ColimaReportDuplicate
    deriving (Eq, Show)

data LimaDisk = LimaDisk
    { limaDiskName :: String
    , limaDiskDirectory :: FilePath
    , limaDiskInstance :: String
    , limaDiskInstanceDirectory :: FilePath
    , limaDiskFormat :: String
    , limaDiskMountPoint :: String
    , limaDiskSize :: Integer
    }
    deriving (Eq, Show)

instance Aeson.FromJSON LimaDisk where
    parseJSON =
        Aeson.withObject "LimaDisk" $ \object ->
            LimaDisk
                <$> object Aeson..: "name"
                <*> object Aeson..: "dir"
                <*> object Aeson..: "instance"
                <*> object Aeson..: "instanceDir"
                <*> object Aeson..: "format"
                <*> object Aeson..: "mountPoint"
                <*> object Aeson..: "size"

newtype DockerContext = DockerContext {dockerContextName :: String}

instance Aeson.FromJSON DockerContext where
    parseJSON = Aeson.withObject "DockerContext" (\object -> DockerContext <$> object Aeson..: "Name")

classifyColimaListing :: CapturedRun -> Either ColimaReportFault [ColimaInstance]
classifyColimaListing run
    | capturedExit run /= ExitSuccess = Left ColimaToolExit
    | not (null (capturedStderr run)) = Left ColimaToolStderr
    | null output = Right []
    | '\r' `elem` output || last output /= '\n' = Left ColimaReportFraming
    | any null rows = Left ColimaReportFraming
    | otherwise =
        case traverse (Aeson.eitherDecodeStrict' . ByteString.pack) rows of
            Left _ -> Left ColimaReportDecode
            Right values
                | not (all validInstance values) -> Left ColimaReportShape
                | length (nub (map ciName values)) /= length values -> Left ColimaReportDuplicate
                | otherwise -> Right values
  where
    output = capturedStdout run
    rows = lines output
    validInstance = validListingName . ciName

validListingName :: String -> Bool
validListingName name =
    not (null name)
        && length name <= 255
        && all (\character -> character >= '!' && character <= '~') name

classifyLimaDiskListing :: CapturedRun -> Either ColimaReportFault [LimaDisk]
classifyLimaDiskListing run = do
    values <- strictJsonLines run
    if not (all validDisk values)
        then Left ColimaReportShape
        else
            if length (nub (map limaDiskName values)) /= length values
                then Left ColimaReportDuplicate
                else Right values
  where
    validDisk value =
        not (null (limaDiskName value))
            && validPath (limaDiskDirectory value)
            && limaDiskSize value > 0
    validPath path =
        ".." `notElem` splitDirectories path
            && ".." `notElem` Posix.splitDirectories path
            && ( (isAbsolute path && normalise path == path)
                    || (Posix.isAbsolute path && Posix.normalise path == path && '\\' `notElem` path)
               )

classifyDockerContextListing :: CapturedRun -> Either ColimaReportFault [String]
classifyDockerContextListing run = do
    values <- strictJsonLines run
    let names = map dockerContextName values
    if not (all validListingName names)
        then Left ColimaReportShape
        else if length (nub names) /= length names
            then Left ColimaReportDuplicate
            else Right names

classifyDockerContextInspect :: CapturedRun -> Either ColimaReportFault Aeson.Value
classifyDockerContextInspect run
    | capturedExit run /= ExitSuccess = Left ColimaToolExit
    | not (null (capturedStderr run)) = Left ColimaToolStderr
    | otherwise =
        case Aeson.eitherDecodeStrict' (ByteString.pack (capturedStdout run)) of
            Right (Aeson.Array values)
                | [value@(Aeson.Object _)] <- foldr (:) [] values -> Right value
            Right _ -> Left ColimaReportShape
            Left _ -> Left ColimaReportDecode

{- | Bind Docker's semantic context object to the already-bound config
directory identity. Decoding before hashing makes insignificant JSON
whitespace and object-key order irrelevant.
-}
dockerContextFingerprint :: ObjectIdentity -> Aeson.Value -> String
dockerContextFingerprint identity value =
    show
        ( Hash.hashWith
            Hash.SHA256
            (LazyByteString.toStrict (Aeson.encode value) <> objectIdentityBytes identity)
        )

strictJsonLines :: (Aeson.FromJSON value) => CapturedRun -> Either ColimaReportFault [value]
strictJsonLines run
    | capturedExit run /= ExitSuccess = Left ColimaToolExit
    | not (null (capturedStderr run)) = Left ColimaToolStderr
    | null output = Right []
    | '\r' `elem` output || last output /= '\n' = Left ColimaReportFraming
    | any null rows = Left ColimaReportFraming
    | otherwise =
        case traverse (Aeson.eitherDecodeStrict' . ByteString.pack) rows of
            Left _ -> Left ColimaReportDecode
            Right values -> Right values
  where
    output = capturedStdout run
    rows = lines output

classifyMachineIdentity :: CapturedRun -> Either ColimaReportFault (String, Word64)
classifyMachineIdentity run
    | capturedExit run /= ExitSuccess = Left ColimaToolExit
    | not (null (capturedStderr run)) = Left ColimaToolStderr
    | otherwise = case capturedStdout run of
        machineAndNewline
            | length machineAndNewline == 33
            , last machineAndNewline == '\n'
            , let machine = init machineAndNewline
            , all isLowerHex machine ->
                Right (machine, machineEpoch machine)
        _ -> Left ColimaReportShape
  where
    isLowerHex value = value >= '0' && value <= '9' || value >= 'a' && value <= 'f'

machineEpoch :: String -> Word64
machineEpoch machine =
    let hashed = foldl (\value byte -> (value `xor` fromIntegral (fromEnum byte)) * 1099511628211) 14695981039346656037 machine
     in if hashed == 0 then 1 else hashed
