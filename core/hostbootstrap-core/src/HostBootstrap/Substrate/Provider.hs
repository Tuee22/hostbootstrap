{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | One pure provider route into each host substrate.

Apple Silicon (Lima), native Linux (Incus), Windows (WSL2), and the direct host
share one lifecycle interface: probe existence, provision, reconcile-to-ready,
stage files, and tear down where the provider supports teardown. Historically
each substrate was hand-branched at every one of those IO sites in the consumer
binary; this
module collapses that to a single pure 'SubstrateProvider' value selected once
by 'selectSubstrateProvider' (the lifecycle peer of
'HostBootstrap.Cluster.Cordon.capacityReadPlan' and
'HostBootstrap.Lift.foldLeaf' — substrate knowledge as data, the IO a generic
interpreter).

Every per-substrate effect is expressed as pure data (a list of 'HostEffect'
and the probe/transfer records), so the whole surface is unit-testable without
running a host tool. The one place the substrates genuinely differ — Lima/Incus
launch with a single sized argv, whereas WSL2's only memory/CPU wall is the
/global/ @.wslconfig@ utility-VM ceiling that must be applied and made effective
with @wsl --shutdown@ before the distro boots — is captured by
'planProviderProvision' returning a /list/ of effects: an
'ApplyGlobalWslWall' for the WSL2 case, and no wall effect for the others. See
@documents/engineering/applied_cordon.md@ and
@documents/engineering/wsl2.md@.
-}
module HostBootstrap.Substrate.Provider (
    -- * Closed provider dispatch
    ProviderKind (..),
    providerKindForSubstrate,
    providerTopologyKind,

    -- * Pure effect vocabulary
    HostEffect (..),
    DirectHostAction (..),
    Membership (..),
    ExistsProbe (..),
    WaitProbe (..),
    FileTransfer (..),
    StagedFile (..),
    ShareReconcile (..),
    HostPathShare (..),

    -- * The one pure provider route per substrate
    VMHandles (..),
    SubstrateProvider,
    providerVmId,
    providerKind,
    providerLiftContext,
    providerExistsProbe,
    providerWaitProbe,
    providerFileTransfer,
    selectProviderKind,
    selectSubstrateProvider,

    -- * Discovery-retained lifecycle operations
    ProviderOperation (..),
    ProviderError (..),
    ProviderObservation (..),
    GuestLockPrimitive (..),
    GuestStatDialect (..),
    GuestPythonCapability (..),
    GuestProviderDiscovery (..),
    DirectProviderDiscovery (..),
    ProviderDiscovery (..),
    ProviderProbeRequest,
    ProviderProbeRequestView (..),
    DirectProbe (..),
    RawProviderOutcome (..),
    providerProbeRequestView,
    ProviderGuestExecutor,
    ProviderCapability,
    discoverProvider,
    providerCapabilityKind,
    providerCapabilityDiscovery,
    providerCapabilityGeneration,
    providerCapabilityGuestExecutor,
    RebootReadyPlan (..),
    planProviderProvision,
    planProviderRebootReady,
    planProviderStop,
    planProviderDelete,
    planProviderShare,
    planProviderAlias,

    -- * Pure interpreters over the provider's data
    foldExistsProbe,
    foldWaitProbe,
    membersOf,
    shareReconcileEffects,
    stageFileEffects,
    vmShellArgs,
    windowsPathToWslMount,

    -- * Guest-side durable alias (one pure state machine, § DD)
    AliasNodeKind (..),
    AliasState (..),
    AliasFacts (..),
    classifyAlias,
    AliasAction (..),
    planAliasEnsure,
    AliasRemoval (..),
    planAliasRemove,
)
where

import Control.Exception (IOException, catch, displayException)
import Data.Char (isAsciiUpper)
import Data.List (dropWhileEnd, isPrefixOf)
import Data.Word (Word64)
import HostBootstrap.Cluster.Cordon (
    budgetFromResources,
    budgetStorageBytes,
    gibibytes,
    incusSizingArgs,
    limaSizingArgs,
    wsl2SizingArgs,
 )
import HostBootstrap.Context (ResourceEnvelope)
import qualified HostBootstrap.Context as Context
import HostBootstrap.HostTool (HostTool (Incus, Lima, Wsl))
import HostBootstrap.Incus (
    IncusVM (..),
    addDiskDeviceArgs,
    createVMArgs,
    destroyVMArgs,
    deviceListArgs,
    execVMArgs,
    pushFileArgs,
    startVMArgs,
    stopVMArgs,
 )
import HostBootstrap.Lift (
    LiftContext (..),
    LiftDispatch (..),
    LiftLayer (..),
    LiftLeaf (..),
    foldLeaf,
    inLimaVM,
    inVM,
    inWsl2VM,
    localContext,
 )
import HostBootstrap.Lima (LimaVM (..))
import qualified HostBootstrap.Lima as Lima
import HostBootstrap.Readiness (
    Decision (..),
    PollError (..),
    PollPolicy,
    ProbeConflict (..),
    ProbeFailure (..),
    ProbeResult (..),
    mkPollPolicy,
    pollStep,
    seconds,
 )
import HostBootstrap.Reconcile (Running)
import HostBootstrap.Substrate (Substrate, SubstrateName (..), substrateName)
import HostBootstrap.Substrate.Provider.Internal (
    DirectProbe (..),
    ProviderBoundExec,
    ProviderBoundRoute (..),
    ProviderGuestExecutor,
    ProviderProbeRequest,
    ProviderProbeRequestView (..),
    RawProviderOutcome (..),
    bindProviderGuestExecutor,
    directProbeRequest,
    guestProbeRequest,
    hostToolRequest,
    providerBoundRoute,
    providerProbeRequestView,
    provisioningEgressRequest,
    runProviderBoundExec,
    waitProviderBoundExec,
 )
import HostBootstrap.Substrate.Provider.Reconcile (
    ManagedProviderHandle,
    managedProviderGeneration,
 )
import HostBootstrap.Wsl2 (Wsl2VM (..))
import qualified HostBootstrap.Wsl2 as Wsl2
import Numeric.Natural (Natural)
import System.Exit (ExitCode (..))

{- | The closed lifecycle-provider vocabulary.

This is intentionally narrower than the topology vocabulary in
"HostBootstrap.Context": containers, Kubernetes, and external placements are
not host-frame lifecycle providers. Every value here has one total
'selectProviderKind' branch.
-}
data ProviderKind
    = ProviderIncus
    | ProviderLima
    | ProviderWsl2
    | ProviderDirectHost
    deriving (Eq, Show)

-- | Select the lifecycle provider implied by a concrete host substrate.
providerKindForSubstrate :: Substrate -> ProviderKind
providerKindForSubstrate sub = case substrateName sub of
    AppleSilicon -> ProviderLima
    LinuxCpu -> ProviderIncus
    LinuxGpu -> ProviderDirectHost
    WindowsCpu -> ProviderWsl2
    WindowsGpu -> ProviderWsl2

