{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
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
import Data.Foldable (traverse_)
import Data.Kind (Type)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word8)
import qualified Fixture
import HostBootstrap.Authority (
    InstalledProjectIdentity,
    ProjectVerb (ProjectDestroy, ProjectDown, ProjectUp),
    VerbUp,
    installedProjectName,
 )
import HostBootstrap.Config.Class (
    ProjectCfg (withProductionProjectCodec),
    ProjectCodec,
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
    withVerifiedConfigHandoff,
 )
import HostBootstrap.Config.Vocab (
    Harness,
    HarnessAuthority,
    Production,
    harnessRunName,
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
    protectedStoreIdentity,
    protectedStoreIdentityText,
 )
import System.Directory (doesPathExist, removePathForcibly)
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
        , testGroup "the recovery wire" recoveryTests
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
        do
            expectedProject <- Fixture.fixtureExecutableName
            withHandoff 7 ProjectUp $ \broker -> do
                token <- freshHandoffToken
                binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
                handoffInstalledProject binding @?= expectedProject
                handoffScope binding @?= "Production"
                handoffBrokerGeneration binding @?= 1
                handoffVerb binding @?= "up"
    , testCase "the canonical and verified binding retain the root protected-store identity" $
        withSystemTempDirectory "hostbootstrap-handoff-store-binding" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 31))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            let expectedStore = protectedStoreIdentityText (protectedStoreIdentity store)
            withRootFor signing store ProjectUp $ \broker -> do
                let input = bindingInputFor childPayload
                (relay, token) <- expectRightIO =<< registerHandoffEdge broker input
                let binding = relayBinding relay
                decodedRelay <-
                    expectRight
                        ( brokerRelayFromRouteWire
                            (rootBrokerRoute broker)
                            (Just input)
                            (renderHandoffBinding binding)
                        )
                let decoded = relayBinding decodedRelay
                decoded @?= binding
                handoffStoreIdentity decoded @?= expectedStore
                offer <- expectRight (mkHandoffOffer relay childPayload token)
                challenge <- freshChallenge
                grant <- expectRightIO =<< grantHandoff broker offer challenge
                verified <-
                    expectRight
                        ( verifyHandoff
                            (rootBrokerVerificationKey broker)
                            (handoffOfferWire offer)
                            decoded
                            challenge
                            grant
                        )
                handoffStoreIdentity (verifiedHandoffBinding verified) @?= expectedStore
    , testCase "a real Harness root derives its exact generative run scope" $
        withHarnessHandoff 7 $ \_ broker authority -> do
            token <- freshHandoffToken
            binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
            handoffScope binding @?= "Harness " <> harnessRunName authority
            assertBool "Harness scope is never Production" (handoffScope binding /= "Production")
    , testCase "scope-fixed parsing refuses signed Harness bytes at a Production boundary" $
        withHarnessHandoff 8 $ \project broker _ -> do
            token <- freshHandoffToken
            binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
            expectBindingRefusal
                ( withHandoffBindingFromWire
                    (productionHandoffScope project)
                    (renderHandoffBinding binding)
                    (const ())
                )
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
    [ testCase "a root broker refuses a protected store outside its root authority" $
        withSystemTempDirectory "hostbootstrap-handoff-wrong-store" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 32))
            rootStore <- openProtectedStore (directory </> "root-authority") >>= expectRightIO
            otherStore <- openProtectedStore (directory </> "other-authority") >>= expectRightIO
            outcome <-
                Fixture.withFixtureInstalledProject $ \project ->
                    withProductionRoot rootStore project ProjectUp $ \root -> do
                        brokered <-
                            withRootBroker
                                (productionHandoffScope project)
                                otherStore
                                signing
                                (productionRootAuthority root)
                                (const (pure ()))
                        pure (Right brokered)
            brokered <- either (assertFailure . show) pure outcome
            case brokered of
                Left (HandoffBindingMismatch detail) ->
                    assertBool
                        "the refusal names the protected-store origin"
                        ("protected store" `Text.isInfixOf` detail)
                other -> assertFailure ("expected a cross-store broker refusal, got " <> show other)
    , testCase "durable and signing operations refuse after the broker bracket closes" $ do
        (registerAfterClose, grantAfterClose, signAfterClose) <-
            withNamedHandoff 33 ProjectDestroy $ \_ broker ->
                withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                    withRecoveryBinding broker recoveryInput recoveryPayload $ \projection -> do
                        (relay, token) <-
                            expectRight =<< registerHandoffEdge broker (bindingInputFor childPayload)
                        offer <- expectRight (mkHandoffOffer relay childPayload token)
                        challenge <- freshChallenge
                        pure
                            ( fmap
                                (fmap (const ()))
                                (registerHandoffEdge broker (bindingInputFor childPayload))
                            , fmap
                                (fmap (const ()))
                                (grantHandoff broker offer challenge)
                            , fmap
                                (fmap (const ()))
                                (signRecoveryWire broker projection recoveryPayload)
                            )
        registerAfterClose >>= (@?= Left HandoffBrokerExpired)
        grantAfterClose >>= (@?= Left HandoffBrokerExpired)
        signAfterClose >>= (@?= Left HandoffBrokerExpired)
    , testCase "a root grant verifies and yields only authenticated config evidence" $
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
    , testCase "authenticated config bytes mint a fresh scope-correct local config identity" $
        withHandoff 13 ProjectUp $ \broker ->
            withProductionProjectCodec @Fixture.ProjectConfig $ \codec -> do
                let cfg =
                        Fixture.defaultProjectConfig
                            "hostbootstrap-demo"
                            "/workspace/demo"
                            Context.HostOrchestrator
                    payload = canonicalConfigBytes codec cfg
                authenticated <- authenticatedPayload broker payload
                admitted <-
                    withAuthenticatedConfigWire codec authenticated $ \wire validated -> do
                        verifiedConfigDigest wire @?= childConfigDigest payload
                        validatedConfigValue validated @?= cfg
                admitted @?= Right ()
    , testCase "authenticated config admission refuses invalid UTF-8, codec failure, and non-canonical source" $
        withHandoff 14 ProjectUp $ \broker ->
            withProductionProjectCodec @Fixture.ProjectConfig $ \codec -> do
                let cfg =
                        Fixture.defaultProjectConfig
                            "hostbootstrap-demo"
                            "/workspace/demo"
                            Context.HostOrchestrator
                    canonical = canonicalConfigBytes codec cfg
                    admit payload = do
                        authenticated <- authenticatedPayload broker payload
                        withAuthenticatedConfigWire codec authenticated (\_ _ -> pure ())
                admit (ByteString.pack [0xff]) >>= (@?= Left ConfigWireInvalidUtf8)
                admit "this is not a project config" >>= (@?= Left ConfigWireCodecRejected)
                admit (canonical <> " ") >>= (@?= Left ConfigWireNonCanonical)
    , testCase "authenticated sibling install is atomic, idempotent, and conflict-preserving" $
        withNamedHandoff 15 ProjectUp $ \(project :: InstalledProjectIdentity projectId) broker ->
            withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \codec -> do
                let projectName = installedProjectName project
                    cfg =
                        Fixture.defaultProjectConfig
                            projectName
                            "/workspace/demo"
                            Context.HostOrchestrator
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
                            ( "one creator installs and its concurrent peer converges, observed "
                                <> show [left, right]
                            )
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
    , testCase "an edge the root never opened is refused, so relaying is weaker than signing" $
        withHandoff 9 ProjectUp $ \broker -> do
            -- Everything an intermediate frame could construct on its own: a
            -- fresh token, a well-formed binding for a child frame the root
            -- never planned, and the offer that carries them.
            token <- freshHandoffToken
            invented <-
                expectRight
                    ( mkHandoffBinding
                        broker
                        (bindingInputFor childPayload){requestedChildFrame = "invented-frame"}
                        token
                    )
            relay <- expectRight (brokerRelay broker invented)
            offer <- expectRight (mkHandoffOffer relay childPayload token)
            challenge <- freshChallenge
            granted <- grantHandoff broker offer challenge
            granted @?= Left HandoffEdgeUnregistered
            -- And the same root still authorizes an edge it did open, so the
            -- refusal is about the edge rather than about the broker.
            (_, planned) <- newOffer broker childPayload
            plannedGrant <- grantHandoff broker planned challenge
            assertBool "an opened edge still authenticates" (isRight plannedGrant)
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
            (relay, token) <- expectRightIO =<< registerHandoffEdge broker (bindingInputFor childPayload)
            let binding = relayBinding relay
            otherBinding <-
                expectRight
                    ( mkHandoffBinding
                        broker
                        (bindingInputFor childPayload){requestedChildFrame = "sibling-2"}
                        token
                    )
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
    , testCase "the verified handoff retains the exact authenticated child frame" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            handoff <- expectRight (verifyHandoff (rootBrokerVerificationKey broker) (handoffOfferWire offer) binding challenge grant)
            handoffChildFrame (verifiedHandoffBinding handoff) @?= "vm-project-container-2"
    , testCase "an up handoff cannot be refined as a teardown config edge" $
        withHandoff 7 ProjectUp $ \broker -> do
            withProductionProjectCodec @Fixture.ProjectConfig $ \codec -> do
                let cfg =
                        Fixture.defaultProjectConfig
                            "hostbootstrap-demo"
                            "/workspace/demo"
                            Context.HostOrchestrator
                    payload = canonicalConfigBytes codec cfg
                handoff <- verifiedHandoffFor broker payload
                authenticated <- expectRight (verifiedConfigPayload handoff)
                admitted <-
                    withAuthenticatedConfigWire codec authenticated $ \wire validated ->
                        pure
                            ( withVerifiedConfigHandoff
                                ProjectDestroy
                                handoff
                                wire
                                validated
                                (const ())
                            )
                case admitted of
                    Right (Left (HandoffBindingMismatch _)) -> pure ()
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
-- Recovery wire

