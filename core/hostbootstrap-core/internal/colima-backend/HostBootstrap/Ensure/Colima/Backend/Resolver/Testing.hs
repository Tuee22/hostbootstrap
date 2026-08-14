module HostBootstrap.Ensure.Colima.Backend.Resolver.Testing
  ( ResolverToolView (..),
    ResolverProtocolView (..),
    ResolverExecutionFixture (..),
    ResolverSettlementView (..),
    ResolverInstallOutcomeView (..),
    ResolverInstallScenarioView (..),
    ResolverFixtureLayout (..),
    resolverFixtureLayout,
    resolverFixtureProgram,
    resolverFixtureProgramForHomeRoot,
    parseResolverProtocolView,
    parseResolverFixtureProtocolView,
    settleResolverExecutionView,
    settleResolverFixtureExecutionView,
    runResolverInstallScenario,
    withTrustedResolverFixture,
  )
where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Word (Word64)
import HostBootstrap.Ensure.Colima.Backend.Resolver
  ( TrustedResolverResult (..),
    settleTrustedResolverFixtureResultForTesting,
    settleTrustedResolverResultForTesting,
    trustedAppleBrewHelperPath,
    trustedAppleBrewPath,
    trustedAppleColimaPath,
    trustedAppleDockerPath,
    trustedAppleHelperPath,
    trustedAppleLimaPath,
    trustedApplePythonPath,
    trustedAppleToolchainFingerprint,
  )
import HostBootstrap.Ensure.Colima.Backend.Resolver.Program
  ( resolverProgramForFixtureRoot,
    resolverProgramForFixtureRootAndHomeRoot,
  )
import HostBootstrap.Ensure.Colima.Backend.Resolver.Install
  ( TrustedInstallActions (..),
    TrustedInstallResult (..),
    runTrustedInstallRediscovery,
  )
import HostBootstrap.Ensure.Colima.Backend.Resolver.Override
  ( ResolverOverride (..),
    withResolverOverride,
  )
import HostBootstrap.Ensure.Colima.Backend.Resolver.Protocol
  ( ResolvedTool (..),
    TrustedResolverProtocol (..),
    TrustedToolIdentity (..),
    parseTrustedResolverOutput,
    parseTrustedResolverOutputForFixtureRoot,
    trustedDirectoryBindingsFingerprint,
  )
import HostBootstrap.Ensure.Colima.Backend.Runner
  ( BoundedToolResult (..),
  )
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))

-- These views deliberately contain only descriptive data.  They let the
-- host-static suite exercise the Cabal-private resolver without exporting an
-- authority constructor or a caller-configurable production resolver.
data ResolverToolView = ResolverToolView !FilePath !Word64 !Word64
  deriving (Eq, Show)

data ResolverProtocolView
  = ResolverProtocolReadyView
      !ResolverToolView
      !ResolverToolView
      !ResolverToolView
      !ResolverToolView
      !String
      !String
  | ResolverProtocolMissingColimaView
      !ResolverToolView
      !ResolverToolView
      !String
      !String
  | ResolverProtocolUnsupportedView !String
  deriving (Eq, Show)

data ResolverExecutionFixture
  = ResolverExecutionCompleted !ExitCode !String !String
  | ResolverExecutionTimedOut
  | ResolverExecutionFailed !String
  deriving (Eq, Show)

data ResolverSettlementView
  = ResolverSettlementReady
      !FilePath
      !FilePath
      !FilePath
      !FilePath
      !String
      !String
  | ResolverSettlementMissingColima !FilePath !String
  | ResolverSettlementUnsupported !String
  deriving (Eq, Show)

data ResolverInstallOutcomeView
  = ResolverInstallReadyView !String
  | ResolverInstallBrewChangedView !String
  | ResolverInstallExitFailureView !ExitCode !String
  | ResolverInstallTimedOutView
  | ResolverInstallExecutionFailedView !String
  | ResolverInstallStillMissingView
  | ResolverInstallUnsupportedView !String
  | ResolverInstallInvalidInitialView
  deriving (Eq, Show)

data ResolverInstallScenarioView = ResolverInstallScenarioView
  { resolverInstallOutcome :: !ResolverInstallOutcomeView,
    resolverInstallTrace :: ![String]
  }
  deriving (Eq, Show)

