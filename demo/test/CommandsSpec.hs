{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module CommandsSpec (hostCfg, tests) where

import Control.Exception (SomeException, bracket, try)
import Data.Either (isLeft)
import Data.Function ((&))
import Data.List (findIndex, isInfixOf, isSuffixOf, tails)
import qualified Data.Text as T
import qualified Dhall
import HostBootstrap.Cluster.Lifecycle (AcceleratorDaemonPlacement (HostResidentDaemon), AcceleratorIngressPlan (ingressKindListenAddress), ClusterDriver (..), ClusterPlan (clusterConfigFile, clusterDriver, clusterName, dataPath, publishesHostPorts), ClusterProfile (Production, TestCase), acceleratorIngressPlan, profileDataPath, profileDataSegments)
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec), projectCodecSpecDigest)
import HostBootstrap.Config.Fields (
    ScopeKind (ProductionScope),
    WireKind (FullProjectWire, ServiceRoleWire),
    decodeRoleWire,
    frameworkEnvelopeCodec,
    frameworkLocalContext,
    frameworkScopeKind,
    frameworkSpecDigest,
    frameworkWireKind,
    inspectFullConfig,
    inspectLocalContext,
    renderValidatedServiceRequest,
    requestFrameworkValidation,
    requestVerifiedDigest,
    roleCodecSpecDigest,
 )
import HostBootstrap.Config.Vocab (Mount (..))
import HostBootstrap.Context (ContextKind (HostOrchestrator, VMOrchestrator, VMProjectContainer))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Detached (detachedLaunchArguments, detachedLaunchExecutable)
import HostBootstrap.Dhall.Gen (artifactName)
import HostBootstrap.HostTool (absExePath)
import HostBootstrap.Lift (ContainerLift (clExtraArgs, clMounts), LiftContext (..), LiftLayer (ViaContainer), localContext)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot, withCanonicalProjectRoot)
import HostBootstrap.RegistryPlan (
    BlobProbe (ApiVersionProbe),
    BlobRouteObservation (..),
    registryPlanRevision,
    settleBlobRoute,
 )
import HostBootstrap.RoleLifecycle (RoleEffect (DurableStore, NetworkListen, ProcessSpawn))
import HostBootstrap.Service (
    serviceIdText,
    serviceRoleSchemaFamilies,
    serviceVariantNames,
    withFinalizedServiceRegistry,
    withSelectedServiceRequest,
 )
import HostBootstrap.Step (Step, StepFrame (..), StepIdentity (..), StepPlan, chainFrames, frameDescent, frameId, mkStepPlan, postHandoffStepsForFrame, projectStepId, providerResourceDeclarationTargetsChild, renderChainPlan, stepFrame, stepIdentity, stepKind, stepKindName, stepLabel, stepPlanSteps, stepProviderResourceDeclarations)
import HostBootstrap.Substrate (Arch (Amd64, Arm64), Substrate (Substrate), SubstrateName (AppleSilicon, LinuxCpu, LinuxGpu, WindowsCpu, WindowsGpu))
import HostBootstrapDemo.Commands (
    absoluteHostAcceleratorDaemonExePath,
    acceleratorDaemonManifest,
    acceleratorHelmValuesForContext,
    containerPlan,
    demoArtifacts,
    demoBaseImageFor,
    demoChainFor,
    demoDirectParentJoin,
    demoForwardChildPlan,
    demoRegistryPlan,
    demoServices,
    demoTestFrameContext,
    directClusterPresence,
    directClusterTeardownArgs,
    dockerBuildArgsWithVerificationKey,
    foldDemoOperationRole,
    hostAcceleratorDaemonArgs,
    hostAcceleratorDaemonLaunch,
    hostAcceleratorDaemonPowerShellScript,
    hostAcceleratorSubstrate,
    hostDaemonIdentityMatches,
    hostDaemonLifecycleStateConsistent,
    minioClusterEndpoint,
    parseBlobRouteAnswer,
    readHostAcceleratorDaemonPid,
    registryConfigYaml,
    registryEndpoint,
    renderRetainedDaemonOutput,
    renderServiceConfigForContext,
    repoRootOfProjectRoot,
    serviceConfigMapManifest,
    uploadSessionUrl,
    validateAcceleratorReplicaCount,
 )
import HostBootstrapDemo.Config (
    Port,
    ProjectConfig (..),
    RunProfile (HarnessRun),
    WebServiceConfig (WebServiceConfig),
    clusterProfileOf,
    demoDefaultDeployConfig,
    demoDefaultDockerfile,
    demoDefaultMessage,
    demoDefaultResources,
    deriveProjectConfigForKind,
    mkPort,
    projectConfigForRole,
 )
import HostBootstrapDemo.Container (
    baseDigestArgs,
    basePullArgs,
    dockerBuildArgs,
    pinnedBaseReference,
 )
import HostBootstrapDemo.Web.Bridge (writeBridge)
import Numeric.Natural (Natural)
import System.Directory (canonicalizePath, createDirectory, doesFileExist, getTemporaryDirectory, removeFile, removePathForcibly)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, (</>))
import System.IO (hClose, hPutStr, openTempFile)
import System.Info (os)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

expectPlan :: [Step] -> StepPlan
expectPlan = either (error . show) id . mkStepPlan

{- | The rendered schema text up to the accelerator entry, i.e. the web role's
own portion. Used to show a field belongs to one role rather than to every one.
-}
webFamilyOnly :: T.Text -> T.Text
webFamilyOnly = fst . T.breakOn "- service: accelerator"

{- | Admit the demo's own canonical project root. The chain is built under it
(§ X), so a test that inspects the plan must go through the same bracket
production does.
-}
withDemoRoot ::
    (forall rootId. CanonicalProjectRoot scope rootId -> IO a) ->
    IO a
withDemoRoot action = do
    outcome <- withCanonicalProjectRoot ".build/hostbootstrap-demo.dhall" "." action
    either (assertFailure . show) pure outcome

validPort :: Natural -> Port
validPort = either (error . ("invalid test port: " ++)) id . mkPort

substringOffset :: String -> String -> Maybe Int
substringOffset needle = findIndex (isInfixOf needle . take (length needle)) . tails

{- | A @\/v2\/@ answer dressed up as an observation: the status is fine and the
port is right, but the probe was liveness, not a blob request.
-}
apiVersionAnswer :: BlobRouteObservation
apiVersionAnswer =
    BlobRouteObservation
        { observedProbe = ApiVersionProbe
        , observedPort = 30500
        , observedStatus = 200
        , observedRedirect = Nothing
        , observedRevision = registryPlanRevision demoRegistryPlan
        }

