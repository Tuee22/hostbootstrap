{-# LANGUAGE OverloadedStrings #-}

{- | The recoverable redo coordinator for Session-owned lifecycle transitions.

The protected store publishes one file atomically, not a set of files. This
module turns a closed lifecycle transition into one logical transaction:

1. publish an @Applying@ descriptor containing exact target expectations and
   desired values;
2. redo each target deterministically, stamping it with the transaction id;
3. publish @Idle@ at the successor coordinator version.

Every authority-producing Session API recovers @Applying@ before it reads
state. A process death can therefore expose a partial physical materialization,
but never a partial logical transition to a cooperating lifecycle caller.

The target builders and runner are package-internal. 'TxnKind' is closed and
records the reserved Mode terminal-close extension points; recovery never
executes an untyped caller-supplied write list.

Nothing here knows that a test exists. What a process death leaves behind is a
/value/ — an @Applying@ coordinator record naming a descriptor, plus however
many of that descriptor's targets were already stamped — so a fixture reaches
any interruption point by writing that value through the store's own
compare-and-swap and then re-entering the ordinary entry point. The coordinator
needs no crash point for that, and would be weaker evidence if it had one: a
branch that exists for a test is a path production never takes, so a gate that
drives it agrees with a shape nothing else produces.
-}
module HostBootstrap.Lifecycle.Transaction (
    TransactionPermit,
    transactionPermitVersion,
    TransactionRecord (..),
    readTransactionRecord,
    TxnKind (..),
    TransactionTarget,
    projectTransactionTarget,
    sessionTransactionTarget,
    operationTransactionTarget,
    ensureTransactionCoordinator,
    runLifecycleTransaction,
    CoordinatorState (..),
    TransactionDescriptor (..),
    coordinatorKey,
    encodeCoordinator,
    stampTarget,
    TransactionError (..),
    transactionErrorMessage,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Char (isHexDigit)
import qualified Crypto.Hash as Hash
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64, Word8)
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    RecordKey,
    RecordVersion,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    mkRecordName,
    readProtectedRecord,
    recordKeyText,
    recordVersionWord,
 )
import Numeric (readHex, showHex)

-- Coordinator permits -------------------------------------------------------------

-- | The exact committed Idle coordinator version authorizing the next transition.
newtype TransactionPermit = TransactionPermit RecordVersion
    deriving (Eq)

instance Show TransactionPermit where
    show (TransactionPermit version) =
        "TransactionPermit " <> show (recordVersionWord version)

transactionPermitVersion :: TransactionPermit -> Word64
transactionPermitVersion (TransactionPermit version) = recordVersionWord version

-- Stamped target records -----------------------------------------------------------

data TransactionRecord = TransactionRecord
    { transactionRecordVersion :: RecordVersion
    , transactionRecordStamp :: Maybe Word64
    , transactionRecordPayload :: ByteString
    }
    deriving (Eq, Show)

targetMagic :: ByteString
targetMagic = "hbtx-target-v1"

stampTarget :: Word64 -> ByteString -> ByteString
stampTarget sequenceNumber payload =
    ByteString.concat
        [ targetMagic
        , "\t"
        , ByteStringChar8.pack (show sequenceNumber)
        , "\n"
        , payload
        ]

decodeStampedTarget :: ByteString -> Either TransactionError (Maybe Word64, ByteString)
decodeStampedTarget raw =
    case ByteStringChar8.break (== '\n') raw of
        (header, rest)
            | header == targetMagic ->
                Left (TransactionMalformed "a stamped target has no transaction id")
            | (targetMagic <> "\t") `ByteString.isPrefixOf` header ->
                case ByteStringChar8.readInteger (ByteString.drop (ByteString.length targetMagic + 1) header) of
                    Just (value, remainder)
                        | ByteString.null remainder && value > 0 ->
                            Right (Just (fromInteger value), ByteString.drop 1 rest)
                    _ -> Left (TransactionMalformed "a stamped target has an invalid transaction id")
            | otherwise -> Right (Nothing, raw)

readTransactionRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either TransactionError (Maybe TransactionRecord))
readTransactionRecord session key = do
    observed <- readProtectedRecord session key
    pure $ case observed of
        Left failure -> Left (TransactionStoreFailure failure)
        Right Nothing -> Right Nothing
        Right (Just record) -> do
            (stamp, payload) <- decodeStampedTarget (protectedRecordBytes record)
            Right
                ( Just
                    TransactionRecord
                        { transactionRecordVersion = protectedRecordVersion record
                        , transactionRecordStamp = stamp
                        , transactionRecordPayload = payload
                        }
                )

-- Closed transaction vocabulary ---------------------------------------------------

data TxnKind
    = TxnOpenProject
    | TxnOpenSession
    | TxnRegisterIntent
    | TxnPrepareOperation
    | TxnAcknowledgeOutcome
    | -- | Abandoned-run recovery rebinding one existing stable session record
      -- to the fresh broker generation. It is deliberately its own kind rather
      -- than a second use of 'TxnCloseSession': a rebind leaves the session
      -- __Open__, so a journal reader can tell a recovered-and-still-open
      -- session from a closed one, and only the recovery interpreter emits it.
      TxnRebindSession
    | TxnCloseSession
    | TxnBeginProjectClose
    | TxnRecordProjectClosed
    | -- Reserved for the Mode integration tranche.
      TxnCloseProductionInvocation
    | -- Reserved for the Mode integration tranche.
      TxnFinalizeHarnessClose
    | -- Reserved for the Mode integration tranche.
      TxnFinalizeProductionProject
    deriving (Eq, Show)

data TargetRole
    = ProjectTarget
    | SessionTarget
    | OperationTarget
    deriving (Eq, Show)

data TargetExpectation
    = TargetAbsent
    | TargetVersion Word64
    deriving (Eq, Show)

data TransactionTarget = TransactionTarget
    { targetRole :: TargetRole
    , targetKey :: RecordKey
    , targetExpectation :: TargetExpectation
    , targetDesiredPayload :: ByteString
    }
    deriving (Eq, Show)

projectTransactionTarget :: RecordKey -> Maybe TransactionRecord -> ByteString -> TransactionTarget
projectTransactionTarget = transactionTarget ProjectTarget

sessionTransactionTarget :: RecordKey -> Maybe TransactionRecord -> ByteString -> TransactionTarget
sessionTransactionTarget = transactionTarget SessionTarget

operationTransactionTarget :: RecordKey -> Maybe TransactionRecord -> ByteString -> TransactionTarget
operationTransactionTarget = transactionTarget OperationTarget

transactionTarget ::
    TargetRole ->
    RecordKey ->
    Maybe TransactionRecord ->
    ByteString ->
    TransactionTarget
transactionTarget role key observed payload =
    TransactionTarget
        { targetRole = role
        , targetKey = key
        , targetExpectation = maybe TargetAbsent (TargetVersion . recordVersionWord . transactionRecordVersion) observed
        , targetDesiredPayload = payload
        }

-- Coordinator record --------------------------------------------------------------

data CoordinatorState
    = CoordinatorIdle Word64
    | CoordinatorApplying TransactionDescriptor
    deriving (Eq, Show)

data TransactionDescriptor = TransactionDescriptor
    { descriptorSequence :: Word64
    , descriptorPlan :: Text
    , descriptorKind :: TxnKind
    , descriptorTargets :: [TransactionTarget]
    }
    deriving (Eq, Show)

-- | The coordinator's record for one plan. The plan digest is namespaced
-- (@\<specDigest\>:\<planBytesDigest\>@), so it reaches the store's key alphabet
-- through the one injective encoding rather than a local sanitizer.
coordinatorKey :: Text -> Either TransactionError RecordKey
coordinatorKey plan =
    either (Left . TransactionStoreFailure) Right $ do
        digest <- mkRecordName plan
        mkRecordKey ("transaction." <> digest)

ensureTransactionCoordinator ::
    ProtectedSession session ->
    Text ->
    IO (Either TransactionError TransactionPermit)