data ResolverFixtureLayout = ResolverFixtureLayout
  { resolverFixtureRoot :: !FilePath,
    resolverFixtureHome :: !FilePath,
    resolverFixturePython :: !FilePath,
    resolverFixtureBrew :: !FilePath,
    resolverFixtureColimaAlias :: !FilePath,
    resolverFixtureColimaTarget :: !FilePath,
    resolverFixtureDockerAlias :: !FilePath,
    resolverFixtureDockerTarget :: !FilePath,
    resolverFixtureDockerApp :: !FilePath,
    resolverFixtureLimaAlias :: !FilePath,
    resolverFixtureLimaTarget :: !FilePath,
    resolverFixtureSystemHelpers :: ![FilePath]
  }
  deriving (Eq, Show)

resolverFixtureLayout :: FilePath -> ResolverFixtureLayout
resolverFixtureLayout root =
  let homebrew = root </> "opt" </> "homebrew"
      cellar = homebrew </> "Cellar"
   in ResolverFixtureLayout
        { resolverFixtureRoot = root,
          resolverFixtureHome = root </> "Users" </> "fixture",
          resolverFixturePython = root </> "usr" </> "bin" </> "python3",
          resolverFixtureBrew = homebrew </> "bin" </> "brew",
          resolverFixtureColimaAlias = homebrew </> "bin" </> "colima",
          resolverFixtureColimaTarget = cellar </> "colima" </> "test" </> "bin" </> "colima",
          resolverFixtureDockerAlias = homebrew </> "bin" </> "docker",
          resolverFixtureDockerTarget = cellar </> "docker" </> "test" </> "bin" </> "docker",
          resolverFixtureDockerApp = root </> "Applications" </> "Docker.app" </> "Contents" </> "Resources" </> "bin" </> "docker",
          resolverFixtureLimaAlias = homebrew </> "bin" </> "limactl",
          resolverFixtureLimaTarget = cellar </> "lima" </> "test" </> "bin" </> "limactl",
          resolverFixtureSystemHelpers =
            [root </> "usr" </> "bin", root </> "bin", root </> "usr" </> "sbin", root </> "sbin"]
        }

resolverFixtureProgram :: FilePath -> Either String String
resolverFixtureProgram = resolverProgramForFixtureRoot

resolverFixtureProgramForHomeRoot :: FilePath -> FilePath -> Either String String
resolverFixtureProgramForHomeRoot = resolverProgramForFixtureRootAndHomeRoot

parseResolverProtocolView :: String -> Either String ResolverProtocolView
parseResolverProtocolView = fmap protocolView . parseTrustedResolverOutput

parseResolverFixtureProtocolView :: FilePath -> String -> Either String ResolverProtocolView
parseResolverFixtureProtocolView root =
  fmap protocolView . parseTrustedResolverOutputForFixtureRoot root

settleResolverExecutionView ::
  FilePath ->
  Word64 ->
  Word64 ->
  ResolverExecutionFixture ->
  ResolverSettlementView
settleResolverExecutionView home device inode execution =
  settlementView
    ( settleTrustedResolverResultForTesting
        home
        (TrustedToolIdentity device inode)
        (executionResult execution)
    )

settleResolverFixtureExecutionView ::
  FilePath ->
  FilePath ->
  Word64 ->
  Word64 ->
  ResolverExecutionFixture ->
  ResolverSettlementView
settleResolverFixtureExecutionView root home device inode execution =
  settlementView
    ( settleTrustedResolverFixtureResultForTesting
        root
        home
        (TrustedToolIdentity device inode)
        (executionResult execution)
    )

runResolverInstallScenario ::
  FilePath ->
  FilePath ->
  Word64 ->
  Word64 ->
  String ->
  Either String () ->
  ResolverExecutionFixture ->
  ResolverExecutionFixture ->
  IO ResolverInstallScenarioView
runResolverInstallScenario
  root
  home
  device
  inode
  initialOutput
  revalidation
  installExecution
  rediscoveryExecution =
    case settleFixture (ResolverExecutionCompleted ExitSuccess initialOutput "") of
      TrustedResolverMissingColima _brew -> do
        trace <- newIORef []
        result <-
          runTrustedInstallRediscovery
            TrustedInstallActions
              { trustedInstallRevalidateBrew = do
                  record trace "revalidate"
                  pure revalidation,
                trustedInstallRunBrew = do
                  record trace "install"
                  pure (executionResult installExecution),
                trustedInstallRediscover = do
                  record trace "rediscover"
                  pure (settleFixture rediscoveryExecution)
              }
        observedTrace <- readIORef trace
        pure
          ResolverInstallScenarioView
            { resolverInstallOutcome = installOutcomeView result,
              resolverInstallTrace = observedTrace
            }
      _ ->
        pure
          ResolverInstallScenarioView
            { resolverInstallOutcome = ResolverInstallInvalidInitialView,
              resolverInstallTrace = []
            }
  where
    settleFixture execution =
      settleTrustedResolverFixtureResultForTesting
        root
        home
        (TrustedToolIdentity device inode)
        (executionResult execution)

    record trace entry = modifyIORef' trace (++ [entry])

