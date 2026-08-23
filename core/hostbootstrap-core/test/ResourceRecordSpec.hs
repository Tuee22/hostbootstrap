{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ResourceRecordSpec (tests, withRecoveryFixture, withRecoveryFixtureFor, withReleasedRecoveryFixture, withReleasedRecoveryFixtureFor, withRecoveryRootFixtureFor, withCanonicalResourceFixture, withCanonicalReleasedResourceFixture, wrongRecoveryMembership) where

import Data.Bits (shiftL, shiftR, (.|.))
import qualified Data.ByteString as ByteString
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64, Word8)
import qualified Fixture
import HostBootstrap.Authority (InstalledProjectIdentity, VerbUp)
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Lifecycle.Mode
    ( ModeError (ModeMalformedRecord)
    , ProductionRoot
    , VerifiedPlanSnapshot
    , productionRootAuthority
    , productionRootModeLease
    , productionRootUnboundLease
    , projectModeLeaseEpoch
    , recordSetDigest
    , withVerifiedResourceRecordSet
    )
import HostBootstrap.ProjectPlan
    ( ProjectPlan
    , forward
    , plannedResourceFrame
    , plannedResourceKey
    , plannedStepOperationKey
    , withPlannedResourceOfKind
    )
import HostBootstrap.ProjectPlan.Snapshot (BoundPlanSnapshot, withPersistedPlanSnapshot)
import HostBootstrap.Lifecycle.Session
    ( SessionError (SessionRecordCorrupt)
    , RehydratedResourceSet
    , foldRehydratedResourceSet
    , withRehydratedResourceSet
    )
import HostBootstrap.Protected
    ( Expectation (ExpectAbsent)
    , ProtectedSession
    , ProtectedStore
    , compareAndSwapProtectedRecord
    , mkRecordKey
    , openProtectedStore
    , withProtectedEntry
    )
import HostBootstrap.Reconcile hiding (plannedResourceFrame, plannedResourceKey)
import HostBootstrap.Step
    ( StepFrame (StepFrame)
    , StepObservation (StepChanged)
    , StepPlan
    , deployKindStep
    , deployVMStep
    , mkStepPlan
    , operationKeyText
    )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

tests :: TestTree
tests =
    testGroup
        "ResourceRecordSpec"
        [ testCase "owned and released canonical records round-trip through the exact bundle" $
            withResource $ \plan planned -> do
                owned <- record plan planned True
                released <- record plan planned False
                (disposition <$> verify plan planned owned) @?= Right "owned:core:deploy-kind"
                (disposition <$> verify plan planned released) @?= Right "released:running:adapter-v1"
        , testCase "long frame and resource identities produce a bounded collision-resistant key" $ do
            let plan = Text.replicate 64 "a"
                frame = Text.replicate 90 "f"
                first = resourceRecordKey plan frame (Text.replicate 90 "a")
                second = resourceRecordKey plan frame (Text.replicate 90 "b")
            (first /= second) @?= True
            either (assertFailure . show) (\key -> Text.length key <= 200 @?= True) first
        , testCase "every durable binding substitution refuses" $
            withResource $ \plan planned -> do
                canonical <- record plan planned True
                let substitutions =
                        [ (2, "wrong-plan")
                        , (3, "wrong-frame")
                        , (4, "wrong-resource")
                        , (5, "8")
                        , (6, "wrong-operation")
                        , (7, "4")
                        , (8, "stopped")
                        , (9, "adapter-v2")
                        ]
                mapM_
                    (\(index, replacement) -> assertRefused plan planned (replaceFrame index replacement canonical))
                    substitutions
        , testCase "format, disposition, truncation, trailing bytes, and noncanonical words refuse" $
            withResource $ \plan planned -> do
                canonical <- record plan planned True
                mapM_
                    (assertRefused plan planned)
                    [ replaceFrame 1 "2" canonical
                    , replaceFrame 10 "foreign" canonical
                    , replaceFrame 5 "07" canonical
                    , ByteString.init canonical
                    , canonical <> "x"
                    ]
        , testCase "the protected exact-set fold accepts every snapshot member" $
            exactSetDigest False >>= assertRightDigest
        , testCase "record-set digest is stable across immutable protected read-back" $ do
            digests <- exactSetDigests
            case digests of
                Left _ -> assertFailure "the immutable record set was refused"
                Right (first, second) -> first @?= second
        , testCase "missing and extra members refuse the complete set" $ do
            missing <- missingSet
            assertMalformed missing
            extra <- extraSet
            assertMalformed extra
        , testCase "the complete set rehydrates owned and released members under its broker" $
            rehydratedDispositions >>= (@?= Right (1, 1))
        , testCase "rehydration refuses the verified set in another protected store" $
            staleStoreRehydration >>= (@?= Right True)
        ]

