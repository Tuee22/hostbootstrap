{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The scope-indexed network algebra and the proof-gated registry plan.

The central claim is negative and is proved by the compile-fail fixtures rather
than here: a host-local client cannot be given a cluster-only redirect, because
no 'Reachability' witness exists for that pair. These cases cover the positive
constructions, the derived rendering, and every way an observation can fail to
mint a route witness.
-}
module RegistryPlanSpec (tests) where

import ClusterBackendSpec (withRuntimeExposure)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Cluster.Backend (withResolvedExposure)
import HostBootstrap.Network
import HostBootstrap.RegistryPlan
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "RegistryPlanSpec"
        [ testGroup "the reachability relation" reachabilityCases
        , testGroup "endpoints and exposure" endpointCases
        , testGroup "plans and derived rendering" planCases
        , testGroup "blob-route readiness" routeCases
        ]

reachabilityCases :: [TestTree]
reachabilityCases =
    [ testCase "a host-local client cannot reach a cluster-only endpoint" $
        reachableFrom HostLocal ClusterOnly @?= False
    , testCase "every supported pair is reachable and every other pair is not" $ do
        let scopes = [HostLocal, VmLocal, ClusterOnly]
            permitted =
                [ (client, endpoint)
                | client <- scopes
                , endpoint <- scopes
                , reachableFrom client endpoint
                ]
        permitted
            @?= [ (HostLocal, HostLocal)
                , (VmLocal, VmLocal)
                , (VmLocal, ClusterOnly)
                , (ClusterOnly, ClusterOnly)
                ]
    , testCase "each witness reports the pair it proves" $ do
        (reachabilityClientScope HostReachesHost, reachabilityEndpointScope HostReachesHost)
            @?= (HostLocal, HostLocal)
        (reachabilityClientScope VmReachesCluster, reachabilityEndpointScope VmReachesCluster)
            @?= (VmLocal, ClusterOnly)
        (reachabilityClientScope ClusterReachesCluster, reachabilityEndpointScope ClusterReachesCluster)
            @?= (ClusterOnly, ClusterOnly)
    ]

endpointCases :: [TestTree]
endpointCases =
    [ testCase "a cluster endpoint carries its scope, not a guess from its text" $ do
        cluster <- expectEndpoint (clusterOnlyEndpoint "minio.default.svc:9000")
        endpointScope cluster @?= ClusterOnly
        endpointAuthority cluster @?= "minio.default.svc:9000"
    , testCase "a path is not an authority" $
        case clusterOnlyEndpoint "minio.default.svc:9000/registry" of
            Left (InvalidEndpointAuthority _ _) -> pure ()
            other -> assertFailure ("expected a path refusal, got " ++ show other)
    , testCase "an empty or whitespace authority is refused" $ do
        case clusterOnlyEndpoint "   " of
            Left (InvalidEndpointAuthority _ _) -> pure ()
            other -> assertFailure ("expected an empty refusal, got " ++ show other)
        case clusterOnlyEndpoint "local host:1" of
            Left (InvalidEndpointAuthority _ _) -> pure ()
            other -> assertFailure ("expected a whitespace refusal, got " ++ show other)
    , testCase "a local exposure retains the exact runtime identity" $
        withHostExposure $ \exposure -> do
            endpointAuthority (exposureEndpoint exposure)
                @?= ("127.0.0.1:" <> Text.pack (show (exposurePort exposure)))
            endpointScope (exposureEndpoint exposure) @?= HostLocal
            exposureService exposure @?= "registry"
            case exposureRuntimeIdentity exposure of
                Just (relay, generation, operation) -> do
                    assertBool "relay identity is retained" (not (Text.null relay))
                    assertBool "cluster generation is retained" (generation > 0)
                    assertBool "ownership operation is retained" (not (Text.null operation))
                Nothing -> assertFailure "the resolved local exposure lost its runtime identity"
    , testCase "a cluster service exposure resolves only in the cluster" $ do
        exposure <- expectExposure (clusterServiceExposure "minio.default.svc" 9000)
        endpointScope (exposureEndpoint exposure) @?= ClusterOnly
        endpointAuthority (exposureEndpoint exposure) @?= "minio.default.svc:9000"
    ]

