{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Real-process coverage for the provider ownership backend.

The lifecycle cases drive the production prepared calls against a real provider
client process and the production protected store, on a real temporary
filesystem.  The client answers only the raw CLI shapes a provider would; it
knows nothing about reconciliation outcomes, and it is this suite's own
executable rather than a wrapper, for the reason "FakeProvider" gives.
-}
module ProviderBackendSpec (tests, backendGuest, providerOriginRefusalCaseWith, aliasPlanRefusalCaseWith, nodeAliasRefusalCaseWith, nodeAliasRefusalExpected) where

import qualified HostBootstrap.Readiness.Kernel as ProbeKernel
import qualified TestDependency
import Control.Exception (SomeException, displayException, try)
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_, void, when)
import ConditionalCase (conditionalCase)
import qualified Data.Aeson as Aeson
import Data.Aeson ((.=))
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyBytes
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sort)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import Expect (expectRight)
import qualified FakeProvider
import qualified Fixture
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.Effect.Vocabulary (EffectTarget (ToolTarget), HostCommand (commandArguments, commandTarget), hostCommand)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool
import qualified HostBootstrap.Incus as Incus
import qualified HostBootstrap.Chain as Chain
import qualified HostBootstrap.Lifecycle.Execution as Execution
import qualified HostBootstrap.Lifecycle.Execution.Core as ExecutionCore (ResourceCarrierCore, newResourceCarrierCore, newStepRuntimeCore, resourceCarrierCoreRefs)
import HostBootstrap.Lifecycle.Prepared (PreparedGate, preparedGateFence, preparedGateJournalVersion)
import qualified HostBootstrap.Lima as Lima
import HostBootstrap.Lift (InVMSelfPath (InVMSelfPath), currentSelfRef)
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import qualified HostBootstrap.Ownership.Object as Ownership
import HostBootstrap.Ownership.Primitive (rowObserveIdentity, withOwnershipRow)
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import qualified HostBootstrap.Ownership.Shipped as Shipped
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    ProtectedError (ProtectedInvalid),
    ProtectedRecord (protectedRecordBytes),
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    openProtectedStore,
    readProtectedRecord,
    recordKeyText,
    recordTupleSeparator,
    recordVersionWord,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile
import HostBootstrap.Step
import HostBootstrap.Substrate (Arch (Amd64, Arm64), Substrate (..), SubstrateName (AppleSilicon, LinuxCpu, LinuxGpu, WindowsCpu, WindowsGpu))
import HostBootstrap.Readiness (ProbeFailure (ProbeFailure))
import HostBootstrap.Substrate.Provider (ProviderError (..), ProviderOperation (ProviderGuestRoute), ProviderObservation (..), ProviderDiscovery (..), GuestProviderDiscovery (..), DirectProviderDiscovery (..), discoverProvider, providerCapabilityKind, providerCapabilityGeneration, providerCapabilityLiftContext, providerLiftContext, providerCapabilityDiscovery, HostPathShare (..), ProviderKind (..), SubstrateProvider, VMHandles (..), selectProviderKind)
import qualified HostBootstrap.Substrate.Provider as Provider
import qualified HostBootstrap.Substrate.Provider.Report as ProviderReport
import qualified HostBootstrap.Substrate.Provider.Resume as Resume
import qualified HostBootstrap.Readiness as Readiness
import qualified HostBootstrap.Substrate.Provider.Alias as Alias
import HostBootstrap.Substrate.Provider.Backend
import HostBootstrap.Substrate.Provider.Command (ProviderSizing (ProviderSizing))
import qualified HostBootstrap.Substrate.Provider.Command as ProviderCommand
import qualified HostBootstrap.Substrate.Provider.GuestVm as GuestVm
#if defined(mingw32_HOST_OS)
import qualified HostBootstrap.Substrate.Provider.WslDisk as WslDisk
#endif
import qualified HostBootstrap.Substrate.Provider.Ownership as Owned
import HostBootstrap.Substrate.Provider.Reconcile
import qualified HostBootstrap.Wsl2 as Wsl2
import PlatformPath (hostFixturePath)
import PrepareFixture (assertPackageGateCommitment, gateFor)
import qualified SourceGuard
import System.Directory
import System.Environment (getExecutablePath, lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeFileName, (</>))
import System.IO (readFile')
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Unsafe.Coerce (unsafeCoerce)


-- The scoped owner-unit producer changes only the private origin coordinates.
-- This case obtains its real handle/receipt through the ordinary public route.
providerOriginRefusalCaseWith ::
    (forall backendId. ProviderBackendBinding backendId -> (Text.Text, Text.Text)) ->
    ConflictDetail ->
    ( forall scope planId backendId providerId.
      (Text.Text, Text.Text) ->
      ManagedProviderHandle scope planId backendId providerId Running ->
      ManagedProviderHandle scope planId backendId providerId Running
    ) ->
    IO ()
providerOriginRefusalCaseWith bindingCoordinates expectedConflict changeOrigin =
    withDirectTools "{}" 0 $ \config root recorded -> do
        spec <- expectRight (mkDirectHostBackendSpec config root "alpine:3.22")
        admitted <-
            discoverStrongProviderBackend config spec $ \backend ->
                withRunningProvider (ProviderUnderTest backend) $ \_ _ _ running -> do
                    managedProviderKey running @?= "core:deploy-vm"
                    managedProviderGeneration running @?= 17
                    readRecorded recorded >>= (@?= ["docker manifest inspect alpine:3.22"])
                    otherDocker <- Fixture.newRecordingFakeTool root "other-docker" "{}" 0 recorded
                    let otherConfig = config{hcToolPaths = Map.fromList [(Docker, fixtureExe otherDocker)]}
                    otherSpec <- expectRight (mkDirectHostBackendSpec otherConfig root "alpine:3.22")
                    another <-
                        discoverStrongProviderBackend otherConfig otherSpec $ \otherBackend -> do
                            let (retainedSemantic, retainedRealization) = bindingCoordinates (providerBackendBinding backend)
                                coordinates@(alternateSemantic, alternateRealization) = bindingCoordinates (providerBackendBinding otherBackend)
                            alternateSemantic @?= retainedSemantic
                            assertBool
                                "the alternate client changes the actual realization"
                                (alternateRealization /= retainedRealization)
                            writeFile recorded ""
                            callbacks <- newIORef (0 :: Int)
                            outcome <-
                                case withProviderBoundExec backend (changeOrigin coordinates running) (\_ -> modifyIORef' callbacks (+ 1)) of
                                    Left refusal -> pure (Left refusal)
                                    Right action -> action >> pure (Right ())
                            outcome @?= Left (Conflict expectedConflict)
                            readIORef callbacks >>= (@?= 0)
                            readRecorded recorded >>= (@?= [])
                    expectRight another
        expectRight admitted

tests :: TestTree
tests =
    testGroup
        "ProviderBackendSpec"
        ([wslFractionalDiskCase] <> limaSizingCases <> incusSizingCases <> guestVmTransactionCases <> guestVmReportCases <> retainedOperationCases <> providerSourceCases <> provisionAndReadinessCases <> portableCases <> backendAdmissionCases <> retainedClientCases <> lifecycleCases <> discoveryCases <> providerRecordCases <> aliasPreparationCases <> aliasBackendAdmissionCases <> [testGroup "prepared guest alias acquisition" aliasAcquisitionCases, testGroup "prepared guest alias release" aliasReleaseCases, testGroup "node guest alias route" nodeAliasCases])

{- | Keep the provider's decisions in the binary and its effects in argv.

The rationale entry "A script is a fork of the binary, and it is the fork nothing
can check" explains why an interpreter program cannot cross this boundary.
Both physical provider modules are checked, including the positive path from
the backend through the ownership driver to Provider.Command and the one
'interpretHostCommand'. Comments and longer diagnostic strings are not tool
names; Haskell string escapes still denote the same forbidden argument.
-}
providerSourceCases :: [TestTree]
providerSourceCases =
    [ testGroup "provider command boundary"
        [ testCase "both provider modules name no interpreter or locking front end" $
            withProviderSources $ \_ source ->
                forbiddenProviderTokens source @?= []
        , testCase "both provider modules reach described commands through the one interpreter" $
            withProviderSources $ \name source -> do
                assertBool (name <> " does not import Provider.Command")
                    (SourceGuard.importsModule "HostBootstrap.Substrate.Provider.Command" source)
                assertBool (name <> " does not reach the command interpreter")
                    (SourceGuard.countHaskellIdentifier "interpretHostCommand" source >= 2)
                let reached = if name == "Backend.hs" then "provisionOwnedInstance" else "launchInstanceCommand"
                assertBool (name <> " does not reach " <> reached)
                    (SourceGuard.countHaskellIdentifier reached source >= 2)
        , testCase "the guard recognizes arguments, constructors and escaped literals" $ do
            forM_ forbiddenProviderNames $ \name ->
                forbiddenProviderTokens ("value = " <> show name) @?= [name]
            forM_ ["Python3", "Flock", "Lockf"] $ \name ->
                forbiddenProviderTokens ("value = " <> name) @?= [name]
            forbiddenProviderTokens "value = \"b\\97sh\"" @?= ["bash"]
            forbiddenProviderTokens "-- bash Python3\n{- Flock -}\nvalue = \"a bash diagnostic\"" @?= []
        ]
    ]

withProviderSources :: (FilePath -> String -> IO ()) -> IO ()
withProviderSources check = do
    cwd <- getCurrentDirectory
    root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " <> cwd)) pure
    let providerRoot = root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "Substrate" </> "Provider"
    forM_ ["Backend.hs", "Ownership.hs"] $ \name ->
        readFile' (providerRoot </> name) >>= check name

forbiddenProviderNames :: [String]
forbiddenProviderNames = ["bash", "sh", "-c", "-lc", "Python3", "Flock", "Lockf"]

forbiddenProviderTokens :: String -> [String]
forbiddenProviderTokens = filter (`elem` forbiddenProviderNames) . map literalValue . SourceGuard.haskellTokens
  where
    literalValue token = case reads token :: [(String, String)] of
        [(value, "")] -> value
        _ -> token

limaSizingCases :: [TestTree]
limaSizingCases =
    [ nativeGuestCase ("owned Lima changed declaration refuses " <> label) $ \cfg owned root -> do
        _ <- createGuestVm cfg owned
        before <- guestVmStoredRecord owned
        declared <- expectRight (ProviderReport.providerSizingBudget sizing)
        actual <- expectRight (ProviderReport.providerSizingBudget (GuestVm.ownedGuestVmSizing owned))
        let changed = owned{GuestVm.ownedGuestVmSizing = sizing}
        GuestVm.provisionOwnedGuestVm cfg changed
            >>= (@?= Left (Owned.ProviderOwnershipSizing declared (ProviderReport.NativeProviderSizing actual)))
        guestVmStoredRecord owned >>= (@?= before)
        FakeProvider.recordedProviderMutations root >>= (@?= ["lima-create"])
    | (label, sizing) <- [("CPU", ProviderSizing 3 "4GiB" "40GiB"),
        ("memory", ProviderSizing 2 "8GiB" "40GiB"), ("disk", ProviderSizing 2 "4GiB" "80GiB")]
    ] <>
    [ nativeGuestBackendCase ("owned Lima native " <> label <> " drift is an exact sizing conflict") $ \host backend ->
        withProvisionedProvider backend $ \_ _ prepared _ -> do
            let owned = backendGuestVmDescription host prepared
            before <- guestVmStoredRecord owned
            FakeProvider.setLimaConfigValue (hostRoot host) vmName field value
            call <- provisionCall backend prepared
            case settleProviderProvision Nothing prepared call of
                Left (Conflict detail) -> detail @?= ConflictDetail "core:deploy-vm"
                    "cpu=2, memory=4294967296 bytes, storage=42949672960 bytes" observed
                    "destroy and reprovision the owned provider with the declared sizing"
                other -> assertFailure ("expected exact Lima sizing conflict, got " <> showEither (() <$ other))
            guestVmStoredRecord owned >>= (@?= before)
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["lima-create"])
    | (label, field, value, observed) <-
        [ ("CPU", "cpus", Aeson.toJSON (3 :: Int), "cpu=3, memory=4294967296 bytes, storage=42949672960 bytes")
        , ("memory", "memory", Aeson.toJSON ("8GiB" :: String), "cpu=2, memory=8589934592 bytes, storage=42949672960 bytes")
        , ("disk", "disk", Aeson.toJSON ("80GiB" :: String), "cpu=2, memory=4294967296 bytes, storage=85899345920 bytes")
        ]
    ] <>
    [ nativeGuestBackendCase "owned Lima missing sizing refuses before AlreadyOwned" $ \host backend ->
        withProvisionedProvider backend $ \_ _ prepared _ -> do
            let owned = backendGuestVmDescription host prepared
                report = Aeson.object
                    [ "name" .= vmName, "status" .= ("Stopped" :: String)
                    , "dir" .= FakeProvider.limaInstanceDirectory (hostRoot host) vmName
                    , "config" .= Aeson.object ["env" .= Aeson.object
                        ["HOSTBOOTSTRAP_OWNER" .= Ownership.ownerClaimText (GuestVm.ownedGuestVmClaim owned)]]
                    ]
                wire = Text.unpack (TextEncoding.decodeUtf8 (LazyBytes.toStrict (Aeson.encode report)))
            before <- guestVmStoredRecord owned
            queueLimaReport host (limaNativeList vmName) 0 wire ""
            call <- provisionCall backend prepared
            assertGuestVmFailure "provision provider"
                (ProviderReport.ProviderReportUnreadable "the Lima instance omits native sizing")
                (settleProviderProvision Nothing prepared call)
            assertLimaReportConsumed host
            guestVmStoredRecord owned >>= (@?= before)
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["lima-create"])
    , nativeGuestCase "owned Lima sizing readback retains the fresh claim barrier" $ \cfg owned root -> do
        _ <- createGuestVm cfg owned
        before <- guestVmStoredRecord owned
        writeFile (FakeProvider.changeLimaClaimPath root) "once\n"
        GuestVm.provisionOwnedGuestVm cfg owned >>= (@?= Left
            (Owned.ProviderOwnershipStanding (Resume.InstanceUnderAnotherClaim
                (Ownership.ownerClaimText (GuestVm.ownedGuestVmClaim owned)) "foreign-owner")))
        guestVmStoredRecord owned >>= (@?= before)
        FakeProvider.recordedProviderMutations root >>= (@?= ["lima-create"])
    ]

-- | Raw client limits exercise the entered owner and the prepared result mapping.
incusSizingCases :: [TestTree]
incusSizingCases =
    [ testCase "owned Incus sizing equals the declaration without mutation" $
        withFakeHost $ \host -> withBackend host $ \backend ->
            withProvisionedProvider backend $ \_ _ prepared _ -> do
                records <- snapshotProviderRecords host
                instances <- FakeProvider.readInstances (hostRoot host)
                mutations <- FakeProvider.recordedProviderMutations (hostRoot host)
                config <- resolvedHostConfig
                store <- openProtectedStore (statePath host) >>= expectRight
                let owned = (providerRecordInstance vmName)
                        {Owned.ownedInstanceOwner = preparedProviderBindingOwner (preparedProviderProvisionBinding prepared)}
                key <- expectRight (Owned.ownedInstanceRecordKey owned)
                identity <- providerRecordBinding host key
                retained <- withProviderOwnershipEntry store $ \session ->
                    Owned.provisionOwnedInstance config session key owned
                retained @?= Owned.ProvisionAlreadyOwned identity
                call <- provisionCall backend prepared
                settled <- expectRight (settleProviderProvision Nothing prepared call)
                withProviderProvisionSettlement settled
                    (\managed _ -> managedProviderGeneration managed @?= 17)
                    (\_ _ _ _ -> assertFailure "equal sizing became foreign")
                snapshotProviderRecords host >>= (@?= records)
                FakeProvider.readInstances (hostRoot host) >>= (@?= instances)
                FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= mutations)
    , testCase "owned Incus equivalent limit units do not relaunch or publish" $
        withFakeHost $ \host -> withBackend host $ \backend ->
            withProvisionedProvider backend $ \_ _ prepared _ -> do
                setIncusLimit host "limits.memory" "2048MiB"
                setIncusLimit host "root.size" "12884901888"
                records <- snapshotProviderRecords host
                instances <- FakeProvider.readInstances (hostRoot host)
                call <- provisionCall backend prepared
                settled <- expectRight (settleProviderProvision Nothing prepared call)
                withProviderProvisionSettlement settled
                    (\_ _ -> pure ())
                    (\_ _ _ _ -> assertFailure "equivalent units became foreign")
                snapshotProviderRecords host >>= (@?= records)
                FakeProvider.readInstances (hostRoot host) >>= (@?= instances)
                FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch"])
    , testCase "replacement during Incus sizing readback cannot become managed" $
        withFakeHost $ \host -> withBackend host $ \backend ->
            withProvisionedProvider backend $ \_ _ prepared _ -> do
                records <- snapshotProviderRecords host
                FakeProvider.armReplacementAfter (hostRoot host) "sizing-read"
                call <- provisionCall backend prepared
                settled <- expectRight (settleProviderProvision Nothing prepared call)
                replacementWasForeign <- newIORef False
                withProviderProvisionSettlement settled
                    (\_ _ -> assertFailure "the replacement obtained managed ownership")
                    (\_ _ _ _ -> writeIORef replacementWasForeign True)
                readIORef replacementWasForeign >>= (@?= True)
                heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity)
                snapshotProviderRecords host >>= (@?= records)
                FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch"])
    , testCase "non-positive Incus declarations refuse before any provider command" $
        withFakeHost $ \host -> do
            config <- resolvedHostConfig
            records <- openProtectedStore (statePath host) >>= expectRight
            let original = providerRecordInstance vmName
            key <- expectRight (Owned.ownedInstanceRecordKey original)
            forM_ [ProviderSizing 0 "2GiB" "12GiB", ProviderSizing 2 "0" "12GiB", ProviderSizing 2 "2GiB" "0"] $ \sizing -> do
                fault <- case ProviderReport.incusSizingBudget sizing of
                    Left reason -> pure reason
                    Right _ -> assertFailure "the invalid declaration unexpectedly became a budget"
                outcome <- withProviderOwnershipEntry records $ \session ->
                    Right <$> Owned.provisionOwnedInstance config session key original{Owned.ownedInstanceSizing = sizing}
                outcome @?= Left (Owned.ProviderOwnershipReport fault)
            FakeProvider.recordedProviderCommands (hostRoot host) >>= (@?= [])
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
            FakeProvider.readInstances (hostRoot host) >>= (@?= [])
            durableRecords host >>= (@?= [])
    , testCase "a changed ordinary Incus declaration refuses the same owned binding" $
        withFakeHost $ \host -> do
            config <- resolvedHostConfig
            records <- openProtectedStore (statePath host) >>= expectRight
            let original = providerRecordInstance vmName
                changed = original{Owned.ownedInstanceSizing = ProviderSizing 3 "2GiB" "12GiB"}
            key <- provisionRecordInstance config records original
            before <- snapshotProviderRecords host
            expected <- expectRight (ProviderReport.providerSizingBudget (Owned.ownedInstanceSizing changed))
            actual <- expectRight (ProviderReport.providerSizingBudget (Owned.ownedInstanceSizing original))
            outcome <- withProviderOwnershipEntry records $ \session ->
                Right <$> Owned.provisionOwnedInstance config session key changed
            outcome @?= Left (Owned.ProviderOwnershipSizing expected (ProviderReport.NativeProviderSizing actual))
            snapshotProviderRecords host >>= (@?= before)
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch"])
    ] <>
    [ testCase ("owned Incus changed " <> label <> " is an exact sizing conflict") $
        withFakeHost $ \host -> withBackend host $ \backend ->
            withProvisionedProvider backend $ \_ _ prepared _ -> do
                setIncusLimit host key value
                records <- snapshotProviderRecords host
                instances <- FakeProvider.readInstances (hostRoot host)
                call <- provisionCall backend prepared
                case settleProviderProvision Nothing prepared call of
                    Left (Conflict detail) -> detail @?= ConflictDetail "core:deploy-vm"
                        "cpu=2, memory=2147483648 bytes, storage=12884901888 bytes" observed
                        "destroy and reprovision the owned provider with the declared sizing"
                    other -> assertFailure ("expected a sizing conflict, got " <> showEither (() <$ other))
                snapshotProviderRecords host >>= (@?= records)
                FakeProvider.readInstances (hostRoot host) >>= (@?= instances)
                FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch"])
    | (label, key, value, observed) <-
        [ ("CPU", "limits.cpu", "3", "cpu=3, memory=2147483648 bytes, storage=12884901888 bytes")
        , ("memory", "limits.memory", "3GiB", "cpu=2, memory=3221225472 bytes, storage=12884901888 bytes")
        , ("storage", "root.size", "13GiB", "cpu=2, memory=2147483648 bytes, storage=13958643712 bytes")
        ]
    ] <>
    [ testCase ("owned Incus " <> label <> " report refuses without mutation") $
        withFakeHost $ \host -> withBackend host $ \backend ->
            withProvisionedProvider backend $ \_ _ prepared _ -> do
                setIncusLimit host key value
                records <- snapshotProviderRecords host
                instances <- FakeProvider.readInstances (hostRoot host)
                call <- provisionCall backend prepared
                case settleProviderProvision Nothing prepared call of
                    Left (Failure detail) ->
                        failureCause detail @?= ProviderReport.providerReportFaultMessage fault
                    other -> assertFailure ("expected a malformed sizing refusal, got " <> showEither (() <$ other))
                snapshotProviderRecords host >>= (@?= records)
                FakeProvider.readInstances (hostRoot host) >>= (@?= instances)
                FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch"])
    | (label, key, value, fault) <-
        [ ("CPU pin-set", "limits.cpu", "0-1",
            ProviderReport.ProviderReportUnreadable "the native CPU limit is not a positive representable CPU count")
        , ("missing storage", "root.size", "",
            ProviderReport.ProviderReportUnreadable "native sizing omits the root-device size")
        ]
    ]

setIncusLimit :: FakeHost -> String -> String -> IO ()
setIncusLimit host key value =
    FakeProvider.alterInstance (hostRoot host) vmName $ \held ->
        held{FakeProvider.instanceConfig = (key, value) : filter ((/= key) . fst) (FakeProvider.instanceConfig held)}

-- The provision/readiness decisions and the CLI stand-in's declared limits.
provisionAndReadinessCases :: [TestTree]
provisionAndReadinessCases =
    [ testCase "an owned instance bound under another run's claim is refused" $
        withFakeHost $ \host -> do
            cfg <- resolvedHostConfig
            store <- openProtectedStore (statePath host) >>= expectRight
            let original = providerRecordInstance vmName
                another = original{Owned.ownedInstanceOwner = "another-run"}
            key <- provisionRecordInstance cfg store original
            records <- snapshotProviderRecords host
            instances <- FakeProvider.readInstances (hostRoot host)
            attempted <-
                withProtectedEntry store $ \session ->
                    Right <$> Owned.provisionOwnedInstance cfg session key another
            expectRight attempted
                >>= (@?= Left
                    ( Owned.ProviderOwnershipStanding
                        ( Resume.InstanceUnderAnotherClaim
                            (Ownership.ownerClaimText (Owned.ownedInstanceClaim another))
                            (Ownership.ownerClaimText (Owned.ownedInstanceClaim original))
                        )
                    ))
            snapshotProviderRecords host >>= (@?= records)
            FakeProvider.readInstances (hostRoot host) >>= (@?= instances)
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch"])
    , testCase "Ready stops after one failed guest probe" $
        withFakeHost $ \host ->
            withBackend host $ \backend ->
                withProvisionedProvider backend $ \execution planned _ provisioned -> do
                    writeFile (guestProbeScriptPath (hostRoot host)) (show ([(7, "", "permission denied\n")] :: [(Int, String, String)]))
                    writeFile (FakeProvider.guestInvocationsPath (hostRoot host)) ""
                    records <- snapshotProviderRecords host
                    result <- readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned)
                    case result of
                        Left (Failure detail) ->
                            failureCause detail @?= "the provider command exited 7: permission denied"
                        other -> assertFailure ("expected terminal Ready failure, got " <> showEither (() <$ other))
                    recordedGuestInvocations (hostRoot host) >>= (@?= [["true"]])
                    snapshotProviderRecords host >>= (@?= records)
    , testCase "guest conflicts retain both identities through the marker grammar" $ do
        expected <- expectRight (Ownership.mkObjectIdentity "bound-instance")
        observed <- expectRight (Ownership.mkObjectIdentity "observed-instance")
        let expectedToken = "identity=" <> Text.unpack (Ownership.objectIdentityText expected)
            observedToken = "identity=" <> Text.unpack (Ownership.objectIdentityText observed)
            clause =
                Ownership.OwnershipConflict
                    (Ownership.ConflictReport
                        "the provider instance a guest command ran in"
                        (Ownership.OriginPresent expected)
                        (Ownership.OriginPresent observed))
        forM_
            [ (Owned.ProviderOwnershipStanding (Resume.InstanceReplaced expected observed), "provider-replaced")
            , (Owned.ProviderOwnershipClause clause, "provider-conflict")
            ] $ \(fault, reason) -> do
                let marker = unwords ["HB_PROVIDER_CONFLICT", expectedToken, observedToken, reason]
                    conflictReport =
                        Readiness.ProbeConflict expectedToken observedToken
                            ("resolve the provider identity conflict before retrying (" <> reason <> ")")
                    outcome = guestOutcome (Left fault)
                outcome @?= RawProviderFailure marker
                Provider.providerConflictMarker marker @?= Just conflictReport
                Provider.classifyProviderProbe outcome @?= Readiness.ProbeConflicted conflictReport
    , testCase "the marker emitter and reader refuse non-ASCII tokens" $ do
        let nonAscii = "instance-\xE9"
            raw = "HB_PROVIDER_CONFLICT record " <> nonAscii <> " provider-conflict"
        Provider.validConflictToken nonAscii @?= False
        Provider.providerConflictMarker raw @?= Nothing
        guestOutcome
            (Left (Owned.ProviderOwnershipStanding (Resume.InstanceUnderAnotherClaim "record" (Text.pack nonAscii))))
            @?= RawProviderFailure "HB_PROVIDER_CONFLICT bounded-token invalid-token invalid-conflict-marker"
    , testCase "an unavailable daemon refuses discovery and provision without mutation" $
        withFakeHostBehaviour FakeProvider.ProviderDaemonUnavailable $ \host -> do
            cfg <- resolvedHostConfig
            listing <- fixtureProviderCommand cfg ["list", vmName, "--format", "csv", "-c", "ns"]
            ProviderReport.classifyProviderListing vmName (Right listing)
                @?= Left (ProviderReport.ProviderCommandExited 1 "provider transport failed")
            forM_
                [ ["--quiet", "launch", imageName, vmName]
                , ["start", vmName]
                , ["stop", vmName, "--force"]
                , ["exec", vmName, "--", "true"]
                , ["config", "get", vmName, "volatile.uuid"]
                , ["config", "device", "list", vmName]
                , ["image", "info", imageName]
                ] $ \argv ->
                    fixtureProviderCommand cfg argv
                        >>= (@?= CapturedRun (ExitFailure 1) "" "provider transport failed\n")
            store <- openProtectedStore (statePath host) >>= expectRight
            let owned = providerRecordInstance vmName
            key <- expectRight (Owned.ownedInstanceRecordKey owned)
            attempted <-
                withProtectedEntry store $ \session ->
                    Right <$> Owned.provisionOwnedInstance cfg session key owned
            expectRight attempted
                >>= (@?= Left (Owned.ProviderOwnershipReport
                    (ProviderReport.ProviderCommandExited 1 "provider transport failed")))
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
            FakeProvider.readInstances (hostRoot host) >>= (@?= [])
            durableRecords host >>= (@?= [])
    , testCase "unavailable provisioning egress is classified as unavailable" $
        withFakeHostBehaviour FakeProvider.ProviderEgressUnavailable $ \host -> do
            cfg <- resolvedHostConfig
            run <- fixtureProviderCommand cfg ["image", "info", imageName]
            Provider.classifyProviderProbe
                (RawProviderExit (capturedExit run) (capturedStdout run) (capturedStderr run))
                @?= Readiness.Unavailable "not found"
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
    , testCase "the CLI stand-in refuses absent and wrong-state operations" $
        withFakeHost $ \host -> do
            cfg <- resolvedHostConfig
            forM_
                [ ["start", vmName]
                , ["stop", vmName, "--force"]
                , ["restart", vmName, "--force"]
                , ["delete", vmName, "--force"]
                , ["exec", vmName, "--", "true"]
                , ["config", "device", "list", vmName]
                , ["config", "device", "get", vmName, "disk", "source"]
                , ["config", "device", "add", vmName, "disk", "disk", "source=/srv", "path=/srv"]
                ] $ \argv ->
                    fixtureProviderCommand cfg argv
                        >>= (@?= CapturedRun (ExitFailure 1) "" "Instance not found\n")
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
            fixtureProviderCommand cfg ["--quiet", "launch", imageName, vmName]
                >>= (@?= CapturedRun ExitSuccess "" "")
            fixtureProviderCommand cfg ["--quiet", "launch", imageName, vmName]
                >>= (@?= CapturedRun (ExitFailure 1) "" "Instance already exists\n")
            fixtureProviderCommand cfg ["start", vmName]
                >>= (@?= CapturedRun (ExitFailure 1) "" "Instance is already running\n")
            fixtureProviderCommand cfg ["stop", vmName, "--force"]
                >>= (@?= CapturedRun ExitSuccess "" "")
            fixtureProviderCommand cfg ["stop", vmName, "--force"]
                >>= (@?= CapturedRun (ExitFailure 1) "" "Instance is already stopped\n")
            fixtureProviderCommand cfg ["exec", vmName, "--", "true"]
                >>= (@?= CapturedRun (ExitFailure 1) "" "Instance is not running\n")
            recordedGuestInvocations (hostRoot host) >>= (@?= [])
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch", "stop"])
    , testCase "the CLI stand-in gives a relaunched name a fresh identity" $
        withFakeHost $ \host -> do
            cfg <- resolvedHostConfig
            fixtureProviderCommand cfg ["--quiet", "launch", imageName, vmName]
                >>= (@?= CapturedRun ExitSuccess "" "")
            heldIdentity host vmName >>= (@?= Just ("instance-" <> vmName <> "-1"))
            fixtureProviderCommand cfg ["delete", vmName, "--force"]
                >>= (@?= CapturedRun ExitSuccess "" "")
            fixtureProviderCommand cfg ["--quiet", "launch", imageName, vmName]
                >>= (@?= CapturedRun ExitSuccess "" "")
            heldIdentity host vmName >>= (@?= Just ("instance-" <> vmName <> "-2"))
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch", "delete", "launch"])
    , testCase "nested provider fixtures restore the previous environment value" $ do
        previous <- lookupEnv FakeProvider.fakeProviderVariable
        FakeProvider.withFakeProviderClient "outer" $ do
            lookupEnv FakeProvider.fakeProviderVariable >>= (@?= Just "outer")
            FakeProvider.withFakeProviderClient "inner" $
                lookupEnv FakeProvider.fakeProviderVariable >>= (@?= Just "inner")
            lookupEnv FakeProvider.fakeProviderVariable >>= (@?= Just "outer")
        lookupEnv FakeProvider.fakeProviderVariable >>= (@?= previous)
    ]

