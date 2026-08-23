{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Canonical, value-bound resource recovery records.

This owner is Cabal-private.  'HostBootstrap.Reconcile' supplies the indexed
plan/resource witnesses, wraps refusals in its public error vocabulary, and is
the only module allowed to mint an ownership receipt from a verified member.
-}
module HostBootstrap.Lifecycle.ResourceRecord
    ( VerifiedResourceRecordBundle
    , VerifiedResourceRecordSet
    , RehydratedResourceSet
    , RehydratedResourceHandle
    , RehydratedOwnershipReceipt
    , RehydratedReleasedTombstone
    , recordSetDigestKernel
    , renderResourceRecordBundleKernel
    , verifyResourceRecordBundleKernel
    , verifyExactResourceRecordBundleKernel
    , verifyResourceRecordSetKernel
    , withVerifiedResourceRecordBundleKernel
    , withVerifiedResourceRecordSetKernel
    , resourceRecordPrefixKernel
    , resourceRecordKeyKernel
    , rehydrateResourceRecordSetKernel
    , foldRehydratedResourceSetKernel
    , rehydratedHandleFrameKernel
    , rehydratedHandleResourceKernel
    , rehydratedTombstoneFrameKernel
    , rehydratedTombstoneResourceKernel
    , rehydratedResourceSetPlanKernel
    , rehydratedResourceSetDigestKernel
    , recoveredOwnedReleaseTransitionKernel
    )
where

import qualified Crypto.Hash as Hash
import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64, Word8)
import Data.List (nub, sort, sortOn)
import HostBootstrap.Protected (mkRecordName, protectedErrorMessage)

data VerifiedResourceRecordBundle scope planId id resource =
    VerifiedResourceRecordBundle
        Text Text Text Word64 Text Word64 Text Text Bool ByteString

type role VerifiedResourceRecordBundle nominal nominal nominal nominal

data ResourceRecordMember = ResourceRecordMember
    Text Text Text Word64 Text Word64 Text Text Bool ByteString

data VerifiedResourceRecordSet scope planId =
    VerifiedResourceRecordSet Text Text Text [ResourceRecordMember]

type role VerifiedResourceRecordSet nominal nominal

data RehydratedResourceHandle scope planId id brokerGeneration =
    RehydratedResourceHandle Text Text Word64 Word64 Word64 Text Text ByteString

type role RehydratedResourceHandle nominal nominal nominal nominal

data RehydratedOwnershipReceipt scope planId id brokerGeneration =
    RehydratedOwnershipReceipt Text Word64 Text

type role RehydratedOwnershipReceipt nominal nominal nominal nominal

data RehydratedReleasedTombstone scope planId id brokerGeneration =
    RehydratedReleasedTombstone Text Text Word64 Word64 Text Text ByteString

type role RehydratedReleasedTombstone nominal nominal nominal nominal

data RehydratedResource = RehydratedResource ResourceRecordMember

data RehydratedResourceSet scope planId brokerGeneration =
    RehydratedResourceSet Text Text Word64 [RehydratedResource]

type role RehydratedResourceSet nominal nominal nominal

recordSetDigestKernel :: VerifiedResourceRecordSet scope planId -> Text
recordSetDigestKernel (VerifiedResourceRecordSet _ _ digest _) = digest

renderResourceRecordBundleKernel ::
    Text -> Text -> Text -> Word64 -> Text -> Word64 -> Text -> Text -> Bool ->
    Either Text ByteString
renderResourceRecordBundleKernel plan frame resource generation operation version phase adapter owned = do
    require "resource record plan digest is empty" (not (Text.null plan))
    require "resource record frame key is empty" (not (Text.null frame))
    require "resource record resource key is empty" (not (Text.null resource))
    require "resource record generation is zero" (generation > 0)
    require "resource record ownership operation key is empty" (not (Text.null operation))
    require "resource record version is zero" (version > 0)
    require "resource record phase is empty" (not (Text.null phase))
    require "resource record adapter revision is empty" (not (Text.null adapter))
    pure . ByteString.concat . map frameWire $
        [ "hostbootstrap/resource-record-bundle"
        , "1"
        , text plan
        , text frame
        , text resource
        , word generation
        , text operation
        , word version
        , text phase
        , text adapter
        , if owned then "owned" else "released"
        ]
  where
    text = TextEncoding.encodeUtf8
    word = text . Text.pack . show

