{-# LANGUAGE LambdaCase #-}
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

    -- * Read-only cluster object observation
    ClusterObjectKind (..),
    ClusterObjectIdentity (..),
    encodeShippedClusterObjectRequest,
    decodeShippedClusterObjectRequest,
    decodeShippedClusterObjectResponse,
    observeClusterObject,
    observeShippedClusterObjectAt,
    interpretShippedClusterObject,
)
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Backend (
    observeRecordedClusterExposure,
    recordedClusterExposureHostPort,
 )
import HostBootstrap.Cluster.Report (safeClusterName)
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (CapturedRun (capturedExit, capturedStderr, capturedStdout))
import HostBootstrap.Effect.Vocabulary (hostCommand)
import HostBootstrap.Handoff.Transaction (withFrameChildTransaction)
import HostBootstrap.HostTool (HostTool (Kubectl))
import System.Directory (doesFileExist)
import System.Exit (ExitCode (ExitSuccess))
import HostBootstrap.HostConfig (HostConfig, buildHostConfig)
import HostBootstrap.Lift (LiftContext, SelfRef)
import HostBootstrap.Network.Port (mkPort)
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

-- | Render the one canonical request admitted by the far frame.
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

-- | Decode the far frame's sole success value.
decodeShippedClusterExposureResponse :: ByteString -> Either Text Int
decodeShippedClusterExposureResponse raw = case ByteString.stripPrefix responsePrefix raw of
    Nothing -> Left "the bytes are not a shipped cluster exposure response"
    Just portBytes -> do
        portText <- decodeField "host port" portBytes
        case readMaybe (Text.unpack portText) of
            Just port
                | isJust (mkPort port)
                , responsePrefix <> TextEncoding.encodeUtf8 (Text.pack (show port)) == raw ->
                    Right port
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

decodeField :: Text -> ByteString -> Either Text Text
decodeField label bytes = case TextEncoding.decodeUtf8' bytes of
    Left _ -> Left ("the cluster exposure " <> label <> " is not UTF-8")
    Right value -> Right value

-- ---------------------------------------------------------------------------
-- Read-only cluster object observation

-- | The closed set of objects a root may observe in a cluster frame: a workload,
-- or a namespace, whose UID identifies the cluster that created it.
data ClusterObjectKind = ClusterDeployment | ClusterStatefulSet | ClusterNamespace
    deriving (Eq, Show)

-- | The object's API identity and its current resource version.
data ClusterObjectIdentity = ClusterObjectIdentity
    { clusterObjectUid :: Text
    , clusterObjectVersion :: Text
    }
    deriving (Eq, Show)

objectRequestPrefix, objectResponsePrefix :: ByteString
objectRequestPrefix = "hostbootstrap/cluster-object/request/v1\0"
objectResponsePrefix = "hostbootstrap/cluster-object/response/v1\0"

kindText :: ClusterObjectKind -> Text
kindText ClusterDeployment = "deployment"
kindText ClusterStatefulSet = "statefulset"
kindText ClusterNamespace = "namespace"

{- | Render the one canonical object request: the cluster's absolute POSIX state
directory, its exact name, and the namespace, kind and name of one object. No
kubeconfig path, executable or selector crosses the frame; the far side derives
the kubeconfig from the cluster's own state directory.
-}
encodeShippedClusterObjectRequest :: FilePath -> String -> Text -> ClusterObjectKind -> Text -> Either Text ByteString
encodeShippedClusterObjectRequest stateDirectory cluster namespace kind name = do
    validateObjectRequest stateDirectory cluster namespace name
    let fields = map TextEncoding.encodeUtf8 [Text.pack stateDirectory, Text.pack cluster, namespace, kindText kind, name]
        encoded = objectRequestPrefix <> ByteString.intercalate "\0" fields
    if ByteString.length encoded <= maxRequestBytes
        then Right encoded
        else Left "the cluster object request exceeds its byte bound"

decodeShippedClusterObjectRequest :: ByteString -> Either Text (FilePath, String, Text, ClusterObjectKind, Text)
decodeShippedClusterObjectRequest raw
    | ByteString.length raw > maxRequestBytes = Left "the cluster object request exceeds its byte bound"
    | otherwise = case ByteString.stripPrefix objectRequestPrefix raw of
        Nothing -> Left "the cluster object request has an unknown prefix"
        Just body -> case ByteString.split 0 body of
            [stateBytes, clusterBytes, namespaceBytes, kindBytes, nameBytes] -> do
                stateDirectory <- Text.unpack <$> decodeObjectField "state directory" stateBytes
                cluster <- Text.unpack <$> decodeObjectField "cluster name" clusterBytes
                namespace <- decodeObjectField "namespace" namespaceBytes
                kind <- decodeObjectField "kind" kindBytes >>= \case
                    "deployment" -> Right ClusterDeployment
                    "statefulset" -> Right ClusterStatefulSet
                    "namespace" -> Right ClusterNamespace
                    _ -> Left "the cluster object kind is outside the closed set"
                name <- decodeObjectField "name" nameBytes
                validateObjectRequest stateDirectory cluster namespace name
                Right (stateDirectory, cluster, namespace, kind, name)
            _ -> Left "the cluster object request does not have exactly five fields"