recoveryTests :: [TestTree]
recoveryTests =
    [ testCase "the canonical request/response verifies only with the independent key" $
        withHandoff 21 ProjectDestroy $ \broker ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryBinding broker recoveryInput recoveryPayload $ \binding -> do
                    request <- expectRight (recoveryRequestFields binding recoveryPayload)
                    decoded <-
                        expectRight
                            ( recoveryRequestFromFields broker recoveryInput request $ \decodedBinding decodedWire ->
                                (renderRecoveryProjectionBinding decodedBinding, decodedWire)
                            )
                    decoded @?= (renderRecoveryProjectionBinding binding, recoveryPayload)
                    grant <- expectRight =<< signRecoveryWire broker binding recoveryPayload
                    response <- expectRight (recoveryResponseFromFields binding (recoveryResponseFields grant))
                    withVerifiedRecoveryWire
                        (rootBrokerVerificationKey broker)
                        binding
                        recoveryPayload
                        response
                        verifiedRecoveryWireBytes
                        @?= Right recoveryPayload
    , testCase "wrong key, wire, raw signature, plan, and edge each refuse" $
        withHandoff 22 ProjectDestroy $ \broker ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryBinding broker recoveryInput recoveryPayload $ \binding -> do
                    grant <- expectRight =<< signRecoveryWire broker binding recoveryPayload
                    otherSigning <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 91))
                    let verifyWith key bytes candidate =
                            withVerifiedRecoveryWire key binding bytes candidate (const ())
                    verifyWith (projectSigningVerificationKey otherSigning) recoveryPayload grant
                        @?= Left HandoffRecoverySignatureInvalid
                    case verifyWith (rootBrokerVerificationKey broker) "changed-wire" grant of
                        Left (HandoffPayloadDigestMismatch _ _) -> pure ()
                        other -> assertFailure ("expected wrong-wire refusal, got " <> show other)
                    raw <- expectRight (recoveryWireGrantFromSignature binding (ByteString.replicate 64 0))
                    verifyWith (rootBrokerVerificationKey broker) recoveryPayload raw
                        @?= Left HandoffRecoverySignatureInvalid
                    traverse_
                        ( \coordinates ->
                            withRecoveryInput coordinates $ \substituted ->
                                assertSubstitutedRecoveryRefuses
                                    broker
                                    (recoveryWireGrantSignature grant)
                                    substituted
                        )
                        [ baseRecoveryCoordinates{recoveryPlanCoordinate = "other-plan"}
                        , baseRecoveryCoordinates{recoveryParentCoordinate = "other-parent"}
                        , baseRecoveryCoordinates{recoveryChildCoordinate = "other-child"}
                        ]
    , testCase "the binding and response codecs reject truncation, trailing bytes, and wrong field counts" $
        withHandoff 23 ProjectDestroy $ \broker ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryBinding broker recoveryInput recoveryPayload $ \binding -> do
                    let encoded = renderRecoveryProjectionBinding binding
                        parse raw = recoveryProjectionBindingFromWire broker recoveryInput raw (const ())
                    case parse (ByteString.take (ByteString.length encoded - 1) encoded) of
                        Left (HandoffWireTruncated _ _) -> pure ()
                        other -> assertFailure ("expected truncated binding refusal, got " <> show other)
                    parse (encoded <> "trailing") @?= Left (HandoffWireTrailingBytes 8)
                    recoveryRequestFromFields broker recoveryInput [encoded] (\_ _ -> ())
                        @?= Left (HandoffRecoveryFieldCount "request" 2 1)
                    case recoveryResponseFromFields binding [] of
                        Left failure -> failure @?= HandoffRecoveryFieldCount "response" 1 0
                        Right _ -> assertFailure "expected an empty recovery response to refuse"
                    case recoveryResponseFromFields binding [ByteString.replicate 63 0] of
                        Left (HandoffRecoverySignatureLength 64 63) -> pure ()
                        _ -> assertFailure "expected a truncated recovery response to refuse"
    , testCase "only teardown roots sign, and config/recovery handoffs do not substitute" $ do
        withHandoff 24 ProjectUp $ \broker ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryBinding broker recoveryInput recoveryPayload $ \binding -> do
                    signed <- signRecoveryWire broker binding recoveryPayload
                    case signed of
                        Left failure -> failure @?= HandoffRecoveryVerbInvalid "up"
                        Right _ -> assertFailure "expected an up root to refuse recovery signing"
        withHandoff 25 ProjectDestroy $ \broker ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryBinding broker recoveryInput recoveryPayload $ \projection -> do
                    recoveryGrant <- expectRight =<< signRecoveryWire broker projection recoveryPayload
                    (recoveryBinding, recoveryOffer) <- newOfferWith broker (recoveryBindingInput recoveryInput recoveryPayload) recoveryPayload
                    challenge <- freshChallenge
                    ordinaryGrant <- expectRightIO =<< grantHandoff broker recoveryOffer challenge
                    recoveryHandoff <-
                        expectRight
                            ( verifyHandoff
                                (rootBrokerVerificationKey broker)
                                (handoffOfferWire recoveryOffer)
                                recoveryBinding
                                challenge
                                ordinaryGrant
                            )
                    case verifiedConfigPayload recoveryHandoff of
                        Left (HandoffBindingMismatch _) -> pure ()
                        other -> assertFailure ("expected recovery-as-config refusal, got " <> show other)
                    withVerifiedRecoveryHandoff
                        ProjectDestroy
                        projection
                        recoveryGrant
                        recoveryHandoff
                        (const ())
                        @?= Right ()
                    (_, configOffer) <- newOffer broker childPayload
                    configChallenge <- freshChallenge
                    configGrant <- expectRightIO =<< grantHandoff broker configOffer configChallenge
                    configHandoff <-
                        expectRight
                            ( verifyHandoff
                                (rootBrokerVerificationKey broker)
                                (handoffOfferWire configOffer)
                                (handoffOfferBinding configOffer)
                                configChallenge
                                configGrant
                            )
                    case withVerifiedRecoveryHandoff
                        ProjectDestroy
                        projection
                        recoveryGrant
                        configHandoff
                        (const ()) of
                        Left (HandoffBindingMismatch _) -> pure ()
                        other -> assertFailure ("expected config-as-recovery refusal, got " <> show other)
    , testCase "a recovery join uses the key retained by the verified handoff" $
        withHandoffPair 26 27 ProjectDestroy $ \handoffBroker recoveryBroker ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryBinding handoffBroker recoveryInput recoveryPayload $ \projection -> do
                    -- Both brokers are valid for the same root evidence and durable
                    -- route, but only the first key authenticated this handoff.
                    -- A caller must not be able to replace that retained key at the
                    -- config/recovery join.
                    foreignRecoveryGrant <-
                        expectRight =<< signRecoveryWire recoveryBroker projection recoveryPayload
                    (binding, offer) <-
                        newOfferWith
                            handoffBroker
                            (recoveryBindingInput recoveryInput recoveryPayload)
                            recoveryPayload
                    challenge <- freshChallenge
                    grant <- expectRightIO =<< grantHandoff handoffBroker offer challenge
                    handoff <-
                        expectRight
                            ( verifyHandoff
                                (rootBrokerVerificationKey handoffBroker)
                                (handoffOfferWire offer)
                                binding
                                challenge
                                grant
                            )
                    withVerifiedRecoveryHandoff
                        ProjectDestroy
                        projection
                        foreignRecoveryGrant
                        handoff
                        (const ())
                        @?= Left HandoffRecoverySignatureInvalid
    , testCase "a recovery grant cannot replay across protected stores" $
        withSystemTempDirectory "hostbootstrap-recovery-cross-store" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 28))
            firstStore <- openProtectedStore (directory </> "first") >>= expectRightIO
            secondStore <- openProtectedStore (directory </> "second") >>= expectRightIO
            Fixture.withFixtureInstalledProject $ \project -> do
                signature <-
                    captureRecoverySignature signing firstStore project ProjectDestroy
                withRecoveryBroker signing secondStore project ProjectDestroy $ \broker ->
                    withRecoveryInput baseRecoveryCoordinates $ \input ->
                        assertRecoveryReplayRefused
                            broker
                            ProjectDestroy
                            input
                            signature
    , testCase "a recovery grant cannot replay across broker generations" $
        withSystemTempDirectory "hostbootstrap-recovery-cross-generation" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 29))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            Fixture.withFixtureInstalledProject $ \project -> do
                signature <- captureRecoverySignature signing store project ProjectDestroy
                withRecoveryBroker signing store project ProjectDestroy $ \broker ->
                    withRecoveryInput baseRecoveryCoordinates $ \input ->
                        assertRecoveryReplayRefused
                            broker
                            ProjectDestroy
                            input
                            signature
    , testCase "down and destroy recovery grants refuse substitution in both directions" $
        withSystemTempDirectory "hostbootstrap-recovery-cross-verb" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 30))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            Fixture.withFixtureInstalledProject $ \project -> do
                downSignature <- captureRecoverySignature signing store project ProjectDown
                destroySignature <- captureRecoverySignature signing store project ProjectDestroy
                withRecoveryBroker signing store project ProjectDestroy $ \broker ->
                    withRecoveryInput baseRecoveryCoordinates $ \input ->
                        assertRecoveryReplayRefused
                            broker
                            ProjectDestroy
                            input
                            downSignature
                withRecoveryBroker signing store project ProjectDown $ \broker ->
                    withRecoveryInput baseRecoveryCoordinates $ \input ->
                        assertRecoveryReplayRefused
                            broker
                            ProjectDown
                            input
                            destroySignature
    ]

