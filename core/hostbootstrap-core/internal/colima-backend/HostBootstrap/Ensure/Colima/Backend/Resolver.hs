{-# LANGUAGE CPP #-}

module HostBootstrap.Ensure.Colima.Backend.Resolver
  ( TrustedAppleToolchain,
    TrustedAppleBrew,
    TrustedToolIdentity,
    TrustedResolverResult
      ( TrustedResolverReady,
        TrustedResolverMissingColima,
        TrustedResolverUnsupported
    ),
    trustedApplePythonPath,
    trustedAppleColimaPath,
    trustedAppleDockerPath,
    trustedAppleLimaPath,
    trustedAppleHelperPath,
    trustedAppleToolchainFingerprint,
    trustedAppleBrewPythonPath,
    trustedAppleBrewPath,
    trustedAppleBrewHelperPath,
    resolveTrustedAppleToolchain,
    revalidateTrustedAppleToolchain,
    revalidateTrustedAppleBrew,
    settleTrustedResolverResultForTesting,
    settleTrustedResolverFixtureResultForTesting,
    currentTrustedResolverOverrideHomeForTesting,
  )
where

import HostBootstrap.Ensure.Colima.Backend.Resolver.Authority
  ( TrustedAppleBrew (..),
    TrustedAppleToolchain (..),
    TrustedResolverResult (..),
    trustedAppleBrewHelperPath,
    trustedAppleBrewPath,
    trustedAppleBrewPythonPath,
    trustedAppleColimaPath,
    trustedAppleDockerPath,
    trustedAppleHelperPath,
    trustedAppleLimaPath,
    trustedApplePythonPath,
    trustedAppleToolchainFingerprint,
  )
import HostBootstrap.Ensure.Colima.Backend.Resolver.Override
  ( ResolverOverride (..),
    currentResolverOverride,
  )
import HostBootstrap.Ensure.Colima.Backend.Resolver.Protocol (TrustedToolIdentity (..))
import HostBootstrap.Ensure.Colima.Backend.Resolver.Native (resolveNativeAppleToolchain)
import HostBootstrap.Ensure.Colima.Backend.Runner (BoundedToolResult (..))
#if !defined(mingw32_HOST_OS)
import HostBootstrap.Ensure.Colima.Backend.Resolver.Protocol
  ( ResolvedTool (..),
    TrustedResolverProtocol (..),
    parseTrustedResolverOutput,
    parseTrustedResolverOutputForFixtureRoot,
  )
import Control.Exception (IOException, bracket, try)
import Control.Monad (unless)
import System.Exit (ExitCode (ExitSuccess))
import System.Posix.Files
  ( FileStatus,
    deviceID,
    fileID,
    fileMode,
    fileOwner,
    getFdStatus,
    groupExecuteMode,
    groupWriteMode,
    intersectFileModes,
    isDirectory,
    isRegularFile,
    nullFileMode,
    otherExecuteMode,
    otherWriteMode,
    ownerExecuteMode,
    unionFileModes,
  )
import System.Posix.IO
  ( OpenFileFlags (..),
    OpenMode (ReadOnly),
    closeFd,
    defaultFileFlags,
    openFd,
    openFdAt,
  )
import System.Posix.Types (FileMode)
#endif

resolveTrustedAppleToolchain :: FilePath -> IO TrustedResolverResult
#if defined(mingw32_HOST_OS)
resolveTrustedAppleToolchain _ = pure (TrustedResolverUnsupported "apple-silicon-required")
#else
resolveTrustedAppleToolchain effectiveHome = do
  override <- currentResolverOverride
  case override of
    Just fixture
      | resolverOverrideHome fixture /= effectiveHome ->
          pure (TrustedResolverUnsupported "resolver-override-home")
      | otherwise -> do
          result <- resolverOverrideExecution fixture
          pure
            ( settleTrustedResolverFixtureResultForTesting
                (resolverOverrideRoot fixture)
                effectiveHome
                (TrustedToolIdentity (resolverOverrideBootstrapDevice fixture) (resolverOverrideBootstrapInode fixture))
                result
            )
    Nothing -> do
      bootstrap <- validateBootstrapPython
      case bootstrap of
        Left reason -> pure (TrustedResolverUnsupported reason)
        Right bootstrapIdentity -> do
          protocol <- resolveNativeAppleToolchain effectiveHome
          pure (settleTrustedProtocol effectiveHome bootstrapIdentity protocol)
#endif

currentTrustedResolverOverrideHomeForTesting :: IO (Maybe FilePath)
currentTrustedResolverOverrideHomeForTesting =
  fmap resolverOverrideHome <$> currentResolverOverride

revalidateTrustedAppleToolchain :: TrustedAppleToolchain -> IO (Either String ())
revalidateTrustedAppleToolchain expected@(TrustedAppleToolchain effectiveHome _ _ _ _ _ _ _ _ _ _) = do
  observed <- resolveTrustedAppleToolchain effectiveHome
  pure $ case observed of
    TrustedResolverReady actual
      | actual == expected -> Right ()
      | otherwise -> Left "trusted-apple-toolchain-changed"
    TrustedResolverMissingColima _ -> Left "trusted-colima-missing"
    TrustedResolverUnsupported reason -> Left reason

revalidateTrustedAppleBrew :: TrustedAppleBrew -> IO (Either String ())
revalidateTrustedAppleBrew expected@(TrustedAppleBrew effectiveHome _ _ _ _ _ _) = do
  observed <- resolveTrustedAppleToolchain effectiveHome
  pure $ case observed of
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
  TrustedToolIdentity ->
  BoundedToolResult ->
  TrustedResolverResult
#if defined(mingw32_HOST_OS)
settleTrustedResolverResultForTesting _ _ _ = TrustedResolverUnsupported "apple-silicon-required"
#else
settleTrustedResolverResultForTesting = settleResolverResult
#endif

settleTrustedResolverFixtureResultForTesting ::
  FilePath ->
  FilePath ->
  TrustedToolIdentity ->
  BoundedToolResult ->
  TrustedResolverResult
#if defined(mingw32_HOST_OS)
settleTrustedResolverFixtureResultForTesting _ _ _ _ = TrustedResolverUnsupported "apple-silicon-required"
#else
settleTrustedResolverFixtureResultForTesting root =
  settleResolverResultWithParser (parseTrustedResolverOutputForFixtureRoot root)
#endif

#if !defined(mingw32_HOST_OS)
settleResolverResult :: FilePath -> TrustedToolIdentity -> BoundedToolResult -> TrustedResolverResult
settleResolverResult = settleResolverResultWithParser parseTrustedResolverOutput

settleResolverResultWithParser ::
  (String -> Either String TrustedResolverProtocol) ->
  FilePath ->
  TrustedToolIdentity ->
  BoundedToolResult ->
  TrustedResolverResult
settleResolverResultWithParser parseResult effectiveHome bootstrapIdentity result =
  case result of
    BoundedToolTimedOut -> TrustedResolverUnsupported "resolver-timeout"
    BoundedToolFailed _ -> TrustedResolverUnsupported "resolver-execution-failed"
    BoundedToolCompleted exitCode output errors
      | exitCode /= ExitSuccess -> TrustedResolverUnsupported "resolver-exit-failure"
      | not (null errors) -> TrustedResolverUnsupported "resolver-stderr"
      | otherwise -> case parseResult output of
          Left reason -> TrustedResolverUnsupported reason
          Right protocol -> settleTrustedProtocol effectiveHome bootstrapIdentity protocol

settleTrustedProtocol :: FilePath -> TrustedToolIdentity -> TrustedResolverProtocol -> TrustedResolverResult
settleTrustedProtocol effectiveHome bootstrapIdentity protocol =
  case protocol of
    ProtocolUnsupported reason -> TrustedResolverUnsupported reason
    ProtocolMissingColima
      (ResolvedTool pythonPath pythonIdentity)
      (ResolvedTool brewPath brewIdentity)
      helperPath
      helperBindings
        | pythonIdentity /= bootstrapIdentity -> TrustedResolverUnsupported "resolver-python-identity"
        | otherwise ->
            TrustedResolverMissingColima
              ( TrustedAppleBrew
                  effectiveHome
                  pythonPath
                  pythonIdentity
                  brewPath
                  brewIdentity
                  helperPath
                  helperBindings
              )
    ProtocolReady
      (ResolvedTool pythonPath pythonIdentity)
      (ResolvedTool colimaPath colimaIdentity)
      (ResolvedTool dockerPath dockerIdentity)
      (ResolvedTool limaPath limaIdentity)
      helperPath
      helperBindings
        | pythonIdentity /= bootstrapIdentity -> TrustedResolverUnsupported "resolver-python-identity"
        | otherwise ->
            TrustedResolverReady
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
              )

