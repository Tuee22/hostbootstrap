{- | The durable direct-Colima stage graph, independent of filesystem and tool effects.

The backend record codec uses these names.  Keeping their order here makes
re-entry idempotent while refusing a skipped or reversed transition before any
effect is attempted.
-}
module HostBootstrap.Ensure.Colima.Backend.Stage (
    ColimaStage (..),
    renderColimaStage,
    parseColimaStage,
    advanceColimaStage,
    ColimaStageIntent (..),
    ColimaStageObservation (..),
    ColimaStageDecision (..),
    decideColimaStage,
    ColimaStageRecord,
    mkColimaStageRecord,
    colimaStageRecordStage,
    colimaStageRecordOwner,
    colimaStageRecordLineage,
    colimaStageRecordInvocation,
    renderColimaStageRecord,
    parseColimaStageRecord,
    ColimaManagedEvidence,
    managedMachineIdentity,
    managedMachineEpoch,
    managedContextDigest,
    managedManifestDigest,
    managedDirectoryChainDigest,
    managedCpu,
    managedMemoryBytes,
    managedDiskBytes,
    managedRootDiskBytes,
    mkColimaManagedEvidence,
    colimaStageRecordEvidence,
    settleColimaStageRecord,
    refreshColimaManifestRecord,
    advanceSettledColimaStageRecord,
    beginColimaReleaseRecord,
    colimaStageRecordCleanupInvocation,
)
where

import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString.Char8
import Data.Word (Word64)

data ColimaStage
    = ColimaReserved
    | ColimaHomeStaged
    | ColimaHomeReady
    | ColimaContextStaged
    | ColimaPrepared
    | ColimaManaged
    | ColimaReleasing
    | ColimaContextReleased
    | ColimaReleased
    deriving (Eq, Ord, Show, Enum, Bounded)

data ColimaStageIntent = AcquireColima | ReleaseColima
    deriving (Eq, Show)

data ColimaStageObservation
    = ColimaNamespaceAbsent
    | ColimaHomeStageExact
    | ColimaHomeExact
    | ColimaContextStageExact
    | ColimaProfileAbsent
    | ColimaProfileExact
    | ColimaCreatedProfileExact
    | ColimaReleasedNamespaceExact
    deriving (Eq, Show, Enum, Bounded)

data ColimaStageDecision
    = AdvanceColimaStage ColimaStage
    | BeginColimaLineage
    | StartColimaProfile
    | DeleteColimaProfile
    | ReleaseColimaNamespace
    | KeepColimaStage
    deriving (Eq, Show)

data ColimaStageRecord = ColimaStageRecord ColimaStage String String String (Maybe ColimaManagedEvidence) (Maybe String)
    deriving (Eq, Show)

colimaStageRecordStage :: ColimaStageRecord -> ColimaStage
colimaStageRecordStage (ColimaStageRecord value _ _ _ _ _) = value

colimaStageRecordOwner :: ColimaStageRecord -> String
colimaStageRecordOwner (ColimaStageRecord _ value _ _ _ _) = value

colimaStageRecordLineage :: ColimaStageRecord -> String
colimaStageRecordLineage (ColimaStageRecord _ _ value _ _ _) = value

colimaStageRecordInvocation :: ColimaStageRecord -> String
colimaStageRecordInvocation (ColimaStageRecord _ _ _ value _ _) = value

colimaStageRecordEvidence :: ColimaStageRecord -> Maybe ColimaManagedEvidence
colimaStageRecordEvidence (ColimaStageRecord _ _ _ _ value _) = value

colimaStageRecordCleanupInvocation :: ColimaStageRecord -> Maybe String
colimaStageRecordCleanupInvocation (ColimaStageRecord _ _ _ _ _ value) = value

data ColimaManagedEvidence = ColimaManagedEvidence String Word64 String String String Integer Integer Integer Integer
    deriving (Eq, Show)

managedMachineIdentity :: ColimaManagedEvidence -> String
managedMachineIdentity (ColimaManagedEvidence value _ _ _ _ _ _ _ _) = value

managedMachineEpoch :: ColimaManagedEvidence -> Word64
managedMachineEpoch (ColimaManagedEvidence _ value _ _ _ _ _ _ _) = value

managedContextDigest :: ColimaManagedEvidence -> String
managedContextDigest (ColimaManagedEvidence _ _ value _ _ _ _ _ _) = value

managedManifestDigest :: ColimaManagedEvidence -> String
managedManifestDigest (ColimaManagedEvidence _ _ _ value _ _ _ _ _) = value

managedDirectoryChainDigest :: ColimaManagedEvidence -> String
managedDirectoryChainDigest (ColimaManagedEvidence _ _ _ _ value _ _ _ _) = value

