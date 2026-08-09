{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The phase-indexed role lifecycle (the composition-and-network-algebra phase).

Every case drives the real engine: real Ed25519 activation grants from a real
root invocation, a real protected store on a real filesystem, and a real kernel
lock for the exclusive branch. Nothing here mints a cursor, a receipt, or an
activation by hand, because none of those has a public constructor.
-}
module RoleLifecycleSpec (tests, withRole, mutatingEffects, storeDraft) where

import qualified Data.ByteString as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
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
import HostBootstrap.RoleLifecycle
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "RoleLifecycleSpec"
        [ testGroup "the project draft" draftTests
        , testGroup "draft verification" verificationTests
        , testGroup "one-use lifecycle admission" admissionTests
        , testGroup "the phase machine" engineTests
        , testGroup "the declared effect row" effectRowTests
        ]

-- ---------------------------------------------------------------------------
-- The draft

draftTests :: [TestTree]
draftTests =
    [ testCase "the historical phase labels are still ordered Load..Exit" $
        rolePhases @?= [Load, Prereq, Acquire, Ready, Serve, Drain, Exit]
    , testCase "an empty draft is refused" $
        case rolePlanDraft [] of
            Left (RoleDraftInvalid _) -> pure ()
            other -> assertFailure ("expected a refusal, got " ++ show other)
    , testCase "duplicate resource names are refused" $
        case rolePlanDraft [request "listener" False, request "listener" False] of
            Left (RoleDraftInvalid _) -> pure ()
            other -> assertFailure ("expected a refusal, got " ++ show other)
    , testCase "a resource name must be one plain line" $
        case mkRoleResourceRequest "two\nlines" False of
            Left (RoleDraftInvalid _) -> pure ()
            other -> assertFailure ("expected a refusal, got " ++ show other)
    , testCase "the draft digest is length-prefixed, so a split cannot collide" $
        assertBool
            "two different splits of the same characters differ"
            ( rolePlanDraftDigest (draftOf [request "ab" False, request "c" False])
                /= rolePlanDraftDigest (draftOf [request "a" False, request "bc" False])
            )
    , testCase "the exclusive flag is part of the digest" $
        assertBool
            "shared and exclusive drafts differ"
            ( rolePlanDraftDigest (draftOf [request "store" False])
                /= rolePlanDraftDigest (draftOf [request "store" True])
            )
    , testCase "only durable-store and process are exclusive effects" $
        map roleEffectExclusive [NetworkListen, NetworkConnect, DurableStore, ProcessSpawn]
            @?= [False, False, True, True]
    , testCase "the effect vocabulary round-trips" $
        map (parseRoleEffect . roleEffectName) [minBound .. maxBound]
            @?= map Just [NetworkListen, NetworkConnect, DurableStore, ProcessSpawn]
    ]

-- ---------------------------------------------------------------------------
-- Verification (no durable mutation)

verificationTests :: [TestTree]
verificationTests =
    [ testCase "a draft that renders to the signed digest verifies" $
        withActivationFor servingEffects listenerDraft $ \activation ->
            case verifyRolePlanDraft activation listenerDraft (const ()) of
                Right () -> pure ()
                Left failure -> assertFailure (roleLifecycleErrorMessage failure)
    , testCase "a different draft is refused against the signed digest" $
        withActivationFor servingEffects listenerDraft $ \activation ->
            case verifyRolePlanDraft activation (draftOf [request "other" False]) (const ()) of
                Left (RoleDraftDigestMismatch _ _) -> pure ()
                other -> assertFailure ("expected a digest mismatch, got " ++ describe other)
    , testCase "an unparseable signed effect is refused rather than assumed harmless" $
        withActivationFor ["teleport"] listenerDraft $ \activation ->
            case verifyRolePlanDraft activation listenerDraft (const ()) of
                Left (RoleEffectUnsupported "teleport") -> pure ()
                other -> assertFailure ("expected an unsupported effect, got " ++ describe other)
    , testCase "an exclusive resource under a no-exclusive ceiling is refused" $
        withActivationFor servingEffects storeDraft $ \activation ->
            case verifyRolePlanDraft activation storeDraft (const ()) of
                Left (RoleDraftInvalid _) -> pure ()
                other -> assertFailure ("expected a refusal, got " ++ describe other)
    , testCase "the same exclusive resource verifies under a mutating ceiling" $
        withActivationFor mutatingEffects storeDraft $ \activation ->
            case verifyRolePlanDraft activation storeDraft (const ()) of
                Right () -> pure ()
                Left failure -> assertFailure (roleLifecycleErrorMessage failure)
    ]

