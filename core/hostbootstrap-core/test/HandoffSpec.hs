{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The authenticated cross-frame handoff value and cryptography layer.

These cases use real Ed25519 signatures and real protected stores. Grant
issuance consumes tokens in the root store; child verification is deliberately
pure and has no store capability.
-}
module HandoffSpec (tests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally)
import Control.Monad (when)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Kind (Type)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Unique (hashUnique, newUnique)
import Data.Word (Word8)
import qualified Fixture
import HostBootstrap.Authority (
    InstalledProject,
    ProjectVerb (ProjectDestroy, ProjectUp),
    VerbUp,
    installedProjectFor,
 )
import HostBootstrap.Config.Vocab (
    Harness,
    HarnessAuthority,
    Production,
    harnessRunName,
 )
import HostBootstrap.Config.Class (
    ProjectCodec,
    ProjectCfg (withProductionProjectCodec),
    renderProjectCodecHoisted,
 )
import HostBootstrap.Config.Schema (
    ConfigWireAdmissionError (..),
    SiblingConfigInstallError (..),
    SiblingConfigInstallResult (..),
    installAuthenticatedProductionSiblingConfig,
    siblingProjectConfigPath,
    validatedConfigValue,
    verifiedConfigDigest,
    withAuthenticatedConfigWire,
 )
import qualified HostBootstrap.Context as Context
import HostBootstrap.Handoff
import HostBootstrap.Lifecycle.Mode (
    ModeError,
    VerifiedIncompleteRunLease,
    harnessPreconditions,
    harnessRootAuthority,
    harnessRootHarnessAuthority,
    productionRootAuthority,
    recoverAbandonedHarnessRuns,
    withHarnessRoot,
    withProductionRoot,
 )
import HostBootstrap.Protected (
    ProtectedStore,
    openProtectedStore,
 )
