{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The broker-signed runtime role activation.

A restart is modelled the way a controller actually produces one: the same pod
UID with an incremented container restart count, or a host daemon with a fresh
invocation nonce. Manifests are genuinely signed, so a refusal here is the
protocol refusing, not a broken signature.
-}
module ActivationSpec (tests) where

import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Fixture
import HostBootstrap.Activation
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Handoff (ProjectVerificationKey, installedVerificationKey)
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
        "ActivationSpec"
        [ testGroup "the manifest" manifestTests
        , testGroup "verification" verificationTests
        , testGroup "lifecycle admission" admissionTests
        ]

-- ---------------------------------------------------------------------------
-- Manifest

manifestTests :: [TestTree]
manifestTests =
    [ testCase "every bound field changes the rendering" $ do
        let variants =
                [ baseManifest{manifestScope = "Harness run-3"}
                , baseManifest{manifestPlanDigest = "plan-2"}
                , baseManifest{manifestSpecDigest = "spec-2"}
                , baseManifest{manifestBinaryDigest = "binary-2"}
                , baseManifest{manifestFrame = "daemon-4"}
                , baseManifest{manifestRevision = "rev-2"}
                , baseManifest{manifestConfigDigest = "config-2"}
                , baseManifest{manifestSecretDigest = "secret-2"}
                , baseManifest{manifestService = "other"}
                , baseManifest{manifestRolePlanDigest = "roleplan-2"}
                , baseManifest{manifestPermittedEffects = ["read"]}
                , baseManifest{manifestSecretChannel = "/elsewhere"}
                ]
            rendered = map renderActivationManifest (baseManifest : variants)
        length (dedupe rendered) @?= length rendered
    , testCase "the effect row cannot be re-read as a different row" $ do
        -- The row is framed as a whole, so splitting one entry into two cannot
        -- produce the same bytes.
        let two = baseManifest{manifestPermittedEffects = ["read", "write"]}
            joined = baseManifest{manifestPermittedEffects = ["readwrite"]}
        assertBool
            "distinct effect rows render distinctly"
            (renderActivationManifest two /= renderActivationManifest joined)
    , testCase "an unbound rollout cannot be signed" $
        withBroker $ \broker _ -> do
            case signActivationManifest broker baseManifest{manifestRevision = ""} of
                Left (ActivationManifestInvalid _) -> pure ()
                other -> assertFailure ("expected a revision refusal, got " <> show other)
            case signActivationManifest broker baseManifest{manifestService = ""} of
                Left (ActivationManifestInvalid _) -> pure ()
                other -> assertFailure ("expected a service refusal, got " <> show other)
    , testCase "the manifest carries digests, never cleartext" $ do
        -- The type has no field a secret value could occupy: the rendering of a
        -- manifest built from digests contains none of the bundle's bytes.
        let rendered = renderActivationManifest baseManifest
        assertBool
            "no cleartext leaked into the manifest"
            (not (ByteString.isInfixOf "hunter2" rendered))
    ]

dedupe :: (Eq a) => [a] -> [a]
dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- ---------------------------------------------------------------------------
-- Verification