-- ---------------------------------------------------------------------------
-- Fixtures

childPayload :: ByteString.ByteString
childPayload = ByteStringChar8.pack "{ message = \"Hello, world!\" }"

secretPayload :: ByteString.ByteString
secretPayload = "SECRET-CONFIG-BYTES-DO-NOT-PRINT"

recoveryPayload :: ByteString.ByteString
recoveryPayload = "provider=incus;instance=demo-vm;policy=destroy"

data RecoveryCoordinates = RecoveryCoordinates
    { recoveryPlanCoordinate :: Text.Text
    , recoveryParentCoordinate :: Text.Text
    , recoveryChildCoordinate :: Text.Text
    }

baseRecoveryCoordinates :: RecoveryCoordinates
baseRecoveryCoordinates =
    RecoveryCoordinates
        { recoveryPlanCoordinate = "plan-digest-1"
        , recoveryParentCoordinate = "vm-orchestrator-1"
        , recoveryChildCoordinate = "vm-project-container-2"
        }

withRecoveryInput ::
    RecoveryCoordinates ->
    ( forall planDigest parentFrame childFrame.
      RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
      IO result
    ) ->
    IO result
withRecoveryInput coordinates use =
    expectRight
        ( withRecoveryProjectionBindingInput
            (recoveryPlanCoordinate coordinates)
            (recoveryParentCoordinate coordinates)
            (recoveryChildCoordinate coordinates)
            use
        )
        >>= id

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

