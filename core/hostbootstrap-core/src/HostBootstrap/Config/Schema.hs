{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The project-local @<project>.dhall@ filename logic and the **generic**
sibling-config loader.

The supported config contract is binary-owned: Python derives the project
name from the Cabal file and never reads or writes Dhall. Normal binary
commands read a sibling project config, validate the runtime context inside
it, and then dispatch.

The core is generic over a project's config type ('ProjectCfg'): it never
names a concrete config record. It decodes/encodes the sibling config through
the project's validated 'CodecWitness' and reaches the embedded runtime
context through 'cfgContext'. A project owns its actual config shape (the
@<project>.dhall@ record) in its own module.
-}
module HostBootstrap.Config.Schema (
    -- * Filename logic (generic)
    projectConfigFileName,
    projectConfigPathForExecutable,
    siblingProjectConfigPath,
    siblingTestConfigPath,

    -- * The typed test-config writer
    TestConfigWrite,
    testConfigWriteFor,
    testConfigWritePath,
    TestConfigReplacement (..),
    TestConfigWriteOutcome (..),
    installTestConfig,

    -- * Roles
    configRoleNames,
    parseConfigRole,
    renderConfigRole,

    -- * Generic config IO
    writeProjectConfigFile,
    writeScopedProjectConfigFile,
    renderScopedProjectConfigBytes,
    withSiblingProjectConfigContext,
    withSiblingValidatedProjectConfigContext,
    withSiblingValidatedProjectConfigRoot,
    VerifiedConfigWire,
    verifiedConfigDigest,
    ValidatedConfig,
    validatedConfigValue,
    withValidatedConfig,
    ConfigWireAdmissionError (..),
    configWireAdmissionErrorMessage,
    withAuthenticatedConfigWire,
    withAssembledHarnessConfig,
    SiblingConfigInstallResult (..),
    SiblingConfigInstallError (..),
    siblingConfigInstallErrorMessage,
    installAuthenticatedProductionSiblingConfig,
    installAuthenticatedHarnessSiblingConfig,

    -- * Validation
    validateProjectConfigForProject,

    -- * Snapshot logging
    projectConfigSnapshotHash,
    projectConfigSnapshotHashBytes,
    renderProjectConfigSnapshotLog,
)
where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
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
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hLock)
import HostBootstrap.Authority (InstalledProject, installedProjectName)
import HostBootstrap.Config.Class (
    ConfigAssembly,
    ConfigInput,
    ProjectCfg (..),
    ProjectCodec,
    decodeProjectCodecWithSettings,
    renderProjectCodecHoisted,
    runConfigAssembly,
 )
import HostBootstrap.Config.Vocab (Harness, HarnessAuthority, Production)
import HostBootstrap.Context (BinaryContext)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (
    CodecWitness,
    renderHoistedValue,
 )
import HostBootstrap.Handoff (
    AuthenticatedConfigPayload,
    authenticatedConfigBytes,
    authenticatedConfigDigest,
    childConfigDigest,
 )
import HostBootstrap.Config.Install.Native (linkNoReplace)
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    ProjectRootError (..),
    withCanonicalProjectRoot,
 )
import Numeric (showHex)
import System.Directory (
    doesFileExist,
    doesPathExist,
    pathIsSymbolicLink,
    removeFile,
 )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure), die, exitWith)
import System.FilePath (takeDirectory, (</>))
import System.IO (
    IOMode (AppendMode, ReadMode),
    hClose,
    hFileSize,
    hFlush,
    hPutStrLn,
    openBinaryFile,
    openBinaryTempFile,
    stderr,
    withBinaryFile,
 )
import System.IO.Error (catchIOError)
import System.IO.Unsafe (unsafePerformIO)

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

{- | The project-local **test** config path: a sibling of the project config
(§ Z).
-}
siblingTestConfigPath :: Text -> IO FilePath
siblingTestConfigPath projectName = do
    configPath <- siblingProjectConfigPath projectName
    pure (takeDirectory configPath </> (T.unpack projectName ++ ".test.dhall"))

{- | One request to write one project's test config.

Opaque, and its only producer resolves the destination itself from the installed
project name: what a caller supplies is the project's own typed test-config
value and its codec, never a path and never rendered bytes. So core cannot be
asked to write arbitrary bytes, nor to write them somewhere other than the
sibling the @test run@ gate reads.
-}
data TestConfigWrite tcfg = TestConfigWrite FilePath (CodecWitness tcfg) tcfg