-- | Exercise the stand-in protocol through the production command interpreter.
fixtureProviderCommand :: HostConfig -> [String] -> IO CapturedRun
fixtureProviderCommand cfg argv =
    interpretHostCommand cfg (hostCommand Incus argv) >>= expectRight

{- | The lifecycle a provider transaction really performs, against a real client.

Every case below drives the production calls through the one interpreter, and
what answers is a real provider client process (see "FakeProvider").  Nothing
here is host-specific: the client is this suite's own executable and its durable
state is ordinary files, so the family runs — and is counted — on every gate host
(§ JJ).
-}
lifecycleCases :: [TestTree]
lifecycleCases =
    [ testCase "provision, fresh boot, share, stop, and conditional delete hold one identity" fullLifecycleCase
    , testCase "retained reverse stops, conditionally deletes, and retires the provider record" retainedReverseCase
    , testCase "concurrent provision enters once and launches once" concurrentProvisionCase
    , testCase "a client that dies after its launch is recovered without relaunching" crashRecoveryCase
    , testCase "readiness retries only a guest that is not answering yet" readinessRetryCase
    , testCase "prepared readiness polls a native Incus agent startup reply" nativeAgentPreparedReadyCase
    , testCase "retained readiness polls a native Incus agent startup reply" nativeAgentRetainedReadyCase
    , testCase "a replacement between transactions is reported and left untouched" replacementCase
    , testCase "an exact share is idempotent and a changed device is a conflict" shareReadbackCase
    , testCase "share preparation refuses the real Incus dependency reprobe failure" incusShareReprobeFailureCase
    , testCase "running dependency refuses the actual same-name Incus replacement" incusDependencyReplacementCase
    , testCase "running dependency refuses an actual Direct root replacement" directDependencyReplacementCase
    , testCase "share preparation refuses the real Direct dependency reprobe failure" directShareReprobeFailureCase
    , testCase "an exact restarted VM is retryable rather than a replacement" exactRestartBeforeDeleteCase
    , testCase "Ready rechecks identity across the guest observation" readyObservationReplacementCase
    , testCase "Stop rechecks identity after the stop it issued" stopObservationReplacementCase
    , testCase "a share rechecks its instance after the device readback" shareObservationReplacementCase
    , testCase "a share rechecks its instance after the activating restart" shareRestartReplacementCase
    , testCase "a same-named replacement is left standing rather than forgotten" deleteReplacementLeftStandingCase
    , testCase "a forward delete resumes after its removal response is lost" (interruptedDeleteRecoveryCase False)
    , testCase "a retained delete resumes after its removal response is lost" (interruptedDeleteRecoveryCase True)
    , testCase "a forward delete releases an interrupted unbound launch" (interruptedLaunchReleaseCase False)
    , testCase "a retained delete releases an interrupted unbound launch" (interruptedLaunchReleaseCase True)
    , testCase "delete refuses an instance replaced after share bookkeeping" deleteAfterShareReplacementCase
    , testCase "delete refuses a repointed recorded share without forgetting records" deleteRepointedShareCase
    , testCase "delete releases an already absent recorded share" deleteAbsentShareCase
    , testCase "UTF-8 share bindings distinguish U+0151 from Q" unicodeShareBindingCase
    ]

-- Discovery is reached through the production managed handle and bound executor.
discoveryCases :: [TestTree]
discoveryCases =
    [ testCase "discovery keeps all three successful guest observations" $
        checkGuestDiscovery incusProvider [] Nothing
            (@?= Right (guestReport ready ready ready))
            [daemonProbe, guestProbe, egressProbe]
    , testCase "discovery retains a ready daemon when the guest is unavailable" $
        let unavailable = ProviderObservedUnavailable "not found"
         in checkGuestDiscovery incusProvider [(1, "", "not found\n")] Nothing
                (@?= Right (guestReport ready unavailable unavailable))
                [daemonProbe, guestProbe]
    , testCase "discovery stops after an unavailable provider listing" $
        let unavailable = ProviderObservedUnavailable "not found"
         in checkGuestDiscovery incusProvider [] (Just "not found")
                (@?= Right (guestReport unavailable unavailable unavailable))
                [daemonProbe]
    , testCase "discovery retries only a not-ready guest probe" $
        checkGuestDiscovery incusProvider [(1, "", "not ready\n"), (0, "", "")] Nothing
            (@?= Right (guestReport ready ready ready))
            [daemonProbe, guestProbe, guestProbe, egressProbe]
    , testCase "discovery never retries an unclassified guest failure" $
        let failed = ProviderObservedFailure (ProbeFailure "provider probe" "exit 7: permission denied")
         in checkGuestDiscovery incusProvider [(7, "", "permission denied\n")] Nothing
                (@?= Right (guestReport ready failed failed))
                [daemonProbe, guestProbe]
    , testCase "discovery refuses a different instance before any probe" $
        let other = selectProviderKind ProviderIncus
                providerHandles{vmhIncus = Incus.IncusVM (vmName <> "-different") imageName}
         in checkGuestDiscovery other [] Nothing
                (\case
                    Left ProviderOperationFailure{providerErrorOperation = ProviderGuestRoute} -> pure ()
                    result -> assertFailure ("expected bound-route refusal, got " <> show result))
                []
    ]
  where
    ready = ProviderObservedReady ()
    guestReport daemon vm egress = ProviderGuestDiscovery (GuestProviderDiscovery daemon vm egress)
    daemonProbe = ["list", "--format", "csv", "-c", "n"]
    guestProbe = ["exec", vmName, "--", "true"]
    egressProbe = ["image", "info", imageName]

checkGuestDiscovery ::
    SubstrateProvider ->
    [(Int, String, String)] ->
    Maybe String ->
    (Either ProviderError ProviderDiscovery -> IO ()) ->
    [[String]] ->
    IO ()
checkGuestDiscovery selected script listingFailure check expected =
    withFakeHost $ \host ->
        withBackend host $ \backend ->
            withRunningProvider backend $ \_ _ _ running -> do
                let root = hostRoot host
                writeFile (FakeProvider.providerCommandsPath root) ""
                writeFile (FakeProvider.guestInvocationsPath root) ""
                writeFile (guestProbeScriptPath root) (show script)
                forM_ listingFailure (writeFile (FakeProvider.listingFailurePath root))
                result <-
                    resolveEitherIO $
                        withProviderBoundExec (underTestBackend backend) running $ \exec ->
                            discoverProvider running selected exec $ \capability -> do
                                providerCapabilityKind capability @?= ProviderIncus
                                providerCapabilityGeneration capability @?= managedProviderGeneration running
                                providerCapabilityLiftContext capability @?= providerLiftContext selected
                                pure (providerCapabilityDiscovery capability)
                check result
                commands <- FakeProvider.recordedProviderCommands root
                if null expected
                    then commands @?= []
                    else filter isDiscoveryCommand commands @?= expected
                recordedGuestInvocations root
                    >>= (@?= [drop 3 argv | argv <- expected, take 1 argv == ["exec"]])
  where
    isDiscoveryCommand argv =
        argv == ["list", "--format", "csv", "-c", "n"]
            || take 1 argv == ["exec"]
            || take 2 argv == ["image", "info"]

portableCases :: [TestTree]
portableCases =
    [ testCase "Incus construction refuses the wrong substrate before discovery" $ do
        let config = emptyHostConfig{hcSubstrate = Substrate LinuxGpu Arm64}
        case mkIncusBackendSpec vmName imageName vmName config (hostFixturePath "/state") 2 "4GiB" "40GiB" of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected substrate refusal, got " <> showEither other)
    , testCase "Incus construction refuses an instance name whose share socket path cannot fit" $ do
        let config = fakeResolvedHostConfig
            overlong = vmName <> replicate 64 'x'
        case mkIncusBackendSpec overlong imageName vmName config (hostFixturePath "/state") 2 "4GiB" "40GiB" of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected socket-path bound refusal, got " <> showEither other)
    , testCase "Incus construction refuses unresolved ownership tools" $
        case mkIncusBackendSpec vmName imageName vmName emptyHostConfig (hostFixturePath "/state") 2 "4GiB" "40GiB" of
            Left (Unsupported _) -> pure ()
            other -> assertFailure ("expected unresolved-tool refusal, got " <> showEither other)
    , testCase "Lima construction admits only the closed Apple realization" $ do
        case mkLimaBackendSpec fakeResolvedHostConfig limaProvider limaEnvelope limaShare of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected Lima host-substrate refusal, got " <> showEither other)
        case mkLimaBackendSpec limaResolvedHostConfig incusProvider limaEnvelope limaShare of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected Lima provider-kind refusal, got " <> showEither other)
    , testCase "Lima construction refuses an unresolved Lima tool" $
        case mkLimaBackendSpec limaUnresolvedHostConfig limaProvider limaEnvelope limaShare of
            Left (Unsupported _) -> pure ()
            other -> assertFailure ("expected unresolved Lima-tool refusal, got " <> showEither other)
    , testCase "WSL2 construction admits only the closed Windows realization" $ do
        case mkWsl2BackendSpec fakeResolvedHostConfig wsl2Provider limaEnvelope limaShare of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected WSL2 host-substrate refusal, got " <> showEither other)
        case mkWsl2BackendSpec wsl2ResolvedHostConfig limaProvider limaEnvelope limaShare of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected WSL2 provider-kind refusal, got " <> showEither other)
        -- Both Windows rows realize the same provider. Keying on the accelerator
        -- row refused a windows-cpu host, and no case here noticed because every
        -- fixture was windows-gpu.
        void $
            either
                (assertFailure . ("windows-cpu must realize the WSL2 provider: " <>) . show)
                pure
                (mkWsl2BackendSpec wsl2CpuResolvedHostConfig wsl2Provider limaEnvelope limaShare)
    , testCase "guest-VM kinds retain distinct backend identity with the same executable" $ do
        let sharedGuestClient = fixtureExe fixtureLima
            wslConfig = wsl2ResolvedHostConfig{hcToolPaths = Map.singleton Wsl sharedGuestClient}
            limaConfig = limaResolvedHostConfig{hcToolPaths = Map.singleton Lima sharedGuestClient}
        Map.lookup Wsl (hcToolPaths wslConfig) @?= Map.lookup Lima (hcToolPaths limaConfig)
        wslSpec <- expectRight (mkWsl2BackendSpec wslConfig wsl2Provider limaEnvelope limaShare)
        limaSpec <- expectRight (mkLimaBackendSpec limaConfig limaProvider limaEnvelope limaShare)
        assertBool "the WSL2 realization shared Lima's backend identity with an identical executable" (wslSpec /= limaSpec)
    , testCase "the two guest-VM constructors are applications of one row" $ do
        backendSource <- readBackendSource
        -- Its signature, its definition, and one application per realization.
        SourceGuard.countHaskellIdentifier "mkGuestVmBackendSpec" backendSource @?= 4
        -- Each realization is a value the row is applied to, named at its
        -- signature, its definition, the constructor application and client lookup.
        SourceGuard.countHaskellIdentifier "limaRealization" backendSource @?= 4
        SourceGuard.countHaskellIdentifier "wsl2Realization" backendSource @?= 4
    , testCase "every backend constructor refuses through the one pair of helpers" $ do
        backendSource <- readBackendSource
        -- The refusal helper's signature/definition, three constructors and
        -- the two strong-admission refusals all use the same computation.
        SourceGuard.countHaskellIdentifier "invalidBackend" backendSource @?= 7
        SourceGuard.countHaskellIdentifier "requireBackendTool" backendSource @?= 5
    , testCase "WSL2 construction refuses an unresolved WSL tool" $
        case mkWsl2BackendSpec wsl2UnresolvedHostConfig wsl2Provider limaEnvelope limaShare of
            Left (Unsupported _) -> pure ()
            other -> assertFailure ("expected unresolved WSL-tool refusal, got " <> showEither other)
    , testCase "Lima fingerprints bind the exact budget and writable share" $ do
        baseline <- either (assertFailure . show) pure (mkLimaBackendSpec limaResolvedHostConfig limaProvider limaEnvelope limaShare)
        retry <- either (assertFailure . show) pure (mkLimaBackendSpec limaResolvedHostConfig limaProvider limaEnvelope limaShare)
        changedBudget <- either (assertFailure . show) pure (mkLimaBackendSpec limaResolvedHostConfig limaProvider limaEnvelope{cpu = 3} limaShare)
        changedShare <- either (assertFailure . show) pure (mkLimaBackendSpec limaResolvedHostConfig limaProvider limaEnvelope limaShare{hpsGuestPath = "/srv/other"})
        changedHost <- expectRight (mkLimaBackendSpec limaResolvedHostConfig limaProvider limaEnvelope limaShare{hpsHostPath = hostFixturePath "/other-share"})
        baseline @?= retry
        assertBool "a changed Lima host root retained the same backend identity" (baseline /= changedHost)
        assertBool "a changed Lima budget retained the same backend identity" (baseline /= changedBudget)
        assertBool "a changed Lima share retained the same backend identity" (baseline /= changedShare)
    , testCase "Direct backend discovery is structurally non-mutating" $
        withDirectTools "{}" 0 $ \config root recorded -> do
            spec <- either (assertFailure . show) pure (mkDirectHostBackendSpec config root imageName)
            discovered <- discoverStrongProviderBackend config spec (const (pure ()))
            discovered @?= Right ()
            readRecorded recorded >>= (@?= [])
    , testCase "Direct capability retains its managed generation and complete discovery" $
        withDirectTools "{}" 0 $ \config root recorded -> do
            spec <- either (assertFailure . show) pure (mkDirectHostBackendSpec config root imageName)
            result <-
                discoverStrongProviderBackend config spec $ \backend ->
                    withRunningProvider (ProviderUnderTest backend) $ \_ _ _ running ->
                        resolveEitherIO $
                            withProviderBoundExec backend running $ \exec -> do
                                let selected = selectProviderKind ProviderDirectHost providerHandles
                                discoverProvider running selected exec $ \capability -> do
                                    providerCapabilityKind capability @?= ProviderDirectHost
                                    providerCapabilityGeneration capability @?= managedProviderGeneration running
                                    providerCapabilityLiftContext capability @?= providerLiftContext selected
                                    providerCapabilityDiscovery capability
                                        @?= ProviderDirectDiscovery
                                            (DirectProviderDiscovery (ProviderObservedReady ()) (ProviderObservedReady ()))
            result @?= Right (Right ())
            readRecorded recorded >>= (@?= ["docker manifest inspect images:ubuntu/24.04", "docker manifest inspect images:ubuntu/24.04"])
    , testCase "Direct Ready validates the exact root then exact egress image" directReadyValidationCase
    , testCase "Direct Ready refuses an absent root before probing egress" directReadyAbsentRootCase
    , testCase "Direct Ready refuses failed egress without minting Running" directReadyEgressFailureCase
    , testCase "Direct Ready refuses a root that is not this host's canonical path" directReadyNonCanonicalCase
    , testCase "the Incus instance name must carry the project's delete guard prefix" $
        case mkIncusBackendSpec "other-vm" imageName "guarded-" fakeResolvedHostConfig (hostFixturePath "/state") 2 "4GiB" "40GiB" of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected guard-prefix refusal, got " <> showEither other)
    , testCase "the Direct egress probe is a described command" $ do
        commandTarget (directEgressCommand imageName) @?= ToolTarget Docker
        commandArguments (directEgressCommand imageName) @?= ["manifest", "inspect", imageName]
    , testCase "the Direct root admission refuses one observed fact at a time" directRootAdmissionCase
    , testCase "a failed Direct canonicalization is a refusing fact" $ do
        let root = hostFixturePath "/srv/canonical-root"
        directRootCanonicalFact root Nothing @?= False
        directRootCanonicalFact root (Just root) @?= True
        directRootCanonicalFact root (Just (root </> "other")) @?= False
    , testCase "the backend reaches every process through the one interpreter" backendHasNoExecutionSeamCase
    , testCase "settled Ready publishes one pending provider package and live reprobe" providerRuntimePackageCase
    , testCase "running-provider registration retains a consumed nonce" (providerRuntimePackageCaseWithRetry True)
    , testCase "provider-share registration retains a consumed nonce" providerShareRegistrationReplayCase
    , testCase "carried provider refuses a fresh native observation mismatch before its continuation" carriedProviderGenerationMismatchCase
    ]