verificationTests :: [TestTree]
verificationTests =
    [ testCase "a genuine activation verifies and exposes its bound package" $
        withSigned $ \key grant -> do
            activation <- expectRight (verify key "rev-1" baseManifest grant baseMeasurement)
            activationRevision activation @?= "rev-1"
            activationService activation @?= "accelerator"
            activationPermittedEffects activation @?= ["durable-write", "service-port"]
            activationSecretChannel activation @?= "/var/run/secrets/hostbootstrap/bundle"
            activationInstance activation @?= measuredInstance baseMeasurement
    , testCase "a changed ConfigMap hash refuses" $
        withSigned $ \key grant -> do
            let changed = baseMeasurement{measuredConfigDigest = "config-tampered"}
            expectMismatch "config" (verify key "rev-1" baseManifest grant changed)
    , testCase "a changed Secret hash refuses" $
        withSigned $ \key grant -> do
            let changed = baseMeasurement{measuredSecretDigest = "secret-tampered"}
            expectMismatch "secret" (verify key "rev-1" baseManifest grant changed)
    , testCase "a different binary refuses, so a cross-binary replay fails" $
        withSigned $ \key grant -> do
            let changed = baseMeasurement{measuredBinaryDigest = "binary-other"}
            expectMismatch "binary" (verify key "rev-1" baseManifest grant changed)
    , testCase "a manifest for a superseded revision refuses" $
        withSigned $ \key grant ->
            case verify key "rev-2" baseManifest grant baseMeasurement of
                Left (ActivationRevisionStale signed expected) -> do
                    signed @?= "rev-1"
                    expected @?= "rev-2"
                other -> assertFailure ("expected a stale-revision refusal, got " <> show other)
    , testCase "another project's key does not authenticate this manifest" $
        withSigned $ \_ grant ->
            withBroker $ \_ otherKey ->
                case verify otherKey "rev-1" baseManifest grant baseMeasurement of
                    Left (ActivationSignatureInvalid _) -> pure ()
                    other -> assertFailure ("expected a signature refusal, got " <> show other)
    , testCase "a manifest edited after signing refuses" $
        withSigned $ \key grant -> do
            let edited = baseManifest{manifestPermittedEffects = ["durable-write", "service-port", "root"]}
            case verify key "rev-1" edited grant baseMeasurement of
                Left (ActivationSignatureInvalid _) -> pure ()
                other -> assertFailure ("expected a signature refusal, got " <> show other)
    , testCase "a restart is a different instance, so a retained activation is not it" $
        withSigned $ \key grant -> do
            first <- expectRight (verify key "rev-1" baseManifest grant baseMeasurement)
            let restarted =
                    baseMeasurement
                        { measuredInstance = KubernetesInstance "pod-uid-1" 1
                        }
            second <- expectRight (verify key "rev-1" baseManifest grant restarted)
            -- Same signed manifest, but the measured instance is bound into the
            -- result, so the two activations are not interchangeable.
            assertBool
                "the two instances differ"
                (activationInstance first /= activationInstance second)
            instanceIdentityText (activationInstance first) @?= "pod:pod-uid-1/0"
            instanceIdentityText (activationInstance second) @?= "pod:pod-uid-1/1"
    , testCase "a host daemon's invocation nonce is its instance identity" $
        withSigned $ \key grant -> do
            let hostRun = baseMeasurement{measuredInstance = HostServiceInstance "nonce-9"}
            activation <- expectRight (verify key "rev-1" baseManifest grant hostRun)
            instanceIdentityText (activationInstance activation) @?= "host:nonce-9"
    ]

expectMismatch ::
    (Show value) =>
    Text ->
    Either ActivationError value ->
    IO ()
expectMismatch expected outcome = case outcome of
    Left (ActivationMeasurementMismatch what _ _) -> what @?= expected
    other -> assertFailure ("expected a " <> Text.unpack expected <> " mismatch, got " <> show other)

-- ---------------------------------------------------------------------------
-- Admission

admissionTests :: [TestTree]
admissionTests =
    [ testCase "an instance reserves its admission exactly once" $
        withStore $ \store ->
            withSigned $ \key grant -> do
                activation <- expectRight (verify key "rev-1" baseManifest grant baseMeasurement)
                first <- inEntry store (\s -> reserveLifecycleAdmission s activation)
                admission <- expectRight first
                assertBool "the key names the instance" ("pod" `Text.isInfixOf` lifecycleAdmissionKey admission)
                -- A duplicated activation cannot open a second admission.
                second <- inEntry store (\s -> reserveLifecycleAdmission s activation)
                case second of
                    Left (ActivationAdmissionConsumed _) -> pure ()
                    other -> assertFailure ("expected a consumed admission, got " <> show other)
    , testCase "a genuine restart gets its own admission" $
        withStore $ \store ->
            withSigned $ \key grant -> do
                original <- expectRight (verify key "rev-1" baseManifest grant baseMeasurement)
                restarted <-
                    expectRight
                        ( verify
                            key
                            "rev-1"
                            baseManifest
                            grant
                            baseMeasurement{measuredInstance = KubernetesInstance "pod-uid-1" 1}
                        )
                _ <- expectRight =<< inEntry store (\s -> reserveLifecycleAdmission s original)
                second <- inEntry store (\s -> reserveLifecycleAdmission s restarted)
                admission <- expectRight second
                assertBool
                    "the restart reserved a different key"
                    (Text.isSuffixOf "1" (lifecycleAdmissionKey admission))
    ]