-- | Project the closed lifecycle kind into the wider topology vocabulary.
providerTopologyKind :: ProviderKind -> Context.ProviderKind
providerTopologyKind kind = case kind of
    ProviderIncus -> Context.IncusVMProvider
    ProviderLima -> Context.LimaVMProvider
    ProviderWsl2 -> Context.Wsl2VMProvider
    ProviderDirectHost -> Context.HostProvider

{- | A single pure host-side effect the lifecycle interpreter runs.
'ApplyGlobalWslWall' and 'ReleaseGlobalWslWall' are the WSL2 @.wslconfig@ wall (a
/global/ user file); 'RunHostTool' is a resolved VM-provider tool invocation,
and 'RunDirectHost' makes an already-local host transition explicit.

Neither wall effect carries a pathname.  The wall is the current user's one
@%UserProfile%\\.wslconfig@, derived by
'HostBootstrap.Wsl2.GlobalWall.Windows' itself, and it is acquired through the
identity-owning host-wall backend rather than a backup copy: an origin record is
journalled before the first mutation and release is conditioned on re-observing
the same object.  Release therefore carries the same managed body it was applied
with, because the wall's specification identity binds owner and body together —
a different declaration is a structured conflict, not an overwrite.
-}
data HostEffect
    = -- | acquire the per-user global WSL wall with this managed body
      ApplyGlobalWslWall [String]
    | -- | release the per-user global WSL wall applied with this managed body
      ReleaseGlobalWslWall [String]
    | -- | run a resolved host tool with these args
      RunHostTool HostTool [String]
    | -- | perform an explicit lifecycle transition on the already-local host
      RunDirectHost DirectHostAction
    deriving (Eq, Show)

{- | Direct-host lifecycle transitions are explicit effects, not silent empty
lists. The generic interpreter can therefore distinguish "the local host is the
selected frame" from "the provider forgot to implement this operation".
-}
data DirectHostAction
    = RealizeDirectHost
    | ReconcileDirectHostReady
    deriving (Eq, Show)

-- | How to read membership of a VM name out of an existence-probe's stdout.
data Membership
    = -- | the name is one of the output lines (@incus list@ / @limactl list@)
      LinesMember
    | -- | the name is a whitespace token of the NUL-stripped output (@wsl --list --quiet@)
      WslQuietMember
    | -- | the name is a RUNNING distro per @wsl --list --verbose@ (the STATE column)
      WslRunningMember
    deriving (Eq, Show)

{- | An idempotency probe: list with @tool args@, then test a caller-owned
membership key (a VM id or managed device name) against the parsed output by
'Membership'.
-}
data ExistsProbe
    = ExistsProbe HostTool [String] Membership
    | DirectHostExistsProbe
    deriving (Eq, Show)

{- | A readiness probe: @tool args@ that runs a trivial @true@ in the VM and
succeeds once the VM answers.
-}
data WaitProbe
    = WaitProbe HostTool [String]
    | DirectHostReadyProbe
    deriving (Eq, Show)

{- | How a host file reaches its execution frame: a tool push (Lima/Incus), an
in-place @/mnt@ drive projection for WSL2, or its unchanged path on direct host.
-}
data FileTransfer
    = IncusFileTransfer IncusVM
    | LimaFileTransfer LimaVM
    | Wsl2MountTransfer Wsl2VM
    | DirectHostTransfer
    deriving (Eq, Show)

{- | The result of planning one file transfer: the host effects to place the file,
the path the guest reads it from, and whether that path is a pushed temporary
(so the caller removes it after) or an in-place mount (so it does not).
-}
data StagedFile = StagedFile
    { sfHostEffects :: [HostEffect]
    , sfGuestPath :: FilePath
    , sfPushedTemp :: Bool
    }
    deriving (Eq, Show)

{- | An optional post-create share reconciliation. The probe lists membership
keys, 'srMember' is the managed key to look for, and 'srWhenMissing' is the
effect list to run only when that key is absent. Incus uses this to make its
post-create disk-device attachment idempotent; Lima declares the share at VM
creation and WSL2 already exposes the host drive, so both use 'Nothing'.
-}
data ShareReconcile = ShareReconcile
    { srProbe :: ExistsProbe
    , srMember :: String
    , srWhenMissing :: [HostEffect]
    }
    deriving (Eq, Show)

{- | One host-backed directory as seen on both sides of a provider boundary.
Lima and Incus preserve the absolute path in the guest; WSL2 projects a Windows
drive path into its DrvFs mount. 'hpsReconcile' captures only an extra
/post-create/ step; Lima's create-time option is folded into the provision
plan.
-}
data HostPathShare = HostPathShare
    { hpsHostPath :: FilePath
    , hpsGuestPath :: FilePath
    , hpsReconcile :: Maybe ShareReconcile
    }
    deriving (Eq, Show)

{- | The consumer-supplied handles the pure selection needs: the per-substrate VM
identities and the delete-guard prefix. No @.wslconfig@ pathname appears here:
the wall backend derives the current user's one target and accepts none.
-}
data VMHandles = VMHandles
    { vmhIncus :: IncusVM
    , vmhLima :: LimaVM
    , vmhWsl2 :: Wsl2VM
    , vmhGuardPrefix :: String
    }
    deriving (Eq, Show)

{- | The one pure provider route into a substrate.  Provision planning depends
on the active 'ResourceEnvelope' and an optional host-path share; share
planning projects a caller-supplied absolute host path into the
provider-specific pure share plan. A provision 'Left' carries a budget-parse
error. Delete planning returns 'Left' when the guard prefix refuses the VM name.
-}
data SubstrateProvider = SubstrateProvider
    { spVmId :: String
    , spProviderKind :: ProviderKind
    , spLiftContext :: LiftContext
    -- ^ one guest boundary for VM providers; 'localContext' for direct host
    , spExists :: ExistsProbe
    , spLaunch :: ResourceEnvelope -> Maybe HostPathShare -> Either String [HostEffect]
    , spShare :: FilePath -> HostPathShare
    , spStartExisting :: [HostEffect]
    , spReconcileCordon :: Maybe (ExistsProbe, [HostEffect])
    {- ^ @Nothing@ where the cordon is baked into the VM at create (Lima/Incus,
    which never idle-stop). @Just@ for WSL2, whose cordon is the GLOBAL
    @.wslconfig@ that only takes effect on a utility-VM restart: a running-state
    probe plus the effects to run when the distro is STOPPED (safe to restart).
    -}
    , spWait :: WaitProbe
    , spTransfer :: FileTransfer
    , spStop :: ResourceEnvelope -> Either String [HostEffect]
    , spDestroy :: ResourceEnvelope -> Either String [HostEffect]
    }

-- Read-only descriptive projections.  The record constructor and its @sp*@
-- fields stay private, so callers cannot replace a route, probe, or mutation
-- planner by record update.
providerVmId :: SubstrateProvider -> String
providerVmId = spVmId

providerKind :: SubstrateProvider -> ProviderKind
providerKind = spProviderKind

providerLiftContext :: SubstrateProvider -> LiftContext
providerLiftContext = spLiftContext

providerExistsProbe :: SubstrateProvider -> ExistsProbe
providerExistsProbe = spExists

providerWaitProbe :: SubstrateProvider -> WaitProbe
providerWaitProbe = spWait

