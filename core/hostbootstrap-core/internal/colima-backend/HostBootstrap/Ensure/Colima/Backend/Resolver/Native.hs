{-# LANGUAGE CPP #-}

module HostBootstrap.Ensure.Colima.Backend.Resolver.Native
  ( resolveNativeAppleToolchain,
    resolveNativeResolverFixture,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (foldM)
import Data.List (nub)
import Data.Word (Word64)
import HostBootstrap.Ensure.Colima.Backend.Resolver.Protocol
  ( ResolvedTool (..),
    TrustedDirectoryBinding (..),
    TrustedResolverProtocol (..),
    TrustedToolIdentity (..),
    renderSearchPath,
    systemHelperDirectories,
  )
import System.FilePath (isAbsolute, splitDirectories, takeDirectory, takeFileName, (</>))
import System.Info (arch, os)
#if !defined(mingw32_HOST_OS)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files
  ( FileStatus,
    deviceID,
    fileID,
    fileMode,
    fileOwner,
    getSymbolicLinkStatus,
    groupWriteMode,
    intersectFileModes,
    isDirectory,
    isRegularFile,
    isSymbolicLink,
    nullFileMode,
    otherWriteMode,
    ownerExecuteMode,
    groupExecuteMode,
    otherExecuteMode,
    readSymbolicLink,
    unionFileModes,
  )
import System.Posix.User (getEffectiveUserID)
import qualified System.Posix.Types
#endif

data ResolverLayout = ResolverLayout
  { layoutRoot :: FilePath,
    layoutPython :: FilePath,
    layoutBrew :: FilePath,
    layoutColima :: FilePath,
    layoutLima :: FilePath,
    layoutDockerBrew :: FilePath,
    layoutDockerApp :: FilePath,
    layoutHelpers :: [FilePath],
    layoutHomebrew :: FilePath,
    layoutApplications :: FilePath,
    layoutUsers :: FilePath,
    layoutFixture :: Bool
  }

resolveNativeAppleToolchain :: FilePath -> IO TrustedResolverProtocol
resolveNativeAppleToolchain home
  | os /= "darwin" || arch /= "aarch64" = pure (ProtocolUnsupported "apple-silicon-required")
  | otherwise = resolve productionLayout home

resolveNativeResolverFixture :: FilePath -> FilePath -> IO TrustedResolverProtocol
resolveNativeResolverFixture root = resolve (fixtureLayout root)

productionLayout :: ResolverLayout
productionLayout =
  ResolverLayout
    "/"
    "/usr/bin/python3"
    "/opt/homebrew/bin/brew"
    "/opt/homebrew/bin/colima"
    "/opt/homebrew/bin/limactl"
    "/opt/homebrew/bin/docker"
    "/Applications/Docker.app/Contents/Resources/bin/docker"
    systemHelperDirectories
    "/opt/homebrew"
    "/Applications"
    "/Users"
    False

fixtureLayout :: FilePath -> ResolverLayout
fixtureLayout root =
  let homebrew = root </> "opt" </> "homebrew"
   in ResolverLayout
        root
        (root </> "usr" </> "bin" </> "python3")
        (homebrew </> "bin" </> "brew")
        (homebrew </> "bin" </> "colima")
        (homebrew </> "bin" </> "limactl")
        (homebrew </> "bin" </> "docker")
        (root </> "Applications" </> "Docker.app" </> "Contents" </> "Resources" </> "bin" </> "docker")
        [root </> "usr" </> "bin", root </> "bin", root </> "usr" </> "sbin", root </> "sbin"]
        homebrew
        (root </> "Applications")
        (root </> "Users")
        True

resolve :: ResolverLayout -> FilePath -> IO TrustedResolverProtocol
#if defined(mingw32_HOST_OS)
resolve _ _ = pure (ProtocolUnsupported "apple-silicon-required")
#else
resolve layout home = do
  user <- getEffectiveUserID
  attempted <- try (resolveChecked layout (fromIntegral user) home) :: IO (Either IOException (Either String TrustedResolverProtocol))
  pure $ case attempted of
    Left _ -> ProtocolUnsupported "resolver-system-error"
    Right (Left refusal) -> ProtocolUnsupported refusal
    Right (Right protocol) -> protocol
#endif

#if !defined(mingw32_HOST_OS)
resolveChecked :: ResolverLayout -> Word64 -> FilePath -> IO (Either String TrustedResolverProtocol)
resolveChecked layout user home = do
  validHome <- validateHome layout user home
  case validHome of
    Left refusal -> pure (Left refusal)
    Right () -> do
      python <- inspectCandidate layout user False False (layoutPython layout)
      case python of
        Left refusal -> pure (Left refusal)
        Right Nothing -> pure (Left "candidate-missing")
        Right (Just pythonTool)
          | resolvedPath pythonTool /= layoutPython layout -> pure (Left "python-canonical")
          | otherwise -> resolveColima layout user pythonTool

resolveColima :: ResolverLayout -> Word64 -> ResolvedTool -> IO (Either String TrustedResolverProtocol)
resolveColima layout user python = do
  colima <- inspectCandidate layout user True True (layoutColima layout)
  case colima of
    Left refusal -> pure (Left refusal)
    Right Nothing -> do
      brew <- inspectCandidate layout user False False (layoutBrew layout)
      case brew of
        Left refusal -> pure (Left refusal)
        Right Nothing -> pure (Left "candidate-missing")
        Right (Just brewTool)
          | resolvedPath brewTool /= layoutBrew layout -> pure (Left "brew-canonical")
          | otherwise -> do
              helpers <- helperBindings layout user ((layoutHomebrew layout </> "bin") : layoutHelpers layout)
              pure (ProtocolMissingColima python brewTool <$> fst helpers <*> snd helpers)
    Right (Just colimaTool) -> case requireFormula layout "colima" "colima" colimaTool of
      Left refusal -> pure (Left refusal)
      Right () -> resolveReady layout user python colimaTool

resolveReady :: ResolverLayout -> Word64 -> ResolvedTool -> ResolvedTool -> IO (Either String TrustedResolverProtocol)
resolveReady layout user python colima = do
  lima <- inspectCandidate layout user False True (layoutLima layout)
  case lima >>= requirePresent "candidate-missing" of
    Left refusal -> pure (Left refusal)
    Right limaTool -> case requireFormula layout "lima" "limactl" limaTool of
      Left refusal -> pure (Left refusal)
      Right () -> do
        dockerBrew <- inspectCandidate layout user True True (layoutDockerBrew layout)
        docker <- case dockerBrew of
          Left refusal -> pure (Left refusal)
          Right (Just tool) -> pure (tool <$ requireFormula layout "docker" "docker" tool)
          Right Nothing -> inspectCandidate layout user True False (layoutDockerApp layout) >>= pure . (>>= requirePresent "docker-missing")
        case docker of
          Left refusal -> pure (Left refusal)
          Right dockerTool -> do
            helpers <- helperBindings layout user ([takeDirectory (resolvedPath colima), takeDirectory (resolvedPath limaTool), takeDirectory (resolvedPath dockerTool), layoutHomebrew layout </> "bin"] ++ layoutHelpers layout)
            pure (ProtocolReady python colima dockerTool limaTool <$> fst helpers <*> snd helpers)

requirePresent :: String -> Maybe value -> Either String value
requirePresent refusal = maybe (Left refusal) Right

resolvedPath :: ResolvedTool -> FilePath
resolvedPath (ResolvedTool path _) = path

inspectCandidate :: ResolverLayout -> Word64 -> Bool -> Bool -> FilePath -> IO (Either String (Maybe ResolvedTool))
inspectCandidate layout user allowMissing allowLink candidate = do
  named <- statusMaybe candidate
  case named of
    Left refusal -> pure (Left refusal)
    Right Nothing | allowMissing -> pure (Right Nothing)
    Right Nothing -> pure (Left "candidate-missing")
    Right (Just entry) -> do
      canonical <-
        if isSymbolicLink entry
          then if not allowLink
            then pure (Left "candidate-symlink")
            else if fileOwner entry /= fromIntegral user
              then pure (Left "symlink-owner")
              else do
                target <- readSymbolicLink candidate
                pure (canonicalTarget candidate target)
          else if isRegularFile entry then pure (Right candidate) else pure (Left "candidate-type")
      case canonical of
        Left refusal -> pure (Left refusal)
        Right path -> validateExecutable layout user path

canonicalTarget :: FilePath -> FilePath -> Either String FilePath
canonicalTarget source target =
  canonicalAbsolute (if isAbsolute target then target else takeDirectory source </> target)

canonicalAbsolute :: FilePath -> Either String FilePath
canonicalAbsolute path
  | not (isAbsolute path) || any (`elem` "\NUL\t\r\n") path = Left "symlink-target"
  | otherwise = do
      segments <- foldM step [] (filter (`notElem` ["", "/", "."]) (splitDirectories path))
      pure (foldl (</>) "/" segments)
  where
    step [] ".." = Left "symlink-target"
    step segments ".." = Right (init segments)
    step segments segment = Right (segments ++ [segment])

validateExecutable :: ResolverLayout -> Word64 -> FilePath -> IO (Either String (Maybe ResolvedTool))
validateExecutable layout user path = do
  directories <- validateDirectoryChain layout user (takeDirectory path)
  case directories of
    Left refusal -> pure (Left refusal)
    Right () -> do
      observed <- statusMaybe path
      pure $ do
        status <- observed >>= requirePresent "candidate-dangling"
        if not (isRegularFile status) then Left "executable-type"
        else if not (admittedOwner layout user path (fromIntegral (fileOwner status))) then Left "executable-owner"
        else if hasMode status groupWriteMode || hasMode status otherWriteMode then Left "executable-write-mode"
        else if not (hasMode status executableModes) then Left "executable-mode"
        else Right (Just (ResolvedTool path (identity status)))

validateHome :: ResolverLayout -> Word64 -> FilePath -> IO (Either String ())
validateHome layout user home
  | not (validAbsolute home) = pure (Left "home-path")
  | takeDirectory home /= layoutUsers layout || takeFileName home `elem` ["", ".", ".."] = pure (Left "home-shape")
  | otherwise = validateDirectoryChain layout user home

validateDirectoryChain :: ResolverLayout -> Word64 -> FilePath -> IO (Either String ())
validateDirectoryChain layout user target
  | not (withinRoot (layoutRoot layout) target) = pure (Left "directory-root")
  | otherwise = foldM step (Right ()) (pathPrefixes (layoutRoot layout) target)
  where
    step (Left refusal) _ = pure (Left refusal)
    step (Right ()) path = do
      observed <- statusMaybe path
      pure $ do
        status <- observed >>= requirePresent "candidate-parent-missing"
        if not (isDirectory status) then Left "directory-type"
        else if not (admittedDirectoryOwner layout user path (fromIntegral (fileOwner status))) then Left "directory-owner"
        else if hasMode status otherWriteMode then Left "directory-world-write"
        else if hasMode status groupWriteMode && path `notElem` administrativeDirectories layout
          then Left (groupWriteRefusal layout path)
        else Right ()

groupWriteRefusal :: ResolverLayout -> FilePath -> String
groupWriteRefusal layout path
  | layoutFixture layout = "directory-group-write"
  | (layoutUsers layout ++ "/") `prefixOf` path = "directory-group-write-user"
  | layoutHomebrew layout `prefixOf` path = "directory-group-write-homebrew"
  | otherwise = "directory-group-write-system"

helperBindings :: ResolverLayout -> Word64 -> [FilePath] -> IO (Either String String, Either String [TrustedDirectoryBinding])
helperBindings layout user paths = do
  bindings <- traverse bind (nub paths)
  let combined = sequence bindings
  pure (renderSearchPath . map bindingPath <$> combined, combined)
  where
    bind path = do
      valid <- validateDirectoryChain layout user path
      case valid of
        Left refusal -> pure (Left refusal)
        Right () -> do
          status <- getSymbolicLinkStatus path
          pure (Right (TrustedDirectoryBinding path (identity status)))
    bindingPath (TrustedDirectoryBinding path _) = path

requireFormula :: ResolverLayout -> String -> FilePath -> ResolvedTool -> Either String ()
requireFormula layout formula binary tool =
  let prefix = layoutHomebrew layout </> "Cellar" </> formula
      relative = drop (length prefix + 1) (resolvedPath tool)
      parts = splitDirectories relative
   in if not ((prefix ++ "/") `prefixOf` resolvedPath tool) then Left (formula ++ "-formula-root")
      else case parts of
        [version, "bin", observed] | not (null version), observed == binary, version `notElem` [".", ".."], all (`notElem` "\t\r\n") version -> Right ()
        [_, _, _] -> Left (formula ++ "-formula-shape")
        _ -> Left (formula ++ "-formula-shape")

prefixOf :: String -> String -> Bool
prefixOf prefix value = take (length prefix) value == prefix

statusMaybe :: FilePath -> IO (Either String (Maybe FileStatus))
statusMaybe path = do
  attempted <- try (getSymbolicLinkStatus path) :: IO (Either IOException FileStatus)
  pure $ case attempted of
    Left failure | isDoesNotExistError failure -> Right Nothing
    Left _ -> Left "resolver-system-error"
    Right status -> Right (Just status)

identity :: FileStatus -> TrustedToolIdentity
identity status = TrustedToolIdentity (fromIntegral (deviceID status)) (fromIntegral (fileID status))

hasMode :: FileStatus -> System.Posix.Types.FileMode -> Bool
hasMode status mode = intersectFileModes (fileMode status) mode /= nullFileMode

executableModes :: System.Posix.Types.FileMode
executableModes = ownerExecuteMode `unionFileModes` groupExecuteMode `unionFileModes` otherExecuteMode

admittedOwner :: ResolverLayout -> Word64 -> FilePath -> Word64 -> Bool
admittedOwner layout user path owner
  | layoutFixture layout = owner == user
  | layoutHomebrew layout `prefixOf` path = owner == user
  | layoutApplications layout `prefixOf` path = owner == 0 || owner == user
  | otherwise = owner == 0

admittedDirectoryOwner :: ResolverLayout -> Word64 -> FilePath -> Word64 -> Bool
admittedDirectoryOwner layout user path owner
  | layoutFixture layout = owner == user
  | path == "/" || path == "/opt" || path == layoutApplications layout || path == layoutUsers layout = owner == 0
  | layoutHomebrew layout `prefixOf` path = owner == user
  | (layoutUsers layout ++ "/") `prefixOf` path = owner == user
  | otherwise = owner == 0

administrativeDirectories :: ResolverLayout -> [FilePath]
administrativeDirectories layout =
  [ layoutHomebrew layout,
    layoutHomebrew layout </> "bin",
    layoutHomebrew layout </> "Cellar",
    layoutHomebrew layout </> "opt",
    layoutApplications layout
  ]

withinRoot :: FilePath -> FilePath -> Bool
withinRoot root path = root == "/" || path == root || (root ++ "/") `prefixOf` path

pathPrefixes :: FilePath -> FilePath -> [FilePath]
pathPrefixes root target
  | root == "/" = scanl (</>) "/" (filter (`notElem` ["", "/"]) (splitDirectories target))
  | target == root = [root]
  | otherwise = scanl (</>) root (splitDirectories (drop (length root + 1) target))

validAbsolute :: FilePath -> Bool
validAbsolute path = canonicalAbsolute path == Right path
#endif