verifyResourceRecordBundleKernel ::
    Text -> Text -> Text -> Word64 -> Text -> Word64 -> Text -> Text -> ByteString ->
    Either Text (VerifiedResourceRecordBundle scope planId id resource)
verifyResourceRecordBundleKernel expectedPlan expectedFrame expectedResource expectedGeneration
    expectedOperation expectedVersion expectedPhase expectedAdapter raw = do
        ResourceRecordMember plan frame resource generation operation version phase adapter owned canonical <-
            parseResourceRecord raw
        require "resource record plan digest differs" (plan == expectedPlan)
        require "resource record frame key differs" (frame == expectedFrame)
        require "resource record resource key differs" (resource == expectedResource)
        require "resource record generation differs" (generation == expectedGeneration)
        require "resource record ownership operation key differs" (operation == expectedOperation)
        require "resource record version differs" (version == expectedVersion)
        require "resource record phase differs" (phase == expectedPhase)
        require "resource record adapter revision differs" (adapter == expectedAdapter)
        pure (VerifiedResourceRecordBundle plan frame resource generation operation version phase adapter owned canonical)

verifyResourceRecordSetKernel ::
    Text ->
    Text ->
    [(Text, Text)] ->
    [(Text, ByteString)] ->
    Either Text (VerifiedResourceRecordSet scope planId)
verifyResourceRecordSetKernel expectedStore expectedPlan expectedMembers keyedBytes = do
    require "resource record set store identity is empty" (not (Text.null expectedStore))
    require "resource record set plan digest is empty" (not (Text.null expectedPlan))
    require "resource record set expected membership contains duplicates"
        (length expectedMembers == length (nub expectedMembers))
    members <- traverse verifyOne keyedBytes
    let actual = sort [(frame, resource) | ResourceRecordMember _ frame resource _ _ _ _ _ _ _ <- members]
        expected = sort expectedMembers
    require "resource record set contains duplicate members" (length actual == length (nub actual))
    require "resource record set membership differs from the snapshot" (actual == expected)
    let canonicalMembers = sortOn memberCoordinate members
        digest = sha256Hex (ByteString.concat (frameWire "hostbootstrap/resource-record-set" : map memberBytes canonicalMembers))
    pure (VerifiedResourceRecordSet expectedStore expectedPlan digest canonicalMembers)
  where
    verifyOne (observedKey, raw) = do
        member@(ResourceRecordMember plan frame resource _ _ _ _ _ _ _) <- parseResourceRecord raw
        require "resource record set member belongs to another plan" (plan == expectedPlan)
        expectedKey <- resourceRecordKeyKernel plan frame resource
        require "resource record key differs from its canonical member" (observedKey == expectedKey)
        pure member

verifyExactResourceRecordBundleKernel ::
    Text -> Text -> Text -> ByteString ->
    Either Text (VerifiedResourceRecordBundle scope planId id resource)
verifyExactResourceRecordBundleKernel expectedPlan expectedFrame expectedResource raw = do
    ResourceRecordMember plan frame resource generation operation version phase adapter owned canonical <- parseResourceRecord raw
    require "resource record plan differs" (plan == expectedPlan)
    require "resource record frame differs" (frame == expectedFrame)
    require "resource record identity differs" (resource == expectedResource)
    pure (VerifiedResourceRecordBundle plan frame resource generation operation version phase adapter owned canonical)

withVerifiedResourceRecordSetKernel ::
    VerifiedResourceRecordSet scope planId ->
    (Text -> [(Text, Text, Word64, Text, Word64, Text, Text, Bool, ByteString)] -> result) ->
    result
withVerifiedResourceRecordSetKernel (VerifiedResourceRecordSet _ _ digest members) consume =
    consume digest (map view members)
  where
    view (ResourceRecordMember _ frame resource generation operation version phase adapter owned raw) =
        (frame, resource, generation, operation, version, phase, adapter, owned, raw)

rehydrateResourceRecordSetKernel ::
    Text ->
    Word64 ->
    VerifiedResourceRecordSet scope planId ->
    Either Text (RehydratedResourceSet scope planId brokerGeneration)
rehydrateResourceRecordSetKernel store broker (VerifiedResourceRecordSet expectedStore plan digest members) = do
    require "resource rehydration store differs" (store == expectedStore)
    require "resource rehydration broker generation is zero" (broker > 0)
    rebound <- traverse reverify members
    pure (RehydratedResourceSet plan digest broker rebound)
  where
    reverify member@(ResourceRecordMember _ _ _ _ _ _ _ _ _ raw) = do
        reparsed <- parseResourceRecord raw
        require "resource changed while the complete set was rebound" (memberView reparsed == memberView member)
        pure (RehydratedResource reparsed)

