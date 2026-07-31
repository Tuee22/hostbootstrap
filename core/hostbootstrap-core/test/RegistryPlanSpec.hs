{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The scope-indexed network algebra and the proof-gated registry plan.

The central claim is negative and is proved by the compile-fail fixtures rather
than here: a host-local client cannot be given a cluster-only redirect, because
no 'Reachability' witness exists for that pair. These cases cover the positive
constructions, the derived rendering, and every way an observation can fail to
mint a route witness.
-}
module RegistryPlanSpec (tests) where

import Data.Text (Text)
import HostBootstrap.Network
import HostBootstrap.RegistryPlan
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

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
    [ testCase "an endpoint carries its scope, not a guess from its text" $ do
        host <- expectEndpoint (hostLocalEndpoint "localhost:30500")
        cluster <- expectEndpoint (clusterOnlyEndpoint "minio.default.svc:9000")
        endpointScope host @?= HostLocal
        endpointScope cluster @?= ClusterOnly
        endpointAuthority cluster @?= "minio.default.svc:9000"
    , testCase "a URL is not an authority" $
        case hostLocalEndpoint "http://localhost:30500" of
            Left (InvalidEndpointAuthority _ _) -> pure ()
            other -> assertFailure ("expected a scheme refusal, got " ++ show other)
    , testCase "a path is not an authority" $
        case clusterOnlyEndpoint "minio.default.svc:9000/registry" of
            Left (InvalidEndpointAuthority _ _) -> pure ()
            other -> assertFailure ("expected a path refusal, got " ++ show other)
    , testCase "an empty or whitespace authority is refused" $ do
        case hostLocalEndpoint "   " of
            Left (InvalidEndpointAuthority _ _) -> pure ()
            other -> assertFailure ("expected an empty refusal, got " ++ show other)
        case hostLocalEndpoint "local host:1" of
            Left (InvalidEndpointAuthority _ _) -> pure ()
            other -> assertFailure ("expected a whitespace refusal, got " ++ show other)
    , testCase "a loopback exposure is always 127.0.0.1" $ do
        exposure <- expectExposure (loopbackExposure 30500)
        endpointAuthority (exposureEndpoint exposure) @?= "127.0.0.1:30500"
        exposurePort exposure @?= 30500
        endpointScope (exposureEndpoint exposure) @?= HostLocal
    , testCase "an out-of-range exposure port is refused" $
        case loopbackExposure 0 of
            Left (InvalidEndpointPort 0) -> pure ()
            other -> assertFailure ("expected a port refusal, got " ++ show other)
    , testCase "a cluster service exposure resolves only in the cluster" $ do
        exposure <- expectExposure (clusterServiceExposure "minio.default.svc" 9000)
        endpointScope (exposureEndpoint exposure) @?= ClusterOnly
        endpointAuthority (exposureEndpoint exposure) @?= "minio.default.svc:9000"
    ]

planCases :: [TestTree]
planCases =
    [ testCase "the host-served plan proxies blobs and disables redirect" $ do
        plan <- hostPlan 1
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
        hostRendered <- renderStorageRedirect <$> hostPlan 3
        clusterRendered <- renderStorageRedirect <$> clusterPlan 3
        -- The golden pairing: there is no third rendering, and no input other
        -- than the delivery can change it.
        (hostRendered, clusterRendered)
            @?= (["  redirect:", "    disable: true"], [])
    , testCase "a zero revision is refused" $ do
        registry <- expectExposure (loopbackExposure 30500)
        store <- expectEndpoint (clusterOnlyEndpoint "minio.default.svc:9000")
        case hostServedRegistryPlan hostLocalClient registry store 0 of
            Left (InvalidRegistryRevision 0) -> pure ()
            other -> assertFailure ("expected a revision refusal, got " ++ show other)
    ]