-- ---------------------------------------------------------------------------
-- Admission

admissionTests :: [TestTree]
admissionTests =
    [ testCase "the first attempt reserves and the second reports recovery owed" $
        withStore $ \store ->
            withActivationFor servingEffects listenerDraft $ \activation ->
                withVerifiedDraft activation listenerDraft $ \verified -> do
                    first <- entry store (\session -> withRoleLifecycleAdmission session activation verified)
                    case first of
                        RoleAdmissionReserved _ -> pure ()
                        other -> assertFailure ("expected a reservation, got " ++ describeAdmission other)
                    second <- entry store (\session -> withRoleLifecycleAdmission session activation verified)
                    case second of
                        RoleAdmissionRecoveryRequired _ persisted ->
                            assertBool
                                "the predecessor record is reported verbatim"
                                ("reserved " `Text.isPrefixOf` persisted)
                        other -> assertFailure ("expected recovery owed, got " ++ describeAdmission other)
    , testCase "the reservation is consumed exactly once" $
        withStore $ \store ->
            withActivationFor servingEffects listenerDraft $ \activation ->
                withVerifiedDraft activation listenerDraft $ \verified -> do
                    reserved <- entry store (\session -> withRoleLifecycleAdmission session activation verified)
                    case reserved of
                        RoleAdmissionReserved admission -> do
                            firstUse <-
                                entry store $ \session ->
                                    withRuntimeRolePlan session activation verified admission $
                                        \plan binding placement _cursor ->
                                            pure
                                                ( rolePlanRevision plan
                                                , rolePlanFrame plan
                                                , rolePlanDigestBindingPlanDigest binding
                                                , placementLeaseRequirement placement
                                                )
                            firstUse @?= Right ("rev-1", "daemon-3", "plan-1", NoExclusiveEffects)
                            secondUse <-
                                entry store $ \session ->
                                    withRuntimeRolePlan session activation verified admission $
                                        \_ _ _ _ -> pure ()
                            case secondUse of
                                Left (RoleAdmissionAlreadyConsumed _) -> pure ()
                                other ->
                                    assertFailure
                                        ("expected the second use to be refused, got " ++ describePlan other)
                        other -> assertFailure ("expected a reservation, got " ++ describeAdmission other)
    , testCase "the binding reports the signed role-plan digest, not a recomputed plan" $
        withStore $ \store ->
            withActivationFor servingEffects listenerDraft $ \activation ->
                withVerifiedDraft activation listenerDraft $ \verified -> do
                    reserved <- entry store (\session -> withRoleLifecycleAdmission session activation verified)
                    case reserved of
                        RoleAdmissionReserved admission -> do
                            outcome <-
                                entry store $ \session ->
                                    withRuntimeRolePlan session activation verified admission $
                                        \_ binding _ _ -> pure (rolePlanDigestBindingRolePlanDigest binding)
                            outcome @?= Right (rolePlanDraftDigest listenerDraft)
                        other -> assertFailure ("expected a reservation, got " ++ describeAdmission other)
    , testCase "a mutating ceiling yields the generation-lease requirement" $
        withStore $ \store ->
            withActivationFor mutatingEffects storeDraft $ \activation ->
                withVerifiedDraft activation storeDraft $ \verified -> do
                    reserved <- entry store (\session -> withRoleLifecycleAdmission session activation verified)
                    case reserved of
                        RoleAdmissionReserved admission -> do
                            outcome <-
                                entry store $ \session ->
                                    withRuntimeRolePlan session activation verified admission $
                                        \_ _ placement _ ->
                                            pure
                                                ( placementLeaseRequirement placement
                                                , placementPermittedEffects placement
                                                , placementService placement
                                                )
                            outcome
                                @?= Right (RequiresGenerationLease, [DurableStore, NetworkListen], "accelerator")
                        other -> assertFailure ("expected a reservation, got " ++ describeAdmission other)
    ]

