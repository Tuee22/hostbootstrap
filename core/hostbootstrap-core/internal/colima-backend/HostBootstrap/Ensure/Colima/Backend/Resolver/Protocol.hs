module HostBootstrap.Ensure.Colima.Backend.Resolver.Protocol
  ( TrustedToolIdentity (..),
    TrustedDirectoryBinding,
    ResolvedTool (..),
    TrustedResolverProtocol (..),
    trustedPythonCandidate,
    systemHelperDirectories,
    renderSearchPath,
    trustedDirectoryBindingsFingerprint,
    parseTrustedResolverOutput,
    parseTrustedResolverOutputForFixtureRoot,
  )
where

import Data.List (intercalate, nub, stripPrefix)
import Data.Word (Word64)
import System.FilePath
  ( isAbsolute,
    normalise,
    searchPathSeparator,
    splitDirectories,
    splitSearchPath,
    takeDirectory,
    (</>),
  )
import Text.Read (readMaybe)

data TrustedToolIdentity = TrustedToolIdentity !Word64 !Word64
  deriving (Eq, Show)

data TrustedDirectoryBinding = TrustedDirectoryBinding !FilePath !TrustedToolIdentity
  deriving (Eq, Show)

data ResolvedTool = ResolvedTool !FilePath !TrustedToolIdentity
  deriving (Eq, Show)

-- | Canonical, ordered encoding of the private helper-directory authority.
-- The constructor remains hidden; callers can bind the whole authority into a
-- durable owner identity without gaining a path or identity projection.
trustedDirectoryBindingsFingerprint :: [TrustedDirectoryBinding] -> String
trustedDirectoryBindingsFingerprint bindings =
  concatMap fingerprintField
    ( ["trusted-apple-helper-directories-v1", show (length bindings)]
        ++ concatMap bindingFields bindings
    )
  where
    bindingFields (TrustedDirectoryBinding path (TrustedToolIdentity device inode)) =
      ["helper-directory", path, show device, show inode]

    fingerprintField value = show (length value) ++ ":" ++ value ++ ","

data TrustedResolverProtocol
  = ProtocolReady
      ResolvedTool
      ResolvedTool
      ResolvedTool
      ResolvedTool
      String
      [TrustedDirectoryBinding]
  | ProtocolMissingColima
      ResolvedTool
      ResolvedTool
      String
      [TrustedDirectoryBinding]
  | ProtocolUnsupported String
  deriving (Eq, Show)

trustedPythonCandidate :: FilePath
trustedPythonCandidate = "/usr/bin/python3"

systemHelperDirectories :: [FilePath]
systemHelperDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

renderSearchPath :: [FilePath] -> String
renderSearchPath = intercalate [searchPathSeparator]

parseTrustedResolverOutput :: String -> Either String TrustedResolverProtocol
parseTrustedResolverOutput = parseTrustedResolverOutputWithLayout productionProtocolLayout

parseTrustedResolverOutputForFixtureRoot :: FilePath -> String -> Either String TrustedResolverProtocol
parseTrustedResolverOutputForFixtureRoot root
  | not (validCanonicalPath root) = const (Left "resolver-fixture-root")
  | otherwise = parseTrustedResolverOutputWithLayout (fixtureProtocolLayout root)

data ResolverProtocolLayout = ResolverProtocolLayout
  { protocolPythonPath :: FilePath,
    protocolBrewPath :: FilePath,
    protocolHomebrewRoot :: FilePath,
    protocolDockerAppPath :: FilePath,
    protocolSystemHelpers :: [FilePath]
  }

productionProtocolLayout :: ResolverProtocolLayout
productionProtocolLayout =
  ResolverProtocolLayout
    { protocolPythonPath = trustedPythonCandidate,
      protocolBrewPath = "/opt/homebrew/bin/brew",
      protocolHomebrewRoot = "/opt/homebrew",
      protocolDockerAppPath = "/Applications/Docker.app/Contents/Resources/bin/docker",
      protocolSystemHelpers = systemHelperDirectories
    }

fixtureProtocolLayout :: FilePath -> ResolverProtocolLayout
fixtureProtocolLayout root =
  ResolverProtocolLayout
    { protocolPythonPath = root </> "usr" </> "bin" </> "python3",
      protocolBrewPath = root </> "opt" </> "homebrew" </> "bin" </> "brew",
      protocolHomebrewRoot = root </> "opt" </> "homebrew",
      protocolDockerAppPath = root </> "Applications" </> "Docker.app" </> "Contents" </> "Resources" </> "bin" </> "docker",
      protocolSystemHelpers =
        [root </> "usr" </> "bin", root </> "bin", root </> "usr" </> "sbin", root </> "sbin"]
    }

