{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The project-local @<project>.dhall@ filename logic and the **generic**
sibling-config loader.

The supported config contract is binary-owned: Python derives the project
name from the Cabal file and never reads or writes Dhall. Normal binary
commands read a sibling project config, validate the runtime context inside
it, and then dispatch.

The core is generic over a project's config type ('ProjectCfg'): it never
names a concrete config record. It decodes/encodes the sibling config via
@FromDhall@/@ToDhall@ and reaches the embedded runtime context through
'cfgContext'. A project owns its actual config shape (the @<project>.dhall@
record) in its own module.
-}
module HostBootstrap.Config.Schema (
    -- * Filename logic (generic)
    projectConfigFileName,
    projectConfigPathForExecutable,
    siblingProjectConfigPath,

    -- * Roles
    configRoleNames,
    parseConfigRole,
    renderConfigRole,

    -- * Generic config IO
    writeProjectConfigFile,
    writeProjectConfigFileExclusive,
    removeProjectConfigFileIfOwned,
    requireSiblingProjectConfig,
    withSiblingProjectConfigContext,

    -- * Validation
    validateProjectConfigForProject,

    -- * Snapshot logging
    projectConfigSnapshotHash,
    projectConfigSnapshotHashBytes,
    renderProjectConfigSnapshotLog,
)
where

import Control.Exception (SomeAsyncException, SomeException, finally, fromException, mask, onException, tryJust)
import Control.Monad (when)
import Data.Bits (xor)
import qualified Data.ByteString as BS
import Data.Functor.Identity (Identity (Identity), runIdentity)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Data.Word (Word64)
import qualified Dhall
import HostBootstrap.Config.Class (ProjectCfg (..))
import HostBootstrap.Context (BinaryContext)
import qualified HostBootstrap.Context as Context
import qualified HostBootstrap.Dhall.Hoist as Hoist
import Numeric (showHex)
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, doesPathExist, removeDirectory, removeFile, renameFile)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)

{- | User-facing role names accepted by @project init --role@ / @service init
--role@.
-}
configRoleNames :: [Text]
configRoleNames =
    [ "host-orchestrator"
    , "vm-orchestrator"
    , "vm-project-container"
    , "image-build-container"
    , "cluster-service"
    , "daemon"
    , "one-shot-job"
    , "test-harness"
    ]

-- | Render the canonical role name for a context kind.
renderConfigRole :: Context.ContextKind -> Text
renderConfigRole = Context.defaultRoleName

-- | The canonical local config filename for a project.
projectConfigFileName :: Text -> FilePath
projectConfigFileName projectName = T.unpack projectName ++ ".dhall"

-- | Where a project-local config lives for a known executable path.
projectConfigPathForExecutable :: Text -> FilePath -> FilePath
projectConfigPathForExecutable projectName exe =
    takeDirectory exe </> projectConfigFileName projectName

-- | The project-local config path for the currently running executable.
siblingProjectConfigPath :: Text -> IO FilePath
siblingProjectConfigPath projectName =
    projectConfigPathForExecutable projectName <$> getExecutablePath

-- | Parse a user-facing role name for generated local configs.
parseConfigRole :: String -> Either String Context.ContextKind
parseConfigRole raw =
    case normalise (T.pack raw) of
        "host" -> Right Context.HostOrchestrator
        "host-orchestrator" -> Right Context.HostOrchestrator
        "vm" -> Right Context.VMOrchestrator
        "vm-orchestrator" -> Right Context.VMOrchestrator
        "container" -> Right Context.VMProjectContainer
        "ad-hoc-container" -> Right Context.VMProjectContainer
        "vm-project-container" -> Right Context.VMProjectContainer
        "image-build" -> Right Context.ImageBuildContainer
        "image-build-container" -> Right Context.ImageBuildContainer
        "service" -> Right Context.ClusterService
        "cluster-service" -> Right Context.ClusterService
        "daemon" -> Right Context.Daemon
        "one-shot" -> Right Context.OneShotJob
        "one-shot-job" -> Right Context.OneShotJob
        "test" -> Right Context.TestHarness
        "test-harness" -> Right Context.TestHarness
        other ->
            Left $
                "unknown config role "
                    <> T.unpack other
                    <> " (expected one of: "
                    <> T.unpack (T.intercalate ", " configRoleNames)
                    <> ")"
  where
    normalise = T.replace "_" "-" . T.toLower . T.strip

