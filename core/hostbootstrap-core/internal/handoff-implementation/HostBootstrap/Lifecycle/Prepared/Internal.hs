{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

module HostBootstrap.Lifecycle.Prepared.Internal (
    -- * The coordinates a gate is written in
    GatePlanDigest (..),
    GateOperationKey (..),
    GateSession (..),
    GateFence (..),
    GateAttempt (..),
    GateJournalVersion (..),
    GateUnknownPhase (..),
    GateCallDigest (..),
    GateCatalogIdentity (..),
    GateFrame (..),
    GateSupersessionGeneration (..),
    PreparedGate,
    preparedGatePlan,
    preparedGateOperation,
    preparedGateSession,
    preparedGateFence,
    preparedGateSupersessionGeneration,
    preparedGateAttempt,
    preparedGateJournalVersion,
    preparedGateEffect,
    bindPreparedGateEffect,
    mintPreparedGate,
    mintRoutedPreparedGate,
    PreparedNodeGrant,
    renderFencedPreparedGatePackageKernel,
    renderPreparedGatePackagesKernel,
    readFencedPreparedGatePackageKernel,
    renderEffectPreparedGatePackageKernel,
    readEffectPreparedGatePackageKernel,
    renderEffectProposalsKernel,
    readEffectProposalsKernel,
    readPreparedGatePackagesKernel,
    renderPreparedNodeKeysKernel,
    mintPreparedNodeGrantKernel,
    withPreparedNodeGrantKernel,
) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)

{- | The coordinate roles a prepared gate is written in.

Three of them are text and three are numbers, in that order, and the canonical
renderer beside them has the same shape. Two adjacent coordinates of the same
underlying type can therefore be transposed at the call site and be invisible
from mint to wire — the durable bytes are still well formed, and every later
comparison is between two values that were both written wrong. A newtype per
role makes the transposition a type error at the one place the coordinates are
supplied, and changes no runtime representation and no durable byte: the fields,
the accessors, and the framing are exactly what they were.
-}
newtype GatePlanDigest = GatePlanDigest Text
    deriving (Eq, Show)

newtype GateOperationKey = GateOperationKey Text
    deriving (Eq, Show)

newtype GateSession = GateSession Text
    deriving (Eq, Show)

newtype GateFence = GateFence Word64
    deriving (Eq, Show)

newtype GateAttempt = GateAttempt Word64
    deriving (Eq, Show)

newtype GateJournalVersion = GateJournalVersion Word64
    deriving (Eq, Show)

-- | The journaled unknown transition and the digest of the effect it permits.
newtype GateUnknownPhase = GateUnknownPhase Text
    deriving (Eq, Show)

newtype GateCallDigest = GateCallDigest Text
    deriving (Eq, Show)

-- | The catalog a rooted gate package names.
newtype GateCatalogIdentity = GateCatalogIdentity Text
    deriving (Eq, Show)

-- | The frame a rooted gate package names.
newtype GateFrame = GateFrame Text
    deriving (Eq, Show)

{- | What invalidates a prior rooted permit.

It stands where an ordinary operation gate carries its fence epoch, and it is a
different role, so it is a different type: writing one where the other belongs
is exactly the confusion these newtypes exist to refuse.
-}
newtype GateSupersessionGeneration = GateSupersessionGeneration Word64
    deriving (Eq, Show)

{- | Coordinates retained after publishing one operation's durable phase record.

The producer supplies the identities, fence and attempt; the journal version
is the one returned by the protected write.

This module is internal to the package. The public
"HostBootstrap.Lifecycle.Prepared" module keeps the constructor and minting
function hidden and exposes only ordinary coordinate readers.
-}
data PreparedGate = PreparedGate Text Text Text Word64 (Maybe Word64) Word64 Word64 (Maybe (GateUnknownPhase, GateCallDigest))
    deriving (Eq)