recoveryBindingInput ::
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    ByteString.ByteString ->
    HandoffBindingInput
recoveryBindingInput recoveryInput payload =
    HandoffBindingInput
        { requestedSpecDigest = "spec-digest-1"
        , requestedPayloadKind = RecoveryAdapterWire
        , requestedPlanRevision = requestedRecoveryPlanDigest recoveryInput
        , requestedParentFrame = requestedRecoveryParentFrame recoveryInput
        , requestedChildFrame = requestedRecoveryChildFrame recoveryInput
        , requestedChildConfigDigest = recoveryWireDigest payload
        , requestedPhase = "teardown"
        }

newOffer ::
    RootBroker scope brokerGeneration verb ->
    ByteString.ByteString ->
    IO
        ( HandoffBinding scope brokerGeneration
        , HandoffOffer scope brokerGeneration
        )
newOffer broker payload = do
    newOfferWith broker (bindingInputFor payload) payload

newOfferWith ::
    RootBroker scope brokerGeneration verb ->
    HandoffBindingInput ->
    ByteString.ByteString ->
    IO
        ( HandoffBinding scope brokerGeneration
        , HandoffOffer scope brokerGeneration
        )
newOfferWith broker input payload = do
    (relay, token) <- expectRightIO =<< registerHandoffEdge broker input
    offer <- expectRight (mkHandoffOffer relay payload token)
    pure (relayBinding relay, offer)

