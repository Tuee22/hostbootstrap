{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeApplications #-}

{- | The broker-signed runtime role activation.

A restart is modelled the way a controller actually produces one: the same pod
UID with an incremented container restart count, or a host daemon with a fresh
invocation nonce. Manifests are genuinely signed, so a refusal here is the
protocol refusing, not a broken signature.
-}
module ActivationSpec (tests, withBrokerFor) where

import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import qualified Crypto.Hash as Hash
import qualified Crypto.PubKey.Ed25519 as Ed25519
import Data.ByteArray (convert)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Activation
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Handoff (frameWire)
import HostBootstrap.Lifecycle.Mode (productionRootAuthority, withProductionRoot)
import HostBootstrap.Config.Class (ProjectCfg (cfgContext), projectCodecSpecDigest, withProductionProjectCodec)
import HostBootstrap.Config.Fields (ScopeKind (ProductionScope), inspectLocalContext, localCurrentFrame, renderValidatedServiceRequest)
import HostBootstrap.Protected (
    ProtectedStore,
    openProtectedStore,
 )
import HostBootstrap.Service
    ( ServiceActivationError (..)
    , installServiceActivationRevision
    , runInstalledServiceProgram
    , serviceId
    , serviceProgramDefinition
    , ServiceResourceBackend (..)
    , singletonServiceRegistry
    , serviceActivationErrorMessage
    , serviceActivationRevisionPath
    , withInstalledServiceActivation
    , withFinalizedServiceRegistry
    , withSelectedServiceProgram
    )
import HostBootstrap.Service.Program
    ( ServiceBackend (..)
    , ServicePayloads (..)
    , lookupAcquiredResource
    , serve
    , withReadyServiceHandles
    )
import HostBootstrap.RoleLifecycle
    ( DeclaredEffects (NoEffects, WithEffect)
    , EffectName (NetworkListenName)
    , RoleAcquireOutcome (Acquired)
    , RolePrereqOutcome (PrereqSatisfied)
    , RoleProbeOutcome (ProbeReadyNow)
    , RoleReleaseOutcome (Released)
    , mkRoleResourceRequest
    , roleExitReportOk
    , rolePlanDraft
    , rolePlanDraftDigest
    )
import qualified Fixture
import qualified Dhall
import qualified HostBootstrap.Context as Context
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
                , baseManifest{manifestSecretDigest = alternateSecretDigest}
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
        withBroker $ \broker _ _ -> do
            invalidRevision <- signActivationManifest broker baseManifest{manifestRevision = ""}
            case invalidRevision of
                Left (ActivationManifestInvalid _) -> pure ()
                other -> assertFailure ("expected a revision refusal, got " <> show other)
            invalidService <- signActivationManifest broker baseManifest{manifestService = ""}
            case invalidService of
                Left (ActivationManifestInvalid _) -> pure ()
                other -> assertFailure ("expected a service refusal, got " <> show other)
    , testCase "the root signs only exact manifests in its closed policy" $
        withBroker $ \broker _ _ -> do
            _ <- expectRight =<< signActivationManifest broker baseManifest
            let variants =
                    [ baseManifest{manifestScope = "Harness run-3"}
                    , baseManifest{manifestPlanDigest = "plan-2"}
                    , baseManifest{manifestSpecDigest = "spec-2"}
                    , baseManifest{manifestBinaryDigest = "binary-2"}
                    , baseManifest{manifestFrame = "daemon-4"}
                    , baseManifest{manifestRevision = "rev-2"}
                    , baseManifest{manifestConfigDigest = "config-2"}
                    , baseManifest{manifestSecretDigest = alternateSecretDigest}
                    , baseManifest{manifestService = "other"}
                    , baseManifest{manifestRolePlanDigest = "roleplan-2"}
                    , baseManifest{manifestPermittedEffects = ["read"]}
                    , baseManifest{manifestSecretChannel = "/elsewhere"}
                    ]
            mapM_
                ( \manifest -> do
                    signed <- signActivationManifest broker manifest
                    case signed of
                        Left ActivationManifestNotAdmitted -> pure ()
                        other -> assertFailure ("expected an exact-policy refusal, got " <> show other)
                )
                variants
    , testCase "the private bundle is serialized only through its computed canonical digest" $ do
        let rendered = renderActivationManifest baseManifest
        assertBool
            "the private bundle bytes are absent"
            (not (ByteString.isInfixOf baseSecretBundle rendered))
        decoded <- expectRight (activationManifestFromWire rendered)
        decoded @?= baseManifest
        Text.length (activationSecretDigestText (manifestSecretDigest decoded)) @?= 64
    , testCase "the wire decoder refuses cleartext and non-canonical secret digests" $ do
        mapM_
            ( \invalid -> case activationManifestFromWire (manifestWireWithSecretDigest invalid baseManifest) of
                Left (ActivationManifestInvalid detail) ->
                    assertBool
                        "the refusal names the canonical digest requirement"
                        ("canonical" `Text.isInfixOf` detail)
                other -> assertFailure ("expected a malformed-digest refusal, got " <> show other)
            )
            ["hunter2", Text.replicate 64 "A"]
    , testCase "the wire decoder refuses a malformed UTF-8 field" $ do
        let rendered = renderActivationManifest baseManifest
            encodedScope = frameWire (TextEncoding.encodeUtf8 (manifestScope baseManifest))
            malformed =
                frameWire (ByteString.singleton 0xff)
                    <> ByteString.drop (ByteString.length encodedScope) rendered
        case activationManifestFromWire malformed of
            Left (ActivationManifestInvalid detail) ->
                assertBool "the refusal names UTF-8" ("UTF-8" `Text.isInfixOf` detail)
            other -> assertFailure ("expected a malformed-wire refusal, got " <> show other)
    , testCase "the wire decoder refuses a truncated final field" $ do
        let truncated = ByteString.init (renderActivationManifest baseManifest)
        case activationManifestFromWire truncated of
            Left (ActivationManifestInvalid detail) ->
                assertBool "the refusal names truncation" ("truncated" `Text.isInfixOf` detail)
            other -> assertFailure ("expected a truncated-wire refusal, got " <> show other)
    , testCase "the wire decoder refuses trailing bytes" $ do
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
    , testCase "the independently provisioned verifier is selected before broker construction" $
        withProvisionedActivationIdentity 41 $ \signing verifier -> do
            restored <-
                expectRight
                    ( activationVerificationKeyFromBytes
                        (activationVerificationKeyBytes verifier)
                    )
            restored @?= verifier
            withBrokerForIdentity signing verifier [baseManifest] $ \broker store installed -> do
                grant <- expectRight =<< signActivationManifest broker baseManifest
                outcome <- verify installed store baseManifest baseManifest grant baseMeasurement ignoreActivation
                _ <- expectRight outcome
                pure ()
    , testCase "a genuine activation verifies and exposes its bound package" $
        withSigned $ \store key grant -> do
            outcome <-
                verify key store baseManifest baseManifest grant baseMeasurement $ \activation -> do
                    activationRevision activation @?= "rev-1"
                    activationService activation @?= "accelerator"
                    activationPermittedEffects activation @?= ["durable-write", "service-port"]
                    activationSecretChannel activation @?= "/var/run/secrets/hostbootstrap/bundle"
                    activationInstance activation @?= measuredInstance baseMeasurement
            _ <- expectRight outcome
            pure ()
    , testCase "a changed ConfigMap hash refuses" $
        withSigned $ \store key grant -> do
            let changed = baseMeasurement{measuredConfigDigest = "config-tampered"}
            outcome <- verify key store baseManifest baseManifest grant changed ignoreActivation
            expectMismatch "config" outcome
    , testCase "a changed Secret hash refuses" $
        withSigned $ \store key grant -> do
            let changed = baseMeasurement{measuredSecretDigest = alternateSecretDigest}
            outcome <- verify key store baseManifest baseManifest grant changed ignoreActivation
            expectMismatch "secret" outcome
    , testCase "a different binary refuses, so a cross-binary replay fails" $
        withSigned $ \store key grant -> do
            let changed = baseMeasurement{measuredBinaryDigest = "binary-other"}
            outcome <- verify key store baseManifest baseManifest grant changed ignoreActivation
            expectMismatch "binary" outcome
    , testCase "a manifest for a superseded revision refuses" $
        withSigned $ \store key grant -> do
            let expected = baseManifest{manifestRevision = "rev-2"}
            outcome <- verify key store expected baseManifest grant baseMeasurement ignoreActivation
            case outcome of
                Left (ActivationRevisionStale signed expectedRevision) -> do
                    signed @?= "rev-1"
                    expectedRevision @?= "rev-2"
                other -> assertFailure ("expected a stale-revision refusal, got " <> show other)
    , testCase "another admitted manifest cannot replace the exact selected workload" $
        withBrokerFor [baseManifest, baseManifest{manifestService = "other"}] $ \broker store key -> do
            let otherManifest = baseManifest{manifestService = "other"}
            grant <- expectRight =<< signActivationManifest broker otherManifest
            outcome <- verify key store baseManifest otherManifest grant baseMeasurement ignoreActivation
            case outcome of
                Left (ActivationManifestMismatch fieldName _ _) -> fieldName @?= "service"
                other -> assertFailure ("expected an exact-manifest refusal, got " <> show other)
    , testCase "another independently provisioned activation key does not authenticate this manifest" $
        withSigned $ \store _ grant ->
            withBrokerSeed 42 $ \_ _ otherKey -> do
                outcome <- verify otherKey store baseManifest baseManifest grant baseMeasurement ignoreActivation
                case outcome of
                    Left (ActivationSignatureInvalid _) -> pure ()
                    other -> assertFailure ("expected a signature refusal, got " <> show other)
    , testCase "an independently produced activation/v1 signature verifies" $
        withStore $ \store -> do
            (key, grant) <- externallySignedGrant "hostbootstrap/activation/v1"
            outcome <- verify key store baseManifest baseManifest grant baseMeasurement ignoreActivation
            _ <- expectRight outcome
            pure ()
    , testCase "the same manifest signed under another domain is refused" $
        withStore $ \store -> do
            (key, grant) <- externallySignedGrant "hostbootstrap/activation/v0"
            outcome <- verify key store baseManifest baseManifest grant baseMeasurement ignoreActivation
            case outcome of
                Left (ActivationSignatureInvalid _) -> pure ()
                other -> assertFailure ("expected a cross-domain signature refusal, got " <> show other)
    , testCase "a manifest edited after signing refuses" $
        withSigned $ \store key grant -> do
            let edited = baseManifest{manifestPermittedEffects = ["durable-write", "service-port", "root"]}
            outcome <- verify key store edited edited grant baseMeasurement ignoreActivation
            case outcome of
                Left (ActivationSignatureInvalid _) -> pure ()
                other -> assertFailure ("expected a signature refusal, got " <> show other)
    , testCase "a restart is a different instance, so a retained activation is not it" $
        withSigned $ \store key grant -> do
            let restarted =
                    baseMeasurement
                        { measuredInstance = KubernetesInstance "pod-uid-1" 1
                        }
            first <-
                verify key store baseManifest baseManifest grant baseMeasurement $ \activation ->
                    pure (activationInstance activation)
            second <-
                verify key store baseManifest baseManifest grant restarted $ \activation ->
                    pure (activationInstance activation)
            firstInstance <- expectRight first
            secondInstance <- expectRight second
            assertBool "the two instances differ" (firstInstance /= secondInstance)
            instanceIdentityText firstInstance @?= "pod:pod-uid-1/0"
            instanceIdentityText secondInstance @?= "pod:pod-uid-1/1"
    , testCase "restart count zero is a valid measured instance" $
        withSigned $ \store key grant -> do
            let firstStart = baseMeasurement{measuredInstance = KubernetesInstance "pod-uid-1" 0}
            outcome <- verify key store baseManifest baseManifest grant firstStart ignoreActivation
            _ <- expectRight outcome
            pure ()
    , testCase "an empty Kubernetes pod UID is refused" $
        withSigned $ \store key grant -> do
            let missingUid = baseMeasurement{measuredInstance = KubernetesInstance "" 0}
            outcome <- verify key store baseManifest baseManifest grant missingUid ignoreActivation
            case outcome of
                Left (ActivationInstanceInvalid detail) ->
                    assertBool "the refusal names the pod UID" ("pod UID" `Text.isInfixOf` detail)
                other -> assertFailure ("expected an empty-pod-UID refusal, got " <> show other)
    , testCase "an empty host invocation nonce is refused" $
        withSigned $ \store key grant -> do
            let missingNonce = baseMeasurement{measuredInstance = HostServiceInstance ""}
            outcome <- verify key store baseManifest baseManifest grant missingNonce ignoreActivation
            case outcome of
                Left (ActivationInstanceInvalid detail) ->
                    assertBool
                        "the refusal names the invocation nonce"
                        ("invocation nonce" `Text.isInfixOf` detail)
                other -> assertFailure ("expected an empty-invocation-nonce refusal, got " <> show other)
    , testCase "a host daemon's invocation nonce is its instance identity" $
        withSigned $ \store key grant -> do
            let hostRun = baseMeasurement{measuredInstance = HostServiceInstance "nonce-9"}
            outcome <-
                verify key store baseManifest baseManifest grant hostRun $ \activation ->
                    instanceIdentityText (activationInstance activation) @?= "host:nonce-9"
            _ <- expectRight outcome
            pure ()
    , testCase "an escaped broker refuses after its active bracket closes" $ do
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
        , manifestSecretDigest = baseSecretDigest
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
        , measuredSecretDigest = activationSecretDigestFromBytes baseSecretBundle
        , measuredInstance = KubernetesInstance "pod-uid-1" 0
        }

