{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

{- | The broker-signed runtime role activation.

A restart is modelled the way a controller actually produces one: the same pod
UID with an incremented container restart count, or a host daemon with a fresh
invocation nonce. Manifests are genuinely signed, so a refusal here is the
protocol refusing, not a broken signature.
-}
module ActivationSpec (tests, withBrokerFor) where

import Control.Monad (forM_, when)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import qualified Crypto.Hash as Hash
import qualified Crypto.PubKey.Ed25519 as Ed25519
import Data.ByteArray (convert)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Dhall
import Expect (expectRight)
import qualified Fixture
import HostBootstrap.Activation
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Config.Class (ProjectCfg (cfgContext), projectCodecSpecDigest, withProductionProjectCodec)
import HostBootstrap.Config.Fields (ScopeKind (ProductionScope), inspectLocalContext, localCurrentFrame, renderValidatedServiceRequest)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Handoff (frameWire, takeHandoffFrame)
import HostBootstrap.Lifecycle.Mode (productionRootAuthority, withProductionRoot)
import HostBootstrap.Protected (
    ProtectedStore,
    openProtectedStore,
    tryProtectedEntry,
 )
import HostBootstrap.RoleLifecycle (
    DeclaredEffects (NoEffects, WithEffect),
    EffectName (NetworkListenName),
    RoleAcquireOutcome (Acquired),
    RolePrereqOutcome (PrereqSatisfied),
    RoleProbeOutcome (ProbeReadyNow),
    RoleReleaseOutcome (Released),
    mkRoleResourceRequest,
    roleExitReportOk,
    rolePlanDraft,
    rolePlanDraftDigest,
 )
import HostBootstrap.Service (
    ServiceActivationError (..),
    ServiceResourceBackend (..),
    installServiceActivationRevision,
    runInstalledServiceProgram,
    serviceActivationErrorMessage,
    serviceActivationRevisionPath,
    serviceId,
    serviceProgramDefinition,
    singletonServiceRegistry,
    withFinalizedServiceRegistry,
    withInstalledServiceActivation,
    withSelectedServiceProgram,
 )
import HostBootstrap.Service.Program (
    ServiceBackend (..),
    ServicePayloads (..),
    lookupAcquiredResource,
    serve,
    withReadyServiceHandles,
 )
import qualified SourceGuard
import System.Directory (createDirectory, createDirectoryIfMissing, removeFile)
import System.Environment (getExecutablePath)
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
        , testGroup "installed revision" installedRevisionTests
        , testGroup "checked manifest input" checkedManifestInputTests
        , testGroup "sealed manifest admission" sealedManifestTests
        , testGroup "checked measured instances" measuredInstanceTests
        ]

-- ---------------------------------------------------------------------------
-- Manifest

manifestTests :: [TestTree]
manifestTests =
    [ testCase "every bound field changes the rendering" $ withBaseManifest $ \baseManifest -> do
        let variantInputs =
                [ checkedManifestInput{manifestInputScope = "Harness run-3"}
                , checkedManifestInput{manifestInputPlanDigest = "plan-2"}
                , checkedManifestInput{manifestInputSpecDigest = "spec-2"}
                , checkedManifestInput{manifestInputBinaryDigest = "binary-2"}
                , checkedManifestInput{manifestInputFrame = "daemon-4"}
                , checkedManifestInput{manifestInputRevision = "rev-2"}
                , checkedManifestInput{manifestInputConfigDigest = "config-2"}
                , checkedManifestInput{manifestInputSecretDigest = alternateSecretDigest}
                , checkedManifestInput{manifestInputService = "other"}
                , checkedManifestInput{manifestInputRolePlanDigest = "roleplan-2"}
                , checkedManifestInput{manifestInputPermittedEffects = ["read"]}
                , checkedManifestInput{manifestInputSecretChannel = "/elsewhere"}
                ]
        variants <- traverse (expectRight . activationManifest) variantInputs
        let rendered = map renderActivationManifest (baseManifest : variants)
        length (dedupe rendered) @?= length rendered
    , testCase "the effect row cannot be re-read as a different row" $ do
        -- The row is framed as a whole, so splitting one entry into two cannot
        -- produce the same bytes.
        two <- expectRight (activationManifest checkedManifestInput{manifestInputPermittedEffects = ["read", "write"]})
        joined <- expectRight (activationManifest checkedManifestInput{manifestInputPermittedEffects = ["readwrite"]})
        commaJoined <- expectRight (activationManifest checkedManifestInput{manifestInputPermittedEffects = ["read,write"]})
        assertBool
            "distinct effect rows render distinctly"
            (renderActivationManifest two /= renderActivationManifest joined)
        assertBool
            "a comma inside one identity cannot become two identities"
            (renderActivationManifest two /= renderActivationManifest commaJoined)
    , testCase "the manifest and private-bundle digests match independent literal vectors" $ withBaseManifest $ \baseManifest -> do
        renderActivationManifest baseManifest @?= literalActivationManifest
        digestBytes (renderActivationManifest baseManifest)
            @?= "22bfd7a1531c8d361ab705b72ee47fd6f803d2d01837af99f2b4287496dae78c"
        activationSecretDigestText baseSecretDigest
            @?= "f1bed3729e696205449afb907fcb46d94006b00e6eab4076d4c1370febd91a1b"
        activationSecretDigestText baseSecretDigest @?= digestBytes baseSecretBundle
    , testCase "the signing policy refuses empty and duplicate validated members exactly" $ withBaseManifest $ \baseManifest -> do
        (() <$ activationSigningPolicy [baseManifest]) @?= Right ()
        forM_
            [ ([], "the signing policy is empty")
            , ([baseManifest, baseManifest], "the signing policy contains a duplicate manifest")
            ] $ \(manifests, detail) ->
                (() <$ activationSigningPolicy manifests) @?= Left (ActivationManifestInvalid detail)
    , testCase "empty rollout and service inputs cannot become signable manifests" $ do
        activationManifest checkedManifestInput{manifestInputRevision = ""}
            @?= Left (ActivationManifestInvalid "the rollout revision is empty")
        activationManifest checkedManifestInput{manifestInputService = ""}
            @?= Left (ActivationManifestInvalid "the service identity is empty")
    , testCase "the root signs only exact manifests in its closed policy" $ withBaseManifest $ \baseManifest ->
        withBroker $ \broker _ _ -> do
            _ <- expectRight =<< signActivationManifest broker baseManifest
            let variantInputs =
                    [ checkedManifestInput{manifestInputScope = "Harness run-3"}
                    , checkedManifestInput{manifestInputPlanDigest = "plan-2"}
                    , checkedManifestInput{manifestInputSpecDigest = "spec-2"}
                    , checkedManifestInput{manifestInputBinaryDigest = "binary-2"}
                    , checkedManifestInput{manifestInputFrame = "daemon-4"}
                    , checkedManifestInput{manifestInputRevision = "rev-2"}
                    , checkedManifestInput{manifestInputConfigDigest = "config-2"}
                    , checkedManifestInput{manifestInputSecretDigest = alternateSecretDigest}
                    , checkedManifestInput{manifestInputService = "other"}
                    , checkedManifestInput{manifestInputRolePlanDigest = "roleplan-2"}
                    , checkedManifestInput{manifestInputPermittedEffects = ["read"]}
                    , checkedManifestInput{manifestInputSecretChannel = "/elsewhere"}
                    ]
            variants <- traverse (expectRight . activationManifest) variantInputs
            mapM_
                ( \manifest -> do
                    signed <- signActivationManifest broker manifest
                    case signed of
                        Left ActivationManifestNotAdmitted -> pure ()
                        other -> assertFailure ("expected an exact-policy refusal, got " <> show other)
                )
                variants
    , testCase "the private bundle is serialized only through its computed canonical digest" $ withBaseManifest $ \baseManifest -> do
        let rendered = renderActivationManifest baseManifest
        assertBool
            "the private bundle bytes are absent"
            (not (ByteString.isInfixOf baseSecretBundle rendered))
        decoded <- expectRight (activationManifestFromWire rendered)
        decoded @?= baseManifest
        Text.length (activationSecretDigestText (manifestSecretDigest decoded)) @?= 64
    , testCase "the wire decoder refuses cleartext and non-canonical secret digests" $ withBaseManifest $ \baseManifest -> do
        manifestWireWithSecretDigest (activationSecretDigestText baseSecretDigest) baseManifest
            @?= renderActivationManifest baseManifest
        forM_
            [ "hunter2", Text.replicate 64 "A", ""
            , Text.replicate 63 "a", Text.replicate 65 "a", Text.replicate 64 "g"
            ] $ \invalid ->
                activationManifestFromWire (manifestWireWithSecretDigest invalid baseManifest)
                    @?= Left (ActivationManifestInvalid "the secret digest is not canonical lower-case SHA-256 hex")
    , testCase "the wire decoder refuses a malformed UTF-8 field" $ withBaseManifest $ \baseManifest -> do
        let rendered = renderActivationManifest baseManifest
            encodedScope = frameWire (TextEncoding.encodeUtf8 (manifestScope baseManifest))
            malformed =
                frameWire (ByteString.singleton 0xff)
                    <> ByteString.drop (ByteString.length encodedScope) rendered
        case activationManifestFromWire malformed of
            Left (ActivationManifestInvalid detail) ->
                assertBool "the refusal names UTF-8" ("UTF-8" `Text.isInfixOf` detail)
            other -> assertFailure ("expected a malformed-wire refusal, got " <> show other)
    , testCase "the wire decoder refuses a truncated final field" $ withBaseManifest $ \baseManifest -> do
        let truncated = ByteString.init (renderActivationManifest baseManifest)
        case activationManifestFromWire truncated of
            Left (ActivationManifestInvalid detail) ->
                assertBool "the refusal names truncation" ("truncated" `Text.isInfixOf` detail)
            other -> assertFailure ("expected a truncated-wire refusal, got " <> show other)
    , testCase "the wire decoder refuses trailing bytes" $ withBaseManifest $ \baseManifest -> do
        let trailing = renderActivationManifest baseManifest <> "trailing"
        case activationManifestFromWire trailing of
            Left (ActivationManifestInvalid detail) ->
                assertBool "the refusal names trailing bytes" ("trailing" `Text.isInfixOf` detail)
            other -> assertFailure ("expected a trailing-wire refusal, got " <> show other)
    ]