assertRightDigest :: Either error Text -> IO ()
assertRightDigest result = case result of
    Left _ -> assertFailure "the exact resource set was refused"
    Right digest | Text.length digest == 64 -> pure ()
    Right _ -> assertFailure "the record-set digest is not SHA-256"

assertMalformed :: Either ModeError result -> IO ()
assertMalformed result = case result of
    Left (ModeMalformedRecord _) -> pure ()
    _ -> assertFailure "an incomplete or extra record set was accepted"

exactSetDigest :: Bool -> IO (Either ModeError Text)
exactSetDigest reverseWrites =
    withSetFixture twoResourcePlan $ \store _root plan verified bound -> do
        records <- resourceRecords plan
        let ordered = if reverseWrites then reverse records else records
        mapM_ (uncurry (writeRecord store)) ordered
        withSetSession store $ \session ->
            withVerifiedResourceRecordSet session verified bound recordSetDigest

exactSetDigests :: IO (Either ModeError (Text, Text))
exactSetDigests =
    withSetFixture twoResourcePlan $ \store _root plan verified bound -> do
        records <- resourceRecords plan
        mapM_ (uncurry (writeRecord store)) (reverse records)
        first <- withSetSession store $ \session ->
            withVerifiedResourceRecordSet session verified bound recordSetDigest
        second <- withSetSession store $ \session ->
            withVerifiedResourceRecordSet session verified bound recordSetDigest
        pure ((,) <$> first <*> second)

missingSet :: IO (Either ModeError ())
missingSet =
    withSetFixture twoResourcePlan $ \store _root _plan verified bound ->
        withSetSession store $ \session ->
            withVerifiedResourceRecordSet session verified bound (const ())

extraSet :: IO (Either ModeError ())
extraSet =
    withSetFixture resourcePlan $ \store _root plan verified bound -> do
        records <- resourceRecords plan
        case records of
            [(key, bytes)] -> do
                writeRecord store key bytes
                let extraBytes = replaceFrame 4 "project:extra-resource" bytes
                extraKey <- resourceKey (lifecyclePlanDigest (lifecyclePlanFromProjectPlan plan)) "host" "project:extra-resource"
                writeRecord store extraKey extraBytes
            _ -> assertFailure "the singleton resource fixture changed"
        withSetSession store $ \session ->
            withVerifiedResourceRecordSet session verified bound (const ())

wrongRecoveryMembership :: IO (Either ModeError ())
wrongRecoveryMembership = extraSet

withCanonicalResourceFixture ::
    (CanonicalPlanSnapshot -> [(Text, ByteString.ByteString)] -> IO result) ->
    IO result
withCanonicalResourceFixture use =
    Fixture.withFixtureProjectPlan resourcePlan $ \plan -> do
        records <- resourceRecords plan
        use (lifecyclePlanSnapshot (lifecyclePlanFromProjectPlan plan)) records

withCanonicalReleasedResourceFixture ::
    (CanonicalPlanSnapshot -> [(Text, ByteString.ByteString)] -> IO result) ->
    IO result
withCanonicalReleasedResourceFixture use =
    withCanonicalResourceFixture $ \snapshot records ->
        use snapshot [(key, replaceFrame 10 "released" bytes) | (key, bytes) <- records]