tests :: TestTree
tests =
    testGroup
        "CommandsSpec"
        [ testCase "cluster config is derived only from the exact plan slices" $ do
            commandsSource <- readFile "src/HostBootstrapDemo/Commands.hs"
            let rendererSource =
                    maybe
                        ""
                        (`drop` commandsSource)
                        (substringOffset "demoExactRenderedClusterConfig ::" commandsSource)
                exactDerivation =
                    [ "demoExactPlanSlices cfg plan"
                    , "plannedStepFrameId planned"
                    , "frame == T.pack directContainerRuntimeFrameId"
                    , "NvkindDriver"
                    , "KindDriver"
                    , "renderExactClusterConfig driver digest cfg clusterSlice published"
                    ]
                positions = traverse (`substringOffset` rendererSource) exactDerivation
            case positions of
                Nothing -> assertFailure "the command projection lost an exact cluster-config derivation stage"
                Just offsets ->
                    assertBool
                        "cluster config stages are not ordered slice/driver/render"
                        (and (zipWith (<) offsets (drop 1 offsets)))
            assertBool
                "the command projection accepts an independently supplied driver"
                (not ("demoExactRenderedClusterConfig driver" `isInfixOf` rendererSource))
            assertBool
                "the command projection accepts independently supplied ports"
                (not ("demoExactRenderedClusterConfig published" `isInfixOf` rendererSource))
        , testCase "the cluster action adopts exact provider, reconcile, cordon, readiness, and package order" $ do
            commandsSource <- readFile "src/HostBootstrapDemo/Commands.hs"
            let adopter = maybe "" (`drop` commandsSource) (substringOffset "deployKindAction stepCfg execution" commandsSource)
                stages =
                    [ "withFreshCarriedRunningProviderDependency"
                    , "withExecutionOwnedCluster"
                    , "withExactPlanOwnedClusterConfig"
                    , "discoverStrongClusterBackend"
                    , "withPreparedClusterReconcile"
                    , "runClusterReconcileCall"
                    , "carryClusterReconcileSettlement"
                    , "runClusterCordonCall"
                    , "runClusterReadinessCall"
                    , "registerClusterRuntimeDependencyPackage"
                    ]
            offsets <- maybe (assertFailure "the exact cluster adopter lost a required stage") pure (traverse (`substringOffset` adopter) stages)
            assertBool "cluster adoption stages are out of order" (and (zipWith (<) offsets (drop 1 offsets)))
            assertBool "the VM provider route is absent" ("core:deploy-vm" `isInfixOf` adopter && "runtime://provider/demo-vm-readiness" `isInfixOf` adopter)
            assertBool "the Direct provider route is absent" ("providerKey = \"core:deploy-vm\"" `isInfixOf` adopter && "runtime://provider/demo-direct-readiness" `isInfixOf` adopter)
            assertBool "the adopted action still calls the compatibility cluster mutator" (not ("clusterCreate cfg" `isInfixOf` adopter))
        , testCase "the chart action consumes the exact cluster package and generic workload transaction" $ do
            commandsSource <- readFile "src/HostBootstrapDemo/Commands.hs"
            let adopterTail = maybe "" (`drop` commandsSource) (substringOffset "deployChartAction stepCfg execution" commandsSource)
                adopter = maybe adopterTail (`take` adopterTail) (substringOffset "{- | The accelerator hub" adopterTail)
                stages =
                    [ "stepExecutionPreparedGate execution"
                    , "withNodeResourceOfKind execution ClusterResourceKind \"core:deploy-kind\""
                    , "withNodeChartWorkloadResource execution"
                    , "withFreshClusterRuntimeDependency execution"
                    , "withPreparedChartWorkload chart cluster readiness execution values gate"
                    , "runChartWorkloadCall Nothing"
                    ]
            offsets <- maybe (assertFailure "the exact chart adopter lost a required stage") pure (traverse (`substringOffset` adopter) stages)
            assertBool "chart adoption stages are out of order" (and (zipWith (<) offsets (drop 1 offsets)))
            assertBool "the chart adopter still calls the compatibility mutator" (not ("deployChart cfg" `isInfixOf` adopter))
            assertBool "the chart adopter still applies a caller-built ConfigMap" (not ("runOrDieStdin cfg Kubectl [\"apply\"" `isInfixOf` adopter))
        , testCase "the reverse command authenticates exact chart ownership without a forward package" $ do
            commandSource <- readFile "../core/hostbootstrap-core/src/HostBootstrap/Command.hs"
            let productionTail = maybe "" (`drop` commandSource) (substringOffset "runProductionTeardown root validated ctx cfg verb = do" commandSource)
                production = maybe productionTail (`take` productionTail) (substringOffset "_reverseProjection ::" productionTail)
                stages =
                    [ "runRootProjectReverseLifecycleEntry"
                    , "localWorkOperationKey local"
                    , "resourceRecordKey planDigest frame resource"
                    , "readProtectedRecord session recordKey"
                    , "verifyProjectChartResourceRecordBundle plan chart"
                    , "runVerifiedChartWorkloadCleanupCall cfg chart bundle"
                    ]
            offsets <- maybe (assertFailure "the reverse chart adopter lost an authenticated stage") pure (traverse (`substringOffset` production) stages)
            assertBool "reverse chart stages are out of order" (and (zipWith (<) offsets (drop 1 offsets)))
            assertBool "reverse adoption reconstructs a forward execution package" (not ("PlanExecutionPackage" `isInfixOf` production))
        , testCase "the VM deployment performs exact provider settlement before package registration" $ do
            commandsSource <- readFile "src/HostBootstrapDemo/Commands.hs"
            let adopterSource =
                    maybe
                        ""
                        (`drop` commandsSource)
                        (substringOffset "runExactIncusProvider ::" commandsSource)
                exactCallsite =
                    [ "stepExecutionPreparedGate execution"
                    , "withNodeResourceOfKind execution ProviderResourceKind (stepExecutionOperationKey execution)"
                    , "withNodeObservedResource execution planned"
                    , "withPreparedProviderProvision execution"
                    , "runProviderProvisionCall backend preparedProvision"
                    , "settleProviderProvision Nothing preparedProvision provisionCall"
                    , "withPreparedProviderReady execution"
                    , "runProviderReadyCall backend preparedReady"
                    , "settleProviderReady preparedReady readyCall"
                    , "carryRunningProviderSettlement execution advance \"provisioned\" \"demo-incus-provider-v1\""
                    , "registerRunningProviderDependencyPackage"
                    ]
                positions = traverse (`substringOffset` adopterSource) exactCallsite
            case positions of
                Nothing -> assertFailure "the exact Incus provider callsite lost a required lifecycle stage"
                Just offsets ->
                    assertBool
                        "provider lifecycle stages are not ordered prepare/provision/ready/carry/register"
                        (and (zipWith (<) offsets (drop 1 offsets)))
            assertBool
                "the VM action does not receive its exact StepExecution"
                ("changed (runVmUp cfg)" `isInfixOf` commandsSource)
            assertBool
                "the provider package route is no longer the fixed invocation-local readiness route"
                ("\"runtime://provider/demo-vm-readiness\"" `isInfixOf` commandsSource)
            assertBool
                "the provider adopter reconstructed an operation-name fallback"
                (not ("withNodeResourceOfKind execution ProviderResourceKind \"" `isInfixOf` commandsSource))
        , testCase "the Direct reservation settles exactly before CUDA and package consumers" $ do
            commandsSource <- readFile "src/HostBootstrapDemo/Commands.hs"
            let bootstrapSource =
                    maybe
                        ""
                        (`drop` commandsSource)
                        (substringOffset "runDirectProviderReservation ::" commandsSource)
                adopterSource =
                    maybe
                        ""
                        (`drop` commandsSource)
                        (substringOffset "runExactDirectProvider ::" commandsSource)
                exactCallsite =
                    [ "stepExecutionPreparedGate execution"
                    , "mkDirectHostBackendSpec cfg canonicalRoot (demoBaseImage cfg)"
                    , "withNodeResourceOfKind execution ProviderResourceKind (stepExecutionOperationKey execution)"
                    , "withNodeObservedResource execution planned"
                    , "withPreparedProviderProvision execution"
                    , "runProviderProvisionCall backend preparedProvision"
                    , "settleProviderProvision Nothing preparedProvision provisionCall"
                    , "withPreparedProviderReady execution"
                    , "runProviderReadyCall backend preparedReady"
                    , "settleProviderReady preparedReady readyCall"
                    , "carryCreatedRunningProviderSettlement execution advance \"demo-direct-provider-v1\""
                    , "registerRunningProviderDependencyPackage"
                    ]
                positions = traverse (`substringOffset` adopterSource) exactCallsite
            case positions of
                Nothing -> assertFailure "the exact Direct provider callsite lost a required lifecycle stage"
                Just offsets ->
                    assertBool
                        "Direct lifecycle stages are not ordered prepare/reserve/ready/carry/register"
                        (and (zipWith (<) offsets (drop 1 offsets)))
            assertBool
                "the Direct build action does not receive its exact StepExecution"
                ("changed (runDirectProviderReservation cfg)" `isInfixOf` commandsSource)
            assertBool
                "Direct reservation is not settled before CUDA mutation"
                ( case (substringOffset "runExactDirectProvider parentCfg cfgAfterDocker execution absoluteRoot" bootstrapSource, substringOffset "runEnsure EnsureCuda.reconciler" bootstrapSource) of
                    (Just exactOffset, Just cudaOffset) -> exactOffset < cudaOffset
                    _ -> False
                )
            assertBool
                "the Direct package route is no longer the fixed invocation-local readiness route"
                ("\"runtime://provider/demo-direct-readiness\"" `isInfixOf` adopterSource)
            assertBool
                "the Direct adopter reconstructed an operation-name fallback"
                (not ("withNodeResourceOfKind execution ProviderResourceKind \"" `isInfixOf` adopterSource))
        , testCase "copy-source keeps the exact writable share lexical before VM descent" $ do
            commandsSource <- readFile "src/HostBootstrapDemo/Commands.hs"
            let adopterSource =
                    maybe
                        ""
                        (`drop` commandsSource)
                        (substringOffset "runExactIncusShare ::" commandsSource)
                exactCallsite =
                    [ "stepExecutionPreparedGate execution"
                    , "mkProviderShareSpec (hpsHostPath durableShare) (hpsGuestPath durableShare)"
                    , "withNodeResourceOfKind execution DurableShareResourceKind (stepExecutionOperationKey execution)"
                    , "withFreshRunningProviderHandle"
                    , "withPreparedProviderShare execution plannedShare shareHandle managedProvider (dependencyProbe reprobe) shareSpec gate"
                    , "runProviderShareCall backend preparedShare"
                    , "settleProviderShare Nothing preparedShare shareCall"
                    , "withProviderShareSettlement"
                    , "withProviderBoundExec backend managedProvider"
                    , "reconcileNodeGuestAlias"
                    ]
                positions = traverse (`substringOffset` adopterSource) exactCallsite
            case positions of
                Nothing -> assertFailure "the exact copy-source adopter lost a required lexical stage"
                Just offsets ->
                    assertBool
                        "copy-source stages are not ordered recover/prepare/attach/settle/use/close"
                        (and (zipWith (<) offsets (drop 1 offsets)))
            vmPlan <- withDemoRoot (\root -> pure (expectPlan (demoChainFor (Substrate LinuxCpu Amd64) root hostCfg)))
            directPlan <- withDemoRoot (\root -> pure (expectPlan (demoChainFor (Substrate LinuxGpu Amd64) root hostCfg)))
            assertBool
                "the VM topology does not contain exactly one copy-source action"
                (length (filter ((== "copy-source") . stepKindName . stepKind) (stepPlanSteps vmPlan)) == 1)
            assertBool
                "the Direct topology acquired a VM-only copy-source action"
                (all ((/= "copy-source") . stepKindName . stepKind) (stepPlanSteps directPlan))
            assertBool
                "the managed share was written into a cross-node carrier"
                (not ("carryManagedResource" `isInfixOf` adopterSource))
        , testCase "the guest alias settles inside the managed copy-source continuation" $ do
            commandsSource <- readFile "src/HostBootstrapDemo/Commands.hs"
            let adopterSource =
                    maybe "" (`drop` commandsSource) (substringOffset "runExactIncusShare ::" commandsSource)
            assertBool
                "copy-source no longer declares its exact guest-alias projection"
                ("Step.projectsOperation\n        \"core:copy-source/guest-alias\"" `isInfixOf` commandsSource)
            assertBool
                "the exact alias does not retain the stable path and provider-selected target"
                ("mkGuestAliasSpec durableDockerHostPath (hpsGuestPath durableShare)" `isInfixOf` adopterSource)
            assertBool
                "alias reconciliation escaped the provider/share settlement continuation"
                ( case (substringOffset "\\managedShare _ -> do" adopterSource, substringOffset "reconcileNodeGuestAlias" adopterSource) of
                    (Just shareOffset, Just aliasOffset) -> shareOffset < aliasOffset
                    _ -> False
                )
            assertBool
                "the exact Incus adopter retained the compatibility alias mutator"
                (not ("mintDurableAlias" `isInfixOf` adopterSource))
        , testCase "the registry config renders proxy delivery from the plan, not a flag" $ do
            -- § GG: the boolean is OUTPUT. The topology (host-local client,
            -- cluster-only store) admits no reachability witness, so the plan
            -- can only be `Proxy`, and proxy delivery must disable redirects.
            let rendered = registryConfigYaml
            assertBool
                ("the redirect stanza is rendered:\n" ++ unlines rendered)
                ("  redirect:" `elem` rendered && "    disable: true" `elem` rendered)
            -- Everything addressable comes from the one plan.
            assertBool
                ("the s3 endpoint is the plan's store: " ++ unlines rendered)
                (any (("    regionendpoint: http://" ++ minioClusterEndpoint) ==) rendered)
            minioClusterEndpoint @?= "minio.default.svc:9000"
            registryEndpoint @?= "localhost:30500"
        , testCase "a served blob settles the route; a redirect to the store refuses" $ do
            -- Proxy delivery: 200 with no Location.
            served <- either assertFailure pure (parseBlobRouteAnswer "200 ")
            case settleBlobRoute demoRegistryPlan served of
                Right _ -> pure ()
                other -> assertFailure ("a served blob must settle, got " ++ show other)
            -- The reproduced defect: the registry redirects a host-local client
            -- to the cluster-only store, which it cannot resolve.
            redirected <-
                either
                    assertFailure
                    pure
                    (parseBlobRouteAnswer "307 http://minio.default.svc:9000/registry/blob")
            case settleBlobRoute demoRegistryPlan redirected of
                Left _ -> pure ()
                other ->
                    assertFailure ("a redirect to the store must refuse, got " ++ show other)
        , testCase "a /v2/ answer is not a blob route, and a bad status is not a match" $ do
            -- Liveness is not readiness: only a blob request can settle a route.
            case settleBlobRoute demoRegistryPlan apiVersionAnswer of
                Left _ -> pure ()
                other -> assertFailure ("a /v2/ probe must refuse, got " ++ show other)
            missing <- either assertFailure pure (parseBlobRouteAnswer "404 ")
            case settleBlobRoute demoRegistryPlan missing of
                Left _ -> pure ()
                other -> assertFailure ("a 404 must refuse, got " ++ show other)
            assertBool
                "an unparseable answer is an error, never a default"
                (either (const True) (const False) (parseBlobRouteAnswer "not-a-status"))
        , testCase "the upload session Location is resolved absolute or relative" $ do
            -- registry:2 answers absolute, but the API permits relative, so a
            -- relative Location is resolved against the dialled endpoint.
            uploadSessionUrl
                "localhost:30500"
                "HTTP/1.1 202 Accepted\nLocation: http://localhost:30500/v2/x/blobs/uploads/abc?_state=q\n"
                @?= Just "http://localhost:30500/v2/x/blobs/uploads/abc?_state=q"
            uploadSessionUrl
                "localhost:30500"
                "HTTP/1.1 202 Accepted\nlocation: /v2/x/blobs/uploads/abc?_state=q\n"
                @?= Just "http://localhost:30500/v2/x/blobs/uploads/abc?_state=q"
            -- No Location is an explicit failure, never a guessed URL.
            uploadSessionUrl "localhost:30500" "HTTP/1.1 202 Accepted\n" @?= Nothing
        , testCase "linux-gpu selects the direct host-to-container nvkind chain" $ do
            plan <- withDemoRoot (\root -> pure (expectPlan (demoChainFor (Substrate LinuxGpu Amd64) root hostCfg)))
            let steps = stepPlanSteps plan
            map frameId (chainFrames plan) @?= ["host-orchestrator-0", "vm-project-container-1"]
            map (stepKindName . stepKind) steps
                @?= [ "deploy-vm"
                    , "build-image"
                    , "context-init"
                    , "deploy-kind"
                    , "deploy-minio"
                    , "deploy-registry"
                    , "push-image"
                    , "deploy-chart"
                    , "expose-port"
                    , "deploy-accelerator-daemon"
                    ]
            assertBool "direct chain names nvkind" (isInfixOf "nvkind" (renderChainPlan plan))
        , testCase "validated direct context keeps nvkind even if the inner host detects CPU" $ do
            let directCtx = Context.deriveLinuxGpuContainerContext (context hostCfg) "/workspace/demo"
                vmCtx = Context.deriveVMContextWithProvider Context.IncusVMProvider (context hostCfg) "/vm/demo"
                ordinaryCtx = Context.deriveContainerContext vmCtx "/workspace/demo"
            clusterDriver (containerPlan Production directCtx) @?= NvkindDriver
            clusterConfigFile (containerPlan Production directCtx) @?= Just "nvkind-in-cluster.yaml"
            clusterDriver (containerPlan Production ordinaryCtx) @?= KindDriver
            clusterConfigFile (containerPlan Production ordinaryCtx) @?= Just "kind-in-cluster.yaml"
        , testCase "VM and Direct topologies author distinct provider resources at their exact target frames" $ do
            vmPlan <- withDemoRoot (\root -> pure (expectPlan (demoChainFor (Substrate LinuxCpu Amd64) root hostCfg)))
            directPlan <- withDemoRoot (\root -> pure (expectPlan (demoChainFor (Substrate LinuxGpu Amd64) root hostCfg)))
            let declarations plan =
                    [ (frameId (stepFrame step), providerResourceDeclarationTargetsChild declaration)
                    | step <- stepPlanSteps plan
                    , declaration <- stepProviderResourceDeclarations step
                    ]
            declarations vmPlan @?= [("host-orchestrator-0", True)]
            declarations directPlan @?= [("host-orchestrator-0", False)]
        , testCase "the exact forward-child projector covers VM, container, Direct, and Harness scopes" $ do
            withDemoRoot $ \root -> do
                let project parent child cfg lift =
                        either assertFailure pure (demoForwardChildPlan cfg parent child lift)
                    requireDescent frame plan =
                        maybe (assertFailure ("missing descent from " ++ frame)) pure (frameDescent frame plan)
                vmRootPlan <- pure (expectPlan (demoChainFor (Substrate LinuxCpu Amd64) root hostCfg))
                vmLift <- requireDescent "host-orchestrator-0" vmRootPlan
                (vmPath, vmCfg, vmPlan) <- project "host-orchestrator-0" "vm-orchestrator-1" hostCfg vmLift
                vmPath @?= "/root/hostbootstrap/demo"
                Context.currentFrame (context vmCfg) @?= "vm-orchestrator-1"
                containerLift <- requireDescent "vm-orchestrator-1" vmPlan
                (containerPath, containerCfg, _containerPlan) <- project "vm-orchestrator-1" "vm-project-container-2" vmCfg containerLift
                containerPath @?= "/workspace/demo"
                Context.currentFrame (context containerCfg) @?= "vm-project-container-2"

                directRootPlan <- pure (expectPlan (demoChainFor (Substrate LinuxGpu Amd64) root hostCfg))
                directLift <- requireDescent "host-orchestrator-0" directRootPlan
                (directPath, directCfg, _directPlan) <- project "host-orchestrator-0" "vm-project-container-1" hostCfg directLift
                directPath @?= "/workspace/demo"
                Context.currentFrame (context directCfg) @?= "vm-project-container-1"

                let harnessCfg = hostCfg{runProfile = HarnessRun "run-42"}
                harnessPlan <- pure (expectPlan (demoChainFor (Substrate LinuxGpu Amd64) root harnessCfg))
                harnessLift <- requireDescent "host-orchestrator-0" harnessPlan
                (_, projectedHarness, _) <- project "host-orchestrator-0" "vm-project-container-1" harnessCfg harnessLift
                clusterProfileOf projectedHarness @?= TestCase "run-42"

                assertBool "a foreign child edge was projected" (isLeft (demoForwardChildPlan hostCfg "host-orchestrator-0" "foreign" directLift))
                assertBool "a VM lift was accepted for the Direct child" (isLeft (demoForwardChildPlan hostCfg "host-orchestrator-0" "vm-project-container-1" vmLift))
        , testCase "the provider/cluster join accepts only one exact immediate parent" $ do
            let parents frame
                    | frame == "cluster" = Just "provider"
                    | frame == "provider" = Just "host"
                    | frame == "sibling" = Just "host"
                    | otherwise = Nothing
            demoDirectParentJoin ["provider"] ["cluster"] parents
                @?= Right ("provider", "cluster")
            assertBool "an absent provider was accepted" (isLeft (demoDirectParentJoin [] ["cluster"] parents))
            assertBool "duplicate providers were accepted" (isLeft (demoDirectParentJoin ["provider", "sibling"] ["cluster"] parents))
            assertBool "an absent cluster was accepted" (isLeft (demoDirectParentJoin ["provider"] [] parents))
            assertBool "duplicate clusters were accepted" (isLeft (demoDirectParentJoin ["provider"] ["cluster", "sibling"] parents))
            assertBool "an ancestor provider was accepted" (isLeft (demoDirectParentJoin ["host"] ["cluster"] parents))
            assertBool "a sibling provider was accepted" (isLeft (demoDirectParentJoin ["sibling"] ["cluster"] parents))
            assertBool "a root cluster without a parent was accepted" (isLeft (demoDirectParentJoin ["provider"] ["root"] parents))
        , testCase "VM and Direct operations partition by closed identity in exact order" $ do
            vmPlan <- withDemoRoot (\root -> pure (expectPlan (demoChainFor (Substrate LinuxCpu Amd64) root hostCfg)))
            directPlan <- withDemoRoot (\root -> pure (expectPlan (demoChainFor (Substrate LinuxGpu Amd64) root hostCfg)))
            let roles :: StepPlan -> [String]
                roles = map (roleOf . stepIdentity) . stepPlanSteps
                roleOf :: StepIdentity -> String
                roleOf identity =
                    either error id (foldDemoOperationRole identity "provider" "cluster" "workload" "service" "assertion")
            roles vmPlan
                @?= replicate 5 "provider"
                    ++ ["cluster"]
                    ++ replicate 4 "workload"
                    ++ ["assertion", "service"]
            roles directPlan
                @?= replicate 3 "provider"
                    ++ ["cluster"]
                    ++ replicate 4 "workload"
                    ++ ["assertion", "service"]
            unknown <- either assertFailure pure (projectStepId "unknown-demo-operation")
            assertBool
                "an unknown typed project identity was accepted"
                (isLeft (foldDemoOperationRole (ProjectStepIdentity unknown) () () () () ()))
        , {- The profile a container-frame plan resolves under is the run's own,
          so a harness run never takes the production cluster name, the durable
          @.data@ root, or the fixed host ports (the worked-demo phase). -}
          testCase "a harness run's container plan is scoped to its own run" $ do
            let ctx = Context.deriveContainerContext (Context.deriveVMContextWithProvider Context.IncusVMProvider (context hostCfg) "/vm/demo") "/workspace/demo"
                production = containerPlan Production ctx
                harness = containerPlan (TestCase "run-42") ctx
            clusterName production @?= "hostbootstrap-demo"
            clusterName harness @?= "hostbootstrap-demo-test-run-42"
            publishesHostPorts production @?= True
            publishesHostPorts harness @?= False
            -- the durable production root is never the harness run's state
            assertBool
                "the harness run's state is its own generation"
                (dataPath harness /= dataPath production)
        , {- The profile travels in the config, so the frame that resolves the
          plan is the frame the parent handed it to. -}
          testCase "the run profile is decoded from the config and crosses each frame" $ do
            let harnessCfg = hostCfg{runProfile = HarnessRun "run-42"}
            clusterProfileOf hostCfg @?= Production
            clusterProfileOf harnessCfg @?= TestCase "run-42"
            vm <- either assertFailure pure (deriveProjectConfigForKind VMOrchestrator harnessCfg "/vm/demo")
            child <- either assertFailure pure (deriveProjectConfigForKind VMProjectContainer vm "/workspace/demo")
            clusterProfileOf vm @?= TestCase "run-42"
            clusterProfileOf child @?= TestCase "run-42"
        , {- The durable host root is the run's own too, and it is the *same*
          directory the resolved plan preserves — both come from
          'profileDataSegments'. That is what keeps the long gate off the
          operator's durable state (the worked-demo phase). -}
          testCase "the durable host root is the run's own, and is the path teardown preserves" $ do
            profileDataSegments Production @?= [".data"]
            profileDataSegments (TestCase "run-42") @?= [".test_data", "run-42"]
            profileDataPath Production "/srv/demo" @?= "/srv/demo/.data"
            profileDataPath (TestCase "run-42") "/srv/demo" @?= "/srv/demo/.test_data/run-42"
            -- the mount and the preserved path are one directory by construction
            let ctx = Context.deriveContainerContext (Context.deriveVMContextWithProvider Context.IncusVMProvider (context hostCfg) "/vm/demo") "/workspace/demo"
            dataPath (containerPlan (TestCase "run-42") ctx)
                @?= profileDataPath (TestCase "run-42") "/workspace/demo"
            dataPath (containerPlan Production ctx)
                @?= profileDataPath Production "/workspace/demo"
        , testCase "accelerator Helm values follow validated daemon placement" $ do
            let directCtx = Context.deriveLinuxGpuContainerContext (context hostCfg) "/workspace/demo"
                incusCtx = Context.deriveContainerContext (Context.deriveVMContextWithProvider Context.IncusVMProvider (context hostCfg) "/vm/demo") "/workspace/demo"
                wslCtx = Context.deriveContainerContext (Context.deriveVMContextWithProvider Context.Wsl2VMProvider (context hostCfg) "/vm/demo") "/workspace/demo"
                clusterIpValues =
                    [ ("service.port", "8080")
                    , ("service.accelerator.type", "ClusterIP")
                    , ("service.accelerator.port", "8081")
                    , ("service.accelerator.targetPort", "8081")
                    ]
            acceleratorHelmValuesForContext hostCfg directCtx @?= Right clusterIpValues
            acceleratorHelmValuesForContext hostCfg incusCtx @?= Right clusterIpValues
            acceleratorHelmValuesForContext hostCfg wslCtx
                @?= Right
                    [ ("service.port", "8080")
                    , ("service.accelerator.type", "NodePort")
                    , ("service.accelerator.port", "8081")
                    , ("service.accelerator.targetPort", "8081")
                    , ("service.accelerator.nodePort", "30081")
                    ]
            let customWebConfig = WebServiceConfig (validPort 9090) (validPort 9091)
                customPorts =
                    hostCfg
                        { webServiceConfig = customWebConfig
                        }
            acceleratorHelmValuesForContext customPorts directCtx
                @?= Right
                    [ ("service.port", "9090")
                    , ("service.accelerator.type", "ClusterIP")
                    , ("service.accelerator.port", "9091")
                    , ("service.accelerator.targetPort", "9091")
                    ]
            assertBool "invalid configured ports cannot be constructed before Helm" $
                case mkPort 0 of
                    Left err -> "between 1 and 65535" `isInfixOf` err
                    Right _ -> False
        , testCase "service ConfigMaps derive the actual parent topology and frame" $ do
            let directCtx = Context.deriveLinuxGpuContainerContext (context hostCfg) "/workspace/demo"
                incusCtx = Context.deriveContainerContext (Context.deriveVMContextWithProvider Context.IncusVMProvider (context hostCfg) "/vm/demo") "/workspace/demo"
                wslCtx = Context.deriveContainerContext (Context.deriveVMContextWithProvider Context.Wsl2VMProvider (context hostCfg) "/vm/demo") "/workspace/demo"
                (directConfig, directFrame) = renderServiceConfigForContext hostCfg directCtx
                (incusConfig, incusFrame) = renderServiceConfigForContext hostCfg incusCtx
                (wslConfig, wslFrame) = renderServiceConfigForContext hostCfg wslCtx
                manifest = serviceConfigMapManifest "hostbootstrap-demo-test-case" directConfig
            directFrame @?= "cluster-service-2"
            incusFrame @?= "cluster-service-3"
            wslFrame @?= "cluster-service-3"
            assertBool "direct service has no invented VM frame" (not ("topologyFrameId = \"vm-orchestrator-1\"" `T.isInfixOf` directConfig))
            assertBool "Incus provider survives into the service projection" ("IncusVMProvider" `T.isInfixOf` incusConfig)
            assertBool "WSL2 provider survives into the service projection" ("Wsl2VMProvider" `T.isInfixOf` wslConfig)
            assertBool "manifest carries every derived config line" $
                all (\line -> ("    " ++ line) `isInfixOf` manifest) (filter (not . null) (lines (T.unpack directConfig)))
        , testCase "durable-readback is a lifecycle-free write/read assertion" $ do
            commandsSource <- readFile "src/HostBootstrapDemo/Commands.hs"
            let assertionTail = maybe "" (`drop` commandsSource) (substringOffset "assertDurableReadback cfg frame" commandsSource)
                assertion = maybe assertionTail (`take` assertionTail) (substringOffset "demoProjectImage ::" assertionTail)
            assertBool "durable-readback does not POST the marker" ("-X POST" `isInfixOf` assertion)
            assertBool "durable-readback does not read the marker back" ("curl --fail --silent --show-error" `isInfixOf` assertion && "hostbootstrap-destroy-up-v1" `isInfixOf` assertion)
            assertBool "project-owned assertion code must not invoke lifecycle" (not ("[\"project\", \"destroy\"]" `isInfixOf` assertion || "[\"project\", \"up\"]" `isInfixOf` assertion))
        , testCase "chart and kind configs consume the placement-specific exposure" $ do
            serviceTemplate <- readFile ("chart" ++ "/templates/service.yaml")
            deploymentTemplate <- readFile ("chart" ++ "/templates/deployment.yaml")
            staticConfigMap <- doesFileExist ("chart" ++ "/templates/configmap.yaml")
            playwrightConfig <- readFile ("playwright" ++ "/playwright.config.ts")
            inClusterKind <- readFile "kind-in-cluster.yaml"
            nvkindTemplate <- readFile "nvkind-in-cluster.yaml"
            hostKind <- readFile "kind.yaml"
            let hostListenAddress = ingressKindListenAddress (acceleratorIngressPlan HostResidentDaemon 8081 30081)
                countLines fragment = length . filter (isInfixOf fragment) . lines
            assertBool "chart renders the configured accelerator Service type" (".Values.service.accelerator.type" `isInfixOf` serviceTemplate)
            assertBool "accelerator Service targets its isolated listener" (".Values.service.accelerator.targetPort" `isInfixOf` serviceTemplate)
            assertBool "chart omits nodePort unless the plan selects NodePort" ("if eq .Values.service.accelerator.type \"NodePort\"" `isInfixOf` serviceTemplate)
            assertBool "chart consumes the derived service frame" (".Values.service.currentFrame" `isInfixOf` deploymentTemplate)
            assertBool "chart rolls when the applied service config changes" (".Values.service.configHash" `isInfixOf` deploymentTemplate)
            assertBool "the chart exposes the exact deployment readiness target" ("kind: Deployment" `isInfixOf` deploymentTemplate)
            assertBool "the chart consumes the exact planned image identity" (".Values.image.identity" `isInfixOf` deploymentTemplate)
            assertBool "web pod mounts the kind-node durable host path" ("path: /var/lib/hostbootstrap-demo-data/web" `isInfixOf` deploymentTemplate && "type: DirectoryOrCreate" `isInfixOf` deploymentTemplate && "mountPath: /var/lib/hostbootstrap-demo-data/web" `isInfixOf` deploymentTemplate)
            assertBool "the service config is owned by the chart transaction" staticConfigMap
            assertBool "browser engines serialize against the single accelerator session" ("workers: 1" `isInfixOf` playwrightConfig)
            assertBool "in-cluster config has no accelerator host mapping" (not ("hostPort: 30081" `isInfixOf` inClusterKind))
            assertBool "nvkind template injects all GPUs into its worker" ("/var/run/nvidia-container-devices/all" `isInfixOf` nvkindTemplate)
            assertBool "nvkind GPU worker is selected by the device-plugin chart" ("nvidia.com/gpu.present: \"true\"" `isInfixOf` nvkindTemplate)
            assertBool "nvkind accelerator remains ClusterIP-only" (not ("hostPort: 30081" `isInfixOf` nvkindTemplate))
            countLines "hostPath: /var/tmp/hostbootstrap-demo-data" hostKind @?= 1
            countLines "containerPath: /var/lib/hostbootstrap-demo-data" hostKind @?= 1
            countLines "hostPath: /var/tmp/hostbootstrap-demo-data" inClusterKind @?= 1
            countLines "containerPath: /var/lib/hostbootstrap-demo-data" inClusterKind @?= 1
            countLines "hostPath: /var/tmp/hostbootstrap-demo-data" nvkindTemplate @?= 2
            countLines "containerPath: /var/lib/hostbootstrap-demo-data" nvkindTemplate @?= 2
            assertBool "host-daemon config consumes the planned local-only address" $
                case hostListenAddress of
                    Just address -> ("listenAddress: \"" ++ address ++ "\"") `isInfixOf` hostKind
                    Nothing -> False
        , testCase "base image flavor follows the metal lane" $ do
            demoBaseImageFor (Substrate LinuxGpu Amd64)
                @?= "docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64"
            demoBaseImageFor (Substrate LinuxCpu Amd64)
                @?= "docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64"
            demoBaseImageFor (Substrate AppleSilicon Arm64)
                @?= "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
            demoBaseImageFor (Substrate WindowsGpu Amd64)
                @?= "docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64"
        , testCase "a derived build always pulls, so a stale local base cannot be used" $ do
            let argv =
                    dockerBuildArgs
                        ( projectConfigForRole
                            "hostbootstrap-demo"
                            "hostbootstrap-demo"
                            "/srv"
                            "docker/Dockerfile"
                            demoDefaultResources
                            demoDefaultDeployConfig
                            demoDefaultMessage
                            Context.HostOrchestrator
                        )
                        "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
            -- Without this a host that once built the rolling tag locally would
            -- build FROM that stale image and never notice (94w FF).
            assertBool "the build pulls its base" ("--pull" `elem` argv)
            assertBool
                "the base still reaches the Dockerfile as a build arg"
                ( "BASE_IMAGE=docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
                    `elem` argv
                )
        , testCase "the derived image receives the independently provisioned verification key" $ do
            let keyHex = replicate 64 'a'
                argv =
                    dockerBuildArgsWithVerificationKey
                        ( projectConfigForRole
                            "hostbootstrap-demo"
                            "hostbootstrap-demo"
                            "/srv"
                            "docker/Dockerfile"
                            demoDefaultResources
                            demoDefaultDeployConfig
                            demoDefaultMessage
                            Context.HostOrchestrator
                        )
                        "docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64"
                        keyHex
            assertBool "the public key is a build argument" ("HANDOFF_VERIFICATION_KEY_HEX=" ++ keyHex `elem` argv)
            last argv @?= "."
        , testCase "a published digest pins the repository, not the tag text" $ do
            pinnedBaseReference
                "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
                "sha256:abc123"
                @?= Right "docker.io/tuee22/hostbootstrap@sha256:abc123"
            -- A registry port is not a tag separator.
            pinnedBaseReference "localhost:5000/base:rolling" "sha256:def456"
                @?= Right "localhost:5000/base@sha256:def456"
            -- A reference with no tag is already a repository.
            pinnedBaseReference "docker.io/tuee22/hostbootstrap" "sha256:abc123"
                @?= Right "docker.io/tuee22/hostbootstrap@sha256:abc123"
        , testCase "a digest that is not a sha256 reference is refused, not concatenated" $
            case pinnedBaseReference "repo/base:tag" "not-a-digest" of
                Left reason ->
                    assertBool
                        ("the refusal names the digest: " ++ reason)
                        ("not-a-digest" `isInfixOf` reason)
                Right value ->
                    assertFailure ("a malformed digest produced " ++ show value)
        , testCase "the pull and inspect argv name the published tag" $ do
            basePullArgs "repo/base:tag" @?= ["pull", "repo/base:tag"]
            let inspectArgv = baseDigestArgs "repo/base:tag"
            assertBool "inspect targets the tag" ("repo/base:tag" `elem` inspectArgv)
            assertBool "inspect asks for repository digests" $
                any ("RepoDigests" `isInfixOf`) inspectArgv
        , testCase "project-container handoffs carry no plan-authored Docker arguments" $ do
            canonicalDemo <- canonicalizePath "."
            -- Both descents are read off the plan itself: the direct lane's is
            -- declared by its metal @context-init@ node, the VM-backed lane's by
            -- the in-VM @context-init@ node (§ W).
            result <-
                withDemoRoot $ \root ->
                    pure
                        ( frameDescent "host-orchestrator-0" (expectPlan (demoChainFor (Substrate LinuxGpu Amd64) root hostCfg))
                        , frameDescent "vm-orchestrator-1" (expectPlan (demoChainFor (Substrate LinuxCpu Amd64) root hostCfg))
                        )
            case result of
                (Just (LiftContext [ViaContainer directLift]), Just (LiftContext [ViaContainer ordinaryLift])) -> do
                    let directArgs = clExtraArgs directLift
                        ordinaryArgs = clExtraArgs ordinaryLift
                        durableMount = Mount (T.pack (canonicalDemo </> ".data")) "/workspace/demo/.data" False
                        guestDurableMount = Mount "/var/tmp/hostbootstrap-demo-data" "/workspace/demo/.data" False
                    directArgs @?= []
                    ordinaryArgs @?= []
                    assertBool "direct handoff carries the canonical host durable root" (durableMount `elem` clMounts directLift)
                    assertBool "VM-backed handoff carries the provider-shared durable root" (guestDurableMount `elem` clMounts ordinaryLift)
                other -> assertBool ("unexpected frame contexts: " ++ show other) False
        , testCase "Linux GPU assertions stay local instead of entering Incus" $
            demoTestFrameContext (Substrate LinuxGpu Amd64) @?= localContext
        , testCase "direct-cluster safety checks every planned node and fails closed" $ do
            let nodes = ["demo-control-plane", "demo-worker"]
            directClusterPresence nodes (Right (ExitSuccess, "demo-worker\n", "")) @?= Right True
            directClusterPresence nodes (Right (ExitSuccess, "unrelated\n", "")) @?= Right False
            assertBool "Docker probe errors must refuse the run" $
                case directClusterPresence nodes (Right (ExitFailure 1, "", "daemon unavailable")) of
                    Left _ -> True
                    Right _ -> False
        , testCase "direct teardown uses the project image's pinned kind against the host socket" $ do
            assertBool "teardown mounts the Docker socket" ("/var/run/docker.sock:/var/run/docker.sock" `elem` directClusterTeardownArgs)
            assertBool "teardown bypasses the demo entrypoint" ("/usr/local/bin/kind" `elem` directClusterTeardownArgs)
            assertBool "teardown deletes the managed name" $
                ["delete", "cluster", "--name", "hostbootstrap-demo"] `isSuffixOf` directClusterTeardownArgs
        , testCase "the direct Docker build context is the repository root" $
            -- Build the expectation with the same separator the input uses:
            -- 'repoRootOfProjectRoot' is 'takeDirectory', so on Windows both
            -- sides are backslash-joined and a hardcoded POSIX literal would
            -- assert the platform rather than the parent-of-project-root rule.
            repoRootOfProjectRoot ("/workspace" </> "hostbootstrap" </> "demo")
                @?= ("/workspace" </> "hostbootstrap")
        , testCase "accelerator daemon manifest requests a GPU only in the CUDA lane" $ do
            let cpuManifest = acceleratorDaemonManifest "hostbootstrap-demo-test-case" False "daemon-3" "config" 8081
                gpuManifest = acceleratorDaemonManifest "hostbootstrap-demo-test-case" True "daemon-3" "config" 8081
                customPortManifest = acceleratorDaemonManifest "hostbootstrap-demo-test-case" False "daemon-3" "config" 9091
            assertBool "CPU pod has no GPU request" (not ("nvidia.com/gpu" `isInfixOf` cpuManifest))
            assertBool "GPU pod requests one GPU" ("nvidia.com/gpu: 1" `isInfixOf` gpuManifest)
            assertBool "GPU pod selects the nvkind NVIDIA runtime" ("runtimeClassName: nvidia" `isInfixOf` gpuManifest)
            assertBool "CPU pod stays on the default runtime" (not ("runtimeClassName: nvidia" `isInfixOf` cpuManifest))
            assertBool "daemon dials the run-scoped ClusterIP service" ("hostbootstrap-demo-test-case-accelerator:8081" `isInfixOf` gpuManifest)
            assertBool "daemon dials a configured accelerator port" ("hostbootstrap-demo-test-case-accelerator:9091" `isInfixOf` customPortManifest)
            assertBool "daemon config changes roll its subPath-mounted pod" ("hostbootstrap.io/config-hash" `isInfixOf` gpuManifest)
            assertBool "daemon rollout cannot overlap reconnecting peers" ("type: Recreate" `isInfixOf` gpuManifest)
            assertBool "daemon rollout waits for its connection readiness marker" ("HOSTBOOTSTRAP_ACCELERATOR_READY_FILE" `isInfixOf` gpuManifest && "readinessProbe:" `isInfixOf` gpuManifest)
        , testCase "accelerator topology rejects process-local HA routing" $ do
            validateAcceleratorReplicaCount 1 @?= Right ()
            assertBool "more than one web pod is unsupported" $
                case validateAcceleratorReplicaCount 2 of
                    Left _ -> True
                    Right _ -> False
        , testCase "linux-cpu runs the accelerator daemon as an in-cluster pod (no host hook)" $ do
            plan <- withDemoRoot (\root -> pure (expectPlan (demoChainFor (Substrate LinuxCpu Amd64) root hostCfg)))
            let steps = stepPlanSteps plan
            map frameId (chainFrames plan) @?= ["host-orchestrator-0", "vm-orchestrator-1", "vm-project-container-2"]
            -- Incus does not forward the guest NodePort to the host, so the Linux CPU
            -- accelerator daemon is an in-cluster pod (dialing the web ClusterIP), NOT a
            -- host-resident post-handoff process as on Apple/Windows.
            map stepLabel (postHandoffStepsForFrame "host-orchestrator-0" plan) @?= []
            stepKindName (stepKind (last steps)) @?= "deploy-accelerator-daemon"
        , testCase "apple/windows keep the host-resident accelerator daemon post-handoff hook" $ do
            plan <- withDemoRoot (\root -> pure (expectPlan (demoChainFor (Substrate AppleSilicon Arm64) root hostCfg)))
            map stepLabel (postHandoffStepsForFrame "host-orchestrator-0" plan)
                @?= ["start the host-resident accelerator daemon after ingress is reachable"]
            hostAcceleratorSubstrate (Substrate AppleSilicon Arm64) @?= True
            hostAcceleratorSubstrate (Substrate WindowsGpu Amd64) @?= True
        , testCase "windows-cpu has no accelerator worker or host-daemon hook" $ do
            plan <- withDemoRoot (\root -> pure (expectPlan (demoChainFor (Substrate WindowsCpu Amd64) root hostCfg)))
            map stepLabel (postHandoffStepsForFrame "host-orchestrator-0" plan) @?= []
            hostAcceleratorSubstrate (Substrate WindowsCpu Amd64) @?= False
        , -- The POSIX daemon's invocation *shape* is not asserted here. It is
          -- not this module's to assert: the shape is sealed in
          -- @HostBootstrap.Detached@ and proved behaviourally by the core
          -- suite's @DetachedSpec@ plus its compile-fail fixtures (§ HH). The
          -- assertion this replaced read the current value of an unsealed
          -- @CreateProcess@ field, so it certified the disposition that closed
          -- the daemon's descriptors. What remains here is what the *call site*
          -- owns: the operands it supplies to the boundary.
          testCase "the host daemon launch supplies only absolute operands" $ do
            let daemonEnv = [("HOSTBOOTSTRAP_ACCELERATOR_WS_URL", "ws://127.0.0.1:30081")]
                buildLaunch exe workDir sink =
                    hostAcceleratorDaemonLaunch exe hostAcceleratorDaemonArgs daemonEnv workDir sink
                absExe = "/repo/.build/accelerator-daemon/hostbootstrap-demo"
                absDir = "/repo/.build/accelerator-daemon"
                absSink = absDir </> "hostbootstrap-demo.accelerator.output"
            hostAcceleratorDaemonArgs @?= ["service", "run"]
            case buildLaunch absExe absDir absSink of
                Left err -> assertFailure ("an absolute launch was refused: " ++ err)
                Right launch -> do
                    absExePath (detachedLaunchExecutable launch) @?= absExe
                    detachedLaunchArguments launch @?= hostAcceleratorDaemonArgs
            assertBool
                "a bare daemon command name was accepted"
                (isLeft (buildLaunch "hostbootstrap-demo" absDir absSink))
            assertBool
                "a relative working directory was accepted"
                (isLeft (buildLaunch absExe "accelerator-daemon" absSink))
            assertBool
                "a relative output sink was accepted"
                (isLeft (buildLaunch absExe absDir "accelerator.output"))
        , testCase "a failed host daemon startup quotes the child's own output" $ do
            assertBool
                "an empty retention produced a banner"
                (null (renderRetainedDaemonOutput (T.pack "   \n")))
            let quoted = renderRetainedDaemonOutput (T.pack "metal: no usable device\n")
            assertBool
                ("the daemon's cause was dropped: " ++ quoted)
                ("metal: no usable device" `isInfixOf` quoted)
        , testCase "the Windows host daemon launches hidden and tracks its pid" $ do
            let daemonEnv = [("HOSTBOOTSTRAP_ACCELERATOR_WS_URL", "ws://127.0.0.1:30081")]
                windowsScript =
                    hostAcceleratorDaemonPowerShellScript
                        "C:\\demo's\\hostbootstrap-demo"
                        "C:\\demo's\\hostbootstrap-demo.accelerator.pid"
                        daemonEnv
            assertBool "Windows launches into an independent hidden process" ("Start-Process" `isInfixOf` windowsScript && "-WindowStyle Hidden" `isInfixOf` windowsScript)
            assertBool "Windows persists the PID before reporting launch success" ("WriteAllText" `isInfixOf` windowsScript && "[Console]::WriteLine($p.Id)" `isInfixOf` windowsScript)
            assertBool "Windows launch failure force-stops an otherwise untracked child" ("Stop-Process -Id $p.Id -Force" `isInfixOf` windowsScript)
            assertBool "PowerShell literals escape apostrophes" ("'C:\\demo''s\\hostbootstrap-demo'" `isInfixOf` windowsScript)
        , testCase "host accelerator identity resolves relative source roots absolutely" $ do
            let relativeCfg =
                    projectConfigForRole
                        "hostbootstrap-demo"
                        "hostbootstrap-demo"
                        "."
                        demoDefaultDockerfile
                        demoDefaultResources
                        demoDefaultDeployConfig
                        demoDefaultMessage
                        HostOrchestrator
            daemonExe <- absoluteHostAcceleratorDaemonExePath (context relativeCfg)
            assertBool "daemon identity path is absolute" (isAbsolute daemonExe)
            assertBool "Windows copied daemons retain the executable extension" (os /= "mingw32" || ".exe" `isSuffixOf` daemonExe)
        , testCase "host accelerator lifecycle requires matching pid and owner witnesses" $ do
            hostDaemonLifecycleStateConsistent False False @?= True
            hostDaemonLifecycleStateConsistent True True @?= True
            hostDaemonLifecycleStateConsistent True False @?= False
            hostDaemonLifecycleStateConsistent False True @?= False
        , testCase "host accelerator pid read releases the file before teardown removal" $ do
            tmp <- getTemporaryDirectory
            (pidPath, handle) <- openTempFile tmp "hostbootstrap-accelerator.pid"
            hPutStr handle "1234\n"
            hClose handle
            readHostAcceleratorDaemonPid pidPath >>= (@?= "1234")
            removeFile pidPath
            doesFileExist pidPath >>= (@?= False)
        , testCase "host accelerator pid parser rejects numeric prefixes" $ do
            tmp <- getTemporaryDirectory
            (pidPath, handle) <- openTempFile tmp "hostbootstrap-accelerator-invalid.pid"
            hPutStr handle "1234junk\n"
            hClose handle
            parsed <- try (readHostAcceleratorDaemonPid pidPath) :: IO (Either SomeException String)
            assertBool "an invalid pid must not be truncated into another process id" (either (const True) (const False) parsed)
            removeFile pidPath
        , testCase "host daemon teardown requires executable identity before a forced stop" $ do
            let exe = "C:\\repo\\.build\\accelerator-daemon\\hostbootstrap-demo"
                validWindows = map toUpperAscii exe ++ "\r\n\"" ++ map toUpperAscii exe ++ "\" service run\r\n"
                validCimWindows = exe ++ "\r\n\"" ++ exe ++ "\" \"service\" \"run\"\r\n"
            hostDaemonIdentityMatches True exe (Right (ExitSuccess, validWindows, "")) @?= True
            hostDaemonIdentityMatches True exe (Right (ExitSuccess, validCimWindows, "")) @?= True
            hostDaemonIdentityMatches True exe (Right (ExitSuccess, exe ++ "\r\n\"" ++ exe ++ "\" project up\r\n", "")) @?= False
            hostDaemonIdentityMatches True exe (Right (ExitSuccess, "C:\\Windows\\System32\\notepad.exe\r\nnotepad.exe\r\n", "")) @?= False
            hostDaemonIdentityMatches False "/repo/daemon" (Right (ExitSuccess, "/repo/daemon service run\n", "")) @?= True
            hostDaemonIdentityMatches False "/repo/daemon" (Right (ExitSuccess, "/repo/daemon project up\n", "")) @?= False
            hostDaemonIdentityMatches False "/repo/daemon" (Right (ExitSuccess, "/repo/daemon-old service run\n", "")) @?= False
        , testCase "web bridge maps Haskell Float into the PureScript numeric primitive" $
            withBridgeTempDirectory $ \dir -> do
                writeBridge dir
                generated <- readFile (dir </> "HostBootstrapDemo" </> "Web" </> "Api.purs")
                assertBool "Float fields use PureScript Number" ("result :: Number" `isInfixOf` generated)
                assertBool "the generated module has no Haskell-only GHC.Types import" (not ("GHC.Types" `isInfixOf` generated))
        , testCase "demo registers web and accelerator service variants" $
            serviceVariantNames demoServices @?= ["web", "accelerator"]
        , testCase "demo registers separately named Production and Harness full-config artifacts" $
            map artifactName demoArtifacts
                @?= ["demoWeb", "demoWebApp", "demoProjectProduction", "demoProjectHarness"]
        , testCase "full and role codecs retain one jointly finalized specification digest" $ do
            let (digest, schemas) =
                    withProductionProjectCodec @ProjectConfig @() $ \baseCodec ->
                        withFinalizedServiceRegistry
                            ProductionScope
                            baseCodec
                            demoServices
                            (\codec registry -> (projectCodecSpecDigest codec, serviceRoleSchemaFamilies registry))
            assertBool "finalized digest is populated" (not (T.null digest))
            assertBool "Production family is named" ("service schema family Production:" `T.isInfixOf` schemas)
            assertBool "Harness family is named separately" ("service schema family Harness:" `T.isInfixOf` schemas)
            assertBool "Web role fields are reflected" ("servedMessage" `T.isInfixOf` schemas && "webParameters" `T.isInfixOf` schemas)
            assertBool "Accelerator role fields are reflected" ("acceleratorParameters" `T.isInfixOf` schemas)
            -- The source root the accelerator handler needs is a field of its own
            -- role wire, because a handler receives only its role's bundle and
            -- never a framework view (§ AA).
            assertBool
                "the accelerator's own source root is a role field"
                ("acceleratorSourceRoot" `T.isInfixOf` schemas)
            assertBool
                "the web role does not carry it"
                (not ("acceleratorSourceRoot" `T.isInfixOf` webFamilyOnly schemas))
        , testCase "selected role wires contain only framework validation and that role's fields" $ do
            let webCfg =
                    projectConfigForRole
                        "hostbootstrap-demo"
                        "hostbootstrap-demo"
                        "/srv"
                        "docker/Dockerfile"
                        demoDefaultResources
                        demoDefaultDeployConfig
                        demoDefaultMessage
                        Context.ClusterService
                acceleratorCfg =
                    projectConfigForRole
                        "hostbootstrap-demo"
                        "hostbootstrap-demo"
                        "/srv"
                        "docker/Dockerfile"
                        demoDefaultResources
                        demoDefaultDeployConfig
                        demoDefaultMessage
                        Context.Daemon
                selectedWire cfg =
                    withProductionProjectCodec @ProjectConfig @() $ \baseCodec ->
                        withFinalizedServiceRegistry
                            ProductionScope
                            baseCodec
                            demoServices
                            ( \_ registry ->
                                withSelectedServiceRequest
                                    "verified-config-digest"
                                    (inspectLocalContext (context cfg))
                                    cfg
                                    registry
                                    ( \identity codec request _ _ ->
                                        ( serviceIdText identity
                                        , requestVerifiedDigest request
                                        , renderValidatedServiceRequest codec request
                                        )
                                    )
                            )
            (webIdentity, webDigest, webWire) <- either (fail . show) pure (selectedWire webCfg)
            webIdentity @?= "web"
            webDigest @?= "verified-config-digest"
            assertBool "web wire retains its fields" ("servedMessage" `T.isInfixOf` webWire && "webParameters" `T.isInfixOf` webWire)
            assertBool "web wire excludes accelerator fields" (not ("acceleratorParameters" `T.isInfixOf` webWire))
            assertBool "web wire excludes plan-only fields" (all (not . (`T.isInfixOf` webWire)) ["dockerfile", "resources", "deploy"])
            (acceleratorIdentity, _, acceleratorWire) <- either (fail . show) pure (selectedWire acceleratorCfg)
            acceleratorIdentity @?= "accelerator"
            assertBool "accelerator wire retains only its service fields" ("acceleratorParameters" `T.isInfixOf` acceleratorWire)
            assertBool "accelerator wire excludes web fields" (all (not . (`T.isInfixOf` acceleratorWire)) ["servedMessage", "webParameters"])
        , testCase "each role declares its own effect row, not the union of both" $ do
            let webCfg =
                    projectConfigForRole
                        "hostbootstrap-demo"
                        "hostbootstrap-demo"
                        "/srv"
                        "docker/Dockerfile"
                        demoDefaultResources
                        demoDefaultDeployConfig
                        demoDefaultMessage
                        Context.ClusterService
                acceleratorCfg =
                    projectConfigForRole
                        "hostbootstrap-demo"
                        "hostbootstrap-demo"
                        "/srv"
                        "docker/Dockerfile"
                        demoDefaultResources
                        demoDefaultDeployConfig
                        demoDefaultMessage
                        Context.Daemon
                declaredFor cfg =
                    withProductionProjectCodec @ProjectConfig @() $ \baseCodec ->
                        withFinalizedServiceRegistry
                            ProductionScope
                            baseCodec
                            demoServices
                            ( \_ registry ->
                                withSelectedServiceRequest
                                    "verified-config-digest"
                                    (inspectLocalContext (context cfg))
                                    cfg
                                    registry
                                    (\_ _ _ declared _ -> declared)
                            )
            webDeclared <- either (fail . show) pure (declaredFor webCfg)
            acceleratorDeclared <- either (fail . show) pure (declaredFor acceleratorCfg)
            -- The web role reaches the durable root; the accelerator does not.
            webDeclared @?= [NetworkListen, DurableStore]
            -- The accelerator runs a worker process; the web role does not.
            acceleratorDeclared @?= [NetworkListen, ProcessSpawn]
            -- Neither is the union: least authority is a property of the
            -- declaration, so a widening shows up as a diff here.
            assertBool
                "the web role does not declare process spawn"
                (ProcessSpawn `notElem` webDeclared)
            assertBool
                "the accelerator does not declare durable store"
                (DurableStore `notElem` acceleratorDeclared)
        , testCase "common envelope agrees across full and role wires and rejects changed tags" $ do
            let webCfg =
                    projectConfigForRole
                        "hostbootstrap-demo"
                        "hostbootstrap-demo"
                        "/srv"
                        "docker/Dockerfile"
                        demoDefaultResources
                        demoDefaultDeployConfig
                        demoDefaultMessage
                        Context.ClusterService
            withProductionProjectCodec @ProjectConfig @() $ \baseCodec ->
                withFinalizedServiceRegistry
                    ProductionScope
                    baseCodec
                    demoServices
                    ( \codec registry -> do
                        let fullValidation =
                                inspectFullConfig
                                    (frameworkEnvelopeCodec ProductionScope codec)
                                    webCfg
                        frameworkWireKind fullValidation @?= FullProjectWire
                        frameworkScopeKind fullValidation @?= ProductionScope
                        withSelectedServiceRequest
                            "verified-config-digest"
                            (inspectLocalContext (context webCfg))
                            webCfg
                            registry
                            ( \_ roleCodec request _ _ -> do
                                let roleValidation = requestFrameworkValidation request
                                    rendered = renderValidatedServiceRequest roleCodec request
                                    changedDigest =
                                        T.replace
                                            (frameworkSpecDigest roleValidation)
                                            "ffffffffffffffff"
                                            rendered
                                    changedScope =
                                        T.replace
                                            ".ProductionScope"
                                            ".HarnessScope"
                                            rendered
                                frameworkWireKind roleValidation @?= ServiceRoleWire
                                frameworkScopeKind roleValidation @?= ProductionScope
                                frameworkLocalContext roleValidation
                                    @?= frameworkLocalContext fullValidation
                                frameworkSpecDigest roleValidation
                                    @?= roleCodecSpecDigest roleCodec
                                accepted <- decodeRoleWire roleCodec Dhall.defaultInputSettings rendered
                                case accepted of
                                    Right _ -> pure ()
                                    Left err -> assertFailure ("matching role wire was rejected: " ++ err)
                                rejectedDigest <- decodeRoleWire roleCodec Dhall.defaultInputSettings changedDigest
                                case rejectedDigest of
                                    Left _ -> pure ()
                                    Right _ -> assertFailure "changed spec digest was accepted"
                                rejectedScope <- decodeRoleWire roleCodec Dhall.defaultInputSettings changedScope
                                case rejectedScope of
                                    Left _ -> pure ()
                                    Right _ -> assertFailure "changed scope tag was accepted"
                            )
                            & either (assertFailure . show) id
                    )
        , testCase "the Direct derived build uses only the authenticated BuildKit channel" $ do
            commandsSource <- readFile "src/HostBootstrapDemo/Commands.hs"
            dockerfileSource <- readFile "docker/Dockerfile"
            coreCommandSource <- readFile "../core/hostbootstrap-core/src/HostBootstrap/Command.hs"
            let coordinatorTail = maybe "" (`drop` commandsSource) (substringOffset "runAuthenticatedDirectImageBuild ::" commandsSource)
                coordinator = maybe coordinatorTail (`take` coordinatorTail) (substringOffset "copyBuildTree ::" coordinatorTail)
                coordinatorStages =
                    [ "installedBuildSigningKey"
                    , "measureBinaryDigest executable"
                    , "measureSourceDigest (staged </> \"demo\")"
                    , "BuildBinding"
                    , "signBuildGrant coordinator binding"
                    , "renderBuildChannel channel"
                    , "--secret"
                    ]
                dockerStages =
                    [ "COPY demo /workspace/demo"
                    , "COPY --from=hostbootstrap-builder hostbootstrap-demo"
                    , "id=hostbootstrap-build-channel,required=true"
                    , "hostbootstrap-demo check-code"
                    , "cabal build --enable-tests --enable-benchmarks all"
                    ]
            coordinatorOffsets <- maybe (assertFailure "the authenticated coordinator lost a required stage") pure (traverse (`substringOffset` coordinator) coordinatorStages)
            dockerOffsets <- maybe (assertFailure "the Dockerfile lost a required authenticated stage") pure (traverse (`substringOffset` dockerfileSource) dockerStages)
            assertBool "coordinator stages are out of order" (and (zipWith (<) coordinatorOffsets (drop 1 coordinatorOffsets)))
            assertBool "Dockerfile stages are out of order" (and (zipWith (<) dockerOffsets (drop 1 dockerOffsets)))
            assertBool "the Dockerfile still mints its own image-build config" (not ("hostbootstrap-demo project init" `isInfixOf` dockerfileSource))
            assertBool "image-build check-code does not require the fixed channel" ("/run/secrets/hostbootstrap-build-channel" `isInfixOf` coreCommandSource)
            assertBool "the Direct call site still invokes raw docker build" ("runAuthenticatedDirectImageBuild execution parentCfg cfg repoRoot repoRootCfg pinnedBase verificationKeyHex" `isInfixOf` commandsSource)
            assertBool "the measured builder is not delivered by named context" ("hostbootstrap-builder=" `isInfixOf` coordinator)
            assertBool "the VM call site omits published-base digest resolution" ("resolvePublishedBaseInVM cfg provider mAuth" `isInfixOf` commandsSource)
            assertBool "the VM call site omits authenticated BuildKit secrets" ("withAuthenticatedVmBuildSecrets execution parentCfg cfg provider" `isInfixOf` commandsSource)
        ]

withBridgeTempDirectory :: (FilePath -> IO a) -> IO a
withBridgeTempDirectory = bracket create removePathForcibly
  where
    create = do
        tmp <- getTemporaryDirectory
        (path, handle) <- openTempFile tmp "hostbootstrap-purescript-bridge"
        hClose handle
        removeFile path
        createDirectory path
        pure path

toUpperAscii :: Char -> Char
toUpperAscii c
    | c >= 'a' && c <= 'z' = toEnum (fromEnum c - 32)
    | otherwise = c

hostCfg :: ProjectConfig ()
hostCfg =
    projectConfigForRole
        "hostbootstrap-demo"
        "hostbootstrap-demo"
        "/workspace/demo"
        demoDefaultDockerfile
        demoDefaultResources
        demoDefaultDeployConfig
        demoDefaultMessage
        HostOrchestrator
