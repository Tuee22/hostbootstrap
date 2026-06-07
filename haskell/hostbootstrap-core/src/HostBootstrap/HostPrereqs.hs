-- | Fail-fast host-minimum checks.
--
-- These are the typed host minimums dispatched by substrate, ported from the
-- Python @python/hostbootstrap/prereqs.py@. Each check is fail-fast: it returns a
-- one-line 'PrereqError' the moment a minimum is unmet. The pure-Python
-- @prereqs.py@ remains the live implementation until Phase 6 reclaims the
-- residual subset into the thin bootstrapper.
--
-- All external tools are invoked through their resolved absolute 'AbsExe' paths
-- from 'HostConfig'; nothing here runs a @$PATH@-resolved bare name.
module HostBootstrap.HostPrereqs
  ( PrereqError (..),
    renderPrereqError,
    checkHostMinimums,
    parseOsRelease,
    isUbuntu2404,
  )
where

import Control.Exception (SomeException)
import Control.Exception.Safe (try)
import Data.List (isInfixOf)
import HostBootstrap.HostConfig (HostConfig (..), resolveMaybe)
import HostBootstrap.HostTool
  ( AbsExe,
    HostTool (..),
    absExePath,
  )
import HostBootstrap.Substrate
  ( Substrate (..),
    SubstrateName (..),
  )
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.Posix.User (getEffectiveUserID)
import System.Process (readProcessWithExitCode)

-- | A host prerequisite is missing or misconfigured.
newtype PrereqError = PrereqError String
  deriving (Eq, Show)

renderPrereqError :: PrereqError -> String
renderPrereqError (PrereqError msg) = msg

-- | Run the fail-fast minimums for the configured substrate. Returns the list
-- of @OK@ messages on success, or the first 'PrereqError' on failure.
checkHostMinimums :: HostConfig -> IO (Either PrereqError [String])
checkHostMinimums cfg =
  runChecks $ case substrateName (hcSubstrate cfg) of
    AppleSilicon ->
      [ ("apple-silicon (arm64)", checkAppleSubstrate cfg),
        ("Xcode Command Line Tools", checkXcodeClt cfg),
        ("passwordless sudo", checkPasswordlessSudo cfg),
        ("Homebrew", checkHomebrew cfg),
        ("Docker daemon reachable", checkDockerReachable cfg)
      ]
    LinuxCpu -> linuxChecks
    LinuxGpu -> linuxChecks ++ [("NVIDIA container runtime", checkNvidiaRuntime cfg)]
  where
    linuxChecks =
      [ ("Ubuntu 24.04", checkUbuntu2404),
        ("passwordless sudo", checkPasswordlessSudo cfg),
        ("Docker daemon reachable", checkDockerReachable cfg)
      ]

-- | Run labelled checks in order, stopping at the first failure (fail-fast).
runChecks :: [(String, IO (Either PrereqError ()))] -> IO (Either PrereqError [String])
runChecks = go []
  where
    go acc [] = pure (Right (reverse acc))
    go acc ((label, check) : rest) = do
      result <- check
      case result of
        Left err -> pure (Left err)
        Right () -> go ((label ++ ": OK") : acc) rest

-- ---------------------------------------------------------------------------
-- Individual checks
-- ---------------------------------------------------------------------------

checkAppleSubstrate :: HostConfig -> IO (Either PrereqError ())
checkAppleSubstrate cfg =
  pure $ case substrateName (hcSubstrate cfg) of
    AppleSilicon -> Right ()
    _ -> Left (PrereqError "apple-silicon prereqs invoked on a non-Apple host")

checkPasswordlessSudo :: HostConfig -> IO (Either PrereqError ())
checkPasswordlessSudo cfg = do
  euid <- getEffectiveUserID
  if euid == 0
    then pure (Right ())
    else case resolveMaybe cfg Sudo of
      Nothing -> pure (Left (PrereqError "sudo is required but not installed"))
      Just sudo -> do
        result <- runTool sudo ["-n", "true"]
        pure $ case result of
          Right (ExitSuccess, _, _) -> Right ()
          Right _ ->
            Left
              ( PrereqError
                  "passwordless sudo is required. Add a NOPASSWD entry for your user in /etc/sudoers.d/ before re-running."
              )
          Left err -> Left err