-- Each rejected field has its own Tasty case and exact structured refusal.
backendAdmissionCases :: [TestTree]
backendAdmissionCases =
    [ testCase ("Incus refuses " <> label) $
        refused "Incus" incusNameReason (incus name imageName "hb" absoluteState 2 "2GiB" "12GiB")
    | (label, name) <-
        [ ("an empty instance name", "")
        , ("an underscore in its instance name", "hb_vm")
        , ("a dot in its instance name", "hb.vm")
        , ("a leading hyphen in its instance name", "-hbvm")
        , ("a trailing hyphen in its instance name", "hbvm-")
        , ("a leading digit in its instance name", "1hbvm")
        , ("an uppercase instance name", "HBvm")
        , ("a non-ASCII instance name", "hbvm\x00e9")
        ]
    ]
        <> [ testCase ("Incus refuses " <> label) $
                refused "Incus" prefixReason (incus "hbvm" imageName prefix absoluteState 2 "2GiB" "12GiB")
           | (label, prefix) <-
                [ ("an empty guard prefix", "")
                , ("a non-portable guard prefix", "hb_")
                , ("a digit-led guard prefix", "1hb")
                , ("a non-ASCII guard prefix", "hb\x00e9")
                ]
           ]
        <> [ testCase "Incus bounds a multibyte name by UTF-8 bytes before hostname classification" $
                refused "Incus" socketReason (incus ("hb" <> replicate 23 '\x00e9') imageName "hb" absoluteState 2 "2GiB" "12GiB")
           , testCase "Incus refuses an ASCII name one byte beyond its socket budget" $
                refused "Incus" socketReason (incus ("hb" <> replicate 46 'x') imageName "hb" absoluteState 2 "2GiB" "12GiB")
           , testCase "Incus admits the exact socket byte budget and a trailing-hyphen guard" $ do
                accepted (incus ("hb" <> replicate 45 'x') imageName "hb" absoluteState 2 "2GiB" "12GiB")
                accepted (incus "hb-vm" imageName "hb-" absoluteState 2 "2GiB" "12GiB")
           , testCase "Incus refuses an empty image" $
                refused "Incus" imageReason (incus "hbvm" "" "hb" absoluteState 2 "2GiB" "12GiB")
           , testCase "Incus refuses NUL in its image" $
                refused "Incus" imageReason (incus "hbvm" "image\0suffix" "hb" absoluteState 2 "2GiB" "12GiB")
           , testCase "Incus refuses a relative state directory" $
                refused "Incus" "the provider state directory must be an absolute path on this host"
                    (incus "hbvm" imageName "hb" "relative-state" 2 "2GiB" "12GiB")
           , testCase "Incus refuses NUL in its state directory" $
                refused "Incus" "the provider state directory must not contain NUL"
                    (incus "hbvm" imageName "hb" (absoluteState <> "\0") 2 "2GiB" "12GiB")
           , testCase "Incus refuses zero CPUs" $
                refused "Incus" "the provider CPU quantity must be positive"
                    (incus "hbvm" imageName "hb" absoluteState 0 "2GiB" "12GiB")
           ]
        <> [ testCase ("Incus refuses " <> field <> " " <> label) $
                refused "Incus" quantityReason
                    (incus "hbvm" imageName "hb" absoluteState 2 memoryValue storageValue)
           | (label, value) <-
                [ ("without a numeric value", "lots")
                , ("with its unit before the number", "GiB4")
                , ("with a non-ASCII digit", "\x0664GiB")
                , ("when empty", "")
                , ("beyond the integer byte range", "9223372036854775808")
                , ("whose unit multiplication overflows", "8EiB")
                , ("with a misspelled unit", "4Gib")
                ]
           , (field, memoryValue, storageValue) <- [("memory", value, "12GiB"), ("storage", "2GiB", value)]
           ]
        <> [ testCase "Incus admits its documented byte suffixes and exact integer ceiling" $
                forM_
                    (map ("1" <>) ["", "B", " bytes", "kB", "MB", "GB", "TB", "PB", "EB", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
                        <> ["9223372036854775807", "7EiB", "9EB"])
                    $ \value -> accepted (incus "hbvm" imageName "hb" absoluteState 2 value value)
           , testCase "Direct refuses a relative root" $
                refused "Direct" "the direct-host root must be an absolute path on this host"
                    (direct "relative-root" imageName)
           , testCase "Direct refuses NUL in its root" $
                refused "Direct" "the direct-host root must not contain NUL"
                    (direct (absoluteState <> "\0") imageName)
           , testCase "Direct refuses an empty egress image" $
                refused "Direct" directImageReason (direct absoluteState "")
           , testCase "Direct refuses NUL in its egress image" $
                refused "Direct" directImageReason (direct absoluteState "image\0suffix")
           ]
  where
    incus name image prefix state cpus memoryValue storageValue =
        mkIncusBackendSpec name image prefix fakeResolvedHostConfig state cpus memoryValue storageValue
    direct root image = mkDirectHostBackendSpec fakeResolvedHostConfig root image
    absoluteState = hostFixturePath "/admission-state"
    prefixReason = "the destructive-delete guard prefix must be a non-empty ASCII hostname prefix starting with a letter"
    socketReason = "the Incus instance name is longer than 47 UTF-8 bytes, so its share device socket path exceeds the platform limit"
    imageReason = "the Incus image must be non-empty and contain no NUL"
    quantityReason = "provider memory and storage quantities must be ASCII digits with an Incus byte suffix and fit a signed 64-bit byte value"
    directImageReason = "the Direct provider egress image must be non-empty and contain no NUL"
    accepted value = expectRight value >> pure ()

incusNameReason :: Text.Text
incusNameReason = "the Incus instance name must be an ASCII hostname: a-z, 0-9 and hyphen, starting with a letter and not ending with a hyphen"

refused :: Text.Text -> Text.Text -> Either ReconcileError value -> IO ()
refused label expected result = case result of
    Left (Failure detail) -> do
        failedOperation detail @?= "validate " <> label <> " provider backend"
        failureCause detail @?= expected
        recoveryDisposition detail @?= DoNotRetry
    other -> assertFailure ("expected exact backend admission refusal, got " <> showEither other)

-- The CLI owns ordinary configuration and real directories. Only the shipped
-- kernel row and protected tape can establish the instance's ownership.
guestVmTransactionCases :: [TestTree]
guestVmTransactionCases =
    [ testGroup "recorded guest VM transaction"
        [ nativeGuestCase "fresh creation binds the actual native directory" $ \cfg owned root -> do
            identity <- createGuestVm cfg owned
            actual <- aliasKernelIdentity (FakeProvider.limaInstanceDirectory root vmName)
            identity @?= actual
            record <- guestVmRecord owned
            Ownership.originRecordOrigin record @?= Ownership.OriginAbsent
            Ownership.originRecordKind record @?= Ownership.ReportedObject (GuestVm.ownedGuestVmClaim owned)
            Ownership.originRecordBinding record @?= Just identity
            FakeProvider.recordedProviderMutations root >>= (@?= ["lima-create"])
        , nativeGuestCase "retained creation adopts only the recorded native identity" $ \cfg owned root -> do
            identity <- createGuestVm cfg owned
            before <- guestVmStoredRecord owned
            let equivalent = owned{GuestVm.ownedGuestVmSizing = ProviderSizing 2 "4096MiB" "40960MiB"}
            GuestVm.provisionOwnedGuestVm cfg equivalent >>= (@?= Right (Owned.ProvisionAlreadyOwned identity))
            guestVmStoredRecord owned >>= (@?= before)
            FakeProvider.recordedProviderMutations root >>= (@?= ["lima-create"])
        , nativeGuestCase "Stopped starts once and Running starts zero additional times" $ \cfg owned root -> do
            identity <- createGuestVm cfg owned
            GuestVm.readyOwnedGuestVm cfg owned >>= (@?= Right (Owned.ReadyStarted identity))
            GuestVm.readyOwnedGuestVm cfg owned >>= (@?= Right (Owned.ReadyAlready identity))
            FakeProvider.recordedProviderMutations root >>= (@?= ["lima-create", "lima-start"])
        , nativeGuestCase "a listed unmarked instance receives no mutation" $ \cfg owned root -> do
            plantUnmarkedLima root
            configBefore <- readFile' (FakeProvider.limaInstanceDirectory root vmName </> "creation.json")
            identity <- aliasKernelIdentity (FakeProvider.limaInstanceDirectory root vmName)
            GuestVm.provisionOwnedGuestVm cfg owned >>= (@?= Left
                (Owned.ProviderOwnershipStanding (Resume.InstanceUnderNoRecord identity)))
            FakeProvider.recordedProviderMutations root >>= (@?= [])
            readFile' (FakeProvider.limaInstanceDirectory root vmName </> "creation.json") >>= (@?= configBefore)
        , nativeGuestCase "even a matching creation claim cannot replace an absent record" $ \cfg owned root -> do
            plantUnmarkedLima root
            FakeProvider.setLimaConfigValue root vmName "env"
                (Aeson.object ["HOSTBOOTSTRAP_OWNER" .= Ownership.ownerClaimText (GuestVm.ownedGuestVmClaim owned)])
            identity <- aliasKernelIdentity (FakeProvider.limaInstanceDirectory root vmName)
            GuestVm.provisionOwnedGuestVm cfg owned >>= (@?= Left
                (Owned.ProviderOwnershipStanding (Resume.InstanceUnderNoRecord identity)))
            FakeProvider.recordedProviderMutations root >>= (@?= [])
        , nativeGuestCase "a different incoming project claim cannot adopt the retained record" $ \cfg owned root -> do
            _ <- createGuestVm cfg owned
            let changedOwner = owned{GuestVm.ownedGuestVmOwner = "other-project-owner"}
            assertGuestVmRefused =<< GuestVm.provisionOwnedGuestVm cfg changedOwner
            FakeProvider.recordedProviderMutations root >>= (@?= ["lima-create"])
        , nativeGuestCase "missing native creation claim refuses dependent work" $ \cfg owned root -> do
            _ <- readyGuestVm cfg owned
            FakeProvider.setLimaConfigValue root vmName "env" (Aeson.object [])
            before <- guestVmInvocations root
            assertGuestVmRefused =<< GuestVm.execInOwnedGuestVm cfg owned ["true"]
            guestVmInvocations root >>= (@?= before)
        , nativeGuestCase "changed native creation claim refuses dependent work" $ \cfg owned root -> do
            _ <- readyGuestVm cfg owned
            FakeProvider.setLimaConfigValue root vmName "env"
                (Aeson.object ["HOSTBOOTSTRAP_OWNER" .= ("another-owner" :: String)])
            before <- guestVmInvocations root
            assertGuestVmRefused =<< GuestVm.execInOwnedGuestVm cfg owned ["true"]
            guestVmInvocations root >>= (@?= before)
        , nativeGuestCase "the claim is checked again immediately before guest launch" $ \cfg owned root -> do
            _ <- readyGuestVm cfg owned
            writeFile (FakeProvider.changeLimaClaimPath root) "once\n"
            before <- guestVmInvocations root
            assertGuestVmRefused =<< GuestVm.execInOwnedGuestVm cfg owned ["true"]
            guestVmInvocations root >>= (@?= before)
        , nativeGuestCase "a same-name native-directory replacement refuses before guest launch" $ \cfg owned root -> do
            identity <- readyGuestVm cfg owned
            FakeProvider.replaceLimaDirectory root vmName
            replacement <- aliasKernelIdentity (FakeProvider.limaInstanceDirectory root vmName)
            before <- guestVmInvocations root
            GuestVm.execInOwnedGuestVm cfg owned ["true"] >>= (@?= Left
                (Owned.ProviderOwnershipStanding (Resume.InstanceReplaced identity replacement)))
            guestVmInvocations root >>= (@?= before)
        , nativeGuestCase "replacement during guest work refuses its result" $ \cfg owned root -> do
            _ <- readyGuestVm cfg owned
            before <- guestVmInvocations root
            FakeProvider.armReplacementAfter root "guest"
            assertGuestVmRefused =<< GuestVm.execInOwnedGuestVm cfg owned ["true"]
            guestVmInvocations root >>= (@?= before <> [["true"]])
        , nativeGuestCase "replacement during start prevents the readiness guest launch" $ \cfg owned root -> do
            _ <- createGuestVm cfg owned
            FakeProvider.armReplacementAfter root "start"
            assertGuestVmRefused =<< GuestVm.readyOwnedGuestVm cfg owned
            guestVmInvocations root >>= (@?= [])
            FakeProvider.recordedProviderMutations root >>= (@?= ["lima-create", "lima-start"])
        , nativeGuestCase "parent replacement refuses before any provider command" $ \cfg owned root -> do
            _ <- readyGuestVm cfg owned
            before <- FakeProvider.recordedProviderCommands root
            let namespace = GuestVm.ownedGuestVmNamespace owned
            renameDirectory namespace (namespace <> ".replaced")
            createDirectory namespace
            assertGuestVmRefused =<< GuestVm.execInOwnedGuestVm cfg owned ["true"]
            FakeProvider.recordedProviderCommands root >>= (@?= before)
        , nativeGuestCase "parent replacement during guest work refuses its result" $ \cfg owned root -> do
            _ <- readyGuestVm cfg owned
            writeFile (FakeProvider.replaceLimaParentPath root) (GuestVm.ownedGuestVmNamespace owned)
            before <- guestVmInvocations root
            assertGuestVmRefused =<< GuestVm.execInOwnedGuestVm cfg owned ["true"]
            guestVmInvocations root >>= (@?= before <> [["true"]])
        , nativeGuestCase "lost create response retains an unbound origin and recovers without creating twice" $ \cfg owned root -> do
            writeFile (FakeProvider.crashAfterLaunchPath root) "once\n"
            assertGuestVmRefused =<< GuestVm.provisionOwnedGuestVm cfg owned
            guestVmRecord owned >>= (\record -> Ownership.originRecordBinding record @?= Nothing)
            resumed <- GuestVm.provisionOwnedGuestVm cfg owned >>= expectRight
            identity <- aliasKernelIdentity (FakeProvider.limaInstanceDirectory root vmName)
            resumed @?= Owned.ProvisionRecovered identity
            guestVmRecord owned >>= (\record -> Ownership.originRecordBinding record @?= Just identity)
            FakeProvider.recordedProviderMutations root >>= (@?= ["lima-create"])
        , nativeGuestCase "failed creation retains the origin needed for retry" $ \cfg owned root -> do
            writeFile (FakeProvider.failLimaCreatePath root) "once\n"
            assertGuestVmRefused =<< GuestVm.provisionOwnedGuestVm cfg owned
            record <- guestVmRecord owned
            Ownership.originRecordBinding record @?= Nothing
            Ownership.originRecordOrigin record @?= Ownership.OriginAbsent
            FakeProvider.recordedProviderMutations root >>= (@?= [])
            removeFile (FakeProvider.failLimaCreatePath root)
            _ <- createGuestVm cfg owned
            FakeProvider.recordedProviderMutations root >>= (@?= ["lima-create"])
        , nativeGuestCase "interrupted creation under a different native claim refuses recovery" $ \cfg owned root -> do
            writeFile (FakeProvider.crashAfterLaunchPath root) "once\n"
            assertGuestVmRefused =<< GuestVm.provisionOwnedGuestVm cfg owned
            FakeProvider.setLimaConfigValue root vmName "env" (Aeson.object [])
            assertGuestVmRefused =<< GuestVm.provisionOwnedGuestVm cfg owned
            guestVmRecord owned >>= (\record -> Ownership.originRecordBinding record @?= Nothing)
            FakeProvider.recordedProviderMutations root >>= (@?= ["lima-create"])
        , nativeGuestCase "guest nonzero readiness is a bounded observation" $ \cfg owned root -> do
            _ <- createGuestVm cfg owned
            writeFile (guestProbeScriptPath root) (show ([(7, "", "not ready\n")] :: [(Int, String, String)]))
            GuestVm.readyOwnedGuestVm cfg owned >>= (@?= Right (Owned.ReadyNotAnswering "not ready"))
            FakeProvider.recordedProviderMutations root >>= (@?= ["lima-create", "lima-start"])
        , nativeGuestCase "guest noisy success refuses through the common report classifier" $ \cfg owned root -> do
            _ <- readyGuestVm cfg owned
            writeFile (guestProbeScriptPath root) (show ([(0, "", "warning\n")] :: [(Int, String, String)]))
            GuestVm.execInOwnedGuestVm cfg owned ["true"] >>= (@?= Left
                (Owned.ProviderOwnershipReport (ProviderReport.ProviderCommandNoisy "warning")))
        , nativeGuestCase "empty dependent argv refuses without launching a client" $ \cfg owned root -> do
            _ <- readyGuestVm cfg owned
            before <- FakeProvider.recordedProviderCommands root
            assertGuestVmRefused =<< GuestVm.execInOwnedGuestVm cfg owned []
            FakeProvider.recordedProviderCommands root >>= (@?= before)
        , nativeGuestCase "NUL dependent argv refuses without launching a client" $ \cfg owned root -> do
            _ <- readyGuestVm cfg owned
            before <- FakeProvider.recordedProviderCommands root
            assertGuestVmRefused =<< GuestVm.execInOwnedGuestVm cfg owned ["bad\0argv"]
            FakeProvider.recordedProviderCommands root >>= (@?= before)
        , nativeGuestCase "concurrent creation preserves one origin and permits an explicit retry" $ \cfg owned root -> do
            first <- newEmptyMVar
            second <- newEmptyMVar
            _ <- forkIO (GuestVm.provisionOwnedGuestVm cfg owned >>= putMVar first)
            _ <- forkIO (GuestVm.provisionOwnedGuestVm cfg owned >>= putMVar second)
            one <- takeMVar first
            two <- takeMVar second
            identity <- aliasKernelIdentity (FakeProvider.limaInstanceDirectory root vmName)
            let contender value = case value of
                    Right (Owned.ProvisionAlreadyOwned actual) -> actual == identity
                    Left (Owned.ProviderOwnershipClause (Ownership.OwnershipProbeFailed operation reason)) ->
                        operation `elem` ["open this frame's ownership authority", "enter this frame's ownership authority"]
                            && Text.isInfixOf "store.lock" reason
                            && Text.isInfixOf "resource busy" reason
                            && Text.isInfixOf "file is locked" reason
                    _ -> False
            assertBool ("one creator and either retained admission or the precise native lock refusal: " <> show (one, two))
                ((one == Right (Owned.ProvisionCreated identity) && contender two)
                    || (two == Right (Owned.ProvisionCreated identity) && contender one))
            GuestVm.provisionOwnedGuestVm cfg owned >>= (@?= Right (Owned.ProvisionAlreadyOwned identity))
            FakeProvider.recordedProviderMutations root >>= (@?= ["lima-create"])
        ]
    ]

nativeGuestCase :: String -> (HostConfig -> GuestVm.OwnedGuestVm -> FilePath -> IO ()) -> TestTree
nativeGuestCase label action = testCase label $
    withSystemTempDirectory "hostbootstrap-recorded-guest" $ \temporary -> do
        root <- canonicalizePath temporary
        let share = root </> "share"
        createDirectory share
        _ <- FakeProvider.newProviderFixture root "lima" FakeProvider.ProviderAnswers
        clientExecutable <- getExecutablePath
        let cfg = HostConfig (Substrate AppleSilicon Arm64) (Map.singleton Lima (fixtureExe clientExecutable))
            owned = GuestVm.OwnedGuestVm limaProvider (ProviderSizing 2 "4GiB" "40GiB")
                (HostPathShare share "/srv/hostbootstrap/data" Nothing) "the-project-owner"
        FakeProvider.withFakeProviderClient root $
#if defined(mingw32_HOST_OS)
            do
                let _ = action
                GuestVm.provisionOwnedGuestVm cfg owned >>= (@?= Left
                    (Owned.ProviderOwnershipClause (Ownership.OwnershipUnsupported
                        "this host's native guest-VM identity row requires WSL2")))
                FakeProvider.recordedProviderCommands root >>= (@?= [])
#else
            action cfg owned root
#endif

createGuestVm :: HostConfig -> GuestVm.OwnedGuestVm -> IO Ownership.ObjectIdentity
createGuestVm cfg owned = do
    result <- GuestVm.provisionOwnedGuestVm cfg owned >>= expectRight
    case result of
        Owned.ProvisionCreated identity -> pure identity
        other -> assertFailure ("expected a fresh recorded guest creation, got " <> show other)

readyGuestVm :: HostConfig -> GuestVm.OwnedGuestVm -> IO Ownership.ObjectIdentity
readyGuestVm cfg owned = do
    identity <- createGuestVm cfg owned
    GuestVm.readyOwnedGuestVm cfg owned >>= (@?= Right (Owned.ReadyStarted identity))
    pure identity

guestVmRecord :: GuestVm.OwnedGuestVm -> IO Ownership.OriginRecord
guestVmRecord owned = do
    held <- guestVmStoredRecord owned
    expectRight (Ownership.parseOriginRecord (protectedRecordBytes held))

guestVmStoredRecord :: GuestVm.OwnedGuestVm -> IO ProtectedRecord
guestVmStoredRecord owned = do
    records <- openProtectedStore (GuestVm.ownedGuestVmRecordDirectory owned) >>= expectRight
    key <- expectRight (mkRecordKey "guest-instance")
    result <- withProtectedEntry records (\session -> readProtectedRecord session key) >>= expectRight
    maybe (assertFailure "the guest-VM origin record disappeared") pure result

guestVmInvocations :: FilePath -> IO [[String]]
guestVmInvocations root = map read . lines <$> readFile' (FakeProvider.guestInvocationsPath root)

assertGuestVmRefused :: Either Owned.ProviderOwnershipFault value -> IO ()
assertGuestVmRefused (Left _) = pure ()
assertGuestVmRefused (Right _) = assertFailure "the recorded guest-VM transaction unexpectedly admitted the effect"

plantUnmarkedLima :: FilePath -> IO ()
plantUnmarkedLima root = do
    createDirectoryIfMissing True (FakeProvider.limaInstanceDirectory root vmName)
    writeFile (FakeProvider.limaInstanceDirectory root vmName </> "creation.json")
        "{\"cpus\":2,\"memory\":\"4GiB\",\"disk\":\"40GiB\"}"
    FakeProvider.writeInstances root [(vmName, FakeProvider.ProviderInstance "Stopped" "" "" [] True [])]

-- Each report fault enters through an actual recorded VM, not a listed name.
guestVmReportCases :: [TestTree]
guestVmReportCases =
    [ testGroup "recorded guest VM backend"
        ( [ nativeGuestBackendCase "fresh provisioning creates and records a stopped VM" $ \host backend ->
                withProvisionedProvider backend $ \_ _ _ managed -> do
                    managedProviderGeneration managed @?= 17
                    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["lima-create"])
          , nativeGuestBackendCase "retained provisioning uses the same record without a second creation" $ \host backend ->
                withProvisionedProvider backend $ \_ _ prepared _ -> do
                    let owned = backendGuestVmDescription host prepared
                    before <- guestVmStoredRecord owned
                    FakeProvider.setLimaConfigValue (hostRoot host) vmName "memory" (Aeson.toJSON ("4096MiB" :: String))
                    call <- provisionCall backend prepared
                    settled <- expectRight (settleProviderProvision Nothing prepared call)
                    withProviderProvisionSettlement settled
                        (\managed _ -> managedProviderGeneration managed @?= 17)
                        (\_ _ _ _ -> assertFailure "the recorded VM became foreign")
                    guestVmStoredRecord owned >>= (@?= before)
                    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["lima-create"])
          , nativeGuestBackendCase "a pre-existing unmarked name remains foreign and receives no mutation" $ \host backend -> do
                plantUnmarkedLima (hostRoot host)
                withPreparedProviderFixture backend 17 $ \_ _ _ prepared -> do
                    call <- provisionCall backend prepared
                    settled <- expectRight (settleProviderProvision Nothing prepared call)
                    withProviderProvisionSettlement settled
                        (\_ _ -> assertFailure "a name-only instance was adopted")
                        (\_ _ _ _ -> pure ())
                    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
          , nativeGuestBackendCase "a failed launch is reported and retains an origin for retry" $ \host backend -> do
                writeFile (FakeProvider.failLimaCreatePath (hostRoot host)) "once\n"
                withPreparedProviderFixture backend 17 $ \_ _ _ prepared -> do
                    call <- provisionCall backend prepared
                    assertGuestVmFailure "provision provider"
                        (ProviderReport.ProviderCommandExited 1 "the Lima create failed before creating anything")
                        (settleProviderProvision Nothing prepared call)
                    removeFile (FakeProvider.failLimaCreatePath (hostRoot host))
                    retry <- provisionCall backend prepared
                    void (expectRight (settleProviderProvision Nothing prepared retry))
                    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["lima-create"])
          , nativeGuestBackendCase "Stopped starts once and Running zero additional times" $ \host backend ->
                withProvisionedProvider backend $ \execution planned _ provisioned -> do
                    _ <- readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned) >>= expectRight
                    _ <- readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned) >>= expectRight
                    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["lima-create", "lima-start"])
          , nativeGuestBackendCase "nonzero readiness retries without a second start" $ \host backend ->
                withProvisionedProvider backend $ \execution planned _ provisioned -> do
                    writeFile (notReadyBudgetPath (hostRoot host)) "1\n"
                    _ <- readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned) >>= expectRight
                    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["lima-create", "lima-start"])
                    guestVmInvocations (hostRoot host) >>= (@?= [["true"], ["true"]])
          , nativeGuestBackendCase "readiness stops after its real sixty-probe budget" $ \host backend ->
                withProvisionedProvider backend $ \execution planned _ provisioned -> do
                    writeFile (notReadyBudgetPath (hostRoot host)) "61\n"
                    outcome <- readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned)
                    case outcome of
                        Left (Failure detail) -> recoveryDisposition detail @?= RetrySameOperationKeyAfterFencing
                        other -> assertFailure ("expected exhausted readiness, got " <> showEither other)
                    probes <- guestVmInvocations (hostRoot host)
                    probes @?= replicate 60 ["true"]
                    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["lima-create", "lima-start"])
          , nativeGuestBackendCase "the bound daemon, guest and egress probes keep recorded ownership" $ \host backend ->
                withRunningProvider backend $ \_ _ _ running ->
                    resolveEitherIO $ withProviderBoundExec (underTestBackend backend) running $ \bound -> do
                        discovered <- discoverProvider running limaProvider bound $ \capability ->
                            providerCapabilityDiscovery capability @?= ProviderGuestDiscovery
                                (GuestProviderDiscovery (ProviderObservedReady ()) (ProviderObservedReady ()) (ProviderObservedReady ()))
                        expectRight discovered
                        FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["lima-create", "lima-start"])
          , nativeGuestBackendCase "bound discovery refuses a replaced native directory before guest work" $ \host backend ->
                withRunningProvider backend $ \_ _ _ running -> do
                    FakeProvider.replaceLimaDirectory (hostRoot host) vmName
                    before <- guestVmInvocations (hostRoot host)
                    resolveEitherIO $ withProviderBoundExec (underTestBackend backend) running $ \bound -> do
                        discovered <- discoverProvider running limaProvider bound $ \capability ->
                            assertBool "the replacement propagates its structured conflict"
                                (Text.isInfixOf "Conflict" (Text.pack (show (providerCapabilityDiscovery capability))))
                        expectRight discovered
                    guestVmInvocations (hostRoot host) >>= (@?= before)
          , nativeGuestBackendCase "bound discovery refuses parent replacement before launching a client" $ \host backend ->
                withRunningProvider backend $ \_ _ prepared running -> do
                    let owned = backendGuestVmDescription host prepared
                        namespace = GuestVm.ownedGuestVmNamespace owned
                    renameDirectory namespace (namespace <> ".replaced")
                    createDirectory namespace
                    before <- FakeProvider.recordedProviderCommands (hostRoot host)
                    resolveEitherIO $ withProviderBoundExec (underTestBackend backend) running $ \bound -> do
                        discovered <- discoverProvider running limaProvider bound (\_ -> pure ())
                        expectRight discovered
                    FakeProvider.recordedProviderCommands (hostRoot host) >>= (@?= before)
          , nativeGuestBackendCase "forward stop retains the exact Unsupported policy" $ \host backend ->
                withRunningProvider backend $ \execution planned _ running -> do
                    stopped <- stopProvider backend execution planned running
                    case stopped of
                        Left (Unsupported detail) -> detail @?= UnsupportedDetail "stop Lima provider through a forward handle"
                            "Lima reverse is owned by the plan's retained step-declared adapter"
                        other -> assertFailure ("expected exact stop Unsupported, got " <> showEither other)
                    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["lima-create", "lima-start"])
          ]
          <> [ nativeGuestBackendCase (label <> " refuses before any process or capability callback") $ \host backend ->
                    withRunningProvider backend $ \_ _ _ running -> do
                        before <- FakeProvider.recordedProviderCommands (hostRoot host)
                        callbacks <- newIORef (0 :: Int)
                        resolveEitherIO $ withProviderBoundExec (underTestBackend backend) running $ \bound -> do
                            result <- discoverProvider running selected bound (\_ -> modifyIORef' callbacks (+ 1))
                            case result of
                                Left fault -> providerErrorOperation fault @?= ProviderGuestRoute
                                Right () -> assertFailure "a different provider route reached the capability callback"
                        readIORef callbacks >>= (@?= 0)
                        FakeProvider.recordedProviderCommands (hostRoot host) >>= (@?= before)
             | (label,selected) <-
                [ ("a foreign host-tool route",incusProvider)
                , ("a Direct probe route",selectProviderKind ProviderDirectHost providerHandles)
                , ("a different VM name",selectProviderKind ProviderLima providerHandles{vmhLima = Lima.LimaVM (vmName <> "-other")})
                ]
             ]
          <> [ nativeGuestBackendCase "oversized CPU refuses before conversion or client launch" $ \host _ -> do
                    clientExecutable <- getExecutablePath
                    let cfg = HostConfig (Substrate AppleSilicon Arm64) (Map.singleton Lima (fixtureExe clientExecutable))
                    spec <- expectRight (mkLimaBackendSpec cfg limaProvider limaEnvelope{cpu = 18446744073709551616}
                        (HostPathShare (shareRoot host) shareGuestPath Nothing))
                    discovered <- discoverStrongProviderBackend cfg spec $ \strong ->
                        withPreparedProviderFixture (ProviderUnderTest strong) 17 $ \_ _ _ prepared -> do
                            call <- provisionCall (ProviderUnderTest strong) prepared
                            case settleProviderProvision Nothing prepared call of
                                Left (Failure detail) -> failureCause detail @?=
                                    "the guest-VM CPU quantity exceeds its provider representation"
                                other -> assertFailure ("expected bounded CPU refusal, got " <> showEither other)
                    expectRight discovered
                    FakeProvider.recordedProviderCommands (hostRoot host) >>= (@?= [])
             ]
          <> [ nativeGuestBackendCase ("native listing refuses " <> label) $ \host backend -> do
                    queueLimaReport host (limaNativeList vmName) status out err
                    withPreparedProviderFixture backend 17 $ \_ _ _ prepared -> do
                        call <- provisionCall backend prepared
                        assertGuestVmFailure "provision provider" fault (settleProviderProvision Nothing prepared call)
                    assertLimaReportConsumed host
                    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
             | (label, status, out, err, fault) <-
                [ ("stderr", 0, "", "warning\n", ProviderReport.ProviderCommandNoisy "warning")
                , ("controls", 0, "\ESC", "", ProviderReport.ProviderReportUnreadable "the provider report carries a control character")
                , ("overlong wire", 0, replicate 65537 'a', "", ProviderReport.ProviderReportUnreadable "the provider report carries a line past the admitted bound")
                , ("nonzero", 7, "", "permission denied\nsecond\n", ProviderReport.ProviderCommandExited 7 "permission denied")
                ]
             ]
          <> [ nativeGuestBackendCase ("create refuses " <> label) $ \host backend ->
                    withPreparedProviderFixture backend 17 $ \_ _ _ prepared -> do
                        queueLimaReport host ["--log-level=error","--tty=false","create","--name",vmName,"-"] status out err
                        call <- provisionCall backend prepared
                        assertGuestVmFailure "provision provider" fault (settleProviderProvision Nothing prepared call)
                        assertLimaReportConsumed host
             | (label, status, out, err, fault) <-
                [ ("failed process", 9, "", "launch refused\n", ProviderReport.ProviderCommandExited 9 "launch refused")
                , ("noisy success", 0, "", "warning\n", ProviderReport.ProviderCommandNoisy "warning")
                ]
             ]
          <> [ nativeGuestBackendCase ("readiness refuses " <> label) $ \host backend ->
                    withProvisionedProvider backend $ \execution planned _ provisioned -> do
                        queueLimaReport host (limaGuestCommand ["true"]) 0 out err
                        outcome <- readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned)
                        assertGuestVmFailure "reconcile provider ready" fault outcome
                        assertLimaReportConsumed host
             | (label, out, err, fault) <- guestVmMalformedAnswers
             ]
          <> [ nativeGuestBackendCase ("bound discovery refuses " <> label) $ \host backend ->
                    withRunningProvider backend $ \_ _ _ running -> do
                        queueLimaReport host (limaGuestCommand ["true"]) 0 out err
                        resolveEitherIO $ withProviderBoundExec (underTestBackend backend) running $ \bound -> do
                            discovered <- discoverProvider running limaProvider bound $ \capability ->
                                providerCapabilityDiscovery capability @?= ProviderGuestDiscovery
                                    (GuestProviderDiscovery (ProviderObservedReady ())
                                        (ProviderObservedFailure (ProbeFailure "provider probe" (Text.unpack (ProviderReport.providerReportFaultMessage fault))))
                                        (ProviderObservedFailure (ProbeFailure "provider probe" (Text.unpack (ProviderReport.providerReportFaultMessage fault)))))
                            expectRight discovered
                        assertLimaReportConsumed host
             | (label, out, err, fault) <- guestVmMalformedAnswers
             ]
          <> [ nativeGuestBackendCase (dimension <> " share probe refuses " <> label) $ \host backend ->
                    withRunningProviderAndShare host backend $ \_ _ _ _ _ _ _ prepared -> do
                        queueLimaReport host (limaGuestCommand ["test", flag, shareGuestPath]) 0 out err
                        call <- shareCall backend prepared
                        assertGuestVmFailure "reprobe guest-VM provider share" fault (settleProviderShare Nothing prepared call)
                        assertLimaReportConsumed host
             | (dimension, flag) <- [("directory","-d"),("writable","-w")]
             , (label, out, err, fault) <- guestVmMalformedAnswers
             ]
          <> [ nativeGuestBackendCase "directory and writable share probes retain separate exact argv" $ \host backend ->
                    withRunningProviderAndShare host backend $ \_ _ _ _ _ _ _ prepared -> do
                        before <- guestVmInvocations (hostRoot host)
                        call <- shareCall backend prepared
                        void (expectRight (settleProviderShare Nothing prepared call))
                        guestVmInvocations (hostRoot host) >>= (@?= before <> [["test","-d",shareGuestPath],["test","-w",shareGuestPath]])
             , nativeGuestBackendCase "writable share nonzero retains the bounded common diagnostic" $ \host backend ->
                    withRunningProviderAndShare host backend $ \_ _ _ _ _ _ _ prepared -> do
                        queueLimaReport host (limaGuestCommand ["test","-w",shareGuestPath]) 4 "" "read only\nsecond\n"
                        call <- shareCall backend prepared
                        assertGuestVmFailure "reprobe guest-VM provider share"
                            (ProviderReport.ProviderCommandExited 4 "read only") (settleProviderShare Nothing prepared call)
                        assertLimaReportConsumed host
             ]
          <> [ nativeGuestBackendCase ("changed share " <> dimension <> " refuses before guest work") $ \host backend -> do
                    let changedHost = if changeSource then host{hostRoot = hostRoot host </> "other"} else host
                        target = if changeSource then shareGuestPath else "/srv/other"
                    createDirectoryIfMissing True (shareRoot changedHost)
                    withRunningProviderAndSharePreparationAt target (pure ()) (assertFailure . show) changedHost backend $
                        \_ _ _ _ _ _ _ prepared -> do
                            before <- guestVmInvocations (hostRoot host)
                            call <- shareCall backend prepared
                            case settleProviderShare Nothing prepared call of
                                Left (Conflict detail) -> detail @?= ConflictDetail "guest-vm-provider-share"
                                    (Text.pack (shareRoot host <> " -> " <> shareGuestPath))
                                    (Text.pack (shareRoot changedHost <> " -> " <> target))
                                    "use the writable share retained by this exact guest-VM provider backend"
                                other -> assertFailure ("expected exact retained-share conflict, got " <> showEither other)
                            guestVmInvocations (hostRoot host) >>= (@?= before)
             | (dimension, changeSource) <- [("source", True),("target", False)]
             ]
        )
    ] <> wslBackendOriginCases

wslFractionalDiskCase :: TestTree
wslFractionalDiskCase = testCase "WSL fractional-GiB storage refuses before namespace or command" $
    withSystemTempDirectory "hostbootstrap-wsl-disk-representation" $ \temporary -> do
        root <- canonicalizePath temporary
        let share = root </> "share"
        createDirectory share
        self <- getExecutablePath
        let cfg = HostConfig (Substrate WindowsCpu Amd64) (Map.singleton Wsl (fixtureExe self))
            owned = GuestVm.OwnedGuestVm wsl2Provider (ProviderSizing 2 "4GiB" "40.5GiB")
                (HostPathShare share shareGuestPath Nothing) "the-fractional-request"
        FakeProvider.newGuestVmFixture root []
        outcome <- FakeProvider.withFakeProviderClient root (GuestVm.provisionOwnedGuestVm cfg owned)
#if defined(mingw32_HOST_OS)
        outcome @?= Left (Owned.ProviderOwnershipClause
            (Ownership.OwnershipMalformed "WSL2 installation requires a whole GiB disk budget"))
#else
        outcome @?= Left (Owned.ProviderOwnershipClause
            (Ownership.OwnershipUnsupported "this host's native guest-VM identity row requires Lima"))
#endif
        listDirectory share >>= (@?= [])
        FakeProvider.recordedProviderCommands root >>= (@?= [])

limaNativeList :: String -> [String]
limaNativeList name = ["--log-level=error","--tty=false","list","--format","json",name]

limaGuestCommand :: [String] -> [String]
limaGuestCommand argv = ["shell",vmName,"--","sudo","-H"] <> argv

queueLimaReport :: FakeHost -> [String] -> Int -> String -> String -> IO ()
queueLimaReport host argv status out err =
    writeFile (FakeProvider.guestVmScriptPath (hostRoot host)) (show [(argv,status,out,err)])