import System.Directory (doesFileExist, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "HandoffSpec"
        [ testGroup "length framing" framingTests
        , testGroup "binding rendering" bindingTests
        , testGroup "the signed handoff protocol" protocolTests
        ]

-- ---------------------------------------------------------------------------
-- Framing

framingTests :: [TestTree]
framingTests =
    [ testCase "a framed payload round-trips" $
        unframeWire (frameWire "narrowed child config") @?= Right "narrowed child config"
    , testCase "an empty payload is a valid frame" $
        unframeWire (frameWire "") @?= Right ""
    , testCase "a short header is truncation, not an empty payload" $
        unframeWire (ByteString.take 4 (frameWire "abc"))
            @?= Left (HandoffWireTruncated 8 4)
    , testCase "a body shorter than its declared length is truncation" $ do
        let full = frameWire "abcdefghij"
        unframeWire (ByteString.take (ByteString.length full - 3) full)
            @?= Left (HandoffWireTruncated 10 7)
    , testCase "bytes after the declared length are refused, not ignored" $
        unframeWire (frameWire "abc" <> "extra")
            @?= Left (HandoffWireTrailingBytes 5)
    , testCase "a declared length beyond the receiver limit is refused before allocation" $ do
        let hostile = ByteString.pack [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff] <> "x"
        case unframeWire hostile of
            Left (HandoffWireTooLarge declared limit) -> do
                assertBool "the declared length exceeds the limit" (declared > limit)
                limit @?= maxWireBytes
            other -> assertFailure ("expected an oversize refusal, got " <> show other)
    , testCase "the grant protocol version is explicit" $
        handoffProtocolVersion @?= 1
    ]

-- ---------------------------------------------------------------------------
-- Bindings

bindingTests :: [TestTree]
bindingTests =
    [ testCase "field boundaries are unambiguous across the frame edge" $
        withHandoff 7 ProjectUp $ \broker -> do
            token <- freshHandoffToken
            left <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload){requestedParentFrame = "a-b", requestedChildFrame = "c"} token)
            right <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload){requestedParentFrame = "a", requestedChildFrame = "b-c"} token)
            assertBool
                "distinct edges render distinctly"
                (renderHandoffBinding left /= renderHandoffBinding right)
    , testCase "every caller-bound field and the token change canonical rendering" $
        withHandoff 7 ProjectUp $ \broker -> do
            token <- freshHandoffToken
            otherToken <- freshHandoffToken
            let input = bindingInputFor childPayload
                variants =
                    [ input{requestedSpecDigest = "spec-2"}
                    , input{requestedPlanRevision = "rev-2"}
                    , input{requestedParentFrame = "elsewhere"}
                    , input{requestedChildFrame = "elsewhere"}
                    , input{requestedChildConfigDigest = "deadbeef"}
                    , input{requestedPhase = "teardown"}
                    ]
            base <- expectRight (mkHandoffBinding broker input token)
            changed <- traverse (\variant -> expectRight (mkHandoffBinding broker variant token)) variants
            changedToken <- expectRight (mkHandoffBinding broker input otherToken)
            let rendered = map renderHandoffBinding (base : changed <> [changedToken])
            length (dedupe rendered) @?= length rendered
    , testCase "project, scope, generation, and verb derive from typed root evidence" $
        withHandoff 7 ProjectUp $ \broker -> do
            token <- freshHandoffToken
            binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
            handoffInstalledProject binding @?= "hostbootstrap-demo"
            handoffScope binding @?= "Production"
            handoffBrokerGeneration binding @?= 1
            handoffVerb binding @?= "up"
    , testCase "a real Harness root derives its exact generative run scope" $
        withHarnessHandoff 7 $ \broker authority -> do
            token <- freshHandoffToken
            binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
            handoffScope binding @?= "Harness " <> harnessRunName authority
            assertBool "Harness scope is never Production" (handoffScope binding /= "Production")
    , testCase "an empty required field is rejected before signing" $
        withHandoff 7 ProjectUp $ \broker -> do
            token <- freshHandoffToken
            case mkHandoffBinding broker (bindingInputFor childPayload){requestedSpecDigest = ""} token of
                Left (HandoffBindingMismatch _) -> pure ()
                other -> assertFailure ("expected an invalid binding, got " <> show other)
    ]

dedupe :: (Eq a) => [a] -> [a]
dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- ---------------------------------------------------------------------------
-- The protocol