ensureTransactionCoordinator session plan =
    case coordinatorKey plan of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (Left (TransactionStoreFailure failure))
                Right Nothing -> do
                    created <-
                        compareAndSwapProtectedRecord
                            session
                            key
                            ExpectAbsent
                            (encodeCoordinator (CoordinatorIdle 0))
                    pure (either (Left . TransactionStoreFailure) (Right . TransactionPermit) created)
                Right (Just record) ->
                    case decodeCoordinator (protectedRecordBytes record) of
                        Left failure -> pure (Left failure)
                        Right (CoordinatorIdle _) ->
                            pure (Right (TransactionPermit (protectedRecordVersion record)))
                        Right (CoordinatorApplying descriptor) ->
                            recoverApplying session key record descriptor

runLifecycleTransaction ::
    ProtectedSession session ->
    Text ->
    TransactionPermit ->
    TxnKind ->
    [TransactionTarget] ->
    IO (Either TransactionError TransactionPermit)
runLifecycleTransaction session plan presented kind targets = do
    current <- ensureTransactionCoordinator session plan
    case current of
        Left failure -> pure (Left failure)
        Right live
            | transactionPermitVersion live /= transactionPermitVersion presented ->
                pure (Left (TransactionStalePermit (transactionPermitVersion presented)))
            | otherwise -> begin live
  where
    begin (TransactionPermit liveVersion) =
        case (coordinatorKey plan, validateTargets plan kind targets) of
            (Left failure, _) -> pure (Left failure)
            (_, Left failure) -> pure (Left failure)
            (Right key, Right ()) -> do
                observed <- readProtectedRecord session key
                case observed of
                    Left failure -> pure (Left (TransactionStoreFailure failure))
                    Right Nothing -> pure (Left (TransactionMalformed "the transaction coordinator disappeared"))
                    Right (Just record)
                        | protectedRecordVersion record /= liveVersion ->
                            pure (Left (TransactionStalePermit (recordVersionWord liveVersion)))
                        | otherwise ->
                            case decodeCoordinator (protectedRecordBytes record) of
                                Left failure -> pure (Left failure)
                                Right (CoordinatorApplying _) ->
                                    pure (Left (TransactionMalformed "the coordinator remained Applying after recovery"))
                                Right (CoordinatorIdle priorSequence)
                                    | priorSequence == maxBound ->
                                        pure (Left (TransactionMalformed "the transaction sequence overflowed"))
                                    | otherwise -> do
                                        let descriptor =
                                                TransactionDescriptor
                                                    { descriptorSequence = priorSequence + 1
                                                    , descriptorPlan = plan
                                                    , descriptorKind = kind
                                                    , descriptorTargets = targets
                                                    }
                                        applying <-
                                            compareAndSwapProtectedRecord
                                                session
                                                key
                                                (ExpectVersion liveVersion)
                                                (encodeCoordinator (CoordinatorApplying descriptor))
                                        case applying of
                                            Left failure -> pure (Left (TransactionStoreFailure failure))
                                            Right applyingVersion -> do
                                                materialized <- applyTargets session descriptor
                                                case materialized of
                                                    Left failure -> pure (Left failure)
                                                    Right () -> do
                                                        committed <-
                                                            compareAndSwapProtectedRecord
                                                                session
                                                                key
                                                                (ExpectVersion applyingVersion)
                                                                ( encodeCoordinator
                                                                    (CoordinatorIdle (descriptorSequence descriptor))
                                                                )
                                                        pure
                                                            ( either
                                                                (Left . TransactionStoreFailure)
                                                                (Right . TransactionPermit)
                                                                committed
                                                            )

recoverApplying ::
    ProtectedSession session ->
    RecordKey ->
    ProtectedRecord ->
    TransactionDescriptor ->
    IO (Either TransactionError TransactionPermit)
recoverApplying session key coordinator descriptor =
    case validateTargets (descriptorPlan descriptor) (descriptorKind descriptor) (descriptorTargets descriptor) of
        Left failure -> pure (Left failure)
        Right () -> do
            materialized <- applyTargets session descriptor
            case materialized of
                Left failure -> pure (Left failure)
                Right () -> do
                    committed <-
                        compareAndSwapProtectedRecord
                            session
                            key
                            (ExpectVersion (protectedRecordVersion coordinator))
                            (encodeCoordinator (CoordinatorIdle (descriptorSequence descriptor)))
                    pure
                        ( either
                            (Left . TransactionStoreFailure)
                            (Right . TransactionPermit)
                            committed
                        )