assertLimaReportConsumed :: FakeHost -> IO ()
assertLimaReportConsumed host = do
    remaining <- read <$> readFile' (FakeProvider.guestVmScriptPath (hostRoot host)) :: IO [([String],Int,String,String)]
    remaining @?= []

guestVmMalformedAnswers :: [(String, String, String, ProviderReport.ProviderReportFault)]
guestVmMalformedAnswers =
    [ ("noisy success", "", "warning\n", ProviderReport.ProviderCommandNoisy "warning")
    , ("control output", "\ESC[0m", "", ProviderReport.ProviderReportUnreadable "the provider report carries a control character")
    , ("overlong output", replicate 513 'a', "", ProviderReport.ProviderReportUnreadable "the provider report carries a line past the admitted bound")
    ]

assertGuestVmFailure :: Text.Text -> ProviderReport.ProviderReportFault -> Either ReconcileError value -> IO ()
assertGuestVmFailure operation fault outcome = case outcome of
    Left (Failure detail) -> detail @?= FailureDetail operation (ProviderReport.providerReportFaultMessage fault) ReprobeBeforeRetry
    other -> assertFailure ("expected the exact common report refusal, got " <> showEither other)

backendGuestVmDescription ::
    FakeHost ->
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    GuestVm.OwnedGuestVm
backendGuestVmDescription host prepared =
    GuestVm.OwnedGuestVm limaProvider (ProviderSizing 2 "4GiB" "40GiB")
        (HostPathShare (shareRoot host) shareGuestPath Nothing)
        (preparedProviderBindingOwner (preparedProviderProvisionBinding prepared))

nativeGuestBackendCase ::
    String ->
    (forall backendId. FakeHost -> ProviderUnderTest backendId -> IO ()) ->
    TestTree
nativeGuestBackendCase label action = testCase label $
    withSystemTempDirectory "hostbootstrap-recorded-backend" $ \temporary -> do
        root <- canonicalizePath temporary
        let host = FakeHost root (root </> "state")
        createDirectoryIfMissing True (shareRoot host)
        createDirectoryIfMissing True (statePath host)
        _ <- FakeProvider.newProviderFixture root "lima" FakeProvider.ProviderAnswers
        clientExecutable <- getExecutablePath
        let cfg = HostConfig (Substrate AppleSilicon Arm64) (Map.singleton Lima (fixtureExe clientExecutable))
        spec <- expectRight (mkLimaBackendSpec cfg limaProvider limaEnvelope
            (HostPathShare (shareRoot host) shareGuestPath Nothing))
        FakeProvider.withFakeProviderClient root $ do
            discovered <- discoverStrongProviderBackend cfg spec $ \backend ->
#if defined(mingw32_HOST_OS)
                do
                    let _ = action
                    withPreparedProviderFixture (ProviderUnderTest backend) 17 $ \_ _ _ prepared -> do
                        call <- provisionCall (ProviderUnderTest backend) prepared
                        case settleProviderProvision Nothing prepared call of
                            Left (Unsupported detail) -> detail @?= UnsupportedDetail "provision provider"
                                "this host's native guest-VM identity row requires WSL2"
                            other -> assertFailure ("expected native Lima refusal, got " <> showEither other)
                    FakeProvider.recordedProviderCommands root >>= (@?= [])
#else
                action host (ProviderUnderTest backend)
#endif
            expectRight discovered

-- A fixed native registry read precedes the compiled install client. No test
-- creates a WSL registration or supplies a surrogate GUID.
wslBackendOriginCases :: [TestTree]
wslBackendOriginCases =
    [ testCase ("WSL recorded installation " <> label) $
        withSystemTempDirectory "hostbootstrap-wsl-recorded-backend" $ \temporary -> do
            root <- canonicalizePath temporary
            createDirectory (root </> "share")
            clientExecutable <- getExecutablePath
            let cfg = HostConfig (Substrate WindowsCpu Amd64) (Map.singleton Wsl (fixtureExe clientExecutable))
                share = HostPathShare (root </> "share") shareGuestPath Nothing
            spec <- expectRight (mkWsl2BackendSpec cfg wsl2Provider limaEnvelope share)
            FakeProvider.withFakeProviderClient root $ do
                discovered <- discoverStrongProviderBackend cfg spec $ \strong ->
                    withPreparedProviderFixture (ProviderUnderTest strong) 17 $ \_ _ _ prepared -> do
                        let owner = preparedProviderBindingOwner (preparedProviderProvisionBinding prepared)
                            owned = GuestVm.OwnedGuestVm wsl2Provider (ProviderSizing 2 "4GiB" "40GiB") share owner
                            command = ProviderCommand.installWslInstanceCommand vmName
                                (GuestVm.ownedGuestVmInstallLocation owned) "40GB"
                            actualArgv = takeFileName clientExecutable : commandArguments command
                        FakeProvider.newGuestVmFixture root [(actualArgv,status,out,err)]
                        FakeProvider.requireGuestVmRecord root
                            (GuestVm.ownedGuestVmRecordDirectory owned </> "records" </> "wsl-installed-storage.rec")
                        call <- provisionCall (ProviderUnderTest strong) prepared
#if defined(mingw32_HOST_OS)
                        case expected of
                            Just fault -> assertGuestVmFailure "provision provider" fault (settleProviderProvision Nothing prepared call)
                            Nothing -> case settleProviderProvision Nothing prepared call of
                                Left (Failure detail) -> failureCause detail @?=
                                    "the guest-VM create command produced no claimed native instance"
                                other -> assertFailure ("a quiet CLI answer substituted for native registration: " <> showEither other)
                        FakeProvider.recordedProviderCommands root >>= (@?= [actualArgv])
                        remaining <- read <$> readFile' (FakeProvider.guestVmScriptPath root) :: IO [([String],Int,String,String)]
                        remaining @?= []
                        guestVmRecord owned >>= (\record -> Ownership.originRecordBinding record @?= Nothing)
                        diskStore <- openProtectedStore (GuestVm.ownedGuestVmRecordDirectory owned) >>= expectRight
                        diskKey <- expectRight (mkRecordKey "wsl-installed-storage")
                        disk <- withProtectedEntry diskStore (\session -> readProtectedRecord session diskKey) >>= expectRight
                        held <- maybe (assertFailure "the original disk cap was not persisted before installation") pure disk
                        WslDisk.classifyWslDiskCap (GuestVm.ownedGuestVmClaim owned) (protectedRecordBytes held)
                            @?= Right 42949672960
#else
                        let _ = expected
                        case settleProviderProvision Nothing prepared call of
                            Left (Unsupported detail) -> detail @?= UnsupportedDetail "provision provider"
                                "this host's native guest-VM identity row requires Lima"
                            other -> assertFailure ("expected native WSL refusal, got " <> showEither other)
                        FakeProvider.recordedProviderCommands root >>= (@?= [])
#endif
                expectRight discovered
    | (label,status,out,err,expected) <-
        [ ("retains a failed install origin",9,"","installation refused\n",
            Just (ProviderReport.ProviderCommandExited 9 "installation refused"))
        , ("refuses noisy install success",0,"","warning\n",
            Just (ProviderReport.ProviderCommandNoisy "warning"))
        , ("does not bind a CLI answer without a native registration",0,"","",Nothing)
        ]
    ]

retainedClientCases :: [TestTree]
retainedClientCases =
    [ testCase (label <> " strong admission holds its retained executable") $
        withFakeHost $ \host -> do
            self <- getExecutablePath
            let config = HostConfig substrate (Map.singleton tool (fixtureExe self))
                state = hostRoot host </> "unopened-admission"
                altered = config{hcToolPaths = Map.singleton tool (fixtureExe (hostRoot host </> "different-client"))}
            spec <- expectRight (construct config state)
            alternate <- expectRight (construct altered state)
            assertBool "a different client kept the same realization fingerprint" (spec /= alternate)
            matched <- discoverStrongProviderBackend config spec (const (pure ()))
            matched @?= Right ()
            forM_ [altered, config{hcToolPaths = Map.empty}] $ \substituted -> do
                result <-
                    discoverStrongProviderBackend substituted spec $ \backend ->
                        withProvisionedProvider (ProviderUnderTest backend) $ \_ _ _ _ -> pure ()
                refused (Text.pack label) "the resolved client executable differs from the admitted provider backend" result
                doesPathExist state >>= (@?= False)
                FakeProvider.recordedProviderCommands (hostRoot host) >>= (@?= [])
                FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
    | (label, tool, substrate, construct) <-
        [ ("Incus", Incus, Substrate LinuxCpu Amd64,
            \config state -> mkIncusBackendSpec vmName imageName vmName config state 2 "2GiB" "12GiB")
        , ("Direct", Docker, Substrate LinuxGpu Amd64,
            \config root -> mkDirectHostBackendSpec config root imageName)
        , ("Lima", Lima, Substrate AppleSilicon Arm64,
            \config _ -> mkLimaBackendSpec config limaProvider limaEnvelope limaShare)
        , ("WSL2", Wsl, Substrate WindowsCpu Amd64,
            \config _ -> mkWsl2BackendSpec config wsl2Provider limaEnvelope limaShare)
        ]
    ]

providerRecordCases :: [TestTree]
providerRecordCases =
    [ testCase "the alias node refuses a carried share dependency before probing" $
        nodeAliasRefusalCaseWith "carried-dependency" id id id id
    , testCase "owned share observation is read-only and refuses absence and replacement" $
        withFakeHost $ \host -> do
            config <- resolvedHostConfig
            store <- openProtectedStore (statePath host) >>= expectRight
            let owned = providerRecordInstance vmName
                share = providerRecordShare host owned "observed-share"
                observe = withProtectedEntry store $ \session ->
                    Right <$> Owned.observeOwnedShare config session share
            _ <- provisionRecordInstance config store owned
            absentRecords <- snapshotProviderRecords host
            absentMutations <- FakeProvider.recordedProviderMutations (hostRoot host)
            absent <- expectRight =<< observe
            case absent of
                Left _ -> pure ()
                Right _ -> assertFailure "an absent share was accepted"
            snapshotProviderRecords host >>= (@?= absentRecords)
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= absentMutations)
            key <- attachRecordShare config store share
            expected <- providerRecordBinding host key
            records <- snapshotProviderRecords host
            mutations <- FakeProvider.recordedProviderMutations (hostRoot host)
            actual <- expectRight =<< observe
            actual @?= Right expected
            snapshotProviderRecords host >>= (@?= records)
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= mutations)
            FakeProvider.armReplacementAfter (hostRoot host) "device-read"
            replacement <- expectRight =<< observe
            case replacement of
                Left _ -> pure ()
                Right _ -> assertFailure "a replaced parent was accepted"
            snapshotProviderRecords host >>= (@?= records)
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= mutations)
    , testCase "provider share address admission precedes every store-opening route" $ do
        source <-
            SourceGuard.withPackageSourceIn ["src"] $ \_ sourceRoot ->
                readFile (sourceRoot </> "HostBootstrap" </> "Substrate" </> "Provider" </> "Backend.hs")
        let instanceEntry =
                unlines
                    [ "withOwnedProviderTransaction _cfg spec owner transaction ="
                    , "case providerOwnershipAddress spec owner of"
                    , "Left fault -> pure (Left fault)"
                    , "Right (stateDirectory, key, owned) -> do"
                    , "opened <- openProtectedStore stateDirectory"
                    ]
            shareEntry =
                unlines
                    [ "withOwnedShareTransaction cfg spec owner device binding source target ="
                    , "case providerOwnershipAddress spec owner of"
                    , "Left fault -> pure (Left fault)"
                    , "Right (_, _, owned) ->"
                    , "let share = OwnedProviderShare owned device source target binding"
                    , "in case ownedShareRecordKey share of"
                    , "Left failure -> pure (Left (ProviderOwnershipStore failure))"
                    , "Right shareKey ->"
                    , "withOwnedProviderTransaction cfg spec owner $ \\session _key _owned ->"
                    , "attachOwnedShare cfg session shareKey share"
                    , "data OwnedProviderRefusal"
                    ]
        SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens instanceEntry) source @?= 1
        SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens shareEntry) source @?= 1
    , testCase "invalid provider declarations create no store directory or provider mutation" $
        withFakeHost $ \host -> do
            config <- resolvedHostConfig
            forM_ (zip ["bad/name", replicate 100 'A'] [1 :: Int ..]) $ \(name, index) -> do
                let state = hostRoot host </> ("unopened-declaration-" <> show index)
                case mkIncusBackendSpec name imageName name config state 2 "2GiB" "12GiB" of
                    Left (Failure detail) -> do
                        failedOperation detail @?= "validate Incus provider backend"
                        recoveryDisposition detail @?= DoNotRetry
                    other -> assertFailure ("expected an invalid provider declaration, got " <> showEither other)
                doesPathExist state >>= (@?= False)
                FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
                FakeProvider.readInstances (hostRoot host) >>= (@?= [])
    , testCase "invalid provider instance addresses refuse before creating store metadata" $
        withFakeHost $ \host -> do
            config <- resolvedHostConfig
            forM_ (zip [".leading", "trailing.", "bad..name"] [1 :: Int ..]) $ \(name, index) -> do
                let state = hostRoot host </> ("unopened-address-" <> show index)
                refused "Incus" incusNameReason (mkIncusBackendSpec name imageName name config state 2 "2GiB" "12GiB")
                doesPathExist state >>= (@?= False)
                FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
                FakeProvider.readInstances (hostRoot host) >>= (@?= [])
    , testCase "provider case, underscore and internal-dot identities keep independent records" $
        withFakeHost $ \host -> do
            store <- expectRight =<< openProtectedStore (statePath host)
            let names = ["Build", "build", "a_b", "aB", "a.b"]
                base = providerRecordInstance "Base_vm"
            instances <- traverse (expectRight . Owned.ownedInstanceRecordKey . providerRecordInstance) names
            shares <- traverse (expectRight . Owned.ownedShareRecordKey . providerRecordShare host base) names
            assertIndependentProviderRecords store (instances <> shares)
    , testCase "provider instance and device tuple boundaries cannot share a record" $
        withFakeHost $ \host -> do
            store <- expectRight =<< openProtectedStore (statePath host)
            keys <-
                traverse
                    (\(name, device) -> expectRight (Owned.ownedShareRecordKey (providerRecordShare host (providerRecordInstance name) device)))
                    [("a.b", "c"), ("a", "b.c"), ("a.device.b", "c"), ("a", "b.device.c")]
            assertIndependentProviderRecords store keys
    , testCase "invalid and expanded oversized provider keys leave every record untouched" $
        withFakeHost $ \host -> do
            store <- expectRight =<< openProtectedStore (statePath host)
            sentinel <- expectRight (mkRecordKey "provider-sentinel")
            assertIndependentProviderRecords store [sentinel]
            before <- snapshotProviderRecords host
            let owned = providerRecordInstance "valid-instance"
                invalid =
                    [ (Owned.ownedInstanceRecordKey (providerRecordInstance "bad/name"), "single record segment")
                    , (Owned.ownedShareRecordKey (providerRecordShare host owned "bad/device"), "single record segment")
                    , (Owned.ownedInstanceRecordKey (providerRecordInstance (replicate 100 'A')), "at most 200")
                    , (Owned.ownedShareRecordKey (providerRecordShare host owned (replicate 100 'A')), "at most 200")
                    ]
            forM_ invalid $ \(result, expectedReason) -> do
                case result of
                    Left (ProtectedInvalid reason) ->
                        assertBool ("the key refusal lost its reason: " <> show reason) (expectedReason `Text.isInfixOf` reason)
                    other -> assertFailure ("expected an invalid provider key, got " <> show other)
                snapshotProviderRecords host >>= (@?= before)
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
            FakeProvider.readInstances (hostRoot host) >>= (@?= [])
    , testCase "retained provider deletion recovers literal case, dot and underscore device identities" $
        withFakeHost $ \host -> do
            store <- expectRight =<< openProtectedStore (statePath host)
            config <- resolvedHostConfig
            let owned = providerRecordInstance "Guard.Vm_A"
                neighbor = providerRecordInstance "Guard.Vm_A.peer"
                devices = ["Disk.A_b", "disk.a_b", "a_b", "aB"]
                shares = map (providerRecordShare host owned) devices
                neighborShare = providerRecordShare host neighbor "Other.Disk_A"
            instanceKey <- provisionRecordInstance config store owned
            neighborKey <- provisionRecordInstance config store neighbor
            shareKeys <- traverse (attachRecordShare config store) shares
            neighborShareKey <- attachRecordShare config store neighborShare
            held <- heldInstance host (Owned.ownedInstanceName owned)
            fmap (sort . map fst . FakeProvider.instanceDevices) held @?= Just (sort devices)
            neighborBefore <- heldInstance host (Owned.ownedInstanceName neighbor)
            assertBool "the neighboring instance was not provisioned" (maybe False (const True) neighborBefore)
            let neighborFiles = sort (map providerRecordFile [neighborKey, neighborShareKey])
            before <- snapshotProviderRecords host
            let retained = filter ((`elem` neighborFiles) . fst) before
            deleted <- withProviderOwnershipEntry store $ \session ->
                Owned.deleteRetainedOwnedInstance config session instanceKey owned
            deleted @?= Owned.DeleteRemoved
            heldInstance host (Owned.ownedInstanceName owned) >>= (@?= Nothing)
            heldInstance host (Owned.ownedInstanceName neighbor) >>= (@?= neighborBefore)
            snapshotProviderRecords host >>= (@?= retained)
            durableRecords host >>= (@?= neighborFiles)
            forM_ (instanceKey : shareKeys) $ \key -> do
                observed <- withProtectedEntry store (\session -> readProtectedRecord session key)
                observed @?= Right Nothing
            mutationsOf host "delete" >>= (@?= 1)
    , testCase "retained provider deletion refuses a noncanonical device record key" $
        withFakeHost $ \host -> do
            store <- expectRight =<< openProtectedStore (statePath host)
            config <- resolvedHostConfig
            let owned = providerRecordInstance "Guard.Vm_A"
            instanceKey <- provisionRecordInstance config store owned
            invalidKey <- expectRight (mkRecordKey (recordKeyText instanceKey <> recordTupleSeparator <> "device._"))
            _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session invalidKey ExpectAbsent "not an ownership record")
            before <- snapshotProviderRecords host
            attempted <- expectRight =<< withProtectedEntry store (\session -> Right <$> Owned.deleteRetainedOwnedInstance config session instanceKey owned)
            case attempted of
                Left (Owned.ProviderOwnershipStore (ProtectedInvalid reason)) ->
                    reason @?= "the provider device record key is not canonical for this instance"
                other -> assertFailure ("expected a canonical-device-key refusal, got " <> show other)
            snapshotProviderRecords host >>= (@?= before)
            held <- heldInstance host (Owned.ownedInstanceName owned)
            assertBool "the refused deletion removed the instance" (maybe False (const True) held)
            mutationsOf host "delete" >>= (@?= 0)
    ]

providerRecordInstance :: String -> Owned.OwnedProviderInstance
providerRecordInstance name =
    Owned.OwnedProviderInstance name imageName name (ProviderSizing 2 "2GiB" "12GiB") ("provider-record:" <> Text.pack name)

providerRecordShare :: FakeHost -> Owned.OwnedProviderInstance -> String -> Owned.OwnedProviderShare
providerRecordShare host owned device =
    Owned.OwnedProviderShare owned device (shareRoot host) shareGuestPath ("share-record:" <> Text.pack device)

assertIndependentProviderRecords :: ProtectedStore -> [RecordKey] -> IO ()
assertIndependentProviderRecords store keys = do
    Map.size (Map.fromList [(Text.toLower (recordKeyText key), ()) | key <- keys]) @?= length keys
    forM_ (zip keys [1 :: Int ..]) $ \(key, index) -> do
        written <- withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord session key ExpectAbsent (payload index)
        recordVersionWord <$> written @?= Right 1
    forM_ (zip keys [1 :: Int ..]) $ \(key, index) -> do
        observed <- withProtectedEntry store $ \session -> readProtectedRecord session key
        fmap (fmap protectedRecordBytes) observed @?= Right (Just (payload index))
  where
    payload index = TextEncoding.encodeUtf8 ("independent provider row " <> Text.pack (show index))

withProviderOwnershipEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either Owned.ProviderOwnershipFault result)) ->
    IO result
withProviderOwnershipEntry store action = do
    entered <- withProtectedEntry store (\session -> Right <$> action session)
    expectRight entered >>= expectRight

provisionRecordInstance :: HostConfig -> ProtectedStore -> Owned.OwnedProviderInstance -> IO RecordKey
provisionRecordInstance config store owned = do
    key <- expectRight (Owned.ownedInstanceRecordKey owned)
    provisioned <- withProviderOwnershipEntry store $ \session -> Owned.provisionOwnedInstance config session key owned
    case provisioned of
        Owned.ProvisionCreated _ -> pure key
        other -> assertFailure ("expected a fresh fixture instance, got " <> show other)

attachRecordShare :: HostConfig -> ProtectedStore -> Owned.OwnedProviderShare -> IO RecordKey
attachRecordShare config store share = do
    key <- expectRight (Owned.ownedShareRecordKey share)
    attached <- withProviderOwnershipEntry store $ \session -> Owned.attachOwnedShare config session key share
    attached @?= Owned.ShareAttached
    pure key

providerRecordFile :: RecordKey -> FilePath
providerRecordFile key = Text.unpack (recordKeyText key) <> ".rec"

snapshotProviderRecords :: FakeHost -> IO [(FilePath, ByteString.ByteString)]
snapshotProviderRecords host = do
    paths <- durableRecords host
    traverse (\path -> (,) path <$> ByteString.readFile (statePath host </> "records" </> path)) paths

providerRuntimePackageCase :: IO ()
providerRuntimePackageCase = providerRuntimePackageCaseWithRetry False

providerRuntimePackageCaseWithRetry :: Bool -> IO ()
providerRuntimePackageCaseWithRetry retryAfterConsumption = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withProvisionedProvider backend $ \execution planned _ provisioned -> do
            gate <- providerGate execution
            result <-
                resolveEitherIO $
                    withPreparedProviderReady execution planned provisioned (providerStartableAfterProvision provisioned) gate $ \prepared -> do
                        call <- readyCall backend prepared
                        case settleProviderReady prepared call of
                            Left failure -> pure (Left failure)
                            Right advance ->
                                do
                                    first <- register 100
                                    either (assertFailure . show) (assertPackageGateCommitment gate) first
                                    retry <- register 100
                                    stale <- register 101
                                    carried <- carryRunningProviderSettlement execution advance "provider-adapter-1"
                                    fresh <-
                                        withFreshRunningProviderDependency
                                            execution
                                            "production"
                                            (providerBackendBinding (underTestBackend backend))
                                            "core:deploy-vm"
                                            "runtime://provider/fresh-readiness"
                                            99
                                            "nonce-1"
                                            (const ())
                                    afterUse <- if retryAfterConsumption then register 100 else pure retry
                                    beforeReplay <- recordedGuestInvocations (hostRoot host)
                                    replay <-
                                        withFreshRunningProviderDependency
                                            execution
                                            "production"
                                            (providerBackendBinding (underTestBackend backend))
                                            "core:deploy-vm"
                                            "runtime://provider/fresh-readiness"
                                            99
                                            "nonce-1"
                                            (const ())
                                    recordedGuestInvocations (hostRoot host) >>= (@?= beforeReplay)
                                    when retryAfterConsumption (replay @?= dependencyReplayRefusal)
                                    when retryAfterConsumption $ case stale of
                                        Left (Conflict (ConflictDetail key _ _ _)) -> key @?= "core:deploy-vm"
                                        other -> assertFailure ("a changed provider package must conflict: " <> show other)
                                    expired <-
                                        withFreshRunningProviderDependency
                                            execution
                                            "production"
                                            (providerBackendBinding (underTestBackend backend))
                                            "core:deploy-vm"
                                            "runtime://provider/fresh-readiness"
                                            100
                                            "nonce-2"
                                            (const ())
                                    pure $ do
                                        package <- first
                                        retryPackage <- retry
                                        afterUsePackage <- afterUse
                                        carried
                                        fresh
                                        if package /= retryPackage || package /= afterUsePackage
                                            then Left (Failure (FailureDetail "register provider runtime dependency" "exact retry changed the package" DoNotRetry))
                                            else case stale of
                                                Left _
                                                    | either (const True) (const False) replay
                                                        && either (const True) (const False) expired ->
                                                        Right package
                                                    | otherwise -> Left (Failure (FailureDetail "recover provider runtime dependency" "replay or expiry was accepted" DoNotRetry))
                                                Right _ -> Left (Failure (FailureDetail "register provider runtime dependency" "a changed package replaced the pending commitment" DoNotRetry))
                              where
                                register expiry =
                                    registerRunningProviderDependencyPackage
                                        (underTestBackend backend)
                                        execution
                                        "production"
                                        gate
                                        prepared
                                        advance
                                        "runtime://provider/fresh-readiness"
                                        expiry
            void (either (assertFailure . show) pure result)

dependencyReplayRefusal :: Either ReconcileError ()
dependencyReplayRefusal = Left (Failure (FailureDetail "fresh provider dependency probe"
    "runtime dependency probe nonce has already been consumed" ReprobeBeforeRetry))

providerShareRegistrationReplayCase :: IO ()
providerShareRegistrationReplayCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ _ _ execution planned running gate prepared -> do
            called <- shareCall backend prepared
            settled <- expectRight (settleProviderShare Nothing prepared called)
            withProviderShareSettlement settled
                (\managed _ -> do
                    managedProviderShareCallDigest managed @?= preparedProviderBindingCallDigest (preparedProviderShareBinding prepared)
                    withProviderShareDependency (underTestBackend backend) prepared managed (const ()) @?= Right ()
                    otherSpec <- expectRight (mkProviderShareSpec (shareRoot host) "/srv/another-share")
                    substitution <- withPreparedProviderShare execution planned
                        (preparedProviderShareHandle prepared) running (TestDependency.dependencyProbeWithKind ProbeKernel.ProviderRespondingKind (pure (Right 17)))
                        otherSpec gate $ \otherPrepared ->
                            case withProviderShareDependency (underTestBackend backend) otherPrepared managed (const ()) of
                                Left (Conflict _) -> pure ()
                                other -> assertFailure ("a different share declaration was accepted: " <> show other)
                    either (assertFailure . show) id substitution
                    carryProviderShareSettlement execution managed "share-replay-v1" >>= expectRight
                    let register expiry = registerProviderShareDependencyPackage
                            (underTestBackend backend) execution "production" gate prepared managed
                            "runtime://provider-share/retained-nonce" expiry
                        probe nonce = withFreshCarriedProviderShareDependency execution "production"
                            (Execution.stepExecutionOperationKey execution)
                            "runtime://provider-share/retained-nonce" 99 nonce (\_ _ -> ())
                    package <- register 100 >>= expectRight
                    assertPackageGateCommitment gate package
                    probe "share-consumed" >>= (@?= Right ())
                    before <- snapshotProviderRecords host
                    mutations <- FakeProvider.recordedProviderMutations (hostRoot host)
                    register 100 >>= expectRight >>= (@?= package)
                    probes <- recordedGuestInvocations (hostRoot host)
                    probe "share-consumed" >>= (@?= dependencyReplayRefusal)
                    recordedGuestInvocations (hostRoot host) >>= (@?= probes)
                    mismatch <- register 101
                    case mismatch of
                        Left (Conflict _) -> pure ()
                        other -> assertFailure ("a changed share package must conflict: " <> show other)
                    probe "share-fresh" >>= (@?= Right ())
                    writeFile (FakeProvider.providerToolStatePath (hostRoot host) </> "share-mount-answer") "ext4\n"
                    wrongMount <- probe "share-wrong-mount"
                    case wrongMount of
                        Left _ -> pure ()
                        Right () -> assertFailure "a non-virtiofs guest mount was accepted"
                    writeFile (FakeProvider.providerToolStatePath (hostRoot host) </> "share-mount-answer") "virtiofs\n"
                    snapshotProviderRecords host >>= (@?= before)
                    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= mutations)
                    FakeProvider.alterInstance (hostRoot host) vmName
                        (\held -> held{FakeProvider.instanceDevices = []})
                    missing <- probe "share-missing"
                    case missing of
                        Left _ -> pure ()
                        Right () -> assertFailure "an absent share was repaired by a dependency probe"
                    snapshotProviderRecords host >>= (@?= before)
                    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= mutations)
                    held <- heldInstance host vmName
                    fmap FakeProvider.instanceDevices held @?= Just [])
                (\_ _ _ _ -> assertFailure "the share replay fixture unexpectedly remained foreign")