withRecoveryBinding ::
    RootBroker scope brokerGeneration verb ->
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    ByteString.ByteString ->
    ( forall recoveryWireDigest.
      RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
      IO result
    ) ->
    IO result
withRecoveryBinding broker input wire use =
    case mkRecoveryProjectionBinding broker input wire use of
        Left failure -> assertFailure (show failure)
        Right action -> action

captureRecoverySignature ::
    ProjectSigningKey ->
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ProjectVerb verb ->
    IO ByteString.ByteString
captureRecoverySignature signing store project verb =
    withRecoveryBroker signing store project verb $ \broker ->
        withRecoveryInput baseRecoveryCoordinates $ \input ->
            withRecoveryBinding broker input recoveryPayload $ \binding ->
                recoveryWireGrantSignature
                    <$> (expectRight =<< signRecoveryWire broker binding recoveryPayload)

withRecoveryBroker ::
    ProjectSigningKey ->
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ProjectVerb verb ->
    ( forall brokerGeneration.
      RootBroker (Production projectId) brokerGeneration verb ->
      IO result
    ) ->
    IO result
withRecoveryBroker signing store project verb use = do
    outcome <- withProductionRoot store project verb $ \root -> do
        brokered <-
            withRootBroker
                (productionHandoffScope project)
                store
                signing
                (productionRootAuthority root)
                use
        result <- either (assertFailure . show) pure brokered
        pure (Right result)
    either (assertFailure . show) pure outcome