{- | The declared effect row and its authorization against the signed ceiling
(§ AA).

The row a handler is indexed by is the one its /definition/ declares; the signed
ceiling is what decides whether that choice is admissible. Declaring less than
the ceiling permits is the point of the split, so the interesting cases are the
narrower row (admitted) and the wider one (refused by name).
-}
effectRowTests :: [TestTree]
effectRowTests =
    [ testCase "a declared row reads back exactly the effects its type names" $ do
        declaredEffectList NoEffects @?= []
        declaredEffectList (WithEffect NetworkListenName NoEffects) @?= [NetworkListen]
        declaredEffectList
            (WithEffect DurableStoreName (WithEffect NetworkListenName NoEffects))
            @?= [DurableStore, NetworkListen]
    , testCase "a row within the signed ceiling is authorized at its own row" $
        withRole mutatingEffects storeDraft $ \_ _ placement _ -> do
            -- the ceiling is [DurableStore, NetworkListen]
            placementPermittedEffects placement @?= [DurableStore, NetworkListen]
            case authorizeServiceEffects placement (WithEffect NetworkListenName NoEffects) of
                Right authorization -> do
                    -- the authorization carries the DECLARED row, not the ceiling
                    authorizedEffects authorization @?= [NetworkListen]
                    -- and the lease requirement follows the declaration: a role
                    -- that declares no exclusive effect does not inherit its
                    -- ceiling's lease
                    authorizedLeaseRequirement authorization @?= NoExclusiveEffects
                    placementLeaseRequirement placement @?= RequiresGenerationLease
                Left failure ->
                    assertFailure ("a narrower row was refused: " ++ roleLifecycleErrorMessage failure)
    , testCase "the exact ceiling is authorized, and keeps its lease requirement" $
        withRole mutatingEffects storeDraft $ \_ _ placement _ ->
            case authorizeServiceEffects
                placement
                (WithEffect DurableStoreName (WithEffect NetworkListenName NoEffects)) of
                Right authorization -> do
                    authorizedEffects authorization @?= [DurableStore, NetworkListen]
                    authorizedLeaseRequirement authorization @?= RequiresGenerationLease
                Left failure ->
                    assertFailure ("the exact ceiling was refused: " ++ roleLifecycleErrorMessage failure)
    , testCase "a row outside the ceiling is refused, naming the service and the effect" $
        withRole mutatingEffects storeDraft $ \_ _ placement _ ->
            case authorizeServiceEffects
                placement
                (WithEffect ProcessSpawnName (WithEffect NetworkListenName NoEffects)) of
                Left (RoleEffectNotPermitted service effect) -> do
                    service @?= "accelerator"
                    effect @?= "process"
                other ->
                    assertFailure
                        ("expected a not-permitted refusal, got " ++ describeAuthorization other)
    , testCase "an empty row is admitted under any ceiling and needs no lease" $
        withRole mutatingEffects storeDraft $ \_ _ placement _ ->
            case authorizeServiceEffects placement NoEffects of
                Right authorization -> do
                    authorizedEffects authorization @?= []
                    authorizedLeaseRequirement authorization @?= NoExclusiveEffects
                Left failure ->
                    assertFailure ("an empty row was refused: " ++ roleLifecycleErrorMessage failure)
    ]

describeAuthorization ::
    Either RoleLifecycleError (EffectAuthorization scope specDigest planId frame revision instanceId service effects) ->
    String
describeAuthorization (Left failure) = roleLifecycleErrorMessage failure
describeAuthorization (Right authorization) = "authorized " ++ show (authorizedEffects authorization)

-- ---------------------------------------------------------------------------
-- The phase machine