instance Show (TestConfigWrite tcfg) where
    show (TestConfigWrite path _ _) = "TestConfigWrite " <> show path

-- | Resolve the sibling destination and bind it to the typed value to write.
testConfigWriteFor :: Text -> CodecWitness tcfg -> tcfg -> IO (TestConfigWrite tcfg)
testConfigWriteFor projectName codec value = do
    path <- siblingTestConfigPath projectName
    pure (TestConfigWrite path codec value)

-- | The destination this request resolved, for a diagnostic that names the file.
testConfigWritePath :: TestConfigWrite tcfg -> FilePath
testConfigWritePath (TestConfigWrite path _ _) = path

{- | Whether an existing test config may be replaced.

Stated rather than implied: silently overwriting is how an operator loses an
edited matrix, and silently skipping is how they run yesterday's. Neither is a
default worth having, so the caller says which one it means.
-}
data TestConfigReplacement
    = RefuseExistingTestConfig
    | ReplaceExistingTestConfig
    deriving (Eq, Show)

-- | What one write did, so a caller reports it rather than inferring it.
data TestConfigWriteOutcome
    = TestConfigWritten FilePath
    | TestConfigReplaced FilePath
    | -- | one already existed and replacement was not requested
      TestConfigExists FilePath
    deriving (Eq, Show)

-- | Write the request's typed value, honouring the stated replacement policy.
installTestConfig :: TestConfigReplacement -> TestConfigWrite tcfg -> IO TestConfigWriteOutcome
installTestConfig replacement (TestConfigWrite path codec value) = do
    present <- doesFileExist path
    case (present, replacement) of
        (True, RefuseExistingTestConfig) -> pure (TestConfigExists path)
        (True, ReplaceExistingTestConfig) -> write TestConfigReplaced
        (False, _) -> write TestConfigWritten
  where
    write outcome = do
        writeProjectConfigFile codec path value
        pure (outcome path)

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

{- | Write a config value (a project config or a test config) as deterministic
Dhall source via its validated codec. The repeated vocabulary unions are
hoisted into top-level @let@ bindings (shared with
'Context.renderContext' via 'Context.vocabUnions') so the generated config
stays compact and standalone.
-}
writeProjectConfigFile :: CodecWitness cfg -> FilePath -> cfg -> IO ()
writeProjectConfigFile codec path cfg =
    codec `seq` BS.writeFile path (renderProjectConfigBytes codec cfg)

-- | Write a scope-indexed project config through its installed mapped codec.
writeScopedProjectConfigFile ::
    ProjectCodec scope specDigest cfg ->
    FilePath ->
    cfg scope ->
    IO ()
writeScopedProjectConfigFile codec path cfg =
    BS.writeFile path (renderScopedProjectConfigBytes codec cfg)

renderProjectConfigFile :: CodecWitness cfg -> cfg -> Text
renderProjectConfigFile codec cfg =
    renderHoistedValue codec Context.vocabUnions cfg <> "\n"

renderProjectConfigBytes :: CodecWitness cfg -> cfg -> BS.ByteString
renderProjectConfigBytes codec = TE.encodeUtf8 . renderProjectConfigFile codec

{- | The exact canonical bytes a scoped config renders to. The harness installs
these through "HostBootstrap.Harness.GeneratedConfig" rather than writing them
here, so the ownership protocol — not the writer — decides whether the path may
be created at all.
-}
renderScopedProjectConfigBytes ::
    ProjectCodec scope specDigest cfg ->
    cfg scope ->
    BS.ByteString
renderScopedProjectConfigBytes codec =
    TE.encodeUtf8
        . (<> "\n")
        . renderProjectCodecHoisted codec Context.vocabUnions

{- | Opaque evidence naming the canonical bytes admitted for one scope-local
config identity. The constructor and generative identity indices are private.
-}
newtype VerifiedConfigWire scope configDigest configId
    = VerifiedConfigWire Text

-- | The digest of the exact canonical bytes that were verified.
verifiedConfigDigest :: VerifiedConfigWire scope configDigest configId -> Text
verifiedConfigDigest (VerifiedConfigWire digest) = digest

{- | A config value admitted by the matching installed project codec. Its scope,
specification identity, and fresh config identity cannot be changed by callers.
-}
newtype ValidatedConfig scope specDigest configId config
    = ValidatedConfig config

-- | Read the validated value without weakening any of its phantom identities.
validatedConfigValue ::
    ValidatedConfig scope specDigest configId config ->
    config
validatedConfigValue (ValidatedConfig value) = value

