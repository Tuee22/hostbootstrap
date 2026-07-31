{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}

{- | The finalized in-cluster registry plan and its proof-gated blob delivery.

A container registry backed by an object store answers a blob request in one of
two ways: it streams the bytes itself, or it returns @307@ with a @Location@
pointing at the store. Distribution's default is to redirect. That default is
correct when the client lives in the cluster and catastrophic when it does not —
a host Docker client following a redirect to @minio.default.svc:9000@ cannot
resolve the name, and the push fails late, after every layer has uploaded, with
an opaque error.

The plan therefore does not carry a redirect boolean. It carries a
'BlobDelivery' whose redirecting constructor demands a
'HostBootstrap.Network.Reachability' proof that the client can actually reach
the store. Since the reachability GADT has no host-local→cluster-only
constructor, a host-served registry cannot be given a redirecting delivery at
all, and the rendered @storage.redirect.disable@ is *derived* from the delivery
rather than chosen beside it.

Readiness is equally exact: @/v2/@ answering proves the registry process is up,
not that a blob can be fetched. 'settleBlobRoute' mints a 'ReadyBlobRoute' only
from an observation of a real blob request whose outcome matches the planned
delivery, at the plan's current revision.
-}
module HostBootstrap.RegistryPlan (
    -- * The finalized plan
    RegistryPlan,
    registryPlanClient,
    registryPlanExposure,
    registryPlanEndpoint,
    registryPlanStore,
    registryPlanDelivery,
    registryPlanRevision,

    -- * Topology-specific constructors
    hostServedRegistryPlan,
    inClusterRegistryPlan,

    -- * Delivery
    BlobDelivery,
    blobDeliveryStrategy,
    DeliveryStrategy (..),
    proxyThroughRegistry,
    redirectToStore,

    -- * Rendering
    renderStorageRedirect,

    -- * Readiness
    BlobRouteObservation (..),
    BlobProbe (..),
    ReadyBlobRoute,
    readyBlobRouteRevision,
    settleBlobRoute,
    RegistryPlanError (..),
)
where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Network (
    Endpoint,
    Exposure,
    NetworkClient,
    NetworkScope (..),
    Reachability,
    clientScope,
    endpointAuthority,
    exposureEndpoint,
    exposurePort,
    reachabilityEndpointScope,
 )

data RegistryPlanError
    = -- | the plan revision must be strictly positive and generative
      InvalidRegistryRevision Word64
    | -- | the observation does not match the planned delivery
      BlobRouteMismatch Text Text
    | -- | a route witness was settled against a different plan revision
      BlobRouteStaleRevision Word64 Word64
    | -- | the probe proves the process is up, not that a blob can be fetched
      BlobRouteNotABlobProbe
    deriving (Eq, Show)

{- | How the registry answers a blob request, indexed by the scope of the client
it answers.

'Proxy' needs no proof: the registry streams the bytes itself, so the client
never learns the store's address. 'Redirect' carries a
'HostBootstrap.Network.Reachability' witness, which is the only way to build it
— and no such witness exists for a host-local client and a cluster-only store.
-}
data BlobDelivery (client :: NetworkScope) where
    Proxy :: BlobDelivery client
    Redirect ::
        Reachability client store ->
        Endpoint store ->
        BlobDelivery client

deriving instance Show (BlobDelivery client)

-- | The term-level view of a delivery, for rendering and assertions.
data DeliveryStrategy
    = -- | the registry streams blob bytes; no @Location@ is issued
      ProxyBlobs
    | -- | the registry redirects to the store at this authority
      RedirectBlobs Text NetworkScope
    deriving (Eq, Show)

blobDeliveryStrategy :: BlobDelivery client -> DeliveryStrategy
blobDeliveryStrategy Proxy = ProxyBlobs
blobDeliveryStrategy (Redirect proof endpoint) =
    RedirectBlobs (endpointAuthority endpoint) (reachabilityEndpointScope proof)

