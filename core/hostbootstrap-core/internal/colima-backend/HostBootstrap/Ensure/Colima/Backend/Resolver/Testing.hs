module HostBootstrap.Ensure.Colima.Backend.Resolver.Testing (
    ResolverToolView (..),
    ResolverProtocolView (..),
    ResolverExecutionFixture (..),
    ResolverSettlementView (..),
    ResolverInstallOutcomeView (..),
    ResolverInstallScenarioView (..),
    ResolverFixtureLayout (..),
    resolverFixtureLayout,
    resolverOwnerModePolicyView,
    executeNativeResolverFixture,
    executeNativeResolverFixtureWithSettlement,
    parseResolverProtocolView,
    parseResolverFixtureProtocolView,
    settleResolverExecutionView,
    settleResolverFixtureExecutionView,
    runResolverInstallScenario,
    revalidateResolverFixtureView,
    settlementView,
)
where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Word (Word64)
import HostBootstrap.Ensure.Colima.Backend.Resolver (
    TrustedResolverResult (..),
    classifyTrustedAppleToolchainRevalidation,
    classifyTrustedAppleBrewRevalidation,
    settleTrustedResolverFixtureResultForTesting,
    settleTrustedResolverProtocolForFixtureTesting,
    settleTrustedResolverResultForTesting,
    trustedAppleBrewHelperPath,
    trustedAppleBrewPath,
    trustedAppleColimaPath,
    trustedAppleDockerPath,
    trustedAppleHelperPath,
    trustedAppleLimaPath,
    trustedAppleToolchainFingerprint,
 )
import HostBootstrap.Ensure.Colima.Backend.Resolver.Install (
    TrustedInstallActions (..),
    TrustedInstallResult (..),
    runTrustedInstallRediscovery,
 )
import HostBootstrap.Ensure.Colima.Backend.Resolver.Native (ResolverPolicyKind (..), resolveNativeResolverFixture, resolverOwnerModePolicy)
import HostBootstrap.Ensure.Colima.Backend.Resolver.Protocol (
    ResolvedTool (..),
    TrustedResolverProtocol (..),
    TrustedToolIdentity (..),
    parseTrustedResolverOutput,
    parseTrustedResolverOutputForFixtureRoot,
    renderTrustedResolverProtocol,
    trustedDirectoryBindingsFingerprint,
 )
import HostBootstrap.Ensure.Colima.Backend.Runner (
    BoundedToolResult (..),
 )
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))

-- Descriptive views project the actual private resolver result. The native
-- fixture entry retains that opaque result from the same kernel walk and settlement;
-- it exports no authority constructor or caller-configurable production resolver.
data ResolverToolView = ResolverToolView !FilePath !Word64 !Word64
    deriving (Eq, Show)

data ResolverProtocolView
    = ResolverProtocolReadyV2View !ResolverToolView !ResolverToolView !ResolverToolView !String !String
    | ResolverProtocolMissingColimaV2View !ResolverToolView !String !String
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
    { resolverInstallOutcome :: !ResolverInstallOutcomeView
    , resolverInstallTrace :: ![String]
    }
    deriving (Eq, Show)

data ResolverFixtureLayout = ResolverFixtureLayout
    { resolverFixtureRoot :: !FilePath
    , resolverFixtureHome :: !FilePath
    , resolverFixtureBrew :: !FilePath
    , resolverFixtureColimaAlias :: !FilePath
    , resolverFixtureColimaTarget :: !FilePath
    , resolverFixtureDockerAlias :: !FilePath
    , resolverFixtureDockerTarget :: !FilePath
    , resolverFixtureDockerApp :: !FilePath
    , resolverFixtureLimaAlias :: !FilePath
    , resolverFixtureLimaTarget :: !FilePath
    , resolverFixtureSystemHelpers :: ![FilePath]
    }
    deriving (Eq, Show)

resolverFixtureLayout :: FilePath -> ResolverFixtureLayout
resolverFixtureLayout root =
    let homebrew = root </> "opt" </> "homebrew"
        cellar = homebrew </> "Cellar"
     in ResolverFixtureLayout
            { resolverFixtureRoot = root
            , resolverFixtureHome = root </> "Users" </> "fixture"
            , resolverFixtureBrew = homebrew </> "bin" </> "brew"
            , resolverFixtureColimaAlias = homebrew </> "bin" </> "colima"
            , resolverFixtureColimaTarget = cellar </> "colima" </> "test" </> "bin" </> "colima"
            , resolverFixtureDockerAlias = homebrew </> "bin" </> "docker"
            , resolverFixtureDockerTarget = cellar </> "docker" </> "test" </> "bin" </> "docker"
            , resolverFixtureDockerApp = root </> "Applications" </> "Docker.app" </> "Contents" </> "Resources" </> "bin" </> "docker"
            , resolverFixtureLimaAlias = homebrew </> "bin" </> "limactl"
            , resolverFixtureLimaTarget = cellar </> "lima" </> "test" </> "bin" </> "limactl"
            , resolverFixtureSystemHelpers =
                [root </> "usr" </> "bin", root </> "bin", root </> "usr" </> "sbin", root </> "sbin"]
            }