decodeShippedClusterObjectResponse :: ByteString -> Either Text ClusterObjectIdentity
decodeShippedClusterObjectResponse raw = case ByteString.stripPrefix objectResponsePrefix raw of
    Nothing -> Left "the cluster object response has an unknown prefix"
    Just body -> case ByteString.split 0 body of
        [uidBytes, versionBytes] -> do
            uid <- decodeObjectField "uid" uidBytes
            version <- decodeObjectField "resource version" versionBytes
            if validObjectToken uid && validObjectToken version
                then Right (ClusterObjectIdentity uid version)
                else Left "the cluster object identity is not bounded token text"
        _ -> Left "the cluster object response does not have exactly two fields"

{- | Read one object's identity with the cluster's own kubeconfig, in this frame.

Nothing is applied or patched; an absent kubeconfig, an absent object, a noisy
or failed query, or an answer other than one bounded identity line refuses.
-}
observeClusterObject :: HostConfig -> FilePath -> String -> Text -> ClusterObjectKind -> Text -> IO (Either Text ClusterObjectIdentity)
observeClusterObject cfg stateDirectory cluster namespace kind name =
    case validateObjectRequest stateDirectory cluster namespace name of
        Left refusal -> pure (Left refusal)
        Right () -> do
            let kubeconfig = stateDirectory Posix.</> "cluster.kubeconfig"
            present <- doesFileExist kubeconfig
            if not present
                then pure (Left "the cluster kubeconfig is absent")
                else do
                    answer <- interpretHostCommand cfg (hostCommand Kubectl
                        [ "--kubeconfig", kubeconfig, "get", Text.unpack (kindText kind <> "/" <> name)
                        , "--namespace", Text.unpack namespace
                        , "-o", "jsonpath={.metadata.uid} {.metadata.resourceVersion}"
                        ])
                    pure $ case answer of
                        Left failure -> Left (Text.take 512 (Text.pack failure))
                        Right captured
                            | capturedExit captured /= ExitSuccess -> Left "the cluster object is absent or the query failed"
                            | not (null (capturedStderr captured)) -> Left "the cluster object query answered on its diagnostic stream"
                            | [uid, version] <- words (capturedStdout captured)
                            , validObjectToken (Text.pack uid), validObjectToken (Text.pack version) ->
                                Right (ClusterObjectIdentity (Text.pack uid) (Text.pack version))
                            | otherwise -> Left "the cluster object identity is not one bounded line"

-- | Ship one object observation to the frame @context@ names.
observeShippedClusterObjectAt :: HostConfig -> SelfRef -> LiftContext -> ByteString -> IO (Either Text ClusterObjectIdentity)
observeShippedClusterObjectAt config self context request = do
    crossed <- withFrameChildTransaction config self context request
    pure (crossed >>= decodeShippedClusterObjectResponse)

{- | Recognize and interpret this module's object request, as the frame that
holds the cluster's state. 'Nothing' leaves other prefixes to their own
interpreters.
-}
interpretShippedClusterObject :: ByteString -> IO (Maybe (Either Text ByteString))
interpretShippedClusterObject raw
    | not (objectRequestPrefix `ByteString.isPrefixOf` raw) = pure Nothing
    | otherwise = case decodeShippedClusterObjectRequest raw of
        Left refusal -> pure (Just (Left refusal))
        Right (stateDirectory, cluster, namespace, kind, name) -> do
            detected <- detect
            case detected of
                Left refusal -> pure (Just (Left (Text.pack refusal)))
                Right substrate -> do
                    config <- buildHostConfig substrate
                    observed <- observeClusterObject config stateDirectory cluster namespace kind name
                    pure . Just $ case observed of
                        Left refusal -> Left refusal
                        Right (ClusterObjectIdentity uid version) ->
                            Right (objectResponsePrefix <> TextEncoding.encodeUtf8 uid <> "\0" <> TextEncoding.encodeUtf8 version)

validateObjectRequest :: FilePath -> String -> Text -> Text -> Either Text ()
validateObjectRequest stateDirectory cluster namespace name = do
    validateRequest stateDirectory cluster "object"
    if not (validKubernetesName namespace)
        then Left "the cluster object namespace is not a DNS label"
        else if not (validKubernetesName name)
            then Left "the cluster object name is not a DNS label"
            else Right ()

validKubernetesName :: Text -> Bool
validKubernetesName value =
    not (Text.null value)
        && Text.length value <= 63
        && Text.all (\character -> character `elem` ['a' .. 'z'] || character `elem` ['0' .. '9'] || character == '-') value
        && Text.head value /= '-'
        && Text.last value /= '-'

validObjectToken :: Text -> Bool
validObjectToken value =
    not (Text.null value) && Text.length value <= 128
        && Text.all (\character -> character > ' ' && character < '\DEL') value

decodeObjectField :: Text -> ByteString -> Either Text Text
decodeObjectField label bytes = case TextEncoding.decodeUtf8' bytes of
    Left _ -> Left ("the cluster object " <> label <> " is not UTF-8")
    Right value -> Right value
