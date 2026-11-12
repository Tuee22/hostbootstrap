module HostBootstrap.Ensure.Colima.Backend.Resolver.Protocol (
    TrustedToolIdentity (..),
    TrustedDirectoryBinding (..),
    ResolvedTool (..),
    TrustedResolverProtocol (..),
    systemHelperDirectories,
    renderSearchPath,
    trustedDirectoryBindingsFingerprint,
    renderTrustedResolverProtocol,
    ResolverProtocolLayout,
    productionProtocolLayout,
    fixtureProtocolLayout,
    validateTrustedProtocol,
    parseTrustedResolverOutput,
    parseTrustedResolverOutputForFixtureRoot,
)
where

import Data.List (intercalate, nub, stripPrefix)
import Data.Word (Word64)
import System.FilePath (
    addTrailingPathSeparator,
    isAbsolute,
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

{- | Canonical, ordered encoding of the private helper-directory authority.
Construction is confined by the Cabal-private component boundary; the module
exports the binding constructor inside that component. The fingerprint binds
its complete ordered paths and identities into the durable owner identity.
-}
trustedDirectoryBindingsFingerprint :: [TrustedDirectoryBinding] -> String
trustedDirectoryBindingsFingerprint bindings =
    concatMap
        fingerprintField
        ( ["trusted-apple-helper-directories-v1", show (length bindings)]
            ++ concatMap bindingFields bindings
        )
  where
    bindingFields (TrustedDirectoryBinding path (TrustedToolIdentity device inode)) =
        ["helper-directory", path, show device, show inode]

    fingerprintField value = show (length value) ++ ":" ++ value ++ ","

data TrustedResolverProtocol
    = ProtocolReadyV2 ResolvedTool ResolvedTool ResolvedTool String [TrustedDirectoryBinding]
    | ProtocolMissingColimaV2 ResolvedTool String [TrustedDirectoryBinding]
    | ProtocolUnsupported String
    deriving (Eq, Show)

renderTrustedResolverProtocol :: TrustedResolverProtocol -> String
renderTrustedResolverProtocol protocol = intercalate "\t" (fields protocol) ++ "\n"
  where
    fields (ProtocolUnsupported reason) = ["UNSUPPORTED", reason]
    fields (ProtocolMissingColimaV2 brew helper bindings) =
        ["MISSING_COLIMA_V2"] ++ tool brew ++ [helper, renderBindings bindings]
    fields (ProtocolReadyV2 colima docker lima helper bindings) =
        ["READY_V2"] ++ concatMap tool [colima, docker, lima] ++ [helper, renderBindings bindings]
    tool (ResolvedTool path (TrustedToolIdentity device inode)) = [path, show device, show inode]
    renderBindings = intercalate ";" . map binding
    binding (TrustedDirectoryBinding path (TrustedToolIdentity device inode)) =
        intercalate "," [path, show device, show inode]

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
    { protocolBrewPath :: FilePath
    , protocolHomebrewRoot :: FilePath
    , protocolDockerAppPath :: FilePath
    , protocolSystemHelpers :: [FilePath]
    }

productionProtocolLayout :: ResolverProtocolLayout
productionProtocolLayout =
    ResolverProtocolLayout
        { protocolBrewPath = "/opt/homebrew/bin/brew"
        , protocolHomebrewRoot = "/opt/homebrew"
        , protocolDockerAppPath = "/Applications/Docker.app/Contents/Resources/bin/docker"
        , protocolSystemHelpers = systemHelperDirectories
        }

fixtureProtocolLayout :: FilePath -> ResolverProtocolLayout
fixtureProtocolLayout root =
    ResolverProtocolLayout
        { protocolBrewPath = root </> "opt" </> "homebrew" </> "bin" </> "brew"
        , protocolHomebrewRoot = root </> "opt" </> "homebrew"
        , protocolDockerAppPath = root </> "Applications" </> "Docker.app" </> "Contents" </> "Resources" </> "bin" </> "docker"
        , protocolSystemHelpers =
            [root </> "usr" </> "bin", root </> "bin", root </> "usr" </> "sbin", root </> "sbin"]
        }

parseTrustedResolverOutputWithLayout :: ResolverProtocolLayout -> String -> Either String TrustedResolverProtocol
parseTrustedResolverOutputWithLayout layout output = do
    body <- strictProtocolBody output
    protocol <- case splitOn '\t' body of
        ["UNSUPPORTED", reason] -> Right (ProtocolUnsupported reason)
        ["MISSING_COLIMA_V2", brewPath, brewDevice, brewInode, helperPath, encodedBindings] -> do
            brew <- parseTool brewPath brewDevice brewInode
            bindings <- parseHelperBindings encodedBindings
            Right (ProtocolMissingColimaV2 brew helperPath bindings)
        ["READY_V2", colimaPath, colimaDevice, colimaInode, dockerPath, dockerDevice, dockerInode, limaPath, limaDevice, limaInode, helperPath, encodedBindings] -> do
            colima <- parseTool colimaPath colimaDevice colimaInode
            docker <- parseTool dockerPath dockerDevice dockerInode
            lima <- parseTool limaPath limaDevice limaInode
            bindings <- parseHelperBindings encodedBindings
            Right (ProtocolReadyV2 colima docker lima helperPath bindings)
        _ -> Left "resolver-protocol-shape"
    validateTrustedProtocol layout protocol
    Right protocol

-- | One content policy for decoded reports and in-process native observations.
validateTrustedProtocol :: ResolverProtocolLayout -> TrustedResolverProtocol -> Either String ()
validateTrustedProtocol layout protocol = case protocol of
    ProtocolUnsupported reason -> require (validReason reason) "resolver-invalid-reason"
    ProtocolMissingColimaV2 brew@(ResolvedTool brewPath _) helperPath bindings -> do
        validateTool brew
        require (brewPath == protocolBrewPath layout) "resolver-brew-path"
        validateHelpers ((protocolHomebrewRoot layout </> "bin") : protocolSystemHelpers layout) helperPath bindings
    ProtocolReadyV2 colima@(ResolvedTool colimaPath _) docker@(ResolvedTool dockerPath _) lima@(ResolvedTool limaPath _) helperPath bindings -> do
        mapM_ validateTool [colima, docker, lima]
        require (validFormulaPath layout "colima" "colima" colimaPath) "resolver-colima-path"
        require (validDockerPath layout dockerPath) "resolver-docker-path"
        require (validFormulaPath layout "lima" "limactl" limaPath) "resolver-lima-path"
        validateHelpers
            (nub (map takeDirectory [colimaPath, limaPath, dockerPath] ++ [protocolHomebrewRoot layout </> "bin"] ++ protocolSystemHelpers layout))
            helperPath bindings
  where
    validateTool (ResolvedTool path (TrustedToolIdentity device inode)) = do
        require (validCanonicalPath path) "resolver-tool-path"
        require (device /= 0 && inode /= 0) "resolver-tool-identity"
    validateHelpers expected helperPath bindings = do
        require (helperPath == renderSearchPath expected) "resolver-helper-path"
        require (validHelperPath helperPath) "resolver-helper-path"
        mapM_ (\(TrustedDirectoryBinding path identity) -> validateTool (ResolvedTool path identity)) bindings
        require (map (\(TrustedDirectoryBinding path _) -> path) bindings == splitSearchPath helperPath) "resolver-helper-binding-paths"

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
    device <- canonicalNumber "resolver-tool-device" deviceText
    inode <- canonicalNumber "resolver-tool-inode" inodeText
    Right (ResolvedTool path (TrustedToolIdentity device inode))

canonicalNumber :: String -> String -> Either String Word64
canonicalNumber reason encoded = case readMaybe encoded of
    Just value | show value == encoded -> Right value
    _ -> Left reason

parseHelperBindings :: String -> Either String [TrustedDirectoryBinding]
parseHelperBindings encoded = traverse parseBinding (splitOn ';' encoded)
  where
    parseBinding entry =
        case splitOn ',' entry of
            [path, device, inode] -> do
                ResolvedTool resolvedPath identity <- parseTool path device inode
                Right (TrustedDirectoryBinding resolvedPath identity)
            _ -> Left "resolver-helper-binding-shape"


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
    case stripPrefix (addTrailingPathSeparator (protocolHomebrewRoot layout </> "Cellar" </> formula)) path of
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
