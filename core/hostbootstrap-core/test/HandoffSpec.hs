{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The authenticated cross-frame handoff transport.

These cases run the real protocol against a real Ed25519 keypair and a real
protected store on disk: a grant is genuinely signed, a replay genuinely
re-presents recorded bytes, and a consumed token is genuinely a durable record.
Nothing here models the transport with a stand-in.
-}
module HandoffSpec (tests) where

import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Fixture
import HostBootstrap.Authority (
    AuthorityError (AuthorityStoreFailure),
    InstalledProject,
    ProjectVerb (ProjectDestroy, ProjectUp),
    installedProjectFor,
    verifyOperatorAuthorization,
    withFreshBrokerEpoch,
    withVerifiedRootInvocation,
 )
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Handoff
import HostBootstrap.Protected (
    ProtectedSession,
    ProtectedStore,
    openProtectedStore,
    withProtectedEntry,
 )
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
    ]

-- ---------------------------------------------------------------------------
-- Bindings

bindingTests :: [TestTree]
bindingTests =
    [ testCase "field boundaries are unambiguous across the frame edge" $ do
        -- With a separator-joined rendering these two bindings would produce
        -- identical bytes, and one signature would authenticate both edges.
        let left = sampleBinding{handoffParentFrame = "a-b", handoffChildFrame = "c"}
            right = sampleBinding{handoffParentFrame = "a", handoffChildFrame = "b-c"}
        assertBool
            "distinct edges render distinctly"
            (renderHandoffBinding left /= renderHandoffBinding right)
    , testCase "every bound field changes the rendering" $ do
        let variants =
                [ sampleBinding{handoffScope = "Harness run-7"}
                , sampleBinding{handoffPlanRevision = "rev-2"}
                , sampleBinding{handoffBrokerGeneration = 99}
                , sampleBinding{handoffParentFrame = "elsewhere"}
                , sampleBinding{handoffChildFrame = "elsewhere"}
                , sampleBinding{handoffChildConfigDigest = "deadbeef"}
                , sampleBinding{handoffVerb = "destroy"}
                , sampleBinding{handoffPhase = "teardown"}
                ]
            rendered = map renderHandoffBinding (sampleBinding : variants)
        length (dedupe rendered) @?= length rendered
    ]

dedupe :: (Eq a) => [a] -> [a]
dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- ---------------------------------------------------------------------------
-- The protocol

