{-# LANGUAGE CPP #-}

module Main (main) where

import qualified AuthoritySpec
import qualified HandoffProtocolSpec
import qualified HandoffReceiverSpec
import qualified HandoffRelaySpec
import qualified HandoffSpec
import qualified SessionSpec
import qualified BuildAuthoritySpec
import qualified ActivationSpec
import qualified CLISpec
import qualified BudgetSpec
import qualified ChainSpec
import qualified ColimaSpec
import qualified CompileFailSpec
import qualified ContextSpec
import qualified CordonSpec
import qualified DetachedSpec
import qualified DhallGenSpec
import qualified DocValidatorSpec
import qualified EnsureSpec
import qualified HarnessSpec
import qualified HostToolSpec
import qualified IncusSpec
import qualified LifecycleSpec
import qualified LiftSpec
import qualified LimaSpec
import qualified ProjectRootSpec
import qualified ClusterBackendSpec
import qualified DataRootSpec
import qualified GeneratedConfigSpec
import qualified ClusterReconcileSpec
import qualified ProviderSpec
import qualified ProviderAliasSpec
import qualified ReadinessSpec
import qualified ReconcileSpec
import qualified RegistryPlanSpec
import qualified RegistrySpec
import qualified RoleLifecycleSpec
import qualified ServiceProgramSpec
import qualified TeardownSpec
import qualified SchemaSpec
import qualified StepSpec
import qualified SubstrateSpec
import System.Environment (getArgs)
import Test.Tasty (defaultMain, localOption, testGroup)
import Test.Tasty.Runners (NumThreads (..))
import qualified Wsl2Spec
import qualified WslGlobalWallConfigBytesSpec
import qualified WslGlobalWallSpec
#if defined(mingw32_HOST_OS)
import qualified WslGlobalWallWindowsSpec
#else
import qualified WslGlobalWallHostSpec
#endif

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["--hostbootstrap-schema-fixture", fixture] ->
            CLISpec.runSchemaFixture fixture
        -- A separate process attempting the protected store's exclusive entry,
        -- so cross-process exclusion is proved with the production primitive.
        ["--hostbootstrap-protected-entry-probe", storeRoot] ->
            AuthoritySpec.runEntryProbe storeRoot
        -- A separate process attempting the *other* lifecycle profile against a
        -- live one, so the cross-profile exclusion is proved across processes
        -- rather than only within one.
        ["--hostbootstrap-mode-profile-probe", storeRoot, profile, reasonPath] ->
            AuthoritySpec.runModeProfileProbe storeRoot profile reasonPath
        -- A separate process that takes the plan's generation token, releases
        -- the store while the parent crosses the fence boundary, and then
        -- presents the now-delayed token.
        ["--hostbootstrap-fence-delay-probe", storeRoot, mode, readyPath, goPath, reasonPath] ->
            SessionSpec.runFenceDelayProbe storeRoot mode readyPath goPath reasonPath
        -- A separate process attempting a whole harness run reservation, so the
        -- concurrency matrix races real competitors rather than threads.
        ["--hostbootstrap-harness-acquire-probe", stateRoot, reasonPath] ->
            HarnessSpec.runHarnessAcquireProbe stateRoot reasonPath
        -- A separate process that takes a whole run AND installs its generated
        -- config, then blocks so the parent can hard-kill it. Only a real kill
        -- leaves the state the abandoned-run sweep exists to resolve: an
        -- in-process exception still runs every finalizer.
        ["--hostbootstrap-harness-abandon-probe", stateRoot, readyPath] ->
            HarnessSpec.runHarnessAbandonProbe stateRoot readyPath
        -- A real child running the in-binary handoff receiver on its own
        -- stdin/stdout, so the exchange crosses a process boundary rather than
        -- a thread one — and its diagnostics go to stderr, because stdout is
        -- the protocol.
        ("--hostbootstrap-handoff-receiver-probe" : probeArgs) ->
            HandoffReceiverSpec.runReceiverProbe probeArgs
        -- One frame of the nested relay chain. In relay mode it launches the
        -- next frame down and hands it an edge it obtained by relaying upward,
        -- because it holds no signing key of its own.
        ("--hostbootstrap-handoff-relay-probe" : probeArgs) ->
            HandoffRelaySpec.runRelayProbe probeArgs
        -- A real child launched through the sealed detached-launch boundary, so
        -- the invocation shape is observed by a process rather than asserted of
        -- a record field (§ HH).
        ("--hostbootstrap-detached-child-probe" : mode) ->
            DetachedSpec.runDetachedChildProbe mode
        _ -> do
            docTests <- DocValidatorSpec.tests
            -- The suite runs single-threaded because several groups drive
            -- process-global state that has no per-test scope: CLISpec,
            -- ContextSpec, HarnessSpec, and ProjectRootSpec bracket a
            -- 'withCurrentDirectory', and the harness/config ownership
            -- protocols resolve their protected store, data root, and generated
            -- config at paths relative to that working directory. Run
            -- concurrently, one group's chdir is visible to every other group,
            -- so the ownership transactions collide and a bracket's cleanup
            -- resolves a path it no longer owns. Those guards are the behaviour
            -- under test, so the fix is to stop scheduling them against each
            -- other rather than to weaken them. The whole suite is ~30s
            -- serially, so the ordering costs nothing worth reclaiming.
            defaultMain $
                localOption (NumThreads 1) $
                    testGroup
                        "hostbootstrap-core"
                        [ AuthoritySpec.tests
                        , HandoffProtocolSpec.tests
                        , HandoffSpec.tests
                        , HandoffReceiverSpec.tests
                        , HandoffRelaySpec.tests
                        , SessionSpec.tests
                        , BuildAuthoritySpec.tests
                        , ActivationSpec.tests
                        , CLISpec.tests
                        , BudgetSpec.tests
                        , CompileFailSpec.tests
                        , DetachedSpec.tests
                        , SubstrateSpec.tests
                        , HostToolSpec.tests
                        , EnsureSpec.tests
                        , ColimaSpec.tests
                        , SchemaSpec.tests
                        , DhallGenSpec.tests
                        , CordonSpec.tests
                        , ProviderSpec.tests
                        , ProviderAliasSpec.tests
                        , ClusterReconcileSpec.tests
                        , ClusterBackendSpec.tests
                        , DataRootSpec.tests
                        , GeneratedConfigSpec.tests
                        , ProjectRootSpec.tests
                        , ContextSpec.tests
                        , LifecycleSpec.tests
                        , HarnessSpec.tests
                        , IncusSpec.tests
                        , LimaSpec.tests
                        , Wsl2Spec.tests
                        , WslGlobalWallSpec.tests
                        , WslGlobalWallConfigBytesSpec.tests
#if defined(mingw32_HOST_OS)
                        , WslGlobalWallWindowsSpec.tests
#else
                        , WslGlobalWallHostSpec.tests
#endif
                        , LiftSpec.tests
                        , StepSpec.tests
                        , ChainSpec.tests
                        , ReadinessSpec.tests
                        , ReconcileSpec.tests
                        , RegistrySpec.tests
                        , RegistryPlanSpec.tests
                        , RoleLifecycleSpec.tests
                        , ServiceProgramSpec.tests
                        , TeardownSpec.tests
                        , docTests
                        ]