foldRehydratedResourceSetKernel ::
    RehydratedResourceSet scope planId brokerGeneration ->
    result ->
    (forall id. result -> RehydratedResourceHandle scope planId id brokerGeneration -> RehydratedOwnershipReceipt scope planId id brokerGeneration -> result) ->
    (forall id. result -> RehydratedReleasedTombstone scope planId id brokerGeneration -> result) ->
    (Text, result)
foldRehydratedResourceSetKernel (RehydratedResourceSet _plan digest broker members) initial onOwned onReleased =
    (digest, foldl step initial members)
  where
    step value (RehydratedResource (ResourceRecordMember _ frame resource generation operation version phase adapter owned raw))
        | owned =
            onOwned
                value
                (RehydratedResourceHandle frame resource generation broker version phase adapter raw)
                (RehydratedOwnershipReceipt resource generation operation)
        | otherwise =
            onReleased value (RehydratedReleasedTombstone frame resource generation version phase adapter raw)

rehydratedHandleFrameKernel :: RehydratedResourceHandle scope planId id brokerGeneration -> Text
rehydratedHandleFrameKernel (RehydratedResourceHandle frame _ _ _ _ _ _ _) = frame

rehydratedHandleResourceKernel :: RehydratedResourceHandle scope planId id brokerGeneration -> Text
rehydratedHandleResourceKernel (RehydratedResourceHandle _ resource _ _ _ _ _ _) = resource

rehydratedTombstoneFrameKernel :: RehydratedReleasedTombstone scope planId id brokerGeneration -> Text
rehydratedTombstoneFrameKernel (RehydratedReleasedTombstone frame _ _ _ _ _ _) = frame

rehydratedTombstoneResourceKernel :: RehydratedReleasedTombstone scope planId id brokerGeneration -> Text
rehydratedTombstoneResourceKernel (RehydratedReleasedTombstone _ resource _ _ _ _ _) = resource

rehydratedResourceSetPlanKernel :: RehydratedResourceSet scope planId brokerGeneration -> Text
rehydratedResourceSetPlanKernel (RehydratedResourceSet plan _ _ _) = plan

rehydratedResourceSetDigestKernel :: RehydratedResourceSet scope planId brokerGeneration -> Text
rehydratedResourceSetDigestKernel (RehydratedResourceSet _ digest _ _) = digest

recoveredOwnedReleaseTransitionKernel ::
    Text ->
    RehydratedResourceHandle scope planId id brokerGeneration ->
    RehydratedOwnershipReceipt scope planId id brokerGeneration ->
    Either Text (Text, ByteString, ByteString)
recoveredOwnedReleaseTransitionKernel plan
    (RehydratedResourceHandle frame resource generation _broker version phase adapter ownedBytes)
    (RehydratedOwnershipReceipt receiptResource receiptGeneration operation) = do
        require "the recovered receipt belongs to another resource" (receiptResource == resource)
        require "the recovered receipt belongs to another generation" (receiptGeneration == generation)
        key <- resourceRecordKeyKernel plan frame resource
        releasedBytes <- renderResourceRecordBundleKernel plan frame resource generation operation version phase adapter False
        pure (key, ownedBytes, releasedBytes)

memberView :: ResourceRecordMember -> (Text, Text, Text, Word64, Text, Word64, Text, Text, Bool, ByteString)
memberView (ResourceRecordMember plan frame resource generation operation version phase adapter owned raw) =
    (plan, frame, resource, generation, operation, version, phase, adapter, owned, raw)

resourceRecordPrefixKernel :: Text -> Either Text Text
resourceRecordPrefixKernel plan = do
    planName <- either (Left . protectedErrorMessage) Right (mkRecordName plan)
    pure ("resource." <> planName <> ".")

resourceRecordKeyKernel :: Text -> Text -> Text -> Either Text Text
resourceRecordKeyKernel plan frame resource = do
    prefix <- resourceRecordPrefixKernel plan
    frameName <- either (Left . protectedErrorMessage) Right (mkRecordName frame)
    resourceName <- either (Left . protectedErrorMessage) Right (mkRecordName resource)
    let memberDigest = sha256Hex (TextEncoding.encodeUtf8 (frameName <> "\NUL" <> resourceName))
    pure (prefix <> memberDigest)

