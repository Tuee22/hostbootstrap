{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

module HostBootstrap.Lifecycle.Prepared.Internal (
    PreparedGate,
    preparedGatePlan,
    preparedGateOperation,
    preparedGateSession,
    preparedGateFence,
    preparedGateAttempt,
    preparedGateJournalVersion,
    mintPreparedGate,
    PreparedNodeGrant,
    renderPreparedGatePackageKernel,
    renderPreparedGatePackagesKernel,
    readPreparedGatePackageKernel,
    readPreparedGatePackagesKernel,
    renderPreparedNodeKeysKernel,
    mintPreparedNodeGrantKernel,
    withPreparedNodeGrantKernel,
    preparedNodeGrantResponseKernel,
) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)

{- | Proof that one operation's unknown phase was durably recorded before its
backend call, carrying the exact identities and indices that write established.

This module is internal to the package. The public
"HostBootstrap.Lifecycle.Prepared" module keeps the constructor and minting
function hidden.
-}
data PreparedGate = PreparedGate
    { preparedGatePlan :: Text
    , preparedGateOperation :: Text
    , preparedGateSession :: Text
    , preparedGateFence :: Word64
    , preparedGateAttempt :: Word64
    , preparedGateJournalVersion :: Word64
    }
    deriving (Eq, Show)

-- | Package-internal constructor used only after the durable write commits.
mintPreparedGate :: Text -> Text -> Text -> Word64 -> Word64 -> Word64 -> PreparedGate
mintPreparedGate = PreparedGate

{- | One root-owned authorization to run exactly one node's local effect.

A grant is what a storeless frame executor is given instead of the store. It
carries the canonical signed response the root already produced, the node it
authorizes, that node's ordered dependencies, and the gate packages proving
every durable unknown row was published and read back first. It carries no
store handle, journal state, session record, permit, or compare-and-swap
operation, so holding one lets a frame know it may act and know nothing about
how the root recorded that.

The ordering is the whole point. The producer cannot reach this constructor
until every exact unknown row — the node's own, then each projected operation
in the catalog's order — is durably present and re-read, so a grant is
evidence that preparation happened rather than a request that it should.

Only a @NextNode -> Prepared@ answer becomes one of these. A @Descend@ or a
@Refused@ answer is a different response family and has no constructor here at
all, which is why "the root told me to descend" can never be mistaken for
"the root authorized this effect".
-}
data PreparedNodeGrant
    scope rootPlanId brokerGeneration catalogId frame sessionId node verb
    where
    PreparedNodeGrant ::
        ByteString ->
        Text ->
        [Text] ->
        ByteString ->
        ByteString ->
        PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb

type role PreparedNodeGrant nominal nominal nominal nominal nominal nominal nominal nominal

instance
    Show (PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb)
    where
    show _ = "PreparedNodeGrant <root-signed>"

{- | Frame one operation's gate coordinates canonically.

Every variable-width value is length-framed and every fixed-width one is a
big-endian word, so the bytes are canonical rather than delimiter-joined. The
supersession generation stands where an ordinary operation gate carries its
fence epoch: for rooted work the broker generation is what invalidates a prior
permit, so it is the coordinate a stale package is caught by.
-}
renderPreparedGatePackageKernel ::
    Text -> Text -> Text -> Text -> Word64 -> Word64 -> Word64 -> ByteString
renderPreparedGatePackageKernel
    planDigest catalogIdentity frame session generation attempt journalVersion =
        ByteString.concat
            [ framed "hostbootstrap/prepared-node-gate"
            , framedWord 1
            , framed planDigest
            , framed catalogIdentity
            , framed frame
            , framed session
            , framedWord generation
            , framedWord attempt
            , framedWord journalVersion
            ]

{- | Frame one ordered operation-key list canonically.

The root names a node's ordered dependencies inside a response it signs, and
the frame that receives it compares them against the ordered keys its own plan
gave that node. Both sides therefore need one rendering rather than two, and it
lives beside the gate framings for the same reason they do: order is part of
the value, so a delimiter-joined list that reorders would still compare equal
while this one does not.
-}
renderPreparedNodeKeysKernel :: [Text] -> ByteString
renderPreparedNodeKeysKernel keys =
    ByteString.concat
        ( [ framed "hostbootstrap/prepared-node-keys"
          , framedWord 1
          , framedWord (fromIntegral (length keys))
          ]
            ++ map framed keys
        )

{- | Read back exactly the seven coordinates one gate package frames.

A storeless frame has no journal to read an attempt or a version off, so the
only place those two coordinates exist for it is inside the package the root
already signed. Reading them is therefore not a way around the durable write —
it is how a frame that never touches the store learns what the store recorded.

The decode is strict and canonical: the domain and version must be the exact
ones this module renders, every field must be present with nothing trailing,
and re-rendering the decoded coordinates must reproduce the input byte for
byte. So a package that decodes here is the one the root rendered rather than
one that merely parses into the same shape.
-}
readPreparedGatePackageKernel ::
    ByteString ->
    Either Text (Text, Text, Text, Text, Word64, Word64, Word64)
readPreparedGatePackageKernel raw = do
    fields <- takeFrames 9 raw
    case fields of
        [ domain
            , version
            , planDigest
            , catalogIdentity
            , frame
            , session
            , generation
            , attempt
            , journalVersion
            ] -> do
                requireGate (domain == "hostbootstrap/prepared-node-gate") "has the wrong gate package domain"
                requireGate (version == wordBytes 1) "has the wrong gate package version"
                decoded <-
                    (,,,,,,)
                        <$> gateText "plan digest" planDigest
                        <*> gateText "catalog identity" catalogIdentity
                        <*> gateText "frame" frame
                        <*> gateText "session" session
                        <*> gateWord "supersession generation" generation
                        <*> gateWord "attempt" attempt
                        <*> gateWord "journal version" journalVersion
                let (planName, catalogName, frameName, sessionName, epoch, attemptCount, rowVersion) =
                        decoded
                requireGate
                    ( renderPreparedGatePackageKernel
                        planName catalogName frameName sessionName epoch attemptCount rowVersion
                        == raw
                    )
                    "is not a canonical gate package"
                pure decoded
        _ -> Left (gateFailure "has the wrong gate package field count")

