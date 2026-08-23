{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The phase-indexed role lifecycle (the composition-and-network-algebra phase).

Every case drives the real engine: real Ed25519 activation grants from a real
root invocation, a real protected store on a real filesystem, and a real kernel
lock for the exclusive branch. Nothing here mints a cursor, a receipt, or an
activation by hand, because none of those has a public constructor.
-}
module RoleLifecycleSpec (tests, withRole, mutatingEffects, storeDraft) where

import Control.Exception (AsyncException (ThreadKilled), throwIO)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Fixture
import HostBootstrap.Activation
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Lifecycle.Mode (productionRootAuthority, withProductionRoot)
import HostBootstrap.Protected (
    ProtectedError (ProtectedMalformedRecord),
    ProtectedSession,
    ProtectedStore,
    openProtectedStore,
    protectedStoreRoot,
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
        withActivationFor servingEffects listenerDraft $ \_ activation ->
            case verifyRolePlanDraft activation listenerDraft (const ()) of
                Right () -> pure ()
                Left failure -> assertFailure (roleLifecycleErrorMessage failure)
    , testCase "a different draft is refused against the signed digest" $
        withActivationFor servingEffects listenerDraft $ \_ activation ->
            case verifyRolePlanDraft activation (draftOf [request "other" False]) (const ()) of
                Left (RoleDraftDigestMismatch _ _) -> pure ()
                other -> assertFailure ("expected a digest mismatch, got " ++ describe other)
    , testCase "an unparseable signed effect is refused rather than assumed harmless" $
        withActivationFor ["teleport"] listenerDraft $ \_ activation ->
            case verifyRolePlanDraft activation listenerDraft (const ()) of
                Left (RoleEffectUnsupported "teleport") -> pure ()
                other -> assertFailure ("expected an unsupported effect, got " ++ describe other)
    , testCase "an exclusive resource under a no-exclusive ceiling is refused" $
        withActivationFor servingEffects storeDraft $ \_ activation ->
            case verifyRolePlanDraft activation storeDraft (const ()) of
                Left (RoleDraftInvalid _) -> pure ()
                other -> assertFailure ("expected a refusal, got " ++ describe other)
    , testCase "the same exclusive resource verifies under a mutating ceiling" $
        withActivationFor mutatingEffects storeDraft $ \_ activation ->
            case verifyRolePlanDraft activation storeDraft (const ()) of
                Right () -> pure ()
                Left failure -> assertFailure (roleLifecycleErrorMessage failure)
    ]

-- ---------------------------------------------------------------------------
-- Admission