managedCpu :: ColimaManagedEvidence -> Integer
managedCpu (ColimaManagedEvidence _ _ _ _ _ value _ _ _) = value

managedMemoryBytes :: ColimaManagedEvidence -> Integer
managedMemoryBytes (ColimaManagedEvidence _ _ _ _ _ _ value _ _) = value

managedDiskBytes :: ColimaManagedEvidence -> Integer
managedDiskBytes (ColimaManagedEvidence _ _ _ _ _ _ _ value _) = value

managedRootDiskBytes :: ColimaManagedEvidence -> Integer
managedRootDiskBytes (ColimaManagedEvidence _ _ _ _ _ _ _ _ value) = value

setRecordStage :: ColimaStage -> ColimaStageRecord -> ColimaStageRecord
setRecordStage stage (ColimaStageRecord _ owner lineage invocation evidence cleanup) =
    ColimaStageRecord stage owner lineage invocation evidence cleanup

setRecordEvidence :: Maybe ColimaManagedEvidence -> ColimaStageRecord -> ColimaStageRecord
setRecordEvidence evidence (ColimaStageRecord stage owner lineage invocation _ cleanup) =
    ColimaStageRecord stage owner lineage invocation evidence cleanup

setRecordCleanup :: Maybe String -> ColimaStageRecord -> ColimaStageRecord
setRecordCleanup cleanup (ColimaStageRecord stage owner lineage invocation evidence _) =
    ColimaStageRecord stage owner lineage invocation evidence cleanup

mkColimaStageRecord :: ColimaStage -> String -> String -> String -> Either String ColimaStageRecord
mkColimaStageRecord stage owner lineage invocation
    | null owner || length owner > 4096 || any (\character -> character < '!' || character > '~') owner = Left "stage-owner"
    | not (validDigest lineage) = Left "stage-lineage"
    | not (validDigest invocation) = Left "stage-invocation"
    | stage > ColimaPrepared = Left "stage-evidence"
    | otherwise = Right (ColimaStageRecord stage owner lineage invocation Nothing Nothing)

mkColimaManagedEvidence :: String -> Word64 -> String -> String -> String -> Integer -> Integer -> Integer -> Integer -> Either String ColimaManagedEvidence
mkColimaManagedEvidence machine epoch context manifest chain cpu memory disk rootDisk
    | length machine /= 32 || not (all isLowerHex machine) = Left "stage-machine"
    | epoch == 0 = Left "stage-epoch"
    | not (validDigest context) = Left "stage-context"
    | not (validDigest manifest) = Left "stage-manifest"
    | not (validDigest chain) = Left "stage-directory-chain"
    | any (<= 0) [cpu, memory, disk, rootDisk] = Left "stage-wall"
    | otherwise = Right (ColimaManagedEvidence machine epoch context manifest chain cpu memory disk rootDisk)

settleColimaStageRecord :: ColimaStageRecord -> ColimaManagedEvidence -> Either String ColimaStageRecord
settleColimaStageRecord record evidence
    | colimaStageRecordStage record /= ColimaPrepared = Left "stage-settlement"
    | otherwise = case decideColimaStage AcquireColima ColimaPrepared ColimaCreatedProfileExact of
        Right (AdvanceColimaStage ColimaManaged) ->
            Right (setRecordEvidence (Just evidence) (setRecordStage ColimaManaged record))
        _ -> Left "stage-settlement"

-- | Managed namespaces may change; release proof is immutable once frozen.
-- Refresh only the manifest facts, preserving identity, wall and lineage.
refreshColimaManifestRecord :: ColimaStageRecord -> String -> String -> Either String ColimaStageRecord
refreshColimaManifestRecord record manifest chain
    | colimaStageRecordStage record /= ColimaManaged = Left "stage-manifest-refresh"
    | otherwise = case colimaStageRecordEvidence record of
        Nothing -> Left "stage-evidence"
        Just evidence -> do
            refreshed <- mkColimaManagedEvidence
                (managedMachineIdentity evidence)
                (managedMachineEpoch evidence)
                (managedContextDigest evidence)
                manifest chain
                (managedCpu evidence)
                (managedMemoryBytes evidence)
                (managedDiskBytes evidence)
                (managedRootDiskBytes evidence)
            Right (setRecordEvidence (Just refreshed) record)

beginColimaReleaseRecord :: ColimaStageRecord -> String -> Either String ColimaStageRecord
beginColimaReleaseRecord record cleanupInvocation
    | not (validDigest cleanupInvocation) = Left "stage-cleanup-invocation"
    | colimaStageRecordStage record /= ColimaManaged = Left "stage-release"
    | colimaStageRecordEvidence record == Nothing = Left "stage-evidence"
    | otherwise =
        Right (setRecordCleanup (Just cleanupInvocation) (setRecordStage ColimaReleasing record))