engineTests :: [TestTree]
engineTests =
    [ testCase "a prerequisite refusal turns at Prereq and acquires nothing" $
        withRole servingEffects twoResourceDraft $ \store plan placement cursor -> do
            trace <- newIORef []
            report <-
                runRoleLifecycle store plan placement cursor $
                    (tracingEngine trace){enginePrereq = pure (PrereqRefused "no GPU present")}
            exitTurnedAtPhase report @?= Prereq
            exitReason report @?= Just "no GPU present"
            exitOwnedResources report @?= []
            exitDrainFailures report @?= []
            readIORef trace >>= (@?= [])
    , testCase "a throwing prerequisite is still a refusal, not an escape" $
        withRole servingEffects twoResourceDraft $ \store plan placement cursor -> do
            trace <- newIORef []
            report <-
                runRoleLifecycle store plan placement cursor $
                    (tracingEngine trace){enginePrereq = ioError (userError "probe blew up")}
            exitTurnedAtPhase report @?= Prereq
            assertBool
                "the cause is carried"
                (maybe False (Text.isInfixOf "probe blew up") (exitReason report))
            readIORef trace >>= (@?= [])
    , testCase "the clean path acquires, probes, serves, then drains in order" $
        withRole servingEffects twoResourceDraft $ \store plan placement cursor -> do
            trace <- newIORef []
            report <- runRoleLifecycle store plan placement cursor (tracingEngine trace)
            assertBool
                ("expected a clean exit: " ++ renderRoleExitReport report)
                (roleExitReportOk report)
            exitTurnedAtPhase report @?= Serve
            exitOwnedResources report @?= ["listener", "worker"]
            steps <- readIORef trace
            steps
                @?= [ "prereq"
                    , "acquire:listener"
                    , "acquire:worker"
                    , "probe:listener"
                    , "probe:worker"
                    , "serve:listener,worker"
                    , "release:listener"
                    , "release:worker"
                    ]
    , testCase "a failed acquisition drains only what was already acquired" $
        withRole servingEffects twoResourceDraft $ \store plan placement cursor -> do
            trace <- newIORef []
            report <-
                runRoleLifecycle store plan placement cursor $
                    (tracingEngine trace)
                        { engineAcquire = \required -> do
                            record trace ("acquire:" <> roleResourceName required)
                            pure
                                ( if roleResourceName required == "worker"
                                    then AcquireFailed "no slot"
                                    else Acquired
                                )
                        }
            exitTurnedAtPhase report @?= Acquire
            exitOwnedResources report @?= ["listener"]
            exitUnknownResources report @?= []
            assertBool
                "the cause names the resource"
                (maybe False (Text.isInfixOf "worker") (exitReason report))
            steps <- readIORef trace
            steps @?= ["prereq", "acquire:listener", "acquire:worker", "release:listener"]
    , testCase "an unknown acquisition is retained for drain rather than dropped" $
        withRole servingEffects twoResourceDraft $ \store plan placement cursor -> do
            trace <- newIORef []
            report <-
                runRoleLifecycle store plan placement cursor $
                    (tracingEngine trace)
                        { engineAcquire = \required -> do
                            record trace ("acquire:" <> roleResourceName required)
                            pure
                                ( if roleResourceName required == "worker"
                                    then AcquireUnknown "the call did not answer"
                                    else Acquired
                                )
                        }
            exitTurnedAtPhase report @?= Acquire
            exitOwnedResources report @?= ["listener"]
            exitUnknownResources report @?= ["worker"]
            assertBool "an unknown outcome is not a clean exit" (not (roleExitReportOk report))
            steps <- readIORef trace
            steps
                @?= [ "prereq"
                    , "acquire:listener"
                    , "acquire:worker"
                    , "release:listener"
                    , "release:worker"
                    ]
    , testCase "a readiness failure cannot reach Serve and drains everything acquired" $
        withRole servingEffects twoResourceDraft $ \store plan placement cursor -> do
            trace <- newIORef []
            report <-
                runRoleLifecycle store plan placement cursor $
                    (tracingEngine trace)
                        { engineProbe = \required -> do
                            record trace ("probe:" <> roleResourceName required)
                            pure
                                ( if roleResourceName required == "worker"
                                    then ProbeNotReady "still starting"
                                    else ProbeReadyNow
                                )
                        }
            exitTurnedAtPhase report @?= Ready
            exitOwnedResources report @?= ["listener", "worker"]
            steps <- readIORef trace
            assertBool "serve never ran" (not (any (Text.isPrefixOf "serve") steps))
            assertBool
                "both were released"
                (["release:listener", "release:worker"] `isSuffixOfList` steps)
    , testCase "a serve exception becomes a typed failure and drain still runs" $
        withRole servingEffects twoResourceDraft $ \store plan placement cursor -> do
            trace <- newIORef []
            report <-
                runRoleLifecycle store plan placement cursor $
                    (tracingEngine trace){engineServe = \_ -> ioError (userError "handler died")}
            exitTurnedAtPhase report @?= Serve
            assertBool
                "the cause is carried"
                (maybe False (Text.isInfixOf "handler died") (exitReason report))
            steps <- readIORef trace
            assertBool
                "both were released"
                (["release:listener", "release:worker"] `isSuffixOfList` steps)
    , testCase "a catchable shutdown drains once and is not a serve failure" $
        withRole servingEffects twoResourceDraft $ \store plan placement cursor -> do
            trace <- newIORef []
            report <-
                runRoleLifecycle store plan placement cursor $
                    (tracingEngine trace){engineServe = \_ -> pure (ServeShutdown "SIGTERM")}
            exitReason report @?= Just "shutdown: SIGTERM"
            steps <- readIORef trace
            length [step | step <- steps, step == "release:listener"] @?= 1
    , testCase "drain attempts every release and aggregates the failures" $
        withRole servingEffects twoResourceDraft $ \store plan placement cursor -> do
            trace <- newIORef []
            report <-
                runRoleLifecycle store plan placement cursor $
                    (tracingEngine trace)
                        { engineRelease = \required -> do
                            record trace ("release:" <> roleResourceName required)
                            pure (ReleaseFailed ("stuck: " <> roleResourceName required))
                        }
            length (exitDrainFailures report) @?= 2
            assertBool "a drain failure makes the exit unclean" (not (roleExitReportOk report))
            steps <- readIORef trace
            assertBool
                "the second release ran despite the first failing"
                ("release:worker" `elem` steps)
    , testCase "a live exclusive holder refuses the peer before it acquires anything" $
        withRole mutatingEffects storeDraft $ \store plan placement cursor -> do
            placementLeaseRequirement placement @?= RequiresGenerationLease
            outer <- newIORef []
            inner <- newIORef []
            peer <- newIORef Nothing
            _ <-
                runRoleLifecycle store plan placement cursor $
                    (tracingEngine outer)
                        { engineServe = \_ -> do
                            -- A second instance of the same role, started while
                            -- this one is live and holding the lease.
                            report <- runRoleLifecycle store plan placement cursor (tracingEngine inner)
                            writeIORef peer (Just report)
                            pure ServeCompleted
                        }
            observed <- readIORef peer
            case observed of
                Nothing -> assertFailure "the peer never ran"
                Just report -> do
                    exitTurnedAtPhase report @?= Prereq
                    exitOwnedResources report @?= []
                    assertBool
                        "the refusal states its cause"
                        (maybe False (Text.isInfixOf "exclusive generation lease") (exitReason report))
            readIORef inner >>= (@?= [])
    ]