applyTargets ::
    ProtectedSession session ->
    TransactionDescriptor ->
    IO (Either TransactionError ())
applyTargets session descriptor = go (descriptorTargets descriptor)
  where
    -- In descriptor order, and stopping at the first failure: a redo that
    -- skipped ahead would leave a gap the next recovery could not tell from a
    -- target the descriptor never named.
    go [] = pure (Right ())
    go (target : rest) = do
        applied <- applyTarget session (descriptorSequence descriptor) target
        case applied of
            Left failure -> pure (Left failure)
            Right () -> go rest

applyTarget ::
    ProtectedSession session ->
    Word64 ->
    TransactionTarget ->
    IO (Either TransactionError ())
applyTarget session sequenceNumber target = do
    observed <- readTransactionRecord session (targetKey target)
    case observed of
        Left failure -> pure (Left failure)
        Right current
            | targetAlreadyApplied sequenceNumber target current -> pure (Right ())
            | targetExpectationMatches (targetExpectation target) current -> do
                written <-
                    compareAndSwapProtectedRecord
                        session
                        (targetKey target)
                        (expectationFor current)
                        (stampTarget sequenceNumber (targetDesiredPayload target))
                pure (either (Left . TransactionStoreFailure) (const (Right ())) written)
            | otherwise ->
                pure
                    ( Left
                        ( TransactionTargetConflict
                            (recordKeyText (targetKey target))
                            sequenceNumber
                        )
                    )

targetAlreadyApplied :: Word64 -> TransactionTarget -> Maybe TransactionRecord -> Bool
targetAlreadyApplied sequenceNumber target current =
    case current of
        Just record ->
            transactionRecordStamp record == Just sequenceNumber
                && transactionRecordPayload record == targetDesiredPayload target
        Nothing -> False

targetExpectationMatches :: TargetExpectation -> Maybe TransactionRecord -> Bool
targetExpectationMatches TargetAbsent Nothing = True
targetExpectationMatches (TargetVersion expected) (Just record) =
    recordVersionWord (transactionRecordVersion record) == expected
targetExpectationMatches _ _ = False

expectationFor :: Maybe TransactionRecord -> Expectation
expectationFor Nothing = ExpectAbsent
expectationFor (Just record) = ExpectVersion (transactionRecordVersion record)

validateTargets :: Text -> TxnKind -> [TransactionTarget] -> Either TransactionError ()
validateTargets plan kind targets
    | not (all (targetMatchesPlan plan) targets) =
        Left (TransactionInvalidTargets kind "a target key is outside the transaction plan")
    | map targetRole targets /= expectedRoles kind =
        Left (TransactionInvalidTargets kind "the target roles do not match the closed transaction kind")
    | otherwise = Right ()

expectedRoles :: TxnKind -> [TargetRole]
expectedRoles kind = case kind of
    TxnOpenProject -> [ProjectTarget]
    TxnOpenSession -> [SessionTarget]
    TxnRegisterIntent -> [OperationTarget, SessionTarget]
    TxnPrepareOperation -> [OperationTarget]
    TxnAcknowledgeOutcome -> [OperationTarget]
    TxnRebindSession -> [SessionTarget]
    TxnCloseSession -> [SessionTarget]
    TxnBeginProjectClose -> [ProjectTarget]
    TxnRecordProjectClosed -> [ProjectTarget]
    TxnCloseProductionInvocation -> []
    TxnFinalizeHarnessClose -> []
    TxnFinalizeProductionProject -> []

{- | Whether a target names a record of this plan.

The comparison is against the plan digest's **record name**, not the digest
itself: a plan digest is namespaced, so the keys the store actually holds carry
its encoded form, and comparing the raw digest here would reject every real
plan's own targets.
-}
targetMatchesPlan :: Text -> TransactionTarget -> Bool
targetMatchesPlan plan target =
    case mkRecordName plan of
        Left _ -> False
        Right digest ->
            let key = recordKeyText (targetKey target)
             in case targetRole target of
                    ProjectTarget -> key == "project." <> digest
                    SessionTarget -> ("session." <> digest <> ".") `Text.isPrefixOf` key
                    OperationTarget ->
                        ("op." <> Text.pack (show (Hash.hash (TextEncoding.encodeUtf8 plan) :: Hash.Digest Hash.SHA256)) <> ".")
                            `Text.isPrefixOf` key