protocolTests :: [TestTree]
protocolTests =
    [ testCase "a root grant verifies and yields config and child authority" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            handoff <-
                expectRight
                    ( verifyHandoff
                        (rootBrokerVerificationKey broker)
                        (handoffOfferWire offer)
                        binding
                        challenge
                        grant
                    )
            verifiedHandoffPayload handoff @?= childPayload
            config <- expectRight (verifiedConfigPayload handoff)
            authenticatedConfigBytes config @?= childPayload
            authenticatedConfigDigest config @?= childConfigDigest childPayload
            authority <- expectRight (authorizeChildProject handoff "vm-project-container-2" ProjectUp)
            childPlanAuthorityBinding authority @?= binding
    , testCase "authenticated config bytes mint a fresh scope-correct local config identity" $
        withHandoff 13 ProjectUp $ \broker ->
            withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec -> do
                let cfg =
                        Fixture.defaultProjectConfig
                            "hostbootstrap-demo"
                            "/workspace/demo"
                            Context.HostOrchestrator ::
                            Fixture.ProjectConfig (Production Fixture.FixtureProject)
                    payload = canonicalConfigBytes codec cfg
                authenticated <- authenticatedPayload broker payload
                admitted <-
                    withAuthenticatedConfigWire codec authenticated $ \wire validated -> do
                        verifiedConfigDigest wire @?= childConfigDigest payload
                        validatedConfigValue validated @?= cfg
                admitted @?= Right ()
    , testCase "authenticated config admission refuses invalid UTF-8, codec failure, and non-canonical source" $
        withHandoff 14 ProjectUp $ \broker ->
            withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec -> do
                let cfg =
                        Fixture.defaultProjectConfig
                            "hostbootstrap-demo"
                            "/workspace/demo"
                            Context.HostOrchestrator ::
                            Fixture.ProjectConfig (Production Fixture.FixtureProject)
                    canonical = canonicalConfigBytes codec cfg
                    admit payload = do
                        authenticated <- authenticatedPayload broker payload
                        withAuthenticatedConfigWire codec authenticated (\_ _ -> pure ())
                admit (ByteString.pack [0xff]) >>= (@?= Left ConfigWireInvalidUtf8)
                admit "this is not a project config" >>= (@?= Left ConfigWireCodecRejected)
                admit (canonical <> " ") >>= (@?= Left ConfigWireNonCanonical)
    , testCase "authenticated sibling install is atomic, idempotent, and conflict-preserving" $ do
        unique <- hashUnique <$> newUnique
        let projectName = Text.pack ("hbconfig-" <> show unique)
        withNamedHandoff 15 projectName ProjectUp $ \project broker ->
            withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec -> do
                let cfg =
                        Fixture.defaultProjectConfig
                            projectName
                            "/workspace/demo"
                            Context.HostOrchestrator ::
                            Fixture.ProjectConfig (Production Fixture.FixtureProject)
                    payload = canonicalConfigBytes codec cfg
                authenticated <- authenticatedPayload broker payload
                path <- siblingProjectConfigPath projectName
                let lockPath = path <> ".hostbootstrap-handoff.lock"
                    cleanup = removeIfPresent path >> removeIfPresent lockPath
                    exercise = do
                        leftResult <- newEmptyMVar
                        rightResult <- newEmptyMVar
                        _ <- forkIO (installAuthenticatedProductionSiblingConfig project authenticated >>= putMVar leftResult)
                        _ <- forkIO (installAuthenticatedProductionSiblingConfig project authenticated >>= putMVar rightResult)
                        left <- takeMVar leftResult
                        right <- takeMVar rightResult
                        assertBool
                            "one creator installs and its concurrent peer converges"
                            ( [left, right]
                                `elem` [ [Right SiblingConfigInstalled, Right SiblingConfigAlreadyPresent]
                                       , [Right SiblingConfigAlreadyPresent, Right SiblingConfigInstalled]
                                       ]
                            )
                        ByteString.readFile path >>= (@?= payload)
                        ByteString.writeFile path "foreign replacement"
                        installAuthenticatedProductionSiblingConfig project authenticated
                            >>= (@?= Left (SiblingConfigConflict path))
                        ByteString.readFile path >>= (@?= "foreign replacement")
                cleanup
                exercise `finally` cleanup
    , testCase "the root makes an identical grant retry idempotent and refuses token reuse" $
        withHandoff 7 ProjectUp $ \broker -> do
            (_, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            first <- expectRightIO =<< grantHandoff broker offer challenge
            retry <- expectRightIO =<< grantHandoff broker offer challenge
            grantSignature retry @?= grantSignature first
            otherChallenge <- freshChallenge
            reused <- grantHandoff broker offer otherChallenge
            reused @?= Left HandoffTokenConsumed
    , testCase "concurrent identical grant requests converge on one signature" $
        withHandoff 7 ProjectUp $ \broker -> do
            (_, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            start <- newEmptyMVar
            firstResult <- newEmptyMVar
            secondResult <- newEmptyMVar
            _ <- forkIO (takeMVar start >> grantHandoff broker offer challenge >>= putMVar firstResult)
            _ <- forkIO (takeMVar start >> grantHandoff broker offer challenge >>= putMVar secondResult)
            putMVar start ()
            putMVar start ()
            first <- takeMVar firstResult >>= expectRightIO
            second <- takeMVar secondResult >>= expectRightIO
            grantSignature second @?= grantSignature first
    , testCase "a grant for another challenge does not authenticate this one" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            recorded <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer recorded
            fresh <- freshChallenge
            assertBool "the receiver issued a different challenge" (challengeBytes fresh /= challengeBytes recorded)
            expectSignatureRefusal
                ( verifyHandoff
                    (rootBrokerVerificationKey broker)
                    (handoffOfferWire offer)
                    binding
                    fresh
                    grant
                )
    , testCase "a payload swapped after signing fails its bound digest" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            let original = handoffOfferWire offer
                swapped = frameWire "message = \"attacker\"" <> dropFirstFrame original
            case verifyHandoff (rootBrokerVerificationKey broker) swapped binding challenge grant of
                Left (HandoffPayloadDigestMismatch expected actual) ->
                    assertBool "the digests differ" (expected /= actual)
                other -> assertFailure ("expected a digest refusal, got " <> show other)
    , testCase "the transmitted canonical binding cannot be substituted" $
        withHandoff 7 ProjectUp $ \broker -> do
            token <- freshHandoffToken
            binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
            otherBinding <-
                expectRight
                    ( mkHandoffBinding broker
                        (bindingInputFor childPayload){requestedChildFrame = "sibling-2"}
                        token
                    )
            relay <- expectRight (brokerRelay broker binding)
            otherRelay <- expectRight (brokerRelay broker otherBinding)
            offer <- expectRight (mkHandoffOffer relay childPayload token)
            substituted <- expectRight (mkHandoffOffer otherRelay childPayload token)
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            case verifyHandoff (rootBrokerVerificationKey broker) (handoffOfferWire substituted) binding challenge grant of
                Left (HandoffBindingMismatch _) -> pure ()
                other -> assertFailure ("expected a canonical-binding refusal, got " <> show other)
    , testCase "another installed project key cannot authenticate this root's grant" $
        withHandoff 7 ProjectUp $ \broker -> do
            otherSigning <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 8))
            let otherKey = projectSigningVerificationKey otherSigning
            (binding, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            expectSignatureRefusal
                ( verifyHandoff
                    otherKey
                    (handoffOfferWire offer)
                    binding
                    challenge
                    grant
                )
            assertBool
                "the two independently provisioned keys differ"
                ( verificationKeyDigest (rootBrokerVerificationKey broker)
                    /= verificationKeyDigest otherKey
                )
    , testCase "a sibling frame cannot use a grant minted for its peer" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            handoff <- expectRight (verifyHandoff (rootBrokerVerificationKey broker) (handoffOfferWire offer) binding challenge grant)
            case authorizeChildProject handoff "daemon-3" ProjectUp of
                Left (HandoffFrameMismatch bound actual) -> do
                    bound @?= "vm-project-container-2"
                    actual @?= "daemon-3"
                other -> assertFailure ("expected a frame refusal, got " <> show other)
    , testCase "an up handoff cannot authorize a teardown edge" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            handoff <- expectRight (verifyHandoff (rootBrokerVerificationKey broker) (handoffOfferWire offer) binding challenge grant)
            case authorizeChildProject handoff "vm-project-container-2" ProjectDestroy of
                Left (HandoffBindingMismatch _) -> pure ()
                other -> assertFailure ("expected a verb refusal, got " <> show other)
    , testCase "a parent cannot offer payload or token bytes the binding does not describe" $
        withHandoff 7 ProjectUp $ \broker -> do
            token <- freshHandoffToken
            replacement <- freshHandoffToken
            binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
            relay <- expectRight (brokerRelay broker binding)
            expectBindingRefusal (mkHandoffOffer relay "different bytes entirely" token)
            expectBindingRefusal (mkHandoffOffer relay childPayload replacement)
    , testCase "a missing, malformed, or trailing token frame is refused" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            let key = rootBrokerVerificationKey broker
                verifyWire wire = verifyHandoff key wire binding challenge grant
            case verifyWire (frameWire childPayload) of
                Left (HandoffWireTruncated{}) -> pure ()
                other -> assertFailure ("expected a truncated-wire refusal, got " <> show other)
            case verifyWire (frameWire childPayload <> frameWire "" <> frameWire (renderHandoffBinding binding)) of
                Left HandoffTokenInvalid -> pure ()
                other -> assertFailure ("expected an invalid-token refusal, got " <> show other)
            case verifyWire (handoffOfferWire offer <> "junk") of
                Left (HandoffWireTrailingBytes _) -> pure ()
                other -> assertFailure ("expected a trailing-bytes refusal, got " <> show other)
    , testCase "failed child verification cannot consume the root token" $
        withHandoff 7 ProjectUp $ \broker -> do
            (_, signedOffer) <- newOffer broker childPayload
            (binding, untouchedOffer) <- newOffer broker childPayload
            challenge <- freshChallenge
            wrongGrant <- expectRightIO =<< grantHandoff broker signedOffer challenge
            expectSignatureRefusal
                ( verifyHandoff
                    (rootBrokerVerificationKey broker)
                    (handoffOfferWire untouchedOffer)
                    binding
                    challenge
                    wrongGrant
                )
            goodGrant <- expectRightIO =<< grantHandoff broker untouchedOffer challenge
            assertBool
                "the root can still authorize the untouched token"
                (isRight (verifyHandoff (rootBrokerVerificationKey broker) (handoffOfferWire untouchedOffer) binding challenge goodGrant))
    , testCase "installed signing and verification files are validated independently" $
        withSystemTempDirectory "hostbootstrap-handoff-key" $ \directory -> do
            let signingPath = directory </> "project.key"
                publicPath = directory </> "project.pub"
                seed = ByteString.replicate 32 19
            signing <- expectRight (projectSigningKeyFromBytes seed)
            ByteString.writeFile signingPath seed
            ByteString.writeFile publicPath (verificationKeyBytes (projectSigningVerificationKey signing))
            loadedSigning <- installedProjectSigningKey signingPath >>= expectRightIO
            loadedPublic <- installedVerificationKey publicPath >>= expectRightIO
            verificationKeyBytes (projectSigningVerificationKey loadedSigning)
                @?= verificationKeyBytes loadedPublic
            installedProjectSigningKey (directory </> "absent.key") >>= expectSigningKeyUnavailable
            installedVerificationKey (directory </> "absent.pub") >>= expectVerificationKeyUnavailable
            ByteString.writeFile signingPath "not a key"
            installedProjectSigningKey signingPath >>= \result -> case result of
                Left HandoffSigningKeyInvalid -> pure ()
                other -> assertFailure ("expected a malformed signing-key refusal, got " <> show other)
            ByteString.writeFile publicPath "not a key"
            installedVerificationKey publicPath >>= expectVerificationKeyUnavailable
    , testCase "Show and errors redact payload, token, and key bytes" $
        withHandoff 7 ProjectUp $ \broker -> do
            (_, offer) <- newOffer broker secretPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            let rendered = unwords [show offer, show broker, show grant, show HandoffTokenConsumed]
            assertBool "payload bytes are absent" (not (ByteStringChar8.unpack secretPayload `contains` rendered))
            assertBool "redaction marker is present" ("<redacted>" `contains` rendered)
            assertBool "consumed-token diagnostics carry no token" (handoffErrorMessage HandoffTokenConsumed == "handoff: one-time token has already authorized another transcript")
    ]

-- ---------------------------------------------------------------------------
-- Fixtures

childPayload :: ByteString.ByteString
childPayload = ByteStringChar8.pack "{ message = \"Hello, world!\" }"

secretPayload :: ByteString.ByteString
secretPayload = "SECRET-CONFIG-BYTES-DO-NOT-PRINT"

bindingInputFor :: ByteString.ByteString -> HandoffBindingInput
bindingInputFor payload =
    HandoffBindingInput
        { requestedSpecDigest = "spec-digest-1"
        , requestedPayloadKind = NarrowedProjectConfig
        , requestedPlanRevision = "rev-1"
        , requestedParentFrame = "vm-orchestrator-1"
        , requestedChildFrame = "vm-project-container-2"
        , requestedChildConfigDigest = childConfigDigest payload
        , requestedPhase = "execute"
        }

newOffer ::
    RootBroker scope brokerGeneration verb ->
    ByteString.ByteString ->
    IO
        ( HandoffBinding scope brokerGeneration
        , HandoffOffer scope brokerGeneration
        )
newOffer broker payload = do
    token <- freshHandoffToken
    binding <- expectRight (mkHandoffBinding broker (bindingInputFor payload) token)
    relay <- expectRight (brokerRelay broker binding)
    offer <- expectRight (mkHandoffOffer relay payload token)
    pure (binding, offer)

authenticatedPayload ::
    RootBroker scope brokerGeneration verb ->
    ByteString.ByteString ->
    IO (AuthenticatedConfigPayload scope brokerGeneration)
authenticatedPayload broker payload = do
    (binding, offer) <- newOffer broker payload
    challenge <- freshChallenge
    grant <- expectRightIO =<< grantHandoff broker offer challenge
    verified <-
        expectRight
            ( verifyHandoff
                (rootBrokerVerificationKey broker)
                (handoffOfferWire offer)
                binding
                challenge
                grant
            )
    expectRight (verifiedConfigPayload verified)

canonicalConfigBytes ::
    ProjectCodec scope specDigest Fixture.ProjectConfig ->
    Fixture.ProjectConfig scope ->
    ByteString.ByteString
canonicalConfigBytes codec =
    TextEncoding.encodeUtf8
        . (<> "\n")
        . renderProjectCodecHoisted codec Context.vocabUnions

withHandoff ::
    Word8 ->
    ProjectVerb verb ->
    ( forall (brokerGeneration :: Type).
      RootBroker (Production Fixture.FixtureProject) brokerGeneration verb ->
      IO ()
    ) ->
    IO ()
withHandoff seedByte verb use =
    withSystemTempDirectory "hostbootstrap-handoff" $ \directory -> do
        signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 seedByte))
        opened <- openProtectedStore (directory </> "authority")
        case opened of
            Left failure -> assertFailure (show failure)
            Right store -> withRootFor signing store verb use