assertRecoveryReplayRefused ::
    RootBroker scope brokerGeneration verb ->
    ProjectVerb verb ->
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    ByteString.ByteString ->
    IO ()
assertRecoveryReplayRefused broker verb input foreignSignature =
    withRecoveryBinding broker input recoveryPayload $ \projection -> do
        replayedGrant <-
            expectRight
                (recoveryWireGrantFromSignature projection foreignSignature)
        (binding, offer) <-
            newOfferWith
                broker
                (recoveryBindingInput input recoveryPayload)
                recoveryPayload
        challenge <- freshChallenge
        configGrant <- expectRightIO =<< grantHandoff broker offer challenge
        handoff <-
            expectRight
                ( verifyHandoff
                    (rootBrokerVerificationKey broker)
                    (handoffOfferWire offer)
                    binding
                    challenge
                    configGrant
                )
        withVerifiedRecoveryHandoff
            verb
            projection
            replayedGrant
            handoff
            (const ())
            @?= Left HandoffRecoverySignatureInvalid

assertSubstitutedRecoveryRefuses ::
    RootBroker scope brokerGeneration verb ->
    ByteString.ByteString ->
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    IO ()
assertSubstitutedRecoveryRefuses broker originalSignature input =
    withRecoveryBinding broker input recoveryPayload $ \substituted -> do
        adopted <-
            expectRight
                ( recoveryWireGrantFromSignature
                    substituted
                    originalSignature
                )
        withVerifiedRecoveryWire
            (rootBrokerVerificationKey broker)
            substituted
            recoveryPayload
            adopted
            (const ())
            @?= Left HandoffRecoverySignatureInvalid

authenticatedPayload ::
    RootBroker scope brokerGeneration verb ->
    ByteString.ByteString ->
    IO (AuthenticatedConfigPayload scope brokerGeneration)
