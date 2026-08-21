{-# LANGUAGE OverloadedStrings #-}

{- | The described cluster commands, compared as values.

Every case here is an equality between a rendered command and the vector it is
supposed to be. That is only possible because the renderers cannot run anything:
a function that both built and launched an argument vector could be observed only
by launching it, and what a launch proves is that /something/ ran (§ NN).

Three properties are asserted over the whole set rather than case by case,
because each is the kind of thing that is true of every command until one day it
is not: every command names one of exactly three tools, every command is
interpreted by a process of the outer host, and the only two commands carrying
standard input are the two that must not put a credential in @argv@.
-}
module ClusterCommandSpec (tests) where

import Data.List (nub)
import HostBootstrap.Cluster.Command
import HostBootstrap.Effect.Vocabulary (
    EffectFrame (OuterHost),
    EffectStdio (CaptureStreams),
    EffectTarget (ToolTarget),
    HostCommand (commandArguments, commandFrame, commandStdio, commandTarget),
 )
import HostBootstrap.HostTool (HostTool (Docker, Kind, Kubectl))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "described cluster commands"
        [ testGroup "the cluster driver" driverTests
        , testGroup "the container runtime" runtimeTests
        , testGroup "the Kubernetes API" apiTests
        , testGroup "the shape every command has" shapeTests
        ]

-- ---------------------------------------------------------------------------
-- The cluster driver

driverTests :: [TestTree]
driverTests =
    [ testCase "the whole listing is asked for, not a membership question" $
        commandArguments listClustersCommand @?= ["get", "clusters"]
    , testCase "one cluster's kubeconfig is read by name" $
        commandArguments (readKubeconfigCommand "demo") @?= ["get", "kubeconfig", "--name", "demo"]
    , testCase "a declared configuration reaches the creating command" $
        commandArguments (createClusterCommand "demo" (Just "/state/demo.yaml") "/state/demo.kubeconfig")
            @?= [ "create"
                , "cluster"
                , "--name"
                , "demo"
                , "--config"
                , "/state/demo.yaml"
                , "--kubeconfig"
                , "/state/demo.kubeconfig"
                ]
    , testCase "no declared configuration renders no --config at all" $
        commandArguments (createClusterCommand "demo" Nothing "/state/demo.kubeconfig")
            @?= ["create", "cluster", "--name", "demo", "--kubeconfig", "/state/demo.kubeconfig"]
    , testCase "the kubeconfig destination is always named" $
        assertBool
            "every creation names where the credential lands"
            ( all
                (\config -> "--kubeconfig" `elem` commandArguments (createClusterCommand "demo" config "/state/k"))
                [Nothing, Just "/state/demo.yaml"]
            )
    , testCase "removal addresses the cluster by name and nothing else" $
        commandArguments (deleteClusterCommand "demo") @?= ["delete", "cluster", "--name", "demo"]
    ]

-- ---------------------------------------------------------------------------
-- The container runtime

runtimeTests :: [TestTree]
runtimeTests =
    [ testCase "a node's container is matched on its exact whole name" $
        commandArguments (listNodeContainerCommand "demo-control-plane")
            @?= [ "container"
                , "ls"
                , "--all"
                , "--quiet"
                , "--no-trunc"
                , "--filter"
                , "name=^/demo-control-plane$"
                ]
    , testCase "a container's own identifier is read back untruncated" $
        commandArguments (readNodeContainerIdCommand "abc123") @?= ["inspect", "-f", "{{.Id}}", "abc123"]
    , testCase "a container's run state is read through the same inspector" $
        commandArguments (readNodeContainerRunningCommand "abc123")
            @?= ["inspect", "-f", "{{.State.Running}}", "abc123"]
    , testCase "a cordon's limits are applied to the bound identity, not the name" $
        commandArguments (updateNodeContainerCommand ["--cpus", "2", "--memory", "4g"] "abc123")
            @?= ["update", "--cpus", "2", "--memory", "4g", "abc123"]
    , testCase "an empty limit set still addresses exactly one container" $
        commandArguments (updateNodeContainerCommand [] "abc123") @?= ["update", "abc123"]
    ]

-- ---------------------------------------------------------------------------
-- The Kubernetes API

apiTests :: [TestTree]
apiTests =
    [ testCase "the readiness endpoint is asked for raw" $
        commandArguments (readApiReadyzCommand kubeconfig)
            @?= ["--kubeconfig=/dev/stdin", "get", "--raw=/readyz"]
    , testCase "every node is asked for in full" $
        commandArguments (listApiNodesCommand kubeconfig)
            @?= ["--kubeconfig=/dev/stdin", "get", "nodes", "-o", "json"]
    , testCase "the credential travels on standard input rather than in argv" $ do
        commandStdio (readApiReadyzCommand kubeconfig) @?= CaptureStreams kubeconfig
        commandStdio (listApiNodesCommand kubeconfig) @?= CaptureStreams kubeconfig
        assertBool
            "no argument carries the kubeconfig body"
            ( all
                (notElem kubeconfig . commandArguments)
                [readApiReadyzCommand kubeconfig, listApiNodesCommand kubeconfig]
            )
    ]
  where
    kubeconfig = "apiVersion: v1\nclusters: []\n"

-- ---------------------------------------------------------------------------
-- What is true of all of them

{- | The commands as one set, so a property is asserted over the set rather than
restated per case.

The credential-bearing pair is listed separately because "carries standard
input" is exactly the distinction being asserted, and a list that included them
in the silent group would make the assertion vacuous.
-}
silentCommands :: [(HostTool, HostCommand)]
silentCommands =
    [ (Kind, listClustersCommand)
    , (Kind, readKubeconfigCommand "demo")
    , (Kind, createClusterCommand "demo" (Just "/state/demo.yaml") "/state/demo.kubeconfig")
    , (Kind, createClusterCommand "demo" Nothing "/state/demo.kubeconfig")
    , (Kind, deleteClusterCommand "demo")
    , (Docker, listNodeContainerCommand "demo-control-plane")
    , (Docker, readNodeContainerIdCommand "abc123")
    , (Docker, readNodeContainerRunningCommand "abc123")
    , (Docker, updateNodeContainerCommand ["--cpus", "2"] "abc123")
    ]

speakingCommands :: [(HostTool, HostCommand)]
speakingCommands =
    [ (Kubectl, readApiReadyzCommand "kubeconfig-bytes")
    , (Kubectl, listApiNodesCommand "kubeconfig-bytes")
    ]

shapeTests :: [TestTree]
shapeTests =
    [ testCase "every command names the tool its own question belongs to" $
        map (commandTarget . snd) allCommands @?= map (ToolTarget . fst) allCommands
    , testCase "the tools driven here are exactly the tools declared here" $ do
        nub (map fst allCommands) @?= clusterCommandTools
        assertBool
            "no command reaches a tool the declaration does not carry"
            (all ((`elem` clusterCommandTools) . fst) allCommands)
    , testCase "every command is interpreted by a process of the outer host" $
        map (commandFrame . snd) allCommands @?= replicate (length allCommands) OuterHost
    , testCase "only the two credential-bearing commands are given standard input" $ do
        map (commandStdio . snd) silentCommands
            @?= replicate (length silentCommands) (CaptureStreams "")
        map (commandStdio . snd) speakingCommands
            @?= replicate (length speakingCommands) (CaptureStreams "kubeconfig-bytes")
    , testCase "no command is empty" $
        assertBool
            "an empty argument vector would name a tool and ask it nothing"
            (all (not . null . commandArguments . snd) allCommands)
    ]
  where
    allCommands = silentCommands <> speakingCommands
