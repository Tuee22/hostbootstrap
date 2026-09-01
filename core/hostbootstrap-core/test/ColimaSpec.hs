{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ColimaSpec (tests, runShippedOwnerProbe) where

import Control.Concurrent (threadDelay)
import Control.Exception (finally)
import Control.Monad (unless)
import Data.Bifunctor (first)
import qualified Data.ByteString as ByteString
import Data.List (isInfixOf, isPrefixOf)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Cluster.Budget
import HostBootstrap.Cluster.Cordon (mkResourceBudget)
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Ensure.Colima
import HostBootstrap.Ensure.Colima.Backend.Stage
import HostBootstrap.Ensure.Colima.Backend.Runner (BackendNamespace (..), BoundedToolResult (..), runShippedCommand)
import HostBootstrap.Ensure.Colima.Backend.Resolver.Testing
import HostBootstrap.Ensure.Colima.Command
import HostBootstrap.Ensure.Colima.Report
  ( ColimaReportFault (..),
    LimaDisk (..),
    classifyColimaListing,
    classifyDockerContextListing,
    classifyDockerContextInspect,
    classifyLimaDiskListing,
    classifyMachineIdentity,
    dockerContextFingerprint,
  )
import HostBootstrap.Ensure.Colima.Ownership
  ( ColimaNativeObservationFault (ColimaNativeCommandUnavailable),
    ColimaArtifactObservation (..),
    ColimaManagedObservation (..),
    ColimaManagedOutcome (..),
    ColimaProfileMutationFault (..),
    ColimaStartedObservation (..),
    acquireColimaDirectory,
    acquireManagedColimaProfileWith,
    bindColimaCreationIdentities,
    cleanupManagedColimaProfileWith,
    observeColimaArtifactsWith,
    runManagedColimaDockerWith,
    colimaHomeKey,
    colimaDiskKey,
    colimaProfileKey,
    colimaManifestKey,
    ensureColimaDirectory,
    observeColimaProfiles,
    prepareColimaNamespaces,
    publishPreparedColimaManifest,
    readColimaStage,
    releaseColimaDirectory,
    startPreparedColimaProfile,
    startPreparedColimaProfileWith,
    settleManagedColimaProfile,
    writeColimaStage,
    withColimaOwnershipEntry,
  )
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.Effect.Vocabulary
  ( EffectTarget (ToolTarget),
    HostCommand (commandArguments, commandTarget),
  )
import HostBootstrap.HostTool (HostTool (Colima, Docker, Lima))
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Lift (localContext)
import HostBootstrap.ProjectPlan
  ( ClusterResource,
    PlannedResource,
    PlannedResourceKind (ClusterResourceKind, ProviderResourceKind),
    ProjectPlan,
    ProviderResource,
    forward,
    plannedStepOperationKey,
    plannedResourceKey,
    renderSnapshot,
    stablePlanSnapshotDigest,
    topology,
    withPlannedResourceOfKind,
  )
import HostBootstrap.Reconcile (ReconcileError (Conflict), withObservedProjectResource)
import HostBootstrap.Protected
  ( Expectation (ExpectAbsent),
    readProtectedRecord,
  )
import HostBootstrap.Ownership.Object (mkKernelObjectIdentity)
import HostBootstrap.Ownership.Manifest
  ( mkOwnershipManifest,
    mutableManifestEntry,
    ownershipManifestDigest,
    parseOwnershipManifest,
    renderOwnershipManifest,
  )
import PrepareFixture (withSuccessorGate)
import SourceGuard (repoRelativePath)
import HostBootstrap.Step
  ( StepFrame (StepFrame),
    StepObservation (StepChanged),
    StepPlan,
    deployKindStep,
    deployVMStep,
    descendsVia,
    mkStepPlan,
  )
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import System.Directory
  ( Permissions (executable),
    createDirectoryIfMissing,
    createFileLink,
    doesDirectoryExist,
    doesFileExist,
    findExecutable,
    getCurrentDirectory,
    getPermissions,
    removePathForcibly,
    removeFile,
    renameDirectory,
    setPermissions,
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.Info (os)
import System.IO.Temp (withSystemTempDirectory)
#if !defined(mingw32_HOST_OS)
import System.Posix.Files (setFileMode)
#endif
import System.Process (createProcess, proc, readProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

gib :: Integer
gib = 1024 ^ (3 :: Integer)

profileName :: String
profileName = "h-012345"

ownerToken :: String
ownerToken =
  "v2-68-70-72-66-63-64-1-65-74-75-76"

acquireInvocation :: String
acquireInvocation = replicate 64 'a'

cleanupInvocation :: String
cleanupInvocation = replicate 64 'b'

exactEnvelope :: Context.ResourceEnvelope
exactEnvelope = Context.ResourceEnvelope 8 "16GiB" "100GiB"

canonicalStartArgs :: [String]
canonicalStartArgs =
  [ "start",
    "--profile",
    profileName,
    "--runtime",
    "docker",
    "--activate=false",
    "--template=false",
    "--ssh-config=false",
    "--mount",
    "none",
    "--kubernetes=false",
    "--network-address=false",
    "--mount-inotify=false",
    "--cpus",
    "8",
    "--memory",
    "16",
    "--root-disk",
    "20",
    "--disk",
    "80"
  ]

tests :: TestTree
tests =
  testGroup
    "ColimaSpec"
    [ testCase "the direct driver describes every tool effect without running it" $ onOwnershipHost $ do
        let view command = (commandTarget command, commandArguments command)
        map view
          [ listColimaProfilesCommand,
            startColimaProfileCommand canonicalStartArgs,
            deleteColimaProfileCommand profileName,
            readColimaMachineIdCommand profileName,
            listLimaDisksCommand,
            inspectDockerContextCommand ("colima-" ++ profileName),
            listDockerContextsCommand,
            removeDockerContextCommand ("colima-" ++ profileName)
          ]
          @?= [ (ToolTarget Colima, ["list", "--json"]),
                (ToolTarget Colima, canonicalStartArgs),
                (ToolTarget Colima, ["delete", "--profile", profileName, "--force", "--data"]),
                (ToolTarget Colima, ["ssh", "--profile", profileName, "--", "cat", "/etc/machine-id"]),
                (ToolTarget Lima, ["disk", "list", "--json"]),
                (ToolTarget Docker, ["context", "inspect", "colima-" ++ profileName]),
                (ToolTarget Docker, ["context", "ls", "--format", "{{json .}}"]),
                (ToolTarget Docker, ["context", "rm", "--force", "colima-" ++ profileName])
              ]
        fmap view (routedDockerCommand profileName ["ps", "--all"])
          @?= Right (ToolTarget Docker, ["--context", "colima-" ++ profileName, "ps", "--all"])
        routedDockerCommand profileName ["ps", "--context", "foreign"]
          @?= Left "Docker command may not override the owned Colima route"
        let listing = CapturedRun ExitSuccess "{\"name\":\"h-a\",\"status\":\"Running\",\"cpus\":8,\"memory\":17179869184,\"disk\":85899345920,\"runtime\":\"docker\"}\n" ""
        fmap (map ciName) (classifyColimaListing listing) @?= Right ["h-a"]
        classifyColimaListing listing {capturedStdout = capturedStdout listing ++ "\n"}
          @?= Left ColimaReportFraming
        classifyColimaListing listing {capturedStderr = "warning"}
          @?= Left ColimaToolStderr
        fmap fst (classifyMachineIdentity (CapturedRun ExitSuccess (replicate 32 'a' ++ "\n") ""))
          @?= Right (replicate 32 'a')
        classifyMachineIdentity (CapturedRun ExitSuccess (replicate 32 'A' ++ "\n") "")
          @?= Left ColimaReportShape
        fmap (map limaDiskName) (classifyLimaDiskListing (CapturedRun ExitSuccess "{\"name\":\"colima-h-a\",\"dir\":\"/owned/disk\",\"instance\":\"colima-h-a\",\"instanceDir\":\"/owned/instance\",\"format\":\"raw\",\"mountPoint\":\"\",\"size\":80}\n" ""))
          @?= Right ["colima-h-a"]
        classifyDockerContextListing (CapturedRun ExitSuccess "{\"Name\":\"colima-h-a\"}\n{\"Name\":\"colima-h-a\"}\n" "")
          @?= Left ColimaReportDuplicate
        let inspectA = classifyDockerContextInspect (CapturedRun ExitSuccess "[{\"Name\":\"colima-h-a\",\"Endpoints\":{\"docker\":{\"Host\":\"unix:///owned.sock\"}}}]\n" "")
            inspectB = classifyDockerContextInspect (CapturedRun ExitSuccess "[ { \"Endpoints\" : { \"docker\" : { \"Host\" : \"unix:///owned.sock\" } }, \"Name\" : \"colima-h-a\" } ]" "")
        case (mkKernelObjectIdentity 1 2, inspectA, inspectB) of
          (Right identity, Right valueA, Right valueB) -> dockerContextFingerprint identity valueA @?= dockerContextFingerprint identity valueB
          other -> assertFailure ("expected canonical Docker context evidence, got " ++ show other)
        case (mkKernelObjectIdentity 1 2, mkKernelObjectIdentity 3 4) of
          (Right firstIdentity, Right secondIdentity) -> do
            let firstEntry = mutableManifestEntry "profile/colima.yaml" firstIdentity 0o600
                secondEntry = mutableManifestEntry "_lima/profile/diffdisk" secondIdentity 0o600
                manifest = sequence [firstEntry, secondEntry] >>= mkOwnershipManifest
                reordered = sequence [secondEntry, firstEntry] >>= mkOwnershipManifest
            fmap ownershipManifestDigest manifest @?= fmap ownershipManifestDigest reordered
            fmap (parseOwnershipManifest . renderOwnershipManifest) manifest @?= fmap Right manifest
            case mutableManifestEntry "../foreign" firstIdentity 0o600 >>= \value -> mkOwnershipManifest [value] of
              Left _ -> pure ()
              Right _ -> assertFailure "a traversal path entered the shared ownership manifest"
          other -> assertFailure ("expected shared manifest identities, got " ++ show other)
        withSystemTempDirectory "hostbootstrap-colima-authority" $ \root -> do
          case mkColimaStageRecord ColimaReserved ownerToken (replicate 64 'c') acquireInvocation of
            Left failure -> assertFailure failure
            Right stageRecord -> do
              owned <-
                withColimaOwnershipEntry root profileName $ \session keys ->
                  Right <$> do
                    written <- writeColimaStage session keys ExpectAbsent stageRecord
                    case written of
                      Left failure -> pure (Left failure)
                      Right _ -> fmap (fmap (fmap (colimaStageRecordStage . snd))) (readColimaStage session keys)
              owned @?= Right (Right (Just ColimaReserved))
          let home = root </> "owned-home"
          acquired <-
            withColimaOwnershipEntry root profileName $ \session keys ->
              Right <$> acquireColimaDirectory session (colimaHomeKey keys) home
          case acquired of
            Right (Right _) -> do
              doesDirectoryExist home >>= (@?= True)
              reentered <-
                withColimaOwnershipEntry root profileName $ \session keys ->
                  Right <$> ensureColimaDirectory session (colimaHomeKey keys) home
              case reentered of
                Right (Right _) -> pure ()
                other -> assertFailure ("expected exact shared-clause re-entry, got " ++ show other)
              released <-
                withColimaOwnershipEntry root profileName $ \session keys ->
                  Right <$> releaseColimaDirectory session (colimaHomeKey keys) home
              released @?= Right (Right ())
              doesDirectoryExist home >>= (@?= False)
            other -> assertFailure ("expected shared-clause directory acquisition, got " ++ show other)
        refused <- withColimaOwnershipEntry "/unused" "default" (\_ _ -> pure (Right ()))
        refused @?= Left "invalid direct-Colima profile"
        withSystemTempDirectory "hostbootstrap-colima-observe" $ \root -> do
          observed <-
            observeColimaProfiles
              HostConfig {hcSubstrate = Substrate LinuxCpu Amd64, hcToolPaths = Map.empty}
              root
              profileName
          case observed of
            Left (ColimaNativeCommandUnavailable _) -> pure ()
            other -> assertFailure ("expected a typed unresolved-command refusal, got " ++ show other)
        withSystemTempDirectory "hostbootstrap-colima-prepare" $ \root -> do
          let home = root </> "isolated-home"
              context = root </> "docker-config"
              instanceDirectory = home </> "_lima" </> ("colima-" ++ profileName)
              diskDirectory = home </> "_lima" </> "_disks" </> ("colima-" ++ profileName)
              diskPath = diskDirectory </> "datadisk"
              prepare = prepareColimaNamespaces root profileName ownerToken (replicate 64 'c') acquireInvocation home context
          prepare >>= (@?= Right ())
          prepare >>= (@?= Right ())
          doesDirectoryExist home >>= (@?= True)
          doesDirectoryExist context >>= (@?= True)
          stage <-
            withColimaOwnershipEntry root profileName $ \session keys ->
              Right <$> readColimaStage session keys
          fmap (fmap (fmap (colimaStageRecordStage . snd))) stage @?= Right (Right (Just ColimaPrepared))
          mutation <-
            startPreparedColimaProfile
              HostConfig {hcSubstrate = Substrate LinuxCpu Amd64, hcToolPaths = Map.empty}
              root
              profileName
              ownerToken
              (replicate 64 'c')
              acquireInvocation
              home
              context
              diskPath
              8
              (16 * gib)
              (80 * gib)
              canonicalStartArgs
          case mutation of
            Left (ColimaMutationCommandUnavailable _) -> pure ()
            other -> assertFailure ("expected native start to retain Prepared on unavailable command, got " ++ show other)
          scripted <-
            newIORef
              [ Right (CapturedRun ExitSuccess "" ""),
                Right (CapturedRun ExitSuccess "started\n" ""),
                Right (CapturedRun ExitSuccess ("{\"name\":\"" ++ profileName ++ "\",\"status\":\"Running\",\"cpus\":8,\"memory\":" ++ show (16 * gib) ++ ",\"disk\":" ++ show (80 * gib) ++ ",\"runtime\":\"docker\"}\n") ""),
                Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") "")
              ]
          let interpret _ =
                atomicModifyIORef' scripted $ \outcomes -> case outcomes of
                  outcome : remaining -> (remaining, outcome)
                  [] -> ([], Left "unexpected command")
          started <-
            startPreparedColimaProfileWith
              interpret
              root
              profileName
              ownerToken
              (replicate 64 'c')
              acquireInvocation
              home
              context
              diskPath
              8
              (16 * gib)
              (80 * gib)
              canonicalStartArgs
          startedObservation <- case started of
            Right observation -> do
              startedMachineIdentity observation @?= replicate 32 'd'
              pure observation
            other -> assertFailure ("expected value-driven native start settlement, got " ++ show other)
          createDirectoryIfMissing True diskDirectory
          writeFile diskPath "owned disk"
          artifactScript <- newIORef (0 :: Int)
          let artifactInterpret command = do
                step <- atomicModifyIORef' artifactScript (\current -> (current + 1, current))
                case (step, commandArguments command) of
                  (0, ["disk", "list", "--json"]) ->
                    pure (Right (CapturedRun ExitSuccess ("{\"name\":\"colima-" ++ profileName ++ "\",\"dir\":" ++ show diskDirectory ++ ",\"instance\":\"colima-" ++ profileName ++ "\",\"instanceDir\":" ++ show instanceDirectory ++ ",\"format\":\"raw\",\"mountPoint\":\"\",\"size\":" ++ show (80 * gib) ++ "}\n") ""))
                  (1, ["context", "inspect", _]) -> pure (Right (CapturedRun ExitSuccess ("[{\"Name\":\"colima-" ++ profileName ++ "\",\"Endpoints\":{\"docker\":{\"Host\":\"unix:///owned.sock\"}}}]\n") ""))
                  _ -> pure (Left "unexpected artifact observation command")
          artifacts <-
            observeColimaArtifactsWith artifactInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation home context (80 * gib)
          observedArtifacts <- case artifacts of
            Right observed -> do
              artifactDiskPath observed @?= diskPath
              pure observed
            other -> assertFailure ("expected authoritative artifact observation, got " ++ show other)
          publishPreparedColimaManifest root profileName ownerToken (replicate 64 'c') acquireInvocation (artifactOwnershipManifest observedArtifacts)
            >>= (@?= Right ())
          bound <-
            bindColimaCreationIdentities
              root
              profileName
              ownerToken
              (replicate 64 'c')
              acquireInvocation
              (replicate 32 'd')
              diskPath
          case bound of
            Right _ -> pure ()
            other -> assertFailure ("expected shared profile/disk identity binding, got " ++ show other)
          settled <-
            settleManagedColimaProfile
              root
              profileName
              ownerToken
              (replicate 64 'c')
              acquireInvocation
              (startedMachineIdentity startedObservation)
              (startedMachineEpoch startedObservation)
              (replicate 64 'e')
              8
              (16 * gib)
              (80 * gib)
              (20 * gib)
              home
              context
          settled @?= Right ()
          origins <-
            withColimaOwnershipEntry root profileName $ \session keys -> do
              profileOrigin <- readProtectedRecord session (colimaProfileKey keys)
              diskOrigin <- readProtectedRecord session (colimaDiskKey keys)
              pure ((,) <$> profileOrigin <*> diskOrigin)
          fmap (\(profileOrigin, diskOrigin) -> (isJust profileOrigin, isJust diskOrigin)) origins
            @?= Right (True, True)
          stageAfterSettlement <-
            withColimaOwnershipEntry root profileName $ \session keys ->
              Right <$> readColimaStage session keys
          fmap (fmap (fmap (colimaStageRecordStage . snd))) stageAfterSettlement @?= Right (Right (Just ColimaManaged))
          let driftPath = context </> "foreign.json"
          writeFile driftPath "{}\n"
          drifted <-
            runManagedColimaDockerWith (\_ -> pure (Left "a drifted manifest must run no command")) root profileName ownerToken (replicate 64 'c') acquireInvocation home context ["ps"]
          case drifted of
            Left (ColimaMutationOwnershipRefused _) -> pure ()
            other -> assertFailure ("expected manifest drift refusal before Docker, got " ++ show other)
          removeFile driftPath
          dockerScript <- newIORef (0 :: Int)
          let runningListing = "{\"name\":\"" ++ profileName ++ "\",\"status\":\"Running\",\"cpus\":8,\"memory\":" ++ show (16 * gib) ++ ",\"disk\":" ++ show (80 * gib) ++ ",\"runtime\":\"docker\"}\n"
              dockerInterpret command = do
                step <- atomicModifyIORef' dockerScript (\current -> (current + 1, current))
                case (step, commandArguments command) of
                  (0, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                  (1, ["ssh", "--profile", _, "--", "cat", "/etc/machine-id"]) -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                  (2, ["--context", contextName, "ps", "--all"])
                    | contextName == "colima-" ++ profileName -> pure (Right (CapturedRun ExitSuccess "container-row\n" ""))
                  (3, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                  (4, ["ssh", "--profile", _, "--", "cat", "/etc/machine-id"]) -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                  _ -> pure (Left "unexpected Docker transaction command")
          dockerRun <-
            runManagedColimaDockerWith dockerInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation home context ["ps", "--all"]
          fmap capturedStdout dockerRun @?= Right "container-row\n"
          changedScript <- newIORef (0 :: Int)
          let changedInterpret command = do
                step <- atomicModifyIORef' changedScript (\current -> (current + 1, current))
                case (step, commandArguments command) of
                  (0, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                  (1, ["ssh", "--profile", _, "--", "cat", "/etc/machine-id"]) -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                  (2, ["--context", _, "version"]) -> pure (Right (CapturedRun ExitSuccess "version\n" ""))
                  (3, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                  (4, ["ssh", "--profile", _, "--", "cat", "/etc/machine-id"]) -> pure (Right (CapturedRun ExitSuccess (replicate 32 'f' ++ "\n") ""))
                  _ -> pure (Left "unexpected replacement command")
          replaced <-
            runManagedColimaDockerWith changedInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation home context ["version"]
          case replaced of
            Left (ColimaMutationProfileConflict "Docker profile identity changed") -> pure ()
            other -> assertFailure ("expected post-command identity refusal, got " ++ show other)
          cleanupScript <- newIORef (0 :: Int)
          let cleanupInterpret command = do
                step <- atomicModifyIORef' cleanupScript (\current -> (current + 1, current))
                case (step, commandArguments command) of
                  (0, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                  (1, ["ssh", "--profile", _, "--", "cat", "/etc/machine-id"]) -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                  (2, ["delete", "--profile", _, "--force", "--data"]) -> do
                    removePathForcibly (home </> "_lima")
                    pure (Right (CapturedRun ExitSuccess "deleted\n" ""))
                  (3, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess "" ""))
                  (4, ["context", "rm", "--force", _]) -> pure (Right (CapturedRun ExitSuccess "" ""))
                  _ -> pure (Left "unexpected cleanup command")
          cleaned <-
            cleanupManagedColimaProfileWith
              cleanupInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation cleanupInvocation home context diskPath
          cleaned @?= Right ()
          doesDirectoryExist home >>= (@?= False)
          doesDirectoryExist context >>= (@?= False)
          cleanupState <-
            withColimaOwnershipEntry root profileName $ \session keys -> do
              profileOrigin <- readProtectedRecord session (colimaProfileKey keys)
              diskOrigin <- readProtectedRecord session (colimaDiskKey keys)
              finalStage <- readColimaStage session keys
              pure (Right (profileOrigin, diskOrigin, finalStage))
          fmap (\(profileOrigin, diskOrigin, finalStage) -> (fmap isJust profileOrigin, fmap isJust diskOrigin, fmap (fmap (colimaStageRecordStage . snd)) finalStage)) cleanupState
            @?= Right (Right False, Right False, Right (Just ColimaReleased))
        withSystemTempDirectory "hostbootstrap-colima-one-entry" $ \root -> do
          let home = root </> "isolated-home"
              context = root </> "docker-config"
              instanceDirectory = home </> "_lima" </> ("colima-" ++ profileName)
              diskDirectory = home </> "_lima" </> "_disks" </> ("colima-" ++ profileName)
              diskPath = diskDirectory </> "datadisk"
              runningListing = "{\"name\":\"" ++ profileName ++ "\",\"status\":\"Running\",\"cpus\":8,\"memory\":" ++ show (16 * gib) ++ ",\"disk\":" ++ show (80 * gib) ++ ",\"runtime\":\"docker\"}\n"
          oneEntryScript <- newIORef (0 :: Int)
          let oneEntryInterpret command = do
                step <- atomicModifyIORef' oneEntryScript (\current -> (current + 1, current))
                case (step, commandArguments command) of
                  (0, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess "" ""))
                  (1, "start" : _) -> do
                    createDirectoryIfMissing True diskDirectory
                    createDirectoryIfMissing True instanceDirectory
                    writeFile diskPath "owned disk"
                    writeFile (context </> "meta.json") "{}\n"
                    pure (Right (CapturedRun ExitSuccess "started\n" ""))
                  (2, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                  (3, ["ssh", "--profile", _, "--", "cat", "/etc/machine-id"]) -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                  (4, ["disk", "list", "--json"]) -> pure (Right (CapturedRun ExitSuccess ("{\"name\":\"colima-" ++ profileName ++ "\",\"dir\":\"" ++ diskDirectory ++ "\",\"instance\":\"colima-" ++ profileName ++ "\",\"instanceDir\":\"" ++ instanceDirectory ++ "\",\"format\":\"raw\",\"mountPoint\":\"\",\"size\":" ++ show (80 * gib) ++ "}\n") ""))
                  (5, ["context", "inspect", _]) -> pure (Right (CapturedRun ExitSuccess ("[{\"Name\":\"colima-" ++ profileName ++ "\"}]\n") ""))
                  (6, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                  (7, ["ssh", "--profile", _, "--", "cat", "/etc/machine-id"]) -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                  (8, ["disk", "list", "--json"]) -> pure (Right (CapturedRun ExitSuccess ("{\"name\":\"colima-" ++ profileName ++ "\",\"dir\":\"" ++ diskDirectory ++ "\",\"instance\":\"colima-" ++ profileName ++ "\",\"instanceDir\":\"" ++ instanceDirectory ++ "\",\"format\":\"raw\",\"mountPoint\":\"\",\"size\":" ++ show (80 * gib) ++ "}\n") ""))
                  (9, ["context", "inspect", _]) -> pure (Right (CapturedRun ExitSuccess ("[{\"Name\":\"colima-" ++ profileName ++ "\"}]\n") ""))
                  _ -> pure (Left "unexpected one-entry acquisition command")
          acquired <-
            acquireManagedColimaProfileWith oneEntryInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation home context 8 (16 * gib) (80 * gib) (20 * gib) canonicalStartArgs
          case acquired of
            Right (ColimaManagedApplied managedObservation) -> startedMachineIdentity (managedStartObservation managedObservation) @?= replicate 32 'd'
            other -> assertFailure ("expected one-entry native Managed acquisition, got " ++ show other)
          repeated <-
            acquireManagedColimaProfileWith oneEntryInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation home context 8 (16 * gib) (80 * gib) (20 * gib) canonicalStartArgs
          case repeated of
            Right (ColimaManagedAlreadyExact managedObservation) -> startedMachineIdentity (managedStartObservation managedObservation) @?= replicate 32 'd'
            other -> assertFailure ("expected exact one-entry native acquisition, got " ++ show other)
          retained <-
            withColimaOwnershipEntry root profileName $ \session keys -> do
              stage <- readColimaStage session keys
              manifest <- readProtectedRecord session (colimaManifestKey keys)
              pure (Right (stage, manifest))
          fmap (\(stage, manifest) -> (fmap (fmap (colimaStageRecordStage . snd)) stage, fmap isJust manifest)) retained
            @?= Right (Right (Just ColimaManaged), Right True)
        colimaCommandTools @?= [Colima, Docker, Lima],
      testCase "the shipped command transaction kills its group on hard parent death" $
        onOwnershipHost $ withSystemTempDirectory "hostbootstrap-colima-shipped-death" $ \directory -> do
          python <- requireExecutable "python3" =<< findExecutable "python3"
          self <- getExecutablePath
          let pidPath = directory </> "child.pid"
          (_, _, _, ownerProcess) <-
            createProcess (proc self ["--hostbootstrap-colima-shipped-owner-probe", directory, pidPath, python])
          waitForPath pidPath
          childPid <- strictReadFile pidPath
          terminateProcess ownerProcess
          _ <- waitForProcess ownerProcess
          waitForPidGone python childPid,
      testCase "the Colima backend admits only native shipped effects" $ do
        current <- getCurrentDirectory
        root <- findRepoRoot current >>= maybe (assertFailure "could not find repository root") pure
        let backend = root </> "core" </> "hostbootstrap-core" </> "internal" </> "colima-backend" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Backend"
        doesDirectoryExist (backend </> "Program") >>= (@?= False)
        doesFileExist (backend </> "Resolver" </> "Program.hs") >>= (@?= False)
        doesFileExist (backend </> "Internal.hs") >>= (@?= False)
        source <- strictReadFile (root </> "core" </> "hostbootstrap-core" </> "test" </> "ColimaSpec.hs")
        mapM_
          (\forbidden -> assertBool ("removed Colima stand-in returned: " ++ forbidden) (not (forbidden `isInfixOf` source)))
          [ "fake" ++ "Colima" ++ "Program",
            "fake" ++ "Docker" ++ "Program",
            "fake" ++ "Lima" ++ "Program",
            "Acquire" ++ "Backend" ++ "CrashPoint",
            "Cleanup" ++ "Backend" ++ "CrashPoint"
          ],
      testCase "the public exact consumer derives a fixed opaque provider profile" $ do
        result <-
          withPreparedTestCall $ \expectedProject call ->
            (Text.unpack expectedProject, preparedColimaProfileName call)
        case result of
          Left failure -> assertFailure failure
          Right (project, profile) -> do
            assertBool "the provider profile is not the caller-visible project name" (profile /= project)
            assertBool "the provider profile is a fixed lowercase local label" (isPrefixOf "h-" profile && length profile == 8),
      testCase "the shared default profile is outside the exact boundary" $
        assertBool
          "default must never become project authority"
          (not (validColimaProjectProfileName "default")),
      testCase "the opt-in native exact-plan lane acquires, refuses conflict, and cleans up without activating default" $ do
        enabled <- lookupEnv "HOSTBOOTSTRAP_COLIMA_LIVE"
        case enabled of
          Just "1" -> runNativeColimaAcceptance
          _ -> pure (),
      testGroup
        "trusted resolver"
        [ testCase "the native fixture observer and strict facade settle one closed ready toolchain" $
            onOwnershipHost $ withResolverHarness "ready" $ \harness -> do
              execution <- executeResolverFixture harness
              (output, protocol) <- requireReadyResolver harness execution
              case protocol of
                ResolverProtocolReadyView
                  (ResolverToolView pythonPath pythonDevice pythonInode)
                  (ResolverToolView colimaPath _ _)
                  (ResolverToolView dockerPath _ _)
                  (ResolverToolView limaPath _ _)
                  helperPath
                  helperFingerprint -> do
                    let layout = resolverHarnessLayout harness
                    pythonPath @?= resolverFixturePython layout
                    colimaPath @?= resolverFixtureColimaTarget layout
                    dockerPath @?= resolverFixtureDockerTarget layout
                    limaPath @?= resolverFixtureLimaTarget layout
                    assertBool "the ready helper path is closed and nonempty" (not (null helperPath))
                    assertBool "helper identities contribute a canonical fingerprint" (not (null helperFingerprint))
                    case
                        settleResolverFixtureExecutionView
                          (resolverFixtureRoot layout)
                          (resolverFixtureHome layout)
                          pythonDevice
                          pythonInode
                          (ResolverExecutionCompleted ExitSuccess output "")
                      of
                        ResolverSettlementReady settledPython settledColima settledDocker settledLima settledPath fingerprint -> do
                          settledPython @?= pythonPath
                          settledColima @?= colimaPath
                          settledDocker @?= dockerPath
                          settledLima @?= limaPath
                          settledPath @?= helperPath
                          assertBool "the complete toolchain has one deterministic fingerprint" (not (null fingerprint))
                        other -> assertFailure ("expected ready resolver settlement, got " ++ show other)
                other -> assertFailure ("expected ready resolver protocol, got " ++ show other),
          testCase "the resolver rejects malformed, decorated, truncated, and cross-branch reports" $
            onOwnershipHost $ withResolverHarness "protocol" $ \harness -> do
              execution <- executeResolverFixture harness
              (output, _protocol) <- requireReadyResolver harness execution
              let malformed =
                    [ "",
                      init output,
                      "noise\n" ++ output,
                      output ++ "noise\n",
                      map (\character -> if character == '\n' then '\r' else character) output,
                      takeWhile (/= '\t') output ++ "\n",
                      "MISSING_COLIMA" ++ dropWhile (/= '\t') output,
                      init output ++ "\textra\n"
                    ]
              mapM_ (assertResolverRejected (resolverFixtureRoot (resolverHarnessLayout harness))) malformed
              assertResolverRejected (resolverFixtureRoot (resolverHarnessLayout harness)) (output ++ output),
          testCase "missing Colima retains only the trusted bounded Brew install route" $
            onOwnershipHost $ withResolverHarness "missing" $ \harness -> do
              let layout = resolverHarnessLayout harness
              removeFile (resolverFixtureColimaAlias layout)
              execution <- executeResolverFixture harness
              case execution of
                BoundedToolCompleted ExitSuccess output "" ->
                  case parseResolverFixtureProtocolView (resolverFixtureRoot layout) output of
                    Right
                      protocol@(ResolverProtocolMissingColimaView (ResolverToolView _ pythonDevice pythonInode) (ResolverToolView brewPath _ _) helperPath helperFingerprint) -> do
                        brewPath @?= resolverFixtureBrew layout
                        assertBool "install helper path is closed" (not (null helperPath))
                        assertBool "install helper identities are bound" (not (null helperFingerprint))
                        settleResolverFixtureExecutionView
                          (resolverFixtureRoot layout)
                          (resolverFixtureHome layout)
                          pythonDevice
                          pythonInode
                          (ResolverExecutionCompleted ExitSuccess output "")
                          @?= ResolverSettlementMissingColima brewPath helperPath
                        assertBool "the missing branch carries no ready Colima tool" (not (isReadyProtocol protocol))
                    other -> assertFailure ("expected missing-Colima report, got " ++ show other)
                other -> assertFailure ("expected completed missing-Colima resolver, got " ++ show other),
          testCase "the trusted install kernel revalidates, installs, and rediscovers in one closed order" $
            onOwnershipHost $ withResolverHarness "install" $ \harness -> do
              let layout = resolverHarnessLayout harness
              readyExecution <- executeResolverFixture harness
              (readyOutput, _readyProtocol) <- requireReadyResolver harness readyExecution
              removeFile (resolverFixtureColimaAlias layout)
              missingExecution <- executeResolverFixture harness
              (missingOutput, pythonDevice, pythonInode) <-
                case missingExecution of
                  BoundedToolCompleted ExitSuccess output "" ->
                    case parseResolverFixtureProtocolView (resolverFixtureRoot layout) output of
                      Right (ResolverProtocolMissingColimaView (ResolverToolView _ device inode) _ _ _) ->
                        pure (output, device, inode)
                      other -> assertFailure ("expected a strict missing-Colima install input, got " ++ show other)
                  other -> assertFailure ("expected completed missing-Colima resolution, got " ++ show other)
              createFileLink (resolverFixtureColimaTarget layout) (resolverFixtureColimaAlias layout)
              let runScenario revalidation installExecution rediscoveryExecution =
                    runResolverInstallScenario
                      (resolverFixtureRoot layout)
                      (resolverFixtureHome layout)
                      pythonDevice
                      pythonInode
                      missingOutput
                      revalidation
                      installExecution
                      rediscoveryExecution
                  completed = ResolverExecutionCompleted ExitSuccess "" ""
              installed <-
                runScenario
                  (Right ())
                  completed
                  (ResolverExecutionCompleted ExitSuccess readyOutput "")
              case resolverInstallOutcome installed of
                ResolverInstallReadyView fingerprint ->
                  assertBool "rediscovery retained the complete ready-toolchain fingerprint" (not (null fingerprint))
                other -> assertFailure ("expected installed ready toolchain, got " ++ show other)
              resolverInstallTrace installed @?= ["revalidate", "install", "rediscover"]
              brewChanged <- runScenario (Left "brew-drift") completed ResolverExecutionTimedOut
              brewChanged
                @?= ResolverInstallScenarioView
                  (ResolverInstallBrewChangedView "brew-drift")
                  ["revalidate"]
              exitFailed <-
                runScenario
                  (Right ())
                  (ResolverExecutionCompleted (ExitFailure 9) "" "brew-error")
                  ResolverExecutionTimedOut
              exitFailed
                @?= ResolverInstallScenarioView
                  (ResolverInstallExitFailureView (ExitFailure 9) "brew-error")
                  ["revalidate", "install"]
              timedOut <- runScenario (Right ()) ResolverExecutionTimedOut completed
              timedOut
                @?= ResolverInstallScenarioView
                  ResolverInstallTimedOutView
                  ["revalidate", "install"]
              executionFailed <- runScenario (Right ()) (ResolverExecutionFailed "launch") completed
              executionFailed
                @?= ResolverInstallScenarioView
                  (ResolverInstallExecutionFailedView "launch")
                  ["revalidate", "install"]
              stillMissing <-
                runScenario
                  (Right ())
                  completed
                  (ResolverExecutionCompleted ExitSuccess missingOutput "")
              stillMissing
                @?= ResolverInstallScenarioView
                  ResolverInstallStillMissingView
                  ["revalidate", "install", "rediscover"]
              unsupported <-
                runScenario
                  (Right ())
                  completed
                  (ResolverExecutionCompleted ExitSuccess "UNSUPPORTED\trediscovery-layout\n" "")
              unsupported
                @?= ResolverInstallScenarioView
                  (ResolverInstallUnsupportedView "rediscovery-layout")
                  ["revalidate", "install", "rediscover"],
          testCase "the fixed resolver refuses an effective home outside its admitted user root" $
            onOwnershipHost $ withResolverHarness "home-shape" $ \harness -> do
              let outsideHome = resolverFixtureRoot (resolverHarnessLayout harness) </> "outside-home"
              createDirectoryIfMissing True outsideHome
              execution <- executeResolverFixtureAt harness outsideHome
              requireUnsupportedResolver harness execution "home-shape",
          testCase "fixed candidates ignore hostile ambient home, path, and working directory" $
            onOwnershipHost $ withResolverHarness "ambient" $ \harness -> do
              let layout = resolverHarnessLayout harness
                  namespace = resolverHarnessNamespace harness
              assertBool "ambient HOME differs from the admitted fixture home" (namespaceHomeDirectory namespace /= resolverFixtureHome layout)
              assertBool "ambient PATH omits the fixture formula directories" (not (takeDirectory (resolverFixtureColimaTarget layout) `isInfixOf` namespaceExecutablePath namespace))
              execution <- executeResolverFixture harness
              _ <- requireReadyResolver harness execution
              pure (),
          testCase "formula, mode, Docker fallback, and helper-directory identity changes are explicit" $
            onOwnershipHost $ do
              withResolverHarness "bad-formula" $ \harness -> do
                let layout = resolverHarnessLayout harness
                removeFile (resolverFixtureColimaAlias layout)
                createFileLink (resolverFixtureBrew layout) (resolverFixtureColimaAlias layout)
                execution <- executeResolverFixture harness
                requireUnsupportedResolver harness execution "colima-formula-root"
              withResolverHarness "bad-mode" $ \harness -> do
                let layout = resolverHarnessLayout harness
                chmodPath harness (resolverFixtureColimaTarget layout) "0777"
                execution <- executeResolverFixture harness
                requireUnsupportedResolver harness execution "executable-write-mode"
              withResolverHarness "docker-app" $ \harness -> do
                let layout = resolverHarnessLayout harness
                removeFile (resolverFixtureDockerAlias layout)
                execution <- executeResolverFixture harness
                (_output, protocol) <- requireReadyResolver harness execution
                case protocol of
                  ResolverProtocolReadyView _ _ (ResolverToolView dockerPath _ _) _ _ _ ->
                    dockerPath @?= resolverFixtureDockerApp layout
                  other -> assertFailure ("expected Docker Desktop fallback, got " ++ show other)
              withResolverHarness "helper-drift" $ \harness -> do
                firstExecution <- executeResolverFixture harness
                (_firstOutput, firstProtocol) <- requireReadyResolver harness firstExecution
                let layout = resolverHarnessLayout harness
                    helper = last (resolverFixtureSystemHelpers layout)
                    moved = helper ++ ".old"
                renameDirectory helper moved
                createDirectoryIfMissing True helper
                secondExecution <- executeResolverFixture harness
                (_secondOutput, secondProtocol) <- requireReadyResolver harness secondExecution
                assertBool
                  "same-path helper-directory replacement changes the retained fingerprint"
                  (resolverFingerprint firstProtocol /= resolverFingerprint secondProtocol),
          testCase "timeout, execution failure, stderr, exit failure, and bootstrap mismatch mint no facade" $
            onOwnershipHost $ withResolverHarness "settlement-errors" $ \harness -> do
              execution <- executeResolverFixture harness
              (output, protocol) <- requireReadyResolver harness execution
              let layout = resolverHarnessLayout harness
                  (pythonDevice, pythonInode) = resolverPythonIdentity protocol
                  settle =
                    settleResolverFixtureExecutionView
                      (resolverFixtureRoot layout)
                      (resolverFixtureHome layout)
              settle pythonDevice pythonInode ResolverExecutionTimedOut @?= ResolverSettlementUnsupported "resolver-timeout"
              settle pythonDevice pythonInode (ResolverExecutionFailed "fixture") @?= ResolverSettlementUnsupported "resolver-execution-failed"
              settle pythonDevice pythonInode (ResolverExecutionCompleted ExitSuccess output "stderr") @?= ResolverSettlementUnsupported "resolver-stderr"
              settle pythonDevice pythonInode (ResolverExecutionCompleted (ExitFailure 7) output "") @?= ResolverSettlementUnsupported "resolver-exit-failure"
              settle (pythonDevice + 1) pythonInode (ResolverExecutionCompleted ExitSuccess output "") @?= ResolverSettlementUnsupported "resolver-python-identity"
        ],
      testCase "the durable Colima stage graph admits only idempotence and one successor" $ do
        let stages = [minBound .. maxBound] :: [ColimaStage]
        mapM_ (\stage -> parseColimaStage (renderColimaStage stage) @?= Right stage) stages
        mapM_ (\stage -> advanceColimaStage stage stage @?= Right stage) stages
        mapM_
          (\(current, successor) -> advanceColimaStage current successor @?= Right successor)
          (zip stages (drop 1 stages))
        advanceColimaStage ColimaReserved ColimaPrepared @?= Left "stage-transition"
        advanceColimaStage ColimaManaged ColimaPrepared @?= Left "stage-transition"
        advanceColimaStage ColimaReleased ColimaReserved @?= Left "stage-transition"
        let decisions =
              [ (AcquireColima, ColimaReserved, ColimaNamespaceAbsent, AdvanceColimaStage ColimaHomeStaged),
                (AcquireColima, ColimaHomeStaged, ColimaHomeStageExact, AdvanceColimaStage ColimaHomeReady),
                (AcquireColima, ColimaHomeReady, ColimaHomeExact, AdvanceColimaStage ColimaContextStaged),
                (AcquireColima, ColimaContextStaged, ColimaContextStageExact, AdvanceColimaStage ColimaPrepared),
                (AcquireColima, ColimaPrepared, ColimaProfileAbsent, StartColimaProfile),
                (AcquireColima, ColimaPrepared, ColimaProfileExact, AdvanceColimaStage ColimaManaged),
                (AcquireColima, ColimaManaged, ColimaProfileExact, KeepColimaStage),
                (ReleaseColima, ColimaManaged, ColimaProfileExact, AdvanceColimaStage ColimaReleasing),
                (ReleaseColima, ColimaReleasing, ColimaProfileExact, DeleteColimaProfile),
                (ReleaseColima, ColimaReleasing, ColimaProfileAbsent, AdvanceColimaStage ColimaContextReleased),
                (ReleaseColima, ColimaContextReleased, ColimaProfileAbsent, AdvanceColimaStage ColimaReleased),
                (ReleaseColima, ColimaReleased, ColimaReleasedNamespaceExact, ReleaseColimaNamespace),
                (ReleaseColima, ColimaReleased, ColimaNamespaceAbsent, KeepColimaStage)
              ]
        mapM_
          (\(intent, stage, observation, decision) -> decideColimaStage intent stage observation @?= Right decision)
          decisions
        let admitted = [(intent, stage, observation) | (intent, stage, observation, _) <- decisions]
            allInputs =
              [ (intent, stage, observation)
                | intent <- [AcquireColima, ReleaseColima],
                  stage <- stages,
                  observation <- [minBound .. maxBound]
              ]
        mapM_
          (\input@(intent, stage, observation) ->
              unless (input `elem` admitted) (decideColimaStage intent stage observation @?= Left "stage-observation"))
          allInputs
        let stageRecord = mkColimaStageRecord ColimaPrepared ownerToken (replicate 64 'c') acquireInvocation
        fmap (parseColimaStageRecord . renderColimaStageRecord) stageRecord @?= fmap Right stageRecord
        fmap colimaStageRecordStage stageRecord @?= Right ColimaPrepared
        (stageRecord >>= parseColimaStageRecord . ByteString.init . renderColimaStageRecord)
          @?= Left "stage-record"
        let evidence = mkColimaManagedEvidence (replicate 32 'd') 42 (replicate 64 'e') (replicate 64 'f') (replicate 64 'a') 8 (16 * gib) (80 * gib) (20 * gib)
            managed = stageRecord >>= \record -> evidence >>= settleColimaStageRecord record
        fmap (parseColimaStageRecord . renderColimaStageRecord) managed @?= fmap Right managed
        fmap colimaStageRecordStage managed @?= Right ColimaManaged
        let releasing = managed >>= (`beginColimaReleaseRecord` cleanupInvocation)
        fmap (parseColimaStageRecord . renderColimaStageRecord) releasing @?= fmap Right releasing
        fmap colimaStageRecordStage releasing
          @?= Right ColimaReleasing
        fmap colimaStageRecordStage (releasing >>= (`advanceSettledColimaStageRecord` ColimaContextReleased))
          @?= Right ColimaContextReleased
        mkColimaStageRecord ColimaManaged ownerToken (replicate 64 'c') acquireInvocation
          @?= Left "stage-evidence"
        parseColimaStage "unknown" @?= Left "record-state",
      testCase "raw Colima JSONL remains plan-independent observation data" $
        parseColimaInstances
          ( unlines
              [ "{\"name\":\"demo\",\"status\":\"Running\",\"cpus\":8,\"memory\":17179869184,\"disk\":107374182400,\"runtime\":\"docker\"}",
                "{\"name\":\"other\",\"status\":\"Stopped\",\"cpus\":2,\"memory\":2147483648,\"disk\":107374182400,\"runtime\":\"incus\"}"
              ]
          )
          @?= Right
            [ ColimaInstance "demo" "Running" 8 (16 * gib) (100 * gib) "docker",
              ColimaInstance "other" "Stopped" 2 (2 * gib) (100 * gib) "incus"
            ],
      testCase "absent, exact-running, and exact-stopped observations classify before mutation" $ do
        result <-
          withPreparedTestCall $ \_ call ->
            let profile = preparedColimaProfileName call
                decide = first show . classifyColimaWall call
             in ( decide [],
                  decide [exactInstance profile "Running"],
                  decide [exactInstance profile "Stopped"]
                )
        case result of
          Left failure -> assertFailure failure
          Right (absent, running, stopped) -> do
            absent @?= Right CreateColimaWall
            running @?= Right KeepExactColimaWall
            stopped @?= Right StartStoppedColimaWall,
      testCase "an incompatible same-name profile is refused as data" $ do
        result <-
          withPreparedTestCall $ \_ call ->
            first show $
              classifyColimaWall
                call
                [ ColimaInstance
                    (preparedColimaProfileName call)
                    "Running"
                    4
                    (16 * gib)
                    (80 * gib)
                    "docker"
                ]
        case result of
          Right (Right (RefuseColimaWall _)) -> pure ()
          other -> assertFailure ("expected refusal, got " ++ show other)
    ]

data ResolverHarness = ResolverHarness
  { resolverHarnessLayout :: ResolverFixtureLayout,
    resolverHarnessNamespace :: BackendNamespace
  }

withResolverHarness :: String -> (ResolverHarness -> IO a) -> IO a
withResolverHarness label action =
  withSystemTempDirectory ("hostbootstrap-colima-resolver-" ++ label) $ \root ->
    setupResolverHarness root >>= action

setupResolverHarness :: FilePath -> IO ResolverHarness
setupResolverHarness root = do
  let layout = resolverFixtureLayout root
      ambient = root </> "ambient"
      namespace =
        BackendNamespace
          { namespaceHomeDirectory = ambient </> "home",
            namespaceColimaHome = ambient </> "colima",
            namespaceLimaHome = ambient </> "lima",
            namespaceColimaCacheHome = ambient </> "cache",
            namespaceTemporaryDirectory = ambient </> "tmp",
            namespaceDockerConfig = ambient </> "docker",
            namespaceWorkingDirectory = ambient </> "cwd",
            namespaceExecutablePath = ambient </> "bin"
          }
      directories =
        [ resolverFixtureHome layout,
          takeDirectory (resolverFixturePython layout),
          takeDirectory (resolverFixtureBrew layout),
          takeDirectory (resolverFixtureColimaTarget layout),
          takeDirectory (resolverFixtureDockerTarget layout),
          takeDirectory (resolverFixtureLimaTarget layout),
          takeDirectory (resolverFixtureDockerApp layout),
          namespaceHomeDirectory namespace,
          namespaceColimaHome namespace,
          namespaceLimaHome namespace,
          namespaceColimaCacheHome namespace,
          namespaceTemporaryDirectory namespace,
          namespaceDockerConfig namespace,
          namespaceWorkingDirectory namespace,
          namespaceExecutablePath namespace
        ]
          ++ resolverFixtureSystemHelpers layout
  mapM_ (createDirectoryIfMissing True) directories
  mapM_
    writeResolverTool
    [ resolverFixturePython layout,
      resolverFixtureBrew layout,
      resolverFixtureColimaTarget layout,
      resolverFixtureDockerTarget layout,
      resolverFixtureLimaTarget layout,
      resolverFixtureDockerApp layout
    ]
  createRelativeFileLink (resolverFixtureColimaTarget layout) (resolverFixtureColimaAlias layout)
  createRelativeFileLink (resolverFixtureDockerTarget layout) (resolverFixtureDockerAlias layout)
  createRelativeFileLink (resolverFixtureLimaTarget layout) (resolverFixtureLimaAlias layout)
  pure
    ResolverHarness
      { resolverHarnessLayout = layout,
        resolverHarnessNamespace = namespace
      }

createRelativeFileLink :: FilePath -> FilePath -> IO ()
createRelativeFileLink target alias =
  createFileLink (repoRelativePath (takeDirectory alias) target) alias

writeResolverTool :: FilePath -> IO ()
writeResolverTool path = do
  writeFile path "resolver-candidate\n"
  makeExecutable path

executeResolverFixture :: ResolverHarness -> IO BoundedToolResult
executeResolverFixture harness =
  executeResolverFixtureAt harness (resolverFixtureHome (resolverHarnessLayout harness))

executeResolverFixtureAt :: ResolverHarness -> FilePath -> IO BoundedToolResult
executeResolverFixtureAt harness effectiveHome = do
  execution <- executeNativeResolverFixture (resolverFixtureRoot (resolverHarnessLayout harness)) effectiveHome
  pure $ case execution of
    ResolverExecutionCompleted code out err -> BoundedToolCompleted code out err
    ResolverExecutionTimedOut -> BoundedToolTimedOut
    ResolverExecutionFailed refusal -> BoundedToolFailed refusal

requireReadyResolver :: ResolverHarness -> BoundedToolResult -> IO (String, ResolverProtocolView)
requireReadyResolver harness execution =
  case execution of
    BoundedToolCompleted ExitSuccess output "" -> do
      protocol <-
        either
          (assertFailure . ("fixture resolver report failed strict decoding: " ++))
          pure
          (parseResolverFixtureProtocolView (resolverFixtureRoot (resolverHarnessLayout harness)) output)
      case parseResolverProtocolView output of
        Left _ -> pure ()
        Right _ -> assertFailure "the production-layout parser accepted fixture-root authority"
      case protocol of
        ResolverProtocolReadyView {} -> pure (output, protocol)
        other -> assertFailure ("expected ready fixture resolver, got " ++ show other)
    other -> assertFailure ("expected a successful fixture resolver, got " ++ show other)

requireUnsupportedResolver :: ResolverHarness -> BoundedToolResult -> String -> IO ()
requireUnsupportedResolver harness execution reason =
  case execution of
    BoundedToolCompleted ExitSuccess output "" ->
      parseResolverFixtureProtocolView (resolverFixtureRoot (resolverHarnessLayout harness)) output
        @?= Right (ResolverProtocolUnsupportedView reason)
    other -> assertFailure ("expected a structured unsupported resolver report, got " ++ show other)

assertResolverRejected :: FilePath -> String -> IO ()
assertResolverRejected root output =
  case parseResolverFixtureProtocolView root output of
    Left _ -> pure ()
    Right value -> assertFailure ("malformed resolver report was accepted as " ++ show value)

resolverFingerprint :: ResolverProtocolView -> String
resolverFingerprint protocol = case protocol of
  ResolverProtocolReadyView _ _ _ _ _ fingerprint -> fingerprint
  ResolverProtocolMissingColimaView _ _ _ fingerprint -> fingerprint
  ResolverProtocolUnsupportedView reason -> "unsupported:" ++ reason

resolverPythonIdentity :: ResolverProtocolView -> (Word64, Word64)
resolverPythonIdentity protocol = case protocol of
  ResolverProtocolReadyView (ResolverToolView _ device inode) _ _ _ _ _ -> (device, inode)
  ResolverProtocolMissingColimaView (ResolverToolView _ device inode) _ _ _ -> (device, inode)
  ResolverProtocolUnsupportedView reason -> error ("unsupported resolver has no Python identity: " ++ reason)

isReadyProtocol :: ResolverProtocolView -> Bool
isReadyProtocol ResolverProtocolReadyView {} = True
isReadyProtocol _ = False

chmodPath :: ResolverHarness -> FilePath -> String -> IO ()
#if defined(mingw32_HOST_OS)
chmodPath _ _ _ = assertFailure "resolver chmod is unavailable on Windows"
#else
chmodPath _ path "0777" = setFileMode path 0o777
chmodPath _ _ mode = assertFailure ("unsupported fixture chmod mode: " ++ mode)
#endif

makeExecutable :: FilePath -> IO ()
makeExecutable path = do
  permissions <- getPermissions path
  setPermissions path permissions {executable = True}

exactInstance :: String -> String -> ColimaInstance
exactInstance profile status =
  ColimaInstance profile status 8 (16 * gib) (80 * gib) "docker"

onOwnershipHost :: IO () -> IO ()
onOwnershipHost action = unless (os == "mingw32") action

strictReadFile :: FilePath -> IO String
strictReadFile path = do
  contents <- readFile path
  seq (length contents) (pure contents)

waitForPidGone :: FilePath -> String -> IO ()
waitForPidGone python pid = do
  result <- timeout 5000000 loop
  case result of
    Just () -> pure ()
    Nothing -> assertFailure ("runner left process " ++ pid ++ " alive")
  where
    loop = do
      (exitCode, _out, _errOut) <-
        readProcessWithExitCode
          python
          [ "-c",
            "import os,sys\ntry: os.kill(int(sys.argv[1]),0)\nexcept ProcessLookupError: raise SystemExit(1)\nexcept PermissionError: pass",
            pid
          ]
          ""
      case exitCode of
        ExitSuccess -> threadDelay 10000 >> loop
        _ -> pure ()

waitForPath :: FilePath -> IO ()
waitForPath target = do
  observed <- timeout 5000000 loop
  case observed of
    Just () -> pure ()
    Nothing -> assertFailure ("timed out waiting for " ++ target)
  where
    loop = do
      present <- doesFileExist target
      if present then pure () else threadDelay 10000 >> loop

runShippedOwnerProbe :: FilePath -> FilePath -> FilePath -> IO ()
runShippedOwnerProbe directory pidPath python = do
  let namespace =
        BackendNamespace
          { namespaceHomeDirectory = directory,
            namespaceColimaHome = directory,
            namespaceLimaHome = directory,
            namespaceColimaCacheHome = directory,
            namespaceTemporaryDirectory = directory,
            namespaceDockerConfig = directory,
            namespaceWorkingDirectory = directory,
            namespaceExecutablePath = "/usr/bin:/bin"
          }
      program =
        "import os,signal,sys,time\n"
          ++ "with open(sys.argv[1],'w') as stream: stream.write(str(os.getpid()))\n"
          ++ "signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
          ++ "time.sleep(30)\n"
  _ <- runShippedCommand 60 namespace python ["-c", program, pidPath]
  pure ()

requireExecutable :: String -> Maybe FilePath -> IO FilePath
requireExecutable _label (Just path) = pure path
requireExecutable label Nothing = assertFailure ("missing test executable: " ++ label)

withPreparedPublicTestCallM ::
  ( forall
      projectId
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      clusterResourceId
      clusterFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence.
    ProjectPlan
      (Production projectId)
      specDigest
      planId
      configId
      Fixture.ProjectConfig ->
    PlannedResource
      (Production projectId)
      planId
      providerResourceId
      ProviderResource
      providerFrame ->
    PlannedResource
      (Production projectId)
      planId
      clusterResourceId
      ClusterResource
      clusterFrame ->
    PreparedGate ->
    IO PreparedGate ->
    Text.Text ->
    PreparedColimaWallCall
      (Production projectId)
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence ->
    IO result
  ) ->
  IO (Either String result)
withPreparedPublicTestCallM consume = do
  withTestProjectResources $ \plan expectedProject providerResource clusterResource -> do
    let planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
        operation = plannedResourceKey providerResource
    withSuccessorGate planDigest operation "session-1" "stale-acquire-session" 1 1 2 $ \gate nextGate ->
      withPreparedTestCallForGate plan providerResource clusterResource gate $
        consume plan providerResource clusterResource gate nextGate expectedProject

withPreparedTestCallForGate ::
  ProjectPlan scope specDigest planId configId Fixture.ProjectConfig ->
  PlannedResource scope planId providerResourceId ProviderResource providerFrame ->
  PlannedResource scope planId clusterResourceId ClusterResource clusterFrame ->
  PreparedGate ->
  ( forall
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence.
    PreparedColimaWallCall
      scope
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence ->
    IO result
  ) ->
  IO (Either String result)
withPreparedTestCallForGate plan providerResource clusterResource gate consume = do
  withPreparedTestCallForGateAndEnvelope exactEnvelope plan providerResource clusterResource gate consume

withPreparedTestCallForGateAndEnvelope ::
  Context.ResourceEnvelope ->
  ProjectPlan scope specDigest planId configId Fixture.ProjectConfig ->
  PlannedResource scope planId providerResourceId ProviderResource providerFrame ->
  PlannedResource scope planId clusterResourceId ClusterResource clusterFrame ->
  PreparedGate ->
  ( forall
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence.
    PreparedColimaWallCall
      scope
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence ->
    IO result
  ) ->
  IO (Either String result)
withPreparedTestCallForGateAndEnvelope envelope plan providerResource clusterResource gate consume = do
  let prepared = do
        workload <- first show (mkWorkload clusterResource 1 1 gib gib)
        overhead <- first show (mkResourceBudget 1 gib gib)
        sliceBudget <- first show (mkResourceBudget 6 (10 * gib) (80 * gib))
        minimumBudget <- first show (mkResourceBudget 1 gib gib)
        request <- first show (mkSliceRequest providerResource sliceBudget minimumBudget)
        flattenBudget $
          withValidatedBudget plan envelope $ \validated ->
            withProviderBudgetCapability plan providerResource ColimaProviderKey $ \capability ->
              flattenBudget $
                admitProviderBudget validated capability $ \wall effective ->
                  flattenBudget $
                    withPlannedWorkloadSet plan [workload] $ \workloads -> do
                      fit <- first show (verifyPlannedWorkloadFit effective workloads)
                      flattenBudget $
                        withBudgetPartition effective fit overhead (request :| []) $ \partition _ ->
                          flattenBudget $
                            withProviderWallReservation plan providerResource wall partition gate $ \reservation ->
                              first show $
                                withObservedProjectResource plan providerResource 17 7 $ \providerHandle -> do
                                  result <-
                                    prepareColimaWallCall
                                      plan
                                      providerResource
                                      providerHandle
                                      (topology plan)
                                      validated
                                      capability
                                      wall
                                      fit
                                      partition
                                      reservation
                                      gate
                                  case result of
                                    Left failure -> pure (Left (show failure))
                                    Right call -> Right <$> consume call
  case prepared of
    Left failure -> pure (Left failure)
    Right action -> action

withPreparedTestCallM ::
  ( forall
      projectId
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence.
    Text.Text ->
    PreparedColimaWallCall
      (Production projectId)
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence ->
    IO result
  ) ->
  IO (Either String result)
withPreparedTestCallM consume =
  withPreparedPublicTestCallM (\_plan _provider _cluster _gate _nextGate project call -> consume project call)

withPreparedTestCall ::
  ( forall
      projectId
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence.
    Text.Text ->
    PreparedColimaWallCall
      (Production projectId)
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence ->
    result
  ) ->
  IO (Either String result)
withPreparedTestCall consume =
  withPreparedTestCallM (\project call -> pure (consume project call))

runNativeColimaAcceptance :: IO ()
runNativeColimaAcceptance = do
  colima <- requireExecutable "colima" =<< findExecutable "colima"
  docker <- requireExecutable "docker" =<< findExecutable "docker"
  ambientProfilesBefore <- requireNativeCommand colima ["list", "--json"]
  ambientContextBefore <- requireNativeCommand docker ["context", "show"]
  accepted <-
    withPreparedPublicTestCallM $ \plan providerResource clusterResource gate nextGate expectedProject call -> do
      let profile = preparedColimaProfileName call
      putStrLn ("direct-colima-live: project=" ++ Text.unpack expectedProject ++ " profile=" ++ profile)
      observation <- runPreparedColimaWallCall call
      case settleColimaWallCall call observation $ \live -> do
        cleanupResult <- newIORef (Left "native direct-Colima cleanup did not run")
        let cleanup = do
              result <-
                case withColimaCleanupAuthority live $ \authority -> do
                  cleanupGate <- nextGate
                  prepared <- prepareColimaCleanupCall plan providerResource cleanupGate authority
                  case prepared of
                    Left failure -> pure (Left (show failure))
                    Right cleanupCall -> fmap (first show . fmap (const ())) (runColimaCleanup cleanupCall) of
                  Nothing -> pure (Left "live direct-Colima wall did not retain cleanup authority")
                  Just action -> action
              writeIORef cleanupResult result
            verify = do
              assertBool "the exact native profile is derived, not caller-selected" (isPrefixOf "h-" profile && length profile == 8)
              assertBool "the exact Docker context cannot be the shared default" (liveColimaDockerContext live /= "default")
              dockerResult <- runLiveColimaDocker live ["version", "--format", "{{.Server.Version}}"]
              case dockerResult of
                Right (ExitSuccess, version, "") ->
                  assertBool "the routed native Docker server returned a version" (not (null version))
                other -> assertFailure ("the routed native Docker probe failed: " ++ show other)
              conflict <-
                withPreparedTestCallForGateAndEnvelope
                  (Context.ResourceEnvelope 9 "16GiB" "100GiB")
                  plan
                  providerResource
                  clusterResource
                  gate
                  ( \conflictingCall -> do
                      conflictingObservation <- runPreparedColimaWallCall conflictingCall
                      pure (settleColimaWallCall conflictingCall conflictingObservation (const ()))
                  )
              case conflict of
                Right (Left Conflict {}) -> pure ()
                other -> assertFailure ("the incompatible same-name native profile was not refused: " ++ show other)
        verify `finally` cleanup
        cleaned <- readIORef cleanupResult
        cleaned @?= Right ()
       of
        Left failure -> assertFailure ("the native direct-Colima wall did not settle: " ++ show failure)
        Right action -> action
  case accepted of
    Left failure -> assertFailure failure
    Right () -> pure ()
  ambientProfilesAfter <- requireNativeCommand colima ["list", "--json"]
  ambientContextAfter <- requireNativeCommand docker ["context", "show"]
  ambientProfilesAfter @?= ambientProfilesBefore
  ambientContextAfter @?= ambientContextBefore
  putStrLn "direct-colima-live: conflict refused; exact profile/context/data cleaned; ambient default unchanged"

requireNativeCommand :: FilePath -> [String] -> IO String
requireNativeCommand executablePath arguments = do
  (code, out, errOut) <- readProcessWithExitCode executablePath arguments ""
  case (code, errOut) of
    (ExitSuccess, "") -> pure out
    _ -> assertFailure ("native acceptance command failed: " ++ show (executablePath, arguments, code, errOut))

flattenBudget :: Either BudgetError (Either String a) -> Either String a
flattenBudget = either (Left . show) id

testPlan :: StepPlan
testPlan =
  either
    (error . show)
    id
    ( mkStepPlan
        [ descendsVia
            localContext
            (deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged))),
          deployKindStep "cluster" (StepFrame "provider" "Provider") (const (pure StepChanged))
        ]
    )

withTestProjectResources ::
  ( forall projectId specDigest planId configId providerId providerFrame clusterId clusterFrame.
    ProjectPlan
      (Production projectId)
      specDigest
      planId
      configId
      Fixture.ProjectConfig ->
    Text.Text ->
    PlannedResource
      (Production projectId)
      planId
      providerId
      ProviderResource
      providerFrame ->
    PlannedResource
      (Production projectId)
      planId
      clusterId
      ClusterResource
      clusterFrame ->
    IO result
  ) ->
  IO result
withTestProjectResources consume =
  Fixture.withFixtureProjectPlanContext id testPlan $ \plan context ->
    case NonEmpty.toList (forward plan) of
      [providerNode, clusterNode] ->
        case
          withPlannedResourceOfKind
            plan
            ProviderResourceKind
            (plannedStepOperationKey providerNode)
            ( \providerResource ->
                withPlannedResourceOfKind
                  plan
                  ClusterResourceKind
                  (plannedStepOperationKey clusterNode)
                  (consume plan (Context.project context) providerResource)
            ) of
          Left failure -> fail ("provider projection failed: " ++ show failure)
          Right (Left failure) -> fail ("cluster projection failed: " ++ show failure)
          Right (Right action) -> action
      nodes -> fail ("expected provider and cluster plan nodes, got " ++ show (length nodes))