{- | Canonically render, hash, strictly re-decode, and re-render one scoped
config through the installed project codec. Only a byte-stable round trip enters
the rank-2 continuation under fresh digest/config identities.
-}
withValidatedConfig ::
    ProjectCodec scope specDigest cfg ->
    cfg scope ->
    ( forall configDigest configId.
      VerifiedConfigWire scope configDigest configId ->
      ValidatedConfig scope specDigest configId (cfg scope) ->
      IO result
    ) ->
    IO (Either String result)
withValidatedConfig projectCodec value use = do
    let payload = renderScopedProjectConfigBytes projectCodec value
        rendered = TE.decodeUtf8 payload
        digest = childConfigDigest payload
    decoded <-
        trySynchronous
            ( decodeProjectCodecWithSettings
                projectCodec
                Dhall.defaultInputSettings
                rendered
            )
    case decoded of
        Left err ->
            pure
                ( Left
                    ( "project codec rejected its canonical rendering: "
                        ++ takeWhile (/= '\n') (show err)
                    )
                )
        Right roundTripped
            | renderScopedProjectConfigBytes projectCodec roundTripped /= payload ->
                pure (Left "project codec canonical render/decode/re-render changed bytes")
            | otherwise ->
                Right
                    <$> mintValidatedConfig
                        digest
                        roundTripped
                        use

mintValidatedConfig ::
    Text ->
    config ->
    ( forall configDigest configId.
      VerifiedConfigWire scope configDigest configId ->
      ValidatedConfig scope specDigest configId config ->
      result
    ) ->
    result
mintValidatedConfig digest value use =
    use (VerifiedConfigWire digest) (ValidatedConfig value)

-- | Failures while turning authenticated transport bytes into a local config.
-- No constructor retains or renders the payload, a signature, or a token.
data ConfigWireAdmissionError
    = ConfigWireDigestMismatch
    | ConfigWireInvalidUtf8
    | ConfigWireCodecRejected
    | ConfigWireNonCanonical
    deriving (Eq, Show)

configWireAdmissionErrorMessage :: ConfigWireAdmissionError -> Text
configWireAdmissionErrorMessage failure = case failure of
    ConfigWireDigestMismatch ->
        "authenticated config bytes do not match the signed digest"
    ConfigWireInvalidUtf8 ->
        "authenticated config bytes are not valid UTF-8"
    ConfigWireCodecRejected ->
        "the installed project codec rejected the authenticated config"
    ConfigWireNonCanonical ->
        "the authenticated config is not the codec's exact canonical rendering"

{- | Admit the exact config bytes authenticated by a verified handoff.

The digest is checked before parsing.  The bytes are then strictly decoded
through the scope-correct installed 'ProjectCodec' and must render back
byte-for-byte.  Only that conjunction mints a fresh local config identity; the
wire's parent-side identity is never reused in this process.
-}
withAuthenticatedConfigWire ::
    ProjectCodec scope specDigest cfg ->
    AuthenticatedConfigPayload scope brokerGeneration ->
    ( forall configDigest configId.
      VerifiedConfigWire scope configDigest configId ->
      ValidatedConfig scope specDigest configId (cfg scope) ->
      IO result
    ) ->
    IO (Either ConfigWireAdmissionError result)
withAuthenticatedConfigWire projectCodec authenticated use
    | childConfigDigest payload /= authenticatedConfigDigest authenticated =
        pure (Left ConfigWireDigestMismatch)
    | otherwise = case TE.decodeUtf8' payload of
        Left _ -> pure (Left ConfigWireInvalidUtf8)
        Right source -> do
            decoded <-
                trySynchronous
                    ( decodeProjectCodecWithSettings
                        projectCodec
                        Dhall.defaultInputSettings
                        source
                    )
            case decoded of
                Left _ -> pure (Left ConfigWireCodecRejected)
                Right value
                    | renderScopedProjectConfigBytes projectCodec value /= payload ->
                        pure (Left ConfigWireNonCanonical)
                    | otherwise ->
                        Right
                            <$> mintValidatedConfig
                                (authenticatedConfigDigest authenticated)
                                value
                                use
  where
    payload = authenticatedConfigBytes authenticated

-- | Result of installing authenticated bytes at the current binary's sibling
-- config path.  An identical incumbent is a successful idempotent replay of
-- installation, not permission to overwrite it.
data SiblingConfigInstallResult
    = SiblingConfigInstalled
    | SiblingConfigAlreadyPresent
    deriving (Eq, Show)

