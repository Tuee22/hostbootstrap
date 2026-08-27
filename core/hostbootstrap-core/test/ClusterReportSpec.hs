{-# LANGUAGE OverloadedStrings #-}

{- | The cluster report, applied to values.

Nothing here runs a cluster driver, a container runtime, or an API server. Every
classifier is a total function of the interpreter's own outcome, so every
constructor and every refusal is reached by handing it one — which is the whole
reason the classification is not inside an interpreter program (§ NN). A stand-in
would only be able to answer what it was told to answer; a value cannot.

The families run and are counted on every gate host, because a function applied
to a value needs no POSIX (§ JJ).
-}
module ClusterReportSpec (tests) where

import Data.Either (isLeft)
import Data.List (intercalate)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Report
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.Ownership.Object (ObjectIdentity, mkObjectIdentity)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "cluster report"
        [ testGroup "what counts as an answer at all" answerTests
        , testGroup "the cluster listing" listingTests
        , testGroup "a node's container" containerTests
        , testGroup "a container's run state" runStateTests
        , testGroup "the kubeconfig" kubeconfigTests
        , testGroup "the API server's readiness" readinessTests
        , testGroup "the API server's node list" nodeTests
        ]

-- ---------------------------------------------------------------------------
-- Helpers

answered :: String -> Either String CapturedRun
answered body = Right (CapturedRun ExitSuccess body "")

identityOf :: String -> ObjectIdentity
identityOf value =
    either (error . show) id (mkObjectIdentity (TextEncoding.encodeUtf8 (Text.pack value)))

controlPlane :: String
controlPlane = "demo-control-plane"

worker :: String
worker = "demo-worker"

-- ---------------------------------------------------------------------------
-- What counts as an answer

answerTests :: [TestTree]
answerTests =
    [ testCase "a command that produced no child is not an answer" $
        classifyClusterListing "demo" (Left "kind not found on this host")
            @?= Left (ClusterCommandUnrun "kind not found on this host")
    , testCase "a non-zero exit carries the tool's own first diagnostic" $
        classifyClusterListing "demo" (Right (CapturedRun (ExitFailure 1) "" "ERROR: no provider\nmore\n"))
            @?= Left (ClusterCommandExited 1 "ERROR: no provider")
    , testCase "a non-zero exit with no diagnostic still names one" $
        classifyClusterListing "demo" (Right (CapturedRun (ExitFailure 7) "" ""))
            @?= Left (ClusterCommandExited 7 "no diagnostic")
    , testCase "a success that wrote to standard error is not an answer" $
        classifyClusterListing "demo" (Right (CapturedRun ExitSuccess "demo\n" "warning\n"))
            @?= Left (ClusterCommandNoisy "warning")
    , testCase "nvkind creation admits noisy success but not a missing or failed child" $ do
        classifyNvkindCreateReport (Right (CapturedRun ExitSuccess "post-setup\n" "Creating cluster\n")) @?= Right ()
        classifyNvkindCreateReport (Left "nvkind missing") @?= Left (ClusterCommandUnrun "nvkind missing")
        classifyNvkindCreateReport (Right (CapturedRun (ExitFailure 1) "" "setup failed\n"))
            @?= Left (ClusterCommandExited 1 "setup failed")
    , testCase "each fault renders as itself" $ do
        let rendered =
                map
                    clusterReportFaultMessage
                    [ ClusterCommandUnrun "no child"
                    , ClusterCommandExited 2 "refused"
                    , ClusterCommandNoisy "noise"
                    , ClusterReportUnreadable "shape"
                    ]
        rendered
            @?= [ "the cluster command produced no process: no child"
                , "the cluster command exited 2: refused"
                , "the cluster command succeeded and wrote to standard error: noise"
                , "the cluster report is not one this vocabulary admits: shape"
                ]
    , testCase "a body that does not end in a newline is a refusal" $
        assertBool "unterminated" (isLeft (classifyClusterListing "demo" (answered "demo")))
    , testCase "a carriage return is a refusal rather than a trimmed row" $
        assertBool "carriage return" (isLeft (classifyClusterListing "demo" (answered "demo\r\n")))
    , testCase "a byte outside ASCII is a refusal" $
        assertBool "non-ascii" (isLeft (classifyClusterListing "demo" (answered "dem\xe9\n")))
    , testCase "an empty row is a refusal rather than a dropped one" $
        assertBool "empty row" (isLeft (classifyClusterListing "demo" (answered "demo\n\n")))
    , testCase "a line past the admitted bound is a refusal" $
        assertBool
            "over-long"
            (isLeft (classifyClusterReport 8 (answered (replicate 9 'a' <> "\n"))))
    , testCase "an empty body is an empty listing rather than a malformed one" $
        classifyClusterReport clusterReportLineBound (answered "") @?= Right []
    ]

-- ---------------------------------------------------------------------------
-- The cluster listing

listingTests :: [TestTree]
listingTests =
    [ testCase "a listing naming this cluster is presence" $
        classifyClusterListing "demo" (answered "other\ndemo\n") @?= Right ClusterPresent
    , testCase "a listing not naming it is an authoritative absence" $
        classifyClusterListing "demo" (answered "other\n") @?= Right ClusterAbsent
    , testCase "an empty listing is an authoritative absence" $
        classifyClusterListing "demo" (answered "") @?= Right ClusterAbsent
    , testCase "the same name twice is a refusal rather than a presence" $
        assertBool "duplicate" (isLeft (classifyClusterListing "demo" (answered "demo\ndemo\n")))
    , testCase "a name outside the portable alphabet is a refusal" $
        assertBool "alphabet" (isLeft (classifyClusterListing "demo" (answered "de mo\n")))
    , testCase "the alphabet admits exactly what a plan can declare" $ do
        assertBool "dotted, dashed, and underscored names" (all safeClusterName ["a.b", "a-b", "a_b", "A9"])
        assertBool "empty, spaced, and over-long names" (not (any safeClusterName ["", "a b", replicate 129 'a']))
    ]

-- ---------------------------------------------------------------------------
-- A node's container

containerTests :: [TestTree]
containerTests =
    [ testCase "no container at the name is an authoritative absence" $
        classifyNodeContainer (answered "") @?= Right Nothing
    , testCase "one container at the name is its identity" $
        classifyNodeContainer (answered (containerId <> "\n")) @?= Right (Just (identityOf containerId))
    , testCase "two containers at one exact name is a refusal" $
        assertBool
            "duplicate"
            (isLeft (classifyNodeContainer (answered (containerId <> "\n" <> otherId <> "\n"))))
    , testCase "an identifier carrying whitespace is a refusal" $
        assertBool "whitespace" (isLeft (classifyNodeContainer (answered "abc def\n")))
    , testCase "the readback is exactly one identifier" $
        classifyNodeContainerIdentity (answered (containerId <> "\n")) @?= Right (identityOf containerId)
    , testCase "a readback naming nothing is a refusal" $
        assertBool "empty readback" (isLeft (classifyNodeContainerIdentity (answered "")))
    , testCase "a readback naming two things is a refusal" $
        assertBool
            "two"
            (isLeft (classifyNodeContainerIdentity (answered (containerId <> "\n" <> otherId <> "\n"))))
    ]
  where
    containerId = replicate 64 'a'
    otherId = replicate 64 'b'

-- ---------------------------------------------------------------------------
-- A container's run state

runStateTests :: [TestTree]
runStateTests =
    [ testCase "the runtime's own true is running" $
        classifyContainerRunState (answered "true\n") @?= Right ContainerRunning
    , testCase "the runtime's own false is not running" $
        classifyContainerRunState (answered "false\n") @?= Right ContainerNotRunning
    , testCase "anything else is a refusal rather than a guess" $
        assertBool
            "third value"
            (all (isLeft . classifyContainerRunState . answered) ["True\n", "yes\n", "\n", "true\nfalse\n"])
    ]

-- ---------------------------------------------------------------------------
-- The kubeconfig

kubeconfigTests :: [TestTree]
kubeconfigTests =
    [ testCase "a well-framed document is returned whole" $
        classifyKubeconfig (answered body) @?= Right body
    , testCase "an empty kubeconfig is a refusal" $
        assertBool "empty" (isLeft (classifyKubeconfig (answered "")))
    , testCase "an unterminated kubeconfig is a refusal" $
        assertBool "unterminated" (isLeft (classifyKubeconfig (answered "apiVersion: v1")))
    , testCase "a carriage return is a refusal" $
        assertBool "carriage return" (isLeft (classifyKubeconfig (answered "apiVersion: v1\r\n")))
    , testCase "a byte outside ASCII is a refusal" $
        assertBool "non-ascii" (isLeft (classifyKubeconfig (answered "api\xe9\n")))
    , testCase "a document past the admitted ceiling is a refusal" $
        assertBool
            "over-long"
            (isLeft (classifyKubeconfig (answered (replicate (kubeconfigByteBound + 1) 'a' <> "\n"))))
    ]
  where
    body = "apiVersion: v1\nclusters: []\n"

-- ---------------------------------------------------------------------------
-- The API server's readiness

readinessTests :: [TestTree]
readinessTests =
    [ testCase "a quiet success is ready" $
        classifyApiReadiness (answered "ok") @?= ApiReady
    , testCase "a control plane that refuses is not ready rather than a fault" $
        classifyApiReadiness (Right (CapturedRun (ExitFailure 1) "" "connection refused\n")) @?= ApiNotReady
    , testCase "a success that complained is not ready" $
        classifyApiReadiness (Right (CapturedRun ExitSuccess "ok" "warning\n")) @?= ApiNotReady
    , testCase "a command that produced no child is not ready" $
        classifyApiReadiness (Left "kubectl not found") @?= ApiNotReady
    ]

-- ---------------------------------------------------------------------------
-- The API server's node list

nodeTests :: [TestTree]
nodeTests =
    [ testCase "every declared node Ready is readiness" $
        classifyApiNodes declared (answered (nodeDocument [(controlPlane, True), (worker, True)]))
            @?= Right NodesReady
    , testCase "one declared node not Ready is not readiness" $
        classifyApiNodes declared (answered (nodeDocument [(controlPlane, True), (worker, False)]))
            @?= Right NodesNotReady
    , testCase "a node carrying no Ready condition is not ready" $
        classifyApiNodes ["solo"] (answered "{\"items\":[{\"metadata\":{\"name\":\"solo\"},\"status\":{}}]}\n")
            @?= Right NodesNotReady
    , testCase "a different node set is unexpected rather than a fault" $
        classifyApiNodes declared (answered (nodeDocument [(controlPlane, True)]))
            @?= Right NodesUnexpected
    , testCase "a document this vocabulary cannot decode is a refusal" $
        assertBool "undecodable" (isLeft (classifyApiNodes declared (answered "not json\n")))
    , testCase "a document carrying no items array is a refusal" $
        assertBool "no items" (isLeft (classifyApiNodes declared (answered "{}\n")))
    , testCase "an item that is not an object is a refusal" $
        assertBool "scalar item" (isLeft (classifyApiNodes declared (answered "{\"items\":[1]}\n")))
    , testCase "a node whose name is not a string is a refusal" $
        assertBool
            "numeric name"
            (isLeft (classifyApiNodes declared (answered "{\"items\":[{\"metadata\":{\"name\":1}}]}\n")))
    , testCase "the same node named twice is a refusal" $
        assertBool
            "duplicate"
            (isLeft (classifyApiNodes [controlPlane] (answered (nodeDocument [(controlPlane, True), (controlPlane, True)]))))
    , testCase "an unterminated document is a refusal" $
        assertBool "unterminated" (isLeft (classifyApiNodes declared (answered "{\"items\":[]}")))
    , testCase "an empty document is a refusal" $
        assertBool "empty" (isLeft (classifyApiNodes declared (answered "")))
    ]
  where
    declared = [controlPlane, worker]

{- | One node-list document, built from the pairs a case declares.

Written out rather than encoded through a schema, because what these cases are
about is the shape the API server really produces and a round-trip through this
project's own encoder would be asserting against itself.
-}
nodeDocument :: [(String, Bool)] -> String
nodeDocument nodes =
    "{\"items\":[" <> intercalate "," (map item nodes) <> "]}\n"
  where
    item (name, ready) =
        "{\"metadata\":{\"name\":\""
            <> name
            <> "\"},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\""
            <> (if ready then "True" else "False")
            <> "\"}]}}"