{- | Write any @ToDhall@ config value (a project config or a test config) as
deterministic Dhall source via its @ToDhall@ embedding. The repeated vocabulary
unions are hoisted into top-level @let@ bindings (shared with
'Context.renderContext' via 'Context.vocabUnions') so the generated config
stays compact and standalone.
-}
writeProjectConfigFile :: (Dhall.ToDhall cfg) => FilePath -> cfg -> IO ()
writeProjectConfigFile path cfg =
    mask $ \restore -> do
        lockPath <- claimConfigWriteLock path
        restore (BS.writeFile path (renderProjectConfigBytes cfg))
            `finally` removeDirectory lockPath

data ProjectConfigOwnership = ProjectConfigOwnership
    { ownedPath :: FilePath
    , ownedPayload :: BS.ByteString
    , ownedLockPath :: FilePath
    }

{- | Atomically claim a previously absent generated-config path. A sibling lock
directory is the ownership token: directory creation is exclusive on every
supported platform, so concurrent harnesses cannot both pass the absence
check. The token remains for the bracket lifetime and is consumed by cleanup.
-}
writeProjectConfigFileExclusive :: (Dhall.ToDhall cfg) => FilePath -> cfg -> IO ProjectConfigOwnership
writeProjectConfigFileExclusive path cfg =
    mask $ \restore -> do
        let payload = renderProjectConfigBytes cfg
        lockPath <- claimConfigWriteLock path
        present <- restore (doesPathExist path) `onException` removeDirectory lockPath
        if present
            then removeDirectory lockPath >> ioError (userError ("generated config path appeared before ownership claim: " ++ path))
            else do
                restore (BS.writeFile path payload)
                    `onException` removeExclusivePartial path lockPath
                pure (ProjectConfigOwnership path payload lockPath)

claimConfigWriteLock :: FilePath -> IO FilePath
claimConfigWriteLock path = do
    let lockPath = configOwnerPath path
    claimed <- trySynchronous (createDirectory lockPath)
    case claimed of
        Right () -> pure lockPath
        Left _ -> ioError (userError ("generated config ownership is active; refusing overwrite: " ++ path))

removeExclusivePartial :: FilePath -> FilePath -> IO ()
removeExclusivePartial path lockPath = do
    present <- doesPathExist path
    when present (removeFile path)
    removeDirectory lockPath

{- | Remove a generated config only while its bytes still equal the payload this
run installed. Cleanup first atomically quarantines the current path inside the
ownership directory. Matching bytes are deleted; differing bytes remain in that
quarantine with the lock held and are reported for explicit recovery, so a
concurrent replacement can never be mistaken for run-owned state or clobbered.
-}
removeProjectConfigFileIfOwned :: FilePath -> ProjectConfigOwnership -> IO (Either String ())
removeProjectConfigFileIfOwned path ownership = do
    if path /= ownedPath ownership
        then pure (Left ("generated config ownership witness belongs to a different path: " ++ ownedPath ownership))
        else removeOwned
  where
    removeOwned = do
        lockPresent <- doesDirectoryExist (ownedLockPath ownership)
        present <- doesPathExist path
        if not lockPresent
            then pure (Left ("generated config ownership token disappeared; preserving path if present: " ++ path))
            else
                if not present
                    then removeDirectory (ownedLockPath ownership) >> pure (Right ())
                    else do
                        let quarantined = ownedLockPath ownership </> "payload"
                        renameFile path quarantined
                        actual <- BS.readFile quarantined
                        if actual == ownedPayload ownership
                            then do
                                removeFile quarantined
                                replacementPresent <- doesPathExist path
                                removeDirectory (ownedLockPath ownership)
                                if replacementPresent
                                    then pure (Left ("generated config was replaced during cleanup; preserving replacement at " ++ path))
                                    else pure (Right ())
                            else do
                                replacementPresent <- doesPathExist path
                                if replacementPresent
                                    then
                                        pure
                                            ( Left
                                                ( "generated config changed ownership and another replacement appeared during cleanup; preserving both "
                                                    ++ path
                                                    ++ " and "
                                                    ++ quarantined
                                                )
                                            )
                                    else do
                                        pure
                                            ( Left
                                                ( "generated config changed ownership during the test run; preserving replacement in quarantine at "
                                                    ++ quarantined
                                                )
                                            )