planCases :: [TestTree]
planCases =
    [ testCase "the host-served plan proxies blobs and disables redirect" $
        withHostPlan 1 $ \plan -> do
            blobDeliveryStrategy (registryPlanDelivery plan) @?= ProxyBlobs
            renderStorageRedirect plan
                @?= [ "  redirect:"
                    , "    disable: true"
                    ]
            registryPlanClient plan @?= HostLocal
    , testCase "the in-cluster plan redirects and renders no override" $ do
        plan <- clusterPlan 1
        blobDeliveryStrategy (registryPlanDelivery plan)
            @?= RedirectBlobs "minio.default.svc:9000" ClusterOnly
        renderStorageRedirect plan @?= []
    , testCase "delivery uniquely determines the rendered redirect stanza" $ do
        withHostPlan 3 $ \host -> do
            cluster <- clusterPlan 3
            -- The golden pairing: there is no third rendering, and no input other
            -- than the delivery can change it.
            (renderStorageRedirect host, renderStorageRedirect cluster)
                @?= (["  redirect:", "    disable: true"], [])
    , testCase "a zero revision is refused" $
        withHostExposure $ \registry -> do
            store <- expectEndpoint (clusterOnlyEndpoint "minio.default.svc:9000")
            case hostServedRegistryPlan hostLocalClient registry store 0 of
                Left (InvalidRegistryRevision 0) -> pure ()
                other -> assertFailure ("expected a revision refusal, got " ++ show other)
    ]

routeCases :: [TestTree]
routeCases =
    [ testCase "a served blob at the current revision mints the route" $
        withHostPlan 7 $ \plan -> do
            route <- expectRoute (settleBlobRoute plan (servedBlob plan 7))
            readyBlobRouteRevision route @?= 7
    , testCase "a /v2/ answer never mints a route" $
        withHostPlan 7 $ \plan ->
            case settleBlobRoute plan (apiVersionOk plan 7) of
                Left BlobRouteNotABlobProbe -> pure ()
                other ->
                    assertFailure ("expected a non-blob-probe refusal, got " ++ show other)
    , testCase "a proxying plan that redirects is a mismatch" $
        withHostPlan 7 $ \plan -> do
            -- Exactly the live defect: every layer uploads, then the registry 307s
            -- the host client to a name it cannot resolve.
            case settleBlobRoute plan (redirectedBlob plan 7 "minio.default.svc:9000" ClusterOnly) of
                Left (BlobRouteMismatch _ _) -> pure ()
                other -> assertFailure ("expected a delivery mismatch, got " ++ show other)
    , testCase "a proxying plan that errors is a mismatch" $
        withHostPlan 7 $ \plan ->
            case settleBlobRoute plan (servedBlob plan 7){observedStatus = 500} of
                Left (BlobRouteMismatch _ _) -> pure ()
                other -> assertFailure ("expected a status mismatch, got " ++ show other)
    , testCase "a route witness cannot be settled against a replacement revision" $
        withHostPlan 7 $ \plan ->
            case settleBlobRoute plan (servedBlob plan 8) of
                Left (BlobRouteStaleRevision 7 8) -> pure ()
                other -> assertFailure ("expected a stale-revision refusal, got " ++ show other)
    , testCase "a redirecting plan requires the exact planned target" $ do
        plan <- clusterPlan 7
        route <-
            expectRoute
                ( settleBlobRoute
                    plan
                    (onPort 5000 (redirectedBlob plan 7 "minio.default.svc:9000" ClusterOnly))
                )
        readyBlobRouteRevision route @?= 7
        case settleBlobRoute plan (onPort 5000 (redirectedBlob plan 7 "somewhere.else:9000" ClusterOnly)) of
            Left (BlobRouteMismatch _ _) -> pure ()
            other -> assertFailure ("expected a target mismatch, got " ++ show other)
    , testCase "a redirecting plan that serves the blob instead is a mismatch" $ do
        plan <- clusterPlan 7
        case settleBlobRoute plan (onPort 5000 (servedBlob plan 7)) of
            Left (BlobRouteMismatch _ _) -> pure ()
            other -> assertFailure ("expected a delivery mismatch, got " ++ show other)
    , testCase "a probe of a different published port cannot mint the route" $
        withHostPlan 7 $ \plan ->
            case settleBlobRoute plan (onPort 31500 (servedBlob plan 7)) of
                Left (BlobRouteMismatch _ _) -> pure ()
                other -> assertFailure ("expected an exposure mismatch, got " ++ show other)
    , testCase "service, relay, generation, and operation mismatches cannot mint a route" $
        withHostPlan 7 $ \plan -> do
            let exact = servedBlob plan 7
                wrongService = exact{observedService = "web"}
                wrongRelay = exact{observedRuntimeIdentity = fmap (\(_, generation, operation) -> ("replacement", generation, operation)) (observedRuntimeIdentity exact)}
                wrongGeneration = exact{observedRuntimeIdentity = fmap (\(relay, generation, operation) -> (relay, generation + 1, operation)) (observedRuntimeIdentity exact)}
                wrongOperation = exact{observedRuntimeIdentity = fmap (\(relay, generation, _) -> (relay, generation, "other-operation")) (observedRuntimeIdentity exact)}
            mapM_
                ( \observation -> case settleBlobRoute plan observation of
                    Left (BlobRouteMismatch _ _) -> pure ()
                    other -> assertFailure ("expected an exact exposure identity mismatch, got " ++ show other)
                )
                [wrongService, wrongRelay, wrongGeneration, wrongOperation]
    ]