withSetSession ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either ModeError result)) ->
    IO (Either ModeError result)
withSetSession store action = do
    withProtectedValue store action

withProtectedValue ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO result) ->
    IO result
withProtectedValue store action = do
    entered <- withProtectedEntry store (fmap Right . action)
    pure $ case entered of
        Left failure -> error (show failure)
        Right result -> result

rehydratedDispositions :: IO (Either ModeError (Int, Int))
rehydratedDispositions =
    withSetFixture twoResourcePlan $ \store root plan verified bound -> do
        records <- resourceRecords plan
        let mixed = case records of
                [owned, (key, released)] -> [owned, (key, replaceFrame 10 "released" released)]
                _ -> records
        mapM_ (uncurry (writeRecord store)) mixed
        withSetSession store $ \session ->
            withVerifiedResourceRecordSet session verified bound $ \set ->
                case withRehydratedResourceSet session (projectModeLeaseEpoch (productionRootModeLease root)) set $ \rehydrated ->
                    snd $
                        foldRehydratedResourceSet
                            rehydrated
                            (0, 0)
                            (\(owned, released) _handle _receipt -> (owned + 1, released))
                            (\(owned, released) _tombstone -> (owned, released + 1))
                 of
                    Left failure -> error (show failure)
                    Right counts -> counts

staleStoreRehydration :: IO (Either ModeError Bool)
staleStoreRehydration =
    withSetFixture resourcePlan $ \store root plan verified bound -> do
        records <- resourceRecords plan
        mapM_ (uncurry (writeRecord store)) records
        withSystemTempDirectory "hostbootstrap-other-protected" $ \directory -> do
            other <- openProtectedStore (directory </> "store") >>= either (assertFailure . show) pure
            deferred <- withSetSession store $ \session ->
                withVerifiedResourceRecordSet session verified bound $ \set ->
                    withProtectedValue other $ \otherSession ->
                        pure $ case withRehydratedResourceSet otherSession (projectModeLeaseEpoch (productionRootModeLease root)) set (const ()) of
                            Left (SessionRecordCorrupt _) -> True
                            _ -> False
            case deferred of
                Left failure -> pure (Left failure)
                Right action -> Right <$> action