-- Encoding -----------------------------------------------------------------------

encodeCoordinator :: CoordinatorState -> ByteString
encodeCoordinator state = case state of
    CoordinatorIdle sequenceNumber ->
        encodeLine ["transaction-v1", "idle", showWord sequenceNumber]
    CoordinatorApplying descriptor ->
        ByteString.intercalate
            "\n"
            ( encodeLine
                [ "transaction-v1"
                , "applying"
                , showWord (descriptorSequence descriptor)
                , kindText (descriptorKind descriptor)
                , descriptorPlan descriptor
                , showWord (fromIntegral (length (descriptorTargets descriptor)))
                ]
                : map encodeTarget (descriptorTargets descriptor)
            )

decodeCoordinator :: ByteString -> Either TransactionError CoordinatorState
decodeCoordinator raw =
    case map decodeLine (ByteStringChar8.lines raw) of
        [["transaction-v1", "idle", sequenceText]] ->
            maybe
                (Left (TransactionMalformed "the Idle sequence is invalid"))
                (Right . CoordinatorIdle)
                (readWord sequenceText)
        ( ["transaction-v1", "applying", sequenceText, rawKind, plan, countText]
            : targetLines
            ) -> do
                sequenceNumber <-
                    maybe
                        (Left (TransactionMalformed "the Applying sequence is invalid"))
                        Right
                        (readWord sequenceText)
                kind <-
                    maybe
                        (Left (TransactionMalformed "the transaction kind is unknown"))
                        Right
                        (parseKind rawKind)
                count <-
                    maybe
                        (Left (TransactionMalformed "the target count is invalid"))
                        Right
                        (readWord countText)
                targets <- traverse decodeTarget targetLines
                if fromIntegral (length targets) /= count
                    then Left (TransactionMalformed "the target count does not match the descriptor")
                    else
                        Right
                            ( CoordinatorApplying
                                TransactionDescriptor
                                    { descriptorSequence = sequenceNumber
                                    , descriptorPlan = plan
                                    , descriptorKind = kind
                                    , descriptorTargets = targets
                                    }
                            )
        _ -> Left (TransactionMalformed "the coordinator record shape is invalid")

encodeTarget :: TransactionTarget -> ByteString
encodeTarget target =
    encodeLine
        [ "target"
        , roleText (targetRole target)
        , recordKeyText (targetKey target)
        , expectationText (targetExpectation target)
        , encodeHex (targetDesiredPayload target)
        ]

decodeTarget :: [Text] -> Either TransactionError TransactionTarget
decodeTarget ["target", rawRole, rawKey, rawExpectation, rawPayload] = do
    role <- maybe (Left (TransactionMalformed "a target role is invalid")) Right (parseRole rawRole)
    key <- either (Left . TransactionStoreFailure) Right (mkRecordKey rawKey)
    expectation <- parseExpectation rawExpectation
    payload <- decodeHex rawPayload
    Right
        TransactionTarget
            { targetRole = role
            , targetKey = key
            , targetExpectation = expectation
            , targetDesiredPayload = payload
            }
decodeTarget _ = Left (TransactionMalformed "a target descriptor is malformed")

encodeLine :: [Text] -> ByteString
encodeLine = ByteStringChar8.pack . Text.unpack . Text.intercalate "\t"

decodeLine :: ByteString -> [Text]
decodeLine = Text.splitOn "\t" . Text.pack . ByteStringChar8.unpack

kindText :: TxnKind -> Text
kindText kind = case kind of
    TxnOpenProject -> "open-project"
    TxnOpenSession -> "open-session"
    TxnRegisterIntent -> "register-intent"
    TxnPrepareOperation -> "prepare-operation"
    TxnAcknowledgeOutcome -> "acknowledge-outcome"
    TxnRebindSession -> "rebind-session"
    TxnCloseSession -> "close-session"
    TxnBeginProjectClose -> "begin-project-close"
    TxnRecordProjectClosed -> "record-project-closed"
    TxnCloseProductionInvocation -> "close-production-invocation"
    TxnFinalizeHarnessClose -> "finalize-harness-close"
    TxnFinalizeProductionProject -> "finalize-production-project"