providerFileTransfer :: SubstrateProvider -> FileTransfer
providerFileTransfer = spTransfer

-- | Lifecycle operations plus the structured guest-route eliminator.
data ProviderOperation
    = ProviderProvision
    | ProviderRebootReady
    | ProviderStop
    | ProviderDelete
    | ProviderShare
    | ProviderAlias
    | ProviderGuestRoute
    deriving (Eq, Show)

{- | Structured provider failure. 'ProviderUnsupported' means the selected
provider or retained discovery facts cannot supply the requested semantics;
'ProviderOperationFailure' means an implemented operation rejected its concrete
input. Neither case is represented by an empty effect list.
-}
data ProviderError
    = ProviderUnsupported
        { providerErrorKind :: ProviderKind
        , providerErrorOperation :: ProviderOperation
        , providerErrorCause :: String
        }
    | ProviderOperationFailure
        { providerErrorKind :: ProviderKind
        , providerErrorOperation :: ProviderOperation
        , providerErrorCause :: String
        }
    deriving (Eq, Show)

{- | Total result of one provider-owned probe.  These values are descriptive
views only: discovery never accepts one from its caller and no constructor here
mints authority.
-}
data ProviderObservation value
    = ProviderObservedReady value
    | ProviderObservedNotReady String
    | ProviderObservedUnavailable String
    | ProviderObservedConflict ProbeConflict
    | ProviderObservedFailure ProbeFailure
    deriving (Eq, Show)

data GuestLockPrimitive = GuestFlock FilePath | GuestLockf FilePath
    deriving (Eq, Show)

data GuestStatDialect = GuestGnuStat FilePath | GuestBsdStat FilePath
    deriving (Eq, Show)

data GuestPythonCapability = GuestPython3 FilePath
    deriving (Eq, Show)

-- | The seven observations that exist only for a real guest provider.
data GuestProviderDiscovery = GuestProviderDiscovery
    { discoveryDaemon :: ProviderObservation ()
    , discoveryPermissions :: ProviderObservation ()
    , discoveryVmCapability :: ProviderObservation ()
    , discoveryEgress :: ProviderObservation ()
    , discoveryGuestLock :: ProviderObservation GuestLockPrimitive
    , discoveryGuestStat :: ProviderObservation GuestStatDialect
    , discoveryGuestPython :: ProviderObservation GuestPythonCapability
    }
    deriving (Eq, Show)

{- | Direct host has exactly its two applicable observations.  There is no
representable daemon, VM, lock, stat, or guest-Python slot to fill in.
-}
data DirectProviderDiscovery = DirectProviderDiscovery
    { discoveryDirectPermissions :: ProviderObservation ()
    , discoveryDirectEgress :: ProviderObservation ()
    }
    deriving (Eq, Show)

data ProviderDiscovery
    = ProviderGuestDiscovery GuestProviderDiscovery
    | ProviderDirectDiscovery DirectProviderDiscovery
    deriving (Eq, Show)

{- | Post-management discovery evidence for one exact provider resource.

It is deliberately not a mutation-backend argument.  It retains the exact raw
executor only so a narrower package-owned guest backend can stay on the same
provider route; public code cannot project an arbitrary argv runner from it.
-}
data ProviderCapability scope planId providerId backendId capabilityId
    = ProviderCapability
        (ManagedProviderHandle scope planId backendId providerId Running)
        SubstrateProvider
        ProviderDiscovery
        (Maybe (ProviderGuestExecutor scope planId providerId Running backendId capabilityId))

type role ProviderCapability nominal nominal nominal nominal nominal

data ProbePlan value
    = ProbePlan
        String
        (Either String ProviderProbeRequest)
        (RawProviderOutcome -> ProbeResult value)

data ProviderDiscoveryPlan
    = GuestDiscoveryPlan
        (ProbePlan ())
        (ProbePlan ())
        (ProbePlan ())
        (ProbePlan ())
        [ProbePlan GuestLockPrimitive]
        (ProbePlan FilePath)
        (ProbePlan FilePath)
    | DirectDiscoveryPlan (ProbePlan ()) (ProbePlan ())

{- | Execute only provider-owned closed probe requests against raw outcomes.

The managed handle fixes scope, plan, and provider resource identity before the
fresh capability identity is introduced.  The injected executor cannot return
@ProviderObservation@ (or any semantic status); private total parsers and a
module-owned bounded poll policy are the sole route from raw process output to
the retained report.
-}
discoverProvider ::
    ManagedProviderHandle scope planId backendId providerId Running ->
    SubstrateProvider ->
    ProviderBoundExec scope planId providerId Running backendId ->
    (forall capabilityId. ProviderCapability scope planId providerId backendId capabilityId -> IO result) ->
    IO (Either ProviderError result)
discoverProvider managed provider exec consume =
    case validateBoundProviderRoute provider (providerBoundRoute exec) of
        Left failure -> pure (Left failure)
        Right () -> do
            discovery <- runDiscoveryPlan exec (providerDiscoveryPlan provider)
            case discovery of
                ProviderDirectDiscovery _ ->
                    Right <$> consume (ProviderCapability managed provider discovery Nothing)
                ProviderGuestDiscovery _ -> do
                    let guestExecutor =
                            bindProviderGuestExecutor $ \argv ->
                                executeRaw exec (guestProbeRequest argv)
                    Right <$> consume (ProviderCapability managed provider discovery (Just guestExecutor))

validateBoundProviderRoute :: SubstrateProvider -> ProviderBoundRoute -> Either ProviderError ()
validateBoundProviderRoute provider boundRoute =
    case (spProviderKind provider, boundRoute, spTransfer provider) of
        (ProviderIncus, ProviderBoundIncusRoute boundName boundImage, IncusFileTransfer (IncusVM expectedName expectedImage))
            | boundName == expectedName && boundImage == expectedImage -> Right ()
            | otherwise -> mismatch ("Incus route " ++ show (boundName, boundImage)) ("Incus route " ++ show (expectedName, expectedImage))
        (ProviderDirectHost, ProviderBoundDirectRoute _ _, DirectHostTransfer) -> Right ()
        _ -> mismatch (show boundRoute) (show (spProviderKind provider, spVmId provider))
  where
    mismatch observed expected =
        Left
            ProviderOperationFailure
                { providerErrorKind = spProviderKind provider
                , providerErrorOperation = ProviderGuestRoute
                , providerErrorCause =
                    "the bound provider backend route does not match the selected substrate provider; expected "
                        ++ expected
                        ++ ", observed "
                        ++ observed
                }

providerCapabilityKind :: ProviderCapability scope planId providerId backendId capabilityId -> ProviderKind
providerCapabilityKind (ProviderCapability _ provider _ _) = spProviderKind provider

providerCapabilityDiscovery :: ProviderCapability scope planId providerId backendId capabilityId -> ProviderDiscovery
providerCapabilityDiscovery (ProviderCapability _ _ discovery _) = discovery

providerCapabilityGeneration :: ProviderCapability scope planId providerId backendId capabilityId -> Word64
providerCapabilityGeneration (ProviderCapability managed _ _ _) = managedProviderGeneration managed