configOwnerPath :: FilePath -> FilePath
configOwnerPath path = path ++ ".hostbootstrap-test-owner"

renderProjectConfigFile :: (Dhall.ToDhall cfg) => cfg -> Text
renderProjectConfigFile cfg = Hoist.renderHoisted Context.vocabUnions cfg <> "\n"

renderProjectConfigBytes :: (Dhall.ToDhall cfg) => cfg -> BS.ByteString
renderProjectConfigBytes = TE.encodeUtf8 . renderProjectConfigFile

{- | Validate that the runtime context inside the config belongs to the derived
project/binary identity. Generic: reaches the context via 'cfgContext'.
-}
validateProjectConfigForProject :: (ProjectCfg cfg) => Text -> cfg -> Either String cfg
validateProjectConfigForProject expected cfg
    | Context.project ctx /= expected =
        Left $
            "project config: expected project "
                <> T.unpack expected
                <> ", got "
                <> T.unpack (Context.project ctx)
    | Context.binary ctx /= expected =
        Left $
            "project config: expected binary "
                <> T.unpack expected
                <> ", got "
                <> T.unpack (Context.binary ctx)
    | otherwise = Right cfg
  where
    ctx = cfgContext cfg

-- | Load and validate the current executable's sibling project config.
requireSiblingProjectConfig ::
    (ProjectCfg cfg) =>
    Text ->
    Context.CommandClass ->
    [Context.Capability] ->
    IO cfg
requireSiblingProjectConfig projectName cls caps =
    fst <$> loadSiblingProjectConfig projectName cls caps

{- | Run an action with a validated sibling project config and its nested
runtime context.
-}
withSiblingProjectConfigContext ::
    (ProjectCfg cfg) =>
    Text ->
    Context.CommandClass ->
    [Context.Capability] ->
    (cfg -> BinaryContext -> IO a) ->
    IO a
withSiblingProjectConfigContext projectName cls caps action = do
    (cfg, cfgCtx) <- loadSiblingProjectConfig projectName cls caps
    action cfg cfgCtx

loadSiblingProjectConfig ::
    forall cfg.
    (ProjectCfg cfg) =>
    Text ->
    Context.CommandClass ->
    [Context.Capability] ->
    IO (cfg, BinaryContext)