admissionTests :: [TestTree]
admissionTests =
    [ testCase "a lost reservation acknowledgement rehydrates the exact reservation" $
        withActivationFor servingEffects listenerDraft $ \store activation ->
            withVerifiedDraft activation listenerDraft $ \verified -> do
                first <- entry store (\session -> withRoleLifecycleAdmission session activation verified)
                case first of
                    RoleAdmissionReserved _ -> pure ()
                    other -> assertFailure ("expected a reservation, got " ++ describeAdmission other)
                second <- entry store (\session -> withRoleLifecycleAdmission session activation verified)
                case second of
                    RoleAdmissionReserved secondAdmission ->
                        assertBool
                            "the same bounded admission key is rehydrated"
                            (not (Text.null (reservedRoleAdmissionKey secondAdmission)))
                    other -> assertFailure ("expected a rehydrated reservation, got " ++ describeAdmission other)
    , testCase "instance identities that the former sanitizer collided reserve distinct rows" $ do
        let manifest =
                baseManifest
                    { manifestPermittedEffects = servingEffects
                    , manifestRolePlanDigest = rolePlanDraftDigest listenerDraft
                    }
            slashIdentity =
                baseMeasurement{measuredInstance = HostServiceInstance "nonce/a"}
            joinedIdentity =
                baseMeasurement{measuredInstance = HostServiceInstance "noncea"}
        withBroker manifest $ \broker store key -> do
            grant <- either (assertFailure . activationErrorMessage) pure =<< signActivationManifest broker manifest
            slashKey <-
                reserveAdmissionKey store key manifest grant slashIdentity listenerDraft
            joinedKey <-
                reserveAdmissionKey store key manifest grant joinedIdentity listenerDraft
            assertBool
                "the slash is framed into the measured coordinate rather than discarded"
                (slashKey /= joinedKey)
    , testCase "an arbitrarily long valid measured identity still reserves with a bounded key" $ do
        let manifest =
                baseManifest
                    { manifestPermittedEffects = servingEffects
                    , manifestRolePlanDigest = rolePlanDraftDigest listenerDraft
                    }
            longIdentity =
                baseMeasurement
                    { measuredInstance = HostServiceInstance (Text.replicate 10000 "n")
                    }
        withBroker manifest $ \broker store key -> do
            grant <- either (assertFailure . activationErrorMessage) pure =<< signActivationManifest broker manifest
            admissionKey <-
                reserveAdmissionKey store key manifest grant longIdentity listenerDraft
            Text.length admissionKey @?= Text.length "role-admission." + 64
            assertBool
                "the admission key remains below the protected store's 200-character limit"
                (Text.length admissionKey <= 200)
    , testCase "a cross-store activation is refused before the target store mutates" $ do
        let manifest =
                baseManifest
                    { manifestPermittedEffects = servingEffects
                    , manifestRolePlanDigest = rolePlanDraftDigest listenerDraft
                    }
        withBroker manifest $ \broker origin key -> do
            signed <- signActivationManifest broker manifest
            grant <- either (assertFailure . activationErrorMessage) pure signed
            withIndependentStore $ \other -> do
                refused <-
                    verifyRuntimeRoleActivation
                        key
                        origin
                        manifest
                        manifest
                        grant
                        baseMeasurement
                        ( \activation ->
                            withVerifiedDraft activation listenerDraft $ \verified -> do
                                outcome <-
                                    entry other $ \session ->
                                        withRoleLifecycleAdmission session activation verified
                                case outcome of
                                    RoleAdmissionRefused detail ->
                                        assertBool
                                            "the deterministic refusal names the protected-store mismatch"
                                            ("protected store" `Text.isInfixOf` detail)
                                    otherOutcome ->
                                        assertFailure
                                            ( "expected a cross-store refusal, got "
                                                ++ describeAdmission otherOutcome
                                            )
                        )
                either (assertFailure . activationErrorMessage) pure refused

                -- If the hostile attempt touched this record, the correctly
                -- verified activation will report recovery instead of reserving.
                admitted <-
                    verifyRuntimeRoleActivation
                        key
                        other
                        manifest
                        manifest
                        grant
                        baseMeasurement
                        ( \activation ->
                            withVerifiedDraft activation listenerDraft $ \verified -> do
                                outcome <-
                                    entry other $ \session ->
                                        withRoleLifecycleAdmission session activation verified
                                case outcome of
                                    RoleAdmissionReserved _ -> pure ()
                                    otherOutcome ->
                                        assertFailure
                                            ( "the refused attempt mutated the target store: "
                                                ++ describeAdmission otherOutcome
                                            )
                        )
                either (assertFailure . activationErrorMessage) pure admitted
    , testCase "an origin-A reservation cannot consume a same-shaped store-B row" $ do
        let manifest =
                baseManifest
                    { manifestPermittedEffects = servingEffects
                    , manifestRolePlanDigest = rolePlanDraftDigest listenerDraft
                    }
        withBroker manifest $ \broker origin key -> do
            signed <- signActivationManifest broker manifest
            grant <- either (assertFailure . activationErrorMessage) pure signed
            withIndependentStore $ \other -> do
                -- Reserve the same semantic admission in B first.  Both fresh
                -- records have version 1, so without the origin guard A's
                -- reservation would be able to consume B's row.
                prepared <-
                    verifyRuntimeRoleActivation
                        key
                        other
                        manifest
                        manifest
                        grant
                        baseMeasurement
                        ( \activation ->
                            withVerifiedDraft activation listenerDraft $ \verified -> do
                                outcome <-
                                    entry other $ \session ->
                                        withRoleLifecycleAdmission session activation verified
                                case outcome of
                                    RoleAdmissionReserved _ -> pure ()
                                    otherOutcome ->
                                        assertFailure
                                            ( "could not prepare store B: "
                                                ++ describeAdmission otherOutcome
                                            )
                        )
                either (assertFailure . activationErrorMessage) pure prepared

                hostile <-
                    verifyRuntimeRoleActivation
                        key
                        origin
                        manifest
                        manifest
                        grant
                        baseMeasurement
                        ( \activation ->
                            withVerifiedDraft activation listenerDraft $ \verified -> do
                                reserved <-
                                    entry origin $ \session ->
                                        withRoleLifecycleAdmission session activation verified
                                case reserved of
                                    RoleAdmissionReserved admission -> do
                                        attempted <-
                                            entry other $ \session ->
                                                withRuntimeRolePlan
                                                    session
                                                    activation
                                                    verified
                                                    admission
                                                    (\_ _ _ _ -> pure ())
                                        case attempted of
                                            Left (RoleAdmissionStoreOriginMismatch detail) ->
                                                assertBool
                                                    "the refusal names the protected-store mismatch"
                                                    ("protected store" `Text.isInfixOf` detail)
                                            otherOutcome ->
                                                assertFailure
                                                    ( "expected an origin refusal, got "
                                                        ++ describePlan otherOutcome
                                                    )
                                    otherOutcome ->
                                        assertFailure
                                            ( "could not reserve in store A: "
                                                ++ describeAdmission otherOutcome
                                            )
                        )
                either (assertFailure . activationErrorMessage) pure hostile

                intact <-
                    verifyRuntimeRoleActivation
                        key
                        other
                        manifest
                        manifest
                        grant
                        baseMeasurement
                        ( \activation ->
                            withVerifiedDraft activation listenerDraft $ \verified -> do
                                outcome <-
                                    entry other $ \session ->
                                        withRoleLifecycleAdmission session activation verified
                                case outcome of
                                    RoleAdmissionReserved _ -> pure ()
                                    otherOutcome ->
                                        assertFailure
                                            ( "store B's row changed unexpectedly: "
                                                ++ describeAdmission otherOutcome
                                            )
                        )
                either (assertFailure . activationErrorMessage) pure intact
    , testCase "the reservation is consumed exactly once" $
        withActivationFor servingEffects listenerDraft $ \store activation ->
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
    , testCase "a lost open acknowledgement resumes the consumed plan without a new admission" $
        withActivationFor servingEffects listenerDraft $ \store activation ->
            withVerifiedDraft activation listenerDraft $ \verified -> do
                reserved <- entry store (\session -> withRoleLifecycleAdmission session activation verified)
                case reserved of
                    RoleAdmissionReserved admission -> do
                        opened <- entry store $ \session ->
                            withRuntimeRolePlan session activation verified admission $ \_ _ _ _ -> pure ()
                        opened @?= Right ()
                        retried <- entry store (\session -> withRoleLifecycleAdmission session activation verified)
                        case retried of
                            RoleAdmissionOpenUnknown _ -> pure ()
                            other -> assertFailure ("expected an open-unknown outcome, got " ++ describeAdmission other)
                        resumed <- entry store $ \session ->
                            resumeRuntimeRolePlanOpen session activation verified $ \plan binding _ _ ->
                                pure (rolePlanInstance plan, rolePlanDigestBindingRolePlanDigest binding)
                        resumed @?= Right ("pod:pod-uid-1/0", rolePlanDraftDigest listenerDraft)
                    other -> assertFailure ("expected a reservation, got " ++ describeAdmission other)
    , testCase "a malformed reservation row remains a store failure, not already consumed" $
        withActivationFor servingEffects listenerDraft $ \store activation ->
            withVerifiedDraft activation listenerDraft $ \verified -> do
                reserved <- entry store (\session -> withRoleLifecycleAdmission session activation verified)
                case reserved of
                    RoleAdmissionReserved admission -> do
                        let recordPath =
                                protectedStoreRoot store
                                    </> "records"
                                    </> (Text.unpack (reservedRoleAdmissionKey admission) <> ".rec")
                        ByteString.writeFile recordPath "not-a-protected-record"
                        attempted <-
                            entry store $ \session ->
                                withRuntimeRolePlan session activation verified admission $
                                    \_ _ _ _ -> pure ()
                        case attempted of
                            Left (RoleAdmissionStoreFailure ProtectedMalformedRecord{}) -> pure ()
                            other ->
                                assertFailure
                                    ( "expected a malformed-record store failure, got "
                                        ++ describePlan other
                                    )
                    other -> assertFailure ("expected a reservation, got " ++ describeAdmission other)
    , testCase "the binding reports the signed role-plan digest, not a recomputed plan" $
        withActivationFor servingEffects listenerDraft $ \store activation ->
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
        withActivationFor mutatingEffects storeDraft $ \store activation ->
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
    [ testCase "a role plan refuses another store before liveness or engine callbacks" $
        withRole mutatingEffects storeDraft $ \_ plan placement cursor ->
            withIndependentStore $ \other -> do
                trace <- newIORef []
                report <- runRoleLifecycle other plan placement cursor (tracingEngine trace)
                exitTurnedAtPhase report @?= Prereq
                exitReason report @?= Just "the role plan belongs to a different protected store"
                exitOwnedResources report @?= []
                exitUnknownResources report @?= []
                exitDrainFailures report @?= []
                readIORef trace >>= (@?= [])
    , testCase "a prerequisite refusal turns at Prereq and acquires nothing" $
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
            exitUnknownResources report @?= []
            assertBool "an unknown outcome is not a clean exit" (not (roleExitReportOk report))
            steps <- readIORef trace
            steps
                @?= [ "prereq"
                    , "acquire:listener"
                    , "acquire:worker"
                    , "release:listener"
                    , "release:worker"
                    ]
    , testCase "an asynchronous exception during acquisition is typed and still reaches Drain" $
        withRole servingEffects twoResourceDraft $ \store plan placement cursor -> do
            trace <- newIORef []
            report <-
                runRoleLifecycle store plan placement cursor $
                    (tracingEngine trace)
                        { engineAcquire = \required -> do
                            record trace ("acquire:" <> roleResourceName required)
                            if roleResourceName required == "worker" then throwIO ThreadKilled else pure Acquired
                        }
            exitTurnedAtPhase report @?= Acquire
            exitUnknownResources report @?= []
            steps <- readIORef trace
            assertBool "Drain released every possibly acquired resource" (["release:listener", "release:worker"] `isSuffixOfList` steps)
    , testCase "a delayed callback exception is forced inside the guarded transition" $
        withRole servingEffects listenerDraft $ \store plan placement cursor -> do
            trace <- newIORef []
            report <- runRoleLifecycle store plan placement cursor $
                (tracingEngine trace){engineAcquire = \_ -> pure (error "delayed acquisition failure")}
            exitTurnedAtPhase report @?= Acquire
            exitUnknownResources report @?= []
            readIORef trace >>= (@?= ["prereq", "release:listener"])
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
            assertBool "an orderly shutdown is a clean exit" (roleExitReportOk report)
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
    , testCase "the one-use cursor refuses a second run before it acquires anything" $
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
                        (maybe False (Text.isInfixOf "cursor was already consumed") (exitReason report))
            readIORef inner >>= (@?= [])
    , testCase "a distinct live exclusive instance is refused before acquisition" $ do
        let manifest = baseManifest
                { manifestPermittedEffects = mutatingEffects
                , manifestRolePlanDigest = rolePlanDraftDigest storeDraft
                }
            peerMeasurement = baseMeasurement{measuredInstance = KubernetesInstance "pod-uid-2" 0}
        withBroker manifest $ \broker store key -> do
            grant <- either (assertFailure . activationErrorMessage) pure =<< signActivationManifest broker manifest
            outerVerified <- verifyRuntimeRoleActivation key store manifest manifest grant baseMeasurement $ \outerActivation ->
                withVerifiedDraft outerActivation storeDraft $ \outerDraft -> do
                    peerVerified <- verifyRuntimeRoleActivation key store manifest manifest grant peerMeasurement $ \peerActivation ->
                        withVerifiedDraft peerActivation storeDraft $ \peerDraft ->
                            entry store $ \session -> do
                                outerReserved <- withRoleLifecycleAdmission session outerActivation outerDraft
                                peerReserved <- withRoleLifecycleAdmission session peerActivation peerDraft
                                case (outerReserved, peerReserved) of
                                    (RoleAdmissionReserved outerAdmission, RoleAdmissionReserved peerAdmission) ->
                                        do
                                          outerOpened <- withRuntimeRolePlan session outerActivation outerDraft outerAdmission $ \outerPlan _ outerPlacement outerCursor -> do
                                            peerOpened <- withRuntimeRolePlan session peerActivation peerDraft peerAdmission $ \peerPlan _ peerPlacement peerCursor -> do
                                                peer <- newIORef Nothing
                                                outerTrace <- newIORef []
                                                outerReport <- runRoleLifecycle store outerPlan outerPlacement outerCursor $
                                                    (tracingEngine outerTrace)
                                                        { engineServe = \_ -> do
                                                            peerTrace <- newIORef []
                                                            report <- runRoleLifecycle store peerPlan peerPlacement peerCursor (tracingEngine peerTrace)
                                                            writeIORef peer (Just (report, peerTrace))
                                                            pure ServeCompleted
                                                        }
                                                observed <- readIORef peer
                                                case observed of
                                                    Nothing -> assertFailure ("the distinct peer never ran: " <> renderRoleExitReport outerReport)
                                                    Just (report, peerTrace) -> do
                                                        exitTurnedAtPhase report @?= Prereq
                                                        assertBool "the live lease refusal is explicit" (maybe False (Text.isInfixOf "exclusive generation lease") (exitReason report))
                                                        readIORef peerTrace >>= (@?= [])
                                            either (assertFailure . roleLifecycleErrorMessage) pure peerOpened
                                          either (assertFailure . roleLifecycleErrorMessage) pure outerOpened
                                    other -> assertFailure ("could not reserve both instances: " <> show (describeAdmission (fst other), describeAdmission (snd other)))
                    either (assertFailure . activationErrorMessage) pure peerVerified
            either (assertFailure . activationErrorMessage) pure outerVerified
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
      ProtectedStore ->
      VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
      IO result
    ) ->
    IO result
withActivationFor effects draft use =
    let manifest =
            baseManifest
                { manifestPermittedEffects = effects
                , manifestRolePlanDigest = rolePlanDraftDigest draft
                }
     in withBroker manifest $ \broker store key -> do
        signed <- signActivationManifest broker manifest
        case signed of
            Left failure -> assertFailure (activationErrorMessage failure)
            Right grant -> do
                verified <-
                    verifyRuntimeRoleActivation
                        key
                        store
                        manifest
                        manifest
                        grant
                        baseMeasurement
                        (use store)
                either (assertFailure . activationErrorMessage) pure verified

withVerifiedDraft ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
    RolePlanDraft ->
    ( forall rolePlanDigest.
      VerifiedRolePlanDraft scope planDigest frame revision instanceId rolePlanDigest ->
      IO result
    ) ->
    IO result
withVerifiedDraft activation draft use =
    case verifyRolePlanDraft activation draft use of
        Left failure -> assertFailure (roleLifecycleErrorMessage failure)
        Right action -> action

-- | Verify one measured instance and return the key only after its admission
-- has been durably reserved.  Returning plain text keeps all generative
-- activation and draft indices inside their verification continuations.
reserveAdmissionKey ::
    ProtectedStore ->
    ActivationVerificationKey ->
    ActivationManifest ->
    ActivationGrant ->
    RuntimeMeasurement ->
    RolePlanDraft ->
    IO Text
reserveAdmissionKey store key manifest grant measurement draft = do
    verified <-
        verifyRuntimeRoleActivation
            key
            store
            manifest
            manifest
            grant
            measurement
            ( \activation ->
                withVerifiedDraft activation draft $ \verifiedDraft -> do
                    outcome <-
                        entry store $ \session ->
                            withRoleLifecycleAdmission session activation verifiedDraft
                    case outcome of
                        RoleAdmissionReserved admission ->
                            pure (reservedRoleAdmissionKey admission)
                        other ->
                            assertFailure
                                ("expected a reservation, got " ++ describeAdmission other)
            )
    either (assertFailure . activationErrorMessage) pure verified

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
    withActivationFor effects draft $ \store activation ->
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

-- | Run one protected transaction, failing the test on a store error.
entry :: ProtectedStore -> (forall session. ProtectedSession session -> IO result) -> IO result
entry store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    either (assertFailure . show) pure outcome

baseSecretBundle :: ByteString.ByteString
baseSecretBundle = "role=accelerator\ncredential=fixture-secret\n"

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
        , manifestSecretDigest = activationSecretDigestFromBytes baseSecretBundle
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
        , measuredSecretDigest = activationSecretDigestFromBytes baseSecretBundle
        , measuredInstance = KubernetesInstance "pod-uid-1" 0
        }

