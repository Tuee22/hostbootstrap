{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The durable reverse-root intent: its private indexed schema and its
canonical codec.

This module holds no store effect. "HostBootstrap.Lifecycle.Mode" owns every
read and compare-and-swap of the protected row; the pure schema and codec live
here so a test can exercise their value-level promises without a store.
-}
module HostBootstrap.Lifecycle.ReverseRootIntent (
    ReverseRootIntent (..),
    encodeReverseRootIntent,
    decodeReverseRootIntent,
    reverseRootPhaseVersion,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority.Kernel (
    ProjectVerb (ProjectDestroy, ProjectDown, ProjectUp),
    VerbDestroy,
    VerbDown,
    projectVerbName,
 )
import HostBootstrap.Protected (RecordKey, mkRecordKey, recordKeyText)

-- Decoder ceilings are part of the wire contract; an attacker-controlled
-- 64-bit frame length is rejected before it reaches 'ByteString.splitAt'.
maxSnapshotRecordBytes :: Int
maxSnapshotRecordBytes = 32 * 1024 * 1024

maxSnapshotTextBytes :: Int
maxSnapshotTextBytes = 1024 * 1024

maxCanonicalPlanBytes :: Int
maxCanonicalPlanBytes = 16 * 1024 * 1024

encodeSnapshotBytes :: ByteString -> Builder.Builder
encodeSnapshotBytes bytes =
    Builder.word64BE (fromIntegral (ByteString.length bytes))
        <> Builder.byteString bytes

takeSnapshotBytesBounded :: Int -> ByteString -> Maybe (ByteString, ByteString)
takeSnapshotBytesBounded limit input = do
    (rawLength, remaining) <- takeSnapshotWord input
    if rawLength > fromIntegral limit
        then Nothing
        else do
            let requested = fromIntegral rawLength
                (value, trailing) = ByteString.splitAt requested remaining
            if ByteString.length value == requested
                then Just (value, trailing)
                else Nothing

takeSnapshotWord :: ByteString -> Maybe (Word64, ByteString)
takeSnapshotWord input =
    let (rawWord, remaining) = ByteString.splitAt 8 input
     in if ByteString.length rawWord /= 8
            then Nothing
            else
                Just
                    ( ByteString.foldl' (\value byte -> value * 256 + fromIntegral byte) 0 rawWord
                    , remaining
                    )

readWord :: Text -> Maybe Word64
readWord raw
    | Text.null raw || Text.length raw > 20 = Nothing
    | not (Text.all asciiDigit raw) = Nothing
    | raw /= "0" && "0" `Text.isPrefixOf` raw = Nothing
    | otherwise = case (reads (Text.unpack raw) :: [(Integer, String)]) of
        [(value, "")]
            | value >= 0
            , value <= toInteger (maxBound :: Word64)
            , let word = fromInteger value
            , Text.pack (show word) == raw -> Just word
        _ -> Nothing
  where
    asciiDigit character = character >= '0' && character <= '9'

{- | Private write-ahead state for one successful Production @up@ lineage.

Pending contains no target generation.  Committed adds the sole allocated
target and the complete predicted mode/lease successor records, so recovery
never has to infer whether either independent suffix write committed.
-}
data ReverseRootIntent projectId sourceBrokerGeneration verb where
    ReverseRootDownPending ::
        ( Text
        , Text
        , Text
        , Word64
        , Text
        , Text
        , Text
        , ByteString
        , Word64
        , RecordKey
        , Word64
        , ByteString
        , RecordKey
        , Word64
        , ByteString
        , Text
        , Word64
        , Word64
        , ByteString
        , Word64
        , ByteString
        ) ->
        ReverseRootIntent projectId sourceBrokerGeneration VerbDown
    ReverseRootDestroyPending ::
        ( Text
        , Text
        , Text
        , Word64
        , Text
        , Text
        , Text
        , ByteString
        , Word64
        , RecordKey
        , Word64
        , ByteString
        , RecordKey
        , Word64
        , ByteString
        , Text
        , Word64
        , Word64
        , ByteString
        , Word64
        , ByteString
        ) ->
        ReverseRootIntent projectId sourceBrokerGeneration VerbDestroy
    ReverseRootDownCommitted ::
        ( Text
        , Text
        , Text
        , Word64
        , Text
        , Text
        , Text
        , ByteString
        , Word64
        , RecordKey
        , Word64
        , ByteString
        , RecordKey
        , Word64
        , ByteString
        , Text
        , Word64
        , Word64
        , ByteString
        , Word64
        , ByteString
        ) ->
        Word64 ->
        Word64 ->
        ByteString ->
        Word64 ->
        ByteString ->
        ReverseRootIntent projectId sourceBrokerGeneration VerbDown
    ReverseRootDestroyCommitted ::
        ( Text
        , Text
        , Text
        , Word64
        , Text
        , Text
        , Text
        , ByteString
        , Word64
        , RecordKey
        , Word64
        , ByteString
        , RecordKey
        , Word64
        , ByteString
        , Text
        , Word64
        , Word64
        , ByteString
        , Word64
        , ByteString
        ) ->
        Word64 ->
        Word64 ->
        ByteString ->
        Word64 ->
        ByteString ->
        ReverseRootIntent projectId sourceBrokerGeneration VerbDestroy
    ReverseRootDownTerminal ::
        ( Text
        , Text
        , Text
        , Word64
        , Text
        , Text
        , Text
        , ByteString
        , Word64
        , RecordKey
        , Word64
        , ByteString
        , RecordKey
        , Word64
        , ByteString
        , Text
        , Word64
        , Word64
        , ByteString
        , Word64
        , ByteString
        ) ->
        Word64 ->
        Word64 ->
        ByteString ->
        Word64 ->
        ByteString ->
        ReverseRootIntent projectId sourceBrokerGeneration VerbDown
    ReverseRootDestroyTerminal ::
        ( Text
        , Text
        , Text
        , Word64
        , Text
        , Text
        , Text
        , ByteString
        , Word64
        , RecordKey
        , Word64
        , ByteString
        , RecordKey
        , Word64
        , ByteString
        , Text
        , Word64
        , Word64
        , ByteString
        , Word64
        , ByteString
        ) ->
        Word64 ->
        Word64 ->
        ByteString ->
        Word64 ->
        ByteString ->
        ReverseRootIntent projectId sourceBrokerGeneration VerbDestroy

type role ReverseRootIntent nominal nominal nominal

reverseRootIntentMagic :: ByteString
reverseRootIntentMagic = "HOSTBOOTSTRAP-REVERSE-ROOT"

reverseRootIntentVersion :: Word64
reverseRootIntentVersion = 1

{- | A settled Down may advance once to Destroy in the same durable row.
The second Pending/Committed/Terminal sequence retains versions 4/5/6.
-}
reverseRootPhaseVersion :: ProjectVerb verb -> Word64 -> Word64 -> Bool
reverseRootPhaseVersion verb initialVersion version = case verb of
    ProjectUp -> False
    ProjectDown -> version == initialVersion
    ProjectDestroy -> version == initialVersion || version == initialVersion + 3

encodeReverseRootIntent :: ReverseRootIntent projectId sourceBrokerGeneration verb -> ByteString
encodeReverseRootIntent intent =
    LazyByteString.toStrict
        ( Builder.toLazyByteString
            ( Builder.byteString reverseRootIntentMagic
                <> Builder.word64BE reverseRootIntentVersion
                <> Builder.word64BE (fromIntegral (length fields))
                <> foldMap encodeSnapshotBytes fields
            )
        )
  where
    fields :: [ByteString]
    fields = case intent of
        ReverseRootDownPending values -> common "pending" "down" values
        ReverseRootDestroyPending values -> common "pending" "destroy" values
        ReverseRootDownCommitted values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes ->
            committed "down" values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes
        ReverseRootDestroyCommitted values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes ->
            committed "destroy" values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes
        ReverseRootDownTerminal values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes ->
            terminal "down" values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes
        ReverseRootDestroyTerminal values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes ->
            terminal "destroy" values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes
    committed verb values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes =
        common "committed" verb values
            <> [word target, word nextModeVersion, nextModeBytes, word nextLeaseVersion, nextLeaseBytes]
    terminal verb values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes =
        common "terminal" verb values
            <> [word target, word nextModeVersion, nextModeBytes, word nextLeaseVersion, nextLeaseBytes]
    common
        state
        verb
        ( project
            , store
            , run
            , revision
            , spec
            , config
            , plan
            , canonical
            , source
            , acquisitionKey
            , acquisitionVersion
            , acquisitionBytes
            , cursorKey
            , cursorVersion
            , cursorBytes
            , rootFrame
            , sessions
            , modeVersion
            , modeBytes
            , leaseVersion
            , leaseBytes
            ) =
            [ text state
            , text verb
            , text project
            , text store
            , text run
            , word revision
            , text spec
            , text config
            , text plan
            , canonical
            , word source
            , text (recordKeyText acquisitionKey)
            , word acquisitionVersion
            , acquisitionBytes
            , text (recordKeyText cursorKey)
            , word cursorVersion
            , cursorBytes
            , text rootFrame
            , word sessions
            , word modeVersion
            , modeBytes
            , word leaseVersion
            , leaseBytes
            ]
    text = TextEncoding.encodeUtf8
    word :: Word64 -> ByteString
    word = ByteStringChar8.pack . show

decodeReverseRootIntent ::
    forall projectId sourceBrokerGeneration verb.
    ProjectVerb verb ->
    ByteString ->
    Maybe (ReverseRootIntent projectId sourceBrokerGeneration verb)
decodeReverseRootIntent expected raw = do
    () <- case expected of
        ProjectUp -> Nothing
        ProjectDown -> pure ()
        ProjectDestroy -> pure ()
    fields <- decodeIntentFields raw
    case fields of
        state : verb : commonFields -> do
            stateText <- asText state
            verbText <- asText verb
            if verbText /= projectVerbName expected then Nothing else pure ()
            case (stateText, commonFields) of
                ("pending", commonValues) -> do
                    ( project
                        , store
                        , run
                        , revision
                        , spec
                        , config
                        , plan
                        , canonical
                        , source
                        , acquisitionKey
                        , acquisitionVersion
                        , acquisitionBytes
                        , cursorKey
                        , cursorVersion
                        , cursorBytes
                        , rootFrame
                        , sessions
                        , modeVersion
                        , modeBytes
                        , leaseVersion
                        , leaseBytes
                        ) <-
                        parseCommon commonValues
                    let values =
                            ( project
                            , store
                            , run
                            , revision
                            , spec
                            , config
                            , plan
                            , canonical
                            , source
                            , acquisitionKey
                            , acquisitionVersion
                            , acquisitionBytes
                            , cursorKey
                            , cursorVersion
                            , cursorBytes
                            , rootFrame
                            , sessions
                            , modeVersion
                            , modeBytes
                            , leaseVersion
                            , leaseBytes
                            )
                    case expected of
                        ProjectDown -> canonicalIntent (ReverseRootDownPending values)
                        ProjectDestroy -> canonicalIntent (ReverseRootDestroyPending values)
                        ProjectUp -> Nothing
                ("committed", commonValues) -> case splitAt 21 commonValues of
                    (base, [targetRaw, nextModeVersionRaw, nextModeBytes, nextLeaseVersionRaw, nextLeaseBytes]) -> do
                        ( project
                            , store
                            , run
                            , revision
                            , spec
                            , config
                            , plan
                            , canonical
                            , source
                            , acquisitionKey
                            , acquisitionVersion
                            , acquisitionBytes
                            , cursorKey
                            , cursorVersion
                            , cursorBytes
                            , rootFrame
                            , sessions
                            , modeVersion
                            , modeBytes
                            , leaseVersion
                            , leaseBytes
                            ) <-
                            parseCommon base
                        target <- positive targetRaw
                        nextModeVersion <- positive nextModeVersionRaw
                        nextLeaseVersion <- positive nextLeaseVersionRaw
                        let values =
                                ( project
                                , store
                                , run
                                , revision
                                , spec
                                , config
                                , plan
                                , canonical
                                , source
                                , acquisitionKey
                                , acquisitionVersion
                                , acquisitionBytes
                                , cursorKey
                                , cursorVersion
                                , cursorBytes
                                , rootFrame
                                , sessions
                                , modeVersion
                                , modeBytes
                                , leaseVersion
                                , leaseBytes
                                )
                        case expected of
                            ProjectDown -> canonicalIntent (ReverseRootDownCommitted values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes)
                            ProjectDestroy -> canonicalIntent (ReverseRootDestroyCommitted values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes)
                            ProjectUp -> Nothing
                    _ -> Nothing
                ("terminal", commonValues) -> case splitAt 21 commonValues of
                    (base, [targetRaw, nextModeVersionRaw, nextModeBytes, nextLeaseVersionRaw, nextLeaseBytes]) -> do
                        ( project
                            , store
                            , run
                            , revision
                            , spec
                            , config
                            , plan
                            , canonical
                            , source
                            , acquisitionKey
                            , acquisitionVersion
                            , acquisitionBytes
                            , cursorKey
                            , cursorVersion
                            , cursorBytes
                            , rootFrame
                            , sessions
                            , modeVersion
                            , modeBytes
                            , leaseVersion
                            , leaseBytes
                            ) <-
                            parseCommon base
                        target <- positive targetRaw
                        nextModeVersion <- positive nextModeVersionRaw
                        nextLeaseVersion <- positive nextLeaseVersionRaw
                        let values =
                                ( project
                                , store
                                , run
                                , revision
                                , spec
                                , config
                                , plan
                                , canonical
                                , source
                                , acquisitionKey
                                , acquisitionVersion
                                , acquisitionBytes
                                , cursorKey
                                , cursorVersion
                                , cursorBytes
                                , rootFrame
                                , sessions
                                , modeVersion
                                , modeBytes
                                , leaseVersion
                                , leaseBytes
                                )
                        case expected of
                            ProjectDown -> canonicalIntent (ReverseRootDownTerminal values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes)
                            ProjectDestroy -> canonicalIntent (ReverseRootDestroyTerminal values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes)
                            ProjectUp -> Nothing
                    _ -> Nothing
                _ -> Nothing
        _ -> Nothing
  where
    canonicalIntent ::
        ReverseRootIntent projectId sourceBrokerGeneration verb ->
        Maybe (ReverseRootIntent projectId sourceBrokerGeneration verb)
    canonicalIntent intent
        | encodeReverseRootIntent intent == raw = Just intent
        | otherwise = Nothing
    parseCommon values = case values of
        [ projectRaw
            , storeRaw
            , runRaw
            , revisionRaw
            , specRaw
            , configRaw
            , planRaw
            , canonical
            , sourceRaw
            , acquisitionKeyRaw
            , acquisitionVersionRaw
            , acquisitionBytes
            , cursorKeyRaw
            , cursorVersionRaw
            , cursorBytes
            , rootFrameRaw
            , sessionsRaw
            , modeVersionRaw
            , modeBytes
            , leaseVersionRaw
            , leaseBytes
            ] -> do
                project <- nonempty projectRaw
                store <- nonempty storeRaw
                run <- nonempty runRaw
                revision <- positive revisionRaw
                spec <- nonempty specRaw
                config <- nonempty configRaw
                plan <- nonempty planRaw
                if ByteString.null canonical || ByteString.length canonical > maxCanonicalPlanBytes
                    then Nothing
                    else pure ()
                source <- positive sourceRaw
                acquisitionKey <- asText acquisitionKeyRaw >>= either (const Nothing) Just . mkRecordKey
                acquisitionVersion <- positive acquisitionVersionRaw
                if ByteString.null acquisitionBytes then Nothing else pure ()
                cursorKey <- asText cursorKeyRaw >>= either (const Nothing) Just . mkRecordKey
                cursorVersion <- positive cursorVersionRaw
                if ByteString.null cursorBytes then Nothing else pure ()
                rootFrame <- nonempty rootFrameRaw
                sessions <- number sessionsRaw
                modeVersion <- positive modeVersionRaw
                if ByteString.null modeBytes then Nothing else pure ()
                leaseVersion <- positive leaseVersionRaw
                if ByteString.null leaseBytes then Nothing else pure ()
                pure
                    ( project
                    , store
                    , run
                    , revision
                    , spec
                    , config
                    , plan
                    , canonical
                    , source
                    , acquisitionKey
                    , acquisitionVersion
                    , acquisitionBytes
                    , cursorKey
                    , cursorVersion
                    , cursorBytes
                    , rootFrame
                    , sessions
                    , modeVersion
                    , modeBytes
                    , leaseVersion
                    , leaseBytes
                    )
        _ -> Nothing
    asText bytes
        | ByteString.length bytes > maxSnapshotTextBytes = Nothing
        | otherwise = either (const Nothing) Just (TextEncoding.decodeUtf8' bytes)
    nonempty bytes = asText bytes >>= \value -> if Text.null value then Nothing else Just value
    number bytes = asText bytes >>= readWord
    positive bytes = number bytes >>= \value -> if value == 0 then Nothing else Just value

decodeIntentFields :: ByteString -> Maybe [ByteString]
decodeIntentFields raw
    | ByteString.length raw > maxSnapshotRecordBytes = Nothing
    | otherwise = do
        afterMagic <- ByteString.stripPrefix reverseRootIntentMagic raw
        (version, afterVersion) <- takeSnapshotWord afterMagic
        if version /= reverseRootIntentVersion then Nothing else pure ()
        (count, payload) <- takeSnapshotWord afterVersion
        if count > 32 then Nothing else collect count payload []
  where
    collect 0 trailing fields
        | ByteString.null trailing = Just (reverse fields)
        | otherwise = Nothing
    collect remaining payload fields = do
        (field, trailing) <- takeSnapshotBytesBounded maxSnapshotRecordBytes payload
        collect (remaining - 1) trailing (field : fields)
