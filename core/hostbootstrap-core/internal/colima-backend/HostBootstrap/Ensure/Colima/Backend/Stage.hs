{- | The durable direct-Colima stage graph, independent of filesystem and tool effects.

The backend record codec uses these names.  Keeping their order here makes
re-entry idempotent while refusing a skipped or reversed transition before any
effect is attempted.
-}
module HostBootstrap.Ensure.Colima.Backend.Stage
  ( ColimaStage (..),
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
    ColimaManagedEvidence (..),
    mkColimaManagedEvidence,
    colimaStageRecordEvidence,
    settleColimaStageRecord,
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
  | ColimaReleasedNamespaceExact
  deriving (Eq, Show, Enum, Bounded)

data ColimaStageDecision
  = AdvanceColimaStage ColimaStage
  | StartColimaProfile
  | DeleteColimaProfile
  | ReleaseColimaNamespace
  | KeepColimaStage
  deriving (Eq, Show)

data ColimaStageRecord = ColimaStageRecord
  { colimaStageRecordStage :: ColimaStage,
    colimaStageRecordOwner :: String,
    colimaStageRecordLineage :: String,
    colimaStageRecordInvocation :: String,
    colimaStageRecordEvidence :: Maybe ColimaManagedEvidence,
    colimaStageRecordCleanupInvocation :: Maybe String
  }
  deriving (Eq, Show)

data ColimaManagedEvidence = ColimaManagedEvidence
  { managedMachineIdentity :: String,
    managedMachineEpoch :: Word64,
    managedContextDigest :: String,
    managedManifestDigest :: String,
    managedDirectoryChainDigest :: String,
    managedCpu :: Integer,
    managedMemoryBytes :: Integer,
    managedDiskBytes :: Integer,
    managedRootDiskBytes :: Integer
  }
  deriving (Eq, Show)

mkColimaStageRecord :: ColimaStage -> String -> String -> String -> Either String ColimaStageRecord
mkColimaStageRecord stage owner lineage invocation
  | null owner || length owner > 4096 || any (`elem` "\r\n\0") owner = Left "stage-owner"
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
  | otherwise = Right record {colimaStageRecordStage = ColimaManaged, colimaStageRecordEvidence = Just evidence}

beginColimaReleaseRecord :: ColimaStageRecord -> String -> Either String ColimaStageRecord
beginColimaReleaseRecord record cleanupInvocation
  | not (validDigest cleanupInvocation) = Left "stage-cleanup-invocation"
  | colimaStageRecordStage record /= ColimaManaged = Left "stage-release"
  | colimaStageRecordEvidence record == Nothing = Left "stage-evidence"
  | otherwise =
      Right
        record
          { colimaStageRecordStage = ColimaReleasing,
            colimaStageRecordCleanupInvocation = Just cleanupInvocation
          }

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
            Right record {colimaStageRecordStage = successor}

renderColimaStageRecord :: ColimaStageRecord -> ByteString.ByteString
renderColimaStageRecord record =
  ByteString.Char8.pack
    (unlines (base ++ evidenceLines))
  where
    base =
      [ "colima-stage-v1",
        "stage " ++ renderColimaStage (colimaStageRecordStage record),
        "owner " ++ colimaStageRecordOwner record,
        "lineage " ++ colimaStageRecordLineage record,
        "invocation " ++ colimaStageRecordInvocation record
      ]
    evidenceLines = case colimaStageRecordEvidence record of
      Nothing -> []
      Just evidence ->
        [ "machine " ++ managedMachineIdentity evidence,
          "epoch " ++ show (managedMachineEpoch evidence),
          "context " ++ managedContextDigest evidence,
          "manifest " ++ managedManifestDigest evidence,
          "directory-chain " ++ managedDirectoryChainDigest evidence,
          "wall " ++ unwords (map show [managedCpu evidence, managedMemoryBytes evidence, managedDiskBytes evidence, managedRootDiskBytes evidence])
        ] ++ cleanupLines
    cleanupLines = case colimaStageRecordCleanupInvocation record of
      Nothing -> []
      Just cleanupInvocation -> ["cleanup " ++ cleanupInvocation]

parseColimaStageRecord :: ByteString.ByteString -> Either String ColimaStageRecord
parseColimaStageRecord raw =
  case lines (ByteString.Char8.unpack raw) of
    ["colima-stage-v1", stageLine, ownerLine, lineageLine, invocationLine]
      | Just stageRaw <- field "stage " stageLine,
        Just owner <- field "owner " ownerLine,
        Just lineage <- field "lineage " lineageLine,
        Just invocation <- field "invocation " invocationLine -> do
          stage <- parseColimaStage stageRaw
          record <- mkColimaStageRecord stage owner lineage invocation
          if renderColimaStageRecord record == raw then Right record else Left "stage-record"
    evidenceLines@[_, _, _, _, _, _, _, _, _, _, _] -> do
      record <- parseEvidenceRecord evidenceLines
      if colimaStageRecordStage record == ColimaManaged && renderColimaStageRecord record == raw then Right record else Left "stage-record"
    evidenceLines@[_, _, _, _, _, _, _, _, _, _, _, cleanupLine]
      | Just cleanupInvocation <- field "cleanup " cleanupLine,
        validDigest cleanupInvocation -> do
          base <- parseEvidenceRecord (init evidenceLines)
          if colimaStageRecordStage base < ColimaReleasing
            then Left "stage-record"
            else do
              let record = base {colimaStageRecordCleanupInvocation = Just cleanupInvocation}
              if renderColimaStageRecord record == raw then Right record else Left "stage-record"
    _ -> Left "stage-record"
  where
    field prefix value =
      if take (length prefix) value == prefix
        then Just (drop (length prefix) value)
        else Nothing

    validateBase stage owner lineage invocation
      | null owner || length owner > 4096 || any (`elem` "\r\n\0") owner = Left "stage-owner"
      | not (validDigest lineage) = Left "stage-lineage"
      | not (validDigest invocation) = Left "stage-invocation"
      | otherwise = Right (ColimaStageRecord stage owner lineage invocation Nothing Nothing)

    positiveRead value = case reads value of
      [(parsed, "")] | parsed > 0 -> Just parsed
      _ -> Nothing

    parseEvidenceRecord value =
      case value of
        ["colima-stage-v1", stageLine, ownerLine, lineageLine, invocationLine, machineLine, epochLine, contextLine, manifestLine, chainLine, wallLine]
          | Just stageRaw <- field "stage " stageLine,
            Just owner <- field "owner " ownerLine,
            Just lineage <- field "lineage " lineageLine,
            Just invocation <- field "invocation " invocationLine,
            Just machine <- field "machine " machineLine,
            Just epochRaw <- field "epoch " epochLine,
            Just context <- field "context " contextLine,
            Just manifest <- field "manifest " manifestLine,
            Just chain <- field "directory-chain " chainLine,
            [cpuRaw, memoryRaw, diskRaw, rootRaw] <- maybe [] words (field "wall " wallLine),
            Just epoch <- positiveRead epochRaw,
            Just cpu <- positiveRead cpuRaw,
            Just memory <- positiveRead memoryRaw,
            Just disk <- positiveRead diskRaw,
            Just rootDisk <- positiveRead rootRaw -> do
              stage <- parseColimaStage stageRaw
              base <- validateBase stage owner lineage invocation
              evidence <- mkColimaManagedEvidence machine epoch context manifest chain cpu memory disk rootDisk
              Right base {colimaStageRecordEvidence = Just evidence}
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

-- | Decide the sole lawful successor or mutation for a durable stage and an
-- authoritative observation. Mutations keep the current stage until their
-- result is re-observed; only a subsequent decision publishes a successor.
decideColimaStage :: ColimaStageIntent -> ColimaStage -> ColimaStageObservation -> Either String ColimaStageDecision
decideColimaStage intent stage observation =
  case (intent, stage, observation) of
    (AcquireColima, ColimaReserved, ColimaNamespaceAbsent) -> advance ColimaHomeStaged
    (AcquireColima, ColimaHomeStaged, ColimaHomeStageExact) -> advance ColimaHomeReady
    (AcquireColima, ColimaHomeReady, ColimaHomeExact) -> advance ColimaContextStaged
    (AcquireColima, ColimaContextStaged, ColimaContextStageExact) -> advance ColimaPrepared
    (AcquireColima, ColimaPrepared, ColimaProfileAbsent) -> Right StartColimaProfile
    (AcquireColima, ColimaPrepared, ColimaProfileExact) -> advance ColimaManaged
    (AcquireColima, ColimaManaged, ColimaProfileExact) -> Right KeepColimaStage
    (ReleaseColima, ColimaManaged, ColimaProfileExact) -> advance ColimaReleasing
    (ReleaseColima, ColimaReleasing, ColimaProfileExact) -> Right DeleteColimaProfile
    (ReleaseColima, ColimaReleasing, ColimaProfileAbsent) -> advance ColimaContextReleased
    (ReleaseColima, ColimaContextReleased, ColimaProfileAbsent) -> advance ColimaReleased
    (ReleaseColima, ColimaReleased, ColimaReleasedNamespaceExact) -> Right ReleaseColimaNamespace
    (ReleaseColima, ColimaReleased, ColimaNamespaceAbsent) -> Right KeepColimaStage
    _ -> Left "stage-observation"
  where
    advance successor = AdvanceColimaStage <$> advanceColimaStage stage successor