-- This case's other-owner fact is the ordinary native observation field on the
-- canonical runtime-probe response wire. The real package, carried receipt,
-- request verifier, invocation service and recovery path remain in use.
carriedProviderGenerationMismatchCase :: IO ()
carriedProviderGenerationMismatchCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withPreparedProviderFixtureCarrier backend 17 $ \carrier execution planned _ preparedProvision -> do
            provisionCallResult <- provisionCall backend preparedProvision
            settled <- expectRight (settleProviderProvision Nothing preparedProvision provisionCallResult)
            withProviderProvisionSettlement settled
                (\provisioned _ -> do
                    gate <- providerGate execution
                    nested <- resolveEitherIO $
                        withPreparedProviderReady execution planned provisioned
                            (providerStartableAfterProvision provisioned) gate $ \prepared -> do
                                call <- readyCall backend prepared
                                advance <- expectRight (settleProviderReady prepared call)
                                _ <- registerRunningProviderDependencyPackage
                                    (underTestBackend backend) execution "production" gate prepared advance
                                    "runtime://provider/generation-mismatch" 100 >>= expectRight
                                carryRunningProviderSettlement execution advance "provider-adapter-1" >>= expectRight
                                config <- resolvedHostConfig
                                nativeReport <- interpretHostCommand config
                                    (ProviderCommand.readInstanceConfigCommand vmName ProviderCommand.providerIdentityConfigKey)
                                nativeValue <- expectRight (ProviderReport.classifyProviderIdentity nativeReport)
                                native <- maybe (assertFailure "the real provider query returned no identity") pure nativeValue
                                let expectedVersion = ProviderReport.identityObservationVersion
                                        (Text.unpack (Ownership.objectIdentityText native))
                                    changedVersion
                                        | expectedVersion == 1 = 2
                                        | expectedVersion `mod` 10 == 0 = expectedVersion + 1
                                        | otherwise = expectedVersion - 1
                                    scalar :: Word64 -> ByteString.ByteString
                                    scalar value = let digits = show value
                                        in TextEncoding.encodeUtf8 (Text.pack (show (length digits) <> ":" <> digits))
                                    expectedScalar = scalar expectedVersion
                                    changedScalar = scalar changedVersion
                                assertBool "a native observation was replaced by the logical generation" (expectedVersion /= 17)
                                positive <- withFreshRunningProviderHandle execution "production"
                                    (providerBackendBinding (underTestBackend backend)) "core:deploy-vm"
                                    "runtime://provider/generation-mismatch" 99 "native-positive"
                                    (\_ managed _ -> managedProviderGeneration managed)
                                positive @?= Right 17
                                requests <- newIORef (0 :: Int)
                                callbacks <- newIORef (0 :: Int)
                                let (_, _, services, _) = ExecutionCore.resourceCarrierCoreRefs carrier
                                    rawReply retained raw = do
                                        modifyIORef' requests (+ 1)
                                        answer <- retained raw
                                        pure $ do
                                            bytes <- answer
                                            if ByteString.length expectedScalar == ByteString.length changedScalar
                                                && ByteString.isSuffixOf expectedScalar bytes
                                                then Right (ByteString.take (ByteString.length bytes - ByteString.length expectedScalar) bytes <> changedScalar)
                                                else Left "the actual native reply did not match its independently queried identity"
                                registeredServices <- readIORef services
                                length registeredServices @?= 1
                                modifyIORef' services (map (\(route, commitment, retained) ->
                                    if route == "runtime://provider/generation-mismatch"
                                        then (route, commitment, rawReply retained)
                                        else (route, commitment, retained)))
                                recovered <- withFreshCarriedRunningProviderDependency execution
                                    "production" "core:deploy-vm" "runtime://provider/generation-mismatch"
                                    99 "wrong-generation-1" (\_ _ -> modifyIORef' callbacks (+ 1))
                                outcome <- case recovered of
                                    Left failure -> pure (Left failure)
                                    Right action -> action >> pure (Right ())
                                outcome @?= Left (Conflict (ConflictDetail "core:deploy-vm"
                                    ("native observation version=" <> Text.pack (show expectedVersion))
                                    ("native observation version=" <> Text.pack (show changedVersion))
                                    "reconcile the provider identity before using its dependency"))
                                readIORef requests >>= (@?= 1)
                                readIORef callbacks >>= (@?= 0)
                                pure (Right () :: Either ReconcileError ())
                    expectRight nested)
                (\_ _ _ _ -> assertFailure "the generation fixture unexpectedly remained foreign")

{- | The Direct root's admission, applied to every observation it refuses.

Five facts and five refusals, each reached by handing the decision a value: the
admission is a total function of what this host answered, so no branch of it
needs a root that actually has the property under test (§ NN).  The observation
itself is taken against the real kernel by 'observeDirectRoot', which the
Direct readiness cases exercise.
-}
directRootAdmissionCase :: IO ()
directRootAdmissionCase = do
    admitDirectRoot root admissible @?= Right ()
    refuses "not absolute" "is not absolute on this host" admissible{directRootAbsolute = False}
    refuses "a symbolic link" "is a symbolic link rather than the directory it names" admissible{directRootSymbolicLink = True}
    refuses "not a directory" "is not a directory" admissible{directRootDirectory = False}
    refuses "not canonical" "is not the canonical path this host resolves it to" admissible{directRootCanonical = False}
    refuses "not accessible" "is not readable, writable, and searchable" admissible{directRootAccessible = False}
  where
    root = "/srv/hostbootstrap"
    admissible =
        DirectRootObservation
            { directRootAbsolute = True
            , directRootSymbolicLink = False
            , directRootDirectory = True
            , directRootCanonical = True
            , directRootAccessible = True
            }
    refuses label reason observed = case admitDirectRoot root observed of
        Left refusal -> assertBool ("the " <> label <> " fact reports its own reason: " <> Text.unpack refusal)
            (Text.isInfixOf reason refusal)
        Right () -> assertFailure ("the Direct root admission admitted " <> label)

{- | The backend holds no execution seam, and the tree carries no name for one.

§ NN's second non-evidence is an injected seam standing in for the subject a gate
claims to cover, so the guard is not that the backend /prefers/ the interpreter
but that there is nothing else it could reach a process through: the module
interprets its described commands, starts no process of its own, and no
production source names the executor record, its request, or either of its
fields.
-}
backendHasNoExecutionSeamCase :: IO ()
backendHasNoExecutionSeamCase = do
    cwd <- getCurrentDirectory
    root <-
        findRepoRoot cwd
            >>= maybe (assertFailure ("could not locate repo root from " <> cwd)) pure
    let packageRoot = root </> "core" </> "hostbootstrap-core"
        providerRoot =
            packageRoot </> "src" </> "HostBootstrap" </> "Substrate" </> "Provider"
        backendPath = providerRoot </> "Backend.hs"
        ownershipPath = providerRoot </> "Ownership.hs"
        executorIdentifiers =
            [ "ProviderBackendExec"
            , "ProviderBackendRequest"
            , "ProviderBackendRequestView"
            , "ProviderBackendProcess"
            , "runProviderBackendExec"
            , "waitProviderBackendExec"
            , "providerBackendRequestView"
            ]
        spawnerIdentifiers =
            [ "runCaptured"
            , "runBoundedGrouped"
            , "runBoundedGroupedWithInput"
            ]
    backendSource <- readFile' backendPath
    ownershipSource <- readFile' ownershipPath
    assertBool
        "the provider backend interprets its described commands"
        (SourceGuard.importsModule "HostBootstrap.Effect.Interpreter" backendSource)
    assertBool
        "the provider backend starts a process of its own"
        (not (SourceGuard.importsModule "System.Process" backendSource))
    SourceGuard.moduleImportTokens "HostBootstrap.Effect.Run" backendSource
        @?= Just
            (SourceGuard.haskellTokens "CapturedRun (capturedExit, capturedStderr, capturedStdout)")
    forM_ [(backendPath, backendSource), (ownershipPath, ownershipSource)] $ \(path, source) ->
        forM_ spawnerIdentifiers $ \identifier ->
            assertBool
                (takeFileName path <> " names the process spawner " <> identifier)
                (SourceGuard.countHaskellIdentifier identifier source == 0)
    productionPaths <-
        concat
            <$> traverse
                (SourceGuard.listHaskellSources . (packageRoot </>))
                ["src", "internal"]
    forM_ productionPaths $ \path -> do
        source <- readFile' path
        forM_ executorIdentifiers $ \identifier ->
            assertBool
                (takeFileName path <> " names the retired provider executor " <> identifier)
                (SourceGuard.countHaskellIdentifier identifier source == 0)

-- | This phase's own backend module, read from the tree it is checked against.
readBackendSource :: IO String
readBackendSource = do
    cwd <- getCurrentDirectory
    root <-
        findRepoRoot cwd
            >>= maybe (assertFailure ("could not locate repo root from " <> cwd)) pure
    readFile
        ( root
            </> "core"
            </> "hostbootstrap-core"
            </> "src"
            </> "HostBootstrap"
            </> "Substrate"
            </> "Provider"
            </> "Backend.hs"
        )

directReadyValidationCase :: IO ()
directReadyValidationCase =
    withDirectTools "{\n\t\"schemaVersion\": 2\n}" 0 $ \config root recorded -> do
        result <- runDirectReadyWith config root
        result @?= Right ()
        readRecorded recorded >>= (@?= ["docker manifest inspect images:ubuntu/24.04"])

directReadyAbsentRootCase :: IO ()
directReadyAbsentRootCase =
    withDirectTools "{}" 0 $ \config root recorded -> do
        result <- runDirectReadyWith config (root </> "absent")
        case result of
            Left (Failure detail) ->
                assertBool "the absent root reports its missing directory"
                    (Text.isInfixOf "is not a directory" (failureCause detail))
            other -> assertFailure ("expected absent Direct root refusal, got " <> showEither other)
        readRecorded recorded >>= (@?= [])

directReadyEgressFailureCase :: IO ()
directReadyEgressFailureCase =
    withDirectTools "" 1 $ \config root recorded -> do
        result <- runDirectReadyWith config root
        case result of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected Direct egress failure, got " <> showEither other)
        readRecorded recorded >>= (@?= ["docker manifest inspect images:ubuntu/24.04"])

{- | A real admissible Direct root, beside a recording egress tool.

The root is a directory this case created, so the admission below runs against
the real kernel rather than against a stand-in for it; the egress probe is the
one described command Direct still issues, and the log is what makes "the
admission ran before the egress" an observation rather than an assumption
(§ NN).
-}
withDirectTools ::
    String ->
    Int ->
    (HostConfig -> FilePath -> FilePath -> IO result) ->
    IO result
withDirectTools egressReport egressStatus use =
    withSystemTempDirectory "hostbootstrap-direct-tools" $ \temporary -> do
        root <- canonicalizePath temporary
        let admissible = root </> "data"
        createDirectory admissible
        docker <- getExecutablePath
        dockerRecorded <- FakeProvider.newDockerFixture root Nothing egressReport egressStatus
        FakeProvider.withFakeProviderClient root $
            use
                emptyHostConfig{hcToolPaths = Map.fromList [(Docker, fixtureExe docker)]}
                admissible
                dockerRecorded

readRecorded :: FilePath -> IO [String]
readRecorded path = map trimReturn . lines <$> readFile path
  where
    trimReturn entry = case reverse entry of
        '\r' : rest -> reverse rest
        _ -> entry

{- | A root that is not this host's canonical path for the directory it names.

Taken against the real kernel on every gate host: the path below really does name
the admissible directory and really is not what the host canonicalizes it to, so
the refusal is an observation rather than a stand-in for one (§ NN).  The
symbolic-link refusal the same admission carries is reached by application in
'directRootAdmissionCase', because creating a link is a privilege some outer
hosts withhold and a case that vanished there would be a smaller total rather
than a failed one (§ JJ).
-}
directReadyNonCanonicalCase :: IO ()
directReadyNonCanonicalCase =
    withDirectTools "{}" 0 $ \config root recorded -> do
        let detour = root </> ".." </> takeFileName root
        result <- runDirectReadyWith config detour
        case result of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected noncanonical Direct root refusal, got " <> showEither other)
        readRecorded recorded >>= (@?= [])

runDirectReadyWith :: HostConfig -> FilePath -> IO (Either ReconcileError ())
runDirectReadyWith config root = do
    spec <- either (assertFailure . show) pure (mkDirectHostBackendSpec config root imageName)
    discovered <-
        discoverStrongProviderBackend config spec $ \backend ->
            withProvisionedProvider (ProviderUnderTest backend) $ \execution planned _ provisioned ->
                (() <$)
                    <$> readyProvider
                        (ProviderUnderTest backend)
                        execution
                        planned
                        provisioned
                        (providerStartableAfterProvision provisioned)
    pure (discovered >>= id)

-- These cases reach the production reprobe through the public runtime dependency service.
-- Their clients become unavailable only after the real Ready transition.
incusShareReprobeFailureCase :: IO ()
incusShareReprobeFailureCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndSharePreparation
            ( do
                FakeProvider.alterInstance (hostRoot host) vmName (\held -> held{FakeProvider.instanceDaemonAnswers = False})
                writeFile (FakeProvider.providerCommandsPath (hostRoot host)) ""
            )
            ( \failure -> do
                failure
                    @?= Failure
                        (FailureDetail "fresh provider dependency probe" "Failure (FailureDetail {failedOperation = \"reconcile provider ready\", failureCause = \"the provider command exited 1: provider transport failed\", recoveryDisposition = ReprobeBeforeRetry})" ReprobeBeforeRetry)
                FakeProvider.recordedProviderCommands (hostRoot host)
                    >>= (@?= [["list", vmName, "--format", "csv", "-c", "ns"]])
                mutationsOf host "device-add" >>= (@?= 0)
                held <- heldInstance host vmName
                fmap FakeProvider.instanceDevices held @?= Just []
            )
            host
            backend
            (\_ _ _ _ _ _ _ _ -> assertFailure "an unavailable Incus dependency prepared a share")

incusDependencyReplacementCase :: IO ()
incusDependencyReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend -> do
        records <- newIORef []
        mutations <- newIORef []
        withRunningProviderAndSharePreparation
            (do
                snapshotProviderRecords host >>= writeIORef records
                FakeProvider.recordedProviderMutations (hostRoot host) >>= writeIORef mutations
                replaceHeldInstance host vmName)
            (\failure -> do
                case failure of
                    Conflict (ConflictDetail key _ actual _) -> do
                        key @?= "core:deploy-vm"
                        replaced <- expectRight (Ownership.mkObjectIdentity
                            (TextEncoding.encodeUtf8 (Text.pack FakeProvider.replacementIdentity)))
                        assertBool "the conflict omitted the actual replacement identity"
                            (Ownership.objectIdentityText replaced `Text.isInfixOf` actual)
                    other -> assertFailure ("expected native replacement Conflict, got " <> show other)
                before <- readIORef records
                snapshotProviderRecords host >>= (@?= before)
                priorMutations <- readIORef mutations
                FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= priorMutations)
                heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity))
            host backend (\_ _ _ _ _ _ _ _ -> assertFailure "a replaced provider prepared a share")

directDependencyReplacementCase :: IO ()
directDependencyReplacementCase = withFakeHost $ \host -> do
    let recorded = hostRoot host </> "direct-native-replacement-invocations"
    writeFile recorded ""
    docker <- Fixture.newRecordingFakeTool (hostRoot host) "direct-native-replacement" "{}" 0 recorded
    let config = emptyHostConfig{hcToolPaths = Map.fromList [(Docker, fixtureExe docker)]}
    spec <- expectRight (mkDirectHostBackendSpec config (shareRoot host) imageName)
    discovered <- discoverStrongProviderBackend config spec $ \backend ->
        withRunningProviderAndSharePreparation
            (do
                renameDirectory (shareRoot host) (shareRoot host <> "-original")
                createDirectory (shareRoot host))
            (\failure -> do
                case failure of
                    Conflict (ConflictDetail key _ actual _) -> do
                        key @?= "core:deploy-vm"
                        observed <- withOwnershipRow ownershipRowForHost
                            (\row -> rowObserveIdentity row (shareRoot host)) >>= expectRight
                        identity <- maybe (assertFailure "the replacement root is absent") pure observed
                        actual @?= "identity=" <> Ownership.objectIdentityText identity
                    other -> assertFailure ("expected Direct root Conflict, got " <> show other)
                listDirectory (shareRoot host) >>= (@?= [])
                doesDirectoryExist (shareRoot host <> "-original") >>= (@?= True))
            host (ProviderUnderTest backend)
            (\_ _ _ _ _ _ _ _ -> assertFailure "a replaced Direct root prepared a share")
    discovered @?= Right ()

directShareReprobeFailureCase :: IO ()
directShareReprobeFailureCase = withFakeHost $ \host -> do
    let recorded = hostRoot host </> "direct-share-egress-invocations"
        toolName = "docker-share-reprobe"
    writeFile recorded ""
    docker <- Fixture.newRecordingFakeTool (hostRoot host) toolName "{}" 0 recorded
    let config = emptyHostConfig{hcToolPaths = Map.fromList [(Docker, fixtureExe docker)]}
    spec <- expectRight (mkDirectHostBackendSpec config (shareRoot host) imageName)
    admitted <-
        discoverStrongProviderBackend config spec $ \backend ->
            withRunningProviderAndSharePreparation
                ( do
                    readRecorded recorded >>= (@?= replicate 3 toolName)
                    replacement <- Fixture.newRecordingFakeTool (hostRoot host) toolName "" 1 recorded
                    replacement @?= docker
                )
                ( \failure -> do
                    failure
                        @?= Failure
                            ( FailureDetail
                                "fresh provider dependency probe"
                                "Failure (FailureDetail {failedOperation = \"reprobe Direct provider provisioning egress\", failureCause = \"the exact probe exited 1: \", recoveryDisposition = ReprobeBeforeRetry})"
                                ReprobeBeforeRetry
                            )
                    readRecorded recorded >>= (@?= replicate 4 toolName)
                )
                host
                (ProviderUnderTest backend)
                (\_ _ _ _ _ _ _ _ -> assertFailure "an unavailable Direct dependency prepared a share")
    admitted @?= Right ()



aliasBackendAdmissionCases :: [TestTree]
aliasBackendAdmissionCases =
    [ testCase "alias admission retains an all-Ready capability generation" $
        checkGuestAliasAdmission FakeProvider.ProviderAnswers [] (GuestProviderDiscovery ready ready ready) (Right ())
    , testCase "alias admission names an unavailable guest VM capability" $
        checkGuestAliasAdmission FakeProvider.ProviderAnswers [(1, "", "not found\n")]
            (GuestProviderDiscovery ready unavailable unavailable)
            (Left (Unsupported (UnsupportedDetail "provider VM capability" "not found")))
    , testCase "alias admission accepts unavailable provisioning egress" $
        checkGuestAliasAdmission FakeProvider.ProviderEgressUnavailable []
            (GuestProviderDiscovery ready ready unavailable) (Right ())
    , testCase "alias admission refuses an unclassified provisioning egress failure" $
        checkGuestAliasAdmission FakeProvider.ProviderEgressFailure []
            (GuestProviderDiscovery ready ready (ProviderObservedFailure (ProbeFailure "provider probe" "exit 1: permission denied")))
            (Left (Failure (FailureDetail "provider provisioning egress"
                "ProbeFailure {failedOperation = \"provider probe\", failureCause = \"exit 1: permission denied\"}" DoNotRetry)))
    , testCase "alias admission refuses a discovered Direct capability" directAliasAdmissionCase
    ]
  where
    ready = ProviderObservedReady ()
    unavailable = ProviderObservedUnavailable "not found"

checkGuestAliasAdmission ::
    FakeProvider.ProviderBehaviour ->
    [(Int, String, String)] ->
    GuestProviderDiscovery ->
    Either ReconcileError () ->
    IO ()
checkGuestAliasAdmission behaviour script expectedDiscovery expectedAdmission =
    withFakeHostBehaviour behaviour $ \host ->
        withBackend host $ \backend ->
            withRunningProvider backend $ \_ _ _ running -> do
                config <- resolvedHostConfig
                self <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
                writeFile (guestProbeScriptPath (hostRoot host)) (show script)
                writeFile (FakeProvider.providerCommandsPath (hostRoot host)) ""
                writeFile (FakeProvider.providerMutationsPath (hostRoot host)) ""
                discovered <-
                    resolveEitherIO $
                        withProviderBoundExec (underTestBackend backend) running $ \execution ->
                            discoverProvider running incusProvider execution $ \capability -> do
                                providerCapabilityGeneration capability @?= 17
                                providerCapabilityDiscovery capability @?= ProviderGuestDiscovery expectedDiscovery
                                commands <- FakeProvider.recordedProviderCommands (hostRoot host)
                                (() <$ Alias.discoverStrongAliasBackend config self capability) @?= expectedAdmission
                                FakeProvider.recordedProviderCommands (hostRoot host) >>= (@?= commands)
                                FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
                expectRight discovered

directAliasAdmissionCase :: IO ()
directAliasAdmissionCase =
    withDirectTools "{}" 0 $ \config root recorded -> do
        spec <- expectRight (mkDirectHostBackendSpec config root imageName)
        self <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
        admitted <-
            discoverStrongProviderBackend config spec $ \backend ->
                withRunningProvider (ProviderUnderTest backend) $ \_ _ _ running ->
                    resolveEitherIO $
                        withProviderBoundExec backend running $ \execution ->
                            discoverProvider running (selectProviderKind ProviderDirectHost providerHandles) execution $ \capability -> do
                                providerCapabilityGeneration capability @?= 17
                                providerCapabilityDiscovery capability
                                    @?= ProviderDirectDiscovery
                                        (DirectProviderDiscovery (ProviderObservedReady ()) (ProviderObservedReady ()))
                                (() <$ Alias.discoverStrongAliasBackend config self capability)
                                    @?= Left (Unsupported (UnsupportedDetail
                                        "reconcile provider guest durable alias" "the direct host has no guest alias frame"))
        admitted @?= Right (Right ())
        readRecorded recorded >>= (@?= ["docker manifest inspect images:ubuntu/24.04", "docker manifest inspect images:ubuntu/24.04"])




data NodeAliasMode = NodeAliasCreated | NodeAliasForeign | NodeAliasGateOnce | NodeAliasRerun
    deriving (Eq)

nodeAliasCases :: [TestTree]
nodeAliasCases =
    [ row "the real Chain interpreter settles its prepared guest alias" NodeAliasCreated
    , row "the Chain node returns an unrecorded exact link as foreign" NodeAliasForeign
    , row "the Chain node cannot take its projected alias gate twice" NodeAliasGateOnce
    , row "fresh invocations reconcile the first node alias as Repaired" NodeAliasRerun
    ]
  where
    row label mode =
        conditionalCase ["ProviderBackendSpec", "node guest alias route"]
            FakeProvider.localGuestAliasSupported label (nodeAliasRunCase mode) aliasAcquisitionRowRefusal

nodeAliasExpected :: NodeAliasMode -> FilePath -> [Either ReconcileError Alias.GuestAliasSettlement]
nodeAliasExpected mode path = case mode of
    NodeAliasCreated -> [created]
    NodeAliasRerun -> [created, Right (Alias.GuestAliasReconciled (Changed Repaired))]
    NodeAliasForeign ->
        [Right (Alias.GuestAliasForeignRetained
            (ForeignObservation (Text.pack path)
                (Text.pack path <> " is occupied by an unmanaged exact-looking symbolic link")))]
    NodeAliasGateOnce ->
        [ created
        , Left (Conflict (ConflictDetail "core:deploy-vm/core:copy-source/guest-alias"
            "an open gate for this node's declared projection" "no gate is available for it"
            "declare the projection on this step and take its gate once"))
        ]
  where
    created = Right (Alias.GuestAliasReconciled (Changed Created))

nodeAliasRunCase :: NodeAliasMode -> IO ()
nodeAliasRunCase mode =
    withFakeHostRoleBehaviour "prepared-alias" FakeProvider.ProviderAnswers $ \host ->
        withBackend host $ \backend -> do
            config <- resolvedHostConfig
            self <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
            observations <- newIORef []
            probes <- newIORef (0 :: Int)
            let graph _ frame =
                    either (error . show) id $
                        mkStepPlan
                            [ deployVMStep "provider for the alias node" frame (nodeAliasProviderAction backend)
                            , projectsOperation "core:deploy-vm/core:copy-source/guest-alias" $
                                copySourceStep "managed guest alias node" frame
                                    (nodeAliasShareAction mode host backend observations probes)
                            ]
            if mode == NodeAliasRerun
                then Fixture.withFixtureRootChainPasses 2 graph $ \store plan authority cursor -> do
                    outcome <- Chain.runChainFromFrameWithDescentFailure config self store plan authority cursor (\_ _ _ _ -> pure (Right ()))
                    outcome @?= Right ()
                else Fixture.withFixtureRootChainEvidence graph $ \store plan authority cursor -> do
                    outcome <- Chain.runChainFromFrameWithDescentFailure config self store plan authority cursor (\_ _ _ _ -> pure (Right ()))
                    outcome @?= Right ()
            readIORef observations >>= (@?= nodeAliasExpected mode (hostRoot host </> "node-alias"))
            readIORef probes >>= (@?= if mode == NodeAliasRerun then 2 else 1)
            getSymbolicLinkTarget (hostRoot host </> "node-alias") >>= (@?= shareRoot host)

nodeAliasProviderAction :: ProviderUnderTest backendId -> Execution.StepExecution scope planId -> IO StepObservation
nodeAliasProviderAction backend execution = do
    gate <- Execution.stepExecutionPreparedGate execution >>= maybe (assertFailure "the Chain provider gate is absent") pure
    resolveNested3 $
        withNodeResourceOfKind execution ProviderResourceKind (Execution.stepExecutionOperationKey execution) $ \planned ->
            withNodeObservedResource execution planned (preparedGateFence gate) (preparedGateJournalVersion gate) $ \observed ->
                withPreparedProviderProvision execution (providerBackendBinding (underTestBackend backend)) planned observed gate $ \prepared -> do
                    result <- provisionCall backend prepared
                    settled <- expectRight (settleProviderProvision Nothing prepared result)
                    withProviderProvisionSettlement settled
                        ( \managed _ ->
                            resolveEitherIO $
                                withPreparedProviderReady execution planned managed (providerStartableAfterProvision managed) gate $ \ready -> do
                                    called <- readyCall backend ready
                                    advance <- expectRight (settleProviderReady ready called)
                                    carryCreatedRunningProviderSettlement execution advance "node-alias-provider-v1" >>= expectRight
                                    registered <-
                                        registerRunningProviderDependencyPackage
                                            (underTestBackend backend) execution "production" gate ready advance
                                            "runtime://provider/node-alias-readiness" 100
                                    void (expectRight registered)
                                    pure StepChanged
                        )
                        (\_ _ _ _ -> assertFailure "the Chain provider unexpectedly stayed foreign")

nodeAliasShareAction ::
    NodeAliasMode ->
    FakeHost ->
    ProviderUnderTest backendId ->
    IORef [Either ReconcileError Alias.GuestAliasSettlement] ->
    IORef Int ->
    Execution.StepExecution scope planId ->
    IO StepObservation
nodeAliasShareAction mode host backend observations probes execution = do
    gate <- Execution.stepExecutionPreparedGate execution >>= maybe (assertFailure "the Chain share gate is absent") pure
    shareSpec <- expectRight (mkProviderShareSpec (shareRoot host) (shareRoot host))
    aliasSpec <- expectRight (Alias.mkGuestAliasSpec (hostRoot host </> "node-alias") (shareRoot host))
    opened <-
        withFreshRunningProviderHandle execution "production" (providerBackendBinding (underTestBackend backend))
            "core:deploy-vm" "runtime://provider/node-alias-readiness" 0 "node-alias-readiness-1" $
            \plannedProvider running reprobe ->
                resolveNested2 $
                    withNodeResourceOfKind execution DurableShareResourceKind (Execution.stepExecutionOperationKey execution) $ \plannedShare ->
                        withNodeObservedResource execution plannedShare (preparedGateFence gate) (preparedGateJournalVersion gate) $ \observedShare -> do
                            prepared <-
                                withPreparedProviderShare execution plannedShare observedShare running reprobe shareSpec gate $ \call -> do
                                    called <- shareCall backend call
                                    settled <- expectRight (settleProviderShare Nothing call called)
                                    withProviderShareSettlement settled
                                        ( \managedShare _ -> do
                                            shareDependency <- expectRight (withProviderShareDependency (underTestBackend backend) call managedShare id)
                                            withFixtureAliasBackend (underTestBackend backend) running $ \aliasBackend -> do
                                                writeFile (FakeProvider.providerCommandsPath (hostRoot host)) ""
                                                writeFile (FakeProvider.guestInvocationsPath (hostRoot host)) ""
                                                writeFile (FakeProvider.providerMutationsPath (hostRoot host)) ""
                                                when (mode == NodeAliasForeign) $
                                                    createFileLink (shareRoot host) (hostRoot host </> "node-alias")
                                                let runAliasNode =
                                                        Alias.reconcileNodeGuestAlias execution aliasBackend
                                                            plannedProvider running plannedShare managedShare aliasSpec
                                                            (preparedGateFence gate, preparedGateJournalVersion gate)
                                                            shareDependency
                                                result <- runAliasNode
                                                results <- if mode == NodeAliasGateOnce then do
                                                    second <- runAliasNode
                                                    pure [result, second]
                                                  else pure [result]
                                                previous <- readIORef observations
                                                let expected = nodeAliasExpected mode (hostRoot host </> "node-alias")
                                                results @?= if mode == NodeAliasRerun then take 1 (drop (length previous) expected) else expected
                                                modifyIORef' observations (++ results)
                                                FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
                                                guestCalls <- recordedGuestInvocations (hostRoot host)
                                                length guestCalls @?= 3
                                                modifyIORef' probes (+ length [() | "findmnt" : _ <- guestCalls])
                                                pure StepChanged
                                        )
                                        (\_ _ _ _ -> assertFailure "the Chain share unexpectedly stayed foreign")
                            resolveEitherIO prepared
    resolveEitherIO opened


