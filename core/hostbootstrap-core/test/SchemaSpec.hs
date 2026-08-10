{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SchemaSpec (tests) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString as BS
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Dhall
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
import HostBootstrap.Authority (ProjectVerb (ProjectUp))
import HostBootstrap.Config.Class (
    ProjectCfg (..),
    configInput,
    decodeProjectCodecWithSettings,
    projectCodecSpecDigest,
    projectCodecSchemaText,
    pureConfigAssembly,
    readConfigInput,
    renderProjectCodecValue,
    runConfigAssembly,
 )
import HostBootstrap.Config.Schema (
    parseConfigRole,
    projectConfigSnapshotHash,
    renderProjectConfigSnapshotLog,
    renderScopedProjectConfigBytes,
    validateProjectConfigForProject,
    validatedConfigDigest,
    validatedConfigSpecDigest,
    validatedConfigValue,
    verifiedConfigDigest,
    withAuthenticatedConfigWire,
    withAssembledHarnessConfig,
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
    commandAllowed,
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
import System.Directory (doesFileExist, getCurrentDirectory, getTemporaryDirectory, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

validConfig :: String
validConfig = T.unpack (renderProjectConfig expected)

expected :: ProjectConfig ()
expected =
    ProjectConfig
        { dockerfile = "docker/demo.Dockerfile"
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
            result <-
                try (decodeProjectConfigText "{ dockerfile = \"x\" }") ::
                    IO (Either SomeException (ProjectConfig ()))
            case result of
                Left _ -> pure ()
                Right s -> assertFailure ("expected a decode error, got " ++ show s)
        , testCase "a wrong-typed field fails with a typed error" $ do
            result <-
                try (decodeProjectConfigText (toText badTypeConfig)) ::
                    IO (Either SomeException (ProjectConfig ()))
            assertBool "expected a decode error for haReplicas : Text" (isLeft result)
        , testCase "decodes the canonical example.dhall fixture" decodeFixture
        , testCase "validates the runtime context against the Cabal-derived project name" $ do
            validateProjectConfigForProject "demo" expected @?= Right expected
            validateProjectConfigForProject "other" expected
                @?= Left "project config: expected project other, got demo"
        , testCase "parses canonical role names and aliases" $ do
            parseConfigRole "host" @?= Right HostOrchestrator
            parseConfigRole "vm-project-container" @?= Right VMProjectContainer
            parseConfigRole "image-build-container" @?= Right ImageBuildContainer
            parseConfigRole "one_shot" @?= Right OneShotJob
            parseConfigRole "unknown" @?= Left "unknown config role unknown (expected one of: host-orchestrator, vm-orchestrator, vm-project-container, image-build-container, cluster-service, daemon, one-shot-job, test-harness)"
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
            dockerfile vm @?= dockerfile host
            deploy service @?= deploy host
            resources vm @?= resources host
            contextKind (context vm) @?= VMOrchestrator
            parentChain (context vm) @?= [ContextFrame HostOrchestrator "demo"]
            topologyFrames (context vm)
                @?= [ TopologyFrame "host-orchestrator-0" "" HostProvider HostOrchestrator "host-orchestrator"
                    , TopologyFrame "vm-orchestrator-1" "host-orchestrator-0" IncusVMProvider VMOrchestrator "vm-orchestrator"
                    ]
            contextKind (context service) @?= ClusterService
            parentChain (context service)
                @?= [ContextFrame HostOrchestrator "demo", ContextFrame VMOrchestrator "demo"]
        , testCase "child projection rejects direct host-to-runtime-container configs" $ do
            let host = defaultProjectConfig "demo" "/workspace/demo" HostOrchestrator
            deriveProjectConfigForKind VMProjectContainer host "/workspace/demo"
                @?= Left "project config: child context VMProjectContainer is not allowed in HostOrchestrator"
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
        , testCase "daemon snapshot log includes config metadata without secret content" $ do
            let daemon = defaultProjectConfig "demo" "/workspace/demo" Daemon
                hash = projectConfigSnapshotHash "password = \"secret\""
                line = renderProjectConfigSnapshotLog "/run/demo.dhall" hash (context daemon)
            assertBool "hash is tagged" ("fnv64:" `T.isPrefixOf` hash)
            assertBool "project is logged" ("project=demo" `T.isInfixOf` line)
            assertBool "role is logged" ("roleName=daemon" `T.isInfixOf` line)
            assertBool "path is logged" ("configPath=/run/demo.dhall" `T.isInfixOf` line)
            assertBool "hash is logged" (("configHash=" <> hash) `T.isInfixOf` line)
            assertBool "config content is not logged" (not ("secret" `T.isInfixOf` line))
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
            written <- TIO.readFile path
            decoded <- decodeProjectConfigFile path
            removeFile path
            written @?= renderProjectConfig expected <> "\n"
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
                    injected <-
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
                                                        (V.TestSecret "fixture")
                                                    )
                                                )
                                        )
                            )
                    result <-
                        try
                            ( decodeProjectCodecWithSettings
                                codec
                                Dhall.defaultInputSettings
                                injected
                            ) ::
                            IO
                                ( Either
                                    SomeException
                                    ( SecretProjectConfig
                                        (V.Production SecretFixtureProject)
                                    )
                                )
                    assertBool
                        "production project decode rejects plaintext before use"
                        (isLeft result)
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
        , testCase "scope API removes the raw context updater and parallel config builders" $ do
            cwd <- getCurrentDirectory
            mroot <- findRepoRoot cwd
            root <- maybe (assertFailure "could not locate repo root") pure mroot
            classSource <-
                readFile
                    ( root
                        </> "core"
                        </> "hostbootstrap-core"
                        </> "src"
                        </> "HostBootstrap"
                        </> "Config"
                        </> "Class.hs"
                    )
            cliSource <-
                readFile
                    ( root
                        </> "core"
                        </> "hostbootstrap-core"
                        </> "src"
                        </> "HostBootstrap"
                        </> "CLI.hs"
                    )
            assertBool "cfgWithContext stays absent" (not ("cfgWithContext" `isInfixOf` classSource))
            assertBool "the project spec owns one assembler" ("psAssemble ::" `isInfixOf` cliSource)
            assertBool "the old production builder stays absent" (not ("psInit ::" `isInfixOf` cliSource))
            assertBool "the old harness builder stays absent" (not ("psTestConfig ::" `isInfixOf` cliSource))
        ]
  where
    badTypeConfig =
        T.unpack (T.replace "haReplicas = 1" "haReplicas = \"two\"" (renderProjectConfig expected))

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

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

isSha256Digest :: T.Text -> Bool
isSha256Digest digest =
    T.length digest == 64
        && T.all (`elem` ("0123456789abcdef" :: String)) digest

expectRight :: Either String a -> IO a
expectRight result =
    case result of
        Right value -> pure value
        Left err -> assertFailure err

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
        case
            verifyHandoff
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
