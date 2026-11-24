{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Neutral canonical bytes for one rooted handoff payload binding.

This Cabal-private module deliberately owns neither cryptography nor handoff
authority.  The exposed 'HostBootstrap.Handoff' facade fixes the binding to an
already authenticated edge, signs it through the live root broker, and admits
received bytes only after the ordinary one-use handoff has verified.
-}
module HostBootstrap.Handoff.Rooted (
    PayloadDigest,
    mkPayloadDigest,
    payloadDigestText,
    ChildConfigDigest,
    mkChildConfigDigest,
    childConfigDigestText,
    RequestDigest,
    mkRequestDigest,
    requestDigestText,
    LifecycleSession,
    mkLifecycleSession,
    lifecycleSessionText,
    LifecycleStage,
    mkLifecycleStage,
    lifecycleStageText,
    LifecycleOrdinal,
    mkLifecycleOrdinal,
    lifecycleOrdinalWord64,
    PredecessorDigest,
    mkPredecessorDigest,
    predecessorDigestText,
    RootedPayloadBinding,
    rootedPayloadBindingKernel,
    rootedPayloadBindingFromWireKernel,
    rootedPayloadBindingEdgeKernel,
    rootedPayloadDigestKernel,
    rootedChildConfigDigestKernel,
    rootedPayloadSignatureKernel,
    renderRootedPayloadBindingKernel,
    renderRootedPayloadUnsignedKernel,
    renderRootedPayloadUnsignedPartsKernel,
    RootedProjectedObservation (..),
    RootedNodeObservation (..),
    renderRootedNodeObservationKernel,
    readRootedNodeObservationKernel,
    readRootedNodeObservationForPlanKernel,
    RootedReverseResource (..),
    RootedReverseObservation (..),
    renderRootedReverseObservationKernel,
    readRootedReverseObservationForPlanKernel,
    renderReversePreparedGateEnvelopeKernel,
    readReversePreparedGateEnvelopeKernel,
    renderRecoveryObserveEnvelopeKernel,
    readRecoveryObserveEnvelopeKernel,
    RootedRecoveryResult (..),
    RootedRecoveryObservation (..),
    renderRootedRecoveryObservationKernel,
    readRootedRecoveryObservationKernel,
    admitRootedRecoveryObservationKernel,
    RecoveryObservationRequest (..),
    renderRecoveryObservationRequestKernel,
    readRecoveryObservationRequestKernel,
    isRecoveryObservationRequestKernel,
    RootedLifecycleRequest,
    rootedOpenFrameRequestKernel,
    rootedNextNodeRequestKernel,
    rootedSettleNodeRequestKernel,
    rootedDescendResultRequestKernel,
    rootedCloseFrameRequestKernel,
    rootedReceiptConfirmRequestKernel,
    rootedLifecycleRequestFromWireKernel,
    renderRootedLifecycleRequestKernel,
    withRootedLifecycleRequestKernel,
    RootedLifecycleResponse,
    rootedOpenedResponseUnsignedKernel,
    rootedPreparedResponseUnsignedKernel,
    rootedDescendResponseUnsignedKernel,
    rootedSettledResponseUnsignedKernel,
    rootedFrameCompleteResponseUnsignedKernel,
    rootedReceiptRecordedResponseUnsignedKernel,
    rootedRefusedResponseUnsignedKernel,
    rootedLifecycleResponseFromUnsignedKernel,
    rootedLifecycleResponseFromWireKernel,
    rootedLifecycleResponseSignatureKernel,
    renderRootedLifecycleResponseKernel,
    renderRootedLifecycleUnsignedResponseKernel,
    rootedLifecycleResponsePairKernel,
    rootedLifecycleUnsignedResponsePairKernel,
    withRootedLifecycleResponseKernel,
)
where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64, Word8)
import HostBootstrap.Lifecycle.Prepared.Internal (readFencedPreparedGatePackageKernel)

-- | One checked complete-payload digest. This descriptive data grants no authority.
newtype PayloadDigest = PayloadDigest Text
    deriving (Eq, Show)

mkPayloadDigest :: Text -> Either Text PayloadDigest
mkPayloadDigest digest = do
    requireDigest "payload" digest
    pure (PayloadDigest digest)

payloadDigestText :: PayloadDigest -> Text
payloadDigestText (PayloadDigest digest) = digest

-- | One checked child-config digest. This descriptive data grants no authority.
newtype ChildConfigDigest = ChildConfigDigest Text
    deriving (Eq, Show)

mkChildConfigDigest :: Text -> Either Text ChildConfigDigest
mkChildConfigDigest digest = do
    requireDigest "child config" digest
    pure (ChildConfigDigest digest)

childConfigDigestText :: ChildConfigDigest -> Text
childConfigDigestText (ChildConfigDigest digest) = digest

-- | One checked request digest. This descriptive data grants no authority.
newtype RequestDigest = RequestDigest Text
    deriving (Eq, Show)

mkRequestDigest :: Text -> Either Text RequestDigest
mkRequestDigest digest = do
    requireDigest "rooted lifecycle request" digest
    pure (RequestDigest digest)

requestDigestText :: RequestDigest -> Text
requestDigestText (RequestDigest digest) = digest

-- | One checked response-session coordinate. This descriptive data grants no authority.
newtype LifecycleSession = LifecycleSession Text
    deriving (Eq, Show)

mkLifecycleSession :: Text -> Either Text LifecycleSession
mkLifecycleSession session = do
    requireLifecycleText "response session" session
    pure (LifecycleSession session)

lifecycleSessionText :: LifecycleSession -> Text
lifecycleSessionText (LifecycleSession session) = session

-- | One checked response-stage coordinate. This descriptive data grants no authority.
newtype LifecycleStage = LifecycleStage Text
    deriving (Eq, Show)

mkLifecycleStage :: Text -> Either Text LifecycleStage
mkLifecycleStage stage = do
    requireLifecycleText "response stage" stage
    pure (LifecycleStage stage)

lifecycleStageText :: LifecycleStage -> Text
lifecycleStageText (LifecycleStage stage) = stage

-- | One checked nonzero response ordinal. This descriptive data grants no authority.
newtype LifecycleOrdinal = LifecycleOrdinal Word64
    deriving (Eq, Show)

mkLifecycleOrdinal :: Word64 -> Either Text LifecycleOrdinal
mkLifecycleOrdinal ordinal = do
    require (ordinal /= 0) "has a zero response ordinal"
    pure (LifecycleOrdinal ordinal)

lifecycleOrdinalWord64 :: LifecycleOrdinal -> Word64
lifecycleOrdinalWord64 (LifecycleOrdinal ordinal) = ordinal

-- | One checked completed-response commitment. This descriptive data grants no authority.
newtype PredecessorDigest = PredecessorDigest Text
    deriving (Eq, Show)

mkPredecessorDigest :: Text -> Either Text PredecessorDigest
mkPredecessorDigest digest = do
    requireDigest "completed response" digest
    pure (PredecessorDigest digest)

predecessorDigestText :: PredecessorDigest -> Text
predecessorDigestText (PredecessorDigest digest) = digest

-- | One root-signed complete-payload and child-config identity.
data RootedPayloadBinding scope brokerGeneration
    = RootedPayloadBinding
        ByteString
        PayloadDigest
        ChildConfigDigest
        ByteString

type role RootedPayloadBinding nominal nominal

rootedPayloadDomain :: ByteString
rootedPayloadDomain = "hostbootstrap/rooted-payload-binding"

rootedPayloadVersion :: ByteString
rootedPayloadVersion = ByteString.pack [0, 0, 0, 0, 0, 0, 0, 1]

rootedPayloadSignatureBytes :: Int
rootedPayloadSignatureBytes = 64

rootedFieldLimit :: Word64
rootedFieldLimit = 8 * 1024 * 1024

-- | Package-private checked constructor used only by the handoff facade.
rootedPayloadBindingKernel ::
    ByteString ->
    PayloadDigest ->
    ChildConfigDigest ->
    ByteString ->
    Either Text (RootedPayloadBinding scope brokerGeneration)
rootedPayloadBindingKernel edge payloadDigest childConfigDigest signature = do
    _ <- renderRootedPayloadUnsignedPartsKernel edge payloadDigest childConfigDigest
    require
        (ByteString.length signature == rootedPayloadSignatureBytes)
        "has a signature whose width is not 64 bytes"
    pure (RootedPayloadBinding edge payloadDigest childConfigDigest signature)

-- | Strictly decode the complete six-field canonical wire.
rootedPayloadBindingFromWireKernel ::
    ByteString ->
    Either Text (RootedPayloadBinding scope brokerGeneration)
rootedPayloadBindingFromWireKernel raw = do
    require
        (fromIntegral (ByteString.length raw) <= rootedFieldLimit)
        "is larger than the bounded authentication field"
    (domain, afterDomain) <- takeRootedFrame raw
    (version, afterVersion) <- takeRootedFrame afterDomain
    (edge, afterEdge) <- takeRootedFrame afterVersion
    (payloadBytes, afterPayload) <- takeRootedFrame afterEdge
    (configBytes, afterConfig) <- takeRootedFrame afterPayload
    (signature, trailing) <- takeRootedFrame afterConfig
    require (ByteString.null trailing) "has trailing bytes"
    require (domain == rootedPayloadDomain) "has the wrong domain"
    require (version == rootedPayloadVersion) "has the wrong version"
    payloadDigest <- decodeDigest "payload" payloadBytes >>= mkPayloadDigest
    childConfigDigest <- decodeDigest "child config" configBytes >>= mkChildConfigDigest
    binding <-
        rootedPayloadBindingKernel
            edge
            payloadDigest
            childConfigDigest
            signature
    require
        (renderRootedPayloadBindingKernel binding == raw)
        "is not canonical"
    pure binding

