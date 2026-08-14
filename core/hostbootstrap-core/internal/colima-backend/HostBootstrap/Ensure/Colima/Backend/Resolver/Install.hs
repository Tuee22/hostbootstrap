module HostBootstrap.Ensure.Colima.Backend.Resolver.Install
  ( TrustedInstallActions (..),
    TrustedInstallResult (..),
    runTrustedInstallRediscovery,
  )
where

import HostBootstrap.Ensure.Colima.Backend.Resolver
  ( TrustedAppleToolchain,
    TrustedResolverResult (..),
  )
import HostBootstrap.Ensure.Colima.Backend.Runner
  ( BoundedToolResult (..),
  )
import System.Exit (ExitCode (ExitSuccess))

-- | The three ordered effects of installing a missing direct-Colima tool.
-- This constructor is confined to the Cabal-private backend component.  The
-- production adapter supplies only its retained Brew revalidation, closed
-- bounded runner, and fixed resolver; tests inject outcomes without creating
-- a public executor or toolchain authority path.
data TrustedInstallActions = TrustedInstallActions
  { trustedInstallRevalidateBrew :: IO (Either String ()),
    trustedInstallRunBrew :: IO BoundedToolResult,
    trustedInstallRediscover :: IO TrustedResolverResult
  }

data TrustedInstallResult
  = TrustedInstallReady TrustedAppleToolchain
  | TrustedInstallBrewChanged String
  | TrustedInstallExitFailure ExitCode String
  | TrustedInstallTimedOut
  | TrustedInstallExecutionFailed String
  | TrustedInstallStillMissing
  | TrustedInstallResolverUnsupported String

runTrustedInstallRediscovery :: TrustedInstallActions -> IO TrustedInstallResult
runTrustedInstallRediscovery actions = do
  unchanged <- trustedInstallRevalidateBrew actions
  case unchanged of
    Left reason -> pure (TrustedInstallBrewChanged reason)
    Right () -> do
      installed <- trustedInstallRunBrew actions
      case installed of
        BoundedToolCompleted ExitSuccess _ _ -> do
          refreshed <- trustedInstallRediscover actions
          pure $ case refreshed of
            TrustedResolverReady toolchain -> TrustedInstallReady toolchain
            TrustedResolverMissingColima _ -> TrustedInstallStillMissing
            TrustedResolverUnsupported reason -> TrustedInstallResolverUnsupported reason
        BoundedToolCompleted exitCode _ errors ->
          pure (TrustedInstallExitFailure exitCode errors)
        BoundedToolTimedOut -> pure TrustedInstallTimedOut
        BoundedToolFailed reason -> pure (TrustedInstallExecutionFailed reason)
