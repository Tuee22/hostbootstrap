{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Build-invocation authority for the in-Dockerfile gate.

Every case measures real files in a real temporary tree and signs with a real
Ed25519 keypair, because the whole point of this gate is that the signed
description and the locally measured reality must agree.
-}
module BuildAuthoritySpec (tests) where

import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Data.ByteArray (convert)
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Crypto.PubKey.Ed25519 as Ed25519
import HostBootstrap.Build
import HostBootstrap.Handoff (frameWire)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "BuildAuthoritySpec"
        [ testGroup "provisioned keys" keyTests
        , testGroup "source measurement" measurementTests
        , testGroup "the coordinator channel" channelTests
        , testGroup "verification" verificationTests
        ]

-- ---------------------------------------------------------------------------
-- Provisioned identity

keyTests :: [TestTree]
keyTests =
    [ testCase "signing and verification keys are provisioned through separate files" $
        withSystemTempDirectory "hostbootstrap-build-keys" $ \root -> do
            let signingPath = root </> "coordinator.key"
                verificationPath = root </> "coordinator.pub"
            ByteString.writeFile signingPath fixtureSigningSeed
            signingKey <- expectIO =<< installedBuildSigningKey signingPath
            let provisionedVerificationKey = buildSigningVerificationKey signingKey
            ByteString.writeFile
                verificationPath
                (buildVerificationKeyBytes provisionedVerificationKey)
            installedVerificationKey <- expectIO =<< installedBuildVerificationKey verificationPath
            buildVerificationKeyBytes installedVerificationKey
                @?= buildVerificationKeyBytes provisionedVerificationKey
    , testCase "a malformed signing seed is refused" $
        case buildSigningKeyFromBytes "short" of
            Left (BuildSigningKeyInvalid _) -> pure ()
            other -> assertFailure ("expected an invalid signing key, got " <> show other)
    , testCase "a malformed installed verification key is refused" $
        withSystemTempDirectory "hostbootstrap-build-keys" $ \root -> do
            let path = root </> "coordinator.pub"
            ByteString.writeFile path "short"
            outcome <- installedBuildVerificationKey path
            case outcome of
                Left (BuildVerificationKeyInvalid _) -> pure ()
                other -> assertFailure ("expected an invalid verification key, got " <> show other)
    , testCase "missing provisioned keys are typed refusals" $
        withSystemTempDirectory "hostbootstrap-build-keys" $ \root -> do
            signing <- installedBuildSigningKey (root </> "missing.key")
            case signing of
                Left (BuildSigningKeyUnavailable _) -> pure ()
                other -> assertFailure ("expected an unavailable signing key, got " <> show other)
            verification <- installedBuildVerificationKey (root </> "missing.pub")
            case verification of
                Left (BuildVerificationKeyUnavailable _) -> pure ()
                other -> assertFailure ("expected an unavailable verification key, got " <> show other)
    ]

-- ---------------------------------------------------------------------------
-- Measurement