{- | Serve blobs through the registry itself. Always available: proxying is safe
from every scope because it introduces no second address.
-}
proxyThroughRegistry :: BlobDelivery client
proxyThroughRegistry = Proxy

{- | Redirect blobs to the backing store. The 'Reachability' argument is the
whole gate — it cannot be supplied for a host-local client and a cluster-only
store, so this constructor is simply unavailable for that pair.
-}
redirectToStore ::
    Reachability client store ->
    Endpoint store ->
    BlobDelivery client
redirectToStore = Redirect

{- | A finalized registry plan: who dials it, where it answers, where its blobs
live, how blobs are delivered, and the revision this shape belongs to.

Opaque, and reachable only through a topology-specific constructor, so no caller
can assemble a registry endpoint and a store endpoint independently and pair
them by convention.
-}
data RegistryPlan (client :: NetworkScope) (store :: NetworkScope) = RegistryPlan
    { planClient :: NetworkClient client
    , planExposure :: Exposure client
    , planStore :: Endpoint store
    , planDelivery :: BlobDelivery client
    , planRevision :: Word64
    }

deriving instance Show (RegistryPlan client store)

registryPlanClient :: RegistryPlan client store -> NetworkScope
registryPlanClient = clientScope . planClient

{- | The exact published exposure the plan answers on. A route witness is bound
to this, not to a bare authority string, so a plan cannot be validated against
one published port and then consumed against another.
-}
registryPlanExposure :: RegistryPlan client store -> Exposure client
registryPlanExposure = planExposure

registryPlanEndpoint :: RegistryPlan client store -> Endpoint client
registryPlanEndpoint = exposureEndpoint . planExposure

registryPlanStore :: RegistryPlan client store -> Endpoint store
registryPlanStore = planStore

registryPlanDelivery :: RegistryPlan client store -> BlobDelivery client
registryPlanDelivery = planDelivery

registryPlanRevision :: RegistryPlan client store -> Word64
registryPlanRevision = planRevision