parseResourceRecord :: ByteString -> Either Text ResourceRecordMember
parseResourceRecord raw = do
    fields <- exactFrames 11 raw
    case fields of
        [domain, format, planRaw, frameRaw, resourceRaw, generationRaw, operationRaw, versionRaw, phaseRaw, adapterRaw, dispositionRaw] -> do
            require "resource record domain differs" (domain == "hostbootstrap/resource-record-bundle")
            require "resource record format version differs" (format == "1")
            plan <- decode "plan digest" planRaw
            frame <- decode "frame key" frameRaw
            resource <- decode "resource key" resourceRaw
            generation <- positive "generation" generationRaw
            operation <- decode "ownership operation key" operationRaw
            version <- positive "record version" versionRaw
            phase <- decode "phase" phaseRaw
            adapter <- decode "adapter revision" adapterRaw
            owned <- case dispositionRaw of
                "owned" -> Right True
                "released" -> Right False
                _ -> Left "resource record disposition is unknown"
            canonical <- renderResourceRecordBundleKernel plan frame resource generation operation version phase adapter owned
            require "resource record bytes are not canonical" (canonical == raw)
            pure (ResourceRecordMember plan frame resource generation operation version phase adapter owned canonical)
        _ -> Left "resource record field count differs"

memberCoordinate :: ResourceRecordMember -> (Text, Text)
memberCoordinate (ResourceRecordMember _ frame resource _ _ _ _ _ _ _) = (frame, resource)

memberBytes :: ResourceRecordMember -> ByteString
memberBytes (ResourceRecordMember _ _ _ _ _ _ _ _ _ raw) = frameWire raw

sha256Hex :: ByteString -> Text
sha256Hex bytes = Text.pack (show (Hash.hash bytes :: Hash.Digest Hash.SHA256))

withVerifiedResourceRecordBundleKernel ::
    VerifiedResourceRecordBundle scope planId id resource ->
    (Text -> Word64 -> Text -> result) ->
    (Text -> Word64 -> Text -> Word64 -> Text -> Text -> ByteString -> result) ->
    result
withVerifiedResourceRecordBundleKernel
    (VerifiedResourceRecordBundle _ _ resource generation operation version phase adapter owned raw)
    onOwned onReleased
        | owned = onOwned resource generation operation
        | otherwise = onReleased resource generation operation version phase adapter raw

exactFrames :: Int -> ByteString -> Either Text [ByteString]
exactFrames expected = go expected []
  where
    go 0 fields trailing
        | ByteString.null trailing = Right (reverse fields)
        | otherwise = Left "resource record has trailing bytes"
    go remaining fields bytes = do
        (field, trailing) <- takeFrame bytes
        go (remaining - 1) (field : fields) trailing

takeFrame :: ByteString -> Either Text (ByteString, ByteString)
takeFrame raw
    | ByteString.length raw < 8 = Left "resource record frame is truncated"
    | size > fromIntegral (ByteString.length body) = Left "resource record frame payload is truncated"
    | otherwise = Right (ByteString.splitAt (fromIntegral size) body)
  where
    (prefix, body) = ByteString.splitAt 8 raw
    size = ByteString.foldl' (\value byte -> shiftL value 8 .|. fromIntegral byte) 0 prefix :: Word64

frameWire :: ByteString -> ByteString
frameWire bytes = ByteString.pack (word64BigEndian (fromIntegral (ByteString.length bytes))) <> bytes

word64BigEndian :: Word64 -> [Word8]
word64BigEndian value = [fromIntegral (shiftR value shift) | shift <- [56, 48 .. 0]]

decode :: Text -> ByteString -> Either Text Text
decode label raw = case TextEncoding.decodeUtf8' raw of
    Left _ -> Left ("resource record " <> label <> " is not UTF-8")
    Right value
        | Text.null value -> Left ("resource record " <> label <> " is empty")
        | otherwise -> Right value

positive :: Text -> ByteString -> Either Text Word64
positive label raw = do
    value <- decode label raw
    case reads (Text.unpack value) of
        [(number, "")] | number > 0 && Text.pack (show number) == value -> Right number
        _ -> Left ("resource record " <> label <> " is not a canonical positive word")

require :: Text -> Bool -> Either Text ()
require _ True = Right ()
require failure False = Left failure