withNamedHandoff ::
    Word8 ->
    Text.Text ->
    ProjectVerb verb ->
    ( forall (brokerGeneration :: Type).
      InstalledProject Fixture.FixtureProject ->
      RootBroker (Production Fixture.FixtureProject) brokerGeneration verb ->
      IO result
    ) ->
    IO result
withNamedHandoff seedByte projectName verb use =
    withSystemTempDirectory "hostbootstrap-named-handoff" $ \directory -> do
        signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 seedByte))
        store <- openProtectedStore (directory </> "authority") >>= expectRightIO
        project <-
            either
                (assertFailure . show)
                pure
                (installedProjectFor @Fixture.FixtureProject @Fixture.ProjectConfig projectName)
        outcome <-
            withProductionRoot store project verb $ \root -> do
                brokered <-
                    withRootBroker
                        (productionHandoffScope project)
                        store
                        signing
                        (productionRootAuthority root)
                        (use project)
                result <- either (assertFailure . show) pure brokered
                pure (Right result)
        either (assertFailure . show) pure outcome

withRootFor ::
    ProjectSigningKey ->
    ProtectedStore ->
    ProjectVerb verb ->
    ( forall (brokerGeneration :: Type).
      RootBroker (Production Fixture.FixtureProject) brokerGeneration verb ->
      IO ()
    ) ->
    IO ()