advanceSettledColimaStageRecord :: ColimaStageRecord -> ColimaStage -> Either String ColimaStageRecord
advanceSettledColimaStageRecord record successor = do
    case colimaStageRecordEvidence record of
        Nothing -> Left "stage-evidence"
        Just _ -> do
            if colimaStageRecordStage record == ColimaManaged && successor == ColimaReleasing
                then Left "stage-cleanup-invocation"
                else case colimaStageRecordCleanupInvocation record of
                    Nothing -> Left "stage-cleanup-invocation"
                    Just _ -> do
                        _ <- advanceColimaStage (colimaStageRecordStage record) successor
                        Right (setRecordStage successor record)

renderColimaStageRecord :: ColimaStageRecord -> ByteString.ByteString
renderColimaStageRecord record =
    ByteString.Char8.pack
        (unlines (base ++ evidenceLines))
  where
    base =
        [ "colima-stage-v1"
        , "stage " ++ renderColimaStage (colimaStageRecordStage record)
        , "owner " ++ colimaStageRecordOwner record
        , "lineage " ++ colimaStageRecordLineage record
        , "invocation " ++ colimaStageRecordInvocation record
        ]
    evidenceLines = case colimaStageRecordEvidence record of
        Nothing -> []
        Just evidence ->
            [ "machine " ++ managedMachineIdentity evidence
            , "epoch " ++ show (managedMachineEpoch evidence)
            , "context " ++ managedContextDigest evidence
            , "manifest " ++ managedManifestDigest evidence
            , "directory-chain " ++ managedDirectoryChainDigest evidence
            , "wall " ++ unwords (map show [managedCpu evidence, managedMemoryBytes evidence, managedDiskBytes evidence, managedRootDiskBytes evidence])
            ]
                ++ cleanupLines
    cleanupLines = case colimaStageRecordCleanupInvocation record of
        Nothing -> []
        Just cleanupInvocation -> ["cleanup " ++ cleanupInvocation]

parseColimaStageRecord :: ByteString.ByteString -> Either String ColimaStageRecord
parseColimaStageRecord raw =
    case lines (ByteString.Char8.unpack raw) of
        ["colima-stage-v1", stageLine, ownerLine, lineageLine, invocationLine]
            | Just stageRaw <- field "stage " stageLine
            , Just owner <- field "owner " ownerLine
            , Just lineage <- field "lineage " lineageLine
            , Just invocation <- field "invocation " invocationLine -> do
                stage <- parseColimaStage stageRaw
                record <- mkColimaStageRecord stage owner lineage invocation
                if renderColimaStageRecord record == raw then Right record else Left "stage-record"
        evidenceLines@[_, _, _, _, _, _, _, _, _, _, _] -> do
            record <- parseEvidenceRecord evidenceLines
            if colimaStageRecordStage record == ColimaManaged && renderColimaStageRecord record == raw then Right record else Left "stage-record"
        evidenceLines@[_, _, _, _, _, _, _, _, _, _, _, cleanupLine]
            | Just cleanupInvocation <- field "cleanup " cleanupLine
            , validDigest cleanupInvocation -> do
                base <- parseEvidenceRecord (init evidenceLines)
                if colimaStageRecordStage base < ColimaReleasing
                    then Left "stage-record"
                    else do
                        let record = setRecordCleanup (Just cleanupInvocation) base
                        if renderColimaStageRecord record == raw then Right record else Left "stage-record"
        _ -> Left "stage-record"
  where
    field prefix value =
        if take (length prefix) value == prefix
            then Just (drop (length prefix) value)
            else Nothing

    validateBase stage owner lineage invocation
        | null owner || length owner > 4096 || any (\character -> character < '!' || character > '~') owner = Left "stage-owner"
        | not (validDigest lineage) = Left "stage-lineage"
        | not (validDigest invocation) = Left "stage-invocation"
        | otherwise = Right (ColimaStageRecord stage owner lineage invocation Nothing Nothing)

    positiveRead value = case reads value of
        [(parsed, "")] | parsed > 0 -> Just parsed
        _ -> Nothing

    parseEvidenceRecord value =
        case value of
            ["colima-stage-v1", stageLine, ownerLine, lineageLine, invocationLine, machineLine, epochLine, contextLine, manifestLine, chainLine, wallLine]
                | Just stageRaw <- field "stage " stageLine
                , Just owner <- field "owner " ownerLine
                , Just lineage <- field "lineage " lineageLine
                , Just invocation <- field "invocation " invocationLine
                , Just machine <- field "machine " machineLine
                , Just epochRaw <- field "epoch " epochLine
                , Just context <- field "context " contextLine
                , Just manifest <- field "manifest " manifestLine
                , Just chain <- field "directory-chain " chainLine
                , [cpuRaw, memoryRaw, diskRaw, rootRaw] <- maybe [] words (field "wall " wallLine)
                , Just epoch <- positiveRead epochRaw
                , Just cpu <- positiveRead cpuRaw
                , Just memory <- positiveRead memoryRaw
                , Just disk <- positiveRead diskRaw
                , Just rootDisk <- positiveRead rootRaw -> do
                    stage <- parseColimaStage stageRaw
                    base <- validateBase stage owner lineage invocation
                    evidence <- mkColimaManagedEvidence machine epoch context manifest chain cpu memory disk rootDisk
                    Right (setRecordEvidence (Just evidence) base)
            _ -> Left "stage-record"