validateBootstrapPython :: IO (Either String TrustedToolIdentity)
validateBootstrapPython = do
  attempted <- try inspectBootstrapPython :: IO (Either IOException TrustedToolIdentity)
  pure $ case attempted of
    Left _ -> Left "bootstrap-python-invalid"
    Right identity -> Right identity

inspectBootstrapPython :: IO TrustedToolIdentity
inspectBootstrapPython =
  bracket (openFd "/" ReadOnly directoryOpenFlags) closeFd $ \rootFd -> do
    validateSystemDirectory =<< getFdStatus rootFd
    bracket (openFdAt (Just rootFd) "usr" ReadOnly directoryOpenFlags) closeFd $ \usrFd -> do
      validateSystemDirectory =<< getFdStatus usrFd
      bracket (openFdAt (Just usrFd) "bin" ReadOnly directoryOpenFlags) closeFd $ \binFd -> do
        validateSystemDirectory =<< getFdStatus binFd
        bracket (openFdAt (Just binFd) "python3" ReadOnly fileOpenFlags) closeFd $ \pythonFd -> do
          status <- getFdStatus pythonFd
          validateSystemExecutable status
          pure
            ( TrustedToolIdentity
                (fromIntegral (deviceID status))
                (fromIntegral (fileID status))
            )