routeCases :: [TestTree]
routeCases =
    [ testCase "a served blob at the current revision mints the route" $ do
        plan <- hostPlan 7
        route <- expectRoute (settleBlobRoute plan (servedBlob 7))
        readyBlobRouteRevision route @?= 7
    , testCase "a /v2/ answer never mints a route" $ do
        plan <- hostPlan 7
        case settleBlobRoute plan (apiVersionOk 7) of
            Left BlobRouteNotABlobProbe -> pure ()
            other ->
                assertFailure ("expected a non-blob-probe refusal, got " ++ show other)
    , testCase "a proxying plan that redirects is a mismatch" $ do
        plan <- hostPlan 7
        -- Exactly the live defect: every layer uploads, then the registry 307s
        -- the host client to a name it cannot resolve.
        case settleBlobRoute plan (redirectedBlob 7 "minio.default.svc:9000" ClusterOnly) of
            Left (BlobRouteMismatch _ _) -> pure ()
            other -> assertFailure ("expected a delivery mismatch, got " ++ show other)
    , testCase "a proxying plan that errors is a mismatch" $ do
        plan <- hostPlan 7
        case settleBlobRoute plan (servedBlob 7){observedStatus = 500} of
            Left (BlobRouteMismatch _ _) -> pure ()
            other -> assertFailure ("expected a status mismatch, got " ++ show other)
    , testCase "a route witness cannot be settled against a replacement revision" $ do
        plan <- hostPlan 7
        case settleBlobRoute plan (servedBlob 8) of
            Left (BlobRouteStaleRevision 7 8) -> pure ()
            other -> assertFailure ("expected a stale-revision refusal, got " ++ show other)
    , testCase "a redirecting plan requires the exact planned target" $ do
        plan <- clusterPlan 7
        route <-
            expectRoute
                ( settleBlobRoute
                    plan
                    (onPort 5000 (redirectedBlob 7 "minio.default.svc:9000" ClusterOnly))
                )
        readyBlobRouteRevision route @?= 7
        case settleBlobRoute plan (onPort 5000 (redirectedBlob 7 "somewhere.else:9000" ClusterOnly)) of
            Left (BlobRouteMismatch _ _) -> pure ()
            other -> assertFailure ("expected a target mismatch, got " ++ show other)
    , testCase "a redirecting plan that serves the blob instead is a mismatch" $ do
        plan <- clusterPlan 7
        case settleBlobRoute plan (onPort 5000 (servedBlob 7)) of
            Left (BlobRouteMismatch _ _) -> pure ()
            other -> assertFailure ("expected a delivery mismatch, got " ++ show other)
    , testCase "a probe of a different published port cannot mint the route" $ do
        plan <- hostPlan 7
        case settleBlobRoute plan (onPort 31500 (servedBlob 7)) of
            Left (BlobRouteMismatch _ _) -> pure ()
            other -> assertFailure ("expected an exposure mismatch, got " ++ show other)
    ]

onPort :: Int -> BlobRouteObservation -> BlobRouteObservation
onPort port observation = observation{observedPort = port}

-- Fixtures --------------------------------------------------------------------

hostPlan :: Int -> IO (RegistryPlan 'HostLocal 'ClusterOnly)
hostPlan revision = do
    registry <- expectExposure (loopbackExposure 30500)
    store <- expectEndpoint (clusterOnlyEndpoint "minio.default.svc:9000")
    either
        (assertFailure . ("host plan: " ++) . show)
        pure
        (hostServedRegistryPlan hostLocalClient registry store (fromIntegral revision))

clusterPlan :: Int -> IO (RegistryPlan 'ClusterOnly 'ClusterOnly)
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

servedBlob :: Int -> BlobRouteObservation
servedBlob revision =
    BlobRouteObservation
        { observedProbe = BlobHeadProbe "sha256:deadbeef"
        , observedPort = 30500
        , observedStatus = 200
        , observedRedirect = Nothing
        , observedRevision = fromIntegral revision
        }

redirectedBlob :: Int -> Text -> NetworkScope -> BlobRouteObservation
redirectedBlob revision authority scope =
    (servedBlob revision)
        { observedStatus = 307
        , observedRedirect = Just (authority, scope)
        }

apiVersionOk :: Int -> BlobRouteObservation
apiVersionOk revision =
    (servedBlob revision){observedProbe = ApiVersionProbe}

expectEndpoint :: Either NetworkError (Endpoint scope) -> IO (Endpoint scope)
expectEndpoint = either (assertFailure . ("endpoint: " ++) . show) pure

expectExposure :: Either NetworkError (Exposure scope) -> IO (Exposure scope)
expectExposure = either (assertFailure . ("exposure: " ++) . show) pure

expectRoute ::
    Either RegistryPlanError (ReadyBlobRoute client store) ->
    IO (ReadyBlobRoute client store)
expectRoute = either (assertFailure . ("route: " ++) . show) pure