-- Only the scoped compiler producer can supply these private descriptor changes.
-- The fixture still obtains all provider/share authorities from real Chain actions.
type NodeAliasExecutionChange = forall scope planId. Execution.StepExecution scope planId -> Execution.StepExecution scope planId

type NodeAliasProviderChange =
    forall scope planId providerId providerFrame.
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    PlannedResource scope planId providerId ProviderResource providerFrame

type NodeAliasShareChange =
    forall scope planId shareId shareFrame.
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    PlannedResource scope planId shareId DurableShareResource shareFrame

nodeAliasRefusalCaseWith ::
    String ->
    NodeAliasExecutionChange ->
    NodeAliasProviderChange ->
    NodeAliasShareChange ->
    NodeAliasExecutionChange ->
    IO ()
nodeAliasRefusalCaseWith mode changeExecution changeProvider changeShare asProvider =
    withFakeHost $ \host ->
        withBackend host $ \backend -> do
            config <- resolvedHostConfig
            self <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
            observations <- newIORef []
            probes <- newIORef (0 :: Int)
            let graph _ frame =
                    either (error . show) id $
                        mkStepPlan
                            [ deployVMStep "provider for the refusing alias node" frame (nodeAliasProviderAction backend)
                            , projectsOperation "core:deploy-vm/core:copy-source/guest-alias" $
                                copySourceStep "refusing managed guest alias node" frame
                                    (nodeAliasRefusalAction mode changeExecution changeProvider changeShare asProvider host backend observations probes)
                            ]
            Fixture.withFixtureRootChainEvidence graph $ \store plan authority cursor -> do
                outcome <- Chain.runChainFromFrameWithDescentFailure config self store plan authority cursor (\_ _ _ _ -> pure (Right ()))
                case outcome of
                    Left _ -> pure ()
                    Right () -> assertFailure "the Chain continued after its alias node refused"
            readIORef observations >>= (@?= [Left (nodeAliasRefusalExpected mode)])
            readIORef probes >>= (@?= 0)

nodeAliasRefusalExpected :: String -> ReconcileError
nodeAliasRefusalExpected mode = case mode of
    "missing-provider" -> outside "core:deploy-vm"
    "missing-share" -> outside "core:copy-source"
    "provider-key" -> Conflict (ConflictDetail "core:deploy-vm" "project:other-provider" "core:deploy-vm"
        "use the running provider authority for this exact planned provider")
    "share-key" -> Conflict (ConflictDetail "core:copy-source" "project:other-share" "core:copy-source"
        "use the provider-derived share authority for this exact planned share")
    "stale-generation" -> Conflict (ConflictDetail "core:deploy-vm" "provider-generation=1" "provider-generation=18"
        "rediscover the alias backend from this exact managed provider generation")
    "carried-dependency" -> Conflict (ConflictDetail "core:copy-source"
        "the exact local provider share dependency" "a carried or different share dependency"
        "use the dependency minted from this managed share")
    "share-origin" -> Conflict (ConflictDetail "core:copy-source"
        "a share derived from this exact provider origin" "a share derived from another provider origin"
        "use the provider share settled through this managed provider authority")
    _ -> error ("unknown node alias refusal case: " <> mode)
  where
    outside key = Failure (FailureDetail "resolve node resource"
        ("operation key is neither this node's own nor in its plan dependency prefix: " <> key) DoNotRetry)

nodeAliasRefusalAction ::
    String -> NodeAliasExecutionChange -> NodeAliasProviderChange -> NodeAliasShareChange -> NodeAliasExecutionChange ->
    FakeHost -> ProviderUnderTest backendId ->
    IORef [Either ReconcileError Alias.GuestAliasSettlement] -> IORef Int ->
    Execution.StepExecution scope planId -> IO StepObservation
nodeAliasRefusalAction mode changeExecution changeProvider changeShare asProvider host backend observations probes execution = do
    gate <- Execution.stepExecutionPreparedGate execution >>= maybe (assertFailure "the refusing Chain share gate is absent") pure
    shareSpec <- expectRight (mkProviderShareSpec (shareRoot host) "/srv/node-alias-share")
    aliasSpec <- expectRight (Alias.mkGuestAliasSpec "/srv/node-alias" "/srv/node-alias-share")
    opened <-
        withFreshRunningProviderHandle execution "production" (providerBackendBinding (underTestBackend backend))
            "core:deploy-vm" "runtime://provider/node-alias-readiness" 0 "node-alias-readiness-1" $
            \plannedProvider running reprobe ->
                resolveNested2 $
                    withNodeResourceOfKind execution DurableShareResourceKind (Execution.stepExecutionOperationKey execution) $ \plannedShare ->
                        withNodeObservedResource execution plannedShare (preparedGateFence gate) (preparedGateJournalVersion gate) $ \observedShare -> do
                            prepared <-
                                withPreparedProviderShare execution plannedShare observedShare running reprobe shareSpec gate $ \call -> do
                                    called <- shareCall backend call
                                    settled <- expectRight (settleProviderShare Nothing call called)
                                    withProviderShareSettlement settled
                                        ( \managedShare _ -> do
                                            shareDependency <- expectRight (withProviderShareDependency (underTestBackend backend) call managedShare id)
                                            withFixtureAliasBackend (underTestBackend backend) running $ \originalAliasBackend ->
                                                if mode == "carried-dependency"
                                                    then do
                                                        carryProviderShareSettlement execution managedShare "node-alias-carried" >>= expectRight
                                                        _ <- registerProviderShareDependencyPackage (underTestBackend backend) execution
                                                            "production" gate call managedShare "runtime://provider-share/alias-carried" 100 >>= expectRight
                                                        carried <- withFreshCarriedProviderShareDependency execution "production"
                                                            (Execution.stepExecutionOperationKey execution) "runtime://provider-share/alias-carried"
                                                            0 "alias-carried" $ \_ recovered ->
                                                                nodeAliasRefusalCall mode changeExecution changeProvider changeShare host observations probes
                                                                    -- The public nominal index already rejects this substitution;
                                                                    -- forge only the phantom to exercise the runtime refusal too.
                                                                    execution gate plannedProvider plannedShare managedShare (unsafeCoerce recovered) originalAliasBackend running aliasSpec
                                                        either (assertFailure . show) id carried
                                                else if mode == "stale-generation" || mode == "share-origin"
                                                    then do
                                                        replacement <- fixtureReplacementRunningProvider backend (asProvider execution) plannedProvider running
                                                        managedProviderGeneration replacement @?= 18
                                                        if mode == "stale-generation"
                                                            then nodeAliasRefusalCall mode changeExecution changeProvider changeShare host observations probes
                                                                execution gate plannedProvider plannedShare managedShare shareDependency originalAliasBackend replacement aliasSpec
                                                            else withFixtureAliasBackend (underTestBackend backend) replacement $ \replacementAliasBackend ->
                                                                nodeAliasRefusalCall mode changeExecution changeProvider changeShare host observations probes
                                                                    execution gate plannedProvider plannedShare managedShare shareDependency replacementAliasBackend replacement aliasSpec
                                                    else nodeAliasRefusalCall mode changeExecution changeProvider changeShare host observations probes
                                                        execution gate plannedProvider plannedShare managedShare shareDependency originalAliasBackend running aliasSpec
                                        )
                                        (\_ _ _ _ -> assertFailure "the refusing Chain share unexpectedly stayed foreign")
                            resolveEitherIO prepared
    resolveEitherIO opened

nodeAliasRefusalCall ::
    String -> NodeAliasExecutionChange -> NodeAliasProviderChange -> NodeAliasShareChange ->
    FakeHost -> IORef [Either ReconcileError Alias.GuestAliasSettlement] -> IORef Int ->
    Execution.StepExecution scope planId -> PreparedGate ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned ->
    ProviderShareDependency scope planId shareId ->
    Alias.StrongAliasBackend scope planId providerId backendId capabilityId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    Alias.GuestAliasSpec -> IO StepObservation
nodeAliasRefusalCall mode changeExecution changeProvider changeShare host observations probes
    execution gate plannedProvider plannedShare managedShare shareDependency aliasBackend running aliasSpec = do
    writeFile (FakeProvider.providerCommandsPath (hostRoot host)) ""
    writeFile (FakeProvider.guestInvocationsPath (hostRoot host)) ""
    writeFile (FakeProvider.providerMutationsPath (hostRoot host)) ""
    result <- Alias.reconcileNodeGuestAlias (changeExecution execution) aliasBackend
        (changeProvider plannedProvider) running (changeShare plannedShare) managedShare aliasSpec
        (preparedGateFence gate, preparedGateJournalVersion gate)
        shareDependency
    result @?= Left (nodeAliasRefusalExpected mode)
    modifyIORef' observations (++ [result])
    readIORef probes >>= (@?= 0)
    recordedGuestInvocations (hostRoot host) >>= (@?= [])
    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= [])
    FakeProvider.recordedProviderCommands (hostRoot host) >>= (@?= [])
    pure (StepRefused (Text.pack (show (nodeAliasRefusalExpected mode))))


data AliasAcquisitionCase
    = AliasCreatedCase
    | AliasRepairedCase
    | AliasUnchangedCase
    | AliasForeignCase
    | AliasWrongClaimCase
    | AliasReplacementCase
    | AliasReleaseZeroCase
    | AliasReleaseWrongVersionCase
    | AliasReleaseReplacementCase
    | AliasReleaseSuccessCase
    deriving (Eq)

aliasAcquisitionCases :: [TestTree]
aliasAcquisitionCases =
    [ aliasAcquisitionCase "a first prepared alias acquisition settles Created" AliasCreatedCase
    , aliasAcquisitionCase "a retained prepared alias without proof settles Repaired" AliasRepairedCase
    , aliasAcquisitionCase "a retained prepared alias with verified prior proof settles Unchanged" AliasUnchangedCase
    , aliasAcquisitionCase "an unrecorded exact alias settles Foreign and survives" AliasForeignCase
    , aliasAcquisitionCase "a wrong-target alias record fails without retry" AliasWrongClaimCase
    , aliasAcquisitionCase "a replaced bound alias settles Conflict and survives" AliasReplacementCase
    ]


aliasReleaseCases :: [TestTree]
aliasReleaseCases =
    [ releaseCase "a zero release version refuses before any guest call" AliasReleaseZeroCase
    , releaseCase "a stale release version refuses before any guest call" AliasReleaseWrongVersionCase
    , releaseCase "a prepared release preserves a replaced bound link and its record" AliasReleaseReplacementCase
    , releaseCase "an exact prepared release forgets its record and retains the authority directory" AliasReleaseSuccessCase
    ]
  where
    releaseCase label mode =
        conditionalCase ["ProviderBackendSpec", "prepared guest alias release"]
            FakeProvider.localGuestAliasSupported label
            (runAliasAcquisitionCase mode) aliasAcquisitionRowRefusal


aliasAcquisitionCase :: String -> AliasAcquisitionCase -> TestTree
aliasAcquisitionCase label mode =
    conditionalCase
        ["ProviderBackendSpec", "prepared guest alias acquisition"]
        FakeProvider.localGuestAliasSupported
        label
        (runAliasAcquisitionCase mode)
        aliasAcquisitionRowRefusal

fixtureShippedLinkTarget :: FilePath -> Shipped.ShippedLinkTargetPath
fixtureShippedLinkTarget = either (error . show) id . Shipped.mkShippedLinkTargetPath

aliasAcquisitionRowRefusal :: IO ()
aliasAcquisitionRowRefusal =
    withSystemTempDirectory "hb-prepared-alias-refusal" $ \root -> do
        key <- expectRight (mkRecordKey "prepared-alias.record")
        authority <- expectRight (Shipped.mkShippedAuthorityPath (root </> "authority"))
        target <- expectRight (Shipped.mkShippedTargetPath (root </> "alias"))
        result <-
            Shipped.runShippedOwnership ownershipRowForHost
                (Shipped.mkShippedOwnership authority key target (Shipped.ShipTakeSymbolicLink (fixtureShippedLinkTarget (root </> "target"))))
        case result of
            Shipped.ShippedRefused (Ownership.OwnershipUnsupported _) -> pure ()
            other -> assertFailure ("expected the declared guest-alias row refusal, got " <> show other)