dedupe :: (Eq a) => [a] -> [a]
dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- ---------------------------------------------------------------------------
-- Verification

verificationTests :: [TestTree]
verificationTests =
    [ testCase "invalid activation signing-key bytes are refused" $
        case activationSigningKeyFromBytes (ByteString.replicate 31 7) of
            Left (ActivationSigningKeyInvalid _) -> pure ()
            other -> assertFailure ("expected an invalid-signing-key refusal, got " <> show other)
    , testCase "invalid activation verification-key bytes are refused" $
        case activationVerificationKeyFromBytes (ByteString.replicate 31 7) of
            Left (ActivationVerificationKeyInvalid _) -> pure ()
            other -> assertFailure ("expected an invalid-verification-key refusal, got " <> show other)
    , testCase "the independently provisioned verifier is selected before broker construction" $ withBaseMeasurement $ \baseMeasurement -> withBaseManifest $ \baseManifest ->
        withProvisionedActivationIdentity 41 $ \signing verifier -> do
            restored <-
                expectRight
                    ( activationVerificationKeyFromBytes
                        (activationVerificationKeyBytes verifier)
                    )
            restored @?= verifier
            withBrokerForIdentity signing verifier [baseManifest] $ \broker store installed -> do
                grant <- expectRight =<< signActivationManifest broker baseManifest
                outcome <- verify installed store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant baseMeasurement ignoreActivation
                _ <- expectRight outcome
                pure ()
    , testCase "a genuine activation verifies and exposes its bound package" $ withBaseMeasurement $ \baseMeasurement -> withBaseManifest $ \baseManifest ->
        withSigned $ \store key grant -> do
            outcome <-
                verify key store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant baseMeasurement $ \activation -> do
                    activationRevision activation @?= "rev-1"
                    activationService activation @?= "accelerator"
                    activationPermittedEffects activation @?= ["durable-write", "service-port"]
                    activationSecretChannel activation @?= "/var/run/secrets/hostbootstrap/bundle"
                    activationInstance activation @?= measuredInstance baseMeasurement
                    activationPlanDigest activation @?= manifestPlanDigest baseManifest
                    activationSpecDigest activation @?= manifestSpecDigest baseManifest
                    activationFrame activation @?= manifestFrame baseManifest
                    activationConfigDigest activation @?= manifestConfigDigest baseManifest
                    activationSecretDigest activation @?= activationSecretDigestText (manifestSecretDigest baseManifest)
                    activationRolePlanDigest activation @?= manifestRolePlanDigest baseManifest
            _ <- expectRight outcome
            pure ()
    , testCase "every manifest requirement is refused by checked input and raw wire admission" $ do
        length invalidManifestCases @?= 12
        forM_ invalidManifestCases $ \(label, input, index, field, detail) -> do
            assertBool (label <> ": checked input refusal")
                (activationManifest input == Left (ActivationManifestInvalid detail))
            raw <- replaceManifestWireFields literalActivationManifest [(index, field)]
            assertBool (label <> ": raw wire admission refusal")
                (activationManifestFromWire raw == Left (ActivationManifestInvalid detail))
    , testCase "installed admission checks the complete selected manifest before the received manifest" $ withPodInstance $ \podInstance -> do
        withInstallFixture $ \broker store key root manifest -> do
            revision <- expectInstall =<< installServiceActivationRevision broker key root manifest installedRoleWire baseSecretBundle
            let directory = serviceActivationRevisionPath revision
                original = renderActivationManifest manifest
            acceptedCalls <- newIORef (0 :: Int)
            accepted <- withInstalledServiceActivation store key revision "binary-1" podInstance
                (\_ _ _ -> modifyIORef' acceptedCalls (+ 1))
            _ <- expectInstall accepted
            readIORef acceptedCalls >>= (@?= 1)
            emptySelected <- replaceManifestWireFields original [(8, "")]
            emptyReceived <- replaceManifestWireFields original [(5, "")]
            malformedSelected <- replaceManifestWireFields original [(0, ByteString.singleton 255)]
            forM_
                [ (emptySelected, ByteString.init original, "the service identity is empty")
                , (malformedSelected, emptyReceived, "a manifest field is not valid UTF-8")
                , (original, emptyReceived, "the rollout revision is empty")
                , (original, ByteString.init original, "the manifest wire is truncated")
                ] $ \(selectedWire, receivedWire, detail) -> do
                    ByteString.writeFile (directory </> "expected.manifest") selectedWire
                    ByteString.writeFile (directory </> "received.manifest") receivedWire
                    calls <- newIORef (0 :: Int)
                    refused <- withInstalledServiceActivation store key revision "wrong-binary" podInstance
                        (\_ _ _ -> modifyIORef' calls (+ 1))
                    case refused of
                        Left (ServiceActivationVerification failure) -> failure @?= ActivationManifestInvalid detail
                        other -> assertFailure ("expected exact manifest admission refusal, got " <> show other)
                    readIORef calls >>= (@?= 0)
            ByteString.writeFile (directory </> "expected.manifest") original
            ByteString.writeFile (directory </> "received.manifest") original
            calls <- newIORef (0 :: Int)
            refused <- withInstalledServiceActivation store key revision "wrong-binary" podInstance
                (\_ _ _ -> modifyIORef' calls (+ 1))
            case refused of
                Left (ServiceActivationVerification failure) ->
                    failure @?= ActivationMeasurementMismatch "binary" "binary-1" "wrong-binary"
                other -> assertFailure ("expected the later binary measurement refusal, got " <> show other)
            readIORef calls >>= (@?= 0)
    , testCase "empty and 63-byte adopted grants reach exact parser refusals" $ withBaseMeasurement $ \baseMeasurement -> withBaseManifest $ \baseManifest ->
        withSigned $ \store key grant -> do
            acceptedCalls <- newIORef (0 :: Int)
            accepted <- verify key store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant baseMeasurement
                (\_ -> modifyIORef' acceptedCalls (+ 1))
            accepted @?= Right ()
            readIORef acceptedCalls >>= (@?= 1)
            let original = activationGrantSignature grant
            ByteString.length original @?= 64
            forM_ [ByteString.empty, ByteString.take 63 original] $ \signature -> do
                calls <- newIORef (0 :: Int)
                refused <- verify key store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest)
                    (adoptRelayedActivationGrant signature) baseMeasurement
                    (\_ -> modifyIORef' calls (+ 1))
                refused @?= Left (ActivationSignatureInvalid "CryptoError_SecretKeyStructureInvalid")
                readIORef calls >>= (@?= 0)
    , testCase "a changed ConfigMap hash refuses" $ withBaseMeasurement $ \baseMeasurement -> withBaseManifest $ \baseManifest ->
        withSigned $ \store key grant -> do
            let changed = baseMeasurement{measuredConfigDigest = "config-tampered"}
            outcome <- verify key store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant changed ignoreActivation
            expectMismatch "config" outcome
    , testCase "a changed Secret hash refuses" $ withBaseMeasurement $ \baseMeasurement -> withBaseManifest $ \baseManifest ->
        withSigned $ \store key grant -> do
            let changed = baseMeasurement{measuredSecretDigest = alternateSecretDigest}
            outcome <- verify key store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant changed ignoreActivation
            expectMismatch "secret" outcome
    , testCase "a different binary refuses, so a cross-binary replay fails" $ withBaseMeasurement $ \baseMeasurement -> withBaseManifest $ \baseManifest ->
        withSigned $ \store key grant -> do
            let changed = baseMeasurement{measuredBinaryDigest = "binary-other"}
            outcome <- verify key store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant changed ignoreActivation
            expectMismatch "binary" outcome
    , testCase "a manifest for a superseded revision refuses" $ withBaseMeasurement $ \baseMeasurement -> withBaseManifest $ \baseManifest ->
        withSigned $ \store key grant -> do
            expected <- expectRight (activationManifest checkedManifestInput{manifestInputRevision = "rev-2"})
            outcome <- verify key store (selectedActivationManifest expected) (receivedActivationManifest baseManifest) grant baseMeasurement ignoreActivation
            case outcome of
                Left (ActivationRevisionStale signed expectedRevision) -> do
                    signed @?= "rev-1"
                    expectedRevision @?= "rev-2"
                other -> assertFailure ("expected a stale-revision refusal, got " <> show other)
    , testCase "another admitted manifest cannot replace the exact selected workload" $ withBaseMeasurement $ \baseMeasurement -> do
        length exactSelectionCases @?= 11
        forM_ exactSelectionCases $ \(fieldName, selectedInput, signedInput, signedValue, selectedValue) -> do
            selected <- expectRight (activationManifest selectedInput)
            signed <- expectRight (activationManifest signedInput)
            withBrokerFor [selected, signed] $ \broker store key -> do
                grant <- expectRight =<< signActivationManifest broker signed
                let measurement = baseMeasurement
                        { measuredBinaryDigest = manifestBinaryDigest signed
                        , measuredConfigDigest = manifestConfigDigest signed
                        , measuredSecretDigest = manifestSecretDigest signed
                        }
                acceptedCalls <- newIORef (0 :: Int)
                accepted <- verify key store (selectedActivationManifest signed) (receivedActivationManifest signed) grant measurement
                    (\_ -> modifyIORef' acceptedCalls (+ 1))
                accepted @?= Right ()
                readIORef acceptedCalls >>= (@?= 1)
                calls <- newIORef (0 :: Int)
                refused <- verify key store (selectedActivationManifest selected) (receivedActivationManifest signed) grant measurement
                    (\_ -> modifyIORef' calls (+ 1))
                refused @?= Left (ActivationManifestMismatch fieldName signedValue selectedValue)
                readIORef calls >>= (@?= 0)
    , testCase "another independently provisioned activation key does not authenticate this manifest" $ withBaseMeasurement $ \baseMeasurement -> withBaseManifest $ \baseManifest ->
        withSigned $ \store _ grant ->
            withBrokerSeed 42 $ \_ _ otherKey -> do
                outcome <- verify otherKey store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant baseMeasurement ignoreActivation
                case outcome of
                    Left (ActivationSignatureInvalid _) -> pure ()
                    other -> assertFailure ("expected a signature refusal, got " <> show other)
    , testCase "an independently produced activation/v1 signature verifies" $ withBaseMeasurement $ \baseMeasurement -> withBaseManifest $ \baseManifest ->
        withStore $ \store -> do
            (key, grant) <- externallySignedGrant "hostbootstrap/activation/v1"
            outcome <- verify key store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant baseMeasurement ignoreActivation
            _ <- expectRight outcome
            pure ()
    , testCase "the same manifest signed under another domain is refused" $ withBaseMeasurement $ \baseMeasurement -> withBaseManifest $ \baseManifest ->
        withStore $ \store -> do
            (key, grant) <- externallySignedGrant "hostbootstrap/activation/v0"
            outcome <- verify key store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant baseMeasurement ignoreActivation
            case outcome of
                Left (ActivationSignatureInvalid _) -> pure ()
                other -> assertFailure ("expected a cross-domain signature refusal, got " <> show other)
    , testCase "a manifest edited after signing refuses" $ withBaseMeasurement $ \baseMeasurement ->
        withSigned $ \store key grant -> do
            edited <- expectRight (activationManifest checkedManifestInput{manifestInputPermittedEffects = ["durable-write", "service-port", "root"]})
            outcome <- verify key store (selectedActivationManifest edited) (receivedActivationManifest edited) grant baseMeasurement ignoreActivation
            case outcome of
                Left (ActivationSignatureInvalid _) -> pure ()
                other -> assertFailure ("expected a signature refusal, got " <> show other)
    , testCase "a restart is a different instance, so a retained activation is not it" $ withBaseMeasurement $ \baseMeasurement -> withBaseManifest $ \baseManifest ->
        withSigned $ \store key grant -> do
            restartedInstance <- expectRight (kubernetesInstance "pod-uid-1" 1)
            let restarted =
                    baseMeasurement
                        { measuredInstance = restartedInstance
                        }
            first <-
                verify key store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant baseMeasurement $ \activation ->
                    pure (activationInstance activation)
            second <-
                verify key store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant restarted $ \activation ->
                    pure (activationInstance activation)
            firstInstance <- expectRight first
            secondInstance <- expectRight second
            assertBool "the two instances differ" (firstInstance /= secondInstance)
            instanceIdentityText firstInstance @?= "pod:pod-uid-1/0"
            instanceIdentityText secondInstance @?= "pod:pod-uid-1/1"
    , testCase "restart count zero is a valid measured instance" $ withBaseMeasurement $ \baseMeasurement -> withPodInstance $ \podInstance -> withBaseManifest $ \baseManifest ->
        withSigned $ \store key grant -> do
            let firstStart = baseMeasurement{measuredInstance = podInstance}
            outcome <- verify key store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant firstStart ignoreActivation
            _ <- expectRight outcome
            pure ()
    , testCase "an empty Kubernetes pod UID is refused" $ do
        kubernetesInstance "" 0
            @?= Left (ActivationInstanceInvalid "the measured Kubernetes pod UID is empty")
    , testCase "an empty host invocation nonce is refused" $ do
        hostServiceInstance ""
            @?= Left (ActivationInstanceInvalid "the measured host invocation nonce is empty")
    , testCase "a host daemon's invocation nonce is its instance identity" $ withBaseMeasurement $ \baseMeasurement -> withBaseManifest $ \baseManifest ->
        withSigned $ \store key grant -> do
            hostInstance <- expectRight (hostServiceInstance "nonce-9")
            let hostRun = baseMeasurement{measuredInstance = hostInstance}
            outcome <-
                verify key store (selectedActivationManifest baseManifest) (receivedActivationManifest baseManifest) grant hostRun $ \activation ->
                    instanceIdentityText (activationInstance activation) @?= "host:nonce-9"
            _ <- expectRight outcome
            pure ()
    , testCase "an escaped broker refuses after its active bracket closes" $ withBaseManifest $ \baseManifest -> do
        escaped <- newIORef Nothing
        withBroker $ \broker _ _ ->
            writeIORef escaped (Just (SomeActivationBroker broker))
        retained <- readIORef escaped
        case retained of
            Nothing -> assertFailure "the fixture did not retain the broker"
            Just (SomeActivationBroker broker) -> do
                outcome <- signActivationManifest broker baseManifest
                outcome @?= Left ActivationBrokerExpired
    ]

invalidManifestCases :: [(String, ActivationManifestInput, Int, ByteString.ByteString, Text)]
invalidManifestCases =
    [ ("scope", checkedManifestInput{manifestInputScope = ""}, 0, "", "the scope is empty")
    , ("plan", checkedManifestInput{manifestInputPlanDigest = ""}, 1, "", "the plan digest is empty")
    , ("spec", checkedManifestInput{manifestInputSpecDigest = ""}, 2, "", "the spec digest is empty")
    , ("binary", checkedManifestInput{manifestInputBinaryDigest = ""}, 3, "", "the binary digest is empty")
    , ("frame", checkedManifestInput{manifestInputFrame = ""}, 4, "", "the frame is empty")
    , ("revision", checkedManifestInput{manifestInputRevision = ""}, 5, "", "the rollout revision is empty")
    , ("config", checkedManifestInput{manifestInputConfigDigest = ""}, 6, "", "the config digest is empty")
    , ("service", checkedManifestInput{manifestInputService = ""}, 8, "", "the service identity is empty")
    , ("role plan", checkedManifestInput{manifestInputRolePlanDigest = ""}, 9, "", "the role-plan digest is empty")
    , ("secret channel", checkedManifestInput{manifestInputSecretChannel = ""}, 11, "", "the secret channel is empty")
    , ("empty effect", checkedManifestInput{manifestInputPermittedEffects = [""]}, 10, frameWire "", "an effect identity is empty")
    , ("duplicate effect", checkedManifestInput{manifestInputPermittedEffects = ["read", "read"]}, 10, frameWire "read" <> frameWire "read", "the effect row contains a duplicate identity")
    ]

exactSelectionCases :: [(Text, ActivationManifestInput, ActivationManifestInput, Text, Text)]
exactSelectionCases =
    [ ("scope", checkedManifestInput, checkedManifestInput{manifestInputScope = "Harness run-3"}, "Harness run-3", "Production")
    , ("plan digest", checkedManifestInput, checkedManifestInput{manifestInputPlanDigest = "plan-2"}, "plan-2", "plan-1")
    , ("spec digest", checkedManifestInput, checkedManifestInput{manifestInputSpecDigest = "spec-2"}, "spec-2", "spec-1")
    , ("binary digest", checkedManifestInput, checkedManifestInput{manifestInputBinaryDigest = "binary-2"}, "binary-2", "binary-1")
    , ("frame", checkedManifestInput, checkedManifestInput{manifestInputFrame = "daemon-4"}, "daemon-4", "daemon-3")
    , ("config digest", checkedManifestInput, checkedManifestInput{manifestInputConfigDigest = "config-2"}, "config-2", "config-1")
    , ("secret digest", checkedManifestInput, checkedManifestInput{manifestInputSecretDigest = alternateSecretDigest},
        activationSecretDigestText alternateSecretDigest, activationSecretDigestText baseSecretDigest)
    , ("service", checkedManifestInput, checkedManifestInput{manifestInputService = "other"}, "other", "accelerator")
    , ("role-plan digest", checkedManifestInput, checkedManifestInput{manifestInputRolePlanDigest = "roleplan-2"}, "roleplan-2", "roleplan-1")
    , ("permitted effects", checkedManifestInput{manifestInputPermittedEffects = ["read,write"]},
        checkedManifestInput{manifestInputPermittedEffects = ["read", "write"]}, "[\"read\",\"write\"]", "[\"read,write\"]")
    , ("secret channel", checkedManifestInput, checkedManifestInput{manifestInputSecretChannel = "/elsewhere"},
        "/elsewhere", "/var/run/secrets/hostbootstrap/bundle")
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
-- Fixtures

baseSecretBundle :: ByteString.ByteString
baseSecretBundle = "user=accelerator\npassword=hunter2\n"

alternateSecretBundle :: ByteString.ByteString
alternateSecretBundle = "user=accelerator\npassword=changed\n"

baseSecretDigest :: ActivationSecretDigest
baseSecretDigest = activationSecretDigestFromBytes baseSecretBundle

alternateSecretDigest :: ActivationSecretDigest
alternateSecretDigest = activationSecretDigestFromBytes alternateSecretBundle

withBaseManifest :: (ActivationManifest -> IO result) -> IO result
withBaseManifest use = expectRight (activationManifest checkedManifestInput) >>= use

withPodInstance :: (MeasuredInstance -> IO result) -> IO result
withPodInstance use = expectRight (kubernetesInstance "pod-uid-1" 0) >>= use

withBaseMeasurement :: (RuntimeMeasurement -> IO result) -> IO result
withBaseMeasurement use = withPodInstance $ \instance' ->
    use RuntimeMeasurement
        { measuredBinaryDigest = "binary-1"
        , measuredConfigDigest = "config-1"
        , measuredSecretDigest = activationSecretDigestFromBytes baseSecretBundle
        , measuredInstance = instance'
        }

verify ::
    ActivationVerificationKey ->
    ProtectedStore ->
    SelectedActivationManifest ->
    ReceivedActivationManifest ->
    ActivationGrant ->
    RuntimeMeasurement ->
    ( forall scope planDigest specDigest binaryDigest frame revision instanceId.
      VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
      IO result
    ) ->
    IO (Either ActivationError result)
verify = verifyRuntimeRoleActivation

ignoreActivation ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
    IO ()
ignoreActivation _ = pure ()

-- ---------------------------------------------------------------------------
-- Installed revision

installedRevisionTests :: [TestTree]
installedRevisionTests =
    [ testCase "an exact immutable revision installs, retries, and reopens" $ withPodInstance $ \podInstance ->
        withInstallFixture $ \broker store key root manifest -> do
            first <- expectInstall =<< installServiceActivationRevision broker key root manifest installedRoleWire baseSecretBundle
            second <- expectInstall =<< installServiceActivationRevision broker key root manifest installedRoleWire baseSecretBundle
            serviceActivationRevisionPath second @?= serviceActivationRevisionPath first
            reopened <-
                withInstalledServiceActivation store key first "binary-1" podInstance $ \activation roleWire secretBundle -> do
                    activationService activation @?= "accelerator"
                    roleWire @?= installedRoleWire
                    secretBundle @?= baseSecretBundle
            _ <- expectInstall reopened
            pure ()
    , testCase "role-wire and private-bundle digest mismatches refuse before publication" $
        withInstallFixture $ \broker _ key root manifest -> do
            badRole <- installServiceActivationRevision broker key root manifest "different-role" baseSecretBundle
            expectInstallInvalid "config digest" badRole
            badSecret <- installServiceActivationRevision broker key root manifest installedRoleWire alternateSecretBundle
            expectInstallInvalid "secret digest" badSecret
    , testCase "a conflicting installed member is never overwritten" $
        withInstallFixture $ \broker _ key root manifest -> do
            revision <- expectInstall =<< installServiceActivationRevision broker key root manifest installedRoleWire baseSecretBundle
            ByteString.writeFile (serviceActivationRevisionPath revision </> "role.dhall") "foreign"
            retried <- installServiceActivationRevision broker key root manifest installedRoleWire baseSecretBundle
            case retried of
                Left (ServiceActivationConflict path) -> path @?= serviceActivationRevisionPath revision
                other -> assertFailure ("expected an immutable conflict, got " <> show other)
    , testCase "an incomplete staging revision resumes only from exact members" $
        withInstallFixture $ \broker _ key root manifest -> do
            let revisionName = Text.unpack (digestBytes (renderActivationManifest manifest))
                staging = root </> ("installing-" <> revisionName)
            createDirectoryIfMissing True root
            createDirectory staging
            ByteString.writeFile (staging </> "expected.manifest") (renderActivationManifest manifest)
            revision <- expectInstall =<< installServiceActivationRevision broker key root manifest installedRoleWire baseSecretBundle
            serviceActivationRevisionPath revision @?= root </> revisionName
    , testCase "runtime measurement failures refuse without exposing secret bytes" $ withPodInstance $ \podInstance ->
        withInstallFixture $ \broker store key root manifest -> do
            revision <- expectInstall =<< installServiceActivationRevision broker key root manifest installedRoleWire baseSecretBundle
            refused <-
                withInstalledServiceActivation store key revision "wrong-binary" podInstance $ \_ _ _ ->
                    assertFailure "a mismatched binary reached the service"
            case refused of
                Left failure -> do
                    let diagnostic = serviceActivationErrorMessage failure
                    assertBool "the diagnostic names the binary mismatch" ("binary" `Text.isInfixOf` Text.pack diagnostic)
                    assertBool "the diagnostic does not expose the bundle" (not (ByteString.isInfixOf baseSecretBundle (TextEncoding.encodeUtf8 (Text.pack diagnostic))))
                Right _ -> assertFailure "expected activation refusal"
    , testCase "a missing installed member refuses closed" $ withPodInstance $ \podInstance ->
        withInstallFixture $ \broker store key root manifest -> do
            revision <- expectInstall =<< installServiceActivationRevision broker key root manifest installedRoleWire baseSecretBundle
            removeFile (serviceActivationRevisionPath revision </> "activation.sig")
            refused <- withInstalledServiceActivation store key revision "binary-1" podInstance (\_ _ _ -> pure ())
            case refused of
                Left (ServiceActivationIO _) -> pure ()
                other -> assertFailure ("expected an installed-member refusal, got " <> show other)
    , testCase "a signed narrowed role enters Acquire, Ready, Serve, Drain, and Exit" $
        withSystemTempDirectory "hostbootstrap-service-runtime" $ \directory -> do
            events <- newIORef ([] :: [Text])
            storeRef <- newIORef Nothing
            request <- either (assertFailure . show) pure (mkRoleResourceRequest "listener" False)
            draft <- either (assertFailure . show) pure (rolePlanDraft [request])
            identity <- either assertFailure pure (serviceId "web")
            let resources =
                    ServiceResourceBackend
                        { serviceRolePlanDraft = draft
                        , servicePrerequisite = record events "prereq" >> pure PrereqSatisfied
                        , serviceAcquireResource = \_ -> record events "acquire" >> pure Acquired
                        , serviceProbeResource = \_ -> record events "probe" >> pure ProbeReadyNow
                        , serviceReleaseResource = \_ -> record events "release" >> pure Released
                        }
                backend :: ServiceBackend RuntimePayloads
                backend =
                    ServiceBackend
                        { backendServe = \_ -> do
                            record events "serve"
                            selectedStore <- readIORef storeRef
                            case selectedStore of
                                Nothing -> pure (Left "the fixture did not publish its protected store")
                                Just selected -> do
                                    entered <- tryProtectedEntry selected (\_ -> pure (Right ()))
                                    pure $ case entered of
                                        Right (Just ()) -> Right ()
                                        other -> Left (Text.pack ("the service callback still holds the global transaction lock: " <> show other))
                        , backendCall = \_ _ -> pure (Right ())
                        , backendWork = \_ _ -> pure (Right ())
                        }
                definition =
                    serviceProgramDefinition
                        identity
                        (\_ -> Right (Just ()))
                        (WithEffect NetworkListenName NoEffects)
                        resources
                        backend
                        ( \_ -> withReadyServiceHandles $ \ready -> case lookupAcquiredResource ready "listener" of
                            Nothing -> pure ()
                            Just listener -> serve [(listener, ())]
                        )
                cfg = Fixture.defaultProjectConfig "activation-runtime" (Text.pack directory) Context.ClusterService
            withProductionProjectCodec @Fixture.ProjectConfig @Fixture.FixtureProject $ \baseCodec ->
                withFinalizedServiceRegistry ProductionScope baseCodec (singletonServiceRegistry definition) $ \codec registry -> do
                    let wireText =
                            either error id $
                                withSelectedServiceProgram
                                    "projection-digest"
                                    (inspectLocalContext (cfgContext cfg))
                                    cfg
                                    registry
                                    (\_ roleCodec selected _ _ _ _ -> renderValidatedServiceRequest roleCodec selected)
                        roleWire = TextEncoding.encodeUtf8 wireText
                    manifest <- expectRight $ activationManifest
                        ActivationManifestInput
                            { manifestInputScope = "Production"
                            , manifestInputPlanDigest = "plan-runtime"
                            , manifestInputSpecDigest = projectCodecSpecDigest codec
                            , manifestInputBinaryDigest = "binary-runtime"
                            , manifestInputFrame = localCurrentFrame (inspectLocalContext (cfgContext cfg))
                            , manifestInputRevision = "revision-runtime"
                            , manifestInputConfigDigest = digestBytes roleWire
                            , manifestInputSecretDigest = activationSecretDigestFromBytes ByteString.empty
                            , manifestInputService = "web"
                            , manifestInputRolePlanDigest = rolePlanDraftDigest draft
                            , manifestInputPermittedEffects = ["network-listen"]
                            , manifestInputSecretChannel = "/run/hostbootstrap/empty"
                            }
                    withBrokerFor [manifest] $ \broker store key -> do
                        writeIORef storeRef (Just store)
                        runtimeInstance <- expectRight (hostServiceInstance "runtime-1")
                        revision <-
                            expectInstall
                                =<< installServiceActivationRevision
                                    broker
                                    key
                                    (directory </> "revisions")
                                    manifest
                                    roleWire
                                    ByteString.empty
                        outcome <-
                            runInstalledServiceProgram
                                store
                                key
                                revision
                                "binary-runtime"
                                runtimeInstance
                                Dhall.defaultInputSettings
                                registry
                        report <- expectInstall outcome
                        assertBool "the lifecycle exits cleanly" (roleExitReportOk report)
                        readIORef events >>= (@?= ["prereq", "acquire", "probe", "serve", "release"])
                        reopened <-
                            runInstalledServiceProgram
                                store
                                key
                                revision
                                "binary-runtime"
                                runtimeInstance
                                Dhall.defaultInputSettings
                                registry
                        reopenedReport <- expectInstall reopened
                        assertBool "the consumed plan reopens at its exact request indices" (roleExitReportOk reopenedReport)
                        readIORef events
                            >>= (@?= ["prereq", "acquire", "probe", "serve", "release", "prereq", "acquire", "probe", "serve", "release"])
    ]

data RuntimePayloads

instance ServicePayloads RuntimePayloads where
    type ListenApp RuntimePayloads = ()
    type CallRequest RuntimePayloads = ()
    type CallReply RuntimePayloads = ()
    type WorkRequest RuntimePayloads = ()
    type WorkReply RuntimePayloads = ()

record :: IORef [Text] -> Text -> IO ()
record events event = modifyIORef' events (++ [event])

installedRoleWire :: ByteString.ByteString
installedRoleWire = "{ service = \"accelerator\" }"

digestBytes :: ByteString.ByteString -> Text
digestBytes bytes = Text.pack (show (Hash.hash bytes :: Hash.Digest Hash.SHA256))

withInstallFixture ::
    ( forall scope brokerGeneration verb.
      ActivationBroker scope brokerGeneration verb ->
      ProtectedStore ->
      ActivationVerificationKey ->
      FilePath ->
      ActivationManifest ->
      IO ()
    ) ->
    IO ()
withInstallFixture use =
    withSystemTempDirectory "hostbootstrap-installed-activation" $ \directory -> do
        manifest <- expectRight $ activationManifest checkedManifestInput
            { manifestInputConfigDigest = digestBytes installedRoleWire
            , manifestInputSecretDigest = activationSecretDigestFromBytes baseSecretBundle
            }
        withBrokerFor [manifest] $ \broker store key ->
            use broker store key (directory </> "revisions") manifest

expectInstall :: (Show failure) => Either failure value -> IO value
expectInstall outcome = case outcome of
    Left failure -> assertFailure (show failure)
    Right value -> pure value

expectInstallInvalid :: Text -> Either ServiceActivationError value -> IO ()
expectInstallInvalid expected outcome = case outcome of
    Left (ServiceActivationInvalid detail) ->
        assertBool "the refusal names the mismatched digest" (expected `Text.isInfixOf` detail)
    Left other -> assertFailure ("expected an installer refusal, got " <> show other)
    Right _ -> assertFailure "expected an installer refusal, got success"

-- | A real root invocation, a real activation broker, and its installed key.
withBroker ::
    ( forall scope brokerGeneration verb.
      ActivationBroker scope brokerGeneration verb ->
      ProtectedStore ->
      ActivationVerificationKey ->
      IO ()
    ) ->
    IO ()
withBroker use = withBaseManifest $ \baseManifest -> withBrokerFor [baseManifest] use

withBrokerSeed ::
    Int ->
    ( forall scope brokerGeneration verb.
      ActivationBroker scope brokerGeneration verb ->
      ProtectedStore ->
      ActivationVerificationKey ->
      IO ()
    ) ->
    IO ()
withBrokerSeed seed use = withBaseManifest $ \baseManifest -> withBrokerForSeed seed [baseManifest] use

withBrokerFor ::
    [ActivationManifest] ->
    ( forall scope brokerGeneration verb.
      ActivationBroker scope brokerGeneration verb ->
      ProtectedStore ->
      ActivationVerificationKey ->
      IO ()
    ) ->
    IO ()
withBrokerFor = withBrokerForSeed 41

withBrokerForSeed ::
    Int ->
    [ActivationManifest] ->
    ( forall scope brokerGeneration verb.
      ActivationBroker scope brokerGeneration verb ->
      ProtectedStore ->
      ActivationVerificationKey ->
      IO ()
    ) ->
    IO ()
withBrokerForSeed seed manifests use =
    withProvisionedActivationIdentity seed $ \signing verification ->
        withBrokerForIdentity signing verification manifests use

withBrokerForIdentity ::
    ActivationSigningKey ->
    ActivationVerificationKey ->
    [ActivationManifest] ->
    ( forall scope brokerGeneration verb.
      ActivationBroker scope brokerGeneration verb ->
      ProtectedStore ->
      ActivationVerificationKey ->
      IO ()
    ) ->
    IO ()
withBrokerForIdentity signing verification manifests use = case activationSigningPolicy manifests of
    Left failure -> assertFailure (activationErrorMessage failure)
    Right policy ->
        withSystemTempDirectory "hostbootstrap-activation" $ \directory -> do
            opened <- openProtectedStore (directory </> "authority")
            case opened of
                Left failure -> assertFailure (show failure)
                Right store -> do
                    outcome <-
                        withFixtureProject $ \project ->
                            withProductionRoot store project Authority.ProjectUp $ \root ->
                                Right
                                    <$> withActivationBroker
                                        signing
                                        (productionRootAuthority root)
                                        policy
                                        (\broker -> use broker store verification)
                    either (assertFailure . show) pure outcome

withProvisionedActivationIdentity ::
    Int ->
    (ActivationSigningKey -> ActivationVerificationKey -> IO result) ->
    IO result
withProvisionedActivationIdentity seed use = do
    signing <-
        expectRight
            (activationSigningKeyFromBytes (ByteString.replicate 32 (fromIntegral seed)))
    let derived = activationSigningVerificationKey signing
    installed <-
        expectRight
            (activationVerificationKeyFromBytes (activationVerificationKeyBytes derived))
    use signing installed

withFixtureProject ::
    (forall projectId. Authority.InstalledProjectIdentity projectId -> IO result) ->
    IO result
withFixtureProject use = do
    projectName <- Authority.normalizeExecutableIdentity <$> getExecutablePath
    admitted <- Authority.withInstalledProjectIdentity projectName use
    either (assertFailure . Text.unpack . Authority.authorityErrorMessage) pure admitted

-- | A signed 'baseManifest' plus the key that verifies it.
withSigned :: (ProtectedStore -> ActivationVerificationKey -> ActivationGrant -> IO ()) -> IO ()
withSigned use =
    withBaseManifest $ \baseManifest ->
        withBroker $ \broker store key -> do
            grant <- expectRight =<< signActivationManifest broker baseManifest
            use store key grant

-- Independent literal vector: 12 explicit fields, unsigned 64-bit big-endian frames.
-- Seed 97 signature was measured with a separate OpenSSL Ed25519 implementation.
literalActivationManifest :: ByteString.ByteString
literalActivationManifest = ByteString.pack
    [ 0, 0, 0, 0, 0, 0, 0, 10, 80, 114, 111, 100, 117, 99, 116, 105
    , 111, 110, 0, 0, 0, 0, 0, 0, 0, 6, 112, 108, 97, 110, 45, 49
    , 0, 0, 0, 0, 0, 0, 0, 6, 115, 112, 101, 99, 45, 49, 0, 0
    , 0, 0, 0, 0, 0, 8, 98, 105, 110, 97, 114, 121, 45, 49, 0, 0
    , 0, 0, 0, 0, 0, 8, 100, 97, 101, 109, 111, 110, 45, 51, 0, 0
    , 0, 0, 0, 0, 0, 5, 114, 101, 118, 45, 49, 0, 0, 0, 0, 0
    , 0, 0, 8, 99, 111, 110, 102, 105, 103, 45, 49, 0, 0, 0, 0, 0
    , 0, 0, 64, 102, 49, 98, 101, 100, 51, 55, 50, 57, 101, 54, 57, 54
    , 50, 48, 53, 52, 52, 57, 97, 102, 98, 57, 48, 55, 102, 99, 98, 52
    , 54, 100, 57, 52, 48, 48, 54, 98, 48, 48, 101, 54, 101, 97, 98, 52
    , 48, 55, 54, 100, 52, 99, 49, 51, 55, 48, 102, 101, 98, 100, 57, 49
    , 97, 49, 98, 0, 0, 0, 0, 0, 0, 0, 11, 97, 99, 99, 101, 108
    , 101, 114, 97, 116, 111, 114, 0, 0, 0, 0, 0, 0, 0, 10, 114, 111
    , 108, 101, 112, 108, 97, 110, 45, 49, 0, 0, 0, 0, 0, 0, 0, 41
    , 0, 0, 0, 0, 0, 0, 0, 13, 100, 117, 114, 97, 98, 108, 101, 45
    , 119, 114, 105, 116, 101, 0, 0, 0, 0, 0, 0, 0, 12, 115, 101, 114
    , 118, 105, 99, 101, 45, 112, 111, 114, 116, 0, 0, 0, 0, 0, 0, 0
    , 37, 47, 118, 97, 114, 47, 114, 117, 110, 47, 115, 101, 99, 114, 101, 116
    , 115, 47, 104, 111, 115, 116, 98, 111, 111, 116, 115, 116, 114, 97, 112, 47
    , 98, 117, 110, 100, 108, 101
    ]

literalActivationSignature :: ByteString.ByteString
literalActivationSignature = ByteString.pack
    [ 69, 210, 211, 36, 239, 210, 50, 244, 225, 1, 74, 105, 147, 3, 240, 26
    , 213, 213, 147, 73, 190, 165, 77, 159, 163, 251, 212, 42, 187, 206, 139, 49
    , 37, 151, 152, 174, 51, 61, 127, 72, 23, 69, 23, 178, 40, 208, 182, 122
    , 34, 250, 222, 211, 46, 175, 60, 102, 45, 33, 13, 63, 102, 22, 13, 13
    ]

{- | Produce a grant without using 'ActivationBroker'.  This pins the public
wire contract independently of the implementation that normally signs it.
-}
externallySignedGrant ::
    ByteString.ByteString ->
    IO (ActivationVerificationKey, ActivationGrant)
externallySignedGrant domain =
    case Ed25519.secretKey (ByteString.replicate 32 97) of
        CryptoFailed failure -> assertFailure ("external signing seed failed: " <> show failure)
        CryptoPassed secret -> do
            domainFrame <- case domain of
                "hostbootstrap/activation/v1" -> pure
                    (ByteString.pack [0, 0, 0, 0, 0, 0, 0, 27] <> "hostbootstrap/activation/v1")
                "hostbootstrap/activation/v0" -> pure
                    (ByteString.pack [0, 0, 0, 0, 0, 0, 0, 27] <> "hostbootstrap/activation/v0")
                _ -> assertFailure "the independent vector supports only the two explicit protocol domains"
            let public = Ed25519.toPublic secret
                material = domainFrame
                    <> ByteString.pack [0, 0, 0, 0, 0, 0, 1, 54]
                    <> literalActivationManifest
                signature :: ByteString.ByteString
                signature = convert (Ed25519.sign secret public material)
            when (domain == "hostbootstrap/activation/v1")
                (signature @?= literalActivationSignature)
            installed <- expectRight (activationVerificationKeyFromBytes (convert public))
            pure (installed, adoptRelayedActivationGrant signature)

data SomeActivationBroker
    = forall scope brokerGeneration verb.
        SomeActivationBroker (ActivationBroker scope brokerGeneration verb)

manifestWireWithSecretDigest :: Text -> ActivationManifest -> ByteString.ByteString
manifestWireWithSecretDigest secretDigest manifest =
    ByteString.concat
        [ field (manifestScope manifest)
        , field (manifestPlanDigest manifest)
        , field (manifestSpecDigest manifest)
        , field (manifestBinaryDigest manifest)
        , field (manifestFrame manifest)
        , field (manifestRevision manifest)
        , field (manifestConfigDigest manifest)
        , field secretDigest
        , field (manifestService manifest)
        , field (manifestRolePlanDigest manifest)
        , frameWire (ByteString.concat (map field (manifestPermittedEffects manifest)))
        , field (manifestSecretChannel manifest)
        ]
  where
    field = frameWire . TextEncoding.encodeUtf8

withStore :: (ProtectedStore -> IO ()) -> IO ()
withStore use =
    withSystemTempDirectory "hostbootstrap-admission" $ \directory -> do
        opened <- openProtectedStore (directory </> "authority")
        case opened of
            Left failure -> assertFailure (show failure)
            Right store -> use store

checkedManifestInputTests :: [TestTree]
checkedManifestInputTests =
    [ testCase "the checked producer retains the independent manifest and signature vectors" $ withBaseManifest $ \baseManifest -> do
        manifest <- expectRight (activationManifest checkedManifestInput)
        manifest @?= baseManifest
        renderActivationManifest manifest @?= literalActivationManifest
        withBrokerSeed 97 $ \broker _ _ -> do
            grant <- expectRight =<< signActivationManifest broker manifest
            activationGrantSignature grant @?= literalActivationSignature
    , testCase "the checked producer refuses all twelve malformed field and effect inputs exactly" $ do
        let refused =
                [ (checkedManifestInput{manifestInputScope = ""}, "the scope is empty")
                , (checkedManifestInput{manifestInputPlanDigest = ""}, "the plan digest is empty")
                , (checkedManifestInput{manifestInputSpecDigest = ""}, "the spec digest is empty")
                , (checkedManifestInput{manifestInputBinaryDigest = ""}, "the binary digest is empty")
                , (checkedManifestInput{manifestInputFrame = ""}, "the frame is empty")
                , (checkedManifestInput{manifestInputRevision = ""}, "the rollout revision is empty")
                , (checkedManifestInput{manifestInputConfigDigest = ""}, "the config digest is empty")
                , (checkedManifestInput{manifestInputService = ""}, "the service identity is empty")
                , (checkedManifestInput{manifestInputRolePlanDigest = ""}, "the role-plan digest is empty")
                , (checkedManifestInput{manifestInputSecretChannel = ""}, "the secret channel is empty")
                , (checkedManifestInput{manifestInputPermittedEffects = [""]}, "an effect identity is empty")
                , (checkedManifestInput{manifestInputPermittedEffects = ["read", "read"]}, "the effect row contains a duplicate identity")
                ]
        length refused @?= 12
        forM_ refused $ \(input, detail) ->
            activationManifest input @?= Left (ActivationManifestInvalid detail)
    , testCase "the checked producer accepts empty and ordered effects and descriptive digest text" $ do
        forM_ [[], ["second", "first"], ["first", "second"]] $ \effects -> do
            manifest <- expectRight (activationManifest checkedManifestInput{manifestInputPermittedEffects = effects})
            manifestPermittedEffects manifest @?= effects
        first <- expectRight (activationManifest checkedManifestInput{manifestInputPermittedEffects = ["first", "second"]})
        second <- expectRight (activationManifest checkedManifestInput{manifestInputPermittedEffects = ["second", "first"]})
        assertBool "the checked producer preserves effect order in canonical bytes"
            (renderActivationManifest first /= renderActivationManifest second)
        descriptive <- expectRight (activationManifest checkedManifestInput
            { manifestInputPlanDigest = "not hexadecimal plan"
            , manifestInputSpecDigest = "not hexadecimal spec"
            , manifestInputBinaryDigest = "not hexadecimal binary"
            , manifestInputConfigDigest = "not hexadecimal config"
            , manifestInputRolePlanDigest = "not hexadecimal role plan"
            })
        manifestPlanDigest descriptive @?= "not hexadecimal plan"
        manifestSpecDigest descriptive @?= "not hexadecimal spec"
        manifestBinaryDigest descriptive @?= "not hexadecimal binary"
        manifestConfigDigest descriptive @?= "not hexadecimal config"
        manifestRolePlanDigest descriptive @?= "not hexadecimal role plan"
    ]

checkedManifestInput :: ActivationManifestInput
checkedManifestInput =
    ActivationManifestInput
        { manifestInputScope = "Production"
        , manifestInputPlanDigest = "plan-1"
        , manifestInputSpecDigest = "spec-1"
        , manifestInputBinaryDigest = "binary-1"
        , manifestInputFrame = "daemon-3"
        , manifestInputRevision = "rev-1"
        , manifestInputConfigDigest = "config-1"
        , manifestInputSecretDigest = baseSecretDigest
        , manifestInputService = "accelerator"
        , manifestInputRolePlanDigest = "roleplan-1"
        , manifestInputPermittedEffects = ["durable-write", "service-port"]
        , manifestInputSecretChannel = "/var/run/secrets/hostbootstrap/bundle"
        }

sealedManifestTests :: [TestTree]
sealedManifestTests =
    [ testCase "wire framing and secret admission precede semantic manifest validation" $ do
        expected <- expectRight (activationManifest checkedManifestInput)
        activationManifestFromWire literalActivationManifest @?= Right expected
        emptyScope <- replaceManifestWireFields literalActivationManifest [(0, "")]
        badLaterText <- replaceManifestWireFields literalActivationManifest [(0, ""), (8, ByteString.singleton 255)]
        badSecret <- replaceManifestWireFields literalActivationManifest [(0, ""), (7, "not-hex")]
        badSecretBeforeTruncation <- replaceManifestWireFields literalActivationManifest [(7, "not-hex")]
        badEffects <- replaceManifestWireFields literalActivationManifest [(0, ""), (10, ByteString.singleton 0)]
        badChannelBeforeEffects <- replaceManifestWireFields literalActivationManifest [(10, ByteString.singleton 0), (11, ByteString.singleton 255)]
        emptyScopeAndEffect <- replaceManifestWireFields literalActivationManifest [(0, ""), (10, frameWire "")]
        forM_
            [ (badLaterText, "a manifest field is not valid UTF-8")
            , (badSecret, "the secret digest is not canonical lower-case SHA-256 hex")
            , (ByteString.init badSecretBeforeTruncation, "the secret digest is not canonical lower-case SHA-256 hex")
            , (badEffects, "the manifest wire is truncated")
            , (badEffects <> "x", "the manifest wire is truncated")
            , (badChannelBeforeEffects, "a manifest field is not valid UTF-8")
            , (emptyScope <> "x", "the manifest wire has trailing bytes")
            , (ByteString.init emptyScope, "the manifest wire is truncated")
            , (emptyScope, "the scope is empty")
            , (emptyScopeAndEffect, "the scope is empty")
            ] $ \(raw, detail) ->
                activationManifestFromWire raw @?= Left (ActivationManifestInvalid detail)
    , testCase "the received manifest role has total descriptive assignment and elimination" $ do
        manifest <- expectRight (activationManifest checkedManifestInput)
        let received = receivedActivationManifest manifest
        receivedActivationManifestValue received @?= manifest
        renderActivationManifest (receivedActivationManifestValue received) @?= literalActivationManifest
    , testCase "the selected manifest role has total descriptive assignment and elimination" $ do
        manifest <- expectRight (activationManifest checkedManifestInput)
        let selected = selectedActivationManifest manifest
        selectedActivationManifestValue selected @?= manifest
        renderActivationManifest (selectedActivationManifestValue selected) @?= literalActivationManifest
    , testCase "the sealed manifest has ordinary getters and preserves the measured Show vectors" $ do
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            description <- SourceGuard.readPackageDescription
            path <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Activation"
            source <- readFile path
            let names =
                    [ "Scope", "PlanDigest", "SpecDigest", "BinaryDigest", "Frame", "Revision"
                    , "ConfigDigest", "SecretDigest", "Service", "RolePlanDigest", "PermittedEffects", "SecretChannel"
                    ]
                privateNames = map (\name -> "manifest" <> name <> "Value") names
            SourceGuard.recordFieldNames "ActivationManifest" source @?= Right privateNames
            exports <- maybe (assertFailure "Activation needs its explicit export list") pure
                (SourceGuard.moduleExportTokens "HostBootstrap.Activation" source)
            forM_ (zip names privateNames) $ \(suffix, privateName) -> do
                let getter = "manifest" <> suffix
                assertBool (getter <> " must remain public") (getter `elem` exports)
                assertBool (privateName <> " must remain private") (privateName `notElem` exports)
                SourceGuard.haskellDefinitionTokens getter source @?= Right [getter, "=", privateName]
        manifest <- expectRight (activationManifest measuredManifestShowInput)
        let observed =
                [(show precedence, showsPrec precedence manifest "") | precedence <- ([0, 10, 11] :: [Int])]
                    ++ [("maybe", show (Just manifest)), ("list", show [manifest])]
        observed @?= measuredManifestShowVectors
    ]

-- These are raw frame edits, not an unchecked opaque manifest constructor.
replaceManifestWireFields :: ByteString.ByteString -> [(Int, ByteString.ByteString)] -> IO ByteString.ByteString
replaceManifestWireFields raw replacements = do
    fields <- collect raw
    length fields @?= 12
    forM_ replacements $ \(index, _) ->
        assertBool "the raw manifest field index is in its twelve-field shape" (index >= 0 && index < 12)
    pure (ByteString.concat [frameWire (maybe field id (lookup index replacements)) | (index, field) <- zip [0 ..] fields])
  where
    collect bytes
        | ByteString.null bytes = pure []
        | otherwise = do
            (field, rest) <- expectRight (takeHandoffFrame bytes)
            (field :) <$> collect rest

-- Literal compatibility subjects measured before sealing.
measuredManifestShowInput :: ActivationManifestInput
measuredManifestShowInput = ActivationManifestInput
    { manifestInputScope = "scope\"line\n"
    , manifestInputPlanDigest = "plan\\path"
    , manifestInputSpecDigest = "spec"
    , manifestInputBinaryDigest = "binary"
    , manifestInputFrame = "frame"
    , manifestInputRevision = "revision"
    , manifestInputConfigDigest = "config"
    , manifestInputSecretDigest = activationSecretDigestFromBytes "show-fixture-secret"
    , manifestInputService = "service"
    , manifestInputRolePlanDigest = "roles"
    , manifestInputPermittedEffects = ["second","first\"quoted"]
    , manifestInputSecretChannel = "/secret"
    }

measuredManifestShowVectors :: [(String, String)]
measuredManifestShowVectors =
    [ ("0", "ActivationManifest {manifestScope = \"scope\\\"line\\n\", manifestPlanDigest = \"plan\\\\path\", manifestSpecDigest = \"spec\", manifestBinaryDigest = \"binary\", manifestFrame = \"frame\", manifestRevision = \"revision\", manifestConfigDigest = \"config\", manifestSecretDigest = ActivationSecretDigest <sha256>, manifestService = \"service\", manifestRolePlanDigest = \"roles\", manifestPermittedEffects = [\"second\",\"first\\\"quoted\"], manifestSecretChannel = \"/secret\"}")
    , ("10", "ActivationManifest {manifestScope = \"scope\\\"line\\n\", manifestPlanDigest = \"plan\\\\path\", manifestSpecDigest = \"spec\", manifestBinaryDigest = \"binary\", manifestFrame = \"frame\", manifestRevision = \"revision\", manifestConfigDigest = \"config\", manifestSecretDigest = ActivationSecretDigest <sha256>, manifestService = \"service\", manifestRolePlanDigest = \"roles\", manifestPermittedEffects = [\"second\",\"first\\\"quoted\"], manifestSecretChannel = \"/secret\"}")
    , ("11", "(ActivationManifest {manifestScope = \"scope\\\"line\\n\", manifestPlanDigest = \"plan\\\\path\", manifestSpecDigest = \"spec\", manifestBinaryDigest = \"binary\", manifestFrame = \"frame\", manifestRevision = \"revision\", manifestConfigDigest = \"config\", manifestSecretDigest = ActivationSecretDigest <sha256>, manifestService = \"service\", manifestRolePlanDigest = \"roles\", manifestPermittedEffects = [\"second\",\"first\\\"quoted\"], manifestSecretChannel = \"/secret\"})")
    , ("maybe", "Just (ActivationManifest {manifestScope = \"scope\\\"line\\n\", manifestPlanDigest = \"plan\\\\path\", manifestSpecDigest = \"spec\", manifestBinaryDigest = \"binary\", manifestFrame = \"frame\", manifestRevision = \"revision\", manifestConfigDigest = \"config\", manifestSecretDigest = ActivationSecretDigest <sha256>, manifestService = \"service\", manifestRolePlanDigest = \"roles\", manifestPermittedEffects = [\"second\",\"first\\\"quoted\"], manifestSecretChannel = \"/secret\"})")
    , ("list", "[ActivationManifest {manifestScope = \"scope\\\"line\\n\", manifestPlanDigest = \"plan\\\\path\", manifestSpecDigest = \"spec\", manifestBinaryDigest = \"binary\", manifestFrame = \"frame\", manifestRevision = \"revision\", manifestConfigDigest = \"config\", manifestSecretDigest = ActivationSecretDigest <sha256>, manifestService = \"service\", manifestRolePlanDigest = \"roles\", manifestPermittedEffects = [\"second\",\"first\\\"quoted\"], manifestSecretChannel = \"/secret\"}]")
    ]

measuredInstanceTests :: [TestTree]
measuredInstanceTests =
    [ testCase "checked measured instances retain both total descriptive alternatives" $ do
        zero <- expectRight (kubernetesInstance "pod-uid-1" 0)
        maximumRestart <- expectRight (kubernetesInstance "pod-uid-1" maxBound)
        slash <- expectRight (hostServiceInstance "nonce/a")
        longNonce <- expectRight (hostServiceInstance (Text.replicate 10000 "n"))
        whitespaceUid <- expectRight (kubernetesInstance " " 0)
        whitespaceNonce <- expectRight (hostServiceInstance " ")
        let observe = foldMeasuredInstance (\uid restarts -> Left (uid, restarts)) Right
        observe zero @?= Left ("pod-uid-1", 0)
        observe maximumRestart @?= Left ("pod-uid-1", maxBound)
        observe slash @?= Right "nonce/a"
        observe longNonce @?= Right (Text.replicate 10000 "n")
        observe whitespaceUid @?= Left (" ", 0)
        observe whitespaceNonce @?= Right " "
        instanceIdentityText zero @?= "pod:pod-uid-1/0"
        instanceIdentityText maximumRestart @?= "pod:pod-uid-1/18446744073709551615"
        instanceIdentityText slash @?= "host:nonce/a"
    , testCase "checked measured instances preserve the measured Show and identity vectors" $ do
        escapedPod <- expectRight (kubernetesInstance "pod\"line\n\\path" 0)
        maximumPod <- expectRight (kubernetesInstance "pod-max" maxBound)
        escapedHost <- expectRight (hostServiceInstance "nonce\"line\n\\path")
        longHost <- expectRight (hostServiceInstance (Text.replicate 10000 "n"))
        let values =
                [ ("escaped-pod-restart0", escapedPod)
                , ("pod-maxWord64", maximumPod)
                , ("escaped-host", escapedHost)
                , ("long-host", longHost)
                ]
            observations =
                [ ( name
                  , [(show precedence, showsPrec precedence value "") | precedence <- ([0, 10, 11] :: [Int])]
                        ++ [("maybe", show (Just value)), ("list", show [value])]
                  , Text.unpack (instanceIdentityText value)
                  )
                | (name, value) <- values
                ]
        observations @?= measuredInstanceShowVectors
    ]

-- Fixed pre-sealing observations; repeated literal runs are represented losslessly.
measuredInstanceShowVectors :: [(String, [(String, String)], String)]
measuredInstanceShowVectors =
    [ ("escaped-pod-restart0"
      , [ ("0", "KubernetesInstance \"pod\\\"line\\n\\\\path\" 0")
        , ("10", "KubernetesInstance \"pod\\\"line\\n\\\\path\" 0")
        , ("11", "(KubernetesInstance \"pod\\\"line\\n\\\\path\" 0)")
        , ("maybe", "Just (KubernetesInstance \"pod\\\"line\\n\\\\path\" 0)")
        , ("list", "[KubernetesInstance \"pod\\\"line\\n\\\\path\" 0]")
        ]
      , "pod:pod\"line\n\\path/0"
      )
    , ("pod-maxWord64"
      , [ ("0", "KubernetesInstance \"pod-max\" 18446744073709551615")
        , ("10", "KubernetesInstance \"pod-max\" 18446744073709551615")
        , ("11", "(KubernetesInstance \"pod-max\" 18446744073709551615)")
        , ("maybe", "Just (KubernetesInstance \"pod-max\" 18446744073709551615)")
        , ("list", "[KubernetesInstance \"pod-max\" 18446744073709551615]")
        ]
      , "pod:pod-max/18446744073709551615"
      )
    , ("escaped-host"
      , [ ("0", "HostServiceInstance \"nonce\\\"line\\n\\\\path\"")
        , ("10", "HostServiceInstance \"nonce\\\"line\\n\\\\path\"")
        , ("11", "(HostServiceInstance \"nonce\\\"line\\n\\\\path\")")
        , ("maybe", "Just (HostServiceInstance \"nonce\\\"line\\n\\\\path\")")
        , ("list", "[HostServiceInstance \"nonce\\\"line\\n\\\\path\"]")
        ]
      , "host:nonce\"line\n\\path"
      )
    , ("long-host"
      , [ ("0", "HostServiceInstance \"" ++ replicate 10000 'n' ++ "\"")
        , ("10", "HostServiceInstance \"" ++ replicate 10000 'n' ++ "\"")
        , ("11", "(HostServiceInstance \"" ++ replicate 10000 'n' ++ "\")")
        , ("maybe", "Just (HostServiceInstance \"" ++ replicate 10000 'n' ++ "\")")
        , ("list", "[HostServiceInstance \"" ++ replicate 10000 'n' ++ "\"]")
        ]
      , "host:" ++ replicate 10000 'n' ++ ""
      )
    ]