withSetFixture ::
    StepPlan ->
    ( forall projectId brokerGeneration specDigest planId configId planDigest.
      ProtectedStore ->
      ProductionRoot projectId brokerGeneration VerbUp ->
      ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
      BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withSetFixture planSteps use =
    Fixture.withFixtureProjectPlanRoot planSteps $ \store _project root plan -> do
        opened <-
            withPersistedPlanSnapshot
                (productionRootAuthority root)
                (productionRootUnboundLease root)
                plan
                (\verified bound _binding _lease _recovery -> use store root plan verified bound)
        pure $ case opened of
            Left failure -> error (show failure)
            Right result -> result

resourceRecords ::
    ProjectPlan scope specDigest planId configId cfg ->
    IO [(Text, ByteString.ByteString)]
resourceRecords projectPlan = do
    let lifecycle = lifecyclePlanFromProjectPlan projectPlan
    provider <- case findOperation "core:deploy-vm" of
        Nothing -> pure Nothing
        Just operation -> case withPlannedResourceOfKind projectPlan ProviderResourceKind operation (renderOne lifecycle "core:deploy-vm") of
            Left _ -> pure Nothing
            Right action -> Just <$> action
    cluster <- case findOperation "core:deploy-kind" of
        Nothing -> pure Nothing
        Just operation -> case withPlannedResourceOfKind projectPlan ClusterResourceKind operation (renderOne lifecycle "core:deploy-kind") of
            Left _ -> pure Nothing
            Right action -> Just <$> action
    pure [value | Just value <- [provider, cluster]]
  where
    findOperation wanted =
        case [plannedStepOperationKey node | node <- NonEmpty.toList (forward projectPlan), Text.pack (operationKeyText (plannedStepOperationKey node)) == wanted] of
            [found] -> Just found
            _ -> Nothing
    renderOne lifecycle operation planned = do
        bytes <- either (assertFailure . show) pure $ renderResourceRecordBundle lifecycle planned 7 operation 3 "running" "adapter-v1" True
        keyText <- resourceKey (lifecyclePlanDigest lifecycle) (plannedResourceFrame planned) (plannedResourceKey planned)
        pure (keyText, bytes)

writeRecord :: ProtectedStore -> Text -> ByteString.ByteString -> IO ()
writeRecord store rawKey bytes = do
    key <- either (assertFailure . show) pure (mkRecordKey rawKey)
    written <- withProtectedEntry store $ \session -> compareAndSwapProtectedRecord session key ExpectAbsent bytes
    either (assertFailure . show) (const (pure ())) written

resourceKey :: Text -> Text -> Text -> IO Text
resourceKey plan frame resource =
    either (assertFailure . show) pure (resourceRecordKey plan frame resource)

record :: LifecyclePlan scope planId -> PlannedResource scope planId id resource frame -> Bool -> IO ByteString.ByteString
record plan planned owned =
    either (assertFailure . show) pure $
        renderResourceRecordBundle plan planned 7 "core:deploy-kind" 3 "running" "adapter-v1" owned

verify :: LifecyclePlan scope planId -> PlannedResource scope planId id resource frame -> ByteString.ByteString -> Either ReconcileError (VerifiedResourceRecordBundle scope planId id resource)
verify plan planned =
    verifyResourceRecordBundle plan planned 7 "core:deploy-kind" 3 "running" "adapter-v1"

disposition :: VerifiedResourceRecordBundle scope planId id resource -> Text
disposition bundle =
    withVerifiedResourceRecordBundle
        bundle
        (\receipt -> "owned:" <> ownershipReceiptOperationKey receipt)
        (\_ _ _ _ phase adapter _ -> "released:" <> phase <> ":" <> adapter)

assertRefused :: LifecyclePlan scope planId -> PlannedResource scope planId id resource frame -> ByteString.ByteString -> IO ()
assertRefused plan planned raw =
    case verify plan planned raw of
        Left _ -> pure ()
        Right _ -> assertFailure "a substituted resource record was accepted"

withRecoveryFixture ::
    (forall projectId specDigest planDigest planId brokerGeneration.
      VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
      RehydratedResourceSet (Production projectId) planId brokerGeneration ->
      IO result) ->
    IO result
withRecoveryFixture use =
    withRecoveryFixtureFor resourcePlan use

withRecoveryFixtureFor ::
    StepPlan ->
    (forall projectId specDigest planDigest planId brokerGeneration.
      VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
      RehydratedResourceSet (Production projectId) planId brokerGeneration ->
      IO result) ->
    IO result
withRecoveryFixtureFor planSteps use =
    withRecoveryFixtureDisposition False planSteps use

withReleasedRecoveryFixture ::
    (forall projectId specDigest planDigest planId brokerGeneration.
      VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
      RehydratedResourceSet (Production projectId) planId brokerGeneration ->
      IO result) ->
    IO result
withReleasedRecoveryFixture =
    withRecoveryFixtureDisposition True resourcePlan

withReleasedRecoveryFixtureFor ::
    StepPlan ->
    (forall projectId specDigest planDigest planId brokerGeneration.
      VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
      RehydratedResourceSet (Production projectId) planId brokerGeneration ->
      IO result) ->
    IO result
withReleasedRecoveryFixtureFor = withRecoveryFixtureDisposition True

withRecoveryFixtureDisposition ::
    Bool ->
    StepPlan ->
    (forall projectId specDigest planDigest planId brokerGeneration.
      VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
      RehydratedResourceSet (Production projectId) planId brokerGeneration ->
      IO result) ->
    IO result
withRecoveryFixtureDisposition released planSteps use =
    do
        opened <- withSetFixture planSteps $ \store root plan verified bound -> do
            records <- resourceRecords plan
            let durableRecords =
                    if released
                        then [(key, replaceFrame 10 "released" bytes) | (key, bytes) <- records]
                        else records
            mapM_ (uncurry (writeRecord store)) durableRecords
            withSetSession store $ \session ->
                withVerifiedResourceRecordSet session verified bound $ \set ->
                    case withRehydratedResourceSet session (projectModeLeaseEpoch (productionRootModeLease root)) set (use verified) of
                        Left failure -> error (show failure)
                        Right action -> action
        either (error . show) id opened

withRecoveryRootFixtureFor ::
    StepPlan ->
    (forall projectId brokerGeneration specDigest planDigest planId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      ProductionRoot projectId brokerGeneration VerbUp ->
      VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
      RehydratedResourceSet (Production projectId) planId brokerGeneration ->
      IO result) ->
    IO result
withRecoveryRootFixtureFor planSteps use =
    Fixture.withFixtureProjectPlanRoot planSteps $ \store project root plan -> do
        opened <-
            withPersistedPlanSnapshot
                (productionRootAuthority root)
                (productionRootUnboundLease root)
                plan
                (\verified bound _binding _lease _recovery -> do
                    records <- resourceRecords plan
                    mapM_ (uncurry (writeRecord store)) records
                    deferred <- withSetSession store $ \session ->
                        withVerifiedResourceRecordSet session verified bound $ \set ->
                            case withRehydratedResourceSet session (projectModeLeaseEpoch (productionRootModeLease root)) set (use store project root verified) of
                                Left failure -> error (show failure)
                                Right action -> pure action
                    case deferred of
                        Left failure -> error (show failure)
                        Right action -> action)
        either (error . show) id opened

withResource ::
    ( forall projectId planId resourceId frame.
      LifecyclePlan (Production projectId) planId ->
      PlannedResource (Production projectId) planId resourceId ClusterResource frame ->
      IO result
    ) ->
    IO result
withResource use =
    Fixture.withFixtureProjectPlan resourcePlan $ \projectPlan ->
        case NonEmpty.toList (forward projectPlan) of
            [node] ->
                either (assertFailure . show) id $
                    withPlannedResourceOfKind
                        projectPlan
                        ClusterResourceKind
                        (plannedStepOperationKey node)
                        (use (lifecyclePlanFromProjectPlan projectPlan))
            _ -> assertFailure "resource fixture is not a singleton plan"

resourcePlan :: StepPlan
resourcePlan =
    either (error . show) id $
        mkStepPlan [deployKindStep "cluster" (StepFrame "host" "Host") (const (pure StepChanged))]

twoResourcePlan :: StepPlan
twoResourcePlan =
    either (error . show) id $
        mkStepPlan
            [ deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged))
            , deployKindStep "cluster" (StepFrame "host" "Host") (const (pure StepChanged))
            ]

