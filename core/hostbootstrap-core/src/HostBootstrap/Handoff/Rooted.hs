{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Neutral canonical bytes for one rooted handoff payload binding.

This Cabal-private module deliberately owns neither cryptography nor handoff
authority.  The exposed 'HostBootstrap.Handoff' facade fixes the binding to an
already authenticated edge, signs it through the live root broker, and admits
received bytes only after the ordinary one-use handoff has verified.
-}
module HostBootstrap.Handoff.Rooted
    ( RootedPayloadBinding
    , rootedPayloadBindingKernel
    , rootedPayloadBindingFromWireKernel
    , rootedPayloadBindingEdgeKernel
    , rootedPayloadDigestKernel
    , rootedChildConfigDigestKernel
    , rootedPayloadSignatureKernel
    , renderRootedPayloadBindingKernel
    , renderRootedPayloadUnsignedKernel
    , renderRootedPayloadUnsignedPartsKernel
    , RootedLifecycleRequest
    , rootedOpenFrameRequestKernel
    , rootedNextNodeRequestKernel
    , rootedSettleNodeRequestKernel
    , rootedDescendResultRequestKernel
    , rootedCloseFrameRequestKernel
    , rootedReceiptConfirmRequestKernel
    , rootedLifecycleRequestFromWireKernel
    , renderRootedLifecycleRequestKernel
    , withRootedLifecycleRequestKernel
    , RootedLifecycleResponse
    , rootedOpenedResponseUnsignedKernel
    , rootedPreparedResponseUnsignedKernel
    , rootedDescendResponseUnsignedKernel
    , rootedSettledResponseUnsignedKernel
    , rootedFrameCompleteResponseUnsignedKernel
    , rootedReceiptRecordedResponseUnsignedKernel
    , rootedRefusedResponseUnsignedKernel
    , rootedLifecycleResponseFromUnsignedKernel
    , rootedLifecycleResponseFromWireKernel
    , rootedLifecycleResponseSignatureKernel
    , renderRootedLifecycleResponseKernel
    , renderRootedLifecycleUnsignedResponseKernel
    , rootedLifecycleResponsePairKernel
    , rootedLifecycleUnsignedResponsePairKernel
    , withRootedLifecycleResponseKernel
    )
where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64, Word8)

-- | One root-signed complete-payload and child-config identity.
data RootedPayloadBinding scope brokerGeneration = RootedPayloadBinding
    ByteString
    Text
    Text
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
    Text ->
    Text ->
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
    payloadDigest <- decodeDigest "payload" payloadBytes
    childConfigDigest <- decodeDigest "child config" configBytes
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
    Text
rootedPayloadDigestKernel (RootedPayloadBinding _ digest _ _) = digest

rootedChildConfigDigestKernel ::
    RootedPayloadBinding scope brokerGeneration ->
    Text
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
    Text ->
    Text ->
    Either Text ByteString
renderRootedPayloadUnsignedPartsKernel edge payloadDigest childConfigDigest = do
    require (not (ByteString.null edge)) "has an empty edge binding"
    require
        (fromIntegral (ByteString.length edge) <= rootedFieldLimit)
        "has an oversized edge binding"
    requireDigest "payload" payloadDigest
    requireDigest "child config" childConfigDigest
    let unsigned = renderRootedPayloadUnsignedParts edge payloadDigest childConfigDigest
    require
        ( fromIntegral
            (ByteString.length unsigned + 8 + rootedPayloadSignatureBytes)
            <= rootedFieldLimit
        )
        "is larger than the bounded authentication field"
    pure unsigned

