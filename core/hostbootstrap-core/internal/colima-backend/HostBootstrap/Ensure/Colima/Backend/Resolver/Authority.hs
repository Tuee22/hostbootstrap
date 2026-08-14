module HostBootstrap.Ensure.Colima.Backend.Resolver.Authority
  ( TrustedAppleToolchain (..),
    TrustedAppleBrew (..),
    TrustedResolverResult (..),
    trustedApplePythonPath,
    trustedAppleColimaPath,
    trustedAppleDockerPath,
    trustedAppleLimaPath,
    trustedAppleHelperPath,
    trustedAppleToolchainFingerprint,
    trustedAppleBrewPythonPath,
    trustedAppleBrewPath,
    trustedAppleBrewHelperPath,
  )
where

import HostBootstrap.Ensure.Colima.Backend.Resolver.Protocol
  ( TrustedDirectoryBinding,
    TrustedToolIdentity (..),
    trustedDirectoryBindingsFingerprint,
  )

data TrustedAppleToolchain = TrustedAppleToolchain
  !FilePath
  !FilePath
  !TrustedToolIdentity
  !FilePath
  !TrustedToolIdentity
  !FilePath
  !TrustedToolIdentity
  !FilePath
  !TrustedToolIdentity
  !String
  ![TrustedDirectoryBinding]
  deriving (Eq, Show)

data TrustedAppleBrew = TrustedAppleBrew
  !FilePath
  !FilePath
  !TrustedToolIdentity
  !FilePath
  !TrustedToolIdentity
  !String
  ![TrustedDirectoryBinding]
  deriving (Eq, Show)

data TrustedResolverResult
  = TrustedResolverReady TrustedAppleToolchain
  | TrustedResolverMissingColima TrustedAppleBrew
  | TrustedResolverUnsupported String
  deriving (Eq, Show)

trustedApplePythonPath :: TrustedAppleToolchain -> FilePath
trustedApplePythonPath (TrustedAppleToolchain _ path _ _ _ _ _ _ _ _ _) = path

trustedAppleColimaPath :: TrustedAppleToolchain -> FilePath
trustedAppleColimaPath (TrustedAppleToolchain _ _ _ path _ _ _ _ _ _ _) = path

trustedAppleDockerPath :: TrustedAppleToolchain -> FilePath
trustedAppleDockerPath (TrustedAppleToolchain _ _ _ _ _ path _ _ _ _ _) = path

trustedAppleLimaPath :: TrustedAppleToolchain -> FilePath
trustedAppleLimaPath (TrustedAppleToolchain _ _ _ _ _ _ _ path _ _ _) = path

trustedAppleHelperPath :: TrustedAppleToolchain -> String
trustedAppleHelperPath (TrustedAppleToolchain _ _ _ _ _ _ _ _ _ path _) = path

-- The netstring-framed fingerprint binds every executable and ordered helper
-- directory identity into durable origin provenance without exposing either
-- authority constructor through the private resolver facade.
trustedAppleToolchainFingerprint :: TrustedAppleToolchain -> String
trustedAppleToolchainFingerprint
  ( TrustedAppleToolchain
      effectiveHome
      pythonPath
      pythonIdentity
      colimaPath
      colimaIdentity
      dockerPath
      dockerIdentity
      limaPath
      limaIdentity
      helperPath
      helperBindings
    ) =
    concatMap fingerprintField
      ( ["trusted-apple-toolchain-v1", "effective-home", effectiveHome, "python", pythonPath]
          ++ identityFields pythonIdentity
          ++ ["colima", colimaPath]
          ++ identityFields colimaIdentity
          ++ ["docker", dockerPath]
          ++ identityFields dockerIdentity
          ++ ["lima", limaPath]
          ++ identityFields limaIdentity
          ++ ["helper-path", helperPath, "helper-directories", trustedDirectoryBindingsFingerprint helperBindings]
      )
  where
    identityFields (TrustedToolIdentity device inode) = [show device, show inode]

fingerprintField :: String -> String
fingerprintField value = show (length value) ++ ":" ++ value ++ ","

trustedAppleBrewPythonPath :: TrustedAppleBrew -> FilePath
trustedAppleBrewPythonPath (TrustedAppleBrew _ path _ _ _ _ _) = path

trustedAppleBrewPath :: TrustedAppleBrew -> FilePath
trustedAppleBrewPath (TrustedAppleBrew _ _ _ path _ _ _) = path

trustedAppleBrewHelperPath :: TrustedAppleBrew -> String
trustedAppleBrewHelperPath (TrustedAppleBrew _ _ _ _ _ path _) = path