{- | The demo's topology: a registry published on the host (or VM) loopback with
its blobs in a cluster-only object store.

The delivery is fixed to 'Proxy' by construction — not by policy, but because
this constructor's client and store scopes admit no reachability witness. That
is the defect this sprint exists to make unrepresentable.
-}
hostServedRegistryPlan ::
    NetworkClient client ->
    Exposure client ->
    Endpoint 'ClusterOnly ->
    Word64 ->
    Either RegistryPlanError (RegistryPlan client 'ClusterOnly)
hostServedRegistryPlan client exposure store revision
    | revision == 0 = Left (InvalidRegistryRevision revision)
    | otherwise =
        Right
            RegistryPlan
                { planClient = client
                , planExposure = exposure
                , planStore = store
                , planDelivery = proxyThroughRegistry
                , planRevision = revision
                }

{- | A registry whose clients are themselves in the cluster: redirection is
sound, and the constructor supplies the witness that says so.
-}
inClusterRegistryPlan ::
    Reachability 'ClusterOnly 'ClusterOnly ->
    NetworkClient 'ClusterOnly ->
    Exposure 'ClusterOnly ->
    Endpoint 'ClusterOnly ->
    Word64 ->
    Either RegistryPlanError (RegistryPlan 'ClusterOnly 'ClusterOnly)
inClusterRegistryPlan proof client exposure store revision
    | revision == 0 = Left (InvalidRegistryRevision revision)
    | otherwise =
        Right
            RegistryPlan
                { planClient = client
                , planExposure = exposure
                , planStore = store
                , planDelivery = redirectToStore proof store
                , planRevision = revision
                }

{- | The Distribution @storage.redirect@ stanza, derived from the plan's
delivery.

There is no raw redirect flag anywhere: a proxying plan renders
@redirect: disable: true@ and a redirecting plan renders nothing, leaving
Distribution's default. Because the delivery is the only input, the rendered
configuration and the reachability proof cannot disagree.
-}
renderStorageRedirect :: RegistryPlan client store -> [Text]
renderStorageRedirect plan =
    case blobDeliveryStrategy (planDelivery plan) of
        ProxyBlobs ->
            [ "  redirect:"
            , "    disable: true"
            ]
        RedirectBlobs _ _ -> []

{- | What a probe actually asked for. @/v2/@ answering proves the registry
process is listening; only a blob request proves the delivery path works.
-}
data BlobProbe
    = -- | @GET \/v2\/@ — liveness only
      ApiVersionProbe
    | -- | @HEAD \/v2\/\<name\>\/blobs\/\<digest\>@
      BlobHeadProbe Text
    deriving (Eq, Show)

-- | One observation of a blob request against the planned registry.
data BlobRouteObservation = BlobRouteObservation
    { observedProbe :: BlobProbe
    , -- | the published port the probe actually dialled
      observedPort :: Int
    , observedStatus :: Int
    , -- | the @Location@ authority and the scope it resolves in, when the
      -- registry issued a redirect
      observedRedirect :: Maybe (Text, NetworkScope)
    , observedRevision :: Word64
    }
    deriving (Eq, Show)

{- | Proof that this exact plan revision's blob route works from this exact
client. It cannot be reused across a replacement revision.
-}
newtype ReadyBlobRoute (client :: NetworkScope) (store :: NetworkScope)
    = ReadyBlobRoute Word64

deriving instance Eq (ReadyBlobRoute client store)

deriving instance Show (ReadyBlobRoute client store)

readyBlobRouteRevision :: ReadyBlobRoute client store -> Word64
readyBlobRouteRevision (ReadyBlobRoute revision) = revision

{- | Settle an observation into a route witness.

The gates, in order: the probe must be a real blob request (a @\/v2\/@ answer is
liveness, never route readiness); the revision must be the plan's current one;
and the observed outcome must match the planned delivery. A proxying plan that
nevertheless issued a redirect is a mismatch even if the target happens to be
reachable, because the rendered configuration and the running registry have
diverged.
-}
settleBlobRoute ::
    RegistryPlan client store ->
    BlobRouteObservation ->
    Either RegistryPlanError (ReadyBlobRoute client store)
settleBlobRoute plan observation =
    case observedProbe observation of
        ApiVersionProbe -> Left BlobRouteNotABlobProbe
        BlobHeadProbe _
            | observedRevision observation /= planRevision plan ->
                Left
                    ( BlobRouteStaleRevision
                        (planRevision plan)
                        (observedRevision observation)
                    )
            | observedPort observation /= exposurePort (planExposure plan) ->
                mismatch
                    ("the exposure on port " <> Text.pack (show (exposurePort (planExposure plan))))
                    ("a probe of port " <> Text.pack (show (observedPort observation)))
            | otherwise -> settleForDelivery
  where
    settleForDelivery =
        case (blobDeliveryStrategy (planDelivery plan), observedRedirect observation) of
            (ProxyBlobs, Nothing)
                | successful -> ready
                | otherwise -> mismatch "a served blob" statusText
            (ProxyBlobs, Just (authority, _)) ->
                mismatch
                    "a served blob with no Location"
                    ("a redirect to " <> authority)
            (RedirectBlobs planned scope, Just (authority, observedScope))
                | planned /= authority ->
                    mismatch
                        ("a redirect to " <> planned)
                        ("a redirect to " <> authority)
                | scope /= observedScope ->
                    mismatch
                        ("a redirect resolving in " <> Text.pack (show scope))
                        ("a redirect resolving in " <> Text.pack (show observedScope))
                | otherwise -> ready
            (RedirectBlobs planned _, Nothing) ->
                mismatch ("a redirect to " <> planned) statusText

    successful = observedStatus observation >= 200 && observedStatus observation < 300
    statusText = "status " <> Text.pack (show (observedStatus observation))
    ready = Right (ReadyBlobRoute (planRevision plan))
    mismatch expected actual = Left (BlobRouteMismatch expected actual)