renderRootedPayloadUnsignedParts :: ByteString -> Text -> Text -> ByteString
renderRootedPayloadUnsignedParts edge payloadDigest childConfigDigest =
    ByteString.concat
        [ rootedFrame rootedPayloadDomain
        , rootedFrame rootedPayloadVersion
        , rootedFrame edge
        , rootedFrame (TextEncoding.encodeUtf8 payloadDigest)
        , rootedFrame (TextEncoding.encodeUtf8 childConfigDigest)
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
            (\path session stage ordinal nonce predecessor ->
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

rootedPreparedResponseUnsignedKernel :: Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> Either Text ByteString
rootedPreparedResponseUnsignedKernel digest path session stage ordinal nonce node dependencies operationGate projectedGates = do
    requireResponsePostOpen digest path session stage ordinal nonce
    body <- preparedResponseBody node dependencies operationGate projectedGates
    boundedResponseUnsigned (responsePostOpenWire "prepared" digest path session stage ordinal nonce body)

rootedDescendResponseUnsignedKernel :: Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> Either Text ByteString
rootedDescendResponseUnsignedKernel = opaqueResponseUnsigned "descend"

rootedSettledResponseUnsignedKernel :: Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> Either Text ByteString
rootedSettledResponseUnsignedKernel = opaqueResponseUnsigned "settled"

rootedFrameCompleteResponseUnsignedKernel :: Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> Either Text ByteString
rootedFrameCompleteResponseUnsignedKernel = opaqueResponseUnsigned "frame-complete"

rootedReceiptRecordedResponseUnsignedKernel :: Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> Text -> Either Text ByteString
rootedReceiptRecordedResponseUnsignedKernel digest path session stage ordinal nonce completionDigest = do
    requireResponsePostOpen digest path session stage ordinal nonce
    requireDigest "completed response" completionDigest
    boundedResponseUnsigned (responsePostOpenWire "receipt-recorded" digest path session stage ordinal nonce (TextEncoding.encodeUtf8 completionDigest))

rootedRefusedResponseUnsignedKernel :: Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> Text -> Either Text ByteString
rootedRefusedResponseUnsignedKernel digest path session stage ordinal nonce detail = do
    requireResponsePostOpen digest path session stage ordinal nonce
    requireLifecycleText "refusal detail" detail
    boundedResponseUnsigned (responsePostOpenWire "refused" digest path session stage ordinal nonce (TextEncoding.encodeUtf8 detail))

opaqueResponseUnsigned :: ByteString -> Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> Either Text ByteString
opaqueResponseUnsigned variant digest path session stage ordinal nonce body = do
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
    withUnsignedResponse unsigned
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
                canonical <- rootedPreparedResponseUnsignedKernel digest path session stage ordinal nonce node dependencies operationGate projectedGates
                require (canonical == raw) "is not a canonical prepared response"
                pure (onPrepared digest path session stage ordinal nonce node dependencies operationGate projectedGates)
            _ -> Left "has the wrong prepared response field count"
    ("descend", postFields) -> decodeOpaqueResponse raw rootedDescendResponseUnsignedKernel onDescend postFields
    ("settled", postFields) -> decodeOpaqueResponse raw rootedSettledResponseUnsignedKernel onSettled postFields
    ("frame-complete", postFields) -> decodeOpaqueResponse raw rootedFrameCompleteResponseUnsignedKernel onComplete postFields
    ("receipt-recorded", postFields) -> do
        (digest, path, session, stage, ordinal, nonce, body) <- decodeResponsePost postFields
        completion <- decodeResponseDigest "completed response" body
        canonical <- rootedReceiptRecordedResponseUnsignedKernel digest path session stage ordinal nonce completion
        require (canonical == raw) "is not a canonical receipt-recorded response"
        pure (onReceipt digest path session stage ordinal nonce completion)
    ("refused", postFields) -> do
        (digest, path, session, stage, ordinal, nonce, body) <- decodeResponsePost postFields
        detail <- decodeLifecycleText "refusal detail" body
        canonical <- rootedRefusedResponseUnsignedKernel digest path session stage ordinal nonce detail
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

decodeOpaqueResponse :: ByteString -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> Either Text ByteString) -> (Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> result) -> [ByteString] -> Either Text result
decodeOpaqueResponse raw build use fields = do
    (digest, path, session, stage, ordinal, nonce, body) <- decodeResponsePost fields
    canonical <- build digest path session stage ordinal nonce body
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
    opened digest _ _ _ _ = require (digest == expected) "names a different rooted lifecycle request" >> case request of
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