directoryOpenFlags :: OpenFileFlags
directoryOpenFlags =
  defaultFileFlags
    { nofollow = True,
      cloexec = True,
      directory = True
    }

fileOpenFlags :: OpenFileFlags
fileOpenFlags =
  defaultFileFlags
    { nofollow = True,
      cloexec = True
    }

validateSystemDirectory :: FileStatus -> IO ()
validateSystemDirectory status = do
  unless (isDirectory status) (ioError (userError "bootstrap-directory-type"))
  unless (fileOwner status == 0) (ioError (userError "bootstrap-directory-owner"))
  unless (not (hasMode status groupWriteMode) && not (hasMode status otherWriteMode)) $
    ioError (userError "bootstrap-directory-mode")

validateSystemExecutable :: FileStatus -> IO ()
validateSystemExecutable status = do
  unless (isRegularFile status) (ioError (userError "bootstrap-executable-type"))
  unless (fileOwner status == 0) (ioError (userError "bootstrap-executable-owner"))
  unless (not (hasMode status groupWriteMode) && not (hasMode status otherWriteMode)) $
    ioError (userError "bootstrap-executable-write-mode")
  unless (hasMode status executableModes) (ioError (userError "bootstrap-executable-mode"))

hasMode :: FileStatus -> FileMode -> Bool
hasMode status mode = intersectFileModes (fileMode status) mode /= nullFileMode

executableModes :: FileMode
executableModes = ownerExecuteMode `unionFileModes` groupExecuteMode `unionFileModes` otherExecuteMode
#endif