measurementTests :: [TestTree]
measurementTests =
    [ testCase "the same tree measures the same digest twice" $
        withSourceTree $ \root -> do
            first <- expectIO =<< measureSourceDigest root
            second <- expectIO =<< measureSourceDigest root
            first @?= second
    , testCase "changed contents change the digest" $
        withSourceTree $ \root -> do
            before <- expectIO =<< measureSourceDigest root
            ByteString.writeFile (root </> "src" </> "Main.hs") "main = pure ()\n-- edited"
            after <- expectIO =<< measureSourceDigest root
            assertBool "the digest moved" (before /= after)
    , testCase "moving bytes to a different name changes the digest" $
        withSourceTree $ \root -> do
            before <- expectIO =<< measureSourceDigest root
            contents <- ByteString.readFile (root </> "src" </> "Main.hs")
            ByteString.writeFile (root </> "src" </> "Renamed.hs") contents
            ByteString.writeFile (root </> "src" </> "Main.hs") ""
            after <- expectIO =<< measureSourceDigest root
            -- Path and contents are both bound, so relocating bytes is visible.
            assertBool "the digest moved" (before /= after)
    , testCase "distinct non-ASCII filenames do not collide" $
        withSystemTempDirectory "hostbootstrap-build-unicode" $ \root -> do
            let first = root </> "first"
                second = root </> "second"
            createDirectoryIfMissing True first
            createDirectoryIfMissing True second
            -- These code points have the same low eight bits. Char8 path
            -- encoding therefore collapsed them even though UTF-8 does not.
            ByteString.writeFile (first </> "\x4e00.hs") "same contents"
            ByteString.writeFile (second </> "\x4f00.hs") "same contents"
            firstDigest <- expectIO =<< measureSourceDigest first
            secondDigest <- expectIO =<< measureSourceDigest second
            assertBool "the Unicode path bytes remain distinct" (firstDigest /= secondDigest)
    , testCase "an absent source root is a refusal, not an empty-tree digest" $
        withSystemTempDirectory "hostbootstrap-build" $ \directory -> do
            outcome <- measureSourceDigest (directory </> "not-here")
            case outcome of
                Left (BuildSourceUnavailable _) -> pure ()
                other -> assertFailure ("expected a source refusal, got " <> show other)
    , testCase "an absent binary is a refusal, not a skipped comparison" $
        withSystemTempDirectory "hostbootstrap-build" $ \directory -> do
            outcome <- measureBinaryDigest (directory </> "no-binary")
            case outcome of
                Left (BuildBinaryUnavailable _) -> pure ()
                other -> assertFailure ("expected a binary refusal, got " <> show other)
    ]

-- ---------------------------------------------------------------------------
-- Channel

channelTests :: [TestTree]
channelTests =
    [ testCase "a rendered channel round-trips" $
        withFixture $ \fixture -> do
            let path = fixtureRoot fixture </> "channel.bin"
            ByteString.writeFile path (renderBuildChannel (fixtureChannel fixture))
            decoded <- expectIO =<< readBuildChannel path
            channelBinding decoded @?= channelBinding (fixtureChannel fixture)
            buildGrantSignature (channelGrant decoded)
                @?= buildGrantSignature (channelGrant (fixtureChannel fixture))
    , testCase "a build backend with no channel is Unsupported, not a fallback" $
        withSystemTempDirectory "hostbootstrap-build" $ \directory -> do
            outcome <- readBuildChannel (directory </> "absent-channel")
            case outcome of
                Left (BuildChannelUnavailable _) -> pure ()
                other -> assertFailure ("expected an unavailable channel, got " <> show other)
    , testCase "a truncated channel is malformed, not partially accepted" $
        withFixture $ \fixture -> do
            let path = fixtureRoot fixture </> "channel.bin"
                full = renderBuildChannel (fixtureChannel fixture)
            ByteString.writeFile path (ByteString.take (ByteString.length full - 5) full)
            outcome <- readBuildChannel path
            case outcome of
                Left (BuildChannelMalformed _) -> pure ()
                other -> assertFailure ("expected a malformed channel, got " <> show other)
    ]

-- ---------------------------------------------------------------------------
-- Verification

