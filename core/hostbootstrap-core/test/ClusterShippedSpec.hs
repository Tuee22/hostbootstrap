{-# LANGUAGE OverloadedStrings #-}

{- | The closed read-only transaction that re-observes a cluster exposure in
the provider frame.

The codec cases are total applications. The backend's successful exact-runtime
observation is covered against a real protected store and real fixture process
in "ClusterBackendSpec". Here one absent-record refusal enters the far
interpreter directly and another crosses a real child process before that
interpreter runs.
-}
module ClusterShippedSpec (tests) where

import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import qualified FakeCluster
import HostBootstrap.HostTool (HostTool (Kubectl), mkAbsExe)
import System.FilePath ((</>))
import qualified Data.Text as Text
import HostBootstrap.Cluster.Shipped
import HostBootstrap.Handoff.Transaction (withFrameChildTransaction)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.Lift (InVMSelfPath (InVMSelfPath), LocalSelfPath (LocalSelfPath), localContext, mkSelfRef)
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import System.Directory (canonicalizePath, createDirectoryIfMissing)
import System.Environment (getExecutablePath)
import System.IO.Temp (withSystemTempDirectory)
import System.Info (os)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "ClusterShippedSpec"
        [ testGroup "the request and response wire" codecCases
        , testGroup "the far-frame observation" observationCases
        , testGroup "cluster object observation" objectCases
        ]

codecCases :: [TestTree]
codecCases =
    [ testCase "one canonical request round-trips exactly" $ do
        let request = encodeShippedClusterExposureRequest "/var/tmp/demo/cluster/kind/state" "demo-test-run-1" "accelerator"
        (request >>= decodeShippedClusterExposureRequest)
            @?= Right ("/var/tmp/demo/cluster/kind/state", "demo-test-run-1", "accelerator")
    , testCase "invalid and unbounded request fields are refused" $ do
        let invalid =
                [ encodeShippedClusterExposureRequest "relative/state" "demo" "web"
                , encodeShippedClusterExposureRequest "/" "demo" "web"
                , encodeShippedClusterExposureRequest "/var/tmp/state/" "demo" "web"
                , encodeShippedClusterExposureRequest "/var/tmp/../state" "demo" "web"
                , encodeShippedClusterExposureRequest "/var/tmp/state" "bad cluster" "web"
                , encodeShippedClusterExposureRequest "/var/tmp/state" "demo" "bad/service"
                , encodeShippedClusterExposureRequest ("/" <> replicate 2050 'a') "demo" "web"
                ]
        assertBool "an invalid request was admitted" (all (either (const True) (const False)) invalid)
    , testCase "trailing bytes are refused rather than ignored" $ do
        request <- either (assertFailure . Text.unpack) pure (encodeShippedClusterExposureRequest "/var/tmp/state" "demo" "web")
        assertBool
            "a request with a trailing field was admitted"
            (either (const True) (const False) (decodeShippedClusterExposureRequest (request <> "\0extra")))
    , testCase "a foreign transaction prefix falls through" $ do
        interpretShippedClusterExposure "hostbootstrap/ownership/request/v1" >>= (@?= Nothing)
    , testCase "a recognized malformed request is a far-frame refusal" $ do
        request <- either (assertFailure . Text.unpack) pure (encodeShippedClusterExposureRequest "/var/tmp/state" "demo" "web")
        interpreted <- interpretShippedClusterExposure (request <> "\0extra")
        case interpreted of
            Just (Left _) -> pure ()
            other -> assertFailure ("expected a recognized refusal, got " <> show other)
    , testCase "only a canonical bounded port is a response" $ do
        assertBool
            "foreign bytes decoded as a response"
            (either (const True) (const False) (decodeShippedClusterExposureResponse "41000"))
    ]

observationCases :: [TestTree]
observationCases =
    [ testCase "the far interpreter names an absent durable exposure as a refusal" $
        withAbsentRequest $ \request -> do
            interpreted <- interpretShippedClusterExposure request
            case interpreted of
                Just (Left refusal) ->
                    assertBool
                        ("the refusal lost the absent exposure fact: " <> Text.unpack refusal)
                        ( "absent" `Text.isInfixOf` refusal
                            || (os == "mingw32" && "not absolute" `Text.isInfixOf` refusal)
                        )
                other -> assertFailure ("expected an absent-record refusal, got " <> show other)
    , testCase "an observation refusal crosses a real frame-child process" $
        withAbsentRequest $ \request -> do
            self <- getExecutablePath
            crossed <-
                withFrameChildTransaction
                    unresolvedHostConfig
                    (mkSelfRef (LocalSelfPath self) (InVMSelfPath self))
                    localContext
                    request
            case crossed of
                Left refusal -> assertBool "the crossing lost the far-frame refusal" ("absent" `Text.isInfixOf` refusal || "not absolute" `Text.isInfixOf` refusal)
                Right _ -> assertFailure "an absent recorded exposure crossed as a successful response"
    ]

withAbsentRequest :: (ByteString.ByteString -> IO result) -> IO result
withAbsentRequest consume =
    withSystemTempDirectory "hostbootstrap-cluster-exposure-absent" $ \temporary -> do
        canonical <- canonicalizePath temporary
        let stateDirectory
                | os == "mingw32" = "/var/tmp/hostbootstrap-cluster-exposure-absent"
                | otherwise = canonical
        request <-
            either
                (assertFailure . Text.unpack)
                pure
                (encodeShippedClusterExposureRequest stateDirectory "demo" "web")
        consume request

unresolvedHostConfig :: HostConfig
unresolvedHostConfig =
    HostConfig
        { hcSubstrate = Substrate LinuxCpu Amd64
        , hcToolPaths = Map.empty
        }

objectCases :: [TestTree]
objectCases =
    [ testCase "one canonical object request round-trips exactly" $ do
        let request = encodeShippedClusterObjectRequest "/var/tmp/demo/cluster/kind/state" "demo" "storage" ClusterDeployment "object-store"
        (request >>= decodeShippedClusterObjectRequest)
            @?= Right ("/var/tmp/demo/cluster/kind/state", "demo", "storage", ClusterDeployment, "object-store")
    , testCase "a cluster's namespace identity request round-trips exactly" $ do
        let request = encodeShippedClusterObjectRequest "/var/tmp/demo/cluster/kind/state" "demo" "kube-system" ClusterNamespace "kube-system"
        (request >>= decodeShippedClusterObjectRequest)
            @?= Right ("/var/tmp/demo/cluster/kind/state", "demo", "kube-system", ClusterNamespace, "kube-system")
    , testCase "invalid object request fields are refused" $ do
        let invalid =
                [ encodeShippedClusterObjectRequest "relative/state" "demo" "storage" ClusterDeployment "object-store"
                , encodeShippedClusterObjectRequest "/var/tmp/state" "demo" "Storage" ClusterDeployment "object-store"
                , encodeShippedClusterObjectRequest "/var/tmp/state" "demo" "storage" ClusterDeployment "-store"
                , encodeShippedClusterObjectRequest "/var/tmp/state" "demo" "storage" ClusterDeployment (Text.replicate 64 "a")
                , encodeShippedClusterObjectRequest "/var/tmp/state" "demo" "" ClusterStatefulSet "registry"
                ]
        assertBool "an invalid object request was admitted" (all (either (const True) (const False)) invalid)
    , testCase "an object request with an unknown kind or trailing field is refused" $ do
        request <- either (assertFailure . Text.unpack) pure
            (encodeShippedClusterObjectRequest "/var/tmp/state" "demo" "storage" ClusterDeployment "object-store")
        assertBool "a trailing field was admitted"
            (either (const True) (const False) (decodeShippedClusterObjectRequest (request <> "\0extra")))
        let (prefix, _) = ByteString.breakSubstring "deployment" request
        assertBool "an unknown kind was admitted"
            (either (const True) (const False) (decodeShippedClusterObjectRequest (prefix <> "daemonset\0object-store")))
    , testCase "foreign prefixes fall through both cluster interpreters" $ do
        interpretShippedClusterObject "hostbootstrap/ownership/request/v1" >>= (@?= Nothing)
        request <- either (assertFailure . Text.unpack) pure
            (encodeShippedClusterObjectRequest "/var/tmp/state" "demo" "storage" ClusterDeployment "object-store")
        interpretShippedClusterExposure request >>= (@?= Nothing)
    , testCase "only a two-field bounded identity is an object response" $ do
        decodeShippedClusterObjectResponse "hostbootstrap/cluster-object/response/v1\0uid-1\0\&7"
            @?= Right (ClusterObjectIdentity "uid-1" "7")
        assertBool "a one-field response decoded"
            (either (const True) (const False) (decodeShippedClusterObjectResponse "hostbootstrap/cluster-object/response/v1\0uid-1"))
        assertBool "a foreign response decoded"
            (either (const True) (const False) (decodeShippedClusterObjectResponse "uid-1 7"))
    , testCase "the object query reads the cluster's own kubeconfig and refuses absent, missing and malformed answers" $
        withSystemTempDirectory "hostbootstrap-cluster-object" $ \temporary -> do
            root <- canonicalizePath temporary
            _ <- FakeCluster.newClusterFixture root []
            self <- FakeCluster.prepareFixtureExecutables root
            kubectl <- either (assertFailure . show) pure (mkAbsExe (FakeCluster.fixtureToolPath self "kubectl"))
            let state = if os == "mingw32" then "/var/tmp/hostbootstrap-cluster-object" else root </> "state"
                cfg = HostConfig (Substrate LinuxCpu Amd64) (Map.singleton Kubectl kubectl)
                observe = observeClusterObject cfg state "demo" "storage" ClusterDeployment "object-store"
                refused label outcome = case outcome of
                    Left _ -> pure ()
                    Right _ -> assertFailure label
            FakeCluster.withFakeClusterClient root $ do
                refused "an absent kubeconfig was observed" =<< observe
                if os == "mingw32"
                    then pure ()
                    else do
                        createStateWithKubeconfig state
                        refused "an absent object was observed" =<< observe
                        writeFile (root </> "cluster-object-storage-deployment-object-store") "uid-1 7"
                        observe >>= (@?= Right (ClusterObjectIdentity "uid-1" "7"))
                        writeFile (root </> "cluster-object-storage-deployment-object-store") "uid-1 7 extra"
                        refused "a malformed identity was observed" =<< observe
                        let observeNamespace = observeClusterObject cfg state "demo" "kube-system" ClusterNamespace "kube-system"
                        refused "an absent namespace was observed" =<< observeNamespace
                        writeFile (root </> "cluster-object-kube-system-namespace-kube-system") "cluster-uid 4"
                        observeNamespace >>= (@?= Right (ClusterObjectIdentity "cluster-uid" "4"))
    ]
  where
    createStateWithKubeconfig state = do
        createDirectoryIfMissing True state
        writeFile (state </> "cluster.kubeconfig") "apiVersion: v1\n"