-- | Fail-closed sibling installation errors.  Payload bytes and OS exception
-- text are deliberately absent from this vocabulary.
data SiblingConfigInstallError
    = SiblingConfigUnsafeDestination FilePath
    | SiblingConfigConflict FilePath
    | SiblingConfigInstallFailed FilePath
    deriving (Eq, Show)

siblingConfigInstallErrorMessage :: SiblingConfigInstallError -> Text
siblingConfigInstallErrorMessage failure = case failure of
    SiblingConfigUnsafeDestination path ->
        "refusing non-regular or linked sibling config destination: " <> T.pack path
    SiblingConfigConflict path ->
        "refusing to replace a differing sibling config: " <> T.pack path
    SiblingConfigInstallFailed path ->
        "failed to install the authenticated sibling config: " <> T.pack path

-- | Production scopes can install only beside the exact installed project
-- whose generative identity appears in the payload scope.
installAuthenticatedProductionSiblingConfig ::
    InstalledProject projectId ->
    AuthenticatedConfigPayload (Production projectId) brokerGeneration ->
    IO (Either SiblingConfigInstallError SiblingConfigInstallResult)
installAuthenticatedProductionSiblingConfig project =
    installAuthenticatedSiblingConfig project . authenticatedConfigBytes

-- | Harness scopes preserve the same project identity and their exact run
-- identity while deriving the destination solely from the installed project
-- and the current executable.
installAuthenticatedHarnessSiblingConfig ::
    InstalledProject projectId ->
    AuthenticatedConfigPayload (Harness projectId runId) brokerGeneration ->
    IO (Either SiblingConfigInstallError SiblingConfigInstallResult)
installAuthenticatedHarnessSiblingConfig project =
    installAuthenticatedSiblingConfig project . authenticatedConfigBytes

installAuthenticatedSiblingConfig ::
    InstalledProject projectId ->
    BS.ByteString ->
    IO (Either SiblingConfigInstallError SiblingConfigInstallResult)
installAuthenticatedSiblingConfig project payload = do
    path <- siblingProjectConfigPath (installedProjectName project)
    attempted <-
        trySynchronous
            ( withSiblingConfigInstallLock path $ do
                existing <- inspectSiblingConfig path payload
                case existing of
                    SiblingMissing -> createSiblingConfig path payload
                    SiblingIdentical -> pure (Right SiblingConfigAlreadyPresent)
                    SiblingUnsafe -> pure (Left (SiblingConfigUnsafeDestination path))
                    SiblingDifferent -> pure (Left (SiblingConfigConflict path))
            )
    pure $ case attempted of
        Left _ -> Left (SiblingConfigInstallFailed path)
        Right result -> result

data ExistingSibling
    = SiblingMissing
    | SiblingIdentical
    | SiblingDifferent
    | SiblingUnsafe

inspectSiblingConfig :: FilePath -> BS.ByteString -> IO ExistingSibling
inspectSiblingConfig path expected = do
    linked <- pathIsSymbolicLinkIfPresent path
    if linked
        then pure SiblingUnsafe
        else do
            present <- doesPathExist path
            if not present
                then pure SiblingMissing
                else do
                    regular <- doesFileExist path
                    if not regular
                        then pure SiblingUnsafe
                        else
                            withBinaryFile path ReadMode $ \handle -> do
                                size <- hFileSize handle
                                if size /= fromIntegral (BS.length expected)
                                    then pure SiblingDifferent
                                    else do
                                        actual <- BS.hGet handle (BS.length expected + 1)
                                        pure
                                            ( if actual == expected
                                                then SiblingIdentical
                                                else SiblingDifferent
                                            )

createSiblingConfig ::
    FilePath ->
    BS.ByteString ->
    IO (Either SiblingConfigInstallError SiblingConfigInstallResult)
