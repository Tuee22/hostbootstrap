{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Build-invocation authority for the in-Dockerfile gate.

Every case measures real files in a real temporary tree and signs with a real
Ed25519 keypair, because the whole point of this gate is that the signed
description and the locally measured reality must agree.
-}
module BuildAuthoritySpec (tests) where

import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Build
import HostBootstrap.Handoff (ProjectVerificationKey, installedVerificationKey)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "BuildAuthoritySpec"
        [ testGroup "source measurement" measurementTests
        , testGroup "the coordinator channel" channelTests
        , testGroup "verification" verificationTests
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
            verified <- verifyFixture fixture (fixtureChannel fixture)
            (frame, authority) <- expectIO verified
            imageBuildFrameName frame @?= "image-build-container-0"
            buildAuthorityBuildId authority @?= "build-7"
            buildCommandAuthorityPhase (authorizeCheckCode frame authority) @?= CheckCodePhase
            buildCommandAuthorityPhase (authorizeBuildPhase frame authority) @?= BuildPhase
    , testCase "a grant for another project is refused" $
        withFixture $ \fixture -> do
            let tampered = rebind fixture (\b -> b{buildProjectName = "other-project"})
            outcome <- verifyFixture fixture tampered
            expectMismatch "project" outcome
    , testCase "a grant naming a different config digest is refused" $
        withFixture $ \fixture -> do
            let tampered = rebind fixture (\b -> b{buildConfigDigest = "0000"})
            outcome <- verifyFixture fixture tampered
            expectMismatch "config digest" outcome
    , testCase "a grant describing different sources is refused" $
        withFixture $ \fixture -> do
            -- The grant is genuinely signed; it simply claims a source digest
            -- that is not what the build context actually contains.
            let tampered = rebind fixture (\b -> b{buildSourceDigest = "deadbeef"})
            outcome <- verifyFixture fixture tampered
            expectMismatch "source digest" outcome
    , testCase "sources edited after signing are refused" $
        withFixture $ \fixture -> do
            ByteString.writeFile (fixtureSource fixture </> "src" </> "Main.hs") "main = evil"
            outcome <- verifyFixture fixture (fixtureChannel fixture)
            expectMismatch "source digest" outcome
    , testCase "a grant minted for another builder cannot authorize this one" $
        withFixture $ \fixture -> do
            let tampered = rebind fixture (\b -> b{buildBuilderDigest = "not-this-builder"})
            outcome <- verifyFixture fixture tampered
            expectMismatch "builder binary" outcome
    , testCase "another coordinator's key does not authenticate this grant" $
        withFixture $ \fixture ->
            withBuildCoordinator (fixtureCoordinatorDigest fixture) $ \other -> do
                let path = fixtureRoot fixture </> "other.pub"
                ByteString.writeFile path (buildCoordinatorKey other)
                loaded <- installedVerificationKey path
                key <- expectIO loaded
                outcome <-
                    verifyBuildInvocation
                        key
                        (fixtureProject fixture)
                        (fixtureConfigDigest fixture)
                        (fixtureSource fixture)
                        (fixtureBuilder fixture)
                        (fixtureChannel fixture)
                case outcome of
                    Left (BuildSignatureInvalid _) -> pure ()
                    other' -> assertFailure ("expected a signature refusal, got " <> show other')
    , testCase "a coordinator refuses to sign a binding attributed to another coordinator" $
        withFixture $ \fixture ->
            withBuildCoordinator "some-other-coordinator" $ \other ->
                case signBuildGrant other (channelBinding (fixtureChannel fixture)) of
                    Left (BuildIdentityMismatch what _ _) -> what @?= "coordinator"
                    other' -> assertFailure ("expected a coordinator refusal, got " <> show other')
    , testCase "an empty build id is refused" $
        withFixture $ \fixture -> do
            let tampered = rebind fixture (\b -> b{buildIdentifier = ""})
            outcome <- verifyFixture fixture tampered
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
    , fixtureConfigDigest :: Text
    , fixtureCoordinatorDigest :: Text
    , fixtureBuilderDigest :: Text
    , fixtureKey :: ProjectVerificationKey
    , fixtureChannel :: BuildChannel
    , fixtureResign :: BuildBinding -> BuildChannel
    }

{- | A real source tree, a real builder file, a real coordinator keypair, and a
genuinely signed channel describing all of them.
-}
withFixture :: (Fixture -> IO ()) -> IO ()
withFixture use =
    withSystemTempDirectory "hostbootstrap-build" $ \root -> do
        let source = root </> "context"
            builder = root </> "hostbootstrap-demo"
        writeSourceTree source
        ByteString.writeFile builder "ELF-ish builder bytes"
        sourceDigest <- expectIO =<< measureSourceDigest source
        builderDigest <- expectIO =<< measureBinaryDigest builder
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
        withBuildCoordinator coordinatorDigest $ \coordinator -> do
            let sign b = case signBuildGrant coordinator b of
                    Left failure -> error ("fixture could not sign: " <> show failure)
                    Right grant -> BuildChannel{channelBinding = b, channelGrant = grant}
                keyPath = root </> "project.pub"
            ByteString.writeFile keyPath (buildCoordinatorKey coordinator)
            key <- expectIO =<< installedVerificationKey keyPath
            use
                Fixture
                    { fixtureRoot = root
                    , fixtureSource = source
                    , fixtureBuilder = builder
                    , fixtureProject = "hostbootstrap-demo"
                    , fixtureConfigDigest = "config-1"
                    , fixtureCoordinatorDigest = coordinatorDigest
                    , fixtureBuilderDigest = builderDigest
                    , fixtureKey = key
                    , fixtureChannel = sign binding
                    , fixtureResign = sign
                    }

-- | Re-sign a modified binding, so the tampered case is a *genuine* signature
-- over a false description rather than a broken signature.
rebind :: Fixture -> (BuildBinding -> BuildBinding) -> BuildChannel
rebind fixture edit = fixtureResign fixture (edit (channelBinding (fixtureChannel fixture)))

verifyFixture ::
    Fixture ->
    BuildChannel ->
    IO
        ( Either
            BuildError
            (ImageBuildFrame () () () (), BuildInvocationAuthority () () () () () ())
        )
verifyFixture fixture channel =
    verifyBuildInvocation
        (fixtureKey fixture)
        (fixtureProject fixture)
        (fixtureConfigDigest fixture)
        (fixtureSource fixture)
        (fixtureBuilder fixture)
        channel

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