withRootFor signing store verb use = do
    outcome <- withFixtureProject $ \project ->
        withProductionRoot store project verb $ \root -> do
            brokered <-
                withRootBroker
                    (productionHandoffScope project)
                    store
                    signing
                    (productionRootAuthority root)
                    use
            case brokered of
                Left failure -> assertFailure (show failure)
                Right () -> pure (Right ())
    case outcome of
        Left failure -> assertFailure (show failure)
        Right () -> pure ()

withHarnessHandoff ::
    Word8 ->
    ( forall runId (brokerGeneration :: Type).
      RootBroker (Harness Fixture.FixtureProject runId) brokerGeneration VerbUp ->
      HarnessAuthority Fixture.FixtureProject runId ->
      IO result
    ) ->
    IO result
withHarnessHandoff seedByte use =
    withSystemTempDirectory "hostbootstrap-handoff-harness" $ \directory -> do
        signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 seedByte))
        opened <- openProtectedStore (directory </> "authority")
        store <- either (assertFailure . show) pure opened
        withFixtureProject $ \project -> do
            swept <- recoverAbandonedHarnessRuns store project recoverNothing recoverNothing >>= either (assertFailure . show) pure
            outcome <-
                withHarnessRoot
                    store
                    project
                    ProjectUp
                    (harnessPreconditions project (directory </> "absent-config") (pure False))
                    swept
                    ( \root -> do
                        brokered <-
                            withRootBroker
                                (harnessHandoffScope project (harnessRootHarnessAuthority root))
                                store
                                signing
                                (harnessRootAuthority root)
                                (\broker -> use broker (harnessRootHarnessAuthority root))
                        result <- either (assertFailure . show) pure brokered
                        pure (Right result)
                    )
            either (assertFailure . show) pure outcome