loadSiblingProjectConfig projectName cls caps = do
    path <- siblingProjectConfigPath projectName
    exists <- doesFileExist path
    if not exists
        then
            failProjectConfig
                path
                ("missing " ++ path ++ "; run `" ++ T.unpack projectName ++ " project init`")
        else do
            rawResult <- trySynchronous (BS.readFile path)
            rawBytes <- case rawResult of
                Left err -> failProjectConfig path ("failed to read " ++ path ++ ": " ++ firstLine (show err))
                Right content -> pure content
            raw <- case TE.decodeUtf8' rawBytes of
                Left err -> failProjectConfig path ("failed to decode UTF-8 in " ++ path ++ ": " ++ firstLine (show err))
                Right content -> pure content
            let inputSettings =
                    setInputSourceName
                        path
                        (setInputRootDirectory (takeDirectory path) Dhall.defaultInputSettings)
            decoded <- trySynchronous (Dhall.inputWithSettings inputSettings Dhall.auto raw)
            cfg <- case decoded of
                Left err -> failProjectConfig path ("failed to decode " ++ path ++ ": " ++ firstLine (show err))
                Right value -> pure value
            case validateProjectConfigForProject projectName cfg of
                Left err -> failProjectConfig path err
                Right validCfg -> do
                    validated <-
                        Context.validateRuntimeContext
                            (Context.contextRequirement projectName cls caps)
                            (cfgContext validCfg)
                    case validated of
                        Left err -> do
                            hPutStrLn stderr (Context.contextErrorMessage err)
                            exitWith (ExitFailure 1)
                        Right cfgCtx -> do
                            when (shouldLogSnapshot cls cfgCtx) $
                                TIO.hPutStrLn
                                    stderr
                                    (renderProjectConfigSnapshotLog path (projectConfigSnapshotHashBytes rawBytes) cfgCtx)
                            pure (validCfg, cfgCtx)
  where
    firstLine = takeWhile (/= '\n')
    failProjectConfig _ detail = do
        hPutStrLn stderr ("project config: " ++ detail)
        exitWith (ExitFailure 1)

    shouldLogSnapshot commandClass cfgCtx =
        commandClass `elem` [Context.DaemonCommand, Context.ServiceCommand]
            || Context.contextKind cfgCtx `elem` [Context.Daemon, Context.ClusterService]

trySynchronous :: IO a -> IO (Either SomeException a)
trySynchronous = tryJust $ \err ->
    case fromException err :: Maybe SomeAsyncException of
        Just _ -> Nothing
        Nothing -> Just err

setInputRootDirectory :: FilePath -> Dhall.InputSettings -> Dhall.InputSettings
setInputRootDirectory value settings =
    runIdentity (Dhall.rootDirectory (const (Identity value)) settings)

setInputSourceName :: FilePath -> Dhall.InputSettings -> Dhall.InputSettings
setInputSourceName value settings =
    runIdentity (Dhall.sourceName (const (Identity value)) settings)

{- | Stable, non-secret fingerprint for startup logging. This is not a
cryptographic digest; it exists to correlate a process with the exact config
snapshot it loaded.
-}
projectConfigSnapshotHash :: Text -> Text
projectConfigSnapshotHash = projectConfigSnapshotHashBytes . TE.encodeUtf8

-- | Hash the exact UTF-8 bytes read from disk or mounted into a ConfigMap.
projectConfigSnapshotHashBytes :: BS.ByteString -> Text
projectConfigSnapshotHashBytes content =
    T.pack ("fnv64:" ++ leftPad16 (showHex (BS.foldl' step offset content) ""))
  where
    offset :: Word64
    offset = 14695981039346656037

    prime :: Word64
    prime = 1099511628211

    step h byte = (h `xor` fromIntegral byte) * prime

    leftPad16 :: String -> String
    leftPad16 value = replicate (max 0 (16 - length value)) '0' ++ value

{- | One-line daemon/service startup metadata. It intentionally includes only
authority and placement metadata, not secrets.
-}
renderProjectConfigSnapshotLog :: FilePath -> Text -> BinaryContext -> Text
renderProjectConfigSnapshotLog path configHash cfgContext' =
    T.unwords
        [ "project-config-snapshot"
        , "project=" <> Context.project cfgContext'
        , "binary=" <> Context.binary cfgContext'
        , "contextKind=" <> T.pack (show (Context.contextKind cfgContext'))
        , "roleName=" <> Context.roleName cfgContext'
        , "configPath=" <> T.pack path
        , "configHash=" <> configHash
        , "sourceRoot=" <> Context.sourceRoot cfgContext'
        , "cpu=" <> T.pack (show (Context.cpu envelope))
        , "memory=" <> Context.memory envelope
        , "storage=" <> Context.storage envelope
        ]
  where
    envelope = Context.resourceEnvelope cfgContext'
