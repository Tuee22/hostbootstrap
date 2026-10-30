{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SchemaSpec (tests) where

import Control.Concurrent (forkFinally, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (bracket, evaluate, mask, try)
import Control.Monad (forM_)
import qualified Data.ByteString as BS
import Data.List (isInfixOf, nub, sort)
import Data.Proxy (Proxy (Proxy))
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Data.Void (Void)
import qualified Dhall
import Dhall.Parser (Src)
import qualified Dhall.TypeCheck
import Expect (expectRight)
import Fixture (
    DeployConfig (..),
    FixtureProject,
    ProjectConfig (..),
    Resources (..),
    SecretFixtureProject,
    SecretProjectConfig (..),
    decodeProjectConfigFile,
    decodeProjectConfigText,
    decodeTestConfigText,
    defaultProjectConfig,
    defaultTestConfig,
    deriveProjectConfigForKind,
    projectConfigCodec,
    renderProjectConfig,
    renderTestConfig,
    withFixtureHarnessAuthority,
    withFixtureInstalledProject,
 )
import GHC.IO.Encoding (getLocaleEncoding, latin1, setLocaleEncoding)
import HostBootstrap.Authority (ProjectVerb (ProjectUp))
import HostBootstrap.Config.Class (
    ExistingOutputPolicy (..),
    ProjectCfg (..),
    configInput,
    decodeProjectCodecWithSettings,
    projectCodecSchemaText,
    projectCodecSpecDigest,
    pureConfigAssembly,
    readConfigInput,
    renderProjectCodecValue,
    runConfigAssembly,
 )
import HostBootstrap.Config.Fields (
    KnownScopeKind (scopeKindOf),
    ScopeKind (..),
    WireKind (..),
    decodeFrameworkEnvelopeWithSettings,
    decodeRoleWire,
    frameworkEnvelopeCodec,
    frameworkScopeKind,
    frameworkSpecDigest,
    frameworkWireKind,
    inspectConfigWireKind,
    inspectFullConfig,
    inspectLocalContext,
    renderRoleWire,
    renderValidatedServiceRequest,
 )
import HostBootstrap.Config.Schema (
    ConfigPublishOutcome (..),
    parseConfigRole,
    projectConfigSnapshotHash,
    publishScopedProjectConfigFile,
    renderProjectConfigSnapshotLog,
    renderScopedProjectConfigBytes,
    validateProjectConfigForProject,
    validatedConfigDigest,
    validatedConfigSpecDigest,
    validatedConfigValue,
    verifiedConfigDigest,
    withAssembledHarnessConfig,
    withAuthenticatedConfigWire,
    withValidatedConfig,
    writeProjectConfigFile,
 )
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Context (
    BinaryContext (..),
    Capability (..),
    CommandClass (..),
    ContextFrame (..),
    ContextKind (..),
    ProviderKind (..),
    TopologyFrame (..),
    allContextKinds,
    commandAllowed,
    contextForKind,
    defaultRoleName,
 )
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Handoff (
    AuthenticatedConfigPayload,
    HandoffBindingInput (..),
    HandoffError (..),
    HandoffPayloadKind (NarrowedProjectConfig),
    childConfigDigest,
    frameWire,
    freshChallenge,
    grantHandoff,
    handoffOfferFrames,
    handoffOfferWire,
    mkHandoffOffer,
    productionHandoffScope,
    projectSigningKeyFromBytes,
    registerHandoffEdge,
    relayBinding,
    rootBrokerVerificationKey,
    verifiedConfigPayload,
    verifyHandoff,
    withRootBroker,
 )
import HostBootstrap.Lifecycle.Mode (productionRootAuthority, withProductionRoot)
import HostBootstrap.Protected (openProtectedStore)
import HostBootstrap.RoleLifecycle (
    DeclaredEffects (NoEffects),
    RoleAcquireOutcome (Acquired),
    RolePrereqOutcome (PrereqSatisfied),
    RoleProbeOutcome (ProbeReadyNow),
    RoleReleaseOutcome (Released),
    mkRoleResourceRequest,
    rolePlanDraft,
 )
import HostBootstrap.Service (
    ServiceRegistry,
    ServiceResourceBackend (..),
    serviceId,
    serviceProgramDefinition,
    serviceRegistry,
    withFinalizedServiceRegistry,
    withSelectedServiceProgram,
 )
import HostBootstrap.Service.Program (ServiceBackend (..))
import qualified SourceGuard
import System.Directory (canonicalizePath, doesFileExist, getCurrentDirectory, getTemporaryDirectory, listDirectory, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Tasty (TestTree, localOption, mkTimeout, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

type DhallTypeError = Dhall.TypeCheck.TypeError Src Void

validConfig :: String
validConfig = T.unpack (renderProjectConfig expected)

expected :: ProjectConfig ()
expected =
    ProjectConfig
        { dockerfile = "docker/Dockerfile"
        , resources = Resources 4 "8GiB" "20GiB"
        , context =
            BinaryContext
                { project = "demo"
                , binary = "demo"
                , sourceRoot = "/workspace/demo"
                , contextKind = HostOrchestrator
                , roleName = "host-orchestrator"
                , parentChain = []
                , topologyFrames =
                    [ TopologyFrame "host-orchestrator-0" "" HostProvider HostOrchestrator "host-orchestrator"
                    ]
                , currentFrame = "host-orchestrator-0"
                , runtimeWitnesses = []
                , capabilities = [HostTools, IncusProvider]
                , allowedCommandClasses =
                    [ EnsureCommand
                    , ConfigInspectionCommand
                    , ConfigGenerationCommand
                    , ContextCreationCommand
                    , ClusterLifecycleCommand
                    , TestWorkflowCommand
                    , CheckCodeCommand
                    , HostOrchestratorCommand
                    , ProjectCommand
                    ]
                , childContextKinds = [VMOrchestrator, ClusterService, Daemon, OneShotJob, TestHarness]
                }
        , deploy = DeployConfig{haReplicas = 1}
        }

tests :: TestTree
tests =
    testGroup
        "SchemaSpec"
        [ testCase "decodes a valid project-local config" $ do
            decoded <- decodeProjectConfigText (toText validConfig)
            decoded @?= expected
        , testCase "rendered project-local config decodes back" $ do
            decoded <- decodeProjectConfigText (renderProjectConfig expected)
            decoded @?= expected
        , testCase "rendered test.dhall decodes back to the same TestConfig" $ do
            let tc = defaultTestConfig (Resources 6 "10GiB" "80GiB")
            decoded <- decodeTestConfigText (renderTestConfig tc)
            decoded @?= tc
        , testCase "rendered config hoists each vocabulary union into a single let" $ do
            let rendered = renderProjectConfig (defaultProjectConfig "demo" "/workspace/demo" HostOrchestrator)
            -- Each union is declared once at the top, not inlined at every use site.
            T.count "let ContextKind =" rendered @?= 1
            T.count "let ProviderKind =" rendered @?= 1
            T.count "let WitnessKind =" rendered @?= 1
            T.count "let Capability =" rendered @?= 1
            T.count "let CommandClass =" rendered @?= 1
            T.count "< HostOrchestrator" rendered @?= 1
            assertBool
                "use sites reference the hoisted binding"
                ("ContextKind.HostOrchestrator" `T.isInfixOf` rendered)
        , testCase "a malformed config fails with a typed error" $ do
            -- This record is syntactically valid but lacks required resources.
            result <-
                try (decodeProjectConfigText "{ dockerfile = \"x\" }") ::
                    IO (Either DhallTypeError (ProjectConfig ()))
            case result of
                Left failure ->
                    assertBool
                        "the type error identifies the missing resources field"
                        ("resources" `T.isInfixOf` T.pack (show failure))
                Right s -> assertFailure ("expected a decode error, got " ++ show s)
        , testCase "a wrong-typed field fails with a typed error" $ do
            result <-
                try (decodeProjectConfigText (toText badTypeConfig)) ::
                    IO (Either DhallTypeError (ProjectConfig ()))
            case result of
                Left failure ->
                    assertBool
                        "the type error identifies the wrong-typed haReplicas field"
                        ("haReplicas" `T.isInfixOf` T.pack (show failure))
                Right value -> assertFailure ("expected a haReplicas type error, got " ++ show value)
        , testCase "decodes the canonical example.dhall fixture" decodeFixture
        , testCase "validates the runtime context against the Cabal-derived project name" $ do
            validateProjectConfigForProject "demo" expected @?= Right expected
            validateProjectConfigForProject "other" expected
                @?= Left "project config: expected project other, got demo"
        , testCase "validates the runtime binary against the Cabal-derived project name" $ do
            let wrongBinary = expected{context = (context expected){binary = "other"}}
            validateProjectConfigForProject "demo" wrongBinary
                @?= Left "project config: expected binary demo, got other"
        , testCase "parses canonical role names and aliases" $ do
            parseConfigRole "host" @?= Right HostOrchestrator
            parseConfigRole "vm-project-container" @?= Right VMProjectContainer
            parseConfigRole "image-build-container" @?= Right ImageBuildContainer
            parseConfigRole "one_shot" @?= Right OneShotJob
            parseConfigRole "unknown" @?= Left "unknown config role unknown (expected one of: host-orchestrator, vm-orchestrator, vm-project-container, image-build-container, cluster-service, daemon, one-shot-job, test-harness)"
        , testCase "the advertised role set is the accepted role set" $ do
            forM_ allContextKinds $ \kind ->
                parseConfigRole (T.unpack (defaultRoleName kind)) @?= Right kind
            forM_
                [ ("host", HostOrchestrator)
                , ("vm", VMOrchestrator)
                , ("container", VMProjectContainer)
                , ("ad-hoc-container", VMProjectContainer)
                , ("image-build", ImageBuildContainer)
                , ("service", ClusterService)
                , ("one-shot", OneShotJob)
                , ("test", TestHarness)
                ]
                (\(alias, kind) -> parseConfigRole alias @?= Right kind)
        , testCase "the Production scope index determines its descriptive tag" $
            scopeKindOf (Proxy :: Proxy (V.Production FixtureProject)) @?= ProductionScope
        , testCase "the Harness scope index determines its descriptive tag" $
            scopeKindOf (Proxy :: Proxy (V.Harness FixtureProject ())) @?= HarnessScope
        , testCase "wire classification distinguishes codec-rendered full and role configs" $
            withProductionProjectCodec @ProjectConfig @FixtureProject $ \baseCodec ->
                withFinalizedServiceRegistry ProductionScope baseCodec schemaServiceRegistry $ \codec registry -> do
                    let cfg = defaultProjectConfig "demo" "." ClusterService
                        fullText = renderProjectCodecValue codec cfg
                    inspectConfigWireKind Dhall.defaultInputSettings fullText >>= (@?= FullProjectWire)
                    selected <-
                        either assertFailure pure $
                            withSelectedServiceProgram
                                (childConfigDigest (renderScopedProjectConfigBytes codec cfg))
                                (inspectLocalContext (context cfg))
                                cfg
                                registry
                                ( \_ roleCodec request _ _ _ _ -> do
                                    decoded <-
                                        decodeRoleWire
                                            roleCodec
                                            Dhall.defaultInputSettings
                                            (renderValidatedServiceRequest roleCodec request)
                                    role <- either assertFailure pure decoded
                                    let roleText = renderRoleWire roleCodec role
                                    inspectConfigWireKind Dhall.defaultInputSettings roleText >>= (@?= ServiceRoleWire)
                                    inspectConfigWireKind Dhall.defaultInputSettings ("{ unrelated = (" <> roleText <> ") }")
                                        >>= (@?= FullProjectWire)
                                    inspectConfigWireKind Dhall.defaultInputSettings ("let ignored = (" <> roleText <> ") in (" <> fullText <> ")")
                                        >>= (@?= FullProjectWire)
                                )
                    selected
        , testCase "wire classification ignores descriptive names in comments and text" $
            forM_
                [ "-- roleFrameworkValidation = ServiceRoleWire\n{ value = 1 }"
                , "{ value = \"roleFrameworkValidation ServiceRoleWire\" }"
                , "{ roleFrameworkValidation = \"ServiceRoleWire\" }"
                , "{ resources ="
                ]
                (\input -> inspectConfigWireKind Dhall.defaultInputSettings input >>= (@?= FullProjectWire))
        , testCase "an admitted full envelope retains the codec scope and specification digest" $
            withProductionProjectCodec @ProjectConfig @FixtureProject $ \codec -> do
                let cfg = defaultProjectConfig "demo" "." HostOrchestrator
                    envelope = frameworkEnvelopeCodec (scopeKindOf (Proxy :: Proxy (V.Production FixtureProject))) codec
                admitted <- decodeFrameworkEnvelopeWithSettings envelope Dhall.defaultInputSettings (renderProjectCodecValue codec cfg)
                admitted @?= cfg
                let validation = inspectFullConfig envelope admitted
                frameworkWireKind validation @?= FullProjectWire
                frameworkScopeKind validation @?= ProductionScope
                frameworkSpecDigest validation @?= projectCodecSpecDigest codec
        , testCase "default role configs decode and re-render stably" $ do
            mapM_
                ( \role -> do
                    let cfg = defaultProjectConfig "demo" "/workspace/demo" role
                    decoded <- decodeProjectConfigText (renderProjectConfig cfg)
                    decoded @?= cfg
                    contextKind (context cfg) @?= role
                )
                [HostOrchestrator, VMOrchestrator, VMProjectContainer, ImageBuildContainer, ClusterService, Daemon, OneShotJob, TestHarness]
        , testCase "child projections preserve project settings and narrow authority" $ do
            let host = defaultProjectConfig "demo" "/workspace/demo" HostOrchestrator
            vm <- expectRight (deriveProjectConfigForKind VMOrchestrator host "/vm/demo")
            service <- expectRight (deriveProjectConfigForKind ClusterService vm "/srv/demo")
            let expectedVM = contextForKind "demo" "demo" "/vm/demo" VMOrchestrator
                expectedService = contextForKind "demo" "demo" "/srv/demo" ClusterService
            dockerfile vm @?= dockerfile host
            deploy service @?= deploy host
            resources vm @?= resources host
            contextKind (context vm) @?= VMOrchestrator
            capabilities (context vm) @?= capabilities expectedVM
            allowedCommandClasses (context vm) @?= allowedCommandClasses expectedVM
            assertBool "the VM child excludes host-orchestrator commands" $
                HostOrchestratorCommand `notElem` allowedCommandClasses (context vm)
            parentChain (context vm) @?= [ContextFrame HostOrchestrator "demo"]
            topologyFrames (context vm)
                @?= [ TopologyFrame "host-orchestrator-0" "" HostProvider HostOrchestrator "host-orchestrator"
                    , TopologyFrame "vm-orchestrator-1" "host-orchestrator-0" IncusVMProvider VMOrchestrator "vm-orchestrator"
                    ]
            contextKind (context service) @?= ClusterService
            capabilities (context service) @?= capabilities expectedService
            allowedCommandClasses (context service) @?= allowedCommandClasses expectedService
            assertBool "the service child excludes host-orchestrator commands" $
                HostOrchestratorCommand `notElem` allowedCommandClasses (context service)
            parentChain (context service)
                @?= [ContextFrame HostOrchestrator "demo", ContextFrame VMOrchestrator "demo"]
        , testCase "the fixture projector declares no direct host-to-runtime-container child" $ do
            let host = defaultProjectConfig "demo" "/workspace/demo" HostOrchestrator
            assertBool "the fixture host excludes a direct runtime-container child" $
                VMProjectContainer `notElem` childContextKinds (context host)
        , testCase "generated roles cannot authorize illegal command families" $ do
            let host = defaultProjectConfig "demo" "/workspace/demo" HostOrchestrator
                container = defaultProjectConfig "demo" "/workspace/demo" VMProjectContainer
                imageBuild = defaultProjectConfig "demo" "/workspace/demo" ImageBuildContainer
                service = defaultProjectConfig "demo" "/workspace/demo" ClusterService
                daemon = defaultProjectConfig "demo" "/workspace/demo" Daemon
            commandAllowed (context host) HostOrchestratorCommand @?= True
            commandAllowed (context container) HostOrchestratorCommand @?= False
            commandAllowed (context imageBuild) CheckCodeCommand @?= True
            commandAllowed (context imageBuild) TestWorkflowCommand @?= False
            commandAllowed (context service) ServiceCommand @?= True
            commandAllowed (context host) ServiceCommand @?= False
            commandAllowed (context container) ServiceCommand @?= False
            commandAllowed (context daemon) DaemonCommand @?= True
            commandAllowed (context daemon) ServiceCommand @?= True
            commandAllowed (context host) DaemonCommand @?= False
        , testCase "ordinary admission retains the digest of the exact canonical config" $
            withProductionProjectCodec @ProjectConfig @FixtureProject $ \codec -> do
                let cfg =
                        defaultProjectConfig
                            "hostbootstrap-demo"
                            "/workspace/demo"
                            HostOrchestrator ::
                            ProjectConfig (V.Production FixtureProject)
                    payload = renderScopedProjectConfigBytes codec cfg
                    digest = childConfigDigest payload
                admitted <-
                    withValidatedConfig codec cfg $ \wire validated -> do
                        verifiedConfigDigest wire @?= digest
                        validatedConfigSpecDigest validated @?= projectCodecSpecDigest codec
                        validatedConfigDigest validated @?= digest
                        validatedConfigValue validated @?= cfg
                admitted @?= Right ()
        , testCase "authenticated admission retains its exact digest and refuses byte substitution" $
            withProductionProjectCodec @ProjectConfig @FixtureProject $ \renderCodec -> do
                let renderedCfg =
                        defaultProjectConfig
                            "hostbootstrap-demo"
                            "/workspace/demo"
                            HostOrchestrator ::
                            ProjectConfig (V.Production FixtureProject)
                    payload = renderScopedProjectConfigBytes renderCodec renderedCfg
                    digest = childConfigDigest payload
                withAuthenticatedFixtureConfig payload $
                    \(authenticated :: AuthenticatedConfigPayload (V.Production projectId) brokerGeneration) ->
                        withProductionProjectCodec @ProjectConfig @projectId $ \codec -> do
                            let cfg =
                                    defaultProjectConfig
                                        "hostbootstrap-demo"
                                        "/workspace/demo"
                                        HostOrchestrator ::
                                        ProjectConfig (V.Production projectId)
                            admitted <-
                                withAuthenticatedConfigWire codec authenticated $ \wire validated -> do
                                    verifiedConfigDigest wire @?= digest
                                    validatedConfigDigest validated @?= digest
                                    validatedConfigValue validated @?= cfg
                            admitted @?= Right ()
        , testCase "daemon snapshot log includes placement metadata and the config hash" $ do
            -- The logger accepts only a path, hash, and BinaryContext. Its
            -- signature excludes configuration text from the logging input.
            let daemon = defaultProjectConfig "demo" "/workspace/demo" Daemon
                hash = projectConfigSnapshotHash "password = \"secret\""
                line = renderProjectConfigSnapshotLog "/run/demo.dhall" hash (context daemon)
            assertBool "hash is tagged" ("fnv64:" `T.isPrefixOf` hash)
            assertBool "project is logged" ("project=demo" `T.isInfixOf` line)
            assertBool "role is logged" ("roleName=daemon" `T.isInfixOf` line)
            assertBool "path is logged" ("configPath=/run/demo.dhall" `T.isInfixOf` line)
            assertBool "hash is logged" (("configHash=" <> hash) `T.isInfixOf` line)
            assertBool "snapshot hash distinguishes physical line endings" $
                projectConfigSnapshotHash "line\n" /= projectConfigSnapshotHash "line\r\n"
        , -- The generated config's ownership is no longer a property of the
          -- writer. It moved to "HostBootstrap.Harness.GeneratedConfig", which
          -- holds the four § EE clauses over the file itself; GeneratedConfigSpec
          -- proves them. What remains here is the writer's own contract: the
          -- bytes it produces are exactly the bytes that protocol installs.
          testCase "the scoped writer produces exactly the bytes the ownership protocol installs" $ do
            tmp <- getTemporaryDirectory
            (path, handle) <- openTempFile tmp "hostbootstrap-owned-config.dhall"
            hClose handle
            writeProjectConfigFile projectConfigCodec path expected
            written <- BS.readFile path
            decoded <- decodeProjectConfigFile path
            removeFile path
            written @?= TE.encodeUtf8 (renderProjectConfig expected <> "\n")
            BS.elem 0x0d written @?= False
            decoded @?= expected
        , testCase "secrets-strict production codec omits and rejects TestPlaintext" $ do
            let cfg =
                    SecretProjectConfig
                        (context expected)
                        (V.promptSecret "database password") ::
                        SecretProjectConfig
                            (V.Production SecretFixtureProject)
            withProductionProjectCodec
                @SecretProjectConfig
                @SecretFixtureProject
                ( \codec -> do
                    assertBool
                        "production project schema has no plaintext alternative"
                        (not ("TestPlaintext" `T.isInfixOf` projectCodecSchemaText codec))
                    let rendered = renderProjectCodecValue codec cfg
                    decoded <-
                        decodeProjectCodecWithSettings
                            codec
                            Dhall.defaultInputSettings
                            rendered
                    decoded @?= cfg
                    admission <-
                        withValidatedConfig codec cfg $ \verified validated -> do
                            assertBool
                                "production verification carries a digest"
                                (isSha256Digest (verifiedConfigDigest verified))
                            validatedConfigValue validated @?= cfg
                    admission @?= Right ()
                    harnessRendering <-
                        withFixtureHarnessAuthority
                            ( \_project authority ->
                                pure $
                                    withHarnessProjectCodec
                                        @SecretProjectConfig
                                        (V.harnessConfigAuthority authority)
                                        ( \harnessCodec ->
                                            renderProjectCodecValue
                                                harnessCodec
                                                ( SecretProjectConfig
                                                    (context expected)
                                                    ( V.testPlaintextSecret
                                                        (V.harnessConfigAuthority authority)
                                                        (V.TestSecret "hunter2")
                                                    )
                                                )
                                        )
                            )
                    injected <- evaluate harnessRendering
                    assertBool
                        "the rendered harness config contains TestPlaintext"
                        ("TestPlaintext" `T.isInfixOf` injected)
                    result <-
                        try
                            ( decodeProjectCodecWithSettings
                                codec
                                Dhall.defaultInputSettings
                                injected
                            ) ::
                            IO
                                ( Either
                                    DhallTypeError
                                    ( SecretProjectConfig
                                        (V.Production SecretFixtureProject)
                                    )
                                )
                    case result of
                        Left failure ->
                            assertBool
                                "the production project type error identifies TestPlaintext"
                                ("TestPlaintext" `T.isInfixOf` T.pack (show failure))
                        Right value -> assertFailure ("production decoded harness plaintext: " ++ show value)
                )
        , testCase "matching harness authority admits plaintext and mints verified scoped config" $
            withFixtureHarnessAuthority
                ( \_project authority ->
                    withHarnessProjectCodec
                        @SecretProjectConfig
                        (V.harnessConfigAuthority authority)
                        ( \codec -> do
                            assertBool
                                "harness schema admits the fixture-only alternative"
                                ("TestPlaintext" `T.isInfixOf` projectCodecSchemaText codec)
                            let cfg =
                                    SecretProjectConfig
                                        (context expected)
                                        ( V.testPlaintextSecret
                                            (V.harnessConfigAuthority authority)
                                            (V.TestSecret "fixture-value")
                                        )
                            outcome <-
                                withAssembledHarnessConfig
                                    []
                                    authority
                                    codec
                                    (pureConfigAssembly cfg)
                                    ( \verified validated -> do
                                        assertBool
                                            "verified canonical bytes carry a digest"
                                            (isSha256Digest (verifiedConfigDigest verified))
                                        let SecretProjectConfig _ admitted =
                                                validatedConfigValue validated
                                        pure (V.secretRefView admitted)
                                    )
                            outcome
                                @?= Right
                                    (V.SecretTestPlaintext (V.TestSecret "fixture-value"))
                        )
                )
        , testCase "ConfigAssembly reads only declared text inputs" $
            withSystemTempDirectory "hostbootstrap-config-assembly" $ \dir -> do
                let path = dir </> "test-secrets.dhall"
                    declared = configInput path
                    assembly = readConfigInput declared
                TIO.writeFile path "fixture-secret"
                undeclared <- runConfigAssembly [] assembly
                assertBool
                    "undeclared read is rejected"
                    (either (T.isInfixOf "undeclared read" . T.pack) (const False) undeclared)
                runConfigAssembly [declared] assembly
                    >>= (@?= Right "fixture-secret")
        , testCase "ConfigAssembly decodes a declared input as UTF-8 under any locale" $
            withSystemTempDirectory "hostbootstrap-config-utf8" $ \dir -> do
                let path = dir </> "utf8-input.dhall"
                    declared = configInput path
                BS.writeFile path (BS.pack [0xc3, 0xa9])
                bracket getLocaleEncoding setLocaleEncoding $ \_ -> do
                    setLocaleEncoding latin1
                    runConfigAssembly [declared] (readConfigInput declared)
                        >>= (@?= Right "é")
        , testCase "ConfigAssembly refuses a declared input that is not UTF-8" $
            withSystemTempDirectory "hostbootstrap-config-invalid-utf8" $ \dir -> do
                let path = dir </> "invalid-utf8-input.dhall"
                    declared = configInput path
                BS.writeFile path (BS.pack [0xff])
                bracket getLocaleEncoding setLocaleEncoding $ \_ -> do
                    setLocaleEncoding latin1
                    runConfigAssembly [declared] (readConfigInput declared)
                        >>= (@?= Left ("config assembly could not decode " ++ path ++ " as UTF-8"))
        , localOption (mkTimeout 60000000) $ testCase "init publication refuses under a concurrent peer" $
            withProductionProjectCodec @ProjectConfig @FixtureProject $ \codec ->
                forM_ [1 .. 50 :: Int] $ \roundNumber ->
                    withSystemTempDirectory ("hostbootstrap-config-race-" <> show roundNumber) $ \directory -> do
                        let path = directory </> "demo.dhall"
                            firstConfig = defaultProjectConfig "demo" "." HostOrchestrator
                            secondConfig = firstConfig{dockerfile = "docker/é.Dockerfile"}
                            firstBytes = renderScopedProjectConfigBytes codec firstConfig
                            secondBytes = renderScopedProjectConfigBytes codec secondConfig
                        assertBool "the competing fixture configs have different bytes" (firstBytes /= secondBytes)
                        outcomes <-
                            runPublicationRace
                                (publishScopedProjectConfigFile RefuseExistingOutput codec path firstConfig)
                                (publishScopedProjectConfigFile RefuseExistingOutput codec path secondConfig)
                        winnerBytes <- case outcomes of
                            (ConfigPublished, ConfigRefusedExisting) -> pure firstBytes
                            (ConfigRefusedExisting, ConfigPublished) -> pure secondBytes
                            other -> assertFailure ("expected one creator and one refusal, got " <> show other)
                        BS.readFile path >>= (@?= winnerBytes)
                        listDirectory directory >>= (@?= ["demo.dhall"])
        , testCase "init publication applies each existing-file policy without leaving temporaries" $
            withProductionProjectCodec @ProjectConfig @FixtureProject $ \codec ->
                withSystemTempDirectory "hostbootstrap-config-publication" $ \directory -> do
                    let path = directory </> "demo.dhall"
                        original = BS.pack [0, 255, 13, 10, 128]
                        cfg = (defaultProjectConfig "demo" "." HostOrchestrator){dockerfile = "docker/é.Dockerfile"}
                        replacement = renderScopedProjectConfigBytes codec cfg
                    BS.writeFile path original
                    forM_
                        [ (RefuseExistingOutput, ConfigRefusedExisting, original)
                        , (KeepExistingOutput, ConfigKeptExisting, original)
                        , (OverwriteExistingOutput, ConfigPublished, replacement)
                        ]
                        ( \(policy, expectedOutcome, expectedBytes) -> do
                            publishScopedProjectConfigFile policy codec path cfg >>= (@?= expectedOutcome)
                            BS.readFile path >>= (@?= expectedBytes)
                            listDirectory directory >>= (@?= ["demo.dhall"])
                        )
        , testCase "the scoped config publisher never writes its output in place" $
            -- DEVELOPMENT_PLAN/rationale.md: "Init publishes complete config bytes".
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                description <- SourceGuard.readPackageDescription
                path <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Config.Schema"
                source <- readFile path
                tokens <-
                    either
                        assertFailure
                        pure
                        (SourceGuard.haskellDefinitionTokens "publishScopedProjectConfigFile" source)
                assertBool "publisher definition contains BS.writeFile" $
                    not (["BS", ".", "writeFile"] `isInfixOf` tokens)
        , testCase "harness plaintext has no parallel config-run getter" $
            -- DEVELOPMENT_PLAN/rationale.md: "Secret references are scope-indexed".
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                description <- SourceGuard.readPackageDescription
                sources <- SourceGuard.readLibrarySources packageRoot description
                forM_ sources $ \(name, path, source) -> do
                    definitions <-
                        either
                            (assertFailure . ((name ++ ": ") ++))
                            pure
                            (SourceGuard.haskellDefinitionNames source)
                    assertBool
                        ("harnessConfigRunName is defined by " ++ name ++ " at " ++ SourceGuard.repoRelativePath packageRoot path)
                        ("harnessConfigRunName" `notElem` definitions)
        , testCase "scope API removes the raw context updater and parallel config builders" $
            -- DEVELOPMENT_PLAN/rationale.md: "Core owns no default config values and no fixed config type".
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                description <- SourceGuard.readPackageDescription
                cliPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.CLI"
                cliSource <- readFile cliPath
                SourceGuard.recordFieldNames "ProjectSpec" cliSource
                    @?= Right
                        [ "psTestSuite", "psCheckCode", "psArtifacts", "psTestCodec", "psAssemblyInputs"
                        , "psServices", "psStepPlan", "psForwardChildPlan", "psTestInit", "psAssemble"
                        ]
                let directories =
                        sort . nub . concatMap SourceGuard.componentSourceDirs $
                            SourceGuard.componentStanzas description
                paths <- concat <$> traverse (SourceGuard.listHaskellSources . (packageRoot </>)) directories
                uniquePaths <- sort . nub <$> traverse canonicalizePath paths
                forM_ uniquePaths $ \path -> do
                    source <- readFile path
                    assertBool
                        ("cfgWithContext occurs in " ++ SourceGuard.repoRelativePath packageRoot path)
                        (SourceGuard.countHaskellIdentifier "cfgWithContext" source == 0)
        , testGroup "record field extraction" recordFieldCases
        , testGroup "value definition extraction" definitionTokenCases
        ]
  where
    badTypeConfig =
        T.unpack (T.replace "haReplicas = 1" "haReplicas = \"two\"" (renderProjectConfig expected))

schemaServiceRegistry :: ServiceRegistry ProjectConfig
schemaServiceRegistry =
    either (error . show) id $
        serviceRegistry
            [ serviceProgramDefinition
                (either error id (serviceId "schema"))
                (\_ -> Right (Just ("fixture parameters" :: T.Text)))
                NoEffects
                resourcesForSchema
                backendForSchema
                (\_ -> pure ())
            ]
  where
    resourcesForSchema =
        ServiceResourceBackend
            { serviceRolePlanDraft = either (error . show) id $ do
                request <- mkRoleResourceRequest "fixture" False
                rolePlanDraft [request]
            , servicePrerequisite = pure PrereqSatisfied
            , serviceAcquireResource = \_ -> pure Acquired
            , serviceProbeResource = \_ -> pure ProbeReadyNow
            , serviceReleaseResource = \_ -> pure Released
            }
    backendForSchema :: ServiceBackend ()
    backendForSchema =
        ServiceBackend
            { backendServe = \_ -> pure (Left "schema fixture declares no effects")
            , backendCall = \_ _ -> pure (Left "schema fixture declares no effects")
            , backendWork = \_ _ -> pure (Left "schema fixture declares no effects")
            }

runPublicationRace :: IO ConfigPublishOutcome -> IO ConfigPublishOutcome -> IO (ConfigPublishOutcome, ConfigPublishOutcome)
runPublicationRace first second =
    mask $ \restore -> do
        start <- newEmptyMVar
        firstReady <- newEmptyMVar
        secondReady <- newEmptyMVar
        firstResult <- newEmptyMVar
        secondResult <- newEmptyMVar
        let worker ready publish = restore $ do
                putMVar ready ()
                readMVar start
                publish
        bracket (forkFinally (worker firstReady first) (putMVar firstResult)) killThread $ \_ ->
            bracket (forkFinally (worker secondReady second) (putMVar secondResult)) killThread $ \_ ->
                restore $ do
                    ready <- timeout 5000000 (takeMVar firstReady >> takeMVar secondReady)
                    case ready of
                        Nothing -> assertFailure "publication workers did not reach the shared start barrier"
                        Just () -> pure ()
                    putMVar start ()
                    completed <- timeout 5000000 ((,) <$> takeMVar firstResult <*> takeMVar secondResult)
                    case completed of
                        Just (Right firstOutcome, Right secondOutcome) -> pure (firstOutcome, secondOutcome)
                        Just failures -> assertFailure ("publication worker failures (first, second): " <> show failures)
                        Nothing -> assertFailure "publication workers did not complete after the shared start barrier"

definitionTokenCases :: [TestTree]
definitionTokenCases =
    [ testCase ("complete value definition: " <> label) $
        SourceGuard.haskellDefinitionTokens "publisher" source @?= Right expectedTokens
    | (label, source, expectedTokens) <-
        [ ( "a multiline signature is excluded"
          , unlines ["publisher ::", "  Int -> IO Int", "publisher value = pure value", "next = BS.writeFile path bytes"]
          , ["publisher", "value", "=", "pure", "value"]
          )
        , ( "guards, nested patterns, and local bindings remain in the body"
          , unlines ["publisher (Just value)", "  | value > 0 = result", "  | otherwise = []", "  where", "    result = [(value, \"}\")]", "next = BS.writeFile path bytes"]
          , ["publisher", "(", "Just", "value", ")", "|", "value", ">", "0", "=", "result", "|", "otherwise", "=", "[", "]", "where", "result", "=", "[", "(", "value", ",", "\"}\"", ")", "]"]
          )
        , ( "comments and quoted fake definitions are ignored"
          , unlines ["{- publisher = BS.writeFile path bytes -}", "quoted = \"publisher = BS.writeFile path bytes\"", "publisher value = pure value -- BS.writeFile path bytes"]
          , ["publisher", "value", "=", "pure", "value"]
          )
        ]
    ]
        <> [ testCase ("value definition extraction refuses " <> label) $
                case SourceGuard.haskellDefinitionTokens "publisher" source of
                    Left _ -> pure ()
                    Right tokens -> assertFailure ("unsupported value definition was accepted: " <> show tokens)
           | (label, source) <-
                [ ("a missing binding", "other value = pure value")
                , ("a signature without an equation", "publisher :: Int -> IO Int")
                , ("multiple equations", "publisher True = pure True\npublisher False = pure False")
                , ("an unsupported infix left-hand side", "publisher + value = value")
                , ("an unbalanced body", "publisher value = pure (value")
                ]
           ]
        <> [ testCase "definition extraction exposes a truncating write in a local binding" $ do
                tokens <-
                    either assertFailure pure $
                        SourceGuard.haskellDefinitionTokens "publisher" $
                            unlines ["publisher path = write", "  where", "    write = BS.writeFile path bytes"]
                assertBool "a real nested BS.writeFile must be visible to the guard" $
                    ["BS", ".", "writeFile"] `isInfixOf` tokens
           ]

recordFieldCases :: [TestTree]
recordFieldCases =
    [ testCase ("ordered record fields: " ++ label) $
        SourceGuard.recordFieldNames "Target" source @?= Right expectedFields
    | (label, source, expectedFields) <-
        [ ( "multiline grouped and rank-2 fields"
          , unlines
                [ "data Target cfg = Target"
                , "  { first, second"
                , "      :: forall scope. (cfg scope, [Maybe Int]) -> ()"
                , "  , third :: Proxy (Ghost :: Type)"
                , "  } deriving (Show)"
                ]
          , ["first", "second", "third"]
          )
        , ( "comments, literals, and other records are not fields"
          , unlines
                [ "-- data Target = Fake { fake :: Int }"
                , "quoted = \"data Target = Fake { fake :: Int }\""
                , "data Other = Other { unrelated :: Int }"
                , "data Target = Target { zed :: Proxy \"{ fake :: Int }\", {- nested {- comment -} -} alpha :: [Int] }"
                ]
          , ["zed", "alpha"]
          )
        , ( "renamed extra fields remain visible"
          , "data Target = Target { allowed :: Int, renamedBuilder :: Bool }"
          , ["allowed", "renamedBuilder"]
          )
        ]
    ]
        <> [ testCase ("record field extraction refuses " ++ label) $
                case SourceGuard.recordFieldNames "Target" source of
                    Left _ -> pure ()
                    Right fields -> assertFailure ("unsupported record was accepted: " ++ show fields)
           | (label, source) <-
                [ ("missing declaration", "data Other = Other { field :: Int }")
                , ("ambiguous declaration", "data Target = First { first :: Int }\ndata Target = Second { second :: Bool }")
                , ("sum after record", "data Target = Target { field :: Int } | Other")
                , ("sum before record", "data Target = Other | Target { field :: Int }")
                , ("positional constructor", "data Target = Target Int")
                , ("positional field after record", "data Target = Target { field :: Int } Bool")
                , ("GADT constructor", "data Target where\n  Target :: { field :: Int } -> Target")
                , ("truncated record", "data Target = Target { field :: Int")
                , ("mismatched nested delimiters", "data Target = Target { field :: (Maybe [Int) }")
                , ("missing signature", "data Target = Target { field Int }")
                , ("empty type", "data Target = Target { field :: }")
                , ("duplicate label", "data Target = Target { field :: Int, field :: Bool }")
                ]
           ]

decodeFixture :: IO ()
decodeFixture = do
    cwd <- getCurrentDirectory
    mroot <- findRepoRoot cwd
    case mroot of
        Nothing -> assertFailure ("could not locate repo root from " ++ cwd)
        Just root -> do
            let path = root </> "core" </> "hostbootstrap-core" </> "dhall" </> "example.dhall"
            exists <- doesFileExist path
            assertBool ("fixture exists: " ++ path) exists
            contents <- readFile path
            decoded <- decodeProjectConfigFile path
            decoded @?= expected
            T.stripEnd (T.pack contents) @?= T.stripEnd (renderProjectConfig expected)

toText :: String -> T.Text
toText = T.pack

isSha256Digest :: T.Text -> Bool
isSha256Digest digest =
    T.length digest == 64
        && T.all (`elem` ("0123456789abcdef" :: String)) digest

withAuthenticatedFixtureConfig ::
    BS.ByteString ->
    ( forall projectId brokerGeneration.
      AuthenticatedConfigPayload
        (V.Production projectId)
        brokerGeneration ->
      IO result
    ) ->
    IO result
withAuthenticatedFixtureConfig payload use =
    withFixtureInstalledProject $ \installedIdentity ->
        withSystemTempDirectory "hostbootstrap-schema-authenticated-config" $ \directory -> do
            signing <- expectRightShow (projectSigningKeyFromBytes (BS.replicate 32 37))
            store <- expectRightIOShow (openProtectedStore (directory </> "authority"))
            rooted <-
                withProductionRoot store installedIdentity ProjectUp $ \root -> do
                    brokered <-
                        withRootBroker
                            (productionHandoffScope installedIdentity)
                            store
                            signing
                            (productionRootAuthority root)
                            (\broker -> authenticateAndUse broker)
                    result <- expectRightShow brokered
                    pure (Right result)
            expectRightShow rooted
  where
    authenticateAndUse broker = do
        (relay, token) <-
            expectRightIOShow
                (registerHandoffEdge broker (authenticatedBindingInput payload))
        let binding = relayBinding relay
        offer <- expectRightShow (mkHandoffOffer relay payload token)
        challenge <- freshChallenge
        grant <- expectRightIOShow (grantHandoff broker offer challenge)
        let (_, tokenBytes, bindingBytes) = handoffOfferFrames offer
            substitutedWire =
                frameWire (payload <> " ")
                    <> frameWire tokenBytes
                    <> frameWire bindingBytes
        case verifyHandoff
            (rootBrokerVerificationKey broker)
            substitutedWire
            binding
            challenge
            grant of
            Left (HandoffPayloadDigestMismatch expectedDigest actualDigest) ->
                assertBool
                    "substituted bytes have a different digest"
                    (expectedDigest /= actualDigest)
            other ->
                assertFailure
                    ("expected byte-substitution refusal, got " <> show other)
        verified <-
            expectRightShow
                ( verifyHandoff
                    (rootBrokerVerificationKey broker)
                    (handoffOfferWire offer)
                    binding
                    challenge
                    grant
                )
        authenticated <- expectRightShow (verifiedConfigPayload verified)
        use authenticated

authenticatedBindingInput :: BS.ByteString -> HandoffBindingInput
authenticatedBindingInput payload =
    HandoffBindingInput
        { requestedSpecDigest = "schema-spec-digest"
        , requestedPayloadKind = NarrowedProjectConfig
        , requestedPlanRevision = "schema-plan-revision"
        , requestedParentFrame = "host-orchestrator-0"
        , requestedChildFrame = "vm-project-container-1"
        , requestedChildConfigDigest = childConfigDigest payload
        , requestedPhase = "schema-admission"
        }

expectRightShow :: (Show error) => Either error value -> IO value
expectRightShow result =
    case result of
        Right value -> pure value
        Left failure -> assertFailure (show failure)

expectRightIOShow :: (Show error) => IO (Either error value) -> IO value
expectRightIOShow action = action >>= expectRightShow