recoverNothing ::
    VerifiedIncompleteRunLease projectId ->
    IO (Either ModeError ())
recoverNothing _ = pure (Right ())

withFixtureProject ::
    (InstalledProject Fixture.FixtureProject -> IO result) ->
    IO result
withFixtureProject use =
    case installedProjectFor @Fixture.FixtureProject @Fixture.ProjectConfig "hostbootstrap-demo" of
        Left failure -> assertFailure (show failure)
        Right project -> use project

removeIfPresent :: FilePath -> IO ()
removeIfPresent path = do
    present <- doesFileExist path
    when present (removeFile path)

dropFirstFrame :: ByteString.ByteString -> ByteString.ByteString
dropFirstFrame = ByteString.drop (ByteString.length (frameWire childPayload))

expectRight :: (Show err) => Either err value -> IO value
expectRight (Right value) = pure value
expectRight (Left failure) = assertFailure ("expected success, got " <> show failure)

expectRightIO :: (Show err) => Either err value -> IO value
expectRightIO = expectRight

expectSignatureRefusal :: (Show value) => Either HandoffError value -> IO ()
expectSignatureRefusal outcome = case outcome of
    Left HandoffSignatureInvalid -> pure ()
    other -> assertFailure ("expected a signature refusal, got " <> show other)

expectBindingRefusal :: (Show value) => Either HandoffError value -> IO ()
expectBindingRefusal outcome = case outcome of
    Left (HandoffBindingMismatch _) -> pure ()
    other -> assertFailure ("expected a binding refusal, got " <> show other)

expectSigningKeyUnavailable :: Either HandoffError ProjectSigningKey -> IO ()
expectSigningKeyUnavailable outcome = case outcome of
    Left (HandoffSigningKeyUnavailable _) -> pure ()
    other -> assertFailure ("expected a missing signing-key refusal, got " <> show other)

expectVerificationKeyUnavailable :: Either HandoffError ProjectVerificationKey -> IO ()
expectVerificationKeyUnavailable outcome = case outcome of
    Left (HandoffVerificationKeyUnavailable _) -> pure ()
    other -> assertFailure ("expected a verification-key refusal, got " <> show other)

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

contains :: String -> String -> Bool
contains needle haystack = any (needle `prefixOf`) (tails haystack)
  where
    tails [] = [[]]
    tails value@(_ : rest) = value : tails rest
    prefixOf [] _ = True
    prefixOf _ [] = False
    prefixOf (x : xs) (y : ys) = x == y && prefixOf xs ys