runAliasAcquisitionCase :: AliasAcquisitionCase -> IO ()
runAliasAcquisitionCase mode =
    withFakeHostRoleBehaviour "prepared-alias" FakeProvider.ProviderAnswers $ \host ->
        withBackend host $ \backend ->
            withRunningProviderAndSharePreparationAt
                (shareRoot host) (pure ()) (assertFailure . show) host backend $
                \plan _ plannedProvider shareExecution plannedShare running _ preparedShare -> do
                    attached <- shareCall backend preparedShare
                    settledShare <- expectRight (settleProviderShare Nothing preparedShare attached)
                    withProviderShareSettlement settledShare
                        ( \managedShare _ ->
                            withFixtureAliasBackend (underTestBackend backend) running $ \aliasBackend ->
                                resolveNested2 $
                                    withNodeGuestAliasProjection shareExecution plannedProvider plannedShare $ \plannedAlias edge ->
                                        withNodeObservedResource shareExecution plannedAlias 43 13 $ \observedAlias -> do
                                            let aliasPath = hostRoot host </> "stable-alias"
                                                target = shareRoot host
                                                aliasText = Text.pack aliasPath
                                                planDigest = ProjectPlan.stablePlanSnapshotDigest (ProjectPlan.renderSnapshot plan)
                                            spec <- expectRight (Alias.mkGuestAliasSpec aliasPath target)
                                            let takeAlias prior = do
                                                    gate <- gateFor planDigest (plannedResourceKey plannedAlias)
                                                    preparation <-
                                                        Alias.withPreparedGuestAliasCall
                                                            aliasBackend running managedShare plannedAlias edge observedAlias
                                                            (TestDependency.dependencyProbeWithKind ProbeKernel.DurableShareKind (pure (Right 101))) spec gate $ \call -> do
                                                                result <- Alias.runPreparedGuestAliasCall aliasBackend call
                                                                pure (Alias.aliasCallResultView result, Alias.settlePreparedGuestAliasCall prior call result)
                                                    resolveEitherIO preparation
                                                managedChange expected result = do
                                                    settled <- expectRight result
                                                    Alias.withGuestAliasCallSettlement settled
                                                        ( \managed change -> do
                                                            change @?= expected
                                                            Alias.managedGuestAliasKey managed @?= plannedResourceKey plannedAlias
                                                            Alias.managedGuestAliasGeneration managed @?= 43
                                                            pure (Alias.managedGuestAliasOperationKey managed)
                                                        )
                                                        (\_ _ _ _ -> assertFailure "the prepared alias unexpectedly settled foreign")
                                                releaseFence expected version result = do
                                                    settled <- expectRight result
                                                    Alias.withGuestAliasCallSettlement settled
                                                        ( \managed _ -> do
                                                            Alias.managedGuestAliasObservationVersion managed @?= 13
                                                            callbacks <- newIORef (0 :: Int)
                                                            writeFile (FakeProvider.providerCommandsPath (hostRoot host)) ""
                                                            outcome <-
                                                                case Alias.withPreparedGuestAliasRelease managed version (\_ -> modifyIORef' callbacks (+ 1)) of
                                                                    Left failure -> pure (Left failure)
                                                                    Right action -> action >> pure (Right ())
                                                            outcome @?= Left expected
                                                            readIORef callbacks >>= (@?= 0)
                                                            FakeProvider.recordedProviderCommands (hostRoot host) >>= (@?= [])
                                                        )
                                                        (\_ _ _ _ -> assertFailure "a foreign alias reached prepared release")
                                                releaseAlias result = do
                                                    settled <- expectRight result
                                                    Alias.withGuestAliasCallSettlement settled
                                                        ( \managed _ ->
                                                            resolveEitherIO $
                                                                Alias.withPreparedGuestAliasRelease managed 13
                                                                    (Alias.runPreparedGuestAliasRelease aliasBackend)
                                                        )
                                                        (\_ _ _ _ -> assertFailure "a foreign alias reached prepared release")
                                                assertAliasRefusal expected result =
                                                    case result of
                                                        Left failure -> failure @?= expected
                                                        Right _ -> assertFailure "the prepared alias unexpectedly settled managed"
                                            case mode of
                                                AliasForeignCase -> createFileLink target aliasPath
                                                AliasWrongClaimCase -> publishWrongAliasClaim spec
                                                _ -> pure ()
                                            (firstView, firstSettlement) <- takeAlias Nothing
                                            case mode of
                                                AliasForeignCase -> do
                                                    let foreignObservation = ForeignObservation aliasText
                                                            (aliasText <> " is occupied by an unmanaged exact-looking symbolic link")
                                                    firstView @?= Alias.AliasResultForeign 43 foreignObservation
                                                    settled <- expectRight firstSettlement
                                                    Alias.withGuestAliasCallSettlement settled
                                                        (\_ _ -> assertFailure "the unrecorded alias became managed")
                                                        ( \key generation version observation -> do
                                                            key @?= plannedResourceKey plannedAlias
                                                            generation @?= 43
                                                            version @?= 13
                                                            observation @?= foreignObservation
                                                        )
                                                    getSymbolicLinkTarget aliasPath >>= (@?= target)
                                                AliasWrongClaimCase -> do
                                                    let failure = FailureDetail "read provider guest alias ownership"
                                                            "the symbolic-link record belongs to a different target claim" DoNotRetry
                                                    firstView @?= Alias.AliasResultFailed failure
                                                    assertAliasRefusal (Failure failure) firstSettlement
                                                    doesPathExist aliasPath >>= (@?= False)
                                                _ -> do
                                                    firstView @?= Alias.AliasResultCreated 43
                                                    operationKey <- managedChange (Changed Created) firstSettlement
                                                    pathIsSymbolicLink aliasPath >>= assertBool "the real shipped child created the link"
                                                    getSymbolicLinkTarget aliasPath >>= (@?= target)
                                                    case mode of
                                                        AliasCreatedCase -> pure ()
                                                        AliasRepairedCase -> do
                                                            (view, settlement) <- takeAlias Nothing
                                                            view @?= Alias.AliasResultAlreadyExact 43
                                                            void (managedChange (Changed Repaired) settlement)
                                                        AliasUnchangedCase -> do
                                                            verified <- expectRight $
                                                                verifyPersistedJournalRecord plan plannedAlias observedAlias "acquire"
                                                                    PersistedJournalRecord
                                                                        { persistedPlanDigest = planDigest
                                                                        , persistedFrameKey = plannedResourceFrame plannedAlias
                                                                        , persistedResourceKey = plannedResourceKey plannedAlias
                                                                        , persistedGeneration = 43
                                                                        , persistedOperation = "acquire"
                                                                        , persistedOperationKey = operationKey
                                                                        , persistedRecordVersion = 1
                                                                        , persistedPhase = Committed
                                                                        }
                                                            repeated <- expectRight (withPriorCommitProof verified (\proof -> takeAlias (Just proof)))
                                                            (view, settlement) <- repeated
                                                            view @?= Alias.AliasResultAlreadyExact 43
                                                            void (managedChange Unchanged settlement)
                                                        AliasReleaseZeroCase ->
                                                            releaseFence (Failure (FailureDetail "prepare guest alias release"
                                                                "conditional version must be positive" DoNotRetry)) 0 firstSettlement
                                                        AliasReleaseWrongVersionCase ->
                                                            releaseFence (Conflict (ConflictDetail (plannedResourceKey plannedAlias)
                                                                "observation-version=13" "conditional-version=14"
                                                                "reobserve the managed alias and prepare release with its exact observation version")) 14 firstSettlement
                                                        AliasReleaseReplacementCase -> do
                                                            before <- aliasRecordBytes spec
                                                            conflict <- replaceAliasForConflict aliasPath target
                                                            released <- releaseAlias firstSettlement
                                                            released @?= Left (Conflict conflict)
                                                            aliasRecordBytes spec >>= (@?= before)
                                                            getSymbolicLinkTarget aliasPath >>= (@?= target)
                                                        AliasReleaseSuccessCase -> do
                                                            released <- releaseAlias firstSettlement
                                                            released @?= Right ()
                                                            doesPathExist aliasPath >>= (@?= False)
                                                            let transaction = Alias.guestAliasOwnershipTransaction spec (Shipped.ShipGiveBackSymbolicLink (fixtureShippedLinkTarget target))
                                                            doesDirectoryExist target >>= (@?= True)
                                                            doesDirectoryExist (Shipped.shippedAuthorityPath (Shipped.shippedAuthority transaction)) >>= (@?= True)
                                                            store <- openProtectedStore (Shipped.shippedAuthorityPath (Shipped.shippedAuthority transaction)) >>= expectRight
                                                            record <- withProtectedEntry store (\session -> readProtectedRecord session (Shipped.shippedRecord transaction)) >>= expectRight
                                                            case record of
                                                                Nothing -> pure ()
                                                                Just _ -> assertFailure "the released alias ownership record remained"
                                                        AliasReplacementCase -> do
                                                            conflict <- replaceAliasForConflict aliasPath target
                                                            (view, settlement) <- takeAlias Nothing
                                                            view @?= Alias.AliasResultConflict conflict
                                                            assertAliasRefusal (Conflict conflict) settlement
                                                            getSymbolicLinkTarget aliasPath >>= (@?= target)
                        )
                        (\_ _ _ _ -> assertFailure "the prepared alias fixture share unexpectedly remained foreign")

replaceAliasForConflict :: FilePath -> FilePath -> IO ConflictDetail
replaceAliasForConflict aliasPath target = do
    original <- aliasKernelIdentity aliasPath
    renameFile aliasPath (aliasPath <> ".retired")
    createFileLink target aliasPath
    replacement <- aliasKernelIdentity aliasPath
    assertBool "the original inode remains retained beside its replacement" (original /= replacement)
    let aliasText = Text.pack aliasPath
    pure (ConflictDetail aliasText
        ("identity=" <> Text.pack (show original))
        ("identity=" <> Text.pack (show replacement))
        ("restore the managed symbolic link before retrying (" <> aliasText <> ")"))

aliasRecordBytes :: Alias.GuestAliasSpec -> IO ByteString.ByteString
aliasRecordBytes spec = do
    let transaction = Alias.guestAliasOwnershipTransaction spec (Shipped.ShipTakeSymbolicLink (fixtureShippedLinkTarget (Alias.guestAliasTarget spec)))
    store <- openProtectedStore (Shipped.shippedAuthorityPath (Shipped.shippedAuthority transaction)) >>= expectRight
    record <- withProtectedEntry store (\session -> readProtectedRecord session (Shipped.shippedRecord transaction)) >>= expectRight
    maybe (assertFailure "the retained alias ownership record disappeared") (pure . protectedRecordBytes) record

aliasKernelIdentity :: FilePath -> IO Ownership.ObjectIdentity
aliasKernelIdentity path = do
    observed <- withOwnershipRow ownershipRowForHost (\row -> rowObserveIdentity row path) >>= expectRight
    maybe (assertFailure "the alias kernel identity disappeared") pure observed

publishWrongAliasClaim :: Alias.GuestAliasSpec -> IO ()
publishWrongAliasClaim spec = do
    let transaction = Alias.guestAliasOwnershipTransaction spec (Shipped.ShipTakeSymbolicLink (fixtureShippedLinkTarget (Alias.guestAliasTarget spec)))
        claim = Ownership.mkOwnerClaim (TextEncoding.encodeUtf8 "another-symbolic-link-target")
        record = Ownership.originRecord (Ownership.ReportedObject claim) Ownership.OriginAbsent
    store <- openProtectedStore (Shipped.shippedAuthorityPath (Shipped.shippedAuthority transaction)) >>= expectRight
    written <- withProtectedEntry store $ \session ->
        compareAndSwapProtectedRecord session (Shipped.shippedRecord transaction) ExpectAbsent
            (Ownership.renderOriginRecord record)
    void (expectRight written)


data AliasPreparationExpectation
    = AliasPreparationReady
    | AliasPreparationProbeFailure
    | AliasPreparationBackendGeneration
    | AliasPreparationShareOrigin
    | AliasPreparationPlanMismatch
    deriving (Eq)

aliasPreparationCases :: [TestTree]
aliasPreparationCases =
    [ testCase "a guest alias prepares from its provider and managed share" $
        aliasPreparationCaseWith AliasPreparationReady id
    , testCase "a failing share probe refuses guest alias preparation" $
        aliasPreparationCaseWith AliasPreparationProbeFailure id
    , testCase "an alias backend from the prior provider generation refuses preparation" $
        aliasPreparationCaseWith AliasPreparationBackendGeneration id
    , testCase "a share from the prior provider origin refuses alias preparation" $
        aliasPreparationCaseWith AliasPreparationShareOrigin id
    ]

aliasPlanRefusalCaseWith ::
    ( forall scope planId aliasId aliasFrame.
      PlannedResource scope planId aliasId DurableAliasResource aliasFrame ->
      PlannedResource scope planId aliasId DurableAliasResource aliasFrame
    ) ->
    IO ()
aliasPlanRefusalCaseWith = aliasPreparationCaseWith AliasPreparationPlanMismatch

aliasPreparationCaseWith ::
    AliasPreparationExpectation ->
    ( forall scope planId aliasId aliasFrame.
      PlannedResource scope planId aliasId DurableAliasResource aliasFrame ->
      PlannedResource scope planId aliasId DurableAliasResource aliasFrame
    ) ->
    IO ()
aliasPreparationCaseWith expectation changePlan =
    withFakeHost $ \host ->
        withBackend host $ \backend ->
            withRunningProviderAndShare host backend $ \_ providerExecution plannedProvider shareExecution plannedShare running _ preparedShare -> do
                attached <- shareCall backend preparedShare
                settled <- expectRight (settleProviderShare Nothing preparedShare attached)
                withProviderShareSettlement
                    settled
                    ( \managedShare _ ->
                        withFixtureAliasBackend (underTestBackend backend) running $ \originalAliasBackend -> do
                            if expectation == AliasPreparationBackendGeneration || expectation == AliasPreparationShareOrigin
                                then do
                                    replacement <- fixtureReplacementRunningProvider backend providerExecution plannedProvider running
                                    managedProviderGeneration replacement @?= 18
                                    if expectation == AliasPreparationBackendGeneration
                                        then prepareAliasFixture expectation changePlan host shareExecution plannedProvider plannedShare managedShare originalAliasBackend replacement
                                        else withFixtureAliasBackend (underTestBackend backend) replacement $ \replacementAliasBackend ->
                                            prepareAliasFixture expectation changePlan host shareExecution plannedProvider plannedShare managedShare replacementAliasBackend replacement
                                else prepareAliasFixture expectation changePlan host shareExecution plannedProvider plannedShare managedShare originalAliasBackend running
                    )
                    (\_ _ _ _ -> assertFailure "the alias fixture share unexpectedly remained foreign")

prepareAliasFixture ::
    AliasPreparationExpectation ->
    ( forall aliasScope aliasPlan aliasId aliasFrame.
      PlannedResource aliasScope aliasPlan aliasId DurableAliasResource aliasFrame ->
      PlannedResource aliasScope aliasPlan aliasId DurableAliasResource aliasFrame
    ) ->
    FakeHost ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned ->
    Alias.StrongAliasBackend scope planId providerId backendId capabilityId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IO ()
prepareAliasFixture expectation changePlan host shareExecution plannedProvider plannedShare managedShare aliasBackend currentProvider =
    resolveNested2 $
        withNodeGuestAliasProjection shareExecution plannedProvider plannedShare $ \alias edge ->
            withNodeObservedResource shareExecution alias 43 13 $ \observedAlias -> do
                spec <- expectRight (Alias.mkGuestAliasSpec "/srv/alias" shareGuestPath)
                let selectedAlias = changePlan alias
                    planDigest = Execution.stepExecutionPlanDigest shareExecution
                    probeFailure = Failure (FailureDetail "fresh fixture share probe" "the share is unavailable" ReprobeBeforeRetry)
                    expected = case expectation of
                        AliasPreparationReady -> Right ()
                        AliasPreparationProbeFailure -> Left probeFailure
                        AliasPreparationBackendGeneration ->
                            Left (Conflict (ConflictDetail "core:deploy-vm" "provider-generation=17" "provider-generation=18"
                                "rediscover the alias backend from this exact managed provider generation"))
                        AliasPreparationShareOrigin ->
                            Left (Conflict (ConflictDetail "core:copy-source"
                                "a share derived from this exact provider origin"
                                "a share derived from another provider origin"
                                "use the provider share settled through this managed provider authority"))
                        AliasPreparationPlanMismatch ->
                            Left (Conflict (ConflictDetail (plannedResourceKey alias)
                                ("provider origin plan=" <> planDigest)
                                "alias plan=another-alias-plan"
                                "prepare the alias from the provider origin plan"))
                gate <- gateFor planDigest (plannedResourceKey alias)
                probes <- newIORef (0 :: Int)
                callbacks <- newIORef (0 :: Int)
                writeFile (FakeProvider.providerCommandsPath (hostRoot host)) ""
                outcome <-
                    Alias.withPreparedGuestAliasCall
                        aliasBackend currentProvider managedShare selectedAlias edge observedAlias
                        (TestDependency.dependencyProbeWithKind ProbeKernel.DurableShareKind (modifyIORef' probes (+ 1) >> pure
                            (if expectation == AliasPreparationProbeFailure then Left probeFailure else Right 101)))
                        spec gate (\_ -> modifyIORef' callbacks (+ 1))
                actual <- case outcome of
                    Left refusal -> pure (Left refusal)
                    Right action -> action >> pure (Right ())
                actual @?= expected
                let shouldProbe = expectation == AliasPreparationReady || expectation == AliasPreparationProbeFailure
                readIORef probes >>= (@?= if shouldProbe then 1 else 0)
                readIORef callbacks >>= (@?= if expectation == AliasPreparationReady then 1 else 0)
                FakeProvider.recordedProviderCommands (hostRoot host) >>= (@?= [])

withFixtureAliasBackend ::
    StrongProviderBackend backendId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    (forall capabilityId. Alias.StrongAliasBackend scope planId providerId backendId capabilityId -> IO result) ->
    IO result
withFixtureAliasBackend backend running consume = do
    config <- resolvedHostConfig
    self <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
    discovered <-
        resolveEitherIO $
            withProviderBoundExec backend running $ \execution ->
                discoverProvider running incusProvider execution $ \capability -> do
                    strong <- expectRight (Alias.discoverStrongAliasBackend config self capability)
                    consume strong
    expectRight discovered

fixtureReplacementRunningProvider ::
    ProviderUnderTest backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IO (ManagedProviderHandle scope planId backendId providerId Running)
fixtureReplacementRunningProvider backend execution planned running = do
    stopped <- stopProvider backend execution planned running >>= expectRight
    deleteProvider backend execution planned stopped >>= expectRight
    gate <- providerGate execution
    resolveNested2 $
        withNodeObservedResource execution planned 18 8 $ \observed ->
            withPreparedProviderProvision execution (providerBackendBinding (underTestBackend backend)) planned observed gate $ \prepared -> do
                call <- provisionCall backend prepared
                settled <- expectRight (settleProviderProvision Nothing prepared call)
                withProviderProvisionSettlement
                    settled
                    (\provisioned _ -> readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned) >>= expectRight)
                    (\_ _ _ _ -> assertFailure "the replacement fixture provider unexpectedly remained foreign")


-- End-to-end cases -----------------------------------------------------------

fullLifecycleCase :: IO ()
fullLifecycleCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ execution planned shareExecution _ running shareGate preparedShare -> do
            attached <- shareCall backend preparedShare
            case settleProviderShare Nothing preparedShare attached of
                Left failure -> assertFailure ("share failed: " <> show failure)
                Right settled ->
                    withProviderShareSettlement
                        settled
                        ( \managed _ -> do
                            carried <- carryProviderShareSettlement shareExecution managed "provider-share-v1"
                            carried @?= Right ()
                            registered <-
                                registerProviderShareDependencyPackage
                                    (underTestBackend backend)
                                    shareExecution
                                    "production"
                                    shareGate
                                    preparedShare
                                    managed
                                    "runtime://provider-share/fresh-readiness"
                                    100
                            void (either (assertFailure . show) pure registered)
                            fresh <-
                                withFreshCarriedProviderShareDependency
                                    shareExecution
                                    "production"
                                    (Execution.stepExecutionOperationKey shareExecution)
                                    "runtime://provider-share/fresh-readiness"
                                    99
                                    "share-nonce-1"
                                    (\_ _ -> ())
                            fresh @?= Right ()
                        )
                        (\_ _ _ _ -> assertFailure "share unexpectedly remained foreign")
            stopped <- stopProvider backend execution planned running
            case stopped of
                Left failure -> assertFailure ("stop failed: " <> show failure)
                Right stoppedHandle -> do
                    deleted <- deleteProvider backend execution planned stoppedHandle
                    deleted @?= Right ()
                    heldInstance host vmName >>= (@?= Nothing)
                    durableRecords host >>= (@?= [])

-- | Retained operations derive their authority from the real durable record.
-- The CLI stand-in exposes only raw states and guest answers, never a retained
-- reconciliation result or an injected production executor.
retainedOperationCases :: [TestTree]
retainedOperationCases =
    [ testGroup "retained provider operations"
        [ testCase "a retained stop and ready preserve the bound instance and record" $
            withFakeHost $ \host ->
                withBackend host $ \backend ->
                    withRunningProvider backend $ \_ _ _ _ -> do
                        before <- heldInstance host vmName
                        records <- snapshotProviderRecords host
                        runRetainedProviderStop (underTestBackend backend) >>= (@?= Right ())
                        heldInstance host vmName
                            >>= (@?= fmap (\held -> held{FakeProvider.instanceRunState = "STOPPED"}) before)
                        snapshotProviderRecords host >>= (@?= records)
                        runRetainedProviderReady (underTestBackend backend) >>= (@?= Right ())
                        heldInstance host vmName >>= (@?= before)
                        snapshotProviderRecords host >>= (@?= records)
                        FakeProvider.recordedProviderMutations (hostRoot host)
                            >>= (@?= ["launch", "stop", "start"])
        , testCase "retained ready polls two not-ready guest answers before the third success" $
            withFakeHost $ \host ->
                withBackend host $ \backend ->
                    withRunningProvider backend $ \_ _ _ _ -> do
                        before <- heldInstance host vmName
                        records <- snapshotProviderRecords host
                        probes <- recordedGuestInvocations (hostRoot host)
                        writeFile (notReadyBudgetPath (hostRoot host)) "2\n"
                        runRetainedProviderReady (underTestBackend backend) >>= (@?= Right ())
                        recordedGuestInvocations (hostRoot host) >>= (@?= probes <> replicate 3 ["true"])
                        notReadyBudget (hostRoot host) >>= (@?= 0)
                        heldInstance host vmName >>= (@?= before)
                        snapshotProviderRecords host >>= (@?= records)
                        FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch"])
        , testCase "retained ready reports a terminal guest failure after one probe" $
            withFakeHost $ \host ->
                withBackend host $ \backend ->
                    withRunningProvider backend $ \_ _ _ _ -> do
                        before <- heldInstance host vmName
                        records <- snapshotProviderRecords host
                        probes <- recordedGuestInvocations (hostRoot host)
                        writeFile (guestProbeScriptPath (hostRoot host))
                            (show ([(7, "", "permission denied\n")] :: [(Int, String, String)]))
                        runRetainedProviderReady (underTestBackend backend)
                            >>= (@?= Left (Failure
                                (FailureDetail "start retained provider"
                                    "the provider command exited 7: permission denied" ReprobeBeforeRetry)))
                        recordedGuestInvocations (hostRoot host) >>= (@?= probes <> [["true"]])
                        heldInstance host vmName >>= (@?= before)
                        snapshotProviderRecords host >>= (@?= records)
                        FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch"])
        , testCase "retained stop refuses a same-named replacement" (retainedReplacementCase runRetainedProviderStop)
        , testCase "retained ready refuses a same-named replacement" (retainedReplacementCase runRetainedProviderReady)
        , testCase "retained delete refuses a same-named replacement" (retainedReplacementCase runRetainedProviderDelete)
        , testCase "retained stop fails when the accepted stop leaves the provider running" $
            withFakeHost $ \host ->
                withBackend host $ \backend ->
                    withRunningProvider backend $ \_ _ _ _ -> do
                        before <- heldInstance host vmName
                        records <- snapshotProviderRecords host
                        writeFile (FakeProvider.stopLeavesRunningPath (hostRoot host)) ""
                        runRetainedProviderStop (underTestBackend backend)
                            >>= (@?= Left (Failure
                                (FailureDetail "stop retained provider"
                                    "the provider still reports the instance running" ReprobeBeforeRetry)))
                        heldInstance host vmName >>= (@?= before)
                        snapshotProviderRecords host >>= (@?= records)
                        FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch", "stop"])
        , testCase "all retained Direct operations return their declared Unsupported result" $
            withDirectTools "{}" 0 $ \cfg root recorded -> do
                spec <- expectRight (mkDirectHostBackendSpec cfg root imageName)
                admitted <- discoverStrongProviderBackend cfg spec $ \backend ->
                    checkRetainedUnsupported backend
                        [ ("stop Direct provider", "the local host is not project-owned and cannot be stopped")
                        , ("start Direct provider", "the local host is not project-owned and is already reachable")
                        , ("delete Direct provider", "the local host is not project-owned and cannot be deleted")
                        ]
                expectRight admitted
                readRecorded recorded >>= (@?= [])
        , testCase "all retained Lima operations return their declared Unsupported result" $ do
            spec <- expectRight (mkLimaBackendSpec limaResolvedHostConfig limaProvider limaEnvelope limaShare)
            admitted <- discoverStrongProviderBackend limaResolvedHostConfig spec $ \backend ->
                checkRetainedUnsupported backend
                    [ ("stop retained Lima provider", "Lima reverse is owned by the plan's retained step-declared adapter")
                    , ("start retained Lima provider", "Lima reverse is owned by the plan's retained step-declared adapter")
                    , ("delete retained Lima provider", "Lima reverse is owned by the plan's retained step-declared adapter")
                    ]
            expectRight admitted
        ]
    ]

retainedReplacementCase ::
    (forall backendId. StrongProviderBackend backendId -> IO (Either ReconcileError ())) ->
    IO ()
retainedReplacementCase action =
    withFakeHost $ \host ->
        withBackend host $ \backend ->
            withRunningProvider backend $ \_ _ _ _ -> do
                records <- snapshotProviderRecords host
                probes <- recordedGuestInvocations (hostRoot host)
                replaceHeldInstance host vmName
                replacement <- FakeProvider.readInstances (hostRoot host)
                observed <- expectRight
                    (Ownership.mkObjectIdentity (TextEncoding.encodeUtf8 (Text.pack FakeProvider.replacementIdentity)))
                action (underTestBackend backend)
                    >>= (@?= Left (Conflict
                        (ConflictDetail (Text.pack vmName)
                            "the identity bound by the retained provider record"
                            ("provider stable identity=" <> Ownership.objectIdentityText observed)
                            "inspect the provider name and retained ownership record")))
                FakeProvider.readInstances (hostRoot host) >>= (@?= replacement)
                snapshotProviderRecords host >>= (@?= records)
                recordedGuestInvocations (hostRoot host) >>= (@?= probes)
                FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch"])

checkRetainedUnsupported ::
    StrongProviderBackend backendId ->
    [(Text.Text, Text.Text)] ->
    IO ()
checkRetainedUnsupported backend expected = do
    let actions =
            [ runRetainedProviderStop backend
            , runRetainedProviderReady backend
            , runRetainedProviderDelete backend
            ]
    length expected @?= length actions
    forM_ (zip actions expected) $ \(action, (operation, reason)) ->
        action >>= (@?= Left (Unsupported (UnsupportedDetail operation reason)))

retainedReverseCase :: IO ()
retainedReverseCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \_ _ _ _ -> do
            result <- runRetainedProviderDelete (underTestBackend backend)
            result @?= Right ()
            heldInstance host vmName >>= (@?= Nothing)
            durableRecords host >>= (@?= [])
            FakeProvider.recordedProviderMutations (hostRoot host)
                >>= (@?= ["launch", "stop", "delete"])

{- | Two provisions converge on one instance and launch it at most once.

The store's exclusive entry serializes the entered calls. This case checks
their convergence; "AuthoritySpec" holds the exclusion itself across processes.
Each child reports a thrown failure through its MVar so the parent sees its
message instead of waiting forever for a missing result.
-}
concurrentProvisionCase :: IO ()
concurrentProvisionCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withPreparedProviderFixture backend 17 $ \_ _ _ prepared -> do
            leftResult <- newEmptyMVar
            rightResult <- newEmptyMVar
            void (forkIO (try (provisionCall backend prepared) >>= putMVar leftResult))
            void (forkIO (try (provisionCall backend prepared) >>= putMVar rightResult))
            first <- takeMVar leftResult >>= either (\fault -> assertFailure (displayException (fault :: SomeException))) pure
            second <- takeMVar rightResult >>= either (\fault -> assertFailure (displayException (fault :: SomeException))) pure
            let classify result = case settleProviderProvision Nothing prepared result of
                    Left _ -> "refused" :: String
                    Right settled ->
                        withProviderProvisionSettlement
                            settled
                            (\_ _ -> "managed")
                            (\_ _ _ _ -> "foreign")
                outcomes = sortTwo (classify first) (classify second)
            assertBool
                ("no racing call adopted a foreign instance, got " <> show outcomes)
                ("foreign" `notElem` outcomes)
            assertBool
                ("at least one racing call owns the instance, got " <> show outcomes)
                ("managed" `elem` outcomes)
            mutationsOf host "launch" >>= (@?= 1)

crashRecoveryCase :: IO ()
crashRecoveryCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withPreparedProviderFixture backend 17 $ \_ _ _ prepared -> do
            writeFile (FakeProvider.crashAfterLaunchPath (hostRoot host)) "once\n"
            first <- provisionCall backend prepared
            case settleProviderProvision Nothing prepared first of
                Left (Failure _) -> pure ()
                other -> assertFailure ("expected interrupted first call, got " <> showEither (() <$ other))
            durableRecords host >>= (\records -> assertBool "the origin record survived the interruption" (not (null records)))
            second <- provisionCall backend prepared
            case settleProviderProvision Nothing prepared second of
                Right settled ->
                    withProviderProvisionSettlement settled (\_ _ -> pure ()) (\_ _ _ _ -> assertFailure "recovery must retain ownership")
                Left failure -> assertFailure ("retry failed: " <> show failure)
            mutationsOf host "launch" >>= (@?= 1)

readinessRetryCase :: IO ()
readinessRetryCase = withFakeHost $ \host -> do
    writeFile (notReadyBudgetPath (hostRoot host)) "2\n"
    withBackend host $ \backend ->
        withRunningProvider backend $ \_ _ _ _ ->
            readFile' (notReadyBudgetPath (hostRoot host)) >>= (\held -> lines held @?= ["0"])

-- Ordinary CLI answers observed during actual Incus cold boot; no identity is supplied.
writeNativeAgentWarmup :: FakeHost -> IO ()
writeNativeAgentWarmup host = writeFile (guestProbeScriptPath (hostRoot host)) $
    show ([(255, "", "Error: VM agent isn't currently running\n"),
           (255, "", "Error: VM agent isn't currently running\n"),
           (0, "", "")] :: [(Int, String, String)])

nativeAgentPreparedReadyCase :: IO ()
nativeAgentPreparedReadyCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withProvisionedProvider backend $ \execution planned _ provisioned -> do
            records <- snapshotProviderRecords host
            before <- heldInstance host vmName
            probes <- recordedGuestInvocations (hostRoot host)
            writeNativeAgentWarmup host
            result <- readyProvider backend execution planned provisioned
                (providerStartableAfterProvision provisioned)
            void (expectRight result)
            recordedGuestInvocations (hostRoot host) >>= (@?= probes <> replicate 3 ["true"])
            snapshotProviderRecords host >>= (@?= records)
            heldInstance host vmName >>= (@?= before)
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch"])

nativeAgentRetainedReadyCase :: IO ()
nativeAgentRetainedReadyCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \_ _ _ _ -> do
            records <- snapshotProviderRecords host
            before <- heldInstance host vmName
            probes <- recordedGuestInvocations (hostRoot host)
            runRetainedProviderStop (underTestBackend backend) >>= (@?= Right ())
            writeNativeAgentWarmup host
            runRetainedProviderReady (underTestBackend backend) >>= (@?= Right ())
            recordedGuestInvocations (hostRoot host) >>= (@?= probes <> replicate 3 ["true"])
            snapshotProviderRecords host >>= (@?= records)
            heldInstance host vmName >>= (@?= before)
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch", "stop", "start"])

replacementCase :: IO ()
replacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            replaceHeldInstance host vmName
            result <- stopProvider backend execution planned running
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected replacement conflict, got " <> showEither (() <$ other))
            heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity)
            mutationsOf host "stop" >>= (@?= 0)

shareReadbackCase :: IO ()
shareReadbackCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ _ _ _ _ _ _ prepared -> do
            first <- shareCall backend prepared
            case settleProviderShare Nothing prepared first of
                Left failure -> assertFailure ("first share failed: " <> show failure)
                Right _ -> pure ()
            before <- mutationsOf host "device-add"
            restartedBefore <- mutationsOf host "restart"
            restartedBefore @?= 1
            second <- shareCall backend prepared
            case settleProviderShare Nothing prepared second of
                Right settled ->
                    withProviderShareSettlement settled (\_ _ -> pure ()) (\_ _ _ _ -> assertFailure "exact owned repeat became foreign")
                Left failure -> assertFailure ("exact repeat failed: " <> show failure)
            after <- mutationsOf host "device-add"
            after @?= before
            mutationsOf host "restart" >>= (@?= restartedBefore)
            device <- onlyDevice host
            retargetDevice host vmName device "/srv/replaced"
            changed <- shareCall backend prepared
            case settleProviderShare Nothing prepared changed of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected changed-device conflict, got " <> showEither (() <$ other))
            deviceSource host vmName device >>= (@?= Just "/srv/replaced")

exactRestartBeforeDeleteCase :: IO ()
exactRestartBeforeDeleteCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
            setHeldRunState host vmName "RUNNING"
            result <- deleteProvider backend execution planned stopped
            case result of
                Left (Failure detail) -> recoveryDisposition detail @?= RetrySameOperationKeyAfterFencing
                other -> assertFailure ("expected exact-provider retry, got " <> showEither other)
            mutationsOf host "delete" >>= (@?= 0)
            heldIdentity host vmName >>= (@?= Just ("instance-" <> vmName <> "-1"))

readyObservationReplacementCase :: IO ()
readyObservationReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withProvisionedProvider backend $ \execution planned _ provisioned -> do
            writeFile (FakeProvider.guestInvocationsPath (hostRoot host)) ""
            writeFile (replaceAfterGuestProbePath (hostRoot host)) "once\n"
            result <- readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned)
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected Ready replacement conflict, got " <> showEither other)
            heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity)
            recordedGuestInvocations (hostRoot host) >>= (@?= [["true"]])

stopObservationReplacementCase :: IO ()
stopObservationReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            FakeProvider.armReplacementAfter (hostRoot host) "stop"
            result <- stopProvider backend execution planned running
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected Stop replacement conflict, got " <> showEither (() <$ other))
            heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity)

{- | Clause 3 binds a device that hangs inside an instance, so the instance is
re-observed after the device readback.

The provider accepts the attachment and something else takes the instance's name
before the record binds.  The device readback answers for the device and for
nothing about whose instance now carries it, so the standing re-taken after it is
what refuses: the transaction reports a conflict rather than binding a record of
this run's to a device inside somebody else's object.
-}
shareObservationReplacementCase :: IO ()
shareObservationReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ _ _ _ _ _ _ prepared -> do
            FakeProvider.armReplacementAfter (hostRoot host) "device-add"
            attached <- shareCall backend prepared
            case settleProviderShare Nothing prepared attached of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected a share replacement conflict, got " <> showEither (() <$ other))
            heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity)

shareRestartReplacementCase :: IO ()
shareRestartReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ _ _ _ _ _ _ prepared -> do
            FakeProvider.armReplacementAfter (hostRoot host) "restart"
            attached <- shareCall backend prepared
            case settleProviderShare Nothing prepared attached of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected a post-restart share replacement conflict, got " <> showEither (() <$ other))
            heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity)

{- | Clause 4 compares the identity, so a same-named replacement is not release.

The provider removes this run's instance and something else immediately takes the
name.  The transaction observes an object present at the name that is not the one
it bound, so it forgets nothing: the record stays, and the replacement is left
exactly as it was found.
-}
deleteReplacementLeftStandingCase :: IO ()
deleteReplacementLeftStandingCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
            originKey <- expectRight (Owned.ownedInstanceRecordKey (providerRecordInstance vmName))
            let originPath = statePath host </> "records" </> providerRecordFile originKey
            beforeOrigin <- ByteString.readFile originPath
            prior <- heldInstance host vmName >>= maybe (assertFailure "the owned fixture instance disappeared") pure
            FakeProvider.armReplacementAfter (hostRoot host) "delete"
            result <- deleteProvider backend execution planned stopped
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected a replacement refusal, got " <> showEither other)
            heldInstance host vmName
                >>= (@?= Just (prior{FakeProvider.instanceIdentity = FakeProvider.replacementIdentity}))
            durableRecords host >>= (\records -> assertBool "the record was not forgotten over a present name" (not (null records)))
            ByteString.readFile originPath >>= (@?= beforeOrigin)

{- | The stand-in removes the instance, then loses its response.

Both records survive that failure. The retry re-enters the actual retained
binding and cleans the share before the instance without another delete.
-}
interruptedDeleteRecoveryCase :: Bool -> IO ()
interruptedDeleteRecoveryCase retained = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ execution planned _ _ running _ prepared -> do
            attached <- shareCall backend prepared
            settled <- expectRight (settleProviderShare Nothing prepared attached)
            withProviderShareSettlement settled
                (\_ _ -> pure ())
                (\_ _ _ _ -> assertFailure "the fixture share unexpectedly remained foreign")
            stopped <- stopProvider backend execution planned running >>= expectRight
            before <- snapshotProviderRecords host
            length before @?= 2
            writeFile (FakeProvider.crashAfterDeletePath (hostRoot host)) "once\n"
            let remove =
                    if retained
                        then runRetainedProviderDelete (underTestBackend backend)
                        else deleteProvider backend execution planned stopped
            first <- remove
            case first of
                Left (Failure detail) ->
                    failureCause detail @?= "the provider command exited 1: the provider client died after the delete it performed"
                other -> assertFailure ("expected lost-delete-response failure, got " <> showEither other)
            heldInstance host vmName >>= (@?= Nothing)
            snapshotProviderRecords host >>= (@?= before)
            second <- remove
            second @?= Right ()
            durableRecords host >>= (@?= [])
            FakeProvider.recordedProviderMutations (hostRoot host)
                >>= (@?= ["launch", "device-add", "restart", "stop", "delete"])
            withProvisionedProvider backend $ \_ _ _ _ ->
                heldIdentity host vmName >>= (@?= Just ("instance-" <> vmName <> "-2"))
            FakeProvider.recordedProviderMutations (hostRoot host)
                >>= (@?= ["launch", "device-add", "restart", "stop", "delete", "launch"])

-- | Failed launch reporting leaves a claimed instance and an unbound real record.
interruptedLaunchReleaseCase :: Bool -> IO ()
interruptedLaunchReleaseCase retained = withFakeHost $ \host -> do
    cfg <- resolvedHostConfig
    store <- openProtectedStore (statePath host) >>= expectRight
    let owned = providerRecordInstance vmName
    key <- expectRight (Owned.ownedInstanceRecordKey owned)
    writeFile (FakeProvider.crashAfterLaunchPath (hostRoot host)) "once\n"
    first <- withProtectedEntry store $ \session ->
        Right <$> Owned.provisionOwnedInstance cfg session key owned
    expectRight first
        >>= (@?= Left (Owned.ProviderOwnershipReport
            (ProviderReport.ProviderCommandExited 1 "the provider client died after the launch it performed")))
    boundBefore <- withProtectedEntry store $ \session -> do
        raw <- readProtectedRecord session key
        pure (fmap (fmap protectedRecordBytes) raw)
    raw <- expectRight boundBefore >>= maybe (assertFailure "the unbound launch record is missing") pure
    record <- expectRight (Ownership.parseOriginRecord raw)
    Ownership.originRecordBinding record @?= Nothing
    removed <- withProtectedEntry store $ \session ->
        Right <$> (if retained then Owned.deleteRetainedOwnedInstance else Owned.deleteOwnedInstance)
            cfg session key owned
    expectRight removed >>= (@?= Right Owned.DeleteRemoved)
    heldInstance host vmName >>= (@?= Nothing)
    durableRecords host >>= (@?= [])
    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch", "stop", "delete"])
    _ <- provisionRecordInstance cfg store owned
    heldIdentity host vmName >>= (@?= Just ("instance-" <> vmName <> "-2"))
    FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= ["launch", "stop", "delete", "launch"])

deleteAfterShareReplacementCase :: IO ()
deleteAfterShareReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ execution planned _ _ running _ prepared -> do
            attached <- shareCall backend prepared
            settled <- expectRight (settleProviderShare Nothing prepared attached)
            withProviderShareSettlement settled
                (\_ _ -> pure ())
                (\_ _ _ _ -> assertFailure "the fixture share unexpectedly remained foreign")
            stopped <- stopProvider backend execution planned running >>= expectRight
            before <- snapshotProviderRecords host
            mutations <- FakeProvider.recordedProviderMutations (hostRoot host)
            prior <- heldInstance host vmName >>= maybe (assertFailure "the owned instance disappeared") pure
            FakeProvider.armReplacementAfter (hostRoot host) "device-read"
            result <- deleteProvider backend execution planned stopped
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected fresh pre-delete identity conflict, got " <> showEither other)
            heldInstance host vmName
                >>= (@?= Just (prior{FakeProvider.instanceIdentity = FakeProvider.replacementIdentity}))
            snapshotProviderRecords host >>= (@?= before)
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= mutations)
            commands <- FakeProvider.recordedProviderCommands (hostRoot host)
            assertBool "the replacement receives no delete command"
                (all (\argv -> take 1 argv /= ["delete"]) commands)

deleteRepointedShareCase :: IO ()
deleteRepointedShareCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ execution planned _ _ running _ prepared -> do
            attached <- shareCall backend prepared
            settled <- expectRight (settleProviderShare Nothing prepared attached)
            withProviderShareSettlement settled
                (\_ _ -> pure ())
                (\_ _ _ _ -> assertFailure "the fixture share unexpectedly remained foreign")
            stopped <- stopProvider backend execution planned running >>= expectRight
            device <- onlyDevice host
            key <- expectRight (Owned.ownedShareRecordKey (providerRecordShare host (providerRecordInstance vmName) device))
            bound <- providerRecordBinding host key
            -- Independent Python hashlib vector for disk/source/path with LF framing.
            shareGuestPath @?= "/srv/hostbootstrap/data"
            observed <- expectRight (Ownership.mkObjectIdentity "d6fe6674c13040e1e13559d3d3dab37241ac8889e82b9c6610d9fd70c198f799")
            retargetDevice host vmName device "/srv/replaced"
            before <- snapshotProviderRecords host
            mutations <- FakeProvider.recordedProviderMutations (hostRoot host)
            instanceBefore <- heldInstance host vmName
            result <- deleteProvider backend execution planned stopped
            case result of
                Left (Conflict (ConflictDetail resource expected actual _)) -> do
                    resource @?= managedProviderKey running
                    expected @?= "identity=" <> Ownership.objectIdentityText bound
                    actual @?= "identity=" <> Ownership.objectIdentityText observed
                other -> assertFailure ("expected exact changed-share conflict, got " <> showEither other)
            snapshotProviderRecords host >>= (@?= before)
            heldInstance host vmName >>= (@?= instanceBefore)
            deviceSource host vmName device >>= (@?= Just "/srv/replaced")
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= mutations)
            commands <- FakeProvider.recordedProviderCommands (hostRoot host)
            assertBool "a changed share receives no instance delete"
                (all (\argv -> take 1 argv /= ["delete"]) commands)

