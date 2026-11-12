{-# LANGUAGE OverloadedStrings #-}

{- | The described cluster commands, compared as values.

Every case here is an equality between a rendered command and the vector it is
supposed to be. That is only possible because the renderers cannot run anything:
a function that both built and launched an argument vector could be observed only
by launching it, and what a launch proves is that /something/ ran (§ NN).

Three properties are asserted over the whole set rather than case by case,
because each is the kind of thing that is true of every command until one day it
is not: every command names one of exactly four tools, every command is
interpreted by a process of the outer host, and the only two commands carrying
standard input are the two that must not put a credential in @argv@.
-}
module ClusterCommandSpec (tests) where

import Data.List (nub, isInfixOf, isPrefixOf, tails)
import Data.Foldable (for_)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Expect
import qualified SourceGuard
import System.FilePath ((</>))
import System.Exit (ExitCode (ExitSuccess, ExitFailure))
import HostBootstrap.Cluster.Ownership (clusterCommandBounds)
import HostBootstrap.Cluster.Report (classifyClusterCommandRun, classifyClusterListing, ClusterReportFault (ClusterCommandUnrun, ClusterCommandExited), clusterReportFaultMessage)
import HostBootstrap.Cluster.Backend (classifyClusterStatus, ClusterStatusObservation (ClusterStatusProbeFailed))
import HostBootstrap.Effect.Run (CapturedRun (..), BoundedRun (..), RunBounds (..))
import HostBootstrap.Cluster.Command
import HostBootstrap.Effect.Vocabulary (
    hostCommand,
    EffectFrame (OuterHost),
    EffectStdio (CaptureStreams),
    EffectTarget (ToolTarget),
    HostCommand (commandArguments, commandFrame, commandStdio, commandTarget),
 )
import HostBootstrap.HostTool (HostTool (Docker, Kind, Kubectl, Nvkind, Helm))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "described cluster commands"
        [ testGroup "bounded cluster command policy" boundedPolicyTests
        , testGroup "the cluster driver" driverTests
        , testGroup "the container runtime" runtimeTests
        , testGroup "the Kubernetes API" apiTests
        , testGroup "the shape every command has" shapeTests
        ]

-- ---------------------------------------------------------------------------
-- The cluster driver

driverTests :: [TestTree]
driverTests =
    [ testCase "the whole listing is asked for, not a membership question" $
        commandArguments listClustersCommand @?= ["--quiet", "get", "clusters"]
    , testCase "one cluster's kubeconfig is read by name" $
        commandArguments (readKubeconfigCommand "demo") @?= ["get", "kubeconfig", "--name", "demo"]
    , testCase "a declared configuration reaches the creating command" $
        commandArguments (createClusterCommand KindDriver "demo" (Just "/state/demo.yaml") "/tmp/private-demo.kubeconfig")
            @?= [ "create"
                , "cluster"
                , "--name"
                , "demo"
                , "--config"
                , "/state/demo.yaml"
                , "--kubeconfig"
                , "/tmp/private-demo.kubeconfig"
                , "--wait"
                , "10m"
                ]
    , testCase "no declared configuration renders no --config at all" $
        commandArguments (createClusterCommand KindDriver "demo" Nothing "/tmp/private-demo.kubeconfig")
            @?= ["create", "cluster", "--name", "demo", "--kubeconfig", "/tmp/private-demo.kubeconfig", "--wait", "10m"]
    , testCase "nvkind creation reaches only the selected GPU driver vocabulary" $
        commandArguments (createClusterCommand NvkindDriver "demo" (Just "/state/demo.yaml") "/tmp/private-demo.kubeconfig")
            @?= [ "cluster"
                , "create"
                , "--name"
                , "demo"
                , "--config-template"
                , "/state/demo.yaml"
                , "--kubeconfig"
                , "/tmp/private-demo.kubeconfig"
                , "--wait"
                , "10m"
                ]
    , testCase "the private staging kubeconfig is always named" $
        assertBool
            "every creation names the private local file its caller opened"
            (all (\config -> "--kubeconfig" `elem` commandArguments (createClusterCommand KindDriver "demo" config "/tmp/private")) [Nothing, Just "/state/demo.yaml"])
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
    , testCase "a dotted node name is quoted before both anchors" $
        commandArguments (listNodeContainerCommand "demo.v1-control-plane")
            @?= ["container", "ls", "--all", "--quiet", "--no-trunc", "--filter", "name=^/demo\\.v1-control-plane$"]
    , testCase "every dot is literal while other admitted punctuation stays exact" $
        last (commandArguments (listNodeContainerCommand "a.b.c_-9")) @?= "name=^/a\\.b\\.c_-9$"
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
silentCommands = filter ((== CaptureStreams "") . commandStdio . snd) declaredCommands

speakingCommands :: [(HostTool, HostCommand)]
speakingCommands = filter ((/= CaptureStreams "") . commandStdio . snd) declaredCommands

-- The production admission catalog supplies the checked command families.
declaredCommands :: [(HostTool, HostCommand)]
declaredCommands = concatMap clusterDriverCommands [KindDriver, NvkindDriver]

shapeTests :: [TestTree]
shapeTests =
    [ testCase "each driver declares its complete ownership API and chart tools" $ do
        clusterDriverTools KindDriver @?= [Kind, Docker, Kubectl, Helm]
        clusterDriverTools NvkindDriver @?= [Kind, Nvkind, Docker, Kubectl, Helm]
        for_ [KindDriver, NvkindDriver] $ \driver -> do
            assertBool "a described command lacks its selected driver's declaration"
                (all ((`elem` clusterDriverTools driver) . fst) (clusterDriverCommands driver))
            assertBool "a declared non-chart tool has no representative command"
                (all (\tool -> tool == Helm || tool `elem` map fst (clusterDriverCommands driver)) (clusterDriverTools driver))
    , testCase "physical cluster command sites stay inside their driver tool declarations" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            description <- SourceGuard.readPackageDescription
            sources <- SourceGuard.readLibrarySources packageRoot description
            let clusterSources = [(name,path,source) | (name,path,source) <- sources, directClusterModule name]
                declaredNames driver = map show (clusterDriverTools driver)
            assertBool "the actual public and private cluster homes are absent" (length clusterSources > 5)
            for_ ["HostBootstrap.Cluster.Backend", "HostBootstrap.Cluster.Command", "HostBootstrap.Cluster.Ownership"] $ \name ->
                assertBool ("the actual driver command home is absent: " <> name)
                    (name `elem` [moduleName | (moduleName,_,_) <- clusterSources])
            directClusterModule "HostBootstrap.Cluster.Backend" @?= True
            directClusterModule "HostBootstrap.Cluster.Command" @?= True
            directClusterModule "HostBootstrap.Cluster.Cordon.Foundation" @?= False
            for_ clusterSources $ \(name,path,source) ->
                for_ (commandSiteTools source) $ \tool ->
                    assertBool (path <> " contains an undeclared command target: " <> tool)
                        (if name == "HostBootstrap.Cluster.Command"
                            then any (tool `elem`) (map declaredNames [KindDriver,NvkindDriver])
                            else all (tool `elem`) (map declaredNames [KindDriver,NvkindDriver]))
            -- The guard's predicate is itself applied to constructed source values.
            commandSiteTools "-- hostCommand UnlistedTool\nexample = hostCommand Docker []"
                @?= ["Docker"]
            commandSiteTools "example = \"hostCommand UnlistedTool\"" @?= []
            commandSiteTools "example = Effect.hostCommand UnlistedTool []" @?= ["UnlistedTool"]
            assertBool "an unknown tool would bypass the closed row"
                ("UnlistedTool" `notElem` declaredNames KindDriver)
            backend <- maybe (assertFailure "the physical cluster backend is absent") pure
                (lookup "HostBootstrap.Cluster.Backend" [(name,source) | (name,_,source) <- sources])
            discovered <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "discoverStrongClusterBackend" backend)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "requiredTools = clusterDriverTools driver") (unwords discovered) @?= 1
    , testCase "every command names the tool its own question belongs to" $
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
    allCommands = declaredCommands


boundedPolicyTests :: [TestTree]
boundedPolicyTests =
    [ testCase "both creation drivers have a wall beyond their rendered ten-minute wait" $
        for_ [KindDriver, NvkindDriver] $ \driver -> do
            let command = createClusterCommand driver "demo" Nothing "/tmp/private-demo.kubeconfig"
            assertBool "the described creation still waits ten minutes" ("10m" `elem` commandArguments command)
            boundWallMicros (clusterCommandBounds command) @?= 660000000
    , testCase "listing inspection update deletion and API commands have short finite walls" $
        for_ [listClustersCommand, readKubeconfigCommand "demo", deleteClusterCommand "demo",
              listNodeContainerCommand "demo-control-plane", readNodeContainerIdCommand "abc123",
              readNodeContainerRunningCommand "abc123", updateNodeContainerCommand ["--cpus", "2"] "abc123",
              readApiReadyzCommand "credential", listApiNodesCommand "credential"] $ \command ->
            boundWallMicros (clusterCommandBounds command) @?= 60000000
    , testCase "every command row bounds output and termination grace" $
        for_ (silentCommands <> speakingCommands) $ \(_, command) -> do
            boundOutputBytes (clusterCommandBounds command) @?= 4194304
            boundTerminationGraceMicros (clusterCommandBounds command) @?= 2000000
    , testCase "Helm waits retain a finite wall beyond their default wait" $
        boundWallMicros (clusterCommandBounds (hostCommand Helm ["upgrade", "--install", "demo", "chart", "--wait"])) @?= 600000000
    , testCase "a five-minute rollout wait has a longer finite command wall" $
        boundWallMicros (clusterCommandBounds (hostCommand Kubectl ["rollout", "status", "deployment/demo", "--timeout=5m"])) @?= 360000000
    , testCase "a creation-shaped vector for another tool gets no creation allowance" $
        boundWallMicros (clusterCommandBounds (hostCommand Docker ["create", "cluster"])) @?= 60000000
    , testCase "completed commands retain their exit and both complete streams" $
        for_ [ExitSuccess, ExitFailure 17] $ \code -> do
            let captured = CapturedRun code "complete stdout\n" "complete stderr\n"
            classifyClusterCommandRun (BoundedCompleted captured) @?= Right captured
    , testCase "a completed failing command cannot classify as absence" $
        classifyClusterListing "demo" (classifyClusterCommandRun (BoundedCompleted (CapturedRun (ExitFailure 17) "" "failed\n")))
            @?= Left (ClusterCommandExited 17 "failed")
    , testCase "timeout becomes a named report fault and status probe failure" $ do
        let reason = "cluster command exceeded its deadline and its process group was terminated"
            fault = ClusterCommandUnrun reason
            outcome = classifyClusterCommandRun BoundedTimedOut
        outcome @?= Left (Text.unpack reason)
        classifyClusterListing "demo" outcome @?= Left fault
        classifyClusterStatus "demo" outcome @?= ClusterStatusProbeFailed (clusterReportFaultMessage fault)
    , testCase "output overflow and failed execution produce no successful report" $ do
        classifyClusterCommandRun BoundedOutputLimit
            @?= Left "cluster command exceeded its output bound and its process group was terminated"
        classifyClusterCommandRun (BoundedFailed "spawn refused") @?= Left "cluster command failed to execute: spawn refused"
    , testCase "the actual ownership and backend paths use the sole bounded runner" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            let readSource name = do
                    let directory = if name == "Ownership.hs" then "internal" </> "cluster-ownership" else "src"
                    raw <- ByteString.readFile (packageRoot </> directory </> "HostBootstrap" </> "Cluster" </> name)
                    Text.unpack <$> Expect.expectRight (TextEncoding.decodeUtf8' raw)
            ownership <- readSource "Ownership.hs"
            backend <- readSource "Backend.hs"
            tokens <- Expect.expectRight (SourceGuard.haskellDefinitionTokens "interpretClusterCommand" ownership)
            for_ ["resolveLaunch", "clusterCommandBounds", "RunNamespace", "getCurrentDirectory", "getEnvironment", "runBoundedGroupedWithInput", "effectStdin", "classifyClusterCommandRun"] $ \name ->
                assertBool ("the actual interpreter retains " <> name) (name `elem` tokens)
            assertBool "the exact described stdin reaches the grouped runner"
                (SourceGuard.haskellTokens "outcome <- runBoundedGroupedWithInput (clusterCommandBounds command) (RunNamespace directory environment) executable arguments (TextEncoding.encodeUtf8 (Text.pack (effectStdin (commandStdio command))))" `isInfixOf` tokens)
            SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "interpret = interpretClusterCommand") ownership @?= 1
            SourceGuard.countHaskellIdentifier "interpretHostCommand" ownership @?= 0
            SourceGuard.countHaskellIdentifier "interpretHostCommand" backend @?= 0
            for_ ["runClusterStatusCall", "runRetainedClusterStatusCall"] $ \entry -> do
                status <- Expect.expectRight (SourceGuard.haskellDefinitionTokens entry backend)
                assertBool ("the read-only status entry shares the query: " <> entry) ("observeClusterStatus" `elem` status)
            query <- Expect.expectRight (SourceGuard.haskellDefinitionTokens "observeClusterStatus" backend)
            assertBool "the shared read-only status query reaches bounded ownership dispatch"
                (SourceGuard.haskellTokens "Owned.interpretClusterCommand" `isInfixOf` query)
            for_ ["runCaptured", "readProcessWithExitCode", "createProcess", "signalProcessGroup"] $ \name ->
                assertBool ("the domain interpreter delegates rather than duplicates " <> name) (name `notElem` tokens)
    ]

-- Imports and export lists are not invocation sites; every actual site must
-- name a literal tool covered by the selected declaration.
commandSiteTools :: String -> [String]
commandSiteTools source =
    [ tool
    | "hostCommand" : tool : _ <- tails (SourceGuard.haskellTokens source)
    , tool `notElem` [",", ")", "::"]
    ]

-- Cluster/*.hs is the driver-command boundary. Nested host-capacity foundations
-- retain their own platform tool declarations (for example df and sysctl).
directClusterModule :: String -> Bool
directClusterModule name =
    prefix `isPrefixOf` name
        && not (null suffix)
        && '.' `notElem` suffix
  where
    prefix = "HostBootstrap.Cluster."
    suffix = drop (length prefix) name