instance Show PreparedGate where
    showsPrec precedence (PreparedGate plan operation session fence supersession attempt journalVersion _) =
        showParen (precedence > 10) $
            showString "PreparedGate {preparedGatePlan = "
                . shows plan
                . showString ", preparedGateOperation = "
                . shows operation
                . showString ", preparedGateSession = "
                . shows session
                . showString ", preparedGateFence = "
                . shows fence
                . maybe id (\generation -> showString ", preparedGateSupersessionGeneration = " . shows generation) supersession
                . showString ", preparedGateAttempt = "
                . shows attempt
                . showString ", preparedGateJournalVersion = "
                . shows journalVersion
                . showString "}"

preparedGatePlan :: PreparedGate -> Text
preparedGatePlan (PreparedGate plan _ _ _ _ _ _ _) = plan

preparedGateOperation :: PreparedGate -> Text
preparedGateOperation (PreparedGate _ operation _ _ _ _ _ _) = operation

preparedGateSession :: PreparedGate -> Text
preparedGateSession (PreparedGate _ _ session _ _ _ _ _) = session

preparedGateFence :: PreparedGate -> Word64
preparedGateFence (PreparedGate _ _ _ fence _ _ _ _) = fence

preparedGateSupersessionGeneration :: PreparedGate -> Maybe Word64
preparedGateSupersessionGeneration (PreparedGate _ _ _ _ generation _ _ _) = generation

preparedGateAttempt :: PreparedGate -> Word64
preparedGateAttempt (PreparedGate _ _ _ _ _ attempt _ _) = attempt

preparedGateJournalVersion :: PreparedGate -> Word64
preparedGateJournalVersion (PreparedGate _ _ _ _ _ _ journalVersion _) = journalVersion

-- | Coordinates of the journaled effect, when the producer has bound them.
preparedGateEffect :: PreparedGate -> Maybe (GateUnknownPhase, GateCallDigest)
preparedGateEffect (PreparedGate _ _ _ _ _ _ _ effect) = effect

-- | Attach coordinates read from the same committed record as this gate.
bindPreparedGateEffect :: GateUnknownPhase -> GateCallDigest -> PreparedGate -> PreparedGate
bindPreparedGateEffect phase digest (PreparedGate plan operation session fence supersession attempt version _) =
    PreparedGate plan operation session fence supersession attempt version (Just (phase, digest))

-- | Package-internal constructor used only after the durable write commits.
mintPreparedGate ::
    GatePlanDigest ->
    GateOperationKey ->
    GateSession ->
    GateFence ->
    GateAttempt ->
    GateJournalVersion ->
    PreparedGate
mintPreparedGate
    (GatePlanDigest plan)
    (GateOperationKey operation)
    (GateSession session)
    (GateFence fence)
    (GateAttempt attempt)
    (GateJournalVersion journalVersion) =
        PreparedGate plan operation session fence Nothing attempt journalVersion Nothing

-- | Mint a routed gate without treating its broker generation as a fence epoch.
mintRoutedPreparedGate ::
    GatePlanDigest ->
    GateOperationKey ->
    GateSession ->
    GateSupersessionGeneration ->
    GateFence ->
    GateAttempt ->
    GateJournalVersion ->
    PreparedGate
mintRoutedPreparedGate
    (GatePlanDigest plan)
    (GateOperationKey operation)
    (GateSession session)
    (GateSupersessionGeneration generation)
    (GateFence fence)
    (GateAttempt attempt)
    (GateJournalVersion journalVersion) =
        PreparedGate plan operation session fence (Just generation) attempt journalVersion Nothing