protocolTests :: [TestTree]
protocolTests =
    [ testCase "a genuine handoff verifies and yields child authority" $
        withHandoff ProjectUp $ \session broker -> do
            relay <- expectRight (brokerRelay broker (bindingFor childPayload))
            offer <- expectRight (mkHandoffOffer relay childPayload "token-1")
            challenge <- freshChallenge
            grant <- expectRight (signHandoffGrant broker (relayBinding relay) challenge)
            verified <-
                verifyHandoff
                    session
                    (rootBrokerVerificationKey broker)
                    (handoffOfferWire offer)
                    (relayBinding relay)
                    challenge
                    grant
            handoff <- expectRightIO verified
            verifiedHandoffPayload handoff @?= childPayload
            authority <- expectRight (authorizeChildProject handoff "vm-project-container-2" ProjectUp)
            childPlanAuthorityBinding authority @?= relayBinding relay
    , testCase "the same token cannot be consumed twice" $
        withHandoff ProjectUp $ \session broker -> do
            relay <- expectRight (brokerRelay broker (bindingFor childPayload))
            offer <- expectRight (mkHandoffOffer relay childPayload "token-replay")
            challenge <- freshChallenge
            grant <- expectRight (signHandoffGrant broker (relayBinding relay) challenge)
            let attempt = verifyHandoff session (rootBrokerVerificationKey broker) (handoffOfferWire offer) (relayBinding relay) challenge grant
            first <- attempt
            assertBool "the first consumption succeeds" (isRight first)
            -- The recorded transcript is byte-identical and its signature is
            -- genuine; only the burnt token stops it.
            second <- attempt
            case second of
                Left (HandoffTokenConsumed token) -> token @?= "token-replay"
                other -> assertFailure ("expected a consumed-token refusal, got " <> show other)
    , testCase "a grant for another challenge does not authenticate this one" $
        withHandoff ProjectUp $ \session broker -> do
            relay <- expectRight (brokerRelay broker (bindingFor childPayload))
            offer <- expectRight (mkHandoffOffer relay childPayload "token-challenge")
            recorded <- freshChallenge
            grant <- expectRight (signHandoffGrant broker (relayBinding relay) recorded)
            fresh <- freshChallenge
            assertBool
                "the receiver issued a different challenge"
                (challengeBytes fresh /= challengeBytes recorded)
            outcome <-
                verifyHandoff
                    session
                    (rootBrokerVerificationKey broker)
                    (handoffOfferWire offer)
                    (relayBinding relay)
                    fresh
                    grant
            expectSignatureRefusal outcome
    , testCase "a payload swapped after signing fails its bound digest" $
        withHandoff ProjectUp $ \session broker -> do
            relay <- expectRight (brokerRelay broker (bindingFor childPayload))
            challenge <- freshChallenge
            grant <- expectRight (signHandoffGrant broker (relayBinding relay) challenge)
            -- A genuine grant, re-attached to different config bytes.
            let swapped = frameWire "message = \"attacker\"" <> frameWire "token-swap"
            outcome <-
                verifyHandoff
                    session
                    (rootBrokerVerificationKey broker)
                    swapped
                    (relayBinding relay)
                    challenge
                    grant
            case outcome of
                Left (HandoffPayloadDigestMismatch expected actual) ->
                    assertBool "the digests differ" (expected /= actual)
                other -> assertFailure ("expected a digest refusal, got " <> show other)
    , testCase "another root's key cannot authenticate this root's grant" $
        withHandoff ProjectUp $ \session broker ->
            withHandoff ProjectUp $ \_ other -> do
                relay <- expectRight (brokerRelay broker (bindingFor childPayload))
                offer <- expectRight (mkHandoffOffer relay childPayload "token-key")
                challenge <- freshChallenge
                grant <- expectRight (signHandoffGrant broker (relayBinding relay) challenge)
                outcome <-
                    verifyHandoff
                        session
                        (rootBrokerVerificationKey other)
                        (handoffOfferWire offer)
                        (relayBinding relay)
                        challenge
                        grant
                expectSignatureRefusal outcome
                assertBool
                    "the two roots really do have different keys"
                    ( verificationKeyBytes (rootBrokerVerificationKey broker)
                        /= verificationKeyBytes (rootBrokerVerificationKey other)
                    )
    , testCase "a sibling frame cannot use a grant minted for its peer" $
        withHandoff ProjectUp $ \session broker -> do
            relay <- expectRight (brokerRelay broker (bindingFor childPayload))
            offer <- expectRight (mkHandoffOffer relay childPayload "token-sibling")
            challenge <- freshChallenge
            grant <- expectRight (signHandoffGrant broker (relayBinding relay) challenge)
            verified <-
                verifyHandoff
                    session
                    (rootBrokerVerificationKey broker)
                    (handoffOfferWire offer)
                    (relayBinding relay)
                    challenge
                    grant
            handoff <- expectRightIO verified
            case authorizeChildProject handoff "daemon-3" ProjectUp of
                Left (HandoffFrameMismatch bound actual) -> do
                    bound @?= "vm-project-container-2"
                    actual @?= "daemon-3"
                other -> assertFailure ("expected a frame refusal, got " <> show other)
    , testCase "an up handoff cannot authorize a teardown edge" $
        withHandoff ProjectUp $ \session broker -> do
            relay <- expectRight (brokerRelay broker (bindingFor childPayload))
            offer <- expectRight (mkHandoffOffer relay childPayload "token-verb")
            challenge <- freshChallenge
            grant <- expectRight (signHandoffGrant broker (relayBinding relay) challenge)
            verified <-
                verifyHandoff
                    session
                    (rootBrokerVerificationKey broker)
                    (handoffOfferWire offer)
                    (relayBinding relay)
                    challenge
                    grant
            handoff <- expectRightIO verified
            case authorizeChildProject handoff "vm-project-container-2" ProjectDestroy of
                Left (HandoffBindingMismatch _) -> pure ()
                other -> assertFailure ("expected a verb refusal, got " <> show other)
    , testCase "a root refuses to relay or sign a binding from another generation" $
        withHandoff ProjectUp $ \_ broker -> do
            let foreign' = (bindingFor childPayload){handoffBrokerGeneration = 987654}
            case brokerRelay broker foreign' of
                Left (HandoffBindingMismatch _) -> pure ()
                other -> assertFailure ("expected a relay refusal, got " <> show other)
            challenge <- freshChallenge
            case signHandoffGrant broker foreign' challenge of
                Left (HandoffBindingMismatch _) -> pure ()
                other -> assertFailure ("expected a signing refusal, got " <> show other)
    , testCase "a root refuses to sign a verb its invocation did not authorize" $
        withHandoff ProjectUp $ \_ broker -> do
            let wrongVerb = (bindingFor childPayload){handoffVerb = "destroy"}
            case brokerRelay broker wrongVerb of
                Left (HandoffBindingMismatch _) -> pure ()
                other -> assertFailure ("expected a verb relay refusal, got " <> show other)
    , testCase "a parent cannot offer a payload the binding does not describe" $
        withHandoff ProjectUp $ \_ broker -> do
            relay <- expectRight (brokerRelay broker (bindingFor childPayload))
            case mkHandoffOffer relay "different bytes entirely" "token-bad" of
                Left (HandoffBindingMismatch _) -> pure ()
                other -> assertFailure ("expected an offer refusal, got " <> show other)
    , testCase "an empty or malformed token frame is refused" $
        withHandoff ProjectUp $ \session broker -> do
            relay <- expectRight (brokerRelay broker (bindingFor childPayload))
            challenge <- freshChallenge
            grant <- expectRight (signHandoffGrant broker (relayBinding relay) challenge)
            let key = rootBrokerVerificationKey broker
                verifyWire wire =
                    verifyHandoff session key wire (relayBinding relay) challenge grant
            -- No token frame at all.
            missing <- verifyWire (frameWire childPayload)
            case missing of
                Left (HandoffWireTruncated{}) -> pure ()
                other -> assertFailure ("expected a truncated-wire refusal, got " <> show other)
            -- Present but empty.
            empty' <- verifyWire (frameWire childPayload <> frameWire "")
            case empty' of
                Left (HandoffTokenInvalid _) -> pure ()
                other -> assertFailure ("expected an invalid-token refusal, got " <> show other)
            -- Trailing bytes after the token.
            trailing <- verifyWire (frameWire childPayload <> frameWire "t" <> "junk")
            case trailing of
                Left (HandoffWireTrailingBytes _) -> pure ()
                other -> assertFailure ("expected a trailing-bytes refusal, got " <> show other)
    , testCase "an unauthenticated message cannot burn a token" $
        withHandoff ProjectUp $ \session broker -> do
            relay <- expectRight (brokerRelay broker (bindingFor childPayload))
            offer <- expectRight (mkHandoffOffer relay childPayload "token-order")
            challenge <- freshChallenge
            stale <- freshChallenge
            badGrant <- expectRight (signHandoffGrant broker (relayBinding relay) stale)
            let key = rootBrokerVerificationKey broker
                wire = handoffOfferWire offer
            refused <- verifyHandoff session key wire (relayBinding relay) challenge badGrant
            expectSignatureRefusal refused
            -- The token survived the forgery attempt, so the legitimate parent
            -- can still complete its handoff.
            goodGrant <- expectRight (signHandoffGrant broker (relayBinding relay) challenge)
            accepted <- verifyHandoff session key wire (relayBinding relay) challenge goodGrant
            assertBool "the genuine handoff still succeeds" (isRight accepted)
    , testCase "an installed key file round-trips and a missing one is a typed refusal" $
        withSystemTempDirectory "hostbootstrap-handoff-key" $ \directory ->
            withHandoff ProjectUp $ \_ broker -> do
                let path = directory </> "project.pub"
                ByteString.writeFile path (verificationKeyBytes (rootBrokerVerificationKey broker))
                loaded <- installedVerificationKey path
                case loaded of
                    Right key ->
                        verificationKeyBytes key
                            @?= verificationKeyBytes (rootBrokerVerificationKey broker)
                    Left failure -> assertFailure ("expected a loaded key, got " <> show failure)
                absent <- installedVerificationKey (directory </> "absent.pub")
                case absent of
                    Left (HandoffVerificationKeyUnavailable _) -> pure ()
                    other -> assertFailure ("expected a missing-key refusal, got " <> show other)
                ByteString.writeFile path "not a key"
                malformed <- installedVerificationKey path
                case malformed of
                    Left (HandoffVerificationKeyUnavailable _) -> pure ()
                    other -> assertFailure ("expected a malformed-key refusal, got " <> show other)
    ]