rootedPayloadBindingEdgeKernel ::
    RootedPayloadBinding scope brokerGeneration ->
    ByteString
rootedPayloadBindingEdgeKernel (RootedPayloadBinding edge _ _ _) = edge

rootedPayloadDigestKernel ::
    RootedPayloadBinding scope brokerGeneration ->
    PayloadDigest
rootedPayloadDigestKernel (RootedPayloadBinding _ digest _ _) = digest

rootedChildConfigDigestKernel ::
    RootedPayloadBinding scope brokerGeneration ->
    ChildConfigDigest
rootedChildConfigDigestKernel (RootedPayloadBinding _ _ digest _) = digest

rootedPayloadSignatureKernel ::
    RootedPayloadBinding scope brokerGeneration ->
    ByteString
rootedPayloadSignatureKernel (RootedPayloadBinding _ _ _ signature) = signature

renderRootedPayloadBindingKernel ::
    RootedPayloadBinding scope brokerGeneration ->
    ByteString
renderRootedPayloadBindingKernel binding =
    renderRootedPayloadUnsignedKernel binding
        <> rootedFrame (rootedPayloadSignatureKernel binding)

renderRootedPayloadUnsignedKernel ::
    RootedPayloadBinding scope brokerGeneration ->
    ByteString
renderRootedPayloadUnsignedKernel binding =
    renderRootedPayloadUnsignedParts
        (rootedPayloadBindingEdgeKernel binding)
        (rootedPayloadDigestKernel binding)
        (rootedChildConfigDigestKernel binding)

renderRootedPayloadUnsignedPartsKernel ::
    ByteString ->
    PayloadDigest ->
    ChildConfigDigest ->
    Either Text ByteString
renderRootedPayloadUnsignedPartsKernel edge payloadDigest childConfigDigest = do
    require (not (ByteString.null edge)) "has an empty edge binding"
    require
        (fromIntegral (ByteString.length edge) <= rootedFieldLimit)
        "has an oversized edge binding"
    let unsigned = renderRootedPayloadUnsignedParts edge payloadDigest childConfigDigest
    require
        ( fromIntegral
            (ByteString.length unsigned + 8 + rootedPayloadSignatureBytes)
            <= rootedFieldLimit
        )
        "is larger than the bounded authentication field"
    pure unsigned

renderRootedPayloadUnsignedParts :: ByteString -> PayloadDigest -> ChildConfigDigest -> ByteString
renderRootedPayloadUnsignedParts edge payloadDigest childConfigDigest =
    ByteString.concat
        [ rootedFrame rootedPayloadDomain
        , rootedFrame rootedPayloadVersion
        , rootedFrame edge
        , rootedFrame (TextEncoding.encodeUtf8 (payloadDigestText payloadDigest))
        , rootedFrame (TextEncoding.encodeUtf8 (childConfigDigestText childConfigDigest))
        ]

decodeDigest :: Text -> ByteString -> Either Text Text
decodeDigest label raw = case TextEncoding.decodeUtf8' raw of
    Left _ -> Left (label <> " digest is not valid UTF-8")
    Right digest -> requireDigest label digest >> pure digest

requireDigest :: Text -> Text -> Either Text ()
requireDigest label digest =
    require
        (Text.length digest == 64 && Text.all isLowerHex digest)
        (label <> " digest is not canonical lowercase SHA-256")
  where
    isLowerHex value =
        ('0' <= value && value <= '9') || ('a' <= value && value <= 'f')

require :: Bool -> Text -> Either Text ()
require True _ = Right ()
require False detail = Left detail

rootedFrame :: ByteString -> ByteString
rootedFrame payload =
    ByteString.pack (word64BigEndian (fromIntegral (ByteString.length payload)))
        <> payload

takeRootedFrame :: ByteString -> Either Text (ByteString, ByteString)
takeRootedFrame raw
    | ByteString.length raw < 8 = Left "is truncated before a frame header"
    | declared > rootedFieldLimit = Left "contains an oversized field"
    | fromIntegral (ByteString.length body) < declared =
        Left "is truncated inside a field"
    | otherwise = Right (ByteString.splitAt (fromIntegral declared) body)
  where
    (header, body) = ByteString.splitAt 8 raw
    declared = bigEndianWord64 (ByteString.unpack header)

word64BigEndian :: Word64 -> [Word8]
word64BigEndian value =
    [fromIntegral ((value `shiftR` shift) .&. 0xff) | shift <- [56, 48, 40, 32, 24, 16, 8, 0]]

bigEndianWord64 :: [Word8] -> Word64
bigEndianWord64 = foldl (\value byte -> (value `shiftL` 8) .|. fromIntegral byte) 0

-- Rooted lifecycle request

-- | One closed, canonical request from a storeless frame executor.
data RootedLifecycleRequest
    = OpenFrame ByteString
    | NextNode [Text] Text Text Word64 ByteString Text
    | SettleNode [Text] Text Text Word64 ByteString Text ByteString
    | DescendResult [Text] Text Text Word64 ByteString Text ByteString
    | CloseFrame [Text] Text Text Word64 ByteString Text
    | ReceiptConfirm [Text] Text Text Word64 ByteString Text

rootedLifecycleDomain :: ByteString
rootedLifecycleDomain = "hostbootstrap/rooted-lifecycle-request"

rootedLifecycleVersion :: ByteString
rootedLifecycleVersion = ByteString.pack [0, 0, 0, 0, 0, 0, 0, 1]

rootedLifecycleWireLimit :: Int
rootedLifecycleWireLimit = 7 * 1024 * 1024

rootedLifecycleBodyLimit :: Int
rootedLifecycleBodyLimit = 6 * 1024 * 1024

rootedLifecycleTextLimit :: Int
rootedLifecycleTextLimit = 4096

rootedLifecyclePathLimit :: Int
rootedLifecyclePathLimit = 256

rootedLifecycleNonceBytes :: Int
rootedLifecycleNonceBytes = 32

-- | Construct the sole request that precedes a root-issued session.
rootedOpenFrameRequestKernel ::
    ByteString ->
    Either Text RootedLifecycleRequest
rootedOpenFrameRequestKernel nonce = do
    requireLifecycleNonce nonce
    boundedLifecycleRequest (OpenFrame nonce)

rootedNextNodeRequestKernel ::
    [Text] ->
    Text ->
    Text ->
    Word64 ->
    ByteString ->
    Text ->
    Either Text RootedLifecycleRequest
rootedNextNodeRequestKernel = rootedPostOpenRequest NextNode

rootedSettleNodeRequestKernel ::
    [Text] ->
    Text ->
    Text ->
    Word64 ->
    ByteString ->
    Text ->
    ByteString ->
    Either Text RootedLifecycleRequest
rootedSettleNodeRequestKernel = rootedPostOpenBodyRequest SettleNode

rootedDescendResultRequestKernel ::
    [Text] ->
    Text ->
    Text ->
    Word64 ->
    ByteString ->
    Text ->
    ByteString ->
    Either Text RootedLifecycleRequest
rootedDescendResultRequestKernel = rootedPostOpenBodyRequest DescendResult

rootedCloseFrameRequestKernel ::
    [Text] ->
    Text ->
    Text ->
    Word64 ->
    ByteString ->
    Text ->
    Either Text RootedLifecycleRequest
rootedCloseFrameRequestKernel = rootedPostOpenRequest CloseFrame

rootedReceiptConfirmRequestKernel ::
    [Text] ->
    Text ->
    Text ->
    Word64 ->
    ByteString ->
    Text ->
    Either Text RootedLifecycleRequest
rootedReceiptConfirmRequestKernel = rootedPostOpenRequest ReceiptConfirm