-- The fixture supplies only a fresh bounded resolver execution.  Each public
-- adapter discovery and revalidation still goes through the real strict
-- fixture parser and opaque resolver settlement; no backend result or trusted
-- toolchain constructor is injected.
withTrustedResolverFixture ::
  FilePath ->
  FilePath ->
  Word64 ->
  Word64 ->
  IO ResolverExecutionFixture ->
  IO a ->
  IO (Either String a)
withTrustedResolverFixture root home device inode execute action = do
  initial <- resolve
  case initial of
    TrustedResolverReady _ ->
      withResolverOverride
        ResolverOverride
          { resolverOverrideRoot = root,
            resolverOverrideHome = home,
            resolverOverrideBootstrapDevice = device,
            resolverOverrideBootstrapInode = inode,
            resolverOverrideExecution = executionResult <$> execute
          }
        action
    TrustedResolverMissingColima _ -> pure (Left "resolver-fixture-colima-missing")
    TrustedResolverUnsupported reason -> pure (Left reason)
  where
    resolve = do
      execution <- execute
      pure
        ( settleTrustedResolverFixtureResultForTesting
            root
            home
            (TrustedToolIdentity device inode)
            (executionResult execution)
        )

protocolView :: TrustedResolverProtocol -> ResolverProtocolView
protocolView protocol = case protocol of
  ProtocolReady python colima docker lima helperPath helperBindings ->
    ResolverProtocolReadyView
      (toolView python)
      (toolView colima)
      (toolView docker)
      (toolView lima)
      helperPath
      (trustedDirectoryBindingsFingerprint helperBindings)
  ProtocolMissingColima python brew helperPath helperBindings ->
    ResolverProtocolMissingColimaView
      (toolView python)
      (toolView brew)
      helperPath
      (trustedDirectoryBindingsFingerprint helperBindings)
  ProtocolUnsupported reason -> ResolverProtocolUnsupportedView reason

toolView :: ResolvedTool -> ResolverToolView
toolView (ResolvedTool path (TrustedToolIdentity device inode)) =
  ResolverToolView path device inode

executionResult :: ResolverExecutionFixture -> BoundedToolResult
executionResult execution = case execution of
  ResolverExecutionCompleted exitCode output errors ->
    BoundedToolCompleted exitCode output errors
  ResolverExecutionTimedOut -> BoundedToolTimedOut
  ResolverExecutionFailed reason -> BoundedToolFailed reason

settlementView :: TrustedResolverResult -> ResolverSettlementView
settlementView result = case result of
  TrustedResolverReady toolchain ->
    ResolverSettlementReady
      (trustedApplePythonPath toolchain)
      (trustedAppleColimaPath toolchain)
      (trustedAppleDockerPath toolchain)
      (trustedAppleLimaPath toolchain)
      (trustedAppleHelperPath toolchain)
      (trustedAppleToolchainFingerprint toolchain)
  TrustedResolverMissingColima brew ->
    ResolverSettlementMissingColima
      (trustedAppleBrewPath brew)
      (trustedAppleBrewHelperPath brew)
  TrustedResolverUnsupported reason -> ResolverSettlementUnsupported reason

installOutcomeView :: TrustedInstallResult -> ResolverInstallOutcomeView
installOutcomeView result = case result of
  TrustedInstallReady toolchain ->
    ResolverInstallReadyView (trustedAppleToolchainFingerprint toolchain)
  TrustedInstallBrewChanged reason -> ResolverInstallBrewChangedView reason
  TrustedInstallExitFailure exitCode errors -> ResolverInstallExitFailureView exitCode errors
  TrustedInstallTimedOut -> ResolverInstallTimedOutView
  TrustedInstallExecutionFailed reason -> ResolverInstallExecutionFailedView reason
  TrustedInstallStillMissing -> ResolverInstallStillMissingView
  TrustedInstallResolverUnsupported reason -> ResolverInstallUnsupportedView reason