parseTrustedResolverOutputWithLayout :: ResolverProtocolLayout -> String -> Either String TrustedResolverProtocol
parseTrustedResolverOutputWithLayout layout output = do
  body <- strictProtocolBody output
  case splitOn '\t' body of
    ["UNSUPPORTED", reason]
      | validReason reason -> Right (ProtocolUnsupported reason)
      | otherwise -> Left "resolver-invalid-reason"
    [ "MISSING_COLIMA",
      pythonPath,
      pythonDevice,
      pythonInode,
      brewPath,
      brewDevice,
      brewInode,
      helperPath,
      helperBindingsText
      ] -> do
        python <- parseTool pythonPath pythonDevice pythonInode
        brew <- parseTool brewPath brewDevice brewInode
        require (pythonPath == protocolPythonPath layout) "resolver-python-path"
        require (brewPath == protocolBrewPath layout) "resolver-brew-path"
        require
          ( helperPath
              == renderSearchPath
                ((protocolHomebrewRoot layout </> "bin") : protocolSystemHelpers layout)
          )
          "resolver-helper-path"
        require (validHelperPath helperPath) "resolver-helper-path"
        bindings <- parseHelperBindings helperPath helperBindingsText
        Right (ProtocolMissingColima python brew helperPath bindings)
    [ "READY",
      pythonPath,
      pythonDevice,
      pythonInode,
      colimaPath,
      colimaDevice,
      colimaInode,
      dockerPath,
      dockerDevice,
      dockerInode,
      limaPath,
      limaDevice,
      limaInode,
      helperPath,
      helperBindingsText
      ] -> do
        python <- parseTool pythonPath pythonDevice pythonInode
        colima <- parseTool colimaPath colimaDevice colimaInode
        docker <- parseTool dockerPath dockerDevice dockerInode
        lima <- parseTool limaPath limaDevice limaInode
        require (pythonPath == protocolPythonPath layout) "resolver-python-path"
        require (validFormulaPath layout "colima" "colima" colimaPath) "resolver-colima-path"
        require (validDockerPath layout dockerPath) "resolver-docker-path"
        require (validFormulaPath layout "lima" "limactl" limaPath) "resolver-lima-path"
        require
          ( helperPath
              == renderSearchPath
                ( nub
                    ( map
                        takeDirectory
                        [colimaPath, limaPath, dockerPath]
                        ++ [protocolHomebrewRoot layout </> "bin"]
                        ++ protocolSystemHelpers layout
                    )
                )
          )
          "resolver-helper-path"
        require (validHelperPath helperPath) "resolver-helper-path"
        bindings <- parseHelperBindings helperPath helperBindingsText
        Right (ProtocolReady python colima docker lima helperPath bindings)
    _ -> Left "resolver-protocol-shape"

strictProtocolBody :: String -> Either String String
strictProtocolBody output =
  case reverse output of
    '\n' : reversedBody ->
      let body = reverse reversedBody
       in if null body || '\n' `elem` body || '\r' `elem` body
            then Left "resolver-protocol-framing"
            else Right body
    _ -> Left "resolver-protocol-framing"

splitOn :: Char -> String -> [String]
splitOn separator value =
  case break (== separator) value of
    (field, []) -> [field]
    (field, _ : rest) -> field : splitOn separator rest

parseTool :: FilePath -> String -> String -> Either String ResolvedTool
parseTool path deviceText inodeText = do
  require (validCanonicalPath path) "resolver-tool-path"
  device <- maybe (Left "resolver-tool-device") Right (readMaybe deviceText)
  inode <- maybe (Left "resolver-tool-inode") Right (readMaybe inodeText)
  require (device /= 0 && inode /= 0) "resolver-tool-identity"
  Right (ResolvedTool path (TrustedToolIdentity device inode))

parseHelperBindings :: String -> String -> Either String [TrustedDirectoryBinding]
parseHelperBindings helperPath encoded = do
  bindings <- traverse parseBinding (splitOn ';' encoded)
  require
    (map bindingPath bindings == splitSearchPath helperPath)
    "resolver-helper-binding-paths"
  Right bindings
  where
    parseBinding entry =
      case splitOn ',' entry of
        [path, device, inode] -> do
          ResolvedTool resolvedPath identity <- parseTool path device inode
          Right (TrustedDirectoryBinding resolvedPath identity)
        _ -> Left "resolver-helper-binding-shape"

    bindingPath (TrustedDirectoryBinding path _) = path

validCanonicalPath :: FilePath -> Bool
validCanonicalPath path =
  isAbsolute path
    && normalise path == path
    && not (null path)
    && not (any (`elem` ['\0', '\t', '\r', '\n', ',', ';']) path)

validHelperPath :: String -> Bool
validHelperPath helperPath =
  let directories = splitSearchPath helperPath
   in not (null directories)
        && directories == nub directories
        && all validCanonicalPath directories

validFormulaPath :: ResolverProtocolLayout -> String -> FilePath -> FilePath -> Bool
validFormulaPath layout formula binary path =
  case stripPrefix (protocolHomebrewRoot layout </> "Cellar" </> formula ++ "/") path of
    Just suffix ->
      case splitDirectories suffix of
        [version, "bin", observedBinary] ->
          not (null version)
            && version /= "."
            && version /= ".."
            && observedBinary == binary
        _ -> False
    Nothing -> False

validDockerPath :: ResolverProtocolLayout -> FilePath -> Bool
validDockerPath layout path =
  validFormulaPath layout "docker" "docker" path
    || path == protocolDockerAppPath layout

validReason :: String -> Bool
validReason reason =
  not (null reason)
    && length reason <= 80
    && all (\character -> character == '-' || character >= 'a' && character <= 'z') reason

require :: Bool -> String -> Either String ()
require True _ = Right ()
require False reason = Left reason