createSiblingConfig path payload =
    mask $ \restore -> do
        (temporary, handle) <- openBinaryTempFile (takeDirectory path) ".hostbootstrap-config.tmp"
        let removeTemporary = do
                present <- doesFileExist temporary
                when present (removeFile temporary)
            closeAndRemove = hClose handle `finally` removeTemporary
        restore (BS.hPut handle payload >> hFlush handle)
            `onException` closeAndRemove
        hClose handle `onException` removeTemporary
        -- A HARD link, not a symbolic one: it publishes the written bytes under
        -- the final name in one create-if-absent kernel operation, and a taken
        -- name fails rather than being replaced. A symlink would publish a
        -- *reference* to the temporary — which 'inspectSiblingConfig' refuses
        -- as a linked destination, and which 'removeTemporary' would then leave
        -- dangling — so the success branch below could never be reached.
        linked <- trySynchronous (restore (linkNoReplace temporary path))
        result <- case linked of
            Right () -> do
                installed <- inspectSiblingConfig path payload
                pure $ case installed of
                    SiblingIdentical -> Right SiblingConfigInstalled
                    SiblingDifferent -> Left (SiblingConfigConflict path)
                    _ -> Left (SiblingConfigUnsafeDestination path)
            Left _ -> do
                raced <- inspectSiblingConfig path payload
                pure $ case raced of
                    SiblingIdentical -> Right SiblingConfigAlreadyPresent
                    SiblingDifferent -> Left (SiblingConfigConflict path)
                    SiblingUnsafe -> Left (SiblingConfigUnsafeDestination path)
                    SiblingMissing -> Left (SiblingConfigInstallFailed path)
        removeTemporary
        pure result