onPort :: Int -> BlobRouteObservation -> BlobRouteObservation
onPort port observation = observation{observedPort = port}

-- Fixtures --------------------------------------------------------------------

withHostExposure ::
    ( forall lifecycleScope planId clusterId service.
      Exposure 'HostLocal lifecycleScope planId clusterId service ->
      IO result
    ) ->
    IO result
withHostExposure consume = do
    outcome <- withRuntimeExposure $ \_ _ _ _ resolved ->
        case withResolvedExposure "registry" resolved (consume . resolvedHostExposure) of
            Left refusal -> assertFailure ("resolved exposure: " ++ show refusal)
            Right run -> run
    either (assertFailure . ("runtime exposure: " ++) . show) pure outcome

withHostPlan ::
    Int ->
    ( forall lifecycleScope planId clusterId service.
      RegistryPlan 'HostLocal 'ClusterOnly lifecycleScope planId clusterId service ->
      IO result
    ) ->
    IO result
withHostPlan revision consume =
    withHostExposure $ \registry -> do
        store <- expectEndpoint (clusterOnlyEndpoint "minio.default.svc:9000")
        case hostServedRegistryPlan hostLocalClient registry store (fromIntegral revision) of
            Left refusal -> assertFailure ("host plan: " ++ show refusal)
            Right plan -> consume plan

clusterPlan ::
    Int ->
    IO (RegistryPlan 'ClusterOnly 'ClusterOnly lifecycleScope planId clusterId service)
clusterPlan revision = do
    registry <- expectExposure (clusterServiceExposure "registry.default.svc" 5000)
    store <- expectEndpoint (clusterOnlyEndpoint "minio.default.svc:9000")
    either
        (assertFailure . ("cluster plan: " ++) . show)
        pure
        ( inClusterRegistryPlan
            ClusterReachesCluster
            clusterOnlyClient
            registry
            store
            (fromIntegral revision)
        )

servedBlob ::
    RegistryPlan client store lifecycleScope planId clusterId service ->
    Int ->
    BlobRouteObservation
servedBlob plan revision =
    BlobRouteObservation
        { observedProbe = BlobHeadProbe "sha256:deadbeef"
        , observedService = exposureService (registryPlanExposure plan)
        , observedPort = exposurePort (registryPlanExposure plan)
        , observedRuntimeIdentity = exposureRuntimeIdentity (registryPlanExposure plan)
        , observedStatus = 200
        , observedRedirect = Nothing
        , observedRevision = fromIntegral revision
        }

redirectedBlob ::
    RegistryPlan client store lifecycleScope planId clusterId service ->
    Int ->
    Text ->
    NetworkScope ->
    BlobRouteObservation
redirectedBlob plan revision authority scope =
    (servedBlob plan revision)
        { observedStatus = 307
        , observedRedirect = Just (authority, scope)
        }

apiVersionOk ::
    RegistryPlan client store lifecycleScope planId clusterId service ->
    Int ->
    BlobRouteObservation
apiVersionOk plan revision =
    (servedBlob plan revision){observedProbe = ApiVersionProbe}

expectEndpoint :: Either NetworkError (Endpoint scope) -> IO (Endpoint scope)
expectEndpoint = either (assertFailure . ("endpoint: " ++) . show) pure

expectExposure ::
    Either NetworkError (Exposure network lifecycleScope planId clusterId service) ->
    IO (Exposure network lifecycleScope planId clusterId service)
expectExposure = either (assertFailure . ("exposure: " ++) . show) pure

expectRoute ::
    Either RegistryPlanError (ReadyBlobRoute client store lifecycleScope planId clusterId service) ->
    IO (ReadyBlobRoute client store lifecycleScope planId clusterId service)
expectRoute = either (assertFailure . ("route: " ++) . show) pure