{- | One root-owned authorization to run exactly one node's local effect.

A grant is what a storeless frame executor is given instead of the store. It
carries the node it authorizes, that node's ordered dependencies, and the gate
packages proving
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
data
    PreparedNodeGrant
        scope
        rootPlanId
        brokerGeneration
        catalogId
        frame
        sessionId
        node
        verb
    where
    PreparedNodeGrant ::
        Text ->
        [Text] ->
        ByteString ->
        ByteString ->
        PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb

type role PreparedNodeGrant nominal nominal nominal nominal nominal nominal nominal nominal

instance Show (PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb) where
    show _ = "PreparedNodeGrant <prepared>"

-- | Version 3 carries the operation fence independently of the broker generation.
renderFencedPreparedGatePackageKernel ::
    GatePlanDigest -> GateCatalogIdentity -> GateFrame -> GateSession -> GateOperationKey ->
    GateSupersessionGeneration -> GateFence -> GateAttempt -> GateJournalVersion -> ByteString
renderFencedPreparedGatePackageKernel
    (GatePlanDigest plan) (GateCatalogIdentity catalog) (GateFrame frame) (GateSession session)
    (GateOperationKey operation) (GateSupersessionGeneration generation) (GateFence fence)
    (GateAttempt attempt) (GateJournalVersion journalVersion) =
        ByteString.concat
            [ framed "hostbootstrap/prepared-node-gate"
            , framedWord 3
            , framed plan
            , framed catalog
            , framed frame
            , framed session
            , framed operation
            , framedWord generation
            , framedWord fence
            , framedWord attempt
            , framedWord journalVersion
            ]

-- | Decode the complete canonical fence-bearing form, refusing absent authority.
readFencedPreparedGatePackageKernel ::
    ByteString -> Either Text (Text, Text, Text, Text, Text, Word64, Word64, Word64, Word64)
readFencedPreparedGatePackageKernel raw = do
    fields <- takeFrames 11 raw
    case fields of
        [domain, version, plan, catalog, frame, session, operation, generation, fence, attempt, journalVersion] -> do
            requireGate (domain == "hostbootstrap/prepared-node-gate") "has the wrong gate package domain"
            requireGate (version == wordBytes 3) "has the wrong gate package version"
            decoded <-
                (,,,,,,,,)
                    <$> gateText "plan digest" plan
                    <*> gateText "catalog identity" catalog
                    <*> gateText "frame" frame
                    <*> gateText "session" session
                    <*> gateText "operation key" operation
                    <*> gateWord "supersession generation" generation
                    <*> gateWord "operation fence" fence
                    <*> gateWord "attempt" attempt
                    <*> gateWord "journal version" journalVersion
            let (planName, catalogName, frameName, sessionName, operationName, epoch, fenceEpoch, attemptCount, rowVersion) = decoded
            requireGate (epoch > 0) "has a zero supersession generation"
            requireGate (fenceEpoch > 0) "has a zero operation fence"
            requireGate (attemptCount > 0) "has a zero attempt"
            requireGate (rowVersion > 0) "has a zero journal version"
            requireGate
                ( renderFencedPreparedGatePackageKernel
                    (GatePlanDigest planName) (GateCatalogIdentity catalogName) (GateFrame frameName)
                    (GateSession sessionName) (GateOperationKey operationName) (GateSupersessionGeneration epoch)
                    (GateFence fenceEpoch) (GateAttempt attemptCount) (GateJournalVersion rowVersion) == raw
                )
                "is not a canonical gate package"
            pure decoded
        _ -> Left (gateFailure "has the wrong gate package field count")

-- | Extend a validated fenced package with the exact recorded effect coordinates.
renderEffectPreparedGatePackageKernel ::
    ByteString -> GateUnknownPhase -> GateCallDigest -> Either Text ByteString
renderEffectPreparedGatePackageKernel fenced (GateUnknownPhase phase) (GateCallDigest digest) = do
    _ <- readFencedPreparedGatePackageKernel fenced
    _ <- gateText "unknown phase" (TextEncoding.encodeUtf8 phase)
    _ <- gateText "call digest" (TextEncoding.encodeUtf8 digest)
    requireGate (ByteString.length (TextEncoding.encodeUtf8 phase) <= fromIntegral maxGateFieldBytes) "has an oversized unknown phase"
    requireGate (ByteString.length (TextEncoding.encodeUtf8 digest) <= fromIntegral maxGateFieldBytes) "has an oversized call digest"
    fields <- takeFrames 11 fenced
    case fields of
        domain : _version : rest ->
            Right (ByteString.concat (map frame' (domain : wordBytes 4 : rest)) <> framed phase <> framed digest)
        _ -> Left (gateFailure "has the wrong gate package field count")

-- | Recover the fenced package and effect from a complete canonical package.
readEffectPreparedGatePackageKernel ::
    ByteString -> Either Text (ByteString, GateUnknownPhase, GateCallDigest)
readEffectPreparedGatePackageKernel raw = do
    fields <- takeFrames 13 raw
    case fields of
        [domain, version, plan, catalog, frame, session, operation, generation, fence, attempt, journalVersion, phase, digest] -> do
            requireGate (version == wordBytes 4) "has the wrong gate package version"
            let fenced = ByteString.concat (map frame' [domain, wordBytes 3, plan, catalog, frame, session, operation, generation, fence, attempt, journalVersion])
            _ <- readFencedPreparedGatePackageKernel fenced
            unknown <- GateUnknownPhase <$> gateText "unknown phase" phase
            call <- GateCallDigest <$> gateText "call digest" digest
            canonical <- renderEffectPreparedGatePackageKernel fenced unknown call
            requireGate (canonical == raw) "is not a canonical gate package"
            pure (fenced, unknown, call)
        _ -> Left (gateFailure "has the wrong gate package field count")

-- | Encode ordered descriptive effects; these bytes grant no authority.
renderEffectProposalsKernel :: [(GateOperationKey, GateUnknownPhase, GateCallDigest)] -> Either Text ByteString
renderEffectProposalsKernel proposals = do
    let keys = [key | (key, _, _) <- proposals]
        fields = concat [[key, phase, digest] | (GateOperationKey key, GateUnknownPhase phase, GateCallDigest digest) <- proposals]
    requireGate (not (null proposals) && length proposals <= maxGatePackages && length keys == length (nub keys)) "has invalid or duplicate effect operations"
    mapM_ validate fields
    pure (ByteString.concat ([framed "hostbootstrap/effect-proposals", framedWord 1, framedWord (fromIntegral (length proposals))] ++ map framed fields))
  where
    validate value = do
        let bytes = TextEncoding.encodeUtf8 value
        _ <- gateText "effect coordinate" bytes
        requireGate (ByteString.length bytes <= fromIntegral maxGateFieldBytes && not (ByteString.elem 9 bytes)) "has an invalid effect coordinate"

-- | Decode and re-render the complete bounded ordered proposal.
readEffectProposalsKernel :: ByteString -> Either Text [(GateOperationKey, GateUnknownPhase, GateCallDigest)]
readEffectProposalsKernel raw = do
    (domain, afterDomain) <- takeFrame raw
    (version, afterVersion) <- takeFrame afterDomain
    (count, remaining) <- takeFrame afterVersion
    requireGate (domain == "hostbootstrap/effect-proposals" && version == wordBytes 1) "has the wrong effect proposal domain or version"
    declared <- gateWord "effect count" count
    requireGate (declared > 0 && declared <= fromIntegral maxGatePackages) "has an invalid effect count"
    fields <- takeFrames (3 * fromIntegral declared) remaining
    proposals <- decode fields
    canonical <- renderEffectProposalsKernel proposals
    requireGate (canonical == raw) "is not a canonical effect proposal"
    pure proposals
  where
    decode [] = Right []
    decode (key : phase : digest : rest) = do
        operation <- GateOperationKey <$> gateText "operation key" key
        unknown <- GateUnknownPhase <$> gateText "unknown phase" phase
        call <- GateCallDigest <$> gateText "call digest" digest
        ((operation, unknown, call) :) <$> decode rest
    decode _ = Left (gateFailure "has the wrong effect proposal field count")

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

-- | Package-internal constructor, reachable only after durable preparation.
mintPreparedNodeGrantKernel ::
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
withPreparedNodeGrantKernel (PreparedNodeGrant node dependencies operationGate projectedGates) use =
    use node dependencies operationGate projectedGates

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