-- A process-wide guard complements the kernel lock because POSIX record locks
-- are process-scoped rather than thread-scoped.  The path-level create-if-
-- absent operation remains the authority against non-cooperating actors.
{-# NOINLINE siblingConfigInstallMutex #-}
siblingConfigInstallMutex :: MVar ()
siblingConfigInstallMutex = unsafePerformIO (newMVar ())

withSiblingConfigInstallLock :: FilePath -> IO result -> IO result
withSiblingConfigInstallLock path action =
    withMVar siblingConfigInstallMutex $ \_ ->
        mask $ \restore -> do
            let lockPath = path <> ".hostbootstrap-handoff.lock"
            linked <- pathIsSymbolicLinkIfPresent lockPath
            when linked (ioError (userError "sibling config lock path is linked"))
            lockHandle <- openBinaryFile lockPath AppendMode
            relinked <- pathIsSymbolicLinkIfPresent lockPath
            when relinked (hClose lockHandle >> ioError (userError "sibling config lock path changed identity"))
            restore (hLock lockHandle ExclusiveLock)
                `onException` hClose lockHandle
            restore action `finally` hClose lockHandle

pathIsSymbolicLinkIfPresent :: FilePath -> IO Bool
pathIsSymbolicLinkIfPresent path =
    pathIsSymbolicLink path `catchIOError` const (pure False)

{- | Interpret one restricted harness assembly and admit its result with the
codec carrying the exact same project/run scope. The authority is consumed only
as the matching type witness; its constructor remains private.
-}
withAssembledHarnessConfig ::
    [ConfigInput] ->
    HarnessAuthority projectId runId ->
    ProjectCodec (Harness projectId runId) specDigest cfg ->
    ConfigAssembly (Harness projectId runId) (cfg (Harness projectId runId)) ->
    ( forall configDigest configId.
      VerifiedConfigWire (Harness projectId runId) configDigest configId ->
      ValidatedConfig
        (Harness projectId runId)
        specDigest
        configId
        (cfg (Harness projectId runId)) ->
      IO result
    ) ->
    IO (Either String result)
withAssembledHarnessConfig allowed authority codec assembly use = do
    authority `seq` pure ()
    assembled <- runConfigAssembly allowed assembly
    case assembled of
        Left err -> pure (Left err)
        Right value -> withValidatedConfig codec value use

{- | Validate that the runtime context inside the config belongs to the derived
project/binary identity. Generic: reaches the context via 'cfgContext'.
-}
validateProjectConfigForProject ::
    (ProjectCfg projectId cfg) =>
    Text ->
    cfg configScope ->
    Either String (cfg configScope)
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

{- | Run an action with a validated sibling project config and its nested
runtime context.
-}
withSiblingProjectConfigContext ::
    (ProjectCfg projectId cfg) =>
    ProjectCodec configScope specDigest cfg ->
    Text ->
    Context.CommandClass ->
    [Context.Capability] ->
    (cfg configScope -> BinaryContext -> IO a) ->
    IO a
withSiblingProjectConfigContext codec projectName cls caps action = do
    withSiblingProjectConfigRoot codec projectName cls caps $ \cfg cfgCtx _ ->
        action cfg cfgCtx

{- | Load the sibling once, apply the normal runtime/root gate, then
canonically render/re-decode it through the same finalized codec. The callback
receives fresh wire/config identities and cannot let a raw config bypass
verification.
-}
withSiblingValidatedProjectConfigContext ::
    forall projectId cfg configScope specDigest result.
    (ProjectCfg projectId cfg) =>
    ProjectCodec configScope specDigest cfg ->
    Text ->
    Context.CommandClass ->
    [Context.Capability] ->
    ( forall configDigest configId.
      VerifiedConfigWire configScope configDigest configId ->
      ValidatedConfig
        configScope
        specDigest
        configId
        (cfg configScope) ->
      BinaryContext ->
      IO result
    ) ->
    IO result
withSiblingValidatedProjectConfigContext codec projectName cls caps action =
    withSiblingProjectConfigRoot codec projectName cls caps $ \cfg cfgCtx _ -> do
        admitted <-
            withValidatedConfig codec cfg $ \wire validated ->
                action wire validated cfgCtx
        either (die . ("project config verification failed: " ++)) pure admitted

{- | Read the sibling **once**, apply the runtime/root gate, and admit the exact
snapshot through the same finalized codec — yielding the verified wire, the
'ValidatedConfig', its context, and the canonical root together.

This is the seam the project lifecycle verbs use (§ 15.9). Its point is that
every later consumer — plan construction, each chain step, each child projection
— receives *this* snapshot rather than reopening @<project>.dhall@. A file
replaced after admission therefore cannot change what the running plan is
executing; the next invocation validates a new snapshot under a new @configId@.
-}
withSiblingValidatedProjectConfigRoot ::
    forall projectId cfg configScope specDigest result.
    (ProjectCfg projectId cfg) =>
    ProjectCodec configScope specDigest cfg ->
    Text ->
    Context.CommandClass ->
    [Context.Capability] ->
    ( forall configDigest configId rootScope rootId.
      VerifiedConfigWire configScope configDigest configId ->
      ValidatedConfig configScope specDigest configId (cfg configScope) ->
      BinaryContext ->
      CanonicalProjectRoot rootScope rootId ->
      IO result
    ) ->
    IO result
withSiblingValidatedProjectConfigRoot codec projectName cls caps action =
    withSiblingProjectConfigRoot codec projectName cls caps $ \cfg cfgCtx root -> do
        admitted <-
            withValidatedConfig codec cfg $ \wire validated ->
                action wire validated cfgCtx root
        either (die . ("project config verification failed: " ++)) pure admitted

{- | Run an action with the validated config/context and the still-opaque
canonical root authority minted during that same admission. Lifecycle callers
use this seam so the root is not reconstructed from the descriptive context.
-}
withSiblingProjectConfigRoot ::
    forall projectId cfg configScope specDigest a.
    (ProjectCfg projectId cfg) =>
    ProjectCodec configScope specDigest cfg ->
    Text ->
    Context.CommandClass ->
    [Context.Capability] ->
    (forall rootScope rootId. cfg configScope -> BinaryContext -> CanonicalProjectRoot rootScope rootId -> IO a) ->
    IO a
withSiblingProjectConfigRoot codec projectName cls caps action = do
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
            decoded <-
                trySynchronous
                    (decodeProjectCodecWithSettings codec inputSettings raw)
            cfg <- case decoded of
                Left err -> failProjectConfig path ("failed to decode " ++ path ++ ": " ++ firstLine (show err))
                Right value -> pure value
            case validateProjectConfigForProject projectName cfg of
                Left err -> failProjectConfig path err
                Right validCfg -> do
                    rooted <-
                        withCanonicalProjectRoot
                            path
                            (T.unpack (Context.sourceRoot (cfgContext validCfg)))
                            ( \root -> do
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
                                        action validCfg cfgCtx root
                            )
                    case rooted of
                        Left rootErr -> failProjectConfig path (renderProjectRootError rootErr)
                        Right value -> pure value
  where
    firstLine = takeWhile (/= '\n')
    failProjectConfig _ detail = do
        hPutStrLn stderr ("project config: " ++ detail)
        exitWith (ExitFailure 1)

    renderProjectRootError (ProjectRootMissing root) =
        "sourceRoot does not name an existing directory: " ++ root
    renderProjectRootError (ProjectRootNotDirectory root) =
        "sourceRoot is not a directory: " ++ root
    renderProjectRootError (ProjectRootEscapesAnchor root anchor) =
        "relative sourceRoot escapes its config-owned project anchor: " ++ root ++ " (anchor " ++ anchor ++ ")"
    renderProjectRootError (ProjectRootResolutionFailed root detail) =
        "failed to canonicalize sourceRoot " ++ root ++ ": " ++ firstLine detail
    renderProjectRootError (ProjectRootSegmentUnsafe segment) =
        "a path segment under the project root is not a single ordinary component: " ++ segment

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
        ]