parseKind :: Text -> Maybe TxnKind
parseKind raw = case raw of
    "open-project" -> Just TxnOpenProject
    "open-session" -> Just TxnOpenSession
    "register-intent" -> Just TxnRegisterIntent
    "prepare-operation" -> Just TxnPrepareOperation
    "acknowledge-outcome" -> Just TxnAcknowledgeOutcome
    "rebind-session" -> Just TxnRebindSession
    "close-session" -> Just TxnCloseSession
    "begin-project-close" -> Just TxnBeginProjectClose
    "record-project-closed" -> Just TxnRecordProjectClosed
    "close-production-invocation" -> Just TxnCloseProductionInvocation
    "finalize-harness-close" -> Just TxnFinalizeHarnessClose
    "finalize-production-project" -> Just TxnFinalizeProductionProject
    _ -> Nothing

roleText :: TargetRole -> Text
roleText role = case role of
    ProjectTarget -> "project"
    SessionTarget -> "session"
    OperationTarget -> "operation"

parseRole :: Text -> Maybe TargetRole
parseRole raw = case raw of
    "project" -> Just ProjectTarget
    "session" -> Just SessionTarget
    "operation" -> Just OperationTarget
    _ -> Nothing

expectationText :: TargetExpectation -> Text
expectationText expectation = case expectation of
    TargetAbsent -> "absent"
    TargetVersion version -> "version:" <> showWord version

parseExpectation :: Text -> Either TransactionError TargetExpectation
parseExpectation "absent" = Right TargetAbsent
parseExpectation raw =
    case Text.stripPrefix "version:" raw >>= readWord of
        Just version | version > 0 -> Right (TargetVersion version)
        _ -> Left (TransactionMalformed "a target expectation is invalid")

showWord :: Word64 -> Text
showWord = Text.pack . show

readWord :: Text -> Maybe Word64
readWord raw = case reads (Text.unpack raw) of
    [(value, "")] -> Just value
    _ -> Nothing

encodeHex :: ByteString -> Text
encodeHex = Text.pack . concatMap byteHex . ByteString.unpack
  where
    byteHex byte = case showHex byte "" of
        [digit] -> ['0', digit]
        digits -> digits

decodeHex :: Text -> Either TransactionError ByteString
decodeHex raw
    | odd (Text.length raw) || not (Text.all isHexDigit raw) =
        Left (TransactionMalformed "a target payload is not valid hexadecimal")
    | otherwise = ByteString.pack <$> traverse decodePair (pairs (Text.unpack raw))
  where
    pairs [] = []
    pairs (first : second : rest) = [first, second] : pairs rest
    pairs _ = []
    decodePair pair = case readHex pair of
        [(value, "")] -> Right (fromIntegral (value :: Int) :: Word8)
        _ -> Left (TransactionMalformed "a target payload contains an invalid byte")

-- Failures -----------------------------------------------------------------------

data TransactionError
    = TransactionStoreFailure ProtectedError
    | TransactionMalformed Text
    | TransactionStalePermit Word64
    | TransactionInvalidTargets TxnKind Text
    | TransactionTargetConflict Text Word64
    deriving (Eq, Show)

transactionErrorMessage :: TransactionError -> Text
transactionErrorMessage failure = case failure of
    TransactionStoreFailure storeFailure -> Text.pack (show storeFailure)
    TransactionMalformed reason -> "transaction: " <> reason
    TransactionStalePermit version ->
        "transaction: coordinator permit " <> showWord version <> " is stale"
    TransactionInvalidTargets kind reason ->
        "transaction: invalid " <> kindText kind <> " descriptor: " <> reason
    TransactionTargetConflict key sequenceNumber ->
        "transaction: target "
            <> key
            <> " conflicts while redoing transaction "
            <> showWord sequenceNumber