-- ---------------------------------------------------------------------------
-- Engine fixtures

tracingEngine :: IORef [Text] -> RoleEngine
tracingEngine trace =
    RoleEngine
        { enginePrereq = record trace "prereq" >> pure PrereqSatisfied
        , engineAcquire = \required -> do
            record trace ("acquire:" <> roleResourceName required)
            pure Acquired
        , engineProbe = \required -> do
            record trace ("probe:" <> roleResourceName required)
            pure ProbeReadyNow
        , engineServe = \ready -> do
            record trace ("serve:" <> Text.intercalate "," (readyRoleHandleNames ready))
            pure ServeCompleted
        , engineRelease = \required -> do
            record trace ("release:" <> roleResourceName required)
            pure Released
        }

record :: IORef [Text] -> Text -> IO ()
record trace value = modifyIORef' trace (++ [value])

-- ---------------------------------------------------------------------------
-- Drafts

request :: Text -> Bool -> RoleResourceRequest
request name exclusive =
    either (error . roleLifecycleErrorMessage) id (mkRoleResourceRequest name exclusive)

draftOf :: [RoleResourceRequest] -> RolePlanDraft
draftOf = either (error . roleLifecycleErrorMessage) id . rolePlanDraft

listenerDraft :: RolePlanDraft
listenerDraft = draftOf [request "listener" False]

storeDraft :: RolePlanDraft
storeDraft = draftOf [request "store" True]

twoResourceDraft :: RolePlanDraft
twoResourceDraft = draftOf [request "listener" False, request "worker" False]

servingEffects :: [Text]
servingEffects = [roleEffectName NetworkListen, roleEffectName NetworkConnect]

mutatingEffects :: [Text]
mutatingEffects = [roleEffectName DurableStore, roleEffectName NetworkListen]

-- ---------------------------------------------------------------------------
-- Activation fixtures

{- | A genuinely signed activation whose manifest names the given effect ceiling
and the given draft's digest, verified against the installed public key.
-}
withActivationFor ::
    [Text] ->
    RolePlanDraft ->
    ( forall scope planDigest specDigest binaryDigest frame revision instanceId.
      VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
      IO ()
    ) ->
    IO ()