providerCapabilityGuestExecutor ::
    ProviderCapability scope planId providerId backendId capabilityId ->
    Either ProviderError (ProviderGuestExecutor scope planId providerId Running backendId capabilityId)
providerCapabilityGuestExecutor capability@(ProviderCapability _ _ _ guestExecutor) =
    case guestExecutor of
        Just executor -> Right executor
        Nothing -> unsupported ProviderAlias capability "the direct host has no guest execution route"

providerDiscoveryPlan :: SubstrateProvider -> ProviderDiscoveryPlan
providerDiscoveryPlan provider =
    case spProviderKind provider of
        ProviderDirectHost ->
            DirectDiscoveryPlan
                (unitPlan "direct-host permissions" (Right (directProbeRequest DirectPermissionProbe)))
                (unitPlan "direct-host provisioning egress" (Right provisioningEgressRequest))
        _ ->
            GuestDiscoveryPlan
                (unitPlan "provider daemon" (existsRequest provider))
                (unitPlan "provider permissions" (existsRequest provider))
                (unitPlan "provider VM capability" (guestRequest provider ["true"]))
                (unitPlan "provider provisioning egress" (egressRequest provider))
                [ whichPlan "guest flock" (guestRequest provider ["which", "flock"]) "flock" GuestFlock
                , whichPlan "guest lockf" (guestRequest provider ["which", "lockf"]) "lockf" GuestLockf
                ]
                (whichPlan "guest stat executable" (guestRequest provider ["which", "stat"]) "stat" id)
                (whichPlan "guest Python 3 executable" (guestRequest provider ["which", "python3"]) "python3" id)

runDiscoveryPlan :: ProviderBoundExec scope planId providerId phase backendId -> ProviderDiscoveryPlan -> IO ProviderDiscovery
runDiscoveryPlan exec plan = case plan of
    DirectDiscoveryPlan permissions egress ->
        ProviderDirectDiscovery
            <$> (DirectProviderDiscovery <$> runProbePlan exec permissions <*> runProbePlan exec egress)
    GuestDiscoveryPlan daemon permissions vm egress locks statExecutable pythonExecutable -> do
        retainedDaemon <- runProbePlan exec daemon
        case retainedDaemon of
            ProviderObservedReady () -> do
                retainedPermissions <- runProbePlan exec permissions
                case retainedPermissions of
                    ProviderObservedReady () -> do
                        retainedVm <- runProbePlan exec vm
                        case retainedVm of
                            ProviderObservedReady () -> do
                                retainedEgress <- runProbePlan exec egress
                                lock <- runAlternatives exec "guest lock frontend" locks
                                retainedStatExecutable <- runProbePlan exec statExecutable
                                statDialect <- case retainedStatExecutable of
                                    ProviderObservedReady executable ->
                                        runAlternatives
                                            exec
                                            "guest stat dialect"
                                            [ statPlan "guest GNU stat" (Right (guestProbeRequest [executable, "-c", "%d:%i", "/"])) (GuestGnuStat executable)
                                            , statPlan "guest BSD stat" (Right (guestProbeRequest [executable, "-f", "%d:%i", "/"])) (GuestBsdStat executable)
                                            ]
                                    other -> pure (propagateObservation other)
                                retainedPythonExecutable <- runProbePlan exec pythonExecutable
                                python <- case retainedPythonExecutable of
                                    ProviderObservedReady executable ->
                                        runProbePlan
                                            exec
                                            ( pythonMarkerPlan
                                                "guest Python 3"
                                                (Right (guestProbeRequest [executable, "-c", "print('hostbootstrap-python3')"]))
                                                "hostbootstrap-python3"
                                                (GuestPython3 executable)
                                            )
                                    other -> pure (propagateObservation other)
                                pure
                                    ( ProviderGuestDiscovery
                                        ( GuestProviderDiscovery
                                            retainedDaemon
                                            retainedPermissions
                                            retainedVm
                                            retainedEgress
                                            lock
                                            statDialect
                                            python
                                        )
                                    )
                            notReadyVm ->
                                pure
                                    ( ProviderGuestDiscovery
                                        ( blockedGuestDiscovery
                                            retainedDaemon
                                            retainedPermissions
                                            notReadyVm
                                            notReadyVm
                                        )
                                    )
                    unavailablePermissions ->
                        pure
                            ( ProviderGuestDiscovery
                                ( blockedGuestDiscovery
                                    retainedDaemon
                                    unavailablePermissions
                                    unavailablePermissions
                                    unavailablePermissions
                                )
                            )
            unavailableDaemon ->
                pure
                    ( ProviderGuestDiscovery
                        ( blockedGuestDiscovery
                            unavailableDaemon
                            unavailableDaemon
                            unavailableDaemon
                            unavailableDaemon
                        )
                    )

blockedGuestDiscovery ::
    ProviderObservation daemon ->
    ProviderObservation permissions ->
    ProviderObservation vm ->
    ProviderObservation egress ->
    GuestProviderDiscovery
blockedGuestDiscovery daemon permissions vm egress =
    GuestProviderDiscovery
        (propagateObservation daemon)
        (propagateObservation permissions)
        (propagateObservation vm)
        (propagateObservation egress)
        (propagateObservation vm)
        (propagateObservation vm)
        (propagateObservation vm)

propagateObservation :: ProviderObservation source -> ProviderObservation target
propagateObservation observed = case observed of
    ProviderObservedReady _ ->
        ProviderObservedFailure
            ProbeFailure
                { failedOperation = "propagate provider discovery observation"
                , failureCause = "an unexpected ready observation lacked its dependent probe"
                }
    ProviderObservedNotReady reason -> ProviderObservedNotReady reason
    ProviderObservedUnavailable reason -> ProviderObservedUnavailable reason
    ProviderObservedConflict conflict -> ProviderObservedConflict conflict
    ProviderObservedFailure failure -> ProviderObservedFailure failure

runAlternatives :: ProviderBoundExec scope planId providerId phase backendId -> String -> [ProbePlan value] -> IO (ProviderObservation value)
runAlternatives _ label [] = pure (ProviderObservedUnavailable (label ++ " has no supported probe plan"))
runAlternatives exec label (candidate : rest) = do
    observed <- runProbePlan exec candidate
    case observed of
        ProviderObservedReady value -> pure (ProviderObservedReady value)
        ProviderObservedUnavailable _
            | not (null rest) -> runAlternatives exec label rest
        ProviderObservedNotReady _ -> pure observed
        ProviderObservedConflict _ -> pure observed
        ProviderObservedFailure _ -> pure observed
        ProviderObservedUnavailable _ -> pure observed

runProbePlan :: ProviderBoundExec scope planId providerId phase backendId -> ProbePlan value -> IO (ProviderObservation value)
runProbePlan _ (ProbePlan _ (Left reason) _) = pure (ProviderObservedUnavailable reason)
runProbePlan exec (ProbePlan label (Right request) parse) =
    case providerDiscoveryPoll of
        Left failure -> pure (ProviderObservedFailure failure)
        Right policy -> go policy (0 :: Natural)
  where
    go policy attempt = do
        raw <- executeRaw exec request
        case pollStep policy label attempt (parse raw) of
            Yield value -> pure (ProviderObservedReady value)
            Retry delay -> waitProviderBoundExec exec delay >> go policy (attempt + 1)
            GiveUp pollError -> pure (observationFromPollError pollError)