-- | A real root invocation, a real activation broker, and its installed key.
withBroker ::
    ActivationManifest ->
    ( forall scope brokerGeneration verb.
      ActivationBroker scope brokerGeneration verb ->
      ProtectedStore ->
      ActivationVerificationKey ->
      IO result
    ) ->
    IO result
withBroker manifest use = case activationSigningPolicy [manifest] of
    Left failure -> assertFailure (activationErrorMessage failure)
    Right policy ->
        withSystemTempDirectory "hostbootstrap-role-broker" $ \directory -> do
            opened <- openProtectedStore (directory </> "authority")
            case opened of
                Left failure -> assertFailure (show failure)
                Right store -> do
                    signing <-
                        case activationSigningKeyFromBytes (ByteString.replicate 32 73) of
                            Left failure -> assertFailure (activationErrorMessage failure)
                            Right key -> pure key
                    let provisioned = activationSigningVerificationKey signing
                    verification <-
                        case
                            activationVerificationKeyFromBytes
                                (activationVerificationKeyBytes provisioned) of
                            Left failure -> assertFailure (activationErrorMessage failure)
                            Right key -> pure key
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

withFixtureProject ::
    (forall projectId. Authority.InstalledProjectIdentity projectId -> IO result) ->
    IO result
withFixtureProject = Fixture.withFixtureInstalledProject

