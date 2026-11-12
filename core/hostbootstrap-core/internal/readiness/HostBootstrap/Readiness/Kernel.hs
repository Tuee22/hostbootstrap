{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Backend-owned observations and plan-indexed probes.

This private kernel depends only on the shared planned-resource identity. It
stores the backend action without interpreting it, choosing a host
configuration, or implementing a second polling loop.
-}
module HostBootstrap.Readiness.Kernel (
    ProbeResult (..),
    ProbeConflict (..),
    ProbeFailure (..),
    BackendReady (..),
    BackendProbeKey (..),
    BackendProbeKind (..),
    backendProbeKeyKind,
    backendProbeKind,
    ProviderResponding,
    ProviderNetworkReady,
    DurableShareReady,
    DockerDaemonReady,
    ObjectStoreRolloutReady,
    RegistryReady,
    ClusterApiReady,
    GpuPluginReady,
    Probe,
    withBackendProbe,
    observeBackendProbe,
)
where

import Data.Word (Word64)
import HostBootstrap.Plan.Resource (
    ClusterResource,
    DockerResource,
    DurableShareResource,
    ObjectStoreResource,
    PlannedResource,
    ProviderResource,
    RegistryResource,
 )

data ProbeConflict = ProbeConflict
    { conflictExpected :: String
    , conflictObserved :: String
    , conflictRemedy :: String
    }
    deriving (Eq, Show)

data ProbeFailure = ProbeFailure
    { failedOperation :: String
    , failureCause :: String
    }
    deriving (Eq, Show)

-- | Exhaustive probe observation. Only 'ProbeReady' is readiness.
data ProbeResult a
    = ProbeReady a
    | NotReady String
    | Unavailable String
    | ProbeConflicted ProbeConflict
    | Failed ProbeFailure
    deriving (Eq, Show)

-- | The closed resource/dependency relation a backend probe must preserve.
data BackendProbeKey resource dependency where
    ProviderRespondingProbe :: BackendProbeKey ProviderResource ProviderResponding
    ProviderNetworkProbe :: BackendProbeKey ProviderResource ProviderNetworkReady
    DurableShareProbe :: BackendProbeKey DurableShareResource DurableShareReady
    DockerDaemonProbe :: BackendProbeKey DockerResource DockerDaemonReady
    ObjectStoreRolloutProbe :: BackendProbeKey ObjectStoreResource ObjectStoreRolloutReady
    RegistryServingProbe :: BackendProbeKey RegistryResource RegistryReady
    ClusterApiProbe :: BackendProbeKey ClusterResource ClusterApiReady
    GpuPluginProbe :: BackendProbeKey ClusterResource GpuPluginReady

-- | Closed term-level counterpart of the typed backend readiness relation.
data BackendProbeKind
    = ProviderRespondingKind
    | ProviderNetworkKind
    | DurableShareKind
    | DockerDaemonKind
    | ObjectStoreRolloutKind
    | RegistryServingKind
    | ClusterApiKind
    | GpuPluginKind
    deriving (Eq, Ord, Show)

backendProbeKeyKind :: BackendProbeKey resource dependency -> BackendProbeKind
backendProbeKeyKind ProviderRespondingProbe = ProviderRespondingKind
backendProbeKeyKind ProviderNetworkProbe = ProviderNetworkKind
backendProbeKeyKind DurableShareProbe = DurableShareKind
backendProbeKeyKind DockerDaemonProbe = DockerDaemonKind
backendProbeKeyKind ObjectStoreRolloutProbe = ObjectStoreRolloutKind
backendProbeKeyKind RegistryServingProbe = RegistryServingKind
backendProbeKeyKind ClusterApiProbe = ClusterApiKind
backendProbeKeyKind GpuPluginProbe = GpuPluginKind

data ProviderResponding
data ProviderNetworkReady
data DurableShareReady
data DockerDaemonReady
data ObjectStoreRolloutReady
data RegistryReady
data ClusterApiReady
data GpuPluginReady

{- | Raw backend readiness: the observed generation, phase version,
observation version, and backend payload. The versions are validated when the
probe is awaited; this report is not itself indexed readiness evidence.
-}
data BackendReady a = BackendReady Word64 Word64 Word64 a
    deriving (Eq, Show)

data Probe scope planId id resource dependency probeId cfg a
    = Probe BackendProbeKind (cfg -> IO (ProbeResult (BackendReady a)))

type role Probe nominal nominal nominal nominal nominal nominal representational representational

{- | Inject backend observations under a closed resource/dependency key. The
fresh @probeId@ cannot escape except through the continuation. Each ready
report supplies its own observed versions; no versions are fixed here.
-}
withBackendProbe ::
    BackendProbeKey resource dependency ->
    PlannedResource scope planId id resource frame ->
    (cfg -> IO (ProbeResult (BackendReady a))) ->
    (forall probeId. Probe scope planId id resource dependency probeId cfg a -> r) ->
    r
withBackendProbe key _planned runProbe consume = consume (Probe (backendProbeKeyKind key) runProbe)

-- | Observe an existing backend probe using the supplied configuration.
observeBackendProbe ::
    Probe scope planId id resource dependency probeId cfg a ->
    cfg ->
    IO (ProbeResult (BackendReady a))
observeBackendProbe (Probe _ runProbe) = runProbe

-- | The kind fixed by the backend key that minted this probe.
backendProbeKind :: Probe scope planId id resource dependency probeId cfg a -> BackendProbeKind
backendProbeKind (Probe kind _) = kind
