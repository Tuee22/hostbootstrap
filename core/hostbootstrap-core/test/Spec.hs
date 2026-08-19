{-# LANGUAGE CPP #-}

module Main (main) where

import qualified AuthoritySpec
import qualified HandoffSpec
import qualified OwnershipObjectSpec
import qualified OwnershipPosixSpec
import qualified OwnershipShippedSpec
import qualified OwnershipSpec
import qualified OwnershipWindowsSpec
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
import qualified EffectSpec
import qualified DocValidatorSpec
import qualified EnsureSpec
import qualified GuestBootstrapSpec
import qualified HarnessSpec
import qualified HostToolSpec
import qualified IncusSpec
import qualified LifecycleSpec
import qualified LiftContextSpec
import qualified LiftSpec
import qualified LimaSpec
import qualified PortabilitySpec
import qualified ProjectRootSpec
import qualified ProjectPlanSpec
import qualified ClusterBackendSpec
import qualified DataRootSpec
import qualified GeneratedConfigSpec
import qualified ClusterReconcileSpec
import qualified ProviderSpec
import qualified ProviderAliasSpec
import qualified ProviderBackendSpec
import qualified ProviderReconcileSpec
import qualified ProviderCommandSpec
import qualified ProviderReportSpec
import qualified ProviderResumeSpec
import qualified ReadinessSpec
import qualified ReconcileSpec
import qualified RegistryPlanSpec
import qualified RegistrySpec
import qualified RoleLifecycleSpec
import qualified ServiceProgramSpec
import qualified TeardownSpec
import qualified SchemaSpec
import qualified SpecIndexSpec
import qualified StepSpec
import qualified SubstrateSpec
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import HostBootstrap.Handoff.Transaction (classifyFrameChild, frameInterpreter, runFrameChildEntry)
import HostBootstrap.Ownership.Shipped (interpretShippedOwnership)
import System.Environment (getArgs)
#if !defined(mingw32_HOST_OS)
import System.Posix.Files (setFileCreationMask)
#endif
import Test.Tasty (defaultMain, localOption, testGroup)
import Test.Tasty.Runners (NumThreads (..))
import qualified Wsl2Spec
import qualified CoverageManifest
import qualified WslGlobalWallConfigBytesSpec
import qualified WslGlobalWallHostSpec
import qualified WslGlobalWallSpec
import qualified WslGlobalWallWindowsSpec

{- | Normalize the process's file-creation mask, where the host has one.

Windows has no umask, so there is nothing to normalize and nothing to differ
between hosts; the definition is total on both.
-}
fixFileCreationMask :: IO ()
#if defined(mingw32_HOST_OS)
fixFileCreationMask = pure ()
#else
fixFileCreationMask = do
    _ <- setFileCreationMask 0o022
    pure ()
#endif

main :: IO ()
main = do
    -- Fix the text encoding before anything reads a file or a captured command
    -- output. The repository's source and governed documentation are UTF-8, and
    -- a spec that reads them through the host's active code page decodes
    -- different characters on a Windows host than on a POSIX one, so a line
    -- budget, a token count, a frozen digest, or a golden containing a section
    -- sign would be a property of the code page rather than of the bytes
    -- (§ JJ). The re-entrant probe branches below inherit it too, because a
    -- probe is a process of this same suite.
    setLocaleEncoding utf8
    -- Fix the file-creation mask for the same reason and in the same place. A
    -- fixture that writes a file inherits the launching shell's umask, so on a
    -- host whose umask is 0002 every file a fixture creates is group-writable —
    -- and a subject that refuses a group-writable input then fails on that host
    -- and passes on one whose umask is 0022. That makes the assertion a property
    -- of the shell rather than of the code under test, which is exactly what
    -- § JJ forbids. The mask is the conventional 0022 and is set before any
    -- fixture runs, so what a fixture writes is the same on every gate host. The
    -- re-entrant probe branches below inherit it too.
    fixFileCreationMask
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
        -- A separate process holding the POSIX ownership row's own exclusive
        -- open and then killed, so that the kernel releasing it is observed by a
        -- process actually dying rather than by a finalizer running.
        ["--hostbootstrap-ownership-posix-lock-probe", target, readyPath] ->
            OwnershipPosixSpec.runOwnershipPosixLockProbe target readyPath
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
        -- A real child launched through the sealed detached-launch boundary, so
        -- the invocation shape is observed by a process rather than asserted of
        -- a record field (§ HH).
        ("--hostbootstrap-detached-child-probe" : mode) ->
            DetachedSpec.runDetachedChildProbe mode
        -- The far side of a frame crossing, entered through the production
        -- classifier and running the production child body. Nothing about the
        -- branch is a fixture: the argument vector is the one the lift fold
        -- places at the leaf, and what answers on the other end of the pipes is
        -- the entry a real frame child runs.
        _
            | Just entry <- classifyFrameChild args ->
                runFrameChildEntry (frameInterpreter interpretShippedOwnership) entry
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
            --
            -- The manifest is assembled from the same list the runner is given,
            -- so what it counts is what runs. A family that lost a case on this
            -- gate host fails its declared count rather than reporting a smaller
            -- total (§ JJ).
            let suite =
                    [ PortabilitySpec.tests
                    , AuthoritySpec.tests
                    , HandoffSpec.tests
                    , OwnershipObjectSpec.tests
                    , OwnershipSpec.tests
                    , OwnershipShippedSpec.tests
                    , OwnershipPosixSpec.tests
                    , OwnershipWindowsSpec.tests
                    , SessionSpec.tests
                    , BuildAuthoritySpec.tests
                    , ActivationSpec.tests
                    , CLISpec.tests
                    , BudgetSpec.tests
                    , CompileFailSpec.tests
                    , DetachedSpec.tests
                    , EffectSpec.tests
                    , SubstrateSpec.tests
                    , HostToolSpec.tests
                    , EnsureSpec.tests
                    , GuestBootstrapSpec.tests
                    , ColimaSpec.tests
                    , SchemaSpec.tests
                    , SpecIndexSpec.tests
                    , DhallGenSpec.tests
                    , CordonSpec.tests
                    , ProviderSpec.tests
                    , ProviderAliasSpec.tests
                    , ProviderBackendSpec.tests
                    , ProviderReconcileSpec.tests
                    , ProviderCommandSpec.tests
                    , ProviderReportSpec.tests
                    , ProviderResumeSpec.tests
                    , ClusterReconcileSpec.tests
                    , ClusterBackendSpec.tests
                    , DataRootSpec.tests
                    , GeneratedConfigSpec.tests
                    , ProjectRootSpec.tests
                    , ProjectPlanSpec.tests
                    , ContextSpec.tests
                    , LifecycleSpec.tests
                    , HarnessSpec.tests
                    , IncusSpec.tests
                    , LimaSpec.tests
                    , Wsl2Spec.tests
                    , WslGlobalWallSpec.tests
                    , WslGlobalWallConfigBytesSpec.tests
                    , WslGlobalWallHostSpec.tests
                    , WslGlobalWallWindowsSpec.tests
                    , LiftContextSpec.tests
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
            defaultMain $
                localOption (NumThreads 1) $
                    testGroup "hostbootstrap-core" (CoverageManifest.tests suite : suite)