executeRaw :: ProviderBoundExec scope planId providerId phase backendId -> ProviderProbeRequest -> IO RawProviderOutcome
executeRaw exec request =
    runProviderBoundExec exec request `catch` executionFailure
  where
    executionFailure failure =
        pure (RawProviderFailure (displayException (failure :: IOException)))

providerDiscoveryPoll :: Either ProbeFailure PollPolicy
providerDiscoveryPoll =
    case seconds 1 >>= mkPollPolicy 60 of
        Right policy -> Right policy
        Left failure ->
            Left
                ProbeFailure
                    { failedOperation = "construct provider discovery polling policy"
                    , failureCause = "invalid closed provider discovery policy: " ++ show failure
                    }

observationFromPollError :: PollError -> ProviderObservation value
observationFromPollError pollError = case pollError of
    PollTimeout _ observation -> ProviderObservedNotReady observation
    PollUnavailable _ reason -> ProviderObservedUnavailable reason
    PollConflict _ conflict -> ProviderObservedConflict conflict
    PollFailed _ failure -> ProviderObservedFailure failure

unitPlan :: String -> Either String ProviderProbeRequest -> ProbePlan ()
unitPlan label request = ProbePlan label request parseUnit

whichPlan :: String -> Either String ProviderProbeRequest -> String -> (FilePath -> value) -> ProbePlan value
whichPlan label request basename retain =
    ProbePlan label request $ \raw -> case raw of
        RawProviderExit ExitSuccess out err ->
            case exactSuccessfulLine label out err of
                Right executable
                    | exactAbsoluteBasename basename executable -> ProbeReady (retain executable)
                    | otherwise -> malformed label ("expected one absolute " ++ basename ++ " path, observed " ++ show executable)
                Left reason -> malformed label reason
        RawProviderExit (ExitFailure code) out err -> candidateUnavailable label code out err
        RawProviderFailure reason -> rawExecutionFailure label reason

statPlan :: String -> Either String ProviderProbeRequest -> value -> ProbePlan value
statPlan label request value =
    ProbePlan label request $ \raw -> case raw of
        RawProviderExit ExitSuccess out err ->
            case exactSuccessfulLine label out err of
                Right identity
                    | validDeviceInode identity -> ProbeReady value
                    | otherwise -> malformed label ("invalid device:inode report " ++ show identity)
                Left reason -> malformed label reason
        RawProviderExit (ExitFailure code) out err -> candidateUnavailable label code out err
        RawProviderFailure reason -> rawExecutionFailure label reason

pythonMarkerPlan :: String -> Either String ProviderProbeRequest -> String -> value -> ProbePlan value
pythonMarkerPlan label request marker value =
    ProbePlan label request $ \raw -> case raw of
        RawProviderExit ExitSuccess out err ->
            case exactSuccessfulLine label out err of
                Right observed
                    | observed == marker -> ProbeReady value
                    | otherwise -> malformed label ("expected exact marker " ++ show marker ++ ", observed " ++ show observed)
                Left reason -> malformed label reason
        RawProviderExit (ExitFailure code) out err -> candidateUnavailable label code out err
        RawProviderFailure reason -> rawExecutionFailure label reason

exactSuccessfulLine :: String -> String -> String -> Either String String
exactSuccessfulLine label out err
    | not (null err) = Left (label ++ " wrote unexpected stderr: " ++ show (firstLine err))
    | length out > 1024 = malformedLine
    | '\r' `elem` out = malformedLine
    | null out || last out /= '\n' = malformedLine
    | length (filter (== '\n') out) /= 1 = malformedLine
    | otherwise = Right (init out)
  where
    malformedLine = Left (label ++ " returned a non-exact single-line report: " ++ show (firstLine out))

candidateUnavailable :: String -> Int -> String -> String -> ProbeResult value
candidateUnavailable label code out err =
    Unavailable
        ( label
            ++ " candidate exited "
            ++ show code
            ++ candidateDiagnostic out err
        )

candidateDiagnostic :: String -> String -> String
candidateDiagnostic out err =
    case firstLine (out ++ err) of
        "" -> ""
        diagnostic -> ": " ++ diagnostic

rawExecutionFailure :: String -> String -> ProbeResult value
rawExecutionFailure label reason = case providerConflictMarker reason of
    Just conflict -> ProbeConflicted conflict
    Nothing ->
        Failed
            ProbeFailure
                { failedOperation = label
                , failureCause = reason
                }

providerConflictMarker :: String -> Maybe ProbeConflict
providerConflictMarker raw = case words raw of
    ["HB_PROVIDER_CONFLICT", expected, observed, reason]
        | unwords ["HB_PROVIDER_CONFLICT", expected, observed, reason] == raw
        , all validConflictToken [expected, observed, reason] ->
            Just
                ProbeConflict
                    { conflictExpected = expected
                    , conflictObserved = observed
                    , conflictRemedy = "resolve the provider identity conflict before retrying (" ++ reason ++ ")"
                    }
    _ -> Nothing

validConflictToken :: String -> Bool
validConflictToken value =
    not (null value)
        && length value <= 240
        && all
            ( \character ->
                (character >= 'A' && character <= 'Z')
                    || (character >= 'a' && character <= 'z')
                    || (character >= '0' && character <= '9')
                    || character `elem` (":._/=-" :: String)
            )
            value

parseUnit :: RawProviderOutcome -> ProbeResult ()
parseUnit raw = case raw of
    RawProviderExit ExitSuccess _ _ -> ProbeReady ()
    _ -> classifyRawFailure "provider probe" raw

classifyRawFailure :: String -> RawProviderOutcome -> ProbeResult value
classifyRawFailure label raw = case raw of
    RawProviderFailure reason -> rawExecutionFailure label reason
    RawProviderExit ExitSuccess out _ -> malformed label ("unexpected successful output " ++ show (firstLine out))
    RawProviderExit (ExitFailure code) out err
        | any (`isPrefixOf` lower) ["not ready", "starting", "connection refused", "daemon is not running"] ->
            NotReady (firstLine combined)
        | any (`isPrefixOf` lower) ["not found", "unsupported", "no such file"] ->
            Unavailable (firstLine combined)
        | otherwise ->
            Failed
                ProbeFailure
                    { failedOperation = label
                    , failureCause = "exit " ++ show code ++ ": " ++ firstLine combined
                    }
      where
        combined = dropWhile (`elem` [' ', '\t', '\r', '\n']) (out ++ err)
        lower = map asciiLower combined

malformed :: String -> String -> ProbeResult value
malformed label reason = Failed (ProbeFailure label reason)

firstLine :: String -> String
firstLine = takeWhile (`notElem` ['\r', '\n'])

asciiLower :: Char -> Char
asciiLower character
    | character >= 'A' && character <= 'Z' = toEnum (fromEnum character + 32)
    | otherwise = character