validDigest :: String -> Bool
validDigest value = length value == 64 && all isLowerHex value

isLowerHex :: Char -> Bool
isLowerHex character = character >= '0' && character <= '9' || character >= 'a' && character <= 'f'

renderColimaStage :: ColimaStage -> String
renderColimaStage stage = case stage of
    ColimaReserved -> "reserved"
    ColimaHomeStaged -> "home-staged"
    ColimaHomeReady -> "home-ready"
    ColimaContextStaged -> "context-staged"
    ColimaPrepared -> "prepared"
    ColimaManaged -> "managed"
    ColimaReleasing -> "releasing"
    ColimaContextReleased -> "context-released"
    ColimaReleased -> "released"

parseColimaStage :: String -> Either String ColimaStage
parseColimaStage raw =
    case filter ((== raw) . renderColimaStage) [minBound .. maxBound] of
        [stage] -> Right stage
        _ -> Left "record-state"

{- | Admit an observation only when it repeats the durable stage or names its
single successor.  A later invocation opens a new lineage from 'ColimaReserved';
it does not turn a released record backwards through this graph.
-}
advanceColimaStage :: ColimaStage -> ColimaStage -> Either String ColimaStage
advanceColimaStage current observed
    | observed == current = Right current
    | fromEnum observed == fromEnum current + 1 = Right observed
    | otherwise = Left "stage-transition"

{- | Decide the sole lawful successor or mutation for a durable stage and an
authoritative observation. Mutations keep the current stage until their
result is re-observed; only a subsequent decision publishes a successor.
-}
decideColimaStage :: ColimaStageIntent -> ColimaStage -> ColimaStageObservation -> Either String ColimaStageDecision
decideColimaStage intent stage observation =
    case (intent, stage, observation) of
        (AcquireColima, ColimaReserved, ColimaNamespaceAbsent) -> advance ColimaHomeStaged
        (AcquireColima, ColimaReserved, ColimaHomeStageExact) -> advance ColimaHomeStaged
        (AcquireColima, ColimaHomeStaged, ColimaHomeStageExact) -> advance ColimaHomeReady
        (AcquireColima, ColimaHomeReady, ColimaHomeExact) -> advance ColimaContextStaged
        (AcquireColima, ColimaContextStaged, ColimaContextStageExact) -> advance ColimaPrepared
        (AcquireColima, ColimaPrepared, ColimaContextStageExact) -> Right KeepColimaStage
        (AcquireColima, ColimaPrepared, ColimaProfileAbsent) -> Right StartColimaProfile
        (AcquireColima, ColimaPrepared, ColimaProfileExact) -> Right KeepColimaStage
        (AcquireColima, ColimaPrepared, ColimaCreatedProfileExact) -> advance ColimaManaged
        (AcquireColima, ColimaManaged, ColimaProfileExact) -> Right KeepColimaStage
        (AcquireColima, ColimaReleased, ColimaNamespaceAbsent) -> Right BeginColimaLineage
        (ReleaseColima, ColimaManaged, ColimaProfileExact) -> advance ColimaReleasing
        (ReleaseColima, ColimaReleasing, ColimaProfileExact) -> Right DeleteColimaProfile
        (ReleaseColima, ColimaReleasing, ColimaProfileAbsent) -> advance ColimaContextReleased
        (ReleaseColima, ColimaContextReleased, ColimaReleasedNamespaceExact) -> Right ReleaseColimaNamespace
        (ReleaseColima, ColimaContextReleased, ColimaNamespaceAbsent) -> advance ColimaReleased
        (ReleaseColima, ColimaReleased, ColimaReleasedNamespaceExact) -> Right ReleaseColimaNamespace
        (ReleaseColima, ColimaReleased, ColimaNamespaceAbsent) -> Right KeepColimaStage
        _ -> Left "stage-observation"
  where
    advance successor = AdvanceColimaStage <$> advanceColimaStage stage successor