-- ---------------------------------------------------------------------------
-- Fixtures

childPayload :: ByteString.ByteString
childPayload = ByteStringChar8.pack "{ message = \"Hello, world!\" }"

sampleBinding :: HandoffBinding
sampleBinding = bindingFor childPayload

{- | The binding for the demo's VM→container edge, with the digest of the exact
payload being carried.
-}
bindingFor :: ByteString.ByteString -> HandoffBinding
bindingFor payload =
    HandoffBinding
        { handoffScope = "Production"
        , handoffPlanRevision = "rev-1"
        , handoffBrokerGeneration = 1
        , handoffParentFrame = "vm-orchestrator-1"
        , handoffChildFrame = "vm-project-container-2"
        , handoffChildConfigDigest = childConfigDigest payload
        , handoffVerb = "up"
        , handoffPhase = "execute"
        }

{- | Run an action inside a real protected store with a real root broker for the
given verb.
-}
withHandoff ::
    ProjectVerb verb ->
    ( forall session brokerGeneration.
      ProtectedSession session ->
      RootBroker (Production Fixture.FixtureProject) brokerGeneration verb ->
      IO ()
    ) ->
    IO ()
withHandoff verb use =
    withSystemTempDirectory "hostbootstrap-handoff" $ \directory -> do
        opened <- openProtectedStore (directory </> "authority")
        case opened of
            Left failure -> assertFailure (show failure)
            Right store -> withRootFor store verb use