replaceFrame :: Int -> ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString
replaceFrame index replacement raw =
    ByteString.concat . map frameWire $
        take index fields <> [replacement] <> drop (index + 1) fields
  where
    fields = either (error . Text.unpack) id (allFrames raw)

allFrames :: ByteString.ByteString -> Either Text [ByteString.ByteString]
allFrames raw
    | ByteString.null raw = Right []
    | otherwise = do
        (field, trailing) <- takeFrame raw
        (field :) <$> allFrames trailing

takeFrame :: ByteString.ByteString -> Either Text (ByteString.ByteString, ByteString.ByteString)
takeFrame raw
    | ByteString.length raw < 8 = Left "truncated"
    | size > fromIntegral (ByteString.length body) = Left "truncated"
    | otherwise = Right (ByteString.splitAt (fromIntegral size) body)
  where
    (prefix, body) = ByteString.splitAt 8 raw
    size = ByteString.foldl' (\value byte -> shiftL value 8 .|. fromIntegral byte) 0 prefix :: Word64

frameWire :: ByteString.ByteString -> ByteString.ByteString
frameWire bytes = ByteString.pack (word64BigEndian (fromIntegral (ByteString.length bytes))) <> bytes

word64BigEndian :: Word64 -> [Word8]
word64BigEndian value = [fromIntegral (shiftR value shift) | shift <- [56, 48 .. 0]]
