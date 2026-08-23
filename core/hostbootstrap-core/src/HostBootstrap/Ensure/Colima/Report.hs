{-# LANGUAGE OverloadedStrings #-}

{- | Total classifications for answers produced by the direct-Colima command
row. No function here performs an effect.
-}
module HostBootstrap.Ensure.Colima.Report
  ( ColimaInstance (..),
    ColimaReportFault (..),
    LimaDisk (..),
    parseColimaInstances,
    classifyColimaListing,
    classifyLimaDiskListing,
    classifyDockerContextListing,
    classifyDockerContextInspect,
    dockerContextFingerprint,
    classifyMachineIdentity,
  )
where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Crypto.Hash as Hash
import Data.Bits (xor)
import Data.List (nub)
import Data.Word (Word64)
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.Ownership.Object (ObjectIdentity, objectIdentityBytes)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (isAbsolute, normalise)

data ColimaInstance = ColimaInstance
  { ciName :: String,
    ciStatus :: String,
    ciCpus :: Integer,
    ciMemoryBytes :: Integer,
    ciDiskBytes :: Integer,
    ciRuntime :: String
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
  { limaDiskName :: String,
    limaDiskDirectory :: FilePath,
    limaDiskInstance :: String,
    limaDiskInstanceDirectory :: FilePath,
    limaDiskFormat :: String,
    limaDiskMountPoint :: String,
    limaDiskSize :: Integer
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

parseColimaInstances :: String -> Either String [ColimaInstance]
parseColimaInstances output = traverse parseLine (filter (not . null) (lines output))
  where
    parseLine = Aeson.eitherDecodeStrict' . ByteString.pack

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
    validInstance value =
      not (null (ciName value))
        && length (ciName value) <= 255
        && all (\character -> character >= '!' && character <= '~') (ciName value)

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
        && isAbsolute (limaDiskDirectory value)
        && normalise (limaDiskDirectory value) == limaDiskDirectory value
        && limaDiskSize value > 0

classifyDockerContextListing :: CapturedRun -> Either ColimaReportFault [String]
classifyDockerContextListing run = do
  values <- strictJsonLines run
  let names = map dockerContextName values
  if length (nub names) /= length names
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

-- | Bind Docker's semantic context object to the already-bound config
-- directory identity. Decoding before hashing makes insignificant JSON
-- whitespace and object-key order irrelevant.
dockerContextFingerprint :: ObjectIdentity -> Aeson.Value -> String
dockerContextFingerprint identity value =
  show
    ( Hash.hashWith
        Hash.SHA256
        ( LazyByteString.toStrict (Aeson.encode value) <> objectIdentityBytes identity
        )
    )

strictJsonLines :: Aeson.FromJSON value => CapturedRun -> Either ColimaReportFault [value]
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
        | length machineAndNewline == 33,
          last machineAndNewline == '\n',
          let machine = init machineAndNewline,
          all isLowerHex machine -> Right (machine, machineEpoch machine)
      _ -> Left ColimaReportShape
  where
    isLowerHex value = value >= '0' && value <= '9' || value >= 'a' && value <= 'f'

machineEpoch :: String -> Word64
machineEpoch machine =
  let hashed = foldl (\value byte -> (value `xor` fromIntegral (fromEnum byte)) * 1099511628211) 14695981039346656037 machine
   in if hashed == 0 then 1 else hashed
