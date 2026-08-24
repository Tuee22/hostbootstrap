{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE StandaloneDeriving #-}

{- | Scope-indexed network endpoints and the closed reachability relation
between them.

A hostname is not evidence. @localhost:<runtime-port>@ is reachable from the host and
meaningless inside a pod; @minio.default.svc:9000@ is reachable from a pod and
unresolvable on the host. Both are just strings, so any code that decides
"can this client reach that endpoint?" by inspecting text is guessing — and the
demo's registry did exactly that, redirecting a host Docker client to a
cluster-only MinIO address it could never resolve.

Here the scope is a type index. An 'Endpoint' carries the scope it lives in, a
'NetworkClient' carries the scope it dials from, and 'Reachability' is a closed
GADT whose constructors enumerate every legal pair. There is deliberately **no**
@Reachability 'HostLocal 'ClusterOnly@ constructor, so a host-local client
cannot be handed a cluster-only endpoint at all: the bad redirect is not a
runtime error to be checked, it is unrepresentable.

Constructors for the opaque values are private; an endpoint is minted only by a
scope-specific smart constructor that validates its authority text.
-}
module HostBootstrap.Network (
    -- * Scopes
    NetworkScope (..),
    ScopeName (..),
    scopeNameOf,

    -- * Opaque scope-indexed values
    Endpoint,
    endpointAuthority,
    endpointScope,
    clusterOnlyEndpoint,
    NetworkClient,
    clientScope,
    hostLocalClient,
    vmLocalClient,
    clusterOnlyClient,

    -- * The closed reachability relation
    Reachability (..),
    reachabilityClientScope,
    reachabilityEndpointScope,
    reachableFrom,

    -- * Exposure
    Exposure,
    exposureEndpoint,
    exposurePort,
    exposureService,
    exposureRuntimeIdentity,
    resolvedHostExposure,
    resolvedVmExposure,
    clusterServiceExposure,

    -- * Errors
    NetworkError (..),
)
where

import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Cluster.Backend (
    ResolvedExposure,
    resolvedExposureClusterGeneration,
    resolvedExposureHostPort,
    resolvedExposureListenAddress,
    resolvedExposureOwnershipOperation,
    resolvedExposureRelayIdentity,
    resolvedExposureService,
 )

{- | Where a network name resolves. The three scopes the composition chain
actually crosses (§ U): the metal host, a provider VM guest, and the inside of
the cluster.
-}
data NetworkScope
    = -- | resolvable on the machine running the project binary
      HostLocal
    | -- | resolvable inside the provider VM guest
      VmLocal
    | -- | resolvable only from inside the cluster network
      ClusterOnly
    deriving (Eq, Show)

-- | A term-level tag for a scope, so a value can report its own index.
data ScopeName (scope :: NetworkScope) where
    HostLocalName :: ScopeName 'HostLocal
    VmLocalName :: ScopeName 'VmLocal
    ClusterOnlyName :: ScopeName 'ClusterOnly

deriving instance Eq (ScopeName scope)

deriving instance Show (ScopeName scope)

scopeNameOf :: ScopeName scope -> NetworkScope
scopeNameOf HostLocalName = HostLocal
scopeNameOf VmLocalName = VmLocal
scopeNameOf ClusterOnlyName = ClusterOnly

data NetworkError
    = -- | the authority text is empty, whitespace-bearing, or scheme-bearing
      InvalidEndpointAuthority Text String
    | -- | a port outside 1..65535
      InvalidEndpointPort Int
    deriving (Eq, Show)

{- | A network authority (@host:port@ or a DNS name) together with the scope it
resolves in. Opaque: the only way to obtain one is a scope-specific smart
constructor, so no caller can relabel a cluster address as host-local.
-}
data Endpoint (scope :: NetworkScope) = Endpoint (ScopeName scope) Text

deriving instance Eq (Endpoint scope)

instance Show (Endpoint scope) where
    show (Endpoint name authority) =
        "Endpoint " ++ show (scopeNameOf name) ++ " " ++ show authority

endpointAuthority :: Endpoint scope -> Text
endpointAuthority (Endpoint _ authority) = authority

endpointScope :: Endpoint scope -> NetworkScope
endpointScope (Endpoint name _) = scopeNameOf name

mkEndpoint :: ScopeName scope -> Text -> Either NetworkError (Endpoint scope)
mkEndpoint name authority
    | Text.null trimmed =
        Left (InvalidEndpointAuthority authority "an endpoint authority must not be empty")
    | Text.any isSpace trimmed =
        Left (InvalidEndpointAuthority authority "an endpoint authority must not contain whitespace")
    | "://" `Text.isInfixOf` trimmed =
        Left
            ( InvalidEndpointAuthority
                authority
                "an endpoint authority is host:port, not a URL with a scheme"
            )
    | "/" `Text.isInfixOf` trimmed =
        Left
            ( InvalidEndpointAuthority
                authority
                "an endpoint authority carries no path"
            )
    | otherwise = Right (Endpoint name trimmed)
  where
    trimmed = Text.strip authority

-- | An in-cluster address, e.g. a @.svc@ Service DNS name.
clusterOnlyEndpoint :: Text -> Either NetworkError (Endpoint 'ClusterOnly)
clusterOnlyEndpoint = mkEndpoint ClusterOnlyName

-- | Something that dials endpoints, indexed by the scope it dials from.
newtype NetworkClient (scope :: NetworkScope) = NetworkClient (ScopeName scope)

deriving instance Eq (NetworkClient scope)

instance Show (NetworkClient scope) where
    show (NetworkClient name) = "NetworkClient " ++ show (scopeNameOf name)

clientScope :: NetworkClient scope -> NetworkScope
clientScope (NetworkClient name) = scopeNameOf name

-- | The host Docker client, a @curl@ on the metal host, and their peers.
hostLocalClient :: NetworkClient 'HostLocal
hostLocalClient = NetworkClient HostLocalName

-- | A client inside the provider VM guest.
vmLocalClient :: NetworkClient 'VmLocal
vmLocalClient = NetworkClient VmLocalName

-- | A client inside the cluster network (a pod).
clusterOnlyClient :: NetworkClient 'ClusterOnly
clusterOnlyClient = NetworkClient ClusterOnlyName

{- | The closed relation "a client in @client@ can reach an endpoint in
@endpoint@".

Every legal pair is a constructor and there are no others. The absent case is
the point of the module: there is no @HostReachesCluster@, because a host-local
client genuinely cannot resolve an in-cluster Service name. A cluster client can
reach a host-published port (through the node's loopback mapping), and a VM
client can reach both its own guest addresses and the cluster it hosts, but
never the reverse of the forbidden pair.
-}
data Reachability (client :: NetworkScope) (endpoint :: NetworkScope) where
    HostReachesHost :: Reachability 'HostLocal 'HostLocal
    VmReachesVm :: Reachability 'VmLocal 'VmLocal
    VmReachesCluster :: Reachability 'VmLocal 'ClusterOnly
    ClusterReachesCluster :: Reachability 'ClusterOnly 'ClusterOnly

deriving instance Eq (Reachability client endpoint)

deriving instance Show (Reachability client endpoint)

reachabilityClientScope :: Reachability client endpoint -> NetworkScope
reachabilityClientScope HostReachesHost = HostLocal
reachabilityClientScope VmReachesVm = VmLocal
reachabilityClientScope VmReachesCluster = VmLocal
reachabilityClientScope ClusterReachesCluster = ClusterOnly

reachabilityEndpointScope :: Reachability client endpoint -> NetworkScope
reachabilityEndpointScope HostReachesHost = HostLocal
reachabilityEndpointScope VmReachesVm = VmLocal
reachabilityEndpointScope VmReachesCluster = ClusterOnly
reachabilityEndpointScope ClusterReachesCluster = ClusterOnly

{- | The term-level view of the same relation, for rendering and diagnostics.
It agrees with the GADT by construction: every 'True' pair has a constructor.
-}
reachableFrom :: NetworkScope -> NetworkScope -> Bool
reachableFrom HostLocal HostLocal = True
reachableFrom VmLocal VmLocal = True
reachableFrom VmLocal ClusterOnly = True
reachableFrom ClusterOnly ClusterOnly = True
reachableFrom _ _ = False

{- | A published endpoint plus the port it is published on. An exposure is how a
scope is *made* reachable; it does not by itself grant reachability from another
scope.
-}
data Exposure (network :: NetworkScope) lifecycleScope planId clusterId service where
    ResolvedLocalExposure ::
        Endpoint network ->
        Int ->
        Text ->
        Text ->
        Word64 ->
        Text ->
        Exposure network lifecycleScope planId clusterId service
    ClusterServiceExposure ::
        Endpoint 'ClusterOnly ->
        Int ->
        Text ->
        Exposure 'ClusterOnly lifecycleScope planId clusterId service

type role Exposure nominal nominal nominal nominal nominal

deriving instance Eq (Exposure network lifecycleScope planId clusterId service)

instance Show (Exposure network lifecycleScope planId clusterId service) where
    show exposure =
        "Exposure " ++ show (exposureEndpoint exposure) ++ " " ++ show (exposurePort exposure)

exposureEndpoint :: Exposure network lifecycleScope planId clusterId service -> Endpoint network
exposureEndpoint (ResolvedLocalExposure endpoint _ _ _ _ _) = endpoint
exposureEndpoint (ClusterServiceExposure endpoint _ _) = endpoint

exposurePort :: Exposure network lifecycleScope planId clusterId service -> Int
exposurePort (ResolvedLocalExposure _ port _ _ _ _) = port
exposurePort (ClusterServiceExposure _ port _) = port

exposureService :: Exposure network lifecycleScope planId clusterId service -> Text
exposureService (ResolvedLocalExposure _ _ service _ _ _) = service
exposureService (ClusterServiceExposure _ _ service) = service

{- | The runtime identity retained by a local exposure. Cluster-only service
addresses need no relay and therefore return 'Nothing'.
-}
exposureRuntimeIdentity ::
    Exposure network lifecycleScope planId clusterId service ->
    Maybe (Text, Word64, Text)
exposureRuntimeIdentity (ResolvedLocalExposure _ _ _ relay generation operation) =
    Just (relay, generation, operation)
exposureRuntimeIdentity (ClusterServiceExposure _ _ _) = Nothing

validPort :: Int -> Bool
validPort port = port > 0 && port < 65536

resolvedHostExposure ::
    ResolvedExposure lifecycleScope planId clusterId service ->
    Exposure 'HostLocal lifecycleScope planId clusterId service
resolvedHostExposure = resolvedLocalExposure HostLocalName

resolvedVmExposure ::
    ResolvedExposure lifecycleScope planId clusterId service ->
    Exposure 'VmLocal lifecycleScope planId clusterId service
resolvedVmExposure = resolvedLocalExposure VmLocalName

resolvedLocalExposure ::
    ScopeName network ->
    ResolvedExposure lifecycleScope planId clusterId service ->
    Exposure network lifecycleScope planId clusterId service
resolvedLocalExposure network resolved =
    ResolvedLocalExposure
        ( Endpoint
            network
            ( resolvedExposureListenAddress resolved
                <> ":"
                <> Text.pack (show (resolvedExposureHostPort resolved))
            )
        )
        (resolvedExposureHostPort resolved)
        (resolvedExposureService resolved)
        (resolvedExposureRelayIdentity resolved)
        (resolvedExposureClusterGeneration resolved)
        (resolvedExposureOwnershipOperation resolved)

-- | An in-cluster Service exposure.
clusterServiceExposure ::
    Text ->
    Int ->
    Either NetworkError (Exposure 'ClusterOnly lifecycleScope planId clusterId service)
clusterServiceExposure service port
    | not (validPort port) = Left (InvalidEndpointPort port)
    | otherwise = do
        endpoint <- clusterOnlyEndpoint (service <> ":" <> Text.pack (show port))
        Right (ClusterServiceExposure endpoint port service)