verificationTests :: [TestTree]
verificationTests =
    [ testCase "an authenticated build yields the frame and its two phase authorities" $
        withFixture $ \fixture -> do
            verified <-
                verifyFixture fixture (fixtureChannel fixture) $ \frame authority -> do
                    imageBuildFrameName frame @?= "image-build-container-0"
                    buildAuthorityBuildId authority @?= "build-7"
                    checkAuthority <- expectIO =<< authorizeCheckCode frame authority
                    buildAuthority <- expectIO =<< authorizeBuildPhase frame authority
                    buildCommandAuthorityPhase checkAuthority @?= CheckCodePhase
                    buildCommandAuthorityPhase buildAuthority @?= BuildPhase
            _ <- expectIO verified
            pure ()
    , testCase "each narrow build phase is at most once on one returned authority" $
        withFixture $ \fixture -> do
            verified <-
                verifyFixture fixture (fixtureChannel fixture) $ \frame authority -> do
                    _ <- expectIO =<< authorizeCheckCode frame authority
                    duplicate <- authorizeCheckCode frame authority
                    case duplicate of
                        Left (BuildPhaseAlreadyAuthorized CheckCodePhase) -> pure ()
                        other -> assertFailure ("expected a consumed phase, got " <> show other)
            _ <- expectIO verified
            pure ()
    , testCase "a grant for another project is refused" $
        withFixture $ \fixture -> do
            tampered <- rebind fixture (\b -> b{buildProjectName = "other-project"})
            outcome <- verifyFixture fixture tampered ignoreVerified
            expectMismatch "project" outcome
    , testCase "a grant naming a different config digest is refused" $
        withFixture $ \fixture -> do
            tampered <- rebind fixture (\b -> b{buildConfigDigest = "0000"})
            outcome <- verifyFixture fixture tampered ignoreVerified
            expectMismatch "config digest" outcome
    , testCase "a grant naming another finalized spec is refused" $
        withFixture $ \fixture -> do
            tampered <- rebind fixture (\b -> b{buildSpecDigest = "spec-other"})
            outcome <- verifyFixture fixture tampered ignoreVerified
            expectMismatch "spec digest" outcome
    , testCase "a grant naming another coordinator binary is refused" $
        withFixture $ \fixture -> do
            outcome <-
                verifyBuildInvocation
                    (fixtureKey fixture)
                    (fixtureProject fixture)
                    (fixtureSpecDigest fixture)
                    (fixtureConfigDigest fixture)
                    "coordinator-other"
                    (fixtureSource fixture)
                    (fixtureBuilder fixture)
                    (fixtureChannel fixture)
                    ignoreVerified
            expectMismatch "coordinator binary" outcome
    , testCase "a grant describing different sources is refused" $
        withFixture $ \fixture -> do
            -- The grant is genuinely signed; it simply claims a source digest
            -- that is not what the build context actually contains.
            tampered <- rebind fixture (\b -> b{buildSourceDigest = "deadbeef"})
            outcome <- verifyFixture fixture tampered ignoreVerified
            expectMismatch "source digest" outcome
    , testCase "sources edited after signing are refused" $
        withFixture $ \fixture -> do
            ByteString.writeFile (fixtureSource fixture </> "src" </> "Main.hs") "main = evil"
            outcome <- verifyFixture fixture (fixtureChannel fixture) ignoreVerified
            expectMismatch "source digest" outcome
    , testCase "a grant minted for another builder cannot authorize this one" $
        withFixture $ \fixture -> do
            tampered <- rebind fixture (\b -> b{buildBuilderDigest = "not-this-builder"})
            outcome <- verifyFixture fixture tampered ignoreVerified
            expectMismatch "builder binary" outcome
    , testCase "another coordinator's key does not authenticate this grant" $
        withFixture $ \fixture -> do
            otherSigningKey <- expectIO (buildSigningKeyFromBytes otherSigningSeed)
            let path = fixtureRoot fixture </> "other.pub"
            ByteString.writeFile
                path
                (buildVerificationKeyBytes (buildSigningVerificationKey otherSigningKey))
            key <- expectIO =<< installedBuildVerificationKey path
            outcome <-
                verifyBuildInvocation
                    key
                    (fixtureProject fixture)
                    (fixtureSpecDigest fixture)
                    (fixtureConfigDigest fixture)
                    (fixtureCoordinatorDigest fixture)
                    (fixtureSource fixture)
                    (fixtureBuilder fixture)
                    (fixtureChannel fixture)
                    ignoreVerified
            case outcome of
                Left (BuildSignatureInvalid _) -> pure ()
                other -> assertFailure ("expected a signature refusal, got " <> show other)
    , testCase "a coordinator refuses to sign a binding attributed to another coordinator" $
        withFixture $ \fixture -> do
            otherSigningKey <- expectIO (buildSigningKeyFromBytes otherSigningSeed)
            withBuildCoordinator otherSigningKey "some-other-coordinator" $ \other -> do
                outcome <- signBuildGrant other (channelBinding (fixtureChannel fixture))
                case outcome of
                    Left (BuildIdentityMismatch what _ _) -> what @?= "coordinator"
                    other' -> assertFailure ("expected a coordinator refusal, got " <> show other')
    , testCase "the exact hostbootstrap/build/v1 domain authenticates" $
        withFixture $ \fixture -> do
            channel <- externallySignedChannel fixture "hostbootstrap/build/v1"
            outcome <- verifyFixture fixture channel ignoreVerified
            _ <- expectIO outcome
            pure ()
    , testCase "a signature under another protocol domain is refused" $
        withFixture $ \fixture -> do
            channel <- externallySignedChannel fixture "hostbootstrap/build/v0"
            outcome <- verifyFixture fixture channel ignoreVerified
            case outcome of
                Left (BuildSignatureInvalid _) -> pure ()
                other -> assertFailure ("expected a domain-separated signature refusal, got " <> show other)
    , testCase "an existentially retained coordinator expires after its callback" $ do
        signingKey <- expectIO (buildSigningKeyFromBytes fixtureSigningSeed)
        escaped <-
            withBuildCoordinator signingKey "coordinator-digest" $
                pure . EscapedBuildCoordinator
        case escaped of
            EscapedBuildCoordinator coordinator -> do
                outcome <- signBuildGrant coordinator expiryBinding
                outcome @?= Left BuildCoordinatorExpired
    , testCase "an empty build id is refused" $
        withFixture $ \fixture -> do
            tampered <- rebind fixture (\b -> b{buildIdentifier = ""})
            outcome <- verifyFixture fixture tampered ignoreVerified
            case outcome of
                Left (BuildChannelMalformed _) -> pure ()
                other -> assertFailure ("expected a malformed refusal, got " <> show other)
    ]

