{-# LANGUAGE OverloadedStrings #-}

{- | Read-only observation of a durable cluster exposure in the provider frame
that owns its Docker engine.

The crossing is the authenticated frame transaction already owned by
"HostBootstrap.Handoff.Transaction". This module adds only a closed, bounded
request and response: an absolute POSIX state path, an exact cluster name, one
service identity, and the freshly re-observed loopback port. No runtime handle,
ownership witness, credential, or executable selector crosses the frame.
-}
module HostBootstrap.Cluster.Shipped (
    encodeShippedClusterExposureRequest,
    decodeShippedClusterExposureRequest,
    decodeShippedClusterExposureResponse,
    observeShippedClusterExposureAt,
    observeShippedClusterExposure,
    interpretShippedClusterExposure,
)
where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Backend (
    observeRecordedClusterExposure,
    recordedClusterExposureHostPort,
 )
import HostBootstrap.Cluster.Report (safeClusterName)
import HostBootstrap.Handoff.Transaction (withFrameChildTransaction)
import HostBootstrap.HostConfig (HostConfig, buildHostConfig)
import HostBootstrap.Lift (LiftContext, SelfRef)
import HostBootstrap.Substrate (detect)
import HostBootstrap.Substrate.Provider (ProviderCapability, providerCapabilityLiftContext)
import qualified System.FilePath.Posix as Posix
import Text.Read (readMaybe)

requestPrefix, responsePrefix :: ByteString
requestPrefix = "hostbootstrap/cluster-exposure/request/v1\0"
responsePrefix = "hostbootstrap/cluster-exposure/response/v1\0"

maxRequestBytes, maxStatePathBytes :: Int
maxRequestBytes = 4096
maxStatePathBytes = 2048

{- | Render the one canonical request admitted by the far frame. -}
encodeShippedClusterExposureRequest :: FilePath -> String -> Text -> Either Text ByteString
encodeShippedClusterExposureRequest stateDirectory cluster service = do
    validateRequest stateDirectory cluster service
    let fields = map TextEncoding.encodeUtf8 [Text.pack stateDirectory, Text.pack cluster, service]
        encoded = requestPrefix <> ByteString.intercalate "\0" fields
    if ByteString.length encoded <= maxRequestBytes
        then Right encoded
        else Left "the cluster exposure request exceeds its byte bound"

{- | Decode only the canonical request; trailing, alternate, or malformed bytes
are refusals rather than guessed representations.
-}
decodeShippedClusterExposureRequest :: ByteString -> Either Text (FilePath, String, Text)
decodeShippedClusterExposureRequest raw
    | ByteString.length raw > maxRequestBytes = Left "the cluster exposure request exceeds its byte bound"
    | otherwise = case ByteString.stripPrefix requestPrefix raw of
        Nothing -> Left "the bytes are not a shipped cluster exposure request"
        Just payload -> case ByteString.split 0 payload of
            [stateBytes, clusterBytes, serviceBytes] -> do
                state <- decodeField "state directory" stateBytes
                cluster <- decodeField "cluster name" clusterBytes
                service <- decodeField "service identity" serviceBytes
                validateRequest (Text.unpack state) (Text.unpack cluster) service
                canonical <- encodeShippedClusterExposureRequest (Text.unpack state) (Text.unpack cluster) service
                if canonical == raw
                    then Right (Text.unpack state, Text.unpack cluster, service)
                    else Left "the cluster exposure request is not canonical"
            _ -> Left "the cluster exposure request does not contain exactly three fields"

{- | Decode the far frame's sole success value. -}
decodeShippedClusterExposureResponse :: ByteString -> Either Text Int
decodeShippedClusterExposureResponse raw = case ByteString.stripPrefix responsePrefix raw of
    Nothing -> Left "the bytes are not a shipped cluster exposure response"
    Just portBytes -> do
        portText <- decodeField "host port" portBytes
        case readMaybe (Text.unpack portText) of
            Just port
                | validPort port
                , responsePrefix <> TextEncoding.encodeUtf8 (Text.pack (show port)) == raw -> Right port
            _ -> Left "the shipped cluster exposure response carries an invalid host port"

{- | Cross into the exact provider capability and return only the freshly
observed loopback port.
-}
observeShippedClusterExposure ::
    HostConfig ->
    SelfRef ->
    ProviderCapability scope planId providerId backendId capabilityId ->
    FilePath ->
    String ->
    Text ->
    IO (Either Text Int)
observeShippedClusterExposure config self capability stateDirectory cluster service =
    observeShippedClusterExposureAt
        config
        self
        (providerCapabilityLiftContext capability)
        stateDirectory
        cluster
        service

{- | Cross through one already-derived lift context. This is the primitive used
by the capability-restricted wrapper above and by providers whose lifecycle
backend owns its route directly rather than packaging a provider capability.
-}
observeShippedClusterExposureAt ::
    HostConfig ->
    SelfRef ->
    LiftContext ->
    FilePath ->
    String ->
    Text ->
    IO (Either Text Int)
observeShippedClusterExposureAt config self context stateDirectory cluster service =
    case encodeShippedClusterExposureRequest stateDirectory cluster service of
        Left refusal -> pure (Left refusal)
        Right request -> do
            crossed <-
                withFrameChildTransaction
                    config
                    self
                    context
                    request
            pure (crossed >>= decodeShippedClusterExposureResponse)

{- | Recognize and interpret this module's request. 'Nothing' means the prefix
belongs to another closed frame transaction, so the shared child dispatcher may
offer it to that transaction's interpreter.
-}
interpretShippedClusterExposure :: ByteString -> IO (Maybe (Either Text ByteString))
interpretShippedClusterExposure raw
    | not (requestPrefix `ByteString.isPrefixOf` raw) = pure Nothing
    | otherwise = case decodeShippedClusterExposureRequest raw of
        Left refusal -> pure (Just (Left refusal))
        Right (stateDirectory, cluster, service) -> do
            detected <- detect
            case detected of
                Left refusal -> pure (Just (Left (Text.pack refusal)))
                Right substrate -> do
                    config <- buildHostConfig substrate
                    observed <- observeRecordedClusterExposure config stateDirectory cluster service
                    pure $
                        Just $
                            case observed of
                                Left refusal -> Left (Text.take 4096 (Text.pack (show refusal)))
                                Right exposure ->
                                    Right
                                        ( responsePrefix
                                            <> TextEncoding.encodeUtf8
                                                (Text.pack (show (recordedClusterExposureHostPort exposure)))
                                        )

validateRequest :: FilePath -> String -> Text -> Either Text ()
validateRequest stateDirectory cluster service
    | not (Posix.isAbsolute stateDirectory) = Left "the cluster state directory is not an absolute POSIX path"
    | stateDirectory == "/" = Left "the cluster state directory cannot be the filesystem root"
    | not (Posix.isValid stateDirectory) = Left "the cluster state directory is not a valid POSIX path"
    | Posix.normalise stateDirectory /= stateDirectory = Left "the cluster state directory is not canonical"
    | Posix.hasTrailingPathSeparator stateDirectory = Left "the cluster state directory has a trailing separator"
    | any (`elem` [".", ".."]) (Posix.splitDirectories stateDirectory) = Left "the cluster state directory contains a relative segment"
    | '\0' `elem` stateDirectory = Left "the cluster state directory contains NUL"
    | ByteString.length (TextEncoding.encodeUtf8 (Text.pack stateDirectory)) > maxStatePathBytes = Left "the cluster state directory exceeds its byte bound"
    | not (safeClusterName cluster) = Left "the cluster name is outside the portable alphabet"
    | not (validService service) = Left "the service identity is invalid or unbounded"
    | otherwise = Right ()

validService :: Text -> Bool
validService service =
    not (Text.null service)
        && Text.length service <= 128
        && not (Text.any (`elem` ['\0', '/', '\\', ':', '\n', '\r', '\t']) service)

validPort :: Int -> Bool
validPort port = port > 0 && port < 65536

decodeField :: Text -> ByteString -> Either Text Text
decodeField label bytes = case TextEncoding.decodeUtf8' bytes of
    Left _ -> Left ("the cluster exposure " <> label <> " is not UTF-8")
    Right value -> Right value