validDeviceInode :: String -> Bool
validDeviceInode value =
    case break (== ':') value of
        (device, ':' : inode) -> not (null device) && not (null inode) && all isAsciiDigit device && all isAsciiDigit inode
        _ -> False
  where
    isAsciiDigit digit = digit >= '0' && digit <= '9'

exactAbsoluteBasename :: String -> String -> Bool
exactAbsoluteBasename basename path =
    case path of
        '/' : _ ->
            all (`notElem` ['\r', '\n']) path
                && reverse (takeWhile (/= '/') (reverse path)) == basename
        _ -> False

existsRequest :: SubstrateProvider -> Either String ProviderProbeRequest
existsRequest provider = case spExists provider of
    ExistsProbe tool args _ -> Right (hostToolRequest tool args)
    DirectHostExistsProbe -> Left "a direct provider has no daemon probe"

guestRequest :: SubstrateProvider -> [String] -> Either String ProviderProbeRequest
guestRequest provider command = case spProviderKind provider of
    ProviderDirectHost -> Left "the direct host has no guest probe route"
    _ -> Right (guestProbeRequest command)

egressRequest :: SubstrateProvider -> Either String ProviderProbeRequest
egressRequest _ = Right provisioningEgressRequest

-- | Reboot/reconcile-to-ready is one operation with a uniform result shape.
data RebootReadyPlan = RebootReadyPlan
    { rebootStartEffects :: [HostEffect]
    , rebootCordonReconcile :: Maybe (ExistsProbe, [HostEffect])
    , rebootWaitProbe :: WaitProbe
    }
    deriving (Eq, Show)

{- | Pure, non-authorizing provision plan. The prepared provider adapter owns
mutation and consumes no discovery capability.
-}
planProviderProvision :: SubstrateProvider -> ResourceEnvelope -> Maybe HostPathShare -> Either ProviderError [HostEffect]
planProviderProvision provider resources share =
    mapProviderFailure ProviderProvision provider (spLaunch provider resources share)

-- | Reconcile an existing provider frame to ready, with no provider branch at the call site.
planProviderRebootReady :: SubstrateProvider -> Either ProviderError RebootReadyPlan
planProviderRebootReady provider =
    Right
        RebootReadyPlan
            { rebootStartEffects = spStartExisting provider
            , rebootCordonReconcile = spReconcileCordon provider
            , rebootWaitProbe = spWait provider
            }

-- | Stop a provider frame, or return a structured refusal where stop has no meaning.
planProviderStop :: SubstrateProvider -> ResourceEnvelope -> Either ProviderError [HostEffect]
planProviderStop provider resources =
    mapProviderTeardownFailure ProviderStop provider (spStop provider resources)

-- | Delete a provider frame, or return a structured refusal where delete has no meaning.
planProviderDelete :: SubstrateProvider -> ResourceEnvelope -> Either ProviderError [HostEffect]
planProviderDelete provider resources =
    mapProviderTeardownFailure ProviderDelete provider (spDestroy provider resources)

-- | Project a durable host path through the selected provider boundary.
planProviderShare :: SubstrateProvider -> FilePath -> Either ProviderError HostPathShare
planProviderShare provider source = Right (spShare provider source)

{- | Plan the common guest alias transition. A direct host has no guest boundary,
so asking it to mint or consume a guest alias is a structured refusal rather
than an apparent success.
-}
planProviderAlias :: SubstrateProvider -> FilePath -> FilePath -> AliasState -> Either ProviderError AliasAction
planProviderAlias provider aliasPath target state = do
    case spProviderKind provider of
        ProviderDirectHost ->
            unsupportedProvider
                ProviderAlias
                provider
                "the direct host has no guest boundary and must not create or consume a guest alias"
        _ -> pure ()
    mapProviderFailure ProviderAlias provider (planAliasEnsure aliasPath target state)

unsupported :: ProviderOperation -> ProviderCapability scope planId providerId backendId capabilityId -> String -> Either ProviderError a
unsupported operation capability cause =
    Left
        ProviderUnsupported
            { providerErrorKind = providerCapabilityKind capability
            , providerErrorOperation = operation
            , providerErrorCause = cause
            }

unsupportedProvider :: ProviderOperation -> SubstrateProvider -> String -> Either ProviderError a
unsupportedProvider operation provider cause =
    Left
        ProviderUnsupported
            { providerErrorKind = spProviderKind provider
            , providerErrorOperation = operation
            , providerErrorCause = cause
            }

mapProviderFailure :: ProviderOperation -> SubstrateProvider -> Either String a -> Either ProviderError a
mapProviderFailure operation provider result =
    case result of
        Right value -> Right value
        Left cause ->
            Left
                ProviderOperationFailure
                    { providerErrorKind = spProviderKind provider
                    , providerErrorOperation = operation
                    , providerErrorCause = cause
                    }

mapProviderTeardownFailure :: ProviderOperation -> SubstrateProvider -> Either String a -> Either ProviderError a
mapProviderTeardownFailure operation provider result =
    case result of
        Left cause
            | spProviderKind provider == ProviderDirectHost ->
                unsupportedProvider operation provider cause
        _ -> mapProviderFailure operation provider result

-- | Select the provider implied by a detected substrate. Every substrate is covered.
selectSubstrateProvider :: Substrate -> VMHandles -> Either String SubstrateProvider
selectSubstrateProvider sub handles = Right (selectProviderKind (providerKindForSubstrate sub) handles)

