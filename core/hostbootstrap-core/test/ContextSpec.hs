{-# LANGUAGE OverloadedStrings #-}

module ContextSpec (tests) where

import Control.Exception (finally, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import HostBootstrap.CLI (runHostBootstrapCLI)
import qualified HostBootstrap.Config.Schema as Schema
import HostBootstrap.Context
import HostBootstrap.Harness (emptySuite)
import System.Directory (removeFile)
import System.Environment (withArgs)
import System.Exit (ExitCode (ExitFailure))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

sampleContext :: BinaryContext
sampleContext =
  BinaryContext
    { project = "demo",
      binary = "demo",
      sourceRoot = "/workspace/demo",
      contextKind = VMProjectContainer,
      roleName = "vm-project-container",
      parentChain =
        [ ContextFrame {frameKind = HostOrchestrator, frameBinary = "demo"},
          ContextFrame {frameKind = VMOrchestrator, frameBinary = "demo"}
        ],
      capabilities = [DockerSocket, ContainerRuntime, KindNetwork],
      allowedCommandClasses = [TestWorkflowCommand, CheckCodeCommand, ConfigGenerationCommand],
      resourceEnvelope = ResourceEnvelope {cpu = 4, memory = "8GiB", storage = "20GiB"},
      childContextKinds = [ClusterService]
    }

testRequirement :: ContextRequirement
testRequirement =
  ContextRequirement
    { requiredProject = "demo",
      requiredBinary = "demo",
      requiredCommandClass = TestWorkflowCommand,
      requiredCapabilities = [DockerSocket, KindNetwork]
    }

tests :: TestTree
tests =
  testGroup
    "ContextSpec"
    [ testCase "rendered context decodes back to the same value" $ do
        decoded <- decodeContextText (renderContext sampleContext)
        decoded @?= sampleContext,
      testCase "projectConfigPathForExecutable uses the executable directory" $
        Schema.projectConfigPathForExecutable "demo" ("/tmp/bin/demo") @?= "/tmp/bin/demo.dhall",
      testCase "readContextFile reports a missing file" $
        withSystemTempDirectory "hostbootstrap-context" $ \dir -> do
          let path = dir </> "context.dhall"
          loaded <- readContextFile path
          loaded @?= Left (ContextMissing path),
      testCase "readContextFile reports a decode failure" $
        withContextFile "not a dhall record" $ \path -> do
          loaded <- readContextFile path
          case loaded of
            Left (ContextDecodeFailed failedPath msg) -> do
              failedPath @?= path
              assertBool "decode error names the bad input" (not (null msg))
            other -> assertFailure ("expected ContextDecodeFailed, got " ++ show other),
      testCase "validateContext accepts a matching command context" $
        validateContext testRequirement sampleContext @?= Right sampleContext,
      testCase "validateContext rejects a project mismatch" $
        validateContext testRequirement {requiredProject = "other"} sampleContext
          @?= Left (ContextProjectMismatch "other" "demo"),
      testCase "validateContext rejects a binary mismatch" $
        validateContext testRequirement {requiredBinary = "other"} sampleContext
          @?= Left (ContextBinaryMismatch "other" "demo"),
      testCase "validateContext rejects a command not allowed in this context" $
        validateContext testRequirement {requiredCommandClass = HostOrchestratorCommand} sampleContext
          @?= Left (ContextCommandNotAllowed HostOrchestratorCommand VMProjectContainer),
      testCase "validateContext rejects a missing capability" $
        validateContext testRequirement {requiredCapabilities = [KubernetesAPI]} sampleContext
          @?= Left (ContextCapabilityMissing KubernetesAPI),
      testCase "hostOrchestratorContext records host capabilities and child context rules" $ do
        let host =
              hostOrchestratorContext
                "demo"
                "demo"
                "/workspace/demo"
                (ResourceEnvelope 4 "8GiB" "20GiB")
        contextKind host @?= HostOrchestrator
        roleName host @?= "host-orchestrator"
        capabilities host @?= [HostTools, IncusProvider]
        childContextKinds host @?= [VMOrchestrator, VMProjectContainer, ClusterService, Daemon, OneShotJob, TestHarness],
      testCase "deriveContainerContext appends the parent frame and carries the envelope" $ do
        let host =
              hostOrchestratorContext
                "demo"
                "demo"
                "/workspace/demo"
                (ResourceEnvelope 4 "8GiB" "20GiB")
            ctr = deriveContainerContext host "/workspace/demo"
        contextKind ctr @?= VMProjectContainer
        roleName ctr @?= "vm-project-container"
        parentChain ctr @?= [ContextFrame HostOrchestrator "demo"]
        resourceEnvelope ctr @?= resourceEnvelope host
        commandAllowed ctr CheckCodeCommand @?= True,
      testCase "deriveVMContext and deriveServiceContext preserve identity and enforce narrower roles" $ do
        let host =
              hostOrchestratorContext
                "demo"
                "demo"
                "/workspace/demo"
                (ResourceEnvelope 4 "8GiB" "20GiB")
            vm = deriveVMContext host "/workspace/demo"
            svc = deriveServiceContext vm "/srv/demo"
        contextKind vm @?= VMOrchestrator
        roleName vm @?= "vm-orchestrator"
        parentChain vm @?= [ContextFrame HostOrchestrator "demo"]
        contextKind svc @?= ClusterService
        roleName svc @?= "cluster-service"
        parentChain svc @?= [ContextFrame HostOrchestrator "demo", ContextFrame VMOrchestrator "demo"]
        commandAllowed svc ServiceCommand @?= True
        commandAllowed svc HostOrchestratorCommand @?= False,
      testCase "standaloneContainerContext is the Dockerfile bootstrap context" $ do
        let ctr = standaloneContainerContext "demo" "demo" "/workspace/demo" defaultResourceEnvelope
        contextKind ctr @?= VMProjectContainer
        roleName ctr @?= "vm-project-container"
        parentChain ctr @?= []
        commandAllowed ctr CheckCodeCommand @?= True,
      testCase "writeContextFile writes Dhall that decodes back" $
        withSystemTempDirectory "hostbootstrap-context" $ \dir -> do
          let path = dir </> "context.dhall"
          writeContextFile path sampleContext
          decoded <- decodeContextFile path
          decoded @?= sampleContext,
      testCase "withValidatedContext does not run side effects when the gate fails" $ do
        ran <- newIORef False
        result <-
          withValidatedContext
            sampleContext
            testRequirement {requiredCommandClass = HostOrchestratorCommand}
            (writeIORef ran True)
        result @?= Left (ContextCommandNotAllowed HostOrchestratorCommand VMProjectContainer)
        readIORef ran >>= (@?= False),
      testCase "requireContextFile exits 1 on a missing context" $
        withSystemTempDirectory "hostbootstrap-context" $ \dir -> do
          let path = dir </> "context.dhall"
          result <- try (requireContextFile path testRequirement) :: IO (Either ExitCode BinaryContext)
          result @?= Left (ExitFailure 1),
      testCase "normal CLI commands fail fast when the sibling context is absent" $ do
        result <-
          try (withArgs ["check-code"] (runHostBootstrapCLI "definitely-missing-context" [] emptySuite)) ::
            IO (Either ExitCode ())
        result @?= Left (ExitFailure 1),
      testCase "normal CLI commands run when the sibling project config authorizes them" $ do
        let projectName = "demo-cli-context"
        path <- Schema.siblingProjectConfigPath projectName
        let cfg = Schema.defaultProjectConfig projectName "/workspace/demo" HostOrchestrator
        ( do
            Schema.writeProjectConfigFile path cfg
            result <-
              try (withArgs ["check-code"] (runHostBootstrapCLI (T.unpack projectName) [] emptySuite)) ::
                IO (Either ExitCode ())
            result @?= Right ()
          )
          `finally` removeFile path,
      testCase "config init writes a project-local config before sibling context gating" $
        withSystemTempDirectory "hostbootstrap-config-init" $ \dir -> do
          let path = dir </> "demo.dhall"
          withArgs
            [ "config",
              "init",
              "--role",
              "vm-project-container",
              "--output",
              path,
              "--source-root",
              "/workspace/demo",
              "--dockerfile",
              "demo/docker/Dockerfile",
              "--cpu",
              "6",
              "--memory",
              "10GiB",
              "--storage",
              "80GiB",
              "--ha-replicas",
              "3"
            ]
            (runHostBootstrapCLI "demo" [] emptySuite)
          decoded <- Schema.decodeProjectConfigFile path
          let Schema.ProjectConfig cfgDockerfile cfgResources cfgContext cfgDeploy = decoded
          cfgDockerfile @?= "demo/docker/Dockerfile"
          cfgResources @?= Schema.Resources 6 "10GiB" "80GiB"
          cfgDeploy @?= Schema.DeployConfig 3
          contextKind cfgContext @?= VMProjectContainer
          sourceRoot cfgContext @?= "/workspace/demo"
    ]

withContextFile :: String -> (FilePath -> IO a) -> IO a
withContextFile body action =
  withSystemTempDirectory "hostbootstrap-context" $ \dir -> do
    let path = dir </> "context.dhall"
    TIO.writeFile path (fromString body)
    action path

fromString :: String -> T.Text
fromString = T.pack