expectMismatch ::
    (Show value) =>
    Text ->
    Either BuildError value ->
    IO ()
expectMismatch expected outcome = case outcome of
    Left (BuildIdentityMismatch what _ _) -> what @?= expected
    other -> assertFailure ("expected a " <> Text.unpack expected <> " mismatch, got " <> show other)

-- ---------------------------------------------------------------------------
-- Fixtures

data Fixture = Fixture
    { fixtureRoot :: FilePath
    , fixtureSource :: FilePath
    , fixtureBuilder :: FilePath
    , fixtureProject :: Text
    , fixtureSpecDigest :: Text
    , fixtureConfigDigest :: Text
    , fixtureCoordinatorDigest :: Text
    , fixtureBuilderDigest :: Text
    , fixtureKey :: BuildVerificationKey
    , fixtureChannel :: BuildChannel
    , fixtureResign :: BuildBinding -> IO BuildChannel
    }

{- | A real source tree, a real builder file, separately installed long-lived
signing/verification keys, and a genuinely signed channel describing all of
them. The verification key is derived and installed before the coordinator
bracket is created.
-}
withFixture :: (Fixture -> IO ()) -> IO ()
withFixture use =
    withSystemTempDirectory "hostbootstrap-build" $ \root -> do
        let source = root </> "context"
            builder = root </> "hostbootstrap-demo"
            signingKeyPath = root </> "coordinator.key"
            verificationKeyPath = root </> "coordinator.pub"
        writeSourceTree source
        ByteString.writeFile builder "ELF-ish builder bytes"
        ByteString.writeFile signingKeyPath fixtureSigningSeed
        sourceDigest <- expectIO =<< measureSourceDigest source
        builderDigest <- expectIO =<< measureBinaryDigest builder
        signingKey <- expectIO =<< installedBuildSigningKey signingKeyPath
        let provisionedVerificationKey = buildSigningVerificationKey signingKey
        ByteString.writeFile
            verificationKeyPath
            (buildVerificationKeyBytes provisionedVerificationKey)
        verificationKey <- expectIO =<< installedBuildVerificationKey verificationKeyPath
        let coordinatorDigest = "coordinator-digest"
            binding =
                BuildBinding
                    { buildProjectName = "hostbootstrap-demo"
                    , buildSpecDigest = "spec-1"
                    , buildConfigDigest = "config-1"
                    , buildIdentifier = "build-7"
                    , buildSourceDigest = sourceDigest
                    , buildCoordinatorDigest = coordinatorDigest
                    , buildBuilderDigest = builderDigest
                    , buildFrameName = "image-build-container-0"
                    }
        withBuildCoordinator signingKey coordinatorDigest $ \coordinator -> do
            let sign b = do
                    grant <- expectIO =<< signBuildGrant coordinator b
                    pure BuildChannel{channelBinding = b, channelGrant = grant}
            channel <- sign binding
            use
                Fixture
                    { fixtureRoot = root
                    , fixtureSource = source
                    , fixtureBuilder = builder
                    , fixtureProject = "hostbootstrap-demo"
                    , fixtureSpecDigest = "spec-1"
                    , fixtureConfigDigest = "config-1"
                    , fixtureCoordinatorDigest = coordinatorDigest
                    , fixtureBuilderDigest = builderDigest
                    , fixtureKey = verificationKey
                    , fixtureChannel = channel
                    , fixtureResign = sign
                    }

