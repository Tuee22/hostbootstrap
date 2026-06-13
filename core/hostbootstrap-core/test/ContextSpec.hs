{-# LANGUAGE OverloadedStrings #-}

module ContextSpec (tests) where

import Control.Exception (try)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import HostBootstrap.CLI (runHostBootstrapCLI)
import HostBootstrap.Context
import HostBootstrap.Harness (emptySuite)
import System.Directory (withCurrentDirectory)
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
      testCase "contextPathForExecutable uses the executable directory" $
        contextPathForExecutable ("/tmp/bin/demo") @?= "/tmp/bin/project-binary-context-config.dhall",
      testCase "readContextFile reports a missing file" $
        withSystemTempDirectory "hostbootstrap-context" $ \dir -> do
          let path = dir </> contextFileName
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
        parentChain vm @?= [ContextFrame HostOrchestrator "demo"]
        contextKind svc @?= ClusterService
        parentChain svc @?= [ContextFrame HostOrchestrator "demo", ContextFrame VMOrchestrator "demo"]
        commandAllowed svc ServiceCommand @?= True
        commandAllowed svc HostOrchestratorCommand @?= False,
      testCase "standaloneContainerContext is the Dockerfile bootstrap context" $ do
        let ctr = standaloneContainerContext "demo" "demo" "/workspace/demo" defaultResourceEnvelope
        contextKind ctr @?= VMProjectContainer
        parentChain ctr @?= []
        commandAllowed ctr CheckCodeCommand @?= True,
      testCase "writeContextFile writes Dhall that decodes back" $
        withSystemTempDirectory "hostbootstrap-context" $ \dir -> do
          let path = dir </> contextFileName
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
          let path = dir </> contextFileName
          result <- try (requireContextFile path testRequirement) :: IO (Either ExitCode BinaryContext)
          result @?= Left (ExitFailure 1),
      testCase "normal CLI commands fail fast when the sibling context is absent" $ do
        result <-
          try (withArgs ["check-code"] (runHostBootstrapCLI "definitely-missing-context" [] emptySuite)) ::
            IO (Either ExitCode ())
        result @?= Left (ExitFailure 1),
      testCase "the Dockerfile context shortcut runs before sibling context gating" $
        withSystemTempDirectory "hostbootstrap-context" $ \dir -> do
          let path = dir </> contextFileName
          withCurrentDirectory dir $
            withArgs ["--create-container-config", path] (runHostBootstrapCLI "demo" [] emptySuite)
          decoded <- decodeContextFile path
          decoded @?= standaloneContainerContext "demo" "demo" (T.pack dir) defaultResourceEnvelope
    ]

withContextFile :: String -> (FilePath -> IO a) -> IO a
withContextFile body action =
  withSystemTempDirectory "hostbootstrap-context" $ \dir -> do
    let path = dir </> contextFileName
    TIO.writeFile path (fromString body)
    action path

fromString :: String -> T.Text
fromString = T.pack