deleteAbsentShareCase :: IO ()
deleteAbsentShareCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ execution planned _ _ running _ prepared -> do
            attached <- shareCall backend prepared
            settled <- expectRight (settleProviderShare Nothing prepared attached)
            withProviderShareSettlement settled
                (\_ _ -> pure ())
                (\_ _ _ _ -> assertFailure "the fixture share unexpectedly remained foreign")
            stopped <- stopProvider backend execution planned running >>= expectRight
            records <- snapshotProviderRecords host
            length records @?= 2
            FakeProvider.alterInstance (hostRoot host) vmName
                (\held -> held{FakeProvider.instanceDevices = []})
            before <- FakeProvider.recordedProviderMutations (hostRoot host)
            removed <- deleteProvider backend execution planned stopped
            removed @?= Right ()
            heldInstance host vmName >>= (@?= Nothing)
            durableRecords host >>= (@?= [])
            FakeProvider.recordedProviderMutations (hostRoot host) >>= (@?= (before <> ["delete"]))

unicodeShareBindingCase :: IO ()
unicodeShareBindingCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndSharePreparationAt "/srv/\x0151"
            (pure ()) (assertFailure . show) host backend $
                \_ providerExecution _ shareExecution plannedShare running shareGate firstPrepared -> do
                    firstCall <- shareCall backend firstPrepared
                    firstSettled <- expectRight (settleProviderShare Nothing firstPrepared firstCall)
                    withProviderShareSettlement firstSettled
                        (\_ _ -> pure ())
                        (\_ _ _ _ -> assertFailure "the first UTF-8 fixture share unexpectedly remained foreign")
                    secondSpec <- expectRight (mkProviderShareSpec (shareRoot host) "/srv/Q")
                    second <-
                        withFreshRunningProviderHandle
                            providerExecution
                            "production"
                            (providerBackendBinding (underTestBackend backend))
                            (managedProviderKey running)
                            "runtime://provider/share-preparation"
                            99
                            "unicode-share-second"
                            (\_ freshRunning reprobe ->
                                resolveEitherIO $
                                    withNodeObservedResource shareExecution plannedShare 29 11 $ \observed -> do
                                        preparedResult <-
                                            withPreparedProviderShare
                                                shareExecution plannedShare observed freshRunning
                                                reprobe secondSpec shareGate $ \secondPrepared -> do
                                                    secondCall <- shareCall backend secondPrepared
                                                    secondSettled <- expectRight (settleProviderShare Nothing secondPrepared secondCall)
                                                    withProviderShareSettlement secondSettled
                                                        (\_ _ -> pure ())
                                                        (\_ _ _ _ -> assertFailure "the second UTF-8 fixture share unexpectedly remained foreign")
                                        either (assertFailure . show) id preparedResult)
                    resolveEitherIO second
                    held <- heldInstance host vmName >>= maybe (assertFailure "the UTF-8 fixture instance disappeared") pure
                    let devices = FakeProvider.instanceDevices held
                    length devices @?= 2
                    Map.size (Map.fromList [(name, ()) | (name, _) <- devices]) @?= 2
                    sort [target | (_, properties) <- devices, Just target <- [lookup "path" properties]]
                        @?= sort ["/srv/\x0151", "/srv/Q"]
                    mutationsOf host "device-add" >>= (@?= 2)

-- | Project the identity from the exact bound share record in the real store.
providerRecordBinding :: FakeHost -> RecordKey -> IO Ownership.ObjectIdentity
providerRecordBinding host key = do
    store <- openProtectedStore (statePath host) >>= expectRight
    found <- withProtectedEntry store $ \session -> readProtectedRecord session key
    held <- expectRight found >>= maybe (assertFailure "the bound fixture share record disappeared") pure
    record <- expectRight (Ownership.parseOriginRecord (protectedRecordBytes held))
    maybe (assertFailure "the fixture share record has no binding") pure (Ownership.originRecordBinding record)

-- Prepared fixtures ---------------------------------------------------------

withPreparedProviderFixture ::
    ProviderUnderTest backendId ->
    Word64 ->
    ( forall projectId planId providerId providerFrame operationKey callDigest attempt journalVersion.
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      ResourceHandle (Production projectId) planId providerId ProviderResource Unclassified Observed ->
      PreparedProviderProvision (Production projectId) planId backendId providerId operationKey callDigest attempt journalVersion ->
      IO result
    ) ->
    IO result
withPreparedProviderFixture backend generation consume =
    withPreparedProviderFixtureCarrier backend generation (\_ -> consume)

withPreparedProviderFixtureCarrier ::
    ProviderUnderTest backendId ->
    Word64 ->
    ( forall projectId planId providerId providerFrame operationKey callDigest attempt journalVersion dependencyPayload.
      ExecutionCore.ResourceCarrierCore (Production projectId) planId dependencyPayload ->
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      ResourceHandle (Production projectId) planId providerId ProviderResource Unclassified Observed ->
      PreparedProviderProvision (Production projectId) planId backendId providerId operationKey callDigest attempt journalVersion ->
      IO result
    ) ->
    IO result
withPreparedProviderFixtureCarrier backend generation consume =
    Fixture.withFixtureProjectPlan providerPlan $ \projectPlan ->
        case NonEmpty.toList (ProjectPlan.forward projectPlan) of
            [providerNode] -> do
                carrier <- ExecutionCore.newResourceCarrierCore
                runtime <- ExecutionCore.newStepRuntimeCore carrier
                let execution = stepExecutionFor projectPlan emptyHostConfig runtime providerNode
                    operationKey = Execution.stepExecutionOperationKey execution
                gate <- providerGate execution
                resolveNested3 $
                    withNodeResourceOfKind execution ProviderResourceKind operationKey $ \planned ->
                        withNodeObservedResource execution planned generation 7 $ \observed ->
                            withPreparedProviderProvision execution (providerBackendBinding (underTestBackend backend)) planned observed gate $
                                consume carrier execution planned observed
            nodes -> assertFailure ("expected one provider node, got " <> show (length nodes))

withProvisionedProvider ::
    ProviderUnderTest backendId ->
    ( forall projectId planId providerId providerFrame operationKey callDigest attempt journalVersion.
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      PreparedProviderProvision (Production projectId) planId backendId providerId operationKey callDigest attempt journalVersion ->
      ManagedProviderHandle (Production projectId) planId backendId providerId Provisioned ->
      IO result
    ) ->
    IO result
withProvisionedProvider backend consume =
    withPreparedProviderFixture backend 17 $ \execution planned _ prepared -> do
        call <- provisionCall backend prepared
        settled <- either (assertFailure . show) pure (settleProviderProvision Nothing prepared call)
        withProviderProvisionSettlement
            settled
            (\managed _ -> consume execution planned prepared managed)
            (\_ _ _ _ -> assertFailure "fixture provider unexpectedly remained foreign")

readyProvider ::
    ProviderUnderTest backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId phase ->
    ProviderStartable scope planId backendId providerId phase ->
    IO (Either ReconcileError (ManagedProviderHandle scope planId backendId providerId Running))
readyProvider backend execution planned managed startable = do
    gate <- providerGate execution
    resolveEitherIO $
        withPreparedProviderReady execution planned managed startable gate $ \prepared -> do
            call <- readyCall backend prepared
            pure $ do
                advance <- settleProviderReady prepared call
                pure (withProviderPhaseAdvance advance id)

withRunningProvider ::
    ProviderUnderTest backendId ->
    ( forall projectId planId providerId providerFrame operationKey callDigest attempt journalVersion.
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      PreparedProviderProvision (Production projectId) planId backendId providerId operationKey callDigest attempt journalVersion ->
      ManagedProviderHandle (Production projectId) planId backendId providerId Running ->
      IO result
    ) ->
    IO result
withRunningProvider backend consume =
    withProvisionedProvider backend $ \execution planned preparedProvision provisioned -> do
        ready <- readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned)
        either (assertFailure . show) (consume execution planned preparedProvision) ready

stopProvider ::
    ProviderUnderTest backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IO (Either ReconcileError (ManagedProviderHandle scope planId backendId providerId Stopped))
stopProvider backend execution planned running = do
    gate <- providerGate execution
    resolveEitherIO $
        withPreparedProviderStop execution planned running gate $ \prepared -> do
            call <- stopCall backend prepared
            pure $ do
                advance <- settleProviderStop prepared call
                pure (withProviderPhaseAdvance advance id)

deleteProvider ::
    ProviderUnderTest backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Stopped ->
    IO (Either ReconcileError ())
deleteProvider backend execution planned stopped = do
    gate <- providerGate execution
    resolveEitherIO $
        withPreparedProviderDelete execution planned stopped gate $ \prepared -> do
            call <- deleteCall backend prepared
            pure (() <$ settleProviderDelete prepared call)

withRunningProviderAndShare ::
    FakeHost ->
    ProviderUnderTest backendId ->
    ( forall projectId specDigest planId configId providerId providerFrame shareId shareFrame operationKey callDigest attempt journalVersion.
      ProjectPlan.ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId shareId DurableShareResource shareFrame ->
      ManagedProviderHandle (Production projectId) planId backendId providerId Running ->
      PreparedGate ->
      PreparedProviderShare
        (Production projectId)
        planId
        backendId
        providerId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
      IO result
    ) ->
    IO result
withRunningProviderAndShare = withRunningProviderAndSharePreparation (pure ()) (assertFailure . show)

withRunningProviderAndSharePreparation ::
    IO () ->
    (ReconcileError -> IO result) ->
    FakeHost ->
    ProviderUnderTest backendId ->
    ( forall projectId specDigest planId configId providerId providerFrame shareId shareFrame operationKey callDigest attempt journalVersion.
      ProjectPlan.ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId shareId DurableShareResource shareFrame ->
      ManagedProviderHandle (Production projectId) planId backendId providerId Running ->
      PreparedGate ->
      PreparedProviderShare
        (Production projectId)
        planId
        backendId
        providerId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
      IO result
    ) ->
    IO result
withRunningProviderAndSharePreparation = withRunningProviderAndSharePreparationAt shareGuestPath

withRunningProviderAndSharePreparationAt ::
    FilePath ->
    IO () ->
    (ReconcileError -> IO result) ->
    FakeHost ->
    ProviderUnderTest backendId ->
    ( forall projectId specDigest planId configId providerId providerFrame shareId shareFrame operationKey callDigest attempt journalVersion.
      ProjectPlan.ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId shareId DurableShareResource shareFrame ->
      ManagedProviderHandle (Production projectId) planId backendId providerId Running ->
      PreparedGate ->
      PreparedProviderShare
        (Production projectId)
        planId
        backendId
        providerId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
      IO result
    ) ->
    IO result
withRunningProviderAndSharePreparationAt guestTarget beforePrepare onPreparationRefusal host backend consume =
    Fixture.withFixtureProjectPlan providerSharePlan $ \projectPlan ->
        case NonEmpty.toList (ProjectPlan.forward projectPlan) of
            [providerNode, shareNode] -> do
                carrier <- ExecutionCore.newResourceCarrierCore
                providerRuntime <- ExecutionCore.newStepRuntimeCore carrier
                shareRuntime <- ExecutionCore.newStepRuntimeCore carrier
                let providerExecution = stepExecutionFor projectPlan emptyHostConfig providerRuntime providerNode
                    shareExecution = stepExecutionFor projectPlan emptyHostConfig shareRuntime shareNode
                    providerKey = Execution.stepExecutionOperationKey providerExecution
                    shareKey = Execution.stepExecutionOperationKey shareExecution
                providerGateValue <- providerGate providerExecution
                shareGateValue <- providerGate shareExecution
                shareSpec <- either (assertFailure . show) pure (mkProviderShareSpec (shareRoot host) guestTarget)
                resolveNested3 $
                    withNodeResourceOfKind providerExecution ProviderResourceKind providerKey $ \plannedProvider ->
                        withNodeObservedResource providerExecution plannedProvider 17 7 $ \observedProvider ->
                            withPreparedProviderProvision providerExecution (providerBackendBinding (underTestBackend backend)) plannedProvider observedProvider providerGateValue $ \preparedProvision -> do
                                provisioned' <- provisionCall backend preparedProvision
                                settled <- either (assertFailure . show) pure (settleProviderProvision Nothing preparedProvision provisioned')
                                withProviderProvisionSettlement
                                    settled
                                    ( \provisioned _ ->
                                        resolveEitherIO $
                                            withPreparedProviderReady
                                                providerExecution
                                                plannedProvider
                                                provisioned
                                                (providerStartableAfterProvision provisioned)
                                                providerGateValue
                                                ( \preparedReady -> do
                                                    readied <- readyCall backend preparedReady
                                                    readyAdvance <- either (assertFailure . show) pure (settleProviderReady preparedReady readied)
                                                    registered <-
                                                        registerRunningProviderDependencyPackage
                                                            (underTestBackend backend)
                                                            providerExecution
                                                            "production"
                                                            providerGateValue
                                                            preparedReady
                                                            readyAdvance
                                                            "runtime://provider/share-preparation"
                                                            100
                                                    void (expectRight registered)
                                                    carried <- carryRunningProviderSettlement providerExecution readyAdvance "provider-adapter-1"
                                                    carried @?= Right ()
                                                    withFreshRunningProviderHandle
                                                        providerExecution
                                                        "production"
                                                        (providerBackendBinding (underTestBackend backend))
                                                        providerKey
                                                        "runtime://provider/share-preparation"
                                                        99
                                                        "share-preparation-1"
                                                        ( \freshPlannedProvider running reprobe ->
                                                            resolveNested2 $
                                                                withNodeResourceOfKind shareExecution DurableShareResourceKind shareKey $ \plannedShare ->
                                                                    withNodeObservedResource shareExecution plannedShare 29 11 $ \observedShare -> do
                                                                        beforePrepare
                                                                        preparedResult <-
                                                                            withPreparedProviderShare
                                                                                shareExecution
                                                                                plannedShare
                                                                                observedShare
                                                                                running
                                                                                reprobe
                                                                                shareSpec
                                                                                shareGateValue
                                                                                (consume projectPlan providerExecution freshPlannedProvider shareExecution plannedShare running shareGateValue)
                                                                        either onPreparationRefusal id preparedResult
                                                        ) >>= resolveEitherIO
                                                )
                                    )
                                    (\_ _ _ _ -> assertFailure "fixture provider unexpectedly remained foreign")
            nodes -> assertFailure ("expected two share-plan nodes, got " <> show (length nodes))

-- The backend under test ----------------------------------------------------

{- | The discovered backend, beside the reports its provider produces.

The backend holds no execution seam: it carries the typed host configuration and
reaches every process through the one interpreter.  A fixture that drives real
programs answers through the production call itself; one whose subject is what a
/report/ means supplies the report as a value and reads it through the exported
classifiers, so no case depends on a substitution point having been reached
(§ NN).
-}
newtype ProviderUnderTest backendId = ProviderUnderTest
    { underTestBackend :: StrongProviderBackend backendId
    }

provisionCall ::
    ProviderUnderTest backendId ->
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderProvisionCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
provisionCall underTest prepared = runProviderProvisionCall (underTestBackend underTest) prepared

readyCall ::
    ProviderUnderTest backendId ->
    PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
    IO (ProviderReadyCallResult scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion)
readyCall underTest prepared = runProviderReadyCall (underTestBackend underTest) prepared

stopCall ::
    ProviderUnderTest backendId ->
    PreparedProviderStop scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderStopCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
stopCall underTest prepared = runProviderStopCall (underTestBackend underTest) prepared

shareCall ::
    ProviderUnderTest backendId ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    IO (ProviderShareCallResult scope planId backendId providerId shareId operationKey callDigest attempt journalVersion)
shareCall underTest prepared = runProviderShareCall (underTestBackend underTest) prepared

deleteCall ::
    ProviderUnderTest backendId ->
    PreparedProviderDelete scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderDeleteCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
deleteCall underTest prepared = runProviderDeleteCall (underTestBackend underTest) prepared

-- | Guest vectors observed by this spec's protocol fixtures.
recordedGuestInvocations :: FilePath -> IO [[String]]
recordedGuestInvocations root =
    map read . lines <$> readFile' (FakeProvider.guestInvocationsPath root)

-- The provider this suite drives --------------------------------------------

{- | One fixture root, holding a provider client's state and a protected store.

The client is a real process and the store is the production one, so a lifecycle
case here is the production transaction end to end: nothing between the call and
the object is substituted (§ NN).
-}
data FakeHost = FakeHost
    { hostRoot :: FilePath
    , statePath :: FilePath
    }

withFakeHost :: (FakeHost -> IO result) -> IO result
withFakeHost = withFakeHostBehaviour FakeProvider.ProviderAnswers

withFakeHostBehaviour :: FakeProvider.ProviderBehaviour -> (FakeHost -> IO result) -> IO result
withFakeHostBehaviour = withFakeHostRoleBehaviour backendRole

withFakeHostRoleBehaviour :: String -> FakeProvider.ProviderBehaviour -> (FakeHost -> IO result) -> IO result
withFakeHostRoleBehaviour role behaviour consume =
    withSystemTempDirectory "hostbootstrap-provider-backend" $ \temporary -> do
        root <- canonicalizePath temporary
        let state = root </> "state"
        createDirectoryIfMissing True state
        createDirectoryIfMissing True (root </> "share")
        _ <- FakeProvider.newProviderFixture root role behaviour
        FakeProvider.withFakeProviderClient root (consume (FakeHost root state))

-- | The role this suite declares its provider fixtures under.
backendRole :: String
backendRole = "backend"

{- | What answers inside the instance for this suite's backend fixtures.

The readiness and discovery vectors both ask the guest to run true, so a
different one is a refusal rather than a success: a driver that starts asking the
guest for something new fails this fixture instead of passing through it.
-}
backendGuest :: FakeProvider.GuestHandler
backendGuest root name role argv
    | ["findmnt", "-n", "-o", "FSTYPE", "--mountpoint", _] <- argv = do
        let path = FakeProvider.providerToolStatePath root </> "share-mount-answer"
        present <- doesFileExist path
        answer <- if present then readFile' path else pure "virtiofs\n"
        pure (RawProviderExit ExitSuccess answer "")
    | ["test", "-w", _] <- argv = pure (RawProviderExit ExitSuccess "" "")
    | role == "lima" && elem argv
        [["test", "-d", shareGuestPath], ["test", "-w", shareGuestPath], ["getent", "hosts", "archive.ubuntu.com"]] =
        pure (RawProviderExit ExitSuccess "" "")
    | argv /= ["true"] =
        pure (RawProviderFailure ("the backend fixture guest was asked to run " <> show argv))
    | otherwise = do
        scripted <- nextGuestProbeAnswer root
        case scripted of
            Just answer -> pure answer
            Nothing -> do
                armed <- doesFileExist (replaceAfterGuestProbePath root)
                when armed $ do
                    removeFile (replaceAfterGuestProbePath root)
                    FakeProvider.alterInstance
                        root
                        name
                        (\held -> held{FakeProvider.instanceIdentity = FakeProvider.replacementIdentity})
                remaining <- notReadyBudget root
                if remaining > 0
                    then do
                        writeFile (notReadyBudgetPath root) (show (remaining - 1) <> "\n")
                        pure (RawProviderExit (ExitFailure 1) "" "not ready: the guest is not answering yet\n")
                    else pure (RawProviderExit ExitSuccess "" "")

-- | Raw answers consumed by guest processes, after lifecycle setup has completed.
guestProbeScriptPath :: FilePath -> FilePath
guestProbeScriptPath root = FakeProvider.providerToolStatePath root </> "guest-probe-script"

nextGuestProbeAnswer :: FilePath -> IO (Maybe RawProviderOutcome)
nextGuestProbeAnswer root = do
    let path = guestProbeScriptPath root
    present <- doesFileExist path
    if not present
        then pure Nothing
        else do
            script <- read <$> readFile' path :: IO [(Int, String, String)]
            case script of
                [] -> pure Nothing
                ((code, out, err) : rest) -> do
                    writeFile path (show rest)
                    pure (Just (RawProviderExit (if code == 0 then ExitSuccess else ExitFailure code) out err))

{- | How many more readiness probes answer "not answering yet".

Durable, because the probe runs in a second process and a poll that retried is a
property of what that process answered rather than of a counter beside it.
-}
notReadyBudgetPath :: FilePath -> FilePath
notReadyBudgetPath root = root </> "not-ready-budget"

notReadyBudget :: FilePath -> IO Int
notReadyBudget root = do
    present <- doesFileExist (notReadyBudgetPath root)
    if present
        then do
            held <- readFile' (notReadyBudgetPath root)
            pure (case reads held of [(value, _)] -> value; _ -> 0)
        else pure 0

-- | Arm the guest to be a different instance's by the time its probe returns.
replaceAfterGuestProbePath :: FilePath -> FilePath
replaceAfterGuestProbePath root = root </> "replace-after-guest-probe"

withBackend :: FakeHost -> (forall backendId. ProviderUnderTest backendId -> IO result) -> IO result
withBackend host consume = do
    config <- resolvedHostConfig
    spec <- either (assertFailure . show) pure (incusSpecForConfig config (statePath host))
    discovered <-
        discoverStrongProviderBackend config spec (\backend -> consume (ProviderUnderTest backend))
    either (assertFailure . show) pure discovered

{- | A host configuration whose provider client is this suite's own executable.

§ KK's one interpreter launches whatever the configuration resolves, and the
guest vectors this project crosses with carry whole programs, so a wrapper
script is not an option: the program has to be one that receives the exact
argument vector.  "FakeProvider" explains the arrangement.
-}
resolvedHostConfig :: IO HostConfig
resolvedHostConfig = do
    self <- getExecutablePath
    pure
        HostConfig
            { hcSubstrate = Substrate LinuxCpu Amd64
            , hcToolPaths = Map.fromList [(Incus, fixtureExe self)]
            }

incusSpecForConfig :: HostConfig -> FilePath -> Either ReconcileError ProviderBackendSpec
incusSpecForConfig config state =
    mkIncusBackendSpec vmName imageName vmName config state 2 "2GiB" "12GiB"

-- What the provider and the store are holding ---------------------------------

heldInstance :: FakeHost -> String -> IO (Maybe FakeProvider.ProviderInstance)
heldInstance host = FakeProvider.instanceNamed (hostRoot host)

heldIdentity :: FakeHost -> String -> IO (Maybe String)
heldIdentity host name = fmap (fmap FakeProvider.instanceIdentity) (heldInstance host name)

replaceHeldInstance :: FakeHost -> String -> IO ()
replaceHeldInstance host name =
    FakeProvider.alterInstance
        (hostRoot host)
        name
        (\held -> held{FakeProvider.instanceIdentity = FakeProvider.replacementIdentity})

setHeldRunState :: FakeHost -> String -> String -> IO ()
setHeldRunState host name state =
    FakeProvider.alterInstance
        (hostRoot host)
        name
        (\held -> held{FakeProvider.instanceRunState = state})

retargetDevice :: FakeHost -> String -> String -> String -> IO ()
retargetDevice host name device source =
    FakeProvider.alterInstance
        (hostRoot host)
        name
        ( \held ->
            held
                { FakeProvider.instanceDevices =
                    [ (key, if key == device then ("source", source) : filter ((/= "source") . fst) properties else properties)
                    | (key, properties) <- FakeProvider.instanceDevices held
                    ]
                }
        )

deviceSource :: FakeHost -> String -> String -> IO (Maybe String)
deviceSource host name device = do
    held <- heldInstance host name
    pure (held >>= lookup device . FakeProvider.instanceDevices >>= lookup "source")

onlyDevice :: FakeHost -> IO String
onlyDevice host = do
    held <- heldInstance host vmName
    case fmap (map fst . FakeProvider.instanceDevices) held of
        Just [device] -> pure device
        other -> assertFailure ("expected exactly one attached device, got " <> show other)

mutationsOf :: FakeHost -> String -> IO Int
mutationsOf host verb = countOf verb <$> FakeProvider.recordedProviderMutations (hostRoot host)

-- | The durable records the protected store is holding, by name.
durableRecords :: FakeHost -> IO [FilePath]
durableRecords host = do
    let records = statePath host </> "records"
    present <- doesDirectoryExist records
    if present then sort <$> listDirectory records else pure []

shareRoot :: FakeHost -> FilePath
shareRoot host = hostRoot host </> "share"

{- | Where the guest sees this suite's share.

POSIX on every outer host, because the frame that reads it is the Linux substrate
the provider realizes; the host side is the outer host's own grammar, because the
provider client that mounts it runs there (§ MM).
-}
shareGuestPath :: FilePath
shareGuestPath = "/srv/hostbootstrap/data"

emptyHostConfig :: HostConfig
emptyHostConfig = HostConfig (Substrate LinuxCpu Arm64) Map.empty

fakeResolvedHostConfig :: HostConfig
fakeResolvedHostConfig =
    emptyHostConfig
        { hcToolPaths =
            Map.fromList
                [(Incus, fixtureExe fixtureIncus)]
        }

limaResolvedHostConfig :: HostConfig
limaResolvedHostConfig =
    HostConfig
        (Substrate AppleSilicon Arm64)
        (Map.fromList [(Lima, fixtureExe fixtureLima)])

limaUnresolvedHostConfig :: HostConfig
limaUnresolvedHostConfig = HostConfig (Substrate AppleSilicon Arm64) Map.empty

wsl2ResolvedHostConfig :: HostConfig
wsl2ResolvedHostConfig =
    HostConfig
        (Substrate WindowsGpu Amd64)
        (Map.fromList [(Wsl, fixtureExe fixtureWsl)])

wsl2CpuResolvedHostConfig :: HostConfig
wsl2CpuResolvedHostConfig =
    HostConfig
        (Substrate WindowsCpu Amd64)
        (Map.fromList [(Wsl, fixtureExe fixtureWsl)])

wsl2UnresolvedHostConfig :: HostConfig
wsl2UnresolvedHostConfig = HostConfig (Substrate WindowsGpu Amd64) Map.empty

limaProvider, incusProvider, wsl2Provider :: SubstrateProvider
limaProvider = selectProviderKind ProviderLima providerHandles
incusProvider = selectProviderKind ProviderIncus providerHandles
wsl2Provider = selectProviderKind ProviderWsl2 providerHandles

providerHandles :: VMHandles
providerHandles =
    VMHandles
        { vmhIncus = Incus.IncusVM vmName imageName
        , vmhLima = Lima.LimaVM vmName
        , vmhWsl2 = Wsl2.Wsl2VM vmName
        , vmhGuardPrefix = vmName
        }

limaEnvelope :: ResourceEnvelope
limaEnvelope = ResourceEnvelope{cpu = 2, memory = "4GiB", storage = "40GiB"}

limaShare :: HostPathShare
limaShare = HostPathShare (hostFixturePath "/share") "/srv/hostbootstrap/data" Nothing

{- | The host tools this suite's fixtures name.

Each is rendered onto the host that runs the suite, so the same total 'AbsExe'
constructor production uses admits it on every supported outer host realization
(§ JJ), and the request assertions compare those same values rather than a
POSIX literal the host would call relative.
-}
fixtureIncus :: FilePath
fixtureIncus = hostFixturePath "/usr/bin/incus"

fixtureLima :: FilePath
fixtureLima = hostFixturePath "/usr/bin/limactl"

fixtureWsl :: FilePath
fixtureWsl = hostFixturePath "/Windows/System32/wsl.exe"

providerGate :: Execution.StepExecution scope planId -> IO PreparedGate
providerGate execution = gateFor (Execution.stepExecutionPlanDigest execution) (Execution.stepExecutionOperationKey execution)

providerPlan :: StepPlan
providerPlan = either (error . show) id (mkStepPlan [deployVMStep "provider" testFrame (const (pure StepChanged))])

providerSharePlan :: StepPlan
providerSharePlan =
    either
        (error . show)
        id
        (mkStepPlan [deployVMStep "provider" testFrame (const (pure StepChanged)), projectsOperation "core:deploy-vm/core:copy-source/guest-alias" (copySourceStep "durable share" testFrame (const (pure StepChanged)))])

testFrame :: StepFrame
testFrame = StepFrame "host" "Host"

vmName :: String
vmName = "hostbootstrap-provider-test"

imageName :: String
imageName = "images:ubuntu/24.04"

fixtureExe :: FilePath -> AbsExe
fixtureExe = either error id . mkAbsExe

countOf :: (Eq value) => value -> [value] -> Int
countOf value = length . filter (== value)

sortTwo :: (Ord value) => value -> value -> [value]
sortTwo left right = if left <= right then [left, right] else [right, left]

showEither :: (Show error) => Either error value -> String
showEither = either show (const "Right <opaque>")

resolveEitherIO :: Either ReconcileError (IO result) -> IO result
resolveEitherIO = either (assertFailure . show) id

resolveNested2 :: Either ReconcileError (Either ReconcileError (IO result)) -> IO result
resolveNested2 = either (assertFailure . show) resolveEitherIO

resolveNested3 :: Either ReconcileError (Either ReconcileError (Either ReconcileError (IO result))) -> IO result
resolveNested3 = either (assertFailure . show) (either (assertFailure . show) resolveEitherIO)