-- | Total dispatch over the closed lifecycle-provider vocabulary.
selectProviderKind :: ProviderKind -> VMHandles -> SubstrateProvider
selectProviderKind kind h = case kind of
    ProviderLima -> apple
    ProviderIncus -> linux
    ProviderWsl2 -> windows
    ProviderDirectHost -> direct
  where
    prefix = vmhGuardPrefix h

    apple =
        let vm = vmhLima h
         in SubstrateProvider
                { spVmId = limaName vm
                , spProviderKind = ProviderLima
                , spLiftContext = inLimaVM vm localContext
                , spExists = ExistsProbe Lima ["list", "-q"] LinesMember
                , spLaunch = \env share -> do
                    sizing <- limaSizingArgs env
                    let mount = maybe [] (Lima.writableMountArgs . hpsHostPath) share
                    pure [RunHostTool Lima (Lima.startVMArgs vm (sizing ++ ["--vm-type", "vz"] ++ mount))]
                , spShare = \source -> HostPathShare source source Nothing
                , spStartExisting = [RunHostTool Lima ["start", limaName vm]]
                , spReconcileCordon = Nothing
                , spWait = WaitProbe Lima (Lima.shellVMArgs vm ["true"])
                , spTransfer = LimaFileTransfer vm
                , spStop = \_ -> Right [RunHostTool Lima (Lima.stopVMArgs vm)]
                , spDestroy =
                    \_ -> (\argv -> [RunHostTool Lima argv]) <$> Lima.deleteVMArgs prefix vm
                }

    linux =
        let vm = vmhIncus h
         in SubstrateProvider
                { spVmId = vmName vm
                , spProviderKind = ProviderIncus
                , spLiftContext = inVM vm localContext
                , spExists = ExistsProbe Incus ["list", "--format", "csv", "-c", "n"] LinesMember
                , spLaunch = \env _ -> do
                    sizing <- incusSizingArgs env
                    pure [RunHostTool Incus (createVMArgs vm (concatMap toLaunchFlag sizing))]
                , spShare = \source ->
                    let device = "durable-data"
                        target = source
                     in HostPathShare
                            { hpsHostPath = source
                            , hpsGuestPath = target
                            , hpsReconcile =
                                Just
                                    ShareReconcile
                                        { srProbe = ExistsProbe Incus (deviceListArgs vm) LinesMember
                                        , srMember = device
                                        , srWhenMissing = [RunHostTool Incus (addDiskDeviceArgs vm device source target)]
                                        }
                            }
                , spStartExisting = [RunHostTool Incus (startVMArgs vm)]
                , spReconcileCordon = Nothing
                , spWait = WaitProbe Incus (execVMArgs vm ["true"])
                , spTransfer = IncusFileTransfer vm
                , spStop = \_ -> Right [RunHostTool Incus (stopVMArgs vm)]
                , spDestroy =
                    \_ -> (\argv -> [RunHostTool Incus argv]) <$> destroyVMArgs prefix vm
                }

    windows =
        let vm = vmhWsl2 h
            distro = Wsl2.wsl2Distro vm
         in SubstrateProvider
                { spVmId = distro
                , spProviderKind = ProviderWsl2
                , spLiftContext = inWsl2VM vm localContext
                , spExists = ExistsProbe Wsl ["--list", "--quiet"] WslQuietMember
                , spLaunch = \env _ -> do
                    body <- wsl2SizingArgs env
                    budget <- budgetFromResources env
                    let vhd = show (gibibytes (budgetStorageBytes budget)) ++ "GB"
                    pure
                        [ ApplyGlobalWslWall body
                        , RunHostTool Wsl Wsl2.wslShutdownArgs
                        , RunHostTool Wsl (Wsl2.wslInstallArgs distro vhd)
                        ]
                , spShare = \source ->
                    HostPathShare
                        { hpsHostPath = source
                        , hpsGuestPath = windowsPathToWslMount source
                        , hpsReconcile = Nothing
                        }
                , -- WSL2 has no explicit "start"; the readiness probe (@wsl -d … true@)
                  -- boots the distro on demand.
                  spStartExisting = []
                , -- Apply the global @.wslconfig@ cordon on reconcile only when the
                  -- distro is STOPPED (a running distro already booted with it live):
                  -- probe the running state, and if stopped run @wsl --shutdown@ so the
                  -- utility VM re-reads @vmIdleTimeout=21600000@ on its next cold boot.
                  spReconcileCordon =
                    Just
                        ( ExistsProbe Wsl ["--list", "--verbose"] WslRunningMember
                        , [RunHostTool Wsl Wsl2.wslShutdownArgs]
                        )
                , spWait = WaitProbe Wsl (Wsl2.wslExecArgs distro ["true"])
                , spTransfer = Wsl2MountTransfer vm
                , -- @project down@ releases the WSL2 wall so it means the same thing
                  -- on every substrate (Lima and Incus already release on stop). The
                  -- order is load-bearing: release the global @.wslconfig@ FIRST, then
                  -- @wsl --shutdown@, so the shared utility VM re-reads the restored
                  -- (uncordoned) file on its next cold boot and drops the memory
                  -- balloon. @wsl --shutdown@ (whole utility VM) rather than
                  -- @wsl --terminate <distro>@ (one distro) is what actually releases
                  -- the global wall; against the finite @vmIdleTimeout@ from Sprint
                  -- 9.11 the VM then idles down instead of pinning memory between runs.
                  -- The release names the same managed body the wall was applied
                  -- with, so it consumes this owner's journalled origin record
                  -- rather than inferring ownership from a backup file's existence.
                  spStop = \env -> do
                    body <- wsl2SizingArgs env
                    pure
                        [ ReleaseGlobalWslWall body
                        , RunHostTool Wsl Wsl2.wslShutdownArgs
                        ]
                , spDestroy = \env -> do
                    body <- wsl2SizingArgs env
                    argv <- Wsl2.wslUnregisterArgs prefix distro
                    pure [RunHostTool Wsl argv, ReleaseGlobalWslWall body]
                }

    direct =
        SubstrateProvider
            { spVmId = "local-host"
            , spProviderKind = ProviderDirectHost
            , spLiftContext = localContext
            , spExists = DirectHostExistsProbe
            , spLaunch = \_ _ -> Right [RunDirectHost RealizeDirectHost]
            , spShare = \source -> HostPathShare source source Nothing
            , spStartExisting = [RunDirectHost ReconcileDirectHostReady]
            , spReconcileCordon = Nothing
            , spWait = DirectHostReadyProbe
            , spTransfer = DirectHostTransfer
            , spStop = \_ -> Left "the direct host cannot be stopped by a project lifecycle"
            , spDestroy = \_ -> Left "the direct host cannot be deleted by a project lifecycle"
            }

    -- incus sizing args are key=value pairs; @root,size=…@ is a device override
    -- (@-d@), the rest are config keys (@-c@).
    toLaunchFlag a
        | "root," `isPrefixOf` a = ["-d", a]
        | otherwise = ["-c", a]

{- | Total eliminator for existence probes. The first branch is the already-local
direct host; the second receives one resolved-tool probe description. Consumers
choose how to interpret those two shapes without matching provider constructors.
-}
foldExistsProbe :: result -> (HostTool -> [String] -> Membership -> result) -> ExistsProbe -> result
foldExistsProbe directResult runTool probe =
    case probe of
        DirectHostExistsProbe -> directResult
        ExistsProbe tool args membership -> runTool tool args membership

{- | Total eliminator for readiness probes. Direct readiness and tool-backed VM
readiness retain one call-site signature without leaking provider dispatch.
-}
foldWaitProbe :: result -> (HostTool -> [String] -> result) -> WaitProbe -> result
foldWaitProbe directResult runTool probe =
    case probe of
        DirectHostReadyProbe -> directResult
        WaitProbe tool args -> runTool tool args

-- | Parse a VM-name list out of an existence-probe's stdout per 'Membership'.
membersOf :: Membership -> String -> [String]
membersOf LinesMember = lines
membersOf WslQuietMember = Wsl2.wslListDistros
membersOf WslRunningMember = Wsl2.wslRunningDistros

{- | Classify a successful share-presence probe into the effects still needed.
No post-create plan means no effects. For an Incus plan, an output containing
the managed device name is already reconciled; otherwise emit its one add
effect. Probe execution and non-zero handling remain in the IO interpreter.
-}
shareReconcileEffects :: HostPathShare -> String -> [HostEffect]
shareReconcileEffects share output =
    case hpsReconcile share of
        Nothing -> []
        Just reconcile ->
            foldExistsProbe
                []
                ( \_ _ membership ->
                    if srMember reconcile `elem` membersOf membership output
                        then []
                        else srWhenMissing reconcile
                )
                (srProbe reconcile)