-- ---------------------------------------------------------------------------
-- Fixtures

baseManifest :: ActivationManifest
baseManifest =
    ActivationManifest
        { manifestScope = "Production"
        , manifestPlanDigest = "plan-1"
        , manifestSpecDigest = "spec-1"
        , manifestBinaryDigest = "binary-1"
        , manifestFrame = "daemon-3"
        , manifestRevision = "rev-1"
        , manifestConfigDigest = "config-1"
        , manifestSecretDigest = "secret-1"
        , manifestService = "accelerator"
        , manifestRolePlanDigest = "roleplan-1"
        , manifestPermittedEffects = ["durable-write", "service-port"]
        , manifestSecretChannel = "/var/run/secrets/hostbootstrap/bundle"
        }

baseMeasurement :: RuntimeMeasurement
baseMeasurement =
    RuntimeMeasurement
        { measuredBinaryDigest = "binary-1"
        , measuredConfigDigest = "config-1"
        , measuredSecretDigest = "secret-1"
        , measuredInstance = KubernetesInstance "pod-uid-1" 0
        }

verify ::
    ProjectVerificationKey ->
    Text ->
    ActivationManifest ->
    ActivationGrant ->
    RuntimeMeasurement ->
    Either ActivationError (VerifiedRuntimeRoleActivation () () () () () () ())
verify = verifyRuntimeRoleActivation

-- | A real root invocation, a real activation broker, and its installed key.
withBroker ::
    ( forall scope brokerGeneration verb.
      ActivationBroker scope brokerGeneration verb ->
      ProjectVerificationKey ->
      IO ()
    ) ->
    IO ()
withBroker use =
    withSystemTempDirectory "hostbootstrap-activation" $ \directory -> do
        opened <- openProtectedStore (directory </> "authority")
        case opened of
            Left failure -> assertFailure (show failure)
            Right store -> do
                outcome <- withAuthorityEntry store $ \session -> do
                    operator <- Authority.verifyOperatorAuthorization session
                    case operator of
                        Left failure -> pure (Left failure)
                        Right authorized ->
                            withFixtureProject $ \project ->
                                Authority.withFreshBrokerEpoch session project $ \epoch ->
                                    Authority.withVerifiedRootInvocation
                                        session
                                        project
                                        authorized
                                        epoch
                                        Authority.ProjectUp
                                        ( \root ->
                                            Right <$> withActivationBroker root (installAndUse directory)
                                        )
                either (assertFailure . show) pure outcome
  where
    installAndUse directory broker = do
        let path = directory </> "project.pub"
        ByteString.writeFile path (activationBrokerKey broker)
        loaded <- installedVerificationKey path
        case loaded of
            Left failure -> assertFailure (show failure)
            Right key -> use broker key

withAuthorityEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either Authority.AuthorityError result)) ->
    IO (Either Authority.AuthorityError result)
withAuthorityEntry store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    pure (either (Left . Authority.AuthorityStoreFailure) id outcome)

withFixtureProject ::
    (Authority.InstalledProject Fixture.FixtureProject -> IO result) ->
    IO result
withFixtureProject use =
    case Authority.installedProjectFor @Fixture.FixtureProject @Fixture.ProjectConfig "hostbootstrap-demo" of
        Left failure -> assertFailure (show failure)
        Right project -> use project

-- | A signed 'baseManifest' plus the key that verifies it.
withSigned :: (ProjectVerificationKey -> ActivationGrant -> IO ()) -> IO ()
withSigned use =
    withBroker $ \broker key ->
        case signActivationManifest broker baseManifest of
            Left failure -> assertFailure (show failure)
            Right grant -> use key grant

withStore :: (ProtectedStore -> IO ()) -> IO ()
withStore use =
    withSystemTempDirectory "hostbootstrap-admission" $ \directory -> do
        opened <- openProtectedStore (directory </> "authority")
        case opened of
            Left failure -> assertFailure (show failure)
            Right store -> use store

inEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either ActivationError result)) ->
    IO (Either ActivationError result)
inEntry store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    pure (either (Left . ActivationStoreFailure) id outcome)

expectRight :: (Show err) => Either err value -> IO value
expectRight (Right value) = pure value
expectRight (Left failure) = assertFailure ("expected success, got " <> show failure)