{- | Read back an ordered list of gate packages against its explicit count.

The count is checked rather than trusted, so a list that claims more or fewer
packages than it carries refuses instead of being read as the shorter prefix
both readings share.
-}
readPreparedGatePackagesKernel :: ByteString -> Either Text [ByteString]
readPreparedGatePackagesKernel raw = do
    (domain, afterDomain) <- takeFrame raw
    (version, afterVersion) <- takeFrame afterDomain
    (count, afterCount) <- takeFrame afterVersion
    requireGate (domain == "hostbootstrap/prepared-node-gates") "has the wrong gate list domain"
    requireGate (version == wordBytes 1) "has the wrong gate list version"
    declared <- gateWord "gate list count" count
    packages <- collectFrames afterCount []
    requireGate
        (fromIntegral (length packages) == declared)
        "does not carry the number of gate packages it declares"
    pure packages
  where
    collectFrames remaining collected
        | ByteString.null remaining = Right (reverse collected)
        | length collected >= maxGatePackages =
            Left (gateFailure "carries more gate packages than one node may project")
        | otherwise = do
            (package, trailing) <- takeFrame remaining
            collectFrames trailing (package : collected)

-- | Frame an ordered list of gate packages with an explicit count.
renderPreparedGatePackagesKernel :: [ByteString] -> ByteString
renderPreparedGatePackagesKernel packages =
    ByteString.concat
        ( [framed "hostbootstrap/prepared-node-gates", framedWord 1, framedWord (fromIntegral (length packages))]
            ++ map frame' packages
        )

{- | Package-internal constructor, reachable only after durable preparation. -}
mintPreparedNodeGrantKernel ::
    ByteString ->
    Text ->
    [Text] ->
    ByteString ->
    ByteString ->
    PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb
mintPreparedNodeGrantKernel = PreparedNodeGrant

{- | Read a grant's fixed evidence without opening any durable state.

The continuation receives the authorized node, its ordered dependencies, and
the two gate packages. It receives no store, session, permit, journal version,
or record key, and its result is fixed.
-}
withPreparedNodeGrantKernel ::
    PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb ->
    (Text -> [Text] -> ByteString -> ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
withPreparedNodeGrantKernel (PreparedNodeGrant _ node dependencies operationGate projectedGates) use =
    use node dependencies operationGate projectedGates

-- | The exact canonical signed response bytes the root already produced.
preparedNodeGrantResponseKernel ::
    PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb ->
    ByteString
preparedNodeGrantResponseKernel (PreparedNodeGrant signed _ _ _ _) = signed

framed :: Text -> ByteString
framed = frame' . TextEncoding.encodeUtf8

framedWord :: Word64 -> ByteString
framedWord = frame' . wordBytes

frame' :: ByteString -> ByteString
frame' payload =
    LazyByteString.toStrict (Builder.toLazyByteString (Builder.word64BE (fromIntegral (ByteString.length payload))))
        <> payload

wordBytes :: Word64 -> ByteString
wordBytes = LazyByteString.toStrict . Builder.toLazyByteString . Builder.word64BE

maxGatePackages :: Int
maxGatePackages = 256

maxGateFieldBytes :: Word64
maxGateFieldBytes = 4096

takeFrame :: ByteString -> Either Text (ByteString, ByteString)
takeFrame raw
    | ByteString.length raw < 8 = Left (gateFailure "is truncated before a gate frame header")
    | declared > maxGateFieldBytes = Left (gateFailure "declares an oversized gate frame")
    | fromIntegral (ByteString.length body) < declared =
        Left (gateFailure "is truncated inside a gate frame")
    | otherwise = Right (ByteString.splitAt (fromIntegral declared) body)
  where
    (header, body) = ByteString.splitAt 8 raw
    declared = ByteString.foldl' (\value byte -> (value `shiftL` 8) .|. fromIntegral byte) 0 header

takeFrames :: Int -> ByteString -> Either Text [ByteString]
takeFrames count = go count []
  where
    go 0 collected trailing
        | ByteString.null trailing = Right (reverse collected)
        | otherwise = Left (gateFailure "has trailing gate package bytes")
    go remaining collected raw = do
        (field, trailing) <- takeFrame raw
        go (remaining - 1) (field : collected) trailing

gateText :: Text -> ByteString -> Either Text Text
gateText label raw = do
    requireGate (not (ByteString.null raw)) ("has an empty " <> label)
    case TextEncoding.decodeUtf8' raw of
        Left _ -> Left (gateFailure ("has a " <> label <> " that is not valid UTF-8"))
        Right value -> Right value

gateWord :: Text -> ByteString -> Either Text Word64
gateWord label raw = do
    requireGate (ByteString.length raw == 8) ("has a noncanonical " <> label <> " width")
    Right (ByteString.foldl' (\value byte -> (value `shiftL` 8) .|. fromIntegral byte) 0 raw)

requireGate :: Bool -> Text -> Either Text ()
requireGate True _ = Right ()
requireGate False detail = Left (gateFailure detail)

gateFailure :: Text -> Text
gateFailure detail = "prepared node gate package: " <> detail