withRootFor ::
    ProtectedStore ->
    ProjectVerb verb ->
    ( forall session brokerGeneration.
      ProtectedSession session ->
      RootBroker (Production Fixture.FixtureProject) brokerGeneration verb ->
      IO ()
    ) ->
    IO ()
withRootFor store verb use = do
    outcome <-
        withAuthorityEntry store $ \session -> do
            operator <- verifyOperatorAuthorization session
            case operator of
                Left failure -> pure (Left failure)
                Right authorized ->
                    withFixtureProject $ \project ->
                        withFreshBrokerEpoch session project $ \epoch ->
                            withVerifiedRootInvocation
                                session
                                project
                                authorized
                                epoch
                                verb
                                (\root -> Right <$> withRootBroker root (use session))
    case outcome of
        Left failure -> assertFailure (show failure)
        Right () -> pure ()

withAuthorityEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either AuthorityError result)) ->
    IO (Either AuthorityError result)
withAuthorityEntry store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    pure (either (Left . AuthorityStoreFailure) id outcome)

withFixtureProject ::
    (InstalledProject Fixture.FixtureProject -> IO result) ->
    IO result
withFixtureProject use =
    case installedProjectFor @Fixture.FixtureProject @Fixture.ProjectConfig "hostbootstrap-demo" of
        Left failure -> assertFailure (show failure)
        Right project -> use project

expectRight :: (Show err) => Either err value -> IO value
expectRight (Right value) = pure value
expectRight (Left failure) = assertFailure ("expected success, got " <> show failure)

expectRightIO :: (Show err) => Either err value -> IO value
expectRightIO = expectRight

expectSignatureRefusal :: (Show value) => Either HandoffError value -> IO ()
expectSignatureRefusal outcome = case outcome of
    Left (HandoffSignatureInvalid _) -> pure ()
    other -> assertFailure ("expected a signature refusal, got " <> show other)

isRight :: Either a b -> Bool
isRight = either (const False) (const True)