rootedPostOpenRequest ::
    ([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> RootedLifecycleRequest) ->
    [Text] ->
    Text ->
    Text ->
    Word64 ->
    ByteString ->
    Text ->
    Either Text RootedLifecycleRequest
rootedPostOpenRequest makeRequest path session stage ordinal nonce predecessor = do
    requireLifecyclePostOpen path session stage ordinal nonce predecessor
    boundedLifecycleRequest (makeRequest path session stage ordinal nonce predecessor)

rootedPostOpenBodyRequest ::
    ([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> ByteString -> RootedLifecycleRequest) ->
    [Text] ->
    Text ->
    Text ->
    Word64 ->
    ByteString ->
    Text ->
    ByteString ->
    Either Text RootedLifecycleRequest
rootedPostOpenBodyRequest makeRequest path session stage ordinal nonce predecessor body = do
    requireLifecyclePostOpen path session stage ordinal nonce predecessor
    require (not (ByteString.null body)) "has an empty lifecycle request body"
    require
        (ByteString.length body <= rootedLifecycleBodyLimit)
        "has an oversized lifecycle request body"
    boundedLifecycleRequest (makeRequest path session stage ordinal nonce predecessor body)

requireLifecyclePostOpen ::
    [Text] ->
    Text ->
    Text ->
    Word64 ->
    ByteString ->
    Text ->
    Either Text ()
requireLifecyclePostOpen path session stage ordinal nonce predecessor = do
    require
        (not (null path) && length path <= rootedLifecyclePathLimit)
        "has an invalid requester path cardinality"
    mapM_ (requireLifecycleText "requester path component") path
    requireLifecycleText "session" session
    requireLifecycleText "stage" stage
    require (ordinal /= 0) "has a zero ordinal"
    requireLifecycleNonce nonce
    requireDigest "predecessor response" predecessor

requireLifecycleText :: Text -> Text -> Either Text ()
requireLifecycleText label value = do
    require (not (Text.null value)) ("has an empty " <> label)
    require
        (ByteString.length (TextEncoding.encodeUtf8 value) <= rootedLifecycleTextLimit)
        ("has an oversized " <> label)

requireLifecycleNonce :: ByteString -> Either Text ()
requireLifecycleNonce nonce =
    require
        (ByteString.length nonce == rootedLifecycleNonceBytes)
        "has a nonce whose width is not 32 bytes"

boundedLifecycleRequest :: RootedLifecycleRequest -> Either Text RootedLifecycleRequest
boundedLifecycleRequest request = do
    require
        (ByteString.length (renderRootedLifecycleRequestKernel request) <= rootedLifecycleWireLimit)
        "is larger than the bounded rooted lifecycle request"
    pure request

-- | Strictly decode one complete canonical rooted request.
rootedLifecycleRequestFromWireKernel ::
    ByteString ->
    Either Text RootedLifecycleRequest
rootedLifecycleRequestFromWireKernel raw = do
    require
        (ByteString.length raw <= rootedLifecycleWireLimit)
        "is larger than the bounded rooted lifecycle request"
    frames <- collectLifecycleFrames raw
    request <- case frames of
        domain : version : variant : fields -> do
            require (domain == rootedLifecycleDomain) "has the wrong lifecycle request domain"
            require (version == rootedLifecycleVersion) "has the wrong lifecycle request version"
            decodeLifecycleVariant variant fields
        _ -> Left "has fewer than three rooted lifecycle request fields"
    require
        (renderRootedLifecycleRequestKernel request == raw)
        "is not a canonical rooted lifecycle request"
    pure request

decodeLifecycleVariant :: ByteString -> [ByteString] -> Either Text RootedLifecycleRequest
decodeLifecycleVariant "open-frame" [nonce] = rootedOpenFrameRequestKernel nonce
decodeLifecycleVariant "open-frame" _ = Left "open-frame has the wrong field count"
decodeLifecycleVariant "next-node" fields =
    decodeLifecyclePostOpen rootedNextNodeRequestKernel fields
decodeLifecycleVariant "settle-node" fields =
    decodeLifecyclePostOpenBody rootedSettleNodeRequestKernel fields
decodeLifecycleVariant "descend-result" fields =
    decodeLifecyclePostOpenBody rootedDescendResultRequestKernel fields
decodeLifecycleVariant "close-frame" fields =
    decodeLifecyclePostOpen rootedCloseFrameRequestKernel fields
decodeLifecycleVariant "receipt-confirm" fields =
    decodeLifecyclePostOpen rootedReceiptConfirmRequestKernel fields
decodeLifecycleVariant _ _ = Left "has an unknown rooted lifecycle request variant"

decodeLifecyclePostOpen ::
    ([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> Either Text RootedLifecycleRequest) ->
    [ByteString] ->
    Either Text RootedLifecycleRequest
decodeLifecyclePostOpen makeRequest fields = case fields of
    [pathRaw, sessionRaw, stageRaw, ordinalRaw, nonce, predecessorRaw] -> do
        path <- decodeLifecyclePath pathRaw
        session <- decodeLifecycleText "session" sessionRaw
        stage <- decodeLifecycleText "stage" stageRaw
        ordinal <- decodeLifecycleOrdinal ordinalRaw
        predecessor <- decodeLifecyclePredecessor predecessorRaw
        makeRequest path session stage ordinal nonce predecessor
    _ -> Left "post-open rooted lifecycle request has the wrong field count"

decodeLifecyclePostOpenBody ::
    ([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> ByteString -> Either Text RootedLifecycleRequest) ->
    [ByteString] ->
    Either Text RootedLifecycleRequest
decodeLifecyclePostOpenBody makeRequest fields = case reverse fields of
    body : reversedCommon ->
        decodeLifecyclePostOpen
            ( \path session stage ordinal nonce predecessor ->
                makeRequest path session stage ordinal nonce predecessor body
            )
            (reverse reversedCommon)
    _ -> Left "body-bearing rooted lifecycle request has the wrong field count"

decodeLifecyclePath :: ByteString -> Either Text [Text]
decodeLifecyclePath raw = do
    components <- collectLifecyclePathFrames raw
    require
        (not (null components))
        "has an empty requester path"
    mapM (decodeLifecycleText "requester path component") components

decodeLifecycleText :: Text -> ByteString -> Either Text Text
decodeLifecycleText label raw = do
    require (not (ByteString.null raw)) ("has an empty " <> label)
    require
        (ByteString.length raw <= rootedLifecycleTextLimit)
        ("has an oversized " <> label)
    value <- case TextEncoding.decodeUtf8' raw of
        Left _ -> Left ("has a " <> label <> " that is not valid UTF-8")
        Right decoded -> Right decoded
    requireLifecycleText label value
    pure value

decodeLifecyclePredecessor :: ByteString -> Either Text Text
decodeLifecyclePredecessor raw = do
    require
        (ByteString.length raw == 64)
        "has a predecessor response digest whose width is not 64 bytes"
    decodeDigest "predecessor response" raw

decodeLifecycleOrdinal :: ByteString -> Either Text Word64
decodeLifecycleOrdinal raw = do
    require (ByteString.length raw == 8) "has a noncanonical ordinal width"
    let ordinal = bigEndianWord64 (ByteString.unpack raw)
    require (ordinal /= 0) "has a zero ordinal"
    pure ordinal

-- | Render the exact canonical request wire.
renderRootedLifecycleRequestKernel :: RootedLifecycleRequest -> ByteString
renderRootedLifecycleRequestKernel request = case request of
    OpenFrame nonce -> lifecycleRequestWire "open-frame" [nonce]
    NextNode path session stage ordinal nonce predecessor ->
        lifecyclePostOpenWire "next-node" path session stage ordinal nonce predecessor []
    SettleNode path session stage ordinal nonce predecessor body ->
        lifecyclePostOpenWire "settle-node" path session stage ordinal nonce predecessor [body]
    DescendResult path session stage ordinal nonce predecessor body ->
        lifecyclePostOpenWire "descend-result" path session stage ordinal nonce predecessor [body]
    CloseFrame path session stage ordinal nonce predecessor ->
        lifecyclePostOpenWire "close-frame" path session stage ordinal nonce predecessor []
    ReceiptConfirm path session stage ordinal nonce predecessor ->
        lifecyclePostOpenWire "receipt-confirm" path session stage ordinal nonce predecessor []

lifecyclePostOpenWire ::
    ByteString ->
    [Text] ->
    Text ->
    Text ->
    Word64 ->
    ByteString ->
    Text ->
    [ByteString] ->
    ByteString
lifecyclePostOpenWire variant path session stage ordinal nonce predecessor body =
    lifecycleRequestWire
        variant
        ( [ renderLifecyclePath path
          , TextEncoding.encodeUtf8 session
          , TextEncoding.encodeUtf8 stage
          , ByteString.pack (word64BigEndian ordinal)
          , nonce
          , TextEncoding.encodeUtf8 predecessor
          ]
            ++ body
        )

lifecycleRequestWire :: ByteString -> [ByteString] -> ByteString
lifecycleRequestWire variant fields =
    ByteString.concat
        (map rootedFrame ([rootedLifecycleDomain, rootedLifecycleVersion, variant] ++ fields))

renderLifecyclePath :: [Text] -> ByteString
renderLifecyclePath =
    ByteString.concat . map (rootedFrame . TextEncoding.encodeUtf8)

-- | Eliminate the closed request through exactly one of six callbacks.
withRootedLifecycleRequestKernel ::
    RootedLifecycleRequest ->
    (ByteString -> result) ->
    ([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> result) ->
    ([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> ByteString -> result) ->
    ([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> ByteString -> result) ->
    ([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> result) ->
    ([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> result) ->
    result
withRootedLifecycleRequestKernel request onOpen onNext onSettle onDescend onClose onReceipt =
    case request of
        OpenFrame nonce -> onOpen nonce
        NextNode path session stage ordinal nonce predecessor ->
            onNext path session stage ordinal nonce predecessor
        SettleNode path session stage ordinal nonce predecessor body ->
            onSettle path session stage ordinal nonce predecessor body
        DescendResult path session stage ordinal nonce predecessor body ->
            onDescend path session stage ordinal nonce predecessor body
        CloseFrame path session stage ordinal nonce predecessor ->
            onClose path session stage ordinal nonce predecessor
        ReceiptConfirm path session stage ordinal nonce predecessor ->
            onReceipt path session stage ordinal nonce predecessor

collectLifecycleFrames :: ByteString -> Either Text [ByteString]
collectLifecycleFrames = collect 10 takeLifecycleFrame "has more than ten rooted lifecycle request fields"

collectLifecyclePathFrames :: ByteString -> Either Text [ByteString]
collectLifecyclePathFrames =
    collect rootedLifecyclePathLimit takeLifecyclePathFrame "has more than 256 requester path components"

collect ::
    Int ->
    (ByteString -> Either Text (ByteString, ByteString)) ->
    Text ->
    ByteString ->
    Either Text [ByteString]
collect limit takeFrame tooMany = go 0 []
  where
    go count frames raw
        | ByteString.null raw = Right (reverse frames)
        | count >= limit = Left tooMany
        | otherwise = do
            (field, trailing) <- takeFrame raw
            go (count + 1) (field : frames) trailing

takeLifecycleFrame :: ByteString -> Either Text (ByteString, ByteString)
takeLifecycleFrame = takeLifecycleBoundedFrame rootedLifecycleWireLimit "rooted lifecycle request field"

takeLifecyclePathFrame :: ByteString -> Either Text (ByteString, ByteString)
takeLifecyclePathFrame = takeLifecycleBoundedFrame rootedLifecycleTextLimit "requester path component"

takeLifecycleBoundedFrame ::
    Int ->
    Text ->
    ByteString ->
    Either Text (ByteString, ByteString)
takeLifecycleBoundedFrame limit label raw
    | ByteString.length raw < 8 = Left (label <> " is truncated before its frame header")
    | declared > fromIntegral limit = Left (label <> " is oversized")
    | fromIntegral (ByteString.length body) < declared = Left (label <> " is truncated")
    | otherwise = Right (ByteString.splitAt (fromIntegral declared) body)
  where
    (header, body) = ByteString.splitAt 8 raw
    declared = bigEndianWord64 (ByteString.unpack header)

-- Rooted lifecycle response

-- | One closed descriptive response.  Possession grants no authority.
data RootedLifecycleResponse
    = Opened Text [Text] Text Text Word64 ByteString
    | Prepared Text [Text] Text Text Word64 ByteString ByteString ByteString ByteString ByteString ByteString
    | Descend Text [Text] Text Text Word64 ByteString ByteString ByteString
    | Settled Text [Text] Text Text Word64 ByteString ByteString ByteString
    | FrameComplete Text [Text] Text Text Word64 ByteString ByteString ByteString
    | ReceiptRecorded Text [Text] Text Text Word64 ByteString Text ByteString
    | Refused Text [Text] Text Text Word64 ByteString Text ByteString

rootedLifecycleResponseDomain :: ByteString
rootedLifecycleResponseDomain = "hostbootstrap/rooted-lifecycle-response"

rootedLifecycleResponseSignatureBytes :: Int
rootedLifecycleResponseSignatureBytes = 64

rootedOpenedResponseUnsignedKernel :: Text -> [Text] -> Text -> Text -> Word64 -> Either Text ByteString
rootedOpenedResponseUnsignedKernel digest path session stage ordinal = do
    requireResponseCommon digest path session stage ordinal
    boundedResponseUnsigned (responseWire "opened" (responseCommon digest path session stage ordinal))

rootedPreparedResponseUnsignedKernel :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> Either Text ByteString
rootedPreparedResponseUnsignedKernel requestDigest path lifecycleSession lifecycleStage lifecycleOrdinal nonce node dependencies operationGate projectedGates = do
    let digest = requestDigestText requestDigest
        session = lifecycleSessionText lifecycleSession
        stage = lifecycleStageText lifecycleStage
        ordinal = lifecycleOrdinalWord64 lifecycleOrdinal
    requireResponsePostOpen digest path session stage ordinal nonce
    body <- preparedResponseBody node dependencies operationGate projectedGates
    boundedResponseUnsigned (responsePostOpenWire "prepared" digest path session stage ordinal nonce body)

rootedDescendResponseUnsignedKernel :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString
rootedDescendResponseUnsignedKernel = opaqueResponseUnsigned "descend"

rootedSettledResponseUnsignedKernel :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString
rootedSettledResponseUnsignedKernel = opaqueResponseUnsigned "settled"

rootedFrameCompleteResponseUnsignedKernel :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString
rootedFrameCompleteResponseUnsignedKernel = opaqueResponseUnsigned "frame-complete"

rootedReceiptRecordedResponseUnsignedKernel :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> PredecessorDigest -> Either Text ByteString
rootedReceiptRecordedResponseUnsignedKernel requestDigest path lifecycleSession lifecycleStage lifecycleOrdinal nonce predecessorDigest = do
    let digest = requestDigestText requestDigest
        session = lifecycleSessionText lifecycleSession
        stage = lifecycleStageText lifecycleStage
        ordinal = lifecycleOrdinalWord64 lifecycleOrdinal
        completionDigest = predecessorDigestText predecessorDigest
    requireResponsePostOpen digest path session stage ordinal nonce
    requireDigest "completed response" completionDigest
    boundedResponseUnsigned (responsePostOpenWire "receipt-recorded" digest path session stage ordinal nonce (TextEncoding.encodeUtf8 completionDigest))

rootedRefusedResponseUnsignedKernel :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> Text -> Either Text ByteString
rootedRefusedResponseUnsignedKernel requestDigest path lifecycleSession lifecycleStage lifecycleOrdinal nonce detail = do
    let digest = requestDigestText requestDigest
        session = lifecycleSessionText lifecycleSession
        stage = lifecycleStageText lifecycleStage
        ordinal = lifecycleOrdinalWord64 lifecycleOrdinal
    requireResponsePostOpen digest path session stage ordinal nonce
    requireLifecycleText "refusal detail" detail
    boundedResponseUnsigned (responsePostOpenWire "refused" digest path session stage ordinal nonce (TextEncoding.encodeUtf8 detail))

opaqueResponseUnsigned :: ByteString -> RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString
opaqueResponseUnsigned variant requestDigest path lifecycleSession lifecycleStage lifecycleOrdinal nonce body = do
    let digest = requestDigestText requestDigest
        session = lifecycleSessionText lifecycleSession
        stage = lifecycleStageText lifecycleStage
        ordinal = lifecycleOrdinalWord64 lifecycleOrdinal
    requireResponsePostOpen digest path session stage ordinal nonce
    requireResponseBody body
    boundedResponseUnsigned (responsePostOpenWire variant digest path session stage ordinal nonce body)

requireResponseCommon :: Text -> [Text] -> Text -> Text -> Word64 -> Either Text ()
requireResponseCommon digest path session stage ordinal = do
    requireDigest "rooted lifecycle request" digest
    require (not (null path) && length path <= rootedLifecyclePathLimit) "has an invalid response path cardinality"
    mapM_ (requireLifecycleText "response path component") path
    requireLifecycleText "response session" session
    requireLifecycleText "response stage" stage
    require (ordinal /= 0) "has a zero response ordinal"

requireResponsePostOpen :: Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> Either Text ()
requireResponsePostOpen digest path session stage ordinal nonce =
    requireResponseCommon digest path session stage ordinal >> requireLifecycleNonce nonce

requireResponseBody :: ByteString -> Either Text ()
requireResponseBody body = do
    require (not (ByteString.null body)) "has an empty rooted lifecycle response body"
    require (ByteString.length body <= rootedLifecycleBodyLimit) "has an oversized rooted lifecycle response body"

preparedResponseBody :: ByteString -> ByteString -> ByteString -> ByteString -> Either Text ByteString
preparedResponseBody node dependencies operationGate projectedGates = do
    mapM_ requireResponseBody [node, dependencies, operationGate, projectedGates]
    let body = ByteString.concat (map rootedFrame [node, dependencies, operationGate, projectedGates])
    requireResponseBody body
    pure body

responseCommon :: Text -> [Text] -> Text -> Text -> Word64 -> [ByteString]
responseCommon digest path session stage ordinal =
    [ TextEncoding.encodeUtf8 digest
    , renderLifecyclePath path
    , TextEncoding.encodeUtf8 session
    , TextEncoding.encodeUtf8 stage
    , ByteString.pack (word64BigEndian ordinal)
    ]

responseWire :: ByteString -> [ByteString] -> ByteString
responseWire variant fields = ByteString.concat (map rootedFrame ([rootedLifecycleResponseDomain, rootedLifecycleVersion, variant] ++ fields))

responsePostOpenWire :: ByteString -> Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> ByteString
responsePostOpenWire variant digest path session stage ordinal nonce body =
    responseWire variant (responseCommon digest path session stage ordinal ++ [nonce, body])

boundedResponseUnsigned :: ByteString -> Either Text ByteString
boundedResponseUnsigned wire = do
    require (ByteString.length wire + 8 + rootedLifecycleResponseSignatureBytes <= rootedLifecycleWireLimit) "is larger than the bounded rooted lifecycle response"
    pure wire

rootedLifecycleResponseFromUnsignedKernel :: ByteString -> ByteString -> Either Text RootedLifecycleResponse
rootedLifecycleResponseFromUnsignedKernel unsigned signature = do
    require (ByteString.length signature == rootedLifecycleResponseSignatureBytes) "has a rooted lifecycle response signature whose width is not 64 bytes"
    withUnsignedResponse
        unsigned
        (\digest path session stage ordinal -> Opened digest path session stage ordinal signature)
        (\digest path session stage ordinal nonce node dependencies operationGate projectedGates -> Prepared digest path session stage ordinal nonce node dependencies operationGate projectedGates signature)
        (\digest path session stage ordinal nonce body -> Descend digest path session stage ordinal nonce body signature)
        (\digest path session stage ordinal nonce body -> Settled digest path session stage ordinal nonce body signature)
        (\digest path session stage ordinal nonce body -> FrameComplete digest path session stage ordinal nonce body signature)
        (\digest path session stage ordinal nonce completion -> ReceiptRecorded digest path session stage ordinal nonce completion signature)
        (\digest path session stage ordinal nonce detail -> Refused digest path session stage ordinal nonce detail signature)

rootedLifecycleResponseFromWireKernel :: ByteString -> Either Text RootedLifecycleResponse
rootedLifecycleResponseFromWireKernel raw = do
    require (ByteString.length raw <= rootedLifecycleWireLimit) "is larger than the bounded rooted lifecycle response"
    frames <- collect 11 takeLifecycleFrame "has more than eleven rooted lifecycle response fields" raw
    case reverse frames of
        signature : reversedUnsigned -> do
            let unsigned = ByteString.concat (map rootedFrame (reverse reversedUnsigned))
            response <- rootedLifecycleResponseFromUnsignedKernel unsigned signature
            require (renderRootedLifecycleResponseKernel response == raw) "is not a canonical rooted lifecycle response"
            pure response
        _ -> Left "has no rooted lifecycle response signature"

withUnsignedResponse :: ByteString -> (Text -> [Text] -> Text -> Text -> Word64 -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> Text -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> Text -> result) -> Either Text result
withUnsignedResponse raw onOpened onPrepared onDescend onSettled onComplete onReceipt onRefused = do
    _ <- boundedResponseUnsigned raw
    frames <- collect 10 takeLifecycleFrame "has more than ten unsigned rooted lifecycle response fields" raw
    case frames of
        domain : version : variant : fields -> do
            require (domain == rootedLifecycleResponseDomain) "has the wrong lifecycle response domain"
            require (version == rootedLifecycleVersion) "has the wrong lifecycle response version"
            decodeUnsignedResponse raw variant fields onOpened onPrepared onDescend onSettled onComplete onReceipt onRefused
        _ -> Left "has fewer than three rooted lifecycle response fields"

decodeUnsignedResponse :: ByteString -> ByteString -> [ByteString] -> (Text -> [Text] -> Text -> Text -> Word64 -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> Text -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> Text -> result) -> Either Text result
decodeUnsignedResponse raw variant fields onOpened onPrepared onDescend onSettled onComplete onReceipt onRefused = case (variant, fields) of
    ("opened", [digestRaw, pathRaw, sessionRaw, stageRaw, ordinalRaw]) -> do
        (digest, path, session, stage, ordinal) <- decodeResponseCommon digestRaw pathRaw sessionRaw stageRaw ordinalRaw
        canonical <- rootedOpenedResponseUnsignedKernel digest path session stage ordinal
        require (canonical == raw) "is not a canonical opened response"
        pure (onOpened digest path session stage ordinal)
    ("prepared", postFields) -> do
        (digest, path, session, stage, ordinal, nonce, body) <- decodeResponsePost postFields
        preparedFields <- decodePreparedResponseBody body
        case preparedFields of
            [node, dependencies, operationGate, projectedGates] -> do
                checkedDigest <- mkRequestDigest digest
                checkedSession <- mkLifecycleSession session
                checkedStage <- mkLifecycleStage stage
                checkedOrdinal <- mkLifecycleOrdinal ordinal
                canonical <- rootedPreparedResponseUnsignedKernel checkedDigest path checkedSession checkedStage checkedOrdinal nonce node dependencies operationGate projectedGates
                require (canonical == raw) "is not a canonical prepared response"
                pure (onPrepared digest path session stage ordinal nonce node dependencies operationGate projectedGates)
            _ -> Left "has the wrong prepared response field count"
    ("descend", postFields) -> decodeOpaqueResponse raw rootedDescendResponseUnsignedKernel onDescend postFields
    ("settled", postFields) -> decodeOpaqueResponse raw rootedSettledResponseUnsignedKernel onSettled postFields
    ("frame-complete", postFields) -> decodeOpaqueResponse raw rootedFrameCompleteResponseUnsignedKernel onComplete postFields
    ("receipt-recorded", postFields) -> do
        (digest, path, session, stage, ordinal, nonce, body) <- decodeResponsePost postFields
        completion <- decodeResponseDigest "completed response" body
        checkedDigest <- mkRequestDigest digest
        checkedSession <- mkLifecycleSession session
        checkedStage <- mkLifecycleStage stage
        checkedOrdinal <- mkLifecycleOrdinal ordinal
        checkedPredecessor <- mkPredecessorDigest completion
        canonical <- rootedReceiptRecordedResponseUnsignedKernel checkedDigest path checkedSession checkedStage checkedOrdinal nonce checkedPredecessor
        require (canonical == raw) "is not a canonical receipt-recorded response"
        pure (onReceipt digest path session stage ordinal nonce completion)
    ("refused", postFields) -> do
        (digest, path, session, stage, ordinal, nonce, body) <- decodeResponsePost postFields
        detail <- decodeLifecycleText "refusal detail" body
        checkedDigest <- mkRequestDigest digest
        checkedSession <- mkLifecycleSession session
        checkedStage <- mkLifecycleStage stage
        checkedOrdinal <- mkLifecycleOrdinal ordinal
        canonical <- rootedRefusedResponseUnsignedKernel checkedDigest path checkedSession checkedStage checkedOrdinal nonce detail
        require (canonical == raw) "is not a canonical refused response"
        pure (onRefused digest path session stage ordinal nonce detail)
    _ -> Left "has an unknown rooted lifecycle response variant or field count"

decodeResponseCommon :: ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> Either Text (Text, [Text], Text, Text, Word64)
decodeResponseCommon digestRaw pathRaw sessionRaw stageRaw ordinalRaw = do
    digest <- decodeResponseDigest "rooted lifecycle request" digestRaw
    path <- decodeLifecyclePath pathRaw
    session <- decodeLifecycleText "response session" sessionRaw
    stage <- decodeLifecycleText "response stage" stageRaw
    ordinal <- decodeLifecycleOrdinal ordinalRaw
    pure (digest, path, session, stage, ordinal)

decodeResponsePost :: [ByteString] -> Either Text (Text, [Text], Text, Text, Word64, ByteString, ByteString)
decodeResponsePost [digestRaw, pathRaw, sessionRaw, stageRaw, ordinalRaw, nonce, body] = do
    (digest, path, session, stage, ordinal) <- decodeResponseCommon digestRaw pathRaw sessionRaw stageRaw ordinalRaw
    requireLifecycleNonce nonce
    pure (digest, path, session, stage, ordinal, nonce, body)
decodeResponsePost _ = Left "post-open rooted lifecycle response has the wrong field count"

decodeResponseDigest :: Text -> ByteString -> Either Text Text
decodeResponseDigest label raw = do
    require (ByteString.length raw == 64) ("has a " <> label <> " digest whose width is not 64 bytes")
    decodeDigest label raw

decodePreparedResponseBody :: ByteString -> Either Text [ByteString]
decodePreparedResponseBody raw = do
    requireResponseBody raw
    fields <- collect 4 (takeLifecycleBoundedFrame rootedLifecycleBodyLimit "prepared response field") "has more than four prepared response fields" raw
    require (length fields == 4) "has fewer than four prepared response fields"
    mapM_ requireResponseBody fields
    pure fields

decodeOpaqueResponse :: ByteString -> (RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> result) -> [ByteString] -> Either Text result
decodeOpaqueResponse raw build use fields = do
    (digest, path, session, stage, ordinal, nonce, body) <- decodeResponsePost fields
    checkedDigest <- mkRequestDigest digest
    checkedSession <- mkLifecycleSession session
    checkedStage <- mkLifecycleStage stage
    checkedOrdinal <- mkLifecycleOrdinal ordinal
    canonical <- build checkedDigest path checkedSession checkedStage checkedOrdinal nonce body
    require (canonical == raw) "is not a canonical opaque rooted lifecycle response"
    pure (use digest path session stage ordinal nonce body)

rootedLifecycleResponseSignatureKernel :: RootedLifecycleResponse -> ByteString
rootedLifecycleResponseSignatureKernel response = withRootedLifecycleResponseKernel response (\_ _ _ _ _ signature -> signature) signaturePrepared signaturePost signaturePost signaturePost signatureReceipt signatureReceipt
  where
    signaturePrepared _ _ _ _ _ _ _ _ _ _ signature = signature
    signaturePost _ _ _ _ _ _ _ signature = signature
    signatureReceipt _ _ _ _ _ _ _ signature = signature

renderRootedLifecycleResponseKernel :: RootedLifecycleResponse -> ByteString
renderRootedLifecycleResponseKernel response = renderRootedLifecycleUnsignedResponseKernel response <> rootedFrame (rootedLifecycleResponseSignatureKernel response)

renderRootedLifecycleUnsignedResponseKernel :: RootedLifecycleResponse -> ByteString
renderRootedLifecycleUnsignedResponseKernel response = withRootedLifecycleResponseKernel response opened prepared descend settled complete receipt refused
  where
    opened digest path session stage ordinal _ = responseWire "opened" (responseCommon digest path session stage ordinal)
    prepared digest path session stage ordinal nonce node dependencies operationGate projectedGates _ = responsePostOpenWire "prepared" digest path session stage ordinal nonce (ByteString.concat (map rootedFrame [node, dependencies, operationGate, projectedGates]))
    descend digest path session stage ordinal nonce body _ = responsePostOpenWire "descend" digest path session stage ordinal nonce body
    settled digest path session stage ordinal nonce body _ = responsePostOpenWire "settled" digest path session stage ordinal nonce body
    complete digest path session stage ordinal nonce body _ = responsePostOpenWire "frame-complete" digest path session stage ordinal nonce body
    receipt digest path session stage ordinal nonce completion _ = responsePostOpenWire "receipt-recorded" digest path session stage ordinal nonce (TextEncoding.encodeUtf8 completion)
    refused digest path session stage ordinal nonce detail _ = responsePostOpenWire "refused" digest path session stage ordinal nonce (TextEncoding.encodeUtf8 detail)

rootedLifecycleResponsePairKernel :: Text -> RootedLifecycleRequest -> RootedLifecycleResponse -> Either Text (Maybe ByteString)
rootedLifecycleResponsePairKernel expected request = rootedLifecycleUnsignedResponsePairKernel expected request . renderRootedLifecycleUnsignedResponseKernel

rootedLifecycleUnsignedResponsePairKernel :: Text -> RootedLifecycleRequest -> ByteString -> Either Text (Maybe ByteString)
rootedLifecycleUnsignedResponsePairKernel expected request unsigned = do
    requireDigest "rooted lifecycle request" expected
    withUnsignedResponse unsigned opened prepared descend settled complete receipt refused >>= id
  where
    opened digest _ _ _ _ =
        require (digest == expected) "names a different rooted lifecycle request" >> case request of
            OpenFrame _ -> Right Nothing
            _ -> Left "opened does not answer this rooted lifecycle request"
    prepared digest path session stage ordinal nonce _ _ _ _ = post "prepared" Nothing Nothing digest path session stage ordinal nonce
    descend digest path session stage ordinal nonce _ = post "descend" Nothing Nothing digest path session stage ordinal nonce
    settled digest path session stage ordinal nonce _ = post "settled" Nothing Nothing digest path session stage ordinal nonce
    complete digest path session stage ordinal nonce body = post "frame-complete" (Just body) Nothing digest path session stage ordinal nonce
    receipt digest path session stage ordinal nonce completion = post "receipt-recorded" Nothing (Just completion) digest path session stage ordinal nonce
    refused digest path session stage ordinal nonce _ = post "refused" Nothing Nothing digest path session stage ordinal nonce
    post :: ByteString -> Maybe ByteString -> Maybe Text -> Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> Either Text (Maybe ByteString)
    post variant report completion digest path session _ _ nonce = do
        require (digest == expected) "names a different rooted lifecycle request"
        (requestPath, requestSession, requestNonce, predecessor) <- case request of
            NextNode p s _ _ n _ | variant `elem` ["prepared", "descend", "refused"] -> Right (p, s, n, Nothing)
            SettleNode p s _ _ n _ _ | variant `elem` ["settled", "refused"] -> Right (p, s, n, Nothing)
            DescendResult p s _ _ n _ _ | variant `elem` ["settled", "refused"] -> Right (p, s, n, Nothing)
            CloseFrame p s _ _ n _ | variant `elem` ["frame-complete", "refused"] -> Right (p, s, n, Nothing)
            ReceiptConfirm p s _ _ n predecessorDigest | variant `elem` ["receipt-recorded", "refused"] -> Right (p, s, n, Just predecessorDigest)
            _ -> Left "rooted lifecycle response does not answer this request family"
        require (path == requestPath && session == requestSession && nonce == requestNonce) "does not echo the rooted lifecycle request coordinates"
        case (completion, predecessor) of
            (Just actual, Just wanted) -> require (actual == wanted) "does not name the confirmed frame-complete response"
            (Just _, Nothing) -> Left "receipt-recorded does not answer a receipt confirmation"
            _ -> Right ()
        pure report

withRootedLifecycleResponseKernel :: RootedLifecycleResponse -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> Text -> ByteString -> result) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> Text -> ByteString -> result) -> result
withRootedLifecycleResponseKernel response onOpened onPrepared onDescend onSettled onComplete onReceipt onRefused = case response of
    Opened digest path session stage ordinal signature -> onOpened digest path session stage ordinal signature
    Prepared digest path session stage ordinal nonce node dependencies operationGate projectedGates signature -> onPrepared digest path session stage ordinal nonce node dependencies operationGate projectedGates signature
    Descend digest path session stage ordinal nonce body signature -> onDescend digest path session stage ordinal nonce body signature
    Settled digest path session stage ordinal nonce body signature -> onSettled digest path session stage ordinal nonce body signature
    FrameComplete digest path session stage ordinal nonce body signature -> onComplete digest path session stage ordinal nonce body signature
    ReceiptRecorded digest path session stage ordinal nonce completion signature -> onReceipt digest path session stage ordinal nonce completion signature
    Refused digest path session stage ordinal nonce detail signature -> onRefused digest path session stage ordinal nonce detail signature


-- | Frame an already-fenced gate and its optional resource predecessor.
renderReversePreparedGateEnvelopeKernel :: ByteString -> Maybe ByteString -> Either Text ByteString
renderReversePreparedGateEnvelopeKernel gate predecessor = do
    _ <- readFencedPreparedGatePackageKernel gate
    case predecessor of
        Just bytes -> require (not (ByteString.null bytes)) "has an empty reverse predecessor"
        Nothing -> pure ()
    let presence = case predecessor of
            Nothing -> rootedFrame "absent"
            Just bytes -> rootedFrame "present" <> rootedFrame bytes
        encoded = rootedFrame "hostbootstrap/reverse-prepared-gate/v1" <> rootedFrame gate <> rootedFrame presence
    require (ByteString.length encoded <= rootedLifecycleBodyLimit) "has an oversized reverse gate envelope"
    pure encoded

-- | Decode the bounded, canonical envelope without granting authority.
readReversePreparedGateEnvelopeKernel :: ByteString -> Either Text (ByteString, Maybe ByteString)
readReversePreparedGateEnvelopeKernel raw = do
    require (ByteString.length raw <= rootedLifecycleBodyLimit) "has an oversized reverse gate envelope"
    (domain, a) <- takeRootedFrame raw
    require (domain == "hostbootstrap/reverse-prepared-gate/v1") "has another reverse gate envelope domain"
    (gate, b) <- takeRootedFrame a
    (presenceRaw, trailing) <- takeRootedFrame b
    require (ByteString.null trailing) "has trailing reverse gate envelope fields"
    (presence, payload) <- takeRootedFrame presenceRaw
    predecessor <- case presence of
        "absent" -> require (ByteString.null payload) "has trailing absent predecessor fields" >> pure Nothing
        "present" -> do
            (bytes, rest) <- takeRootedFrame payload
            require (ByteString.null rest) "has trailing predecessor fields"
            pure (Just bytes)
        _ -> Left "has an invalid reverse predecessor state"
    canonical <- renderReversePreparedGateEnvelopeKernel gate predecessor
    require (canonical == raw) "is not a canonical reverse gate envelope"
    pure (gate, predecessor)

-- | Ask the child to run only its retained recovery observer for one exact gate.
renderRecoveryObserveEnvelopeKernel :: ByteString -> Either Text ByteString
renderRecoveryObserveEnvelopeKernel gate = do
    _ <- readFencedPreparedGatePackageKernel gate
    let encoded = rootedFrame "hostbootstrap/recovery-observe/v1" <> rootedFrame gate
    require (ByteString.length encoded <= rootedLifecycleBodyLimit) "has an oversized recovery observe envelope"
    pure encoded

-- | Decode the bounded, canonical observe envelope without granting authority.
readRecoveryObserveEnvelopeKernel :: ByteString -> Either Text ByteString
readRecoveryObserveEnvelopeKernel raw = do
    require (ByteString.length raw <= rootedLifecycleBodyLimit) "has an oversized recovery observe envelope"
    (domain, a) <- takeRootedFrame raw
    require (domain == "hostbootstrap/recovery-observe/v1") "has another recovery observe envelope domain"
    (gate, trailing) <- takeRootedFrame a
    require (ByteString.null trailing) "has trailing recovery observe envelope fields"
    canonical <- renderRecoveryObserveEnvelopeKernel gate
    require (canonical == raw) "is not a canonical recovery observe envelope"
    pure gate

-- | The closed result a recovery observer reports, on the wire.
data RootedRecoveryResult
    = RootedRecoveryAbsent
    | RootedRecoveryPresent Text
    | RootedRecoveryForeign Text
    | RootedRecoveryInconclusive Text
    deriving (Eq, Show)

{- | One recovery observation as the child reports it: the exact operation,
record version and attempt of the gate it answers, the observer identity and
revision that produced it, and the closed result. It settles nothing.
-}
data RootedRecoveryObservation = RootedRecoveryObservation Text Word64 Word64 Text Word64 RootedRecoveryResult
    deriving (Eq, Show)

renderRootedRecoveryObservationKernel :: RootedRecoveryObservation -> Either Text ByteString
renderRootedRecoveryObservationKernel (RootedRecoveryObservation operation version attempt observer revision result) = do
    requireLifecycleText "recovery operation" operation
    requireLifecycleText "recovery observer" observer
    require (version > 0 && attempt > 0 && revision > 0) "has a zero recovery coordinate"
    (tag, detail) <- case result of
        RootedRecoveryAbsent -> Right ("absent", "")
        RootedRecoveryPresent identity -> named "present" identity
        RootedRecoveryForeign identity -> named "foreign" identity
        RootedRecoveryInconclusive reason -> named "inconclusive" reason
    let encoded =
            ByteString.concat
                ( map
                    rootedFrame
                    [ "hostbootstrap/rooted-recovery-observation/v1"
                    , TextEncoding.encodeUtf8 operation
                    , ByteString.pack (word64BigEndian version)
                    , ByteString.pack (word64BigEndian attempt)
                    , TextEncoding.encodeUtf8 observer
                    , ByteString.pack (word64BigEndian revision)
                    , tag
                    , detail
                    ]
                )
    require (ByteString.length encoded <= rootedLifecycleBodyLimit) "has an oversized recovery observation"
    pure encoded
  where
    named tag text = do
        requireLifecycleText "recovery detail" text
        Right (tag, TextEncoding.encodeUtf8 text)

-- | Strictly decode one canonical recovery observation.
readRootedRecoveryObservationKernel :: ByteString -> Either Text RootedRecoveryObservation
readRootedRecoveryObservationKernel raw = do
    require (ByteString.length raw <= rootedLifecycleBodyLimit) "has an oversized recovery observation"
    frames <- collectRecoveryFrames raw
    observation <- case frames of
        [domain, operationRaw, versionRaw, attemptRaw, observerRaw, revisionRaw, tag, detailRaw] -> do
            require (domain == "hostbootstrap/rooted-recovery-observation/v1") "has another recovery observation domain"
            operation <- decodeLifecycleText "recovery operation" operationRaw
            version <- decodeLifecycleOrdinal versionRaw
            attempt <- decodeLifecycleOrdinal attemptRaw
            observer <- decodeLifecycleText "recovery observer" observerRaw
            revision <- decodeLifecycleOrdinal revisionRaw
            result <- case tag of
                "absent" -> require (ByteString.null detailRaw) "has detail on an absent recovery result" >> Right RootedRecoveryAbsent
                "present" -> RootedRecoveryPresent <$> decodeLifecycleText "recovery detail" detailRaw
                "foreign" -> RootedRecoveryForeign <$> decodeLifecycleText "recovery detail" detailRaw
                "inconclusive" -> RootedRecoveryInconclusive <$> decodeLifecycleText "recovery detail" detailRaw
                _ -> Left "has an unknown recovery result"
            Right (RootedRecoveryObservation operation version attempt observer revision result)
        _ -> Left "does not have exactly eight recovery observation fields"
    canonical <- renderRootedRecoveryObservationKernel observation
    require (canonical == raw) "is not a canonical recovery observation"
    pure observation
  where
    collectRecoveryFrames bytes
        | ByteString.null bytes = Right []
        | otherwise = do
            (field, rest) <- takeRootedFrame bytes
            (field :) <$> collectRecoveryFrames rest

{- | Admit an observation only for the exact gate and observer it must answer:
the operation, record version, attempt, observer identity and revision must
all match. A mismatch refuses; admission settles nothing.
-}
admitRootedRecoveryObservationKernel ::
    Text -> Word64 -> Word64 -> Text -> Word64 -> RootedRecoveryObservation -> Either Text RootedRecoveryResult
admitRootedRecoveryObservationKernel operation version attempt observer revision (RootedRecoveryObservation observedOperation observedVersion observedAttempt observedObserver observedRevision result)
    | observedOperation /= operation = Left "the recovery observation names another operation"
    | observedVersion /= version || observedAttempt /= attempt = Left "the recovery observation answers another record version or attempt"
    | observedObserver /= observer || observedRevision /= revision = Left "the recovery observation came from another observer or revision"
    | otherwise = Right result

{- | The shipped recovery-observation act. It names the exact plan coordinates
the frame re-admits its plan under (profile, profile epoch, installed project,
store identity and plan digest), the frame and operation, the unresolved row's
record version and attempt, the observer identity and revision the plan binds,
and the frame's canonical child config. It carries no authority.
-}
data RecoveryObservationRequest = RecoveryObservationRequest Text Word64 Text Text Text Text Text Word64 Word64 Text Word64 ByteString
    deriving (Eq, Show)

recoveryObservationRequestDomain :: ByteString
recoveryObservationRequestDomain = "hostbootstrap/recovery-observation/request/v1"

renderRecoveryObservationRequestKernel :: RecoveryObservationRequest -> Either Text ByteString
renderRecoveryObservationRequestKernel (RecoveryObservationRequest profile epoch project store digest frame operation version attempt observer revision config) = do
    mapM_ (uncurry requireLifecycleText)
        [("recovery profile", profile), ("recovery project", project), ("recovery store", store), ("recovery plan digest", digest)
        , ("recovery frame", frame), ("recovery operation", operation), ("recovery observer", observer)]
    require (epoch > 0 && version > 0 && attempt > 0 && revision > 0) "has a zero recovery request coordinate"
    require (not (ByteString.null config)) "has an empty recovery child config"
    let word = ByteString.pack . word64BigEndian
        encoded =
            ByteString.concat
                ( map rootedFrame
                    [ recoveryObservationRequestDomain
                    , TextEncoding.encodeUtf8 profile, word epoch, TextEncoding.encodeUtf8 project, TextEncoding.encodeUtf8 store
                    , TextEncoding.encodeUtf8 digest, TextEncoding.encodeUtf8 frame, TextEncoding.encodeUtf8 operation
                    , word version, word attempt, TextEncoding.encodeUtf8 observer, word revision, config
                    ]
                )
    require (ByteString.length encoded <= rootedLifecycleBodyLimit) "has an oversized recovery observation request"
    pure encoded

-- | Whether the bytes claim the recovery-observation act; other acts fall through.
isRecoveryObservationRequestKernel :: ByteString -> Bool
isRecoveryObservationRequestKernel raw = case takeRootedFrame raw of
    Right (domain, _) -> domain == recoveryObservationRequestDomain
    Left _ -> False

-- | Strictly decode one canonical recovery-observation act.
readRecoveryObservationRequestKernel :: ByteString -> Either Text RecoveryObservationRequest
readRecoveryObservationRequestKernel raw = do
    require (ByteString.length raw <= rootedLifecycleBodyLimit) "has an oversized recovery observation request"
    frames <- collectFrames raw
    request <- case frames of
        [domain, profileRaw, epochRaw, projectRaw, storeRaw, digestRaw, frameRaw, operationRaw, versionRaw, attemptRaw, observerRaw, revisionRaw, config] -> do
            require (domain == recoveryObservationRequestDomain) "has another recovery observation request domain"
            RecoveryObservationRequest
                <$> decodeLifecycleText "recovery profile" profileRaw
                <*> decodeLifecycleOrdinal epochRaw
                <*> decodeLifecycleText "recovery project" projectRaw
                <*> decodeLifecycleText "recovery store" storeRaw
                <*> decodeLifecycleText "recovery plan digest" digestRaw
                <*> decodeLifecycleText "recovery frame" frameRaw
                <*> decodeLifecycleText "recovery operation" operationRaw
                <*> decodeLifecycleOrdinal versionRaw
                <*> decodeLifecycleOrdinal attemptRaw
                <*> decodeLifecycleText "recovery observer" observerRaw
                <*> decodeLifecycleOrdinal revisionRaw
                <*> pure config
        _ -> Left "does not have exactly thirteen recovery observation request fields"
    canonical <- renderRecoveryObservationRequestKernel request
    require (canonical == raw) "is not a canonical recovery observation request"
    pure request
  where
    collectFrames bytes
        | ByteString.null bytes = Right []
        | otherwise = do
            (field, rest) <- takeRootedFrame bytes
            (field :) <$> collectFrames rest

-- | One descriptive reverse transition over an exact predecessor.
data RootedReverseResource = RootedReverseResource Text Text ByteString ByteString
    deriving (Eq, Show)

-- | A reverse outcome and the exact durable transitions it reports.
data RootedReverseObservation = RootedReverseObservation Text ByteString [RootedReverseResource]
    deriving (Eq, Show)

renderRootedReverseObservationKernel :: RootedReverseObservation -> Either Text ByteString
renderRootedReverseObservationKernel (RootedReverseObservation operation observation resources) = do
    requireLifecycleText "reverse operation" operation
    require (not (ByteString.null observation)) "has an empty reverse observation"
    require (length resources <= rootedLifecyclePathLimit + 1) "has too many reverse resource transitions"
    let keys = [key | RootedReverseResource _ key _ _ <- resources]
    require (length keys == length (unique keys)) "has duplicate reverse resource transitions"
    mapM_ validate resources
    let encoded = ByteString.concat
            [ rootedFrame "hostbootstrap/reverse-node-observation/v1"
            , rootedFrame (TextEncoding.encodeUtf8 operation)
            , rootedFrame observation
            , rootedFrame (ByteString.concat (map encode resources))
            ]
    require (ByteString.length encoded <= rootedLifecycleBodyLimit) "has an oversized reverse observation"
    pure encoded
  where
    unique [] = []
    unique (key : rest) = key : unique (filter (/= key) rest)
    validate (RootedReverseResource frame key previous successor) = do
        requireLifecycleText "reverse resource frame" frame
        requireLifecycleText "reverse resource key" key
        require (not (ByteString.null previous) && not (ByteString.null successor)) "has an empty reverse resource transition"
    encode (RootedReverseResource frame key previous successor) = rootedFrame $ ByteString.concat
        [ rootedFrame (TextEncoding.encodeUtf8 frame)
        , rootedFrame (TextEncoding.encodeUtf8 key)
        , rootedFrame previous
        , rootedFrame successor
        ]

-- | Decode only the ordered resource subset belonging to this exact node and frame.
readRootedReverseObservationForPlanKernel :: Text -> Text -> [Text] -> ByteString -> Either Text RootedReverseObservation
readRootedReverseObservationForPlanKernel frame operation allowed raw = do
    require (ByteString.length raw <= rootedLifecycleBodyLimit) "has an oversized reverse observation"
    (domain, a) <- takeRootedFrame raw
    require (domain == "hostbootstrap/reverse-node-observation/v1") "has another reverse observation domain"
    (operationRaw, b) <- takeRootedFrame a
    (observation, c) <- takeRootedFrame b
    (resourceRaw, trailing) <- takeRootedFrame c
    require (ByteString.null trailing) "has trailing reverse observation fields"
    actualOperation <- decodeLifecycleText "reverse operation" operationRaw
    resources <- readResources 0 resourceRaw
    let result = RootedReverseObservation actualOperation observation resources
        keys = [key | RootedReverseResource _ key _ _ <- resources]
    canonical <- renderRootedReverseObservationKernel result
    require (canonical == raw) "has noncanonical reverse observation bytes"
    require (actualOperation == operation) "the reverse observation names another operation"
    require (all (\(RootedReverseResource actual _ _ _) -> actual == frame) resources) "a reverse resource names another frame"
    require (filter (`elem` keys) allowed == keys) "the reverse resources differ from the admitted order or membership"
    pure result
  where
    readResources count bytes
        | ByteString.null bytes = Right []
        | count >= rootedLifecyclePathLimit + 1 = Left "has too many reverse resource transitions"
        | otherwise = do
            (row, rest) <- takeRootedFrame bytes
            (frameRaw, a) <- takeRootedFrame row
            (keyRaw, b) <- takeRootedFrame a
            (previous, c) <- takeRootedFrame b
            (successor, trailing) <- takeRootedFrame c
            require (ByteString.null trailing) "has trailing reverse resource fields"
            resourceFrame <- decodeLifecycleText "reverse resource frame" frameRaw
            key <- decodeLifecycleText "reverse resource key" keyRaw
            (RootedReverseResource resourceFrame key previous successor :) <$> readResources (count + 1) rest

-- | A projected gate's use and optional durable resource settlement.
data RootedProjectedObservation = RootedProjectedObservation
    Text Bool (Maybe (Text, Maybe ByteString, ByteString))
    deriving (Eq, Show)

-- | The complete observation returned by one forward frame node.
data RootedNodeObservation = RootedNodeObservation
    Text Bool Text [RootedProjectedObservation]
    deriving (Eq, Show)

-- | Render bounded, canonical node and projection evidence.
renderRootedNodeObservationKernel :: RootedNodeObservation -> Either Text ByteString
renderRootedNodeObservationKernel (RootedNodeObservation operation succeeded detail projections) = do
    requireLifecycleText "observation operation" operation
    require (succeeded || not (Text.null detail)) "has an empty failure detail"
    require (length projections <= rootedLifecyclePathLimit + 1) "has too many projected observations"
    let keys = [key | RootedProjectedObservation key _ _ <- projections]
    require (length keys == length (unique keys)) "has duplicate projected observations"
    mapM_ validateProjection projections
    let encoded = ByteString.concat
            [ rootedFrame "hostbootstrap/forward-node-observation/v2"
            , rootedFrame (TextEncoding.encodeUtf8 operation)
            , rootedFrame (if succeeded then "succeeded" else "failed")
            , rootedFrame (TextEncoding.encodeUtf8 detail)
            , rootedFrame (ByteString.concat (map renderProjection projections))
            ]
    require (ByteString.length encoded <= rootedLifecycleBodyLimit) "has an oversized node observation"
    pure encoded
  where
    unique [] = []
    unique (key : rest) = key : unique (filter (/= key) rest)
    validateProjection (RootedProjectedObservation key taken settlement) = do
        requireLifecycleText "projected operation" key
        require (taken || settlement == Nothing) "an unused projection has a resource settlement"
        case settlement of
            Nothing -> pure ()
            Just (frame, _, bytes) -> do
                requireLifecycleText "resource frame" frame
                require (not (ByteString.null bytes)) "has an empty resource settlement"
    renderProjection (RootedProjectedObservation key taken settlement) = rootedFrame $ ByteString.concat
        [ rootedFrame (TextEncoding.encodeUtf8 key)
        , rootedFrame (if taken then "taken" else "unused")
        , rootedFrame (case settlement of
            Nothing -> rootedFrame "none"
            Just (frame, previous, bytes) -> ByteString.concat
                [ rootedFrame "resource"
                , rootedFrame (TextEncoding.encodeUtf8 frame)
                , rootedFrame (case previous of Nothing -> rootedFrame "absent"; Just old -> rootedFrame "present" <> rootedFrame old)
                , rootedFrame bytes
                ])
        ]

-- | Reject malformed, noncanonical, or oversized node observation bytes.
readRootedNodeObservationKernel :: ByteString -> Either Text RootedNodeObservation
readRootedNodeObservationKernel raw = do
    require (ByteString.length raw <= rootedLifecycleBodyLimit) "has an oversized node observation"
    (domain, a) <- takeRootedFrame raw
    require (domain == "hostbootstrap/forward-node-observation/v2") "has another node observation domain"
    (operationRaw, b) <- takeRootedFrame a
    (status, c) <- takeRootedFrame b
    (detailRaw, d) <- takeRootedFrame c
    (projectedRaw, trailing) <- takeRootedFrame d
    require (ByteString.null trailing) "has trailing node observation fields"
    operation <- decodeLifecycleText "observation operation" operationRaw
    succeeded <- case status of "succeeded" -> Right True; "failed" -> Right False; _ -> Left "has an invalid node outcome"
    detail <- either (const (Left "has non-UTF-8 observation detail")) Right (TextEncoding.decodeUtf8' detailRaw)
    projections <- readProjections projectedRaw
    let result = RootedNodeObservation operation succeeded detail projections
    canonical <- renderRootedNodeObservationKernel result
    require (canonical == raw) "has noncanonical node observation bytes"
    pure result
  where
    readProjections bytes = go 0 bytes
    go count bytes
        | ByteString.null bytes = Right []
        | count >= rootedLifecyclePathLimit + 1 = Left "has too many projected observations"
        | otherwise = do
            (row, rest) <- takeRootedFrame bytes
            projection <- readProjection row
            (projection :) <$> go (count + 1) rest
    readProjection row = do
        (keyRaw, a) <- takeRootedFrame row
        (useRaw, b) <- takeRootedFrame a
        (settlementRaw, trailing) <- takeRootedFrame b
        require (ByteString.null trailing) "has trailing projected observation fields"
        key <- decodeLifecycleText "projected operation" keyRaw
        taken <- case useRaw of "taken" -> Right True; "unused" -> Right False; _ -> Left "has an invalid projected gate state"
        (kind, payload) <- takeRootedFrame settlementRaw
        settlement <- case kind of
            "none" -> require (ByteString.null payload) "has trailing empty settlement fields" >> pure Nothing
            "resource" -> do
                (frameRaw, x) <- takeRootedFrame payload
                (previousRaw, y) <- takeRootedFrame x
                (bytes, end) <- takeRootedFrame y
                require (ByteString.null end) "has trailing resource settlement fields"
                frame <- decodeLifecycleText "resource frame" frameRaw
                (presence, oldPayload) <- takeRootedFrame previousRaw
                previous <- case presence of
                    "absent" -> require (ByteString.null oldPayload) "has trailing absent predecessor fields" >> pure Nothing
                    "present" -> do
                        (old, afterOld) <- takeRootedFrame oldPayload
                        require (ByteString.null afterOld) "has trailing predecessor fields"
                        pure (Just old)
                    _ -> Left "has an invalid predecessor state"
                pure (Just (frame, previous, bytes))
            _ -> Left "has an invalid resource settlement kind"
        pure (RootedProjectedObservation key taken settlement)

-- | Admit a node report only for the exact node and ordered projections in its plan.
readRootedNodeObservationForPlanKernel :: Text -> Text -> [Text] -> ByteString -> Either Text RootedNodeObservation
readRootedNodeObservationForPlanKernel frame node projections raw = do
    report@(RootedNodeObservation operation _ _ entries) <- readRootedNodeObservationKernel raw
    require (operation == node) "the observation names another node"
    require ([key | RootedProjectedObservation key _ _ <- entries] == node : projections) "the observation names other node or projected operations"
    require (case entries of RootedProjectedObservation _ True _ : _ -> True; _ -> False) "the node gate was not taken"
    require (all (belongsToFrame frame) entries) "a resource settlement names another frame"
    pure report
  where
    belongsToFrame expected (RootedProjectedObservation _ _ settlement) =
        case settlement of
            Nothing -> True
            Just (observed, _, _) -> observed == expected