-- | Descriptive policy evaluation, with an explicit private fixture root.
resolverOwnerModePolicyView :: Maybe FilePath -> Bool -> FilePath -> Word64 -> Word64 -> Word64 -> Either String ()
resolverOwnerModePolicyView fixtureRoot directory = resolverOwnerModePolicy kind
  where
    kind = case (fixtureRoot, directory) of
        (Nothing, False) -> ProductionExecutablePolicy
        (Nothing, True) -> ProductionDirectoryPolicy
        (Just root, False) -> FixtureExecutablePolicy root
        (Just root, True) -> FixtureDirectoryPolicy root

executeNativeResolverFixture :: FilePath -> FilePath -> IO ResolverExecutionFixture
executeNativeResolverFixture root home = fst <$> executeNativeResolverFixtureWithSettlement root home

-- | Observe the native result and its shared settlement without decoding wire.
executeNativeResolverFixtureWithSettlement :: FilePath -> FilePath -> IO (ResolverExecutionFixture, TrustedResolverResult)
executeNativeResolverFixtureWithSettlement root home = do
    protocol <- resolveNativeResolverFixture root home
    pure
        ( ResolverExecutionCompleted ExitSuccess (renderTrustedResolverProtocol protocol) ""
        , settleTrustedResolverProtocolForFixtureTesting root home protocol
        )

parseResolverProtocolView :: String -> Either String ResolverProtocolView
parseResolverProtocolView = fmap protocolView . parseTrustedResolverOutput

parseResolverFixtureProtocolView :: FilePath -> String -> Either String ResolverProtocolView
parseResolverFixtureProtocolView root =
    fmap protocolView . parseTrustedResolverOutputForFixtureRoot root

settleResolverExecutionView ::
    FilePath ->
    ResolverExecutionFixture ->
    ResolverSettlementView
settleResolverExecutionView home execution =
    settlementView
        ( settleTrustedResolverResultForTesting
            home
            (executionResult execution)
        )

settleResolverFixtureExecutionView ::
    FilePath ->
    FilePath ->
    ResolverExecutionFixture ->
    ResolverSettlementView
settleResolverFixtureExecutionView root home execution =
    settlementView
        ( settleTrustedResolverFixtureResultForTesting
            root
            home
            (executionResult execution)
        )

runResolverInstallScenario ::
    FilePath ->
    FilePath ->
    String ->
    Either String () ->
    ResolverExecutionFixture ->
    ResolverExecutionFixture ->
    IO ResolverInstallScenarioView
runResolverInstallScenario
    root
    home
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
                                pure revalidation
                            , trustedInstallRunBrew = do
                                record trace "install"
                                pure (executionResult installExecution)
                            , trustedInstallRediscover = do
                                record trace "rediscover"
                                pure (settleFixture rediscoveryExecution)
                            }
                observedTrace <- readIORef trace
                pure
                    ResolverInstallScenarioView
                        { resolverInstallOutcome = installOutcomeView result
                        , resolverInstallTrace = observedTrace
                        }
            _ ->
                pure
                    ResolverInstallScenarioView
                        { resolverInstallOutcome = ResolverInstallInvalidInitialView
                        , resolverInstallTrace = []
                        }
      where
        settleFixture execution =
            settleTrustedResolverFixtureResultForTesting
                root
                home
                (executionResult execution)

        record trace entry = modifyIORef' trace (++ [entry])

-- | Descriptive classification only: settlement retains authority inside the
-- private component, and no callback can redirect a production resolver.
revalidateResolverFixtureView ::
    FilePath ->
    FilePath ->
    ResolverExecutionFixture ->
    ResolverExecutionFixture ->
    Either String ()
revalidateResolverFixtureView root home retained fresh =
    case settle retained of
        TrustedResolverReady expected ->
            classifyTrustedAppleToolchainRevalidation expected (settle fresh)
        TrustedResolverMissingColima expected ->
            classifyTrustedAppleBrewRevalidation expected (settle fresh)
        TrustedResolverUnsupported reason -> Left reason
  where
    settle execution =
        settleTrustedResolverFixtureResultForTesting root home (executionResult execution)

protocolView :: TrustedResolverProtocol -> ResolverProtocolView
protocolView protocol = case protocol of
    ProtocolReadyV2 colima docker lima helperPath helperBindings ->
        ResolverProtocolReadyV2View (toolView colima) (toolView docker) (toolView lima) helperPath
            (trustedDirectoryBindingsFingerprint helperBindings)
    ProtocolMissingColimaV2 brew helperPath helperBindings ->
        ResolverProtocolMissingColimaV2View (toolView brew) helperPath
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