-- | Re-sign a modified binding, so the tampered case is a *genuine* signature
-- over a false description rather than a broken signature.
rebind :: Fixture -> (BuildBinding -> BuildBinding) -> IO BuildChannel
rebind fixture edit = fixtureResign fixture (edit (channelBinding (fixtureChannel fixture)))

{- | Build a channel using the fixture's provisioned seed but an independently
spelled protocol domain. This pins the public v1 signature domain rather than
merely checking that this module's signer and verifier agree with each other.
-}
externallySignedChannel :: Fixture -> ByteString -> IO BuildChannel
externallySignedChannel fixture domain = do
    secret <- case Ed25519.secretKey fixtureSigningSeed of
        CryptoFailed err -> assertFailure ("fixture signing seed was invalid: " <> show err)
        CryptoPassed value -> pure value
    let binding = channelBinding (fixtureChannel fixture)
        material = frameWire domain <> frameWire (renderBuildBinding binding)
        signature :: ByteString
        signature = convert (Ed25519.sign secret (Ed25519.toPublic secret) material)
        path = fixtureRoot fixture </> "external-channel.bin"
    ByteString.writeFile
        path
        (renderBuildBinding binding <> frameWire signature)
    expectIO =<< readBuildChannel path

data EscapedBuildCoordinator where
    EscapedBuildCoordinator :: BuildCoordinator coordinatorId -> EscapedBuildCoordinator

expiryBinding :: BuildBinding
expiryBinding =
    BuildBinding
        { buildProjectName = "hostbootstrap-demo"
        , buildSpecDigest = "spec-1"
        , buildConfigDigest = "config-1"
        , buildIdentifier = "build-expired"
        , buildSourceDigest = "source"
        , buildCoordinatorDigest = "coordinator-digest"
        , buildBuilderDigest = "builder"
        , buildFrameName = "image-build-container-0"
        }

fixtureSigningSeed :: ByteString
fixtureSigningSeed = ByteString.pack [0 .. 31]

otherSigningSeed :: ByteString
otherSigningSeed = ByteString.pack [32 .. 63]

verifyFixture ::
    Fixture ->
    BuildChannel ->
    ( forall projectId specDigest configId frame buildId sourceDigest builderBinaryDigest.
      ImageBuildFrame projectId specDigest configId frame ->
      BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest ->
      IO result
    ) ->
    IO (Either BuildError result)
verifyFixture fixture channel use =
    verifyBuildInvocation
        (fixtureKey fixture)
        (fixtureProject fixture)
        (fixtureSpecDigest fixture)
        (fixtureConfigDigest fixture)
        (fixtureCoordinatorDigest fixture)
        (fixtureSource fixture)
        (fixtureBuilder fixture)
        channel
        use

ignoreVerified ::
    ImageBuildFrame projectId specDigest configId frame ->
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest ->
    IO ()
ignoreVerified _ _ = pure ()

withSourceTree :: (FilePath -> IO ()) -> IO ()
withSourceTree use =
    withSystemTempDirectory "hostbootstrap-source" $ \root -> do
        writeSourceTree root
        use root

writeSourceTree :: FilePath -> IO ()
writeSourceTree root = do
    createDirectoryIfMissing True (root </> "src")
    ByteString.writeFile (root </> "project.cabal") "name: demo\n"
    ByteString.writeFile (root </> "src" </> "Main.hs") "main = pure ()\n"

expectIO :: (Show err) => Either err value -> IO value
expectIO (Right value) = pure value
expectIO (Left failure) = assertFailure ("expected success, got " <> show failure)
