{-# LANGUAGE CPP #-}

module HostBootstrap.Ensure.Colima.Backend.Resolver (
    TrustedAppleToolchain,
    TrustedAppleBrew,
    TrustedResolverResult (
        TrustedResolverReady,
        TrustedResolverMissingColima,
        TrustedResolverUnsupported
    ),
    trustedAppleColimaPath,
    trustedAppleDockerPath,
    trustedAppleLimaPath,
    trustedAppleHelperPath,
    trustedAppleToolchainFingerprint,
    trustedAppleBrewPath,
    trustedAppleBrewHelperPath,
    resolveTrustedAppleToolchain,
    revalidateTrustedAppleToolchain,
    revalidateTrustedAppleBrew,
    classifyTrustedAppleToolchainRevalidation,
    classifyTrustedAppleBrewRevalidation,
    settleTrustedResolverResultForTesting,
    settleTrustedResolverFixtureResultForTesting,
    settleTrustedResolverProtocolForFixtureTesting,
)
where

import HostBootstrap.Ensure.Colima.Backend.Resolver.Authority (
    TrustedAppleBrew (..),
    TrustedAppleToolchain (..),
    TrustedResolverResult (..),
    trustedAppleBrewHelperPath,
    trustedAppleBrewPath,
    trustedAppleColimaPath,
    trustedAppleDockerPath,
    trustedAppleHelperPath,
    trustedAppleLimaPath,
    trustedAppleToolchainFingerprint,
 )
#if defined(mingw32_HOST_OS)
import HostBootstrap.Ensure.Colima.Backend.Resolver.Protocol (TrustedResolverProtocol)
#else
import HostBootstrap.Ensure.Colima.Backend.Resolver.Native (resolveNativeAppleToolchain)
import HostBootstrap.Ensure.Colima.Backend.Resolver.Protocol
  ( ResolvedTool (..),
    TrustedResolverProtocol (..),
    ResolverProtocolLayout,
    productionProtocolLayout,
    fixtureProtocolLayout,
    validateTrustedProtocol,
    parseTrustedResolverOutput,
    parseTrustedResolverOutputForFixtureRoot,
  )
#endif
import HostBootstrap.Ensure.Colima.Backend.Runner (BoundedToolResult (..))
#if !defined(mingw32_HOST_OS)
import System.Exit (ExitCode (ExitSuccess))
#endif

resolveTrustedAppleToolchain :: FilePath -> IO TrustedResolverResult
#if defined(mingw32_HOST_OS)
resolveTrustedAppleToolchain _ = pure (TrustedResolverUnsupported "apple-silicon-required")
#else
resolveTrustedAppleToolchain effectiveHome = do
  protocol <- resolveNativeAppleToolchain effectiveHome
  pure (settleTrustedProtocol productionProtocolLayout effectiveHome protocol)
#endif

revalidateTrustedAppleToolchain :: TrustedAppleToolchain -> IO (Either String ())
revalidateTrustedAppleToolchain expected@(TrustedAppleToolchain effectiveHome _ _ _ _ _ _ _ _) = do
    observed <- resolveTrustedAppleToolchain effectiveHome
    pure (classifyTrustedAppleToolchainRevalidation expected observed)

classifyTrustedAppleToolchainRevalidation :: TrustedAppleToolchain -> TrustedResolverResult -> Either String ()
classifyTrustedAppleToolchainRevalidation expected observed = case observed of
    TrustedResolverReady actual
        | actual == expected -> Right ()
        | otherwise -> Left "trusted-apple-toolchain-changed"
    TrustedResolverMissingColima _ -> Left "trusted-colima-missing"
    TrustedResolverUnsupported reason -> Left reason

revalidateTrustedAppleBrew :: TrustedAppleBrew -> IO (Either String ())
revalidateTrustedAppleBrew expected@(TrustedAppleBrew effectiveHome _ _ _ _) = do
    observed <- resolveTrustedAppleToolchain effectiveHome
    pure (classifyTrustedAppleBrewRevalidation expected observed)

classifyTrustedAppleBrewRevalidation :: TrustedAppleBrew -> TrustedResolverResult -> Either String ()
classifyTrustedAppleBrewRevalidation expected observed = case observed of
    TrustedResolverMissingColima actual
        | actual == expected -> Right ()
        | otherwise -> Left "trusted-apple-brew-changed"
    TrustedResolverReady _ -> Left "trusted-colima-now-present"
    TrustedResolverUnsupported reason -> Left reason

-- Kept inside the Cabal-private component and re-exposed only through the
-- non-authorizing testing view.  Production resolution always executes the
-- closed resolver before reaching this settlement function.
settleTrustedResolverResultForTesting ::
    FilePath ->
    BoundedToolResult ->
    TrustedResolverResult
#if defined(mingw32_HOST_OS)
settleTrustedResolverResultForTesting _ _ = TrustedResolverUnsupported "apple-silicon-required"
#else
settleTrustedResolverResultForTesting = settleResolverResult
#endif

settleTrustedResolverFixtureResultForTesting ::
    FilePath ->
    FilePath ->
    BoundedToolResult ->
    TrustedResolverResult
#if defined(mingw32_HOST_OS)
settleTrustedResolverFixtureResultForTesting _ _ _ = TrustedResolverUnsupported "apple-silicon-required"
#else
settleTrustedResolverFixtureResultForTesting root =
  settleResolverResultWithParser (fixtureProtocolLayout root) (parseTrustedResolverOutputForFixtureRoot root)
#endif

-- The testing view observes this same native settlement without wire decoding.
settleTrustedResolverProtocolForFixtureTesting ::
  FilePath -> FilePath -> TrustedResolverProtocol -> TrustedResolverResult
#if defined(mingw32_HOST_OS)
settleTrustedResolverProtocolForFixtureTesting _ _ _ = TrustedResolverUnsupported "apple-silicon-required"
#else
settleTrustedResolverProtocolForFixtureTesting root = settleTrustedProtocol (fixtureProtocolLayout root)
#endif

#if !defined(mingw32_HOST_OS)
settleResolverResult :: FilePath -> BoundedToolResult -> TrustedResolverResult
settleResolverResult = settleResolverResultWithParser productionProtocolLayout parseTrustedResolverOutput

settleResolverResultWithParser ::
  ResolverProtocolLayout ->
  (String -> Either String TrustedResolverProtocol) ->
  FilePath ->
  BoundedToolResult ->
  TrustedResolverResult
settleResolverResultWithParser layout parseResult effectiveHome result =
  case result of
    BoundedToolTimedOut -> TrustedResolverUnsupported "resolver-timeout"
    BoundedToolFailed _ -> TrustedResolverUnsupported "resolver-execution-failed"
    BoundedToolCompleted exitCode output errors
      | exitCode /= ExitSuccess -> TrustedResolverUnsupported "resolver-exit-failure"
      | not (null errors) -> TrustedResolverUnsupported "resolver-stderr"
      | otherwise -> case parseResult output of
          Left reason -> TrustedResolverUnsupported reason
          Right protocol -> settleTrustedProtocol layout effectiveHome protocol

settleTrustedProtocol :: ResolverProtocolLayout -> FilePath -> TrustedResolverProtocol -> TrustedResolverResult
settleTrustedProtocol layout effectiveHome protocol =
  case validateTrustedProtocol layout protocol of
    Left reason -> TrustedResolverUnsupported reason
    Right () -> case protocol of
      ProtocolUnsupported reason -> TrustedResolverUnsupported reason
      ProtocolMissingColimaV2 (ResolvedTool brewPath brewIdentity) helperPath helperBindings ->
        TrustedResolverMissingColima
          (TrustedAppleBrew effectiveHome brewPath brewIdentity helperPath helperBindings)
      ProtocolReadyV2 (ResolvedTool colimaPath colimaIdentity) (ResolvedTool dockerPath dockerIdentity)
          (ResolvedTool limaPath limaIdentity) helperPath helperBindings ->
        TrustedResolverReady
          (TrustedAppleToolchain effectiveHome colimaPath colimaIdentity dockerPath dockerIdentity limaPath limaIdentity helperPath helperBindings)

#endif