withActivationFor effects draft use =
    withBroker $ \broker key -> do
        let manifest =
                baseManifest
                    { manifestPermittedEffects = effects
                    , manifestRolePlanDigest = rolePlanDraftDigest draft
                    }
        case signActivationManifest broker manifest of
            Left failure -> assertFailure (activationErrorMessage failure)
            Right grant ->
                case verifyRuntimeRoleActivation key "rev-1" manifest grant baseMeasurement of
                    Left failure -> assertFailure (activationErrorMessage failure)
                    Right activation -> use activation

withVerifiedDraft ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
    RolePlanDraft ->
    ( forall rolePlanDigest.
      VerifiedRolePlanDraft scope planDigest frame revision instanceId rolePlanDigest ->
      IO ()
    ) ->
    IO ()
withVerifiedDraft activation draft use =
    case verifyRolePlanDraft activation draft use of
        Left failure -> assertFailure (roleLifecycleErrorMessage failure)
        Right action -> action

{- | Everything a role needs to reach its first cursor: a store, a signed
activation, a verified draft, a reserved-then-consumed admission, and the plan.
-}
withRole ::
    [Text] ->
    RolePlanDraft ->
    ( forall scope specDigest planId configId secretDigest frame revision instanceId service permittedEffects.
      ProtectedStore ->
      RolePlan scope specDigest planId configId secretDigest frame revision instanceId ->
      VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects ->
      RoleCursor scope planId frame instanceId PrereqPhase ->
      IO ()
    ) ->
    IO ()
withRole effects draft use =
    withStore $ \store ->
        withActivationFor effects draft $ \activation ->
            withVerifiedDraft activation draft $ \verified -> do
                reserved <- entry store (\session -> withRoleLifecycleAdmission session activation verified)
                case reserved of
                    RoleAdmissionReserved admission -> do
                        opened <-
                            entry store $ \session ->
                                withRuntimeRolePlan session activation verified admission $
                                    \plan _binding placement cursor -> use store plan placement cursor
                        either (assertFailure . roleLifecycleErrorMessage) pure opened
                    other -> assertFailure ("expected a reservation, got " ++ describeAdmission other)

withStore :: (ProtectedStore -> IO ()) -> IO ()
withStore use =
    withSystemTempDirectory "hostbootstrap-role" $ \directory -> do
        opened <- openProtectedStore (directory </> "authority")
        either (assertFailure . show) use opened

-- | Run one protected transaction, failing the test on a store error.
entry :: ProtectedStore -> (forall session. ProtectedSession session -> IO result) -> IO result
entry store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    either (assertFailure . show) pure outcome

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
        , manifestPermittedEffects = []
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

-- | A real root invocation, a real activation broker, and its installed key.
withBroker ::
    ( forall scope brokerGeneration verb.
      ActivationBroker scope brokerGeneration verb ->
      ProjectVerificationKey ->
      IO ()
    ) ->
    IO ()
withBroker use =
    withSystemTempDirectory "hostbootstrap-role-broker" $ \directory -> do
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
                                        (\root -> Right <$> withActivationBroker root (installAndUse directory))
                either (assertFailure . show) pure outcome
  where
    installAndUse directory broker = do
        let path = directory </> "project.pub"
        ByteString.writeFile path (activationBrokerKey broker)
        loaded <- installedVerificationKey path
        either (assertFailure . show) (use broker) loaded

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

-- ---------------------------------------------------------------------------
-- Small helpers

describe :: (Show failure) => Either failure () -> String
describe = either show (const "an accepted draft")

describeAdmission :: RoleAdmissionOutcome scope planDigest frame revision instanceId -> String
describeAdmission outcome = case outcome of
    RoleAdmissionReserved admission -> "reserved " ++ show (reservedRoleAdmissionKey admission)
    RoleAdmissionRecoveryRequired key persisted -> "recovery owed " ++ show (key, persisted)
    RoleAdmissionUnknown detail -> "unknown " ++ show detail

describePlan :: Either RoleLifecycleError () -> String
describePlan = either roleLifecycleErrorMessage (const "a second opened plan")

isSuffixOfList :: (Eq a) => [a] -> [a] -> Bool
isSuffixOfList needle haystack = needle == drop (length haystack - length needle) haystack