withIndependentStore :: (ProtectedStore -> IO result) -> IO result
withIndependentStore use =
    withSystemTempDirectory "hostbootstrap-role-other-store" $ \directory -> do
        opened <- openProtectedStore (directory </> "authority")
        either (assertFailure . show) use opened

-- ---------------------------------------------------------------------------
-- Small helpers

describe :: (Show failure) => Either failure () -> String
describe = either show (const "an accepted draft")

describeAdmission :: RoleAdmissionOutcome scope planDigest frame revision instanceId -> String
describeAdmission outcome = case outcome of
    RoleAdmissionReserved admission -> "reserved " ++ show (reservedRoleAdmissionKey admission)
    RoleAdmissionOpenUnknown key -> "open unknown " ++ show key
    RoleAdmissionRecoveryRequired key persisted -> "recovery owed " ++ show (key, persisted)
    RoleAdmissionRefused detail -> "refused " ++ show detail
    RoleAdmissionUnknown detail -> "unknown " ++ show detail

describePlan :: Either RoleLifecycleError () -> String
describePlan = either roleLifecycleErrorMessage (const "a second opened plan")

isSuffixOfList :: (Eq a) => [a] -> [a] -> Bool
isSuffixOfList needle haystack = needle == drop (length haystack - length needle) haystack