verify ::
    ActivationVerificationKey ->
    ProtectedStore ->
    ActivationManifest ->
    ActivationManifest ->
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
    [ testCase "an exact immutable revision installs, retries, and reopens" $
        withInstallFixture $ \broker store key root manifest -> do
            first <- expectInstall =<< installServiceActivationRevision broker key root manifest installedRoleWire baseSecretBundle
            second <- expectInstall =<< installServiceActivationRevision broker key root manifest installedRoleWire baseSecretBundle
            serviceActivationRevisionPath second @?= serviceActivationRevisionPath first
            reopened <-
                withInstalledServiceActivation store key first "binary-1" (KubernetesInstance "pod-uid-1" 0) $ \activation roleWire secretBundle -> do
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
    , testCase "runtime measurement failures refuse without exposing secret bytes" $
        withInstallFixture $ \broker store key root manifest -> do
            revision <- expectInstall =<< installServiceActivationRevision broker key root manifest installedRoleWire baseSecretBundle
            refused <-
                withInstalledServiceActivation store key revision "wrong-binary" (KubernetesInstance "pod-uid-1" 0) $ \_ _ _ ->
                    assertFailure "a mismatched binary reached the service"
            case refused of
                Left failure -> do
                    let diagnostic = serviceActivationErrorMessage failure
                    assertBool "the diagnostic names the binary mismatch" ("binary" `Text.isInfixOf` Text.pack diagnostic)
                    assertBool "the diagnostic does not expose the bundle" (not (ByteString.isInfixOf baseSecretBundle (TextEncoding.encodeUtf8 (Text.pack diagnostic))))
                Right _ -> assertFailure "expected activation refusal"
    , testCase "a missing installed member refuses closed" $
        withInstallFixture $ \broker store key root manifest -> do
            revision <- expectInstall =<< installServiceActivationRevision broker key root manifest installedRoleWire baseSecretBundle
            removeFile (serviceActivationRevisionPath revision </> "activation.sig")
            refused <- withInstalledServiceActivation store key revision "binary-1" (KubernetesInstance "pod-uid-1" 0) (\_ _ _ -> pure ())
            case refused of
                Left (ServiceActivationIO _) -> pure ()
                other -> assertFailure ("expected an installed-member refusal, got " <> show other)
    , testCase "a signed narrowed role enters Acquire, Ready, Serve, Drain, and Exit" $
        withSystemTempDirectory "hostbootstrap-service-runtime" $ \directory -> do
            events <- newIORef ([] :: [Text])
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
                        { backendServe = \_ -> record events "serve" >> pure (Right ())
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
                        (\_ -> withReadyServiceHandles $ \ready -> case lookupAcquiredResource ready "listener" of
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
                        manifest =
                            ActivationManifest
                                { manifestScope = "Production"
                                , manifestPlanDigest = "plan-runtime"
                                , manifestSpecDigest = projectCodecSpecDigest codec
                                , manifestBinaryDigest = "binary-runtime"
                                , manifestFrame = localCurrentFrame (inspectLocalContext (cfgContext cfg))
                                , manifestRevision = "revision-runtime"
                                , manifestConfigDigest = digestBytes roleWire
                                , manifestSecretDigest = activationSecretDigestFromBytes ByteString.empty
                                , manifestService = "web"
                                , manifestRolePlanDigest = rolePlanDraftDigest draft
                                , manifestPermittedEffects = ["network-listen"]
                                , manifestSecretChannel = "/run/hostbootstrap/empty"
                                }
                    withBrokerFor [manifest] $ \broker store key -> do
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
                                (HostServiceInstance "runtime-1")
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
                                (HostServiceInstance "runtime-1")
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
    withSystemTempDirectory "hostbootstrap-installed-activation" $ \directory ->
        let manifest =
                baseManifest
                    { manifestConfigDigest = digestBytes installedRoleWire
                    , manifestSecretDigest = activationSecretDigestFromBytes baseSecretBundle
                    }
         in withBrokerFor [manifest] $ \broker store key ->
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
withBroker = withBrokerFor [baseManifest]

withBrokerSeed ::
    Int ->
    ( forall scope brokerGeneration verb.
      ActivationBroker scope brokerGeneration verb ->
      ProtectedStore ->
      ActivationVerificationKey ->
      IO ()
    ) ->
    IO ()
withBrokerSeed seed = withBrokerForSeed seed [baseManifest]

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
    withBroker $ \broker store key -> do
        grant <- expectRight =<< signActivationManifest broker baseManifest
        use store key grant

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
            let public = Ed25519.toPublic secret
                signature :: ByteString.ByteString
                signature =
                    convert
                        ( Ed25519.sign
                            secret
                            public
                            (frameWire domain <> frameWire (renderActivationManifest baseManifest))
                        )
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

expectRight :: (Show err) => Either err value -> IO value
expectRight (Right value) = pure value
expectRight (Left failure) = assertFailure ("expected success, got " <> show failure)