{- | Plan one host→frame file transfer (pure). Lima/Incus push to @dst@; WSL2
reads @src@ through @/mnt@, and direct host reads the same path in place.
-}
stageFileEffects :: FileTransfer -> FilePath -> FilePath -> StagedFile
stageFileEffects (IncusFileTransfer vm) src dst =
    StagedFile [RunHostTool Incus (pushFileArgs vm src dst)] dst True
stageFileEffects (LimaFileTransfer vm) src dst =
    StagedFile [RunHostTool Lima (Lima.copyToVMArgs vm src dst)] dst True
stageFileEffects (Wsl2MountTransfer _) src _ =
    StagedFile [] (windowsPathToWslMount src) False
stageFileEffects DirectHostTransfer src _ = StagedFile [] src False

{- | The resolved-tool invocation that runs @cmd@ inside a VM frame, for the
single-layer lift the consumer uses to shell into the distro. 'Nothing' for a
container layer (a container is reached through 'HostBootstrap.Lift', not here).
-}
vmShellArgs :: LiftLayer -> [String] -> Maybe (HostTool, [String])
vmShellArgs layer cmd =
    case foldLeaf (LiftContext [layer]) (RawCmd cmd) of
        DispatchTool tool args
            | layerIsVM layer -> Just (tool, args)
        _ -> Nothing
  where
    layerIsVM (ViaVM _) = True
    layerIsVM (ViaLimaVM _) = True
    layerIsVM (ViaWsl2VM _) = True
    layerIsVM (ViaContainer _) = False

-- ---------------------------------------------------------------------------
-- Guest-side durable alias: one pure state machine (§ DD).
--
-- A host-backed durable share is only usable at the Docker boundary through a
-- stable Docker-visible alias — a symlink from a fixed path to the share. The
-- alias is minted by the VM-shell lane (trivial guest probes:
-- @test -L@, @readlink@, @test -e@ — no compound @set -eu@, no nested @"$(…)"@,
-- so it survives the Windows PowerShell→@wsl@→@bash@ quoting path, § CC).
-- Direct host has no guest boundary and supplies the canonical host projection
-- directly, so it never calls this state machine. Every guest step is
-- readiness-gated by the consumer (§ CC): the alias cannot
-- be minted before a @Ready DurableShareMounted@ witness proves the share is a
-- writable directory.
-- ---------------------------------------------------------------------------

{- | The observed state of the stable Docker-visible alias that points at a
host-backed durable share (§ DD).
-}
data AliasNodeKind
    = AliasRegularFile
    | AliasDirectory
    | AliasOtherNode
    | AliasNodeKindUnknown
    deriving (Eq, Show)

data AliasState
    = -- | nothing exists at the alias path
      AliasAbsent
    | -- | a symlink already pointing at the expected share target (idempotent no-op)
      AliasLinkedCorrectly
    | -- | a symlink pointing somewhere else — a stale/foreign link (a collision)
      AliasLinkedElsewhere FilePath
    | -- | a non-symlink node occupies the path (a collision)
      AliasOccupied AliasNodeKind
    deriving (Eq, Show)

{- | The raw facts a lane's probes gather about the alias path, classified the same
way by 'classifyAlias'. 'afSymlinkTarget' is @Just t@ only when the path is a
symlink and its target was read successfully. Probe failures are structured
backend failures and must not be encoded as an empty target. 'afExists' is
whether the path exists as anything at all.
-}
data AliasFacts = AliasFacts
    { afSymlinkTarget :: Maybe FilePath
    , afExists :: Bool
    }
    deriving (Eq, Show)

{- | Classify the alias path against the expected share target. Total. Trailing
slashes are trimmed before comparison; a backend that creates the link uses the exact
expected target string, so a correctly-linked alias compares equal.
-}
classifyAlias :: FilePath -> AliasFacts -> AliasState
classifyAlias expected facts = case afSymlinkTarget facts of
    Just t
        | trimTrailingSlash t == trimTrailingSlash expected -> AliasLinkedCorrectly
        | otherwise -> AliasLinkedElsewhere t
    Nothing
        | afExists facts -> AliasOccupied AliasNodeKindUnknown
        | otherwise -> AliasAbsent

trimTrailingSlash :: FilePath -> FilePath
trimTrailingSlash = dropWhileEnd (`elem` ("/\\" :: String))

{- | The action a lane takes to make the alias correct, from its 'AliasState'. An
idempotent correct link is 'AliasLeaveLinked'; an absent path is 'AliasCreateLink';
a collision ('AliasLinkedElsewhere' / 'AliasOccupied') is a 'Left' message — a
deterministic @Failed@ condition (§ CC), surfaced legibly, never a bare exit code.
Pure and diagnostic only: this view does not authorize mutation or cleanup.
-}
data AliasAction = AliasLeaveLinked | AliasCreateLink
    deriving (Eq, Show)

planAliasEnsure :: FilePath -> FilePath -> AliasState -> Either String AliasAction
planAliasEnsure aliasPath target state = case state of
    AliasAbsent -> Right AliasCreateLink
    AliasLinkedCorrectly -> Right AliasLeaveLinked
    AliasLinkedElsewhere other ->
        Left ("durable alias " ++ aliasPath ++ " points to " ++ other ++ ", expected " ++ target)
    AliasOccupied nodeKind ->
        Left
            ( "durable alias collision: "
                ++ aliasPath
                ++ " already exists as "
                ++ show nodeKind
                ++ " and is not a symbolic link to "
                ++ target
            )

{- | The teardown action: remove the alias **only** when it is still the exact link
this project owns ('AliasLinkedCorrectly' → 'AliasUnlink'); an absent path or a
foreign non-symlink occupant is left in place with a reason ('AliasKeep'); a
retargeted link is a 'Left' refusal (never silently clobbered). Pure. Mirrors the
never-delete-@.data@ discipline (§ Y): the host target itself is never removed here.
This diagnostic view is not ownership proof; effectful teardown additionally
requires the matching managed handle, receipt, and an identity-bound conditional
backend operation.
-}
data AliasRemoval = AliasKeep String | AliasUnlink
    deriving (Eq, Show)

planAliasRemove :: FilePath -> FilePath -> AliasState -> Either String AliasRemoval
planAliasRemove aliasPath target state = case state of
    AliasAbsent -> Right (AliasKeep ("durable alias " ++ aliasPath ++ " is already absent"))
    AliasLinkedCorrectly -> Right AliasUnlink
    AliasLinkedElsewhere other ->
        Left ("refusing to remove durable alias " ++ aliasPath ++ ": it points to " ++ other ++ ", expected " ++ target)
    AliasOccupied _ ->
        Right (AliasKeep ("durable alias path " ++ aliasPath ++ " is occupied by a non-symlink; leaving it untouched"))

{- | Rewrite a Windows path (@C:\\…@) to its WSL2 drive mount (@/mnt/c/…@), so a
distro reads a host file in place without a copy tool. Pure.
-}
windowsPathToWslMount :: FilePath -> FilePath
windowsPathToWslMount path =
    case path of
        drive : ':' : rest -> "/mnt/" ++ [toLowerAscii drive] ++ map slash rest
        _ -> map slash path
  where
    slash '\\' = '/'
    slash c = c
    toLowerAscii c
        | isAsciiUpper c = toEnum (fromEnum c + 32)
        | otherwise = c