authenticatedPayload broker payload = do
    verified <- verifiedHandoffFor broker payload
    expectRight (verifiedConfigPayload verified)

verifiedHandoffFor ::
    RootBroker scope brokerGeneration verb ->
    ByteString.ByteString ->
    IO (VerifiedHandoff scope brokerGeneration)
verifiedHandoffFor broker payload = do
    (binding, offer) <- newOffer broker payload
    challenge <- freshChallenge
    grant <- expectRightIO =<< grantHandoff broker offer challenge
    expectRight
        ( verifyHandoff
            (rootBrokerVerificationKey broker)
            (handoffOfferWire offer)
            binding
            challenge
            grant
        )

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
    ( forall projectId (brokerGeneration :: Type).
      RootBroker (Production projectId) brokerGeneration verb ->
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

withHandoffPair ::
    Word8 ->
    Word8 ->
    ProjectVerb verb ->
    ( forall projectId (brokerGeneration :: Type).
      RootBroker (Production projectId) brokerGeneration verb ->
      RootBroker (Production projectId) brokerGeneration verb ->
      IO ()
    ) ->
    IO ()
withHandoffPair firstSeed secondSeed verb use =
    withSystemTempDirectory "hostbootstrap-handoff-pair" $ \directory -> do
        firstSigning <-
            expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 firstSeed))
        secondSigning <-
            expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 secondSeed))
        store <- openProtectedStore (directory </> "authority") >>= expectRightIO
        outcome <- Fixture.withFixtureInstalledProject $ \project ->
            withProductionRoot store project verb $ \root -> do
                first <-
                    withRootBroker
                        (productionHandoffScope project)
                        store
                        firstSigning
                        (productionRootAuthority root)
                        ( \firstBroker ->
                            withRootBroker
                                (productionHandoffScope project)
                                store
                                secondSigning
                                (productionRootAuthority root)
                                (use firstBroker)
                        )
                case first of
                    Left failure -> assertFailure (show failure)
                    Right second -> do
                        _ <- either (assertFailure . show) pure second
                        pure (Right ())
        _ <- either (assertFailure . show) pure outcome
        pure ()

withNamedHandoff ::
    Word8 ->
    ProjectVerb verb ->
    ( forall projectId (brokerGeneration :: Type).
      InstalledProjectIdentity projectId ->
      RootBroker (Production projectId) brokerGeneration verb ->
      IO result
    ) ->
    IO result
withNamedHandoff seedByte verb use =
    withSystemTempDirectory "hostbootstrap-named-handoff" $ \directory -> do
        signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 seedByte))
        store <- openProtectedStore (directory </> "authority") >>= expectRightIO
        outcome <- Fixture.withFixtureInstalledProject $ \project ->
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
    ( forall projectId (brokerGeneration :: Type).
      RootBroker (Production projectId) brokerGeneration verb ->
      IO ()
    ) ->
    IO ()
withRootFor signing store verb use = do
    outcome <- Fixture.withFixtureInstalledProject $ \project ->
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
    ( forall projectId runId (brokerGeneration :: Type).
      InstalledProjectIdentity projectId ->
      RootBroker (Harness projectId runId) brokerGeneration VerbUp ->
      HarnessAuthority projectId runId ->
      IO result
    ) ->
    IO result
withHarnessHandoff seedByte use =
    withSystemTempDirectory "hostbootstrap-handoff-harness" $ \directory -> do
        signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 seedByte))
        opened <- openProtectedStore (directory </> "authority")
        store <- either (assertFailure . show) pure opened
        Fixture.withFixtureInstalledProject $ \project -> do
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
                                (\broker -> use project broker (harnessRootHarnessAuthority root))
                        result <- either (assertFailure . show) pure brokered
                        pure (Right result)
                    )
            either (assertFailure . show) pure outcome

recoverNothing ::
    VerifiedIncompleteRunLease projectId ->
    IO (Either ModeError ())
recoverNothing _ = pure (Right ())

{- | Clear a fixture path whatever it currently names.

'doesFileExist' follows symbolic links, so it reports 'False' for a /dangling/
one and the path would survive cleanup — which is exactly how a single failed
run used to poison the destination for every later run in the same build tree.
'doesPathExist' asks about the name itself.
-}
removeIfPresent :: FilePath -> IO ()
removeIfPresent path = do
    present <- doesPathExist path
    when present (removePathForcibly path)

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