checkDockerReachable :: HostConfig -> IO (Either PrereqError ())
checkDockerReachable cfg = case resolveMaybe cfg Docker of
  Nothing -> pure (Left (PrereqError "docker CLI not found; install Docker and retry"))
  Just docker -> do
    result <- runTool docker ["info"]
    pure $ case result of
      Right (ExitSuccess, _, _) -> Right ()
      Right _ ->
        Left
          ( PrereqError
              "docker daemon is not reachable. Start Docker Desktop, Colima, or dockerd and retry."
          )
      Left err -> Left err

checkUbuntu2404 :: IO (Either PrereqError ())
checkUbuntu2404 = do
  let osRelease = "/etc/os-release"
  exists <- doesFileExist osRelease
  if not exists
    then pure (Left (PrereqError "cannot read /etc/os-release; Linux substrates require Ubuntu 24.04"))
    else do
      contents <- readFile osRelease
      pure $
        if isUbuntu2404 contents
          then Right ()
          else Left (PrereqError "Linux substrates require Ubuntu 24.04")

checkXcodeClt :: HostConfig -> IO (Either PrereqError ())
checkXcodeClt cfg = case resolveMaybe cfg XcodeSelect of
  Nothing ->
    pure
      ( Left
          (PrereqError "Xcode Command Line Tools are required. Install with: xcode-select --install")
      )
  Just xcode -> do
    result <- runTool xcode ["-p"]
    pure $ case result of
      Right (ExitSuccess, out, _)
        | not (null (trim out)) -> Right ()
      Right _ ->
        Left (PrereqError "Xcode Command Line Tools are required. Install with: xcode-select --install")
      Left err -> Left err

checkHomebrew :: HostConfig -> IO (Either PrereqError ())
checkHomebrew cfg =
  pure $ case resolveMaybe cfg Brew of
    Just _ -> Right ()
    Nothing -> Left (PrereqError "Homebrew is required on apple-silicon. Install from https://brew.sh.")

checkNvidiaRuntime :: HostConfig -> IO (Either PrereqError ())
checkNvidiaRuntime cfg = case resolveMaybe cfg NvidiaSmi of
  Nothing -> pure (Left (PrereqError "nvidia-smi not found; install the NVIDIA driver"))
  Just _ -> case resolveMaybe cfg Docker of
    Nothing -> pure (Right ())
    Just docker -> do
      result <- runTool docker ["info", "--format", "{{json .Runtimes}}"]
      pure $ case result of
        Right (_, out, _)
          | "nvidia" `isInfixOf` out -> Right ()
        Right _ ->
          Left
            ( PrereqError
                "NVIDIA container toolkit is not registered with Docker. Install nvidia-container-toolkit and re-configure dockerd."
            )
        Left err -> Left err

-- ---------------------------------------------------------------------------
-- /etc/os-release parsing (pure)
-- ---------------------------------------------------------------------------

-- | Parse @KEY=VALUE@ lines, stripping surrounding double quotes from values.
parseOsRelease :: String -> [(String, String)]
parseOsRelease = concatMap parseLine . lines
  where
    parseLine l = case break (== '=') l of
      (key, '=' : value) -> [(key, stripQuotes value)]
      _ -> []
    stripQuotes v = case v of
      ('"' : rest) -> takeWhile (/= '"') rest
      _ -> v

-- | Whether @/etc/os-release@ content describes Ubuntu 24.04.
isUbuntu2404 :: String -> Bool
isUbuntu2404 contents =
  lookup "ID" fields == Just "ubuntu" && lookup "VERSION_ID" fields == Just "24.04"
  where
    fields = parseOsRelease contents

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

runTool :: AbsExe -> [String] -> IO (Either PrereqError (ExitCode, String, String))
runTool exe args = do
  result <- try (readProcessWithExitCode (absExePath exe) args "")
  pure $ case (result :: Either SomeException (ExitCode, String, String)) of
    Right ok -> Right ok
    Left err -> Left (PrereqError ("could not exec " ++ absExePath exe ++ ": " ++ show err))

trim :: String -> String
trim = f . f where f = reverse . dropWhile (`elem` (" \t\r\n" :: String))
