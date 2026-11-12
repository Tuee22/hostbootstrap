{-# LANGUAGE CPP #-}

module HostBootstrap.Ensure.Colima.Backend.Resolver.Native (
    resolveNativeAppleToolchain,
    resolveNativeResolverFixture,
    ResolverPolicyKind (..),
    resolverOwnerModePolicy,
)
where

import Data.Bits ((.&.))
import Data.List (isPrefixOf)
import Data.Word (Word64)
import qualified System.FilePath.Posix as Posix
import HostBootstrap.Ensure.Colima.Backend.Resolver.Protocol (TrustedResolverProtocol (..))

#if defined(mingw32_HOST_OS)
resolveNativeAppleToolchain :: FilePath -> IO TrustedResolverProtocol
resolveNativeAppleToolchain _ = pure (ProtocolUnsupported "apple-silicon-required")

resolveNativeResolverFixture :: FilePath -> FilePath -> IO TrustedResolverProtocol
resolveNativeResolverFixture _ _ = pure (ProtocolUnsupported "apple-silicon-required")
#else
import Control.Exception (IOException, bracket, try)
import Control.Monad (foldM)
import Data.List (nub)
import HostBootstrap.Ensure.Colima.Backend.Resolver.Protocol
  ( ResolvedTool (..),
    TrustedDirectoryBinding (..),
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
    getFdStatus,
    getSymbolicLinkStatus,
    isDirectory,
    isRegularFile,
    isSymbolicLink,
    readSymbolicLink,
  )
import qualified System.Posix.IO as PosixIO
import System.Posix.User (getEffectiveUserID)
#endif

data ResolverLayout = ResolverLayout
  { layoutRoot :: FilePath,
    layoutBrew :: FilePath,
    layoutColima :: FilePath,
    layoutLima :: FilePath,
    layoutDockerBrew :: FilePath,
    layoutDockerApp :: FilePath,
    layoutHelpers :: [FilePath],
    layoutHomebrew :: FilePath,
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
    "/opt/homebrew/bin/brew"
    "/opt/homebrew/bin/colima"
    "/opt/homebrew/bin/limactl"
    "/opt/homebrew/bin/docker"
    "/Applications/Docker.app/Contents/Resources/bin/docker"
    systemHelperDirectories
    "/opt/homebrew"
    "/Users"
    False

fixtureLayout :: FilePath -> ResolverLayout
fixtureLayout root =
  let homebrew = root </> "opt" </> "homebrew"
   in ResolverLayout
        root
        (homebrew </> "bin" </> "brew")
        (homebrew </> "bin" </> "colima")
        (homebrew </> "bin" </> "limactl")
        (homebrew </> "bin" </> "docker")
        (root </> "Applications" </> "Docker.app" </> "Contents" </> "Resources" </> "bin" </> "docker")
        [root </> "usr" </> "bin", root </> "bin", root </> "usr" </> "sbin", root </> "sbin"]
        homebrew
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
    Right () -> resolveColima layout user

resolveColima :: ResolverLayout -> Word64 -> IO (Either String TrustedResolverProtocol)
resolveColima layout user = do
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
              pure (ProtocolMissingColimaV2 brewTool <$> fst helpers <*> snd helpers)
    Right (Just colimaTool) -> case requireFormula layout "colima" "colima" colimaTool of
      Left refusal -> pure (Left refusal)
      Right () -> resolveReady layout user colimaTool

resolveReady :: ResolverLayout -> Word64 -> ResolvedTool -> IO (Either String TrustedResolverProtocol)
resolveReady layout user colima = do
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
            pure (ProtocolReadyV2 colima dockerTool limaTool <$> fst helpers <*> snd helpers)

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
      observed <- observeNativeEntry layout user False path
      pure (Just . ResolvedTool path <$> observed)

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
      observed <- observeNativeEntry layout user True path
      pure (() <$ observed)

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
          observed <- observeNativeEntry layout user True path
          pure (TrustedDirectoryBinding path <$> observed)
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

-- Bind an admitted pathname to a no-follow descriptor, then re-observe the
-- pathname while that descriptor is live. No unchecked path observation can
-- supply a tool or helper identity.
observeNativeEntry :: ResolverLayout -> Word64 -> Bool -> FilePath -> IO (Either String TrustedToolIdentity)
observeNativeEntry layout user directory path = do
  named <- statusMaybe path
  case named >>= requirePresent missing >>= admit of
    Left refusal -> pure (Left refusal)
    Right before ->
      bracket (PosixIO.openFd path PosixIO.ReadOnly flags) PosixIO.closeFd $ \fd -> do
        opened <- getFdStatus fd
        current <- getSymbolicLinkStatus path
        pure $ do
          openedIdentity <- admit opened
          currentIdentity <- admit current
          if before == openedIdentity && currentIdentity == openedIdentity
            then Right openedIdentity
            else Left "entry-identity-changed"
  where
    missing = if directory then "candidate-parent-missing" else "candidate-dangling"
    flags = PosixIO.defaultFileFlags
      { PosixIO.nofollow = True,
        PosixIO.cloexec = True,
        PosixIO.nonBlock = True,
        PosixIO.directory = directory
      }
    admit status
      | directory && not (isDirectory status) = Left "directory-type"
      | not directory && not (isRegularFile status) = Left "executable-type"
      | otherwise = do
          resolverOwnerModePolicy (resolverPolicyKind layout directory) path
            (fromIntegral (fileOwner status)) (fromIntegral (fileMode status)) user
          Right (identity status)

statusMaybe :: FilePath -> IO (Either String (Maybe FileStatus))
statusMaybe path = do
  attempted <- try (getSymbolicLinkStatus path) :: IO (Either IOException FileStatus)
  pure $ case attempted of
    Left failure | isDoesNotExistError failure -> Right Nothing
    Left _ -> Left "resolver-system-error"
    Right status -> Right (Just status)

identity :: FileStatus -> TrustedToolIdentity
identity status = TrustedToolIdentity (fromIntegral (deviceID status)) (fromIntegral (fileID status))

resolverPolicyKind :: ResolverLayout -> Bool -> ResolverPolicyKind
resolverPolicyKind layout directory = case (layoutFixture layout, directory) of
  (False, False) -> ProductionExecutablePolicy
  (False, True) -> ProductionDirectoryPolicy
  (True, False) -> FixtureExecutablePolicy (layoutRoot layout)
  (True, True) -> FixtureDirectoryPolicy (layoutRoot layout)

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
#endif


-- | Layout and entry kind for the shared, descriptive owner/mode policy.
data ResolverPolicyKind
  = ProductionExecutablePolicy
  | ProductionDirectoryPolicy
  | FixtureExecutablePolicy FilePath
  | FixtureDirectoryPolicy FilePath
  deriving (Eq, Show)

-- | Production and fixture filesystem observations pass this same total policy.
-- A fixture's private root is owned by its effective user; modes and the
-- administrative-directory exceptions use the same logical Apple paths.
resolverOwnerModePolicy :: ResolverPolicyKind -> FilePath -> Word64 -> Word64 -> Word64 -> Either String ()
resolverOwnerModePolicy kind path owner mode user
  | not ownerAllowed = Left (if directory then "directory-owner" else "executable-owner")
  | directory && writableByOthers = Left "directory-world-write"
  | directory && writableByGroup && logicalPath `notElem` administrative = Left groupRefusal
  | not directory && (writableByGroup || writableByOthers) = Left "executable-write-mode"
  | not directory && mode .&. 0o111 == 0 = Left "executable-mode"
  | otherwise = Right ()
  where
    (fixtureRoot, directory) = case kind of
      ProductionExecutablePolicy -> (Nothing, False)
      ProductionDirectoryPolicy -> (Nothing, True)
      FixtureExecutablePolicy root -> (Just root, False)
      FixtureDirectoryPolicy root -> (Just root, True)
    logicalPath = case fixtureRoot of
      Nothing -> path
      Just root -> Posix.normalise ("/" Posix.</> Posix.makeRelative root path)
    ownerAllowed = case fixtureRoot of
      Just root -> under root path && owner == user
      Nothing
        | directory && logicalPath `elem` ["/", "/opt", "/Applications", "/Users"] -> owner == 0
        | under "/opt/homebrew" logicalPath -> owner == user
        | under "/Applications" logicalPath -> owner == 0 || owner == user
        | directory && under "/Users" logicalPath -> owner == user
        | otherwise -> owner == 0
    under root value = value == root || Posix.addTrailingPathSeparator root `isPrefixOf` value
    writableByGroup = mode .&. 0o020 /= 0
    writableByOthers = mode .&. 0o002 /= 0
    administrative = ["/opt/homebrew", "/opt/homebrew/bin", "/opt/homebrew/Cellar", "/opt/homebrew/opt", "/Applications"]
    groupRefusal = case fixtureRoot of
      Just _ -> "directory-group-write"
      Nothing
        | under "/Users" logicalPath -> "directory-group-write-user"
        | under "/opt/homebrew" logicalPath -> "directory-group-write-homebrew"
        | otherwise -> "directory-group-write-system"
