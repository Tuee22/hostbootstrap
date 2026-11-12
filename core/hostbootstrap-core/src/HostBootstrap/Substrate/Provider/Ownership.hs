{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The four ownership clauses, held over an instance a host provider owns.

@development_plan_standards.md § EE@ says a resource this project mutates is
owned under four clauses, and § LL says a provider is a __row__ of one frame
table rather than a module of parallel logic. This module is where the two meet
for a provider instance: clause 1 is the protected store's exclusive entry,
clause 2 that store's compare-and-swap, clause 3 the identity the provider
itself answers with, and clause 4 the conditional release the later transactions
hold over the same record.

Nothing here is written in another language. /What to ask/ the provider is a
described command ("HostBootstrap.Substrate.Provider.Command"), /what an answer
means/ is a total classification ("HostBootstrap.Substrate.Provider.Report"),
/where the transaction stands/ is a total function of three values
("HostBootstrap.Substrate.Provider.Resume"), and /what a clause is/ belongs to
the one seam ("HostBootstrap.Ownership.Primitive"). What is left for this module
is the order those compose in — and it can compose them in no other order,
because each clause token is produced from its predecessor.

The order matters most in the window a crash lands in. Clause 2's record is
published __before__ the launch and names this run's owner claim; the launch
carries that same claim, so an instance exists only ever naming the record that
made it. A run that dies between the two leaves a record and no instance, and one
that dies between the launch and the identity binding leaves an instance carrying
the claim of an unbound record. Neither is a mystery: both are standings, and the
same transaction re-enters both, because clause 2's publication is idempotent —
a first attempt is the store's compare-and-swap from absent and a resumed one is
a byte-equality check against the record already there.

Whether a record survives the crash at all is __not__ a question this module
answers. Every durable byte it publishes is the protected store's
compare-and-swap, so the partial-write, partial-fsync, and partial-unlink windows
belong to the store's own contract — the
[ownership-clauses-and-reservations phase](../../../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md)'s,
and covered there. This boundary inherits that contract by holding no durable
byte of its own: it names no mutating filesystem primitive, which is why there is
no instruction point here at which a second durability window could exist to
patch (§ NN). A source guard holds the absence across the provider facade and
its whole module subtree, and checks that this driver applies the record tape's
publications rather than merely importing their names.
-}
module HostBootstrap.Substrate.Provider.Ownership (
    -- * The instance a transaction owns
    OwnedProviderInstance (..),
    ownedInstanceClaim,
    ownedInstanceRecordKey,

    -- * The share a transaction owns
    OwnedProviderShare (..),
    ownedShareRecordKey,

    -- * What a transaction did
    ProviderProvisionOutcome (..),
    ProviderReadyOutcome (..),
    ProviderStopOutcome (..),
    ProviderDeleteOutcome (..),
    ProviderShareOutcome (..),

    -- * Why a transaction could not proceed
    ProviderOwnershipFault (..),
    providerOwnershipFaultMessage,

    -- * The transactions
    provisionOwnedInstance,
    readyOwnedInstance,
    stopOwnedInstance,
    deleteOwnedInstance,
    deleteRetainedOwnedInstance,
    attachOwnedShare,
    execInOwnedInstance,

    -- * The observation every clause is held against
    observeOwnedInstanceOrigin,
    observeOwnedShare,
)
where

import Control.Concurrent (threadDelay)
import HostBootstrap.Cluster.Cordon.Foundation (ResourceBudget)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (CapturedRun)
import HostBootstrap.Effect.Vocabulary (HostCommand)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lift (
    IncusVM (IncusVM),
    LiftLeaf (RawCmd),
    foldLeafCommand,
    inVM,
 )
import HostBootstrap.Lift.Context (emptyVMStack, vmContext)
import HostBootstrap.Ownership.Clause (Bound, Recorded, recordedEvidence)
import HostBootstrap.Ownership.Object (
    ConflictReport (ConflictReport, conflictExpected, conflictObserved, conflictSubject),
    ObjectIdentity,
    ObjectKind (ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OriginRecord,
    OwnerClaim,
    OwnershipFault (
        OwnershipConflict,
        OwnershipMalformed,
        OwnershipOccupied,
        OwnershipProbeFailed,
        OwnershipUnsupported
    ),
    mkObjectIdentity,
    mkOwnerClaim,
    originRecordBinding,
    originRecordKind,
    originRecordOrigin,
    ownerClaimText,
    ownershipFaultMessage,
 )
import HostBootstrap.Ownership.Primitive (
    bindReportedIdentity,
    enterReportedObject,
    reenterStoredReportedObject,
    recordReportedOrigin,
    releaseReportedObject,
    resumeReportedRemoval,
    reobserveReportedIdentity,
 )
import HostBootstrap.Ownership.Tape (
    OwnershipCarrier (fromClauseFault, fromStoreFault),
    RecordSubject (RecordSubject, subjectBinding, subjectRecord),
    RecordTape,
    carryClause,
    carryClauseFault,
    forgetRecord,
    publishBoundRecord,
    publishFreshRecord,
    readRecordUnder,
    readStoredRecordUnder,
    storedOriginRecord,
    recordTape,
 )
import HostBootstrap.Protected (
    ProtectedError (ProtectedInvalid),
    ProtectedSession,
    RecordKey,
    listProtectedRecords,
    mkRecordKey,
    mkRecordSegment,
    protectedErrorMessage,
    recordKeyText,
    recordNameIdentity,
    recordTupleSeparator,
 )
import HostBootstrap.Readiness (ProbeResult (NotReady), microsValue, pollSchedule, vmBootPoll)
import HostBootstrap.Substrate.Provider (RawProviderOutcome (RawProviderExit), classifyProviderProbe)
import System.Exit (ExitCode (ExitFailure))
import HostBootstrap.Substrate.Provider.Command (
    ProviderSizing,
    attachShareDeviceCommand,
    deleteInstanceCommand,
    launchInstanceCommand,
    listInstanceCommand,
    listShareDevicesCommand,
    providerIdentityConfigKey,
    providerOwnerConfigKey,
    readInstanceConfigCommand,
    readShareDeviceCommand,
    restartInstanceCommand,
    startInstanceCommand,
    stopInstanceCommand,
 )
import HostBootstrap.Substrate.Provider.Report (
    ProviderSizingObservation,
    incusSizingBudget,
    classifyIncusSizing,
    providerSizingMatches,
    declaredSizingText,
    observedSizingText,
    sizingConflictRemedy,
    ProviderConfigValue (ProviderConfigUnset),
    providerConfigValueText,
    ProviderListing (listedState),
    ProviderReportFault (ProviderCommandExited, ProviderCommandUnrun),
    ProviderRunState (ProviderRunning, ProviderStopped),
    classifyProviderConfigValue,
    classifyProviderIdentity,
    classifyProviderListing,
    classifyProviderReport,
    providerObservedOrigin,
    providerReportFaultMessage,
    providerReportLineBound,
 )
import HostBootstrap.Substrate.Provider.Resume (
    ProviderStanding (InstanceCreated, InstanceOwned, NothingDone, OriginRecorded),
    ProviderStandingConflict (InstanceReplaced, InstanceUnderAnotherClaim, InstanceVanished),
    providerStanding,
    providerStandingConflictMessage,
 )

-- ---------------------------------------------------------------------------
-- What is owned

{- | Everything a transaction needs to know about the instance it owns.

Four fields and no handle: a transaction reads its own record, asks the provider
its own questions, and decides from those, so nothing is carried in from a
previous call and kept correct.

The owner is this run's durable binding — its plan digest, resource key,
generation, and backend realization — and the claim is minted from it. That is
what makes a claim fresh in the only sense that matters: two attempts at one
generation derive the same claim and are the same transaction, while a new
generation derives a different one and owns a different instance.
-}
data OwnedProviderInstance = OwnedProviderInstance
    { ownedInstanceName :: String
    -- ^ the instance's own name, which is also its record's key
    , ownedInstanceImage :: String
    -- ^ the image a first launch creates it from
    , ownedInstanceGuardPrefix :: String
    -- ^ the project's destructive-delete guard prefix (§ LL)
    , ownedInstanceSizing :: ProviderSizing
    -- ^ what the instance is declared as
    , ownedInstanceOwner :: Text
    -- ^ this run's durable owner binding
    }
    deriving (Eq, Show)

{- | The claim this run stamps on the instance.

Derived rather than drawn from a generator, so a resumed entry mints exactly the
claim the entry that published the record did and can therefore recognize its own
half-made instance.
-}
ownedInstanceClaim :: OwnedProviderInstance -> OwnerClaim
ownedInstanceClaim = mkOwnerClaim . TextEncoding.encodeUtf8 . ownedInstanceOwner

{- | The protected-store key this instance's durable record lives under.

The instance name, because that is what the plan declares and what the provider
answers about. A second naming scheme would be a second way to fail to find the
record a previous entry wrote.
-}
ownedInstanceRecordKey :: OwnedProviderInstance -> Either ProtectedError RecordKey
ownedInstanceRecordKey owned =
    mkRecordSegment ("instance:" <> Text.pack (ownedInstanceName owned)) >>= mkRecordKey

-- ---------------------------------------------------------------------------
-- What a transaction did

{- | What provisioning established, and how far it had to go.

Three of the four are the same end state reached by different histories, and an
operator reading a run wants to know which: a first launch, a resumed entry whose
instance already existed, and an entry that found all three clauses held. The
fourth is not an end state at all — it is an instance no record of this project's
claims — and it is reported rather than adopted.
-}
data ProviderProvisionOutcome
    = -- | this entry launched the instance and bound its identity
      ProvisionCreated ObjectIdentity
    | -- | a previous entry launched it; this one bound the identity
      ProvisionRecovered ObjectIdentity
    | -- | clauses 1 through 3 were already held over this instance
      ProvisionAlreadyOwned ObjectIdentity
    deriving (Eq, Show)

{- | What readiness observed.

A guest that does not answer is an observation rather than a failure: an instance
that has just been started is not answering /yet/, and the caller's bounded poll
decides whether that is still true a moment later.
-}
data ProviderReadyOutcome
    = -- | the instance was stopped, this entry started it, and its guest answers
      ReadyStarted ObjectIdentity
    | -- | the instance was already running and its guest answers
      ReadyAlready ObjectIdentity
    | -- | the instance is running and its guest does not answer yet
      ReadyNotAnswering Text
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Why a transaction could not proceed

{- | The closed set of reasons a transaction stopped short of an outcome.

Four, and each names a different authority: the protected store, the provider's
own report, the standing three values decide, and the seam that mints the clause
tokens. A driver above this module maps them onto its own vocabulary through the
one renderer, so no reason is described twice.
-}
data ProviderOwnershipFault
    = -- | the protected store could not be read or written
      ProviderOwnershipStore ProtectedError
    | -- | the provider's answer is not one this vocabulary admits
      ProviderOwnershipReport ProviderReportFault
    | -- | the three facts do not describe a transaction this run may continue
      ProviderOwnershipStanding ProviderStandingConflict
    | -- | the owned instance's sizing differs from the current declaration
      ProviderOwnershipSizing ResourceBudget ProviderSizingObservation
    | -- | a clause could not be held
      ProviderOwnershipClause OwnershipFault
    deriving (Eq, Show)

-- | One rendering, so no caller writes a second description of a refusal.
providerOwnershipFaultMessage :: ProviderOwnershipFault -> Text
providerOwnershipFaultMessage fault = case fault of
    ProviderOwnershipStore inner -> protectedErrorMessage inner
    ProviderOwnershipReport inner -> providerReportFaultMessage inner
    ProviderOwnershipStanding inner -> providerStandingConflictMessage inner
    ProviderOwnershipClause inner -> ownershipFaultMessage inner
    ProviderOwnershipSizing declared observed ->
        "declared " <> declaredSizingText declared <> "; observed " <> observedSizingText observed
            <> "; " <> sizingConflictRemedy

-- ---------------------------------------------------------------------------
-- What the provider is currently reporting

{- | The one observation every clause over this instance is held against.

Whether the provider lists the instance and in which state, what stable identity
it answers with, and what claim it carries — asked once. Asked separately at each
call site, these become answers about different moments that disagree with each
other.
-}
data ProviderObservation = ProviderObservation
    { observedListing :: Maybe ProviderListing
    , observedOrigin :: Origin
    , observedClaim :: ProviderConfigValue
    }

{- | What the provider says is there, for a caller that must decide whether to
act at all.

Exported because a dependent operation's precondition asks exactly this question,
and a second asker would be a second answer.
-}
observeOwnedInstanceOrigin ::
    HostConfig ->
    OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault Origin)
observeOwnedInstanceOrigin cfg owned =
    fmap (fmap observedOrigin) (observeInstance cfg owned)

observeInstance ::
    HostConfig ->
    OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault ProviderObservation)
observeInstance cfg owned = do
    listed <- classifyProviderListing name <$> interpret cfg (listInstanceCommand name)
    case listed of
        Left fault -> pure (Left (ProviderOwnershipReport fault))
        Right Nothing ->
            pure (Right (ProviderObservation Nothing OriginAbsent ProviderConfigUnset))
        Right (Just listing) -> do
            identified <- classifyProviderIdentity <$> configValue cfg name providerIdentityConfigKey
            claimed <- classifyProviderConfigValue <$> configValue cfg name providerOwnerConfigKey
            pure $ reported $ do
                identity <- identified
                claim <- claimed
                origin <- providerObservedOrigin (Just listing) identity
                Right (ProviderObservation (Just listing) origin claim)
  where
    name = ownedInstanceName owned

configValue :: HostConfig -> String -> String -> IO (Either String CapturedRun)
configValue cfg name key = interpret cfg (readInstanceConfigCommand name key)

-- ---------------------------------------------------------------------------
-- Provisioning

{- | Hold clauses 1 through 3 over the instance, launching it if it is not there.

The caller supplies the exclusive entry, because clause 1 is the store's and one
entry covers a whole transaction. Everything after it is this module's, in the
only order the tokens admit: observe, decide where the transaction stands,
publish the record, launch under its claim, re-observe, bind.
-}
provisionOwnedInstance ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault ProviderProvisionOutcome)
provisionOwnedInstance cfg session key owned =
    case incusSizingBudget (ownedInstanceSizing owned) of
        Left fault -> pure (Left (ProviderOwnershipReport fault))
        Right _ -> provisionSizedInstance cfg session key owned

provisionSizedInstance ::
    HostConfig -> ProtectedSession session -> RecordKey -> OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault ProviderProvisionOutcome)
provisionSizedInstance cfg session key owned = do
    entered <- standingOf cfg session key owned
    case entered of
        Left fault -> pure (Left fault)
        Right (standing, _) -> case standing of
            InstanceOwned claim identity
                | claim == ownedInstanceClaim owned -> checkOwnedInstanceSizing cfg session key owned identity
                | otherwise ->
                    pure
                        ( Left
                            ( ProviderOwnershipStanding
                                ( InstanceUnderAnotherClaim
                                    (ownerClaimText (ownedInstanceClaim owned))
                                    (ownerClaimText claim)
                                )
                            )
                        )
            NothingDone ->
                withRecordedOrigin session key owned (launchThenBind cfg session key owned)
            OriginRecorded _ ->
                withRecordedOrigin session key owned (launchThenBind cfg session key owned)
            InstanceCreated _ _ ->
                withRecordedOrigin
                    session
                    key
                    owned
                    (bindObservedIdentity cfg session key owned ProvisionRecovered)

-- | Compare retained limits while holding and rechecking the exact owned binding.
checkOwnedInstanceSizing ::
    HostConfig -> ProtectedSession session -> RecordKey -> OwnedProviderInstance -> ObjectIdentity ->
    IO (Either ProviderOwnershipFault ProviderProvisionOutcome)
checkOwnedInstanceSizing cfg session key owned identity =
    withBoundInstance session key owned identity $ \bound -> do
        cpu <- configValue cfg name "limits.cpu"
        memory <- configValue cfg name "limits.memory"
        storage <- interpret cfg (readShareDeviceCommand name "root" "size")
        fresh <- standingOf cfg session key owned
        pure $ do
            (current, observation) <- fresh
            _ <- either (Left . ProviderOwnershipClause) Right
                (reobserveReportedIdentity bound (observedOrigin observation))
            case current of
                InstanceOwned claim actual
                    | claim == ownedInstanceClaim owned && actual == identity -> Right ()
                    | otherwise -> Left (ProviderOwnershipStanding
                        (InstanceUnderAnotherClaim (ownerClaimText (ownedInstanceClaim owned)) (ownerClaimText claim)))
                _ -> Left (ProviderOwnershipClause
                    (OwnershipOccupied "the retained provider origin changed during sizing readback"))
            declared <- reported (incusSizingBudget (ownedInstanceSizing owned))
            observed <- reported (classifyIncusSizing cpu memory storage)
            if providerSizingMatches declared observed
                then Right (ProvisionAlreadyOwned identity)
                else Left (ProviderOwnershipSizing declared observed)
  where
    name = ownedInstanceName owned

{- | Launch the instance under its record's claim, then bind what comes back.

The claim rides on the launch itself, so the instance names the record that made
it from the moment it exists; a configuration write that followed the launch
would leave an interval in which it named nothing.
-}
launchThenBind ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    Recorded session object ->
    IO (Either ProviderOwnershipFault ProviderProvisionOutcome)
launchThenBind cfg session key owned recorded = do
    launched <-
        interpret
            cfg
            ( launchInstanceCommand
                (ownedInstanceName owned)
                (ownedInstanceImage owned)
                (ownedInstanceSizing owned)
                (Text.unpack (ownerClaimText (ownedInstanceClaim owned)))
            )
    case classifyProviderReport providerReportLineBound launched of
        Left fault -> pure (Left (ProviderOwnershipReport fault))
        Right _ -> bindObservedIdentity cfg session key owned ProvisionCreated recorded

{- | Bind clause 3 from what the provider reports after the creating command.

The re-observation goes back through the same standing decision, so "the launch
produced this record's instance" is the same judgement everywhere rather than a
second comparison written here.
-}
bindObservedIdentity ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    (ObjectIdentity -> ProviderProvisionOutcome) ->
    Recorded session object ->
    IO (Either ProviderOwnershipFault ProviderProvisionOutcome)
bindObservedIdentity cfg session key owned outcome recorded = do
    observed <- observeInstance cfg owned
    case observed of
        Left fault -> pure (Left fault)
        Right observation ->
            recordedEvidence
                ( \_target record ->
                    case providerStanding (Just record) (observedOrigin observation) (observedClaim observation) of
                        Left conflict -> pure (Left (ProviderOwnershipStanding conflict))
                        Right (InstanceCreated _ identity) ->
                            bindIdentity session key recorded identity (outcome identity)
                        Right (InstanceOwned _ identity) -> pure (Right (outcome identity))
                        Right _ -> pure (Left (launchLostItsInstance owned))
                )
                recorded

{- | The refusal a launch that answered without producing an instance earns.

A probe failure rather than a conflict, because nothing disagrees: the provider
reported success and then reported nothing at the name it was told to create.
-}
launchLostItsInstance :: OwnedProviderInstance -> ProviderOwnershipFault
launchLostItsInstance owned =
    ProviderOwnershipClause
        ( OwnershipProbeFailed
            "bind the provider instance identity"
            ( "the provider reported no instance named "
                <> Text.pack (ownedInstanceName owned)
                <> " after the launch it accepted"
            )
        )

-- ---------------------------------------------------------------------------
-- Readiness

{- | Re-observe the bound instance, start it if it is stopped, and probe its
guest.

Every step re-observes first: readiness is the precondition every dependent
mutation is taken under, so a start issued against a standing nobody rechecked
would be a mutation of whatever now stands at the name.
-}
readyOwnedInstance ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault ProviderReadyOutcome)
readyOwnedInstance cfg session key owned = do
    entered <- ownedStanding cfg session key owned
    case entered of
        Left fault -> pure (Left fault)
        Right (identity, observation) -> case fmap listedState (observedListing observation) of
            Just ProviderRunning -> probeGuest cfg session key owned (ReadyAlready identity)
            Just ProviderStopped -> do
                started <- interpret cfg (startInstanceCommand (ownedInstanceName owned))
                case classifyProviderReport providerReportLineBound started of
                    Left fault -> pure (Left (ProviderOwnershipReport fault))
                    Right _ -> do
                        restanding <- ownedStanding cfg session key owned
                        case restanding of
                            Left fault -> pure (Left fault)
                            Right (restarted, _) -> probeGuest cfg session key owned (ReadyStarted restarted)
            Nothing -> pure (Left (unlistedOwnedInstance owned))

{- | Ask the guest whether it answers, through the one in-instance runner.

Readiness is the precondition every dependent mutation is taken under, so the
answer has to be /this/ instance's: the probe therefore goes through
'execInOwnedInstance', which re-observes the bound identity on both sides of the
crossing and renders the crossing itself through the lift's own fold and no
second renderer (§ LL).  An instance replaced while the probe ran is then a
conflict rather than a readiness, which is the difference between a dependent
mutation entering this run's object and entering whatever now stands at the
name.
-}
probeGuest ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    ProviderReadyOutcome ->
    IO (Either ProviderOwnershipFault ProviderReadyOutcome)
probeGuest cfg session key owned answered = do
    probe <- execInOwnedInstance cfg session key owned "true" []
    pure $ case probe of
        Right run -> case classifyProviderReport providerReportLineBound (Right run) of
            Right _ -> Right answered
            Left fault@(ProviderCommandExited code diagnostic) ->
                case classifyProviderProbe (RawProviderExit (ExitFailure code) "" (Text.unpack diagnostic)) of
                    NotReady _ -> Right (ReadyNotAnswering diagnostic)
                    _ -> Left (ProviderOwnershipReport fault)
            Left fault -> Left (ProviderOwnershipReport fault)
        Left fault -> Left fault

{- | The standing readiness and every later transaction require: this record's
own instance, bound and present.
-}
ownedStanding ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault (ObjectIdentity, ProviderObservation))
ownedStanding cfg session key owned = do
    entered <- standingOf cfg session key owned
    pure $ case entered of
        Left fault -> Left fault
        Right (InstanceOwned _ identity, observation) -> Right (identity, observation)
        Right _ -> Left (notYetOwned owned)

notYetOwned :: OwnedProviderInstance -> ProviderOwnershipFault
notYetOwned owned =
    ProviderOwnershipClause
        ( OwnershipProbeFailed
            "act on the owned provider instance"
            ( "the durable record for "
                <> Text.pack (ownedInstanceName owned)
                <> " does not yet bind an instance this run owns"
            )
        )

unlistedOwnedInstance :: OwnedProviderInstance -> ProviderOwnershipFault
unlistedOwnedInstance owned =
    ProviderOwnershipClause
        ( OwnershipProbeFailed
            "read the owned provider instance state"
            ( "the provider bound an identity for "
                <> Text.pack (ownedInstanceName owned)
                <> " and lists no instance under that name"
            )
        )

-- ---------------------------------------------------------------------------
-- Stopping

-- | What stopping observed.
data ProviderStopOutcome
    = -- | the instance was running and this entry stopped it
      StopStopped ObjectIdentity
    | -- | the instance was already stopped
      StopAlreadyStopped ObjectIdentity
    | -- | the provider still reports it running after the stop it accepted
      StopStillRunning Text
    deriving (Eq, Show)

{- | Stop the owned instance, re-observing the bound identity around the act.

The forced stop powers the VM off without a clean guest shutdown and can lose
unflushed guest writes. It carries no name guard because this transaction
re-observes the exact owned instance's standing before and after the
name-addressed stop.
-}
stopOwnedInstance ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault ProviderStopOutcome)
stopOwnedInstance cfg session key owned = do
    entered <- ownedStanding cfg session key owned
    case entered of
        Left fault -> pure (Left fault)
        Right (identity, observation) -> case fmap listedState (observedListing observation) of
            Just ProviderStopped -> pure (Right (StopAlreadyStopped identity))
            Just ProviderRunning -> do
                stopped <- interpret cfg (stopInstanceCommand (ownedInstanceName owned))
                case classifyProviderReport providerReportLineBound stopped of
                    Left fault -> pure (Left (ProviderOwnershipReport fault))
                    Right _ -> do
                        restanding <- ownedStanding cfg session key owned
                        pure $ case restanding of
                            Left fault -> Left fault
                            Right (settled, after) -> case fmap listedState (observedListing after) of
                                Just ProviderStopped -> Right (StopStopped settled)
                                Just ProviderRunning ->
                                    Right (StopStillRunning "the provider still reports the instance running")
                                Nothing -> Left (unlistedOwnedInstance owned)
            Nothing -> pure (Left (unlistedOwnedInstance owned))

-- ---------------------------------------------------------------------------
-- Deleting

-- | What deleting observed.
data ProviderDeleteOutcome
    = -- | the instance and every record of it are gone, and this entry did it
      DeleteRemoved
    | -- | no instance needs removal; an unbound record may have been forgotten
      DeleteAlreadyRemoved
    | -- | the provider still reports the instance, so no record was forgotten
      DeleteStillPresent
    deriving (Eq, Show)

{- | Release the owned instance and every share attached to it (clause 4).

The order is clause 4's and is the only one the tokens admit: every object is
re-observed as the identity this run bound /before/ the destructive command,
the command runs once, and a record is forgotten only over a reported absence.
The shares go first because they are objects inside the instance: a share record
forgotten after its instance is gone could not have re-observed the device it
was bound to.

The destructive command itself is the frame table's one guarded delete (§ LL),
so a name outside the project's own namespace has no command at all rather than
a command that is not run.
-}
deleteOwnedInstance ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault ProviderDeleteOutcome)
deleteOwnedInstance cfg session key owned = do
    entered <- standingOf cfg session key owned
    case entered of
        Left (ProviderOwnershipStanding (InstanceVanished identity)) ->
            resumeAbsentInstance cfg session key owned (ownedInstanceClaim owned) identity
        Left fault -> pure (Left fault)
        Right (NothingDone, _) -> pure (Right DeleteAlreadyRemoved)
        Right (OriginRecorded _, _) -> forgetUnboundRecord session key
        Right (InstanceCreated claim _, _)
            | claim == ownedInstanceClaim owned -> bindCreatedThenDelete cfg session key owned claim
            | otherwise ->
                pure (Left (ProviderOwnershipStanding
                    (InstanceUnderAnotherClaim (ownerClaimText (ownedInstanceClaim owned)) (ownerClaimText claim))))
        Right (InstanceOwned _ identity, observation) ->
            case fmap listedState (observedListing observation) of
                Nothing -> pure (Left (unlistedOwnedInstance owned))
                Just ProviderRunning -> pure (Right DeleteStillPresent)
                Just ProviderStopped ->
                    withBoundInstance session key owned identity
                        (removeInstance cfg session key owned identity)

{- | Delete the instance named by the exact retained provider record.

Reverse interpretation does not possess a forward action's lexical managed
handle, but it does possess the provider store whose record is the durable
clause-2/3 authority.  Re-enter that record, derive its claim rather than
accepting one from the caller, and mint the clause tokens again before the
identity-conditional removal.  A running instance is stopped only after the
record, reported identity, and provider claim agree, then re-observed before
delete.  This is the reverse counterpart of 'provisionOwnedInstance'; it never
deletes a same-named instance for which the retained record does not answer.
-}
deleteRetainedOwnedInstance ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault ProviderDeleteOutcome)
deleteRetainedOwnedInstance cfg session key owned = do
    entered <- standingOf cfg session key owned
    case entered of
        Left (ProviderOwnershipStanding (InstanceVanished identity)) ->
            withRetainedInstanceClaim session key $ \claim ->
                resumeAbsentInstance cfg session key owned claim identity
        Left fault -> pure (Left fault)
        Right (NothingDone, _) -> pure (Right DeleteAlreadyRemoved)
        Right (OriginRecorded _, _) -> forgetUnboundRecord session key
        Right (InstanceCreated claim _, _) -> bindCreatedThenDelete cfg session key owned claim
        Right (InstanceOwned claim identity, observation) -> do
            stopped <- case fmap listedState (observedListing observation) of
                Nothing -> pure (Left (unlistedOwnedInstance owned))
                Just ProviderStopped -> pure (Right ())
                Just ProviderRunning -> do
                    result <- interpret cfg (stopInstanceCommand (ownedInstanceName owned))
                    case classifyProviderReport providerReportLineBound result of
                        Left fault -> pure (Left (ProviderOwnershipReport fault))
                        Right _ -> do
                            after <- standingOf cfg session key owned
                            pure $ case after of
                                Left fault -> Left fault
                                Right (InstanceOwned _ observedIdentity, observedState)
                                    | observedIdentity /= identity ->
                                        Left (ProviderOwnershipStanding (InstanceReplaced identity observedIdentity))
                                    | fmap listedState (observedListing observedState) == Just ProviderStopped -> Right ()
                                    | otherwise -> Left (ProviderOwnershipClause (OwnershipProbeFailed "stop the retained provider instance" "the provider remained running"))
                                Right _ -> Left (notYetOwned owned)
            case stopped of
                Left fault -> pure (Left fault)
                Right () ->
                    withBoundInstanceClaim session key owned claim identity
                        (removeInstance cfg session key owned identity)

-- | Bind the interrupted launch before the retained release stops and removes it.
bindCreatedThenDelete ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    OwnerClaim ->
    IO (Either ProviderOwnershipFault ProviderDeleteOutcome)
bindCreatedThenDelete cfg session key owned claim =
    withRecordedClaim session key owned claim $ \recorded -> do
        recovered <- bindObservedIdentity cfg session key owned ProvisionRecovered recorded
        case recovered of
            Left fault -> pure (Left fault)
            Right _ -> deleteRetainedOwnedInstance cfg session key owned

-- | A retained delete takes its claim from the record it is authorized to release.
withRetainedInstanceClaim ::
    ProtectedSession session ->
    RecordKey ->
    (OwnerClaim -> IO (Either ProviderOwnershipFault result)) ->
    IO (Either ProviderOwnershipFault result)
withRetainedInstanceClaim session key continue = do
    stored <- readRecordUnder (providerTape session) key
    case stored of
        Left fault -> pure (Left fault)
        Right (Just record) -> case originRecordKind record of
            ReportedObject claim -> continue claim
            _ -> pure (Left (ProviderOwnershipClause
                (OwnershipMalformed "the retained provider record describes a kernel object")))
        Right Nothing -> pure (Left (ProviderOwnershipClause
            (OwnershipProbeFailed "recover the retained provider removal"
                "the bound record vanished inside the exclusive entry")))

{- | Retire an unfinished removal only after validating records and fresh absence.

No provider device query is possible after its instance has gone. The exact
canonical share-record keys and their reported absent origins are checked in
the same protected entry, then the instance is observed afresh. Clause 4
retires those child records before the instance's retained binding.
-}
resumeAbsentInstance ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    OwnerClaim ->
    ObjectIdentity ->
    IO (Either ProviderOwnershipFault ProviderDeleteOutcome)
resumeAbsentInstance cfg session key owned claim identity =
    withBoundInstanceClaim session key owned claim identity $ \bound -> do
        pending <- absentInstanceShareRecords session key owned
        case pending of
            Left fault -> pure (Left fault)
            Right shares -> do
                fresh <- observeInstance cfg owned
                case fresh of
                    Left fault -> pure (Left fault)
                    Right observation -> do
                        released <- resumeReportedRemoval bound (observedOrigin observation) $ \_ -> do
                            forgotten <- traverse (forgetRecord (providerTape session)) shares
                            case sequence_ forgotten of
                                Left fault -> pure (Left fault)
                                Right () -> forgetRecord (providerTape session) key
                        pure (fmap (const DeleteRemoved) (carryClauseFault released))

absentInstanceShareRecords ::
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault [RecordKey])
absentInstanceShareRecords session key owned = do
    keys <- instanceShareRecordKeys session key
    case keys of
        Left fault -> pure (Left fault)
        Right candidates -> do
            checked <- traverse validate candidates
            pure (fmap (const candidates) (sequence_ checked))
  where
    validate candidate = case deviceOfRecordKey owned candidate of
        Left fault -> pure (Left (ProviderOwnershipStore fault))
        Right _ -> do
            stored <- readRecordUnder (providerTape session) candidate
            pure $ case stored of
                Left fault -> Left fault
                Right Nothing -> Right ()
                Right (Just record) -> case originRecordKind record of
                    ReportedObject _
                        | originRecordOrigin record == OriginAbsent -> Right ()
                    _ -> Left (ProviderOwnershipClause
                        (OwnershipMalformed "the retained provider share record is not a reported object over absence"))

{- | Forget a record whose instance was never created.

Clause 2 published it and nothing carried it further, so there is no object to
re-observe and nothing to remove: the honest release is to forget the record and
report that there was nothing there.
-}
forgetUnboundRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either ProviderOwnershipFault ProviderDeleteOutcome)
forgetUnboundRecord session key = do
    forgotten <- forgetRecord (providerTape session) key
    pure (fmap (const DeleteAlreadyRemoved) (carryClauseFault forgotten))

removeInstance ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    ObjectIdentity ->
    Bound session object ->
    IO (Either ProviderOwnershipFault ProviderDeleteOutcome)
removeInstance cfg session key owned identity bound = do
    shares <- releasableShares cfg session key owned
    case shares of
        Left fault -> pure (Left fault)
        Right pending -> do
            fresh <- observeInstance cfg owned
            case fresh of
                Left fault -> pure (Left fault)
                Right observation ->
                    case reobserveReportedIdentity bound (observedOrigin observation) of
                        Left fault -> pure (Left (ProviderOwnershipClause fault))
                        Right releasable -> deleteObserved pending releasable
  where
    deleteObserved pending releasable =
        case deleteInstanceCommand (ownedInstanceGuardPrefix owned) (ownedInstanceName owned) of
            Left refusal -> pure (Left (guardedDeleteRefused refusal))
            Right command -> do
                removed <- interpret cfg command
                case classifyProviderReport providerReportLineBound removed of
                    Left fault -> pure (Left (ProviderOwnershipReport fault))
                    Right _ -> do
                        observed <- observeInstance cfg owned
                        case observed of
                            Left fault -> pure (Left fault)
                            Right after -> case observedOrigin after of
                                OriginPresent standing
                                    | standing /= identity ->
                                        pure (Left (replacedUnderDelete identity standing))
                                    | otherwise -> pure (Right DeleteStillPresent)
                                OriginAbsent -> do
                                    forgottenShares <- forgetReleasableShares session pending
                                    case forgottenShares of
                                        Left fault -> pure (Left fault)
                                        Right () -> do
                                            forgotten <-
                                                releaseReportedObject releasable OriginAbsent (const (forgetRecord (providerTape session) key))
                                            pure (fmap (const DeleteRemoved) (carryClauseFault forgotten))

{- | The refusal an object that took the name during the delete earns.

Clause 4 compares the identity, not the name, so an object standing where this
run's instance was is somebody else's: it is reported and left exactly as it was
found, and no record is forgotten over it.
-}
replacedUnderDelete :: ObjectIdentity -> ObjectIdentity -> ProviderOwnershipFault
replacedUnderDelete expected observed =
    ProviderOwnershipStanding (InstanceReplaced expected observed)

guardedDeleteRefused :: String -> ProviderOwnershipFault
guardedDeleteRefused refusal =
    ProviderOwnershipClause
        (OwnershipUnsupported ("the guarded destructive delete refused: " <> Text.pack refusal))

-- ---------------------------------------------------------------------------
-- Sharing

{- | One host directory this run attaches to the instance as a disk device.

An owned object of its own, with its own durable record: a share that lived
inside the instance's record would be a second thing that record means, and a
resumed entry could not tell which of the two it had published.
-}
data OwnedProviderShare = OwnedProviderShare
    { ownedShareInstance :: OwnedProviderInstance
    -- ^ the instance the device is attached to
    , ownedShareDevice :: String
    -- ^ the device name, derived from the share's own binding
    , ownedShareSource :: FilePath
    -- ^ the host directory the device exposes
    , ownedShareTarget :: FilePath
    -- ^ where the guest sees it
    , ownedShareOwner :: Text
    -- ^ this share's own durable owner binding
    }
    deriving (Eq, Show)

-- | The protected-store key this share's durable record lives under.
ownedShareRecordKey :: OwnedProviderShare -> Either ProtectedError RecordKey
ownedShareRecordKey share = do
    instanceKey <- ownedInstanceRecordKey (ownedShareInstance share)
    device <- mkRecordSegment ("device:" <> Text.pack (ownedShareDevice share))
    mkRecordKey (recordKeyText instanceKey <> recordTupleSeparator <> device)

-- | The claim this run stamps on its share record.
ownedShareClaim :: OwnedProviderShare -> OwnerClaim
ownedShareClaim = mkOwnerClaim . TextEncoding.encodeUtf8 . ownedShareOwner

-- | What attaching observed.
data ProviderShareOutcome
    = -- | this entry attached the device and bound its identity
      ShareAttached
    | -- | a previous entry attached it; this one bound the identity
      ShareRepaired
    | -- | the device is attached and its identity is already bound
      ShareAlreadyAttached
    deriving (Eq, Show)

{- | Attach the share under its own four clauses.

The instance must be this run's, observed through the same standing every other
transaction uses, because a device attached to somebody else's instance is a
mutation of somebody else's object. Beyond that the shape is clause order again:
record, attach, re-observe, bind.

The instance standing is taken on __both__ sides of the device readback, exactly
as a guest crossing takes it on both sides of the command it runs. A device
readback answers for the device and for nothing about the instance the device
hangs in, so an instance replaced between the entry standing and the binding
would otherwise leave a record of this run's bound to a device inside somebody
else's object.
-}
attachOwnedShare ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderShare ->
    IO (Either ProviderOwnershipFault ProviderShareOutcome)
attachOwnedShare cfg session shareKey share = do
    instanceKey <- pure (ownedInstanceRecordKey owned)
    case instanceKey of
        Left failure -> pure (Left (ProviderOwnershipStore failure))
        Right key -> do
            entered <- ownedStanding cfg session key owned
            case entered of
                Left fault -> pure (Left fault)
                Right (instanceIdentity, _) -> do
                    observed <- observeShareDevice cfg share
                    stored <- readRecordUnder (providerTape session) shareKey
                    case (observed, stored) of
                        (Left fault, _) -> pure (Left fault)
                        (_, Left fault) -> pure (Left fault)
                        (Right deviceOrigin, Right record) ->
                            case shareStanding record deviceOrigin of
                                Left fault -> pure (Left fault)
                                Right standing -> case standing of
                                    ShareNothingDone -> attachThenBind cfg session key instanceIdentity shareKey share
                                    ShareOriginRecorded -> attachThenBind cfg session key instanceIdentity shareKey share
                                    ShareDeviceAttached identity ->
                                        withRecordedShare session shareKey share $ \recorded ->
                                            bindShareUnderInstance
                                                cfg
                                                session
                                                key
                                                instanceIdentity
                                                share
                                                ( restartShareThenBind
                                                    cfg
                                                    session
                                                    key
                                                    instanceIdentity
                                                    share
                                                    (bindShare session shareKey recorded identity ShareRepaired)
                                                )
                                    ShareDeviceOwned _ -> pure (Right ShareAlreadyAttached)
  where
    owned = ownedShareInstance share

{- | Reobserve an already bound share without attaching or repairing it.

The record must name this share's claim and bind the device the provider now
reports. The parent's identity is checked on both sides of the device read.
-}
observeOwnedShare ::
    HostConfig ->
    ProtectedSession session ->
    OwnedProviderShare ->
    IO (Either ProviderOwnershipFault ObjectIdentity)
observeOwnedShare cfg session share =
    case (ownedInstanceRecordKey owned, ownedShareRecordKey share) of
        (Left failure, _) -> pure (Left (ProviderOwnershipStore failure))
        (_, Left failure) -> pure (Left (ProviderOwnershipStore failure))
        (Right instanceKey, Right shareKey) -> do
            entered <- ownedStanding cfg session instanceKey owned
            case entered of
                Left fault -> pure (Left fault)
                Right (parentIdentity, _) -> do
                    device <- observeShareDevice cfg share
                    stored <- readRecordUnder (providerTape session) shareKey
                    case (device, stored) of
                        (Left fault, _) -> pure (Left fault)
                        (_, Left fault) -> pure (Left fault)
                        (Right origin, Right record) ->
                            case ownedShareObservation record origin of
                                Left fault -> pure (Left fault)
                                Right identity -> do
                                    final <- ownedStanding cfg session instanceKey owned
                                    pure $ case final of
                                        Left fault -> Left fault
                                        Right (observed, _)
                                            | observed == parentIdentity -> Right identity
                                            | otherwise -> Left (replacedUnderShareAttachment parentIdentity observed)
  where
    owned = ownedShareInstance share
    ownedShareObservation record origin = case record of
        Just row
            | originRecordKind row == ReportedObject (ownedShareClaim share)
            , originRecordOrigin row == OriginAbsent -> do
                standing <- shareStanding record origin
                case standing of
                    ShareDeviceOwned identity -> Right identity
                    _ -> Left missingBoundShare
        _ -> Left missingBoundShare
    missingBoundShare =
        ProviderOwnershipClause
            ( OwnershipProbeFailed
                "observe the owned provider share"
                "the exact share has no matching bound ownership record"
            )

attachThenBind ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    ObjectIdentity ->
    RecordKey ->
    OwnedProviderShare ->
    IO (Either ProviderOwnershipFault ProviderShareOutcome)
attachThenBind cfg session instanceKey instanceIdentity shareKey share =
    withRecordedShare session shareKey share $ \recorded -> do
        attached <-
            interpret
                cfg
                ( attachShareDeviceCommand
                    (ownedInstanceName (ownedShareInstance share))
                    (ownedShareDevice share)
                    (ownedShareSource share)
                    (ownedShareTarget share)
                )
        case classifyProviderReport providerReportLineBound attached of
            Left fault -> pure (Left (ProviderOwnershipReport fault))
            Right _ -> do
                observed <- observeShareDevice cfg share
                case observed of
                    Left fault -> pure (Left fault)
                    Right OriginAbsent -> pure (Left (attachLostItsDevice share))
                    Right (OriginPresent identity) ->
                        bindShareUnderInstance
                            cfg
                            session
                            instanceKey
                            instanceIdentity
                            share
                            ( restartShareThenBind
                                cfg
                                session
                                instanceKey
                                instanceIdentity
                                share
                                (bindShare session shareKey recorded identity ShareAttached)
                            )

{- | Activate an attached Incus VM disk before binding its ownership record.

The provider may accept @config device add@ while the running guest still sees
the underlying directory at the declared target.  A forced restart is therefore
part of the share's clause-3 publication: it runs only after the exact device
has been re-observed, and the instance identity and Running state are rechecked
before the share record can bind.  Recovery from a lost restart answer repeats
this idempotent boot boundary while the record remains unbound.
-}
restartShareThenBind ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    ObjectIdentity ->
    OwnedProviderShare ->
    IO (Either ProviderOwnershipFault ProviderShareOutcome) ->
    IO (Either ProviderOwnershipFault ProviderShareOutcome)
restartShareThenBind cfg session instanceKey expected share continue = do
    restarted <- interpret cfg (restartInstanceCommand (ownedInstanceName owned))
    case classifyProviderReport providerReportLineBound restarted of
        Left fault -> pure (Left (ProviderOwnershipReport fault))
        Right _ -> do
            standing <- ownedStanding cfg session instanceKey owned
            case standing of
                Left fault -> pure (Left fault)
                Right (observed, report)
                    | observed /= expected ->
                        pure (Left (replacedUnderShareAttachment expected observed))
                    | fmap listedState (observedListing report) == Just ProviderRunning ->
                        waitForShareGuest cfg session instanceKey owned expected continue
                    | otherwise ->
                        pure
                            ( Left
                                ( ProviderOwnershipClause
                                    ( OwnershipProbeFailed
                                        "activate the provider share device"
                                        "the provider accepted the restart but the owned instance is not running"
                                    )
                                )
                            )
  where
    owned = ownedShareInstance share

waitForShareGuest ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    ObjectIdentity ->
    IO (Either ProviderOwnershipFault ProviderShareOutcome) ->
    IO (Either ProviderOwnershipFault ProviderShareOutcome)
waitForShareGuest cfg session key owned expected continue = go (pollSchedule vmBootPoll)
  where
    go delays = do
        answered <- probeGuest cfg session key owned (ReadyAlready expected)
        case answered of
            Left fault -> pure (Left fault)
            Right (ReadyNotAnswering reason) -> case delays of
                [] ->
                    pure
                        ( Left
                            ( ProviderOwnershipClause
                                ( OwnershipProbeFailed
                                    "activate the provider share device"
                                    ("the restarted guest did not answer within the VM boot budget: " <> reason)
                                )
                            )
                        )
                delay : remaining -> do
                    threadDelay (microsValue delay)
                    go remaining
            Right _ -> continue

{- | Bind the share only while the instance it hangs in is still the entered one.

Clause 3 binds an identity to a record, and the record names a device __inside__
an instance. Re-observing the device says the device stands; it says nothing
about whose instance now carries it. The standing is therefore re-taken after
the device readback and before the binding, and a different identity there is a
conflict rather than an attachment.
-}
bindShareUnderInstance ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    ObjectIdentity ->
    OwnedProviderShare ->
    IO (Either ProviderOwnershipFault ProviderShareOutcome) ->
    IO (Either ProviderOwnershipFault ProviderShareOutcome)
bindShareUnderInstance cfg session instanceKey instanceIdentity share continue = do
    settled <- ownedStanding cfg session instanceKey (ownedShareInstance share)
    case settled of
        Left fault -> pure (Left fault)
        Right (observed, _)
            | observed == instanceIdentity -> continue
            | otherwise -> pure (Left (replacedUnderShareAttachment instanceIdentity observed))

replacedUnderShareAttachment :: ObjectIdentity -> ObjectIdentity -> ProviderOwnershipFault
replacedUnderShareAttachment expected observed =
    ProviderOwnershipClause
        ( OwnershipConflict
            ConflictReport
                { conflictSubject = "the provider instance a share device was attached to"
                , conflictExpected = OriginPresent expected
                , conflictObserved = OriginPresent observed
                }
        )

attachLostItsDevice :: OwnedProviderShare -> ProviderOwnershipFault
attachLostItsDevice share =
    ProviderOwnershipClause
        ( OwnershipProbeFailed
            "bind the provider share device identity"
            ( "the provider reported no device named "
                <> Text.pack (ownedShareDevice share)
                <> " after the attachment it accepted"
            )
        )

{- | Where one share's transaction stands.

Four prefixes of the same clause order the instance's own standing has, and one
fewer question: a device carries no claim of its own, because its /name/ is
derived from this share's binding and nothing else attaches a device under it.
-}
data ShareStanding
    = ShareNothingDone
    | ShareOriginRecorded
    | ShareDeviceAttached ObjectIdentity
    | ShareDeviceOwned ObjectIdentity

shareStanding ::
    Maybe OriginRecord ->
    Origin ->
    Either ProviderOwnershipFault ShareStanding
shareStanding Nothing OriginAbsent = Right ShareNothingDone
shareStanding Nothing (OriginPresent _) =
    Left
        ( ProviderOwnershipClause
            ( OwnershipOccupied
                "a device already stands at this share's name under no record of this project's"
            )
        )
shareStanding (Just record) observed = case (originRecordBinding record, observed) of
    (Nothing, OriginAbsent) -> Right ShareOriginRecorded
    (Nothing, OriginPresent identity) -> Right (ShareDeviceAttached identity)
    (Just bound, OriginAbsent) -> Left (shareConflict bound OriginAbsent)
    (Just bound, OriginPresent identity)
        | identity == bound -> Right (ShareDeviceOwned bound)
        | otherwise -> Left (shareConflict bound (OriginPresent identity))

shareConflict :: ObjectIdentity -> Origin -> ProviderOwnershipFault
shareConflict expected observed =
    ProviderOwnershipClause
        ( OwnershipConflict
            ConflictReport
                { conflictSubject = "the provider share device"
                , conflictExpected = OriginPresent expected
                , conflictObserved = observed
                }
        )

{- | What the provider currently reports about this share's device.

Present means the device is listed /and/ answers for the three properties the
declaration names; the identity is bound from those three, so a device that was
replaced under the same name is a different identity rather than the same one.
-}
observeShareDevice ::
    HostConfig ->
    OwnedProviderShare ->
    IO (Either ProviderOwnershipFault Origin)
observeShareDevice cfg share = do
    listed <- interpret cfg (listShareDevicesCommand instanceName)
    case classifyProviderReport providerReportLineBound listed of
        Left fault -> pure (Left (ProviderOwnershipReport fault))
        Right devices
            | ownedShareDevice share `notElem` devices -> pure (Right OriginAbsent)
            | otherwise -> do
                kind <- deviceProperty "type"
                source <- deviceProperty "source"
                target <- deviceProperty "path"
                pure $ do
                    kindValue <- kind
                    sourceValue <- source
                    targetValue <- target
                    fmap OriginPresent (shareDeviceIdentity kindValue sourceValue targetValue)
  where
    instanceName = ownedInstanceName (ownedShareInstance share)

    deviceProperty key = do
        captured <- interpret cfg (readShareDeviceCommand instanceName (ownedShareDevice share) key)
        pure $ case classifyProviderConfigValue captured of
            Left fault -> Left (ProviderOwnershipReport fault)
            Right value -> Right (maybe "" Text.unpack (providerConfigValueText value))

{- | The identity a device the provider reports carries.

A digest of exactly the three properties the declaration names, because the
provider mints no identifier for a device and the shape /is/ what distinguishes
the device this run attached from one that replaced it. Sixty-four hex
characters, which is what the identity vocabulary admits.
-}
shareDeviceIdentity :: String -> String -> String -> Either ProviderOwnershipFault ObjectIdentity
shareDeviceIdentity kind source target =
    either (Left . ProviderOwnershipClause) Right (mkObjectIdentity digest)
  where
    digest =
        convertToBase
            Base16
            (hash (TextEncoding.encodeUtf8 (Text.pack (kind <> "\n" <> source <> "\n" <> target))) :: Digest SHA256)

withRecordedShare ::
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderShare ->
    ( forall object.
      Recorded session object ->
      IO (Either ProviderOwnershipFault result)
    ) ->
    IO (Either ProviderOwnershipFault result)
withRecordedShare session key share continue = do
    outcome <-
        enterReportedObject session (ownedShareDevice share) OriginAbsent $ \entered -> do
            recorded <-
                recordReportedOrigin
                    entered
                    (ownedShareClaim share)
                    (publishFreshRecord (providerTape session) key)
            traverse continue recorded
    pure (carryClause outcome)

bindShare ::
    ProtectedSession session ->
    RecordKey ->
    Recorded session object ->
    ObjectIdentity ->
    ProviderShareOutcome ->
    IO (Either ProviderOwnershipFault ProviderShareOutcome)
bindShare = bindIdentity

-- ---------------------------------------------------------------------------
-- Releasing the shares an instance carries

{- | Validate the recorded share identities before removing their owned instance.

Each bound device must still be exact or already absent. This returns record
keys, not individual release tokens. The instance's conditional removal and
reported absence authorize retiring those child records afterwards.
-}
releasableShares ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault [RecordKey])
releasableShares cfg session key owned = do
    keys <- instanceShareRecordKeys session key
    case keys of
        Left fault -> pure (Left fault)
        Right mine -> do
            observed <- traverse (observeShareRecord cfg session owned) mine
            pure (fmap (const mine) (sequence_ observed))

instanceShareRecordKeys ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either ProviderOwnershipFault [RecordKey])
instanceShareRecordKeys session key = do
    keys <- listProtectedRecords session
    pure $ case keys of
        Left failure -> Left (ProviderOwnershipStore failure)
        Right present ->
            Right
                ( sort
                    [ candidate
                    | candidate <- present
                    , (recordKeyText key <> recordTupleSeparator <> "device.") `Text.isPrefixOf` recordKeyText candidate
                    ]
                )

{- | One share record beside the device the provider still reports for it.

The device must be exactly the identity the record bound: a share whose device
was replaced is a conflict that leaves both the device and the record alone.
-}
observeShareRecord ::
    HostConfig ->
    ProtectedSession session ->
    OwnedProviderInstance ->
    RecordKey ->
    IO (Either ProviderOwnershipFault ())
observeShareRecord cfg session owned candidate =
    case deviceOfRecordKey owned candidate of
        Left failure -> pure (Left (ProviderOwnershipStore failure))
        Right device -> do
            stored <- readRecordUnder (providerTape session) candidate
            case stored of
                Left fault -> pure (Left fault)
                Right Nothing -> pure (Right ())
                Right (Just record) -> case originRecordBinding record of
                    Nothing -> pure (Right ())
                    Just bound -> do
                        observed <-
                            observeShareDevice
                                cfg
                                ( OwnedProviderShare
                                    owned
                                    device
                                    ""
                                    ""
                                    ""
                                )
                        pure $ case observed of
                            Left fault -> Left fault
                            Right OriginAbsent -> Right ()
                            Right (OriginPresent identity)
                                | identity == bound -> Right ()
                                | otherwise -> Left (shareConflict bound (OriginPresent identity))

deviceOfRecordKey :: OwnedProviderInstance -> RecordKey -> Either ProtectedError String
deviceOfRecordKey owned candidate = do
    instanceKey <- ownedInstanceRecordKey owned
    encoded <- maybe invalid Right (Text.stripPrefix (recordKeyText instanceKey <> recordTupleSeparator) (recordKeyText candidate))
    device <- maybe invalid Right (Text.stripPrefix "device:" (recordNameIdentity encoded))
    reconstructed <-
        ownedShareRecordKey (OwnedProviderShare owned (Text.unpack device) "" "" "")
    if reconstructed == candidate then Right (Text.unpack device) else invalid
  where
    invalid :: Either ProtectedError result
    invalid = Left (ProtectedInvalid "the provider device record key is not canonical for this instance")

-- | Retire validated child records after the owned instance is reported absent.
forgetReleasableShares ::
    ProtectedSession session ->
    [RecordKey] ->
    IO (Either ProviderOwnershipFault ())
forgetReleasableShares session = fmap sequence_ . traverse forget
  where
    forget candidate = carryClauseFault <$> forgetRecord (providerTape session) candidate

-- ---------------------------------------------------------------------------
-- Running a command where the instance is

{- | Run one argument vector inside the owned instance.

The crossing itself is the lift's own fold and no second renderer (§ LL), and
the identity is re-observed on both sides of it: an instance replaced while the
command ran is a conflict rather than a result, because the bytes that came back
would be another object's.

The captured run is returned whole rather than classified, because what the
guest said means something to the driver that asked and nothing to this module.
-}
execInOwnedInstance ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    String ->
    [String] ->
    IO (Either ProviderOwnershipFault CapturedRun)
execInOwnedInstance cfg session key owned exe arguments = do
    before <- ownedStanding cfg session key owned
    case before of
        Left fault -> pure (Left fault)
        Right (identity, _) -> do
            captured <- case guestCommand owned exe arguments of
                Left refusal -> pure (Left refusal)
                Right command -> interpret cfg command
            after <- ownedStanding cfg session key owned
            pure $ case after of
                Left fault -> Left fault
                Right (settled, _)
                    | settled /= identity -> Left (replacedUnderGuestCommand identity settled)
                    | otherwise -> case captured of
                        Left refusal -> Left (ProviderOwnershipReport (ProviderCommandUnrun (Text.pack refusal)))
                        Right run -> Right run

guestCommand :: OwnedProviderInstance -> String -> [String] -> Either String HostCommand
guestCommand owned exe arguments =
    foldLeafCommand
        (vmContext (inVM (IncusVM (ownedInstanceName owned) (ownedInstanceImage owned)) emptyVMStack))
        (RawCmd exe arguments)

replacedUnderGuestCommand :: ObjectIdentity -> ObjectIdentity -> ProviderOwnershipFault
replacedUnderGuestCommand expected observed =
    ProviderOwnershipClause
        ( OwnershipConflict
            ConflictReport
                { conflictSubject = "the provider instance a guest command ran in"
                , conflictExpected = OriginPresent expected
                , conflictObserved = OriginPresent observed
                }
        )

-- ---------------------------------------------------------------------------
-- The shared re-entry

{- | Re-establish clauses 1 through 3 over an instance a previous entry bound.

Read back the durable record in the held entry and require the exact claim,
absent origin and bound identity this instance names. Reported re-entry mints
the existing binding without publishing fresh or bound bytes, so the record's
version remains unchanged. Absence or a different record is refused.
-}
withBoundInstance ::
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    ObjectIdentity ->
    ( forall object.
      Bound session object ->
      IO (Either ProviderOwnershipFault result)
    ) ->
    IO (Either ProviderOwnershipFault result)
withBoundInstance session key owned identity continue =
    withBoundInstanceClaim session key owned (ownedInstanceClaim owned) identity continue

withBoundInstanceClaim ::
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    OwnerClaim ->
    ObjectIdentity ->
    ( forall object.
      Bound session object ->
      IO (Either ProviderOwnershipFault result)
    ) ->
    IO (Either ProviderOwnershipFault result)
withBoundInstanceClaim session key owned claim identity continue = do
    stored <- readStoredRecordUnder (providerTape session) key
    case stored of
        Left fault -> pure (Left fault)
        Right Nothing ->
            pure
                (Left (ProviderOwnershipClause
                    (OwnershipProbeFailed "re-enter the provider origin record"
                        "the origin record vanished inside the exclusive entry")))
        Right (Just held)
            | originRecordKind (storedOriginRecord held) == ReportedObject claim
            , originRecordOrigin (storedOriginRecord held) == OriginAbsent
            , originRecordBinding (storedOriginRecord held) == Just identity -> do
                outcome <-
                    reenterStoredReportedObject session (ownedInstanceName owned) held
                        (\token -> Right <$> continue token)
                pure (carryClause outcome)
            | otherwise ->
                pure
                    (Left (ProviderOwnershipClause
                        (OwnershipOccupied
                            "the stored provider origin record does not match this instance claim and bound identity")))

{- | What this owner calls its records, for the tape's refusals.

The only thing the provider supplies to the shared store adapter: everything
else about publishing, binding, forgetting and reading a record back is the
same act every owner behind the seam performs.
-}
providerSubject :: RecordSubject
providerSubject =
    RecordSubject
        { subjectRecord = "the provider origin record"
        , subjectBinding = "bind the provider instance identity"
        }

providerTape :: ProtectedSession session -> RecordTape session
providerTape session = recordTape session providerSubject

instance OwnershipCarrier ProviderOwnershipFault where
    fromClauseFault = ProviderOwnershipClause
    fromStoreFault = ProviderOwnershipStore

-- ---------------------------------------------------------------------------
-- The shared steps

{- | Where the transaction stands, from the record, the report, and the claim.

One decision, taken in one place, so provision and readiness cannot come to
disagree about what an unbound record beside a present instance means.
-}
standingOf ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault (ProviderStanding, ProviderObservation))
standingOf cfg session key owned = do
    observed <- observeInstance cfg owned
    case observed of
        Left fault -> pure (Left fault)
        Right observation -> do
            stored <- readRecordUnder (providerTape session) key
            pure $ case stored of
                Left fault -> Left fault
                Right record ->
                    case providerStanding record (observedOrigin observation) (observedClaim observation) of
                        Left conflict -> Left (ProviderOwnershipStanding conflict)
                        Right standing -> Right (standing, observation)

{- | Hold clause 2 and continue under its token.

The origin recorded is an absence on every branch that reaches here, and that is
a fact rather than a simplification: an instance the provider names under no
record is refused by the standing before this point, so a record this vocabulary
writes was always published over nothing.
-}
withRecordedOrigin ::
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    ( forall object.
      Recorded session object ->
      IO (Either ProviderOwnershipFault result)
    ) ->
    IO (Either ProviderOwnershipFault result)
withRecordedOrigin session key owned continue = do
    withRecordedClaim session key owned (ownedInstanceClaim owned) continue

{- | Publish clause 2 or re-enter this claim's durable record.

'publishFreshRecord' accepts this kind and absent origin when the record already
extends the attempted publication, including a previous identity binding. The
continuation receives the same durable-record fact on a first entry and a retry.
-}
withRecordedClaim ::
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    OwnerClaim ->
    ( forall object.
      Recorded session object ->
      IO (Either ProviderOwnershipFault result)
    ) ->
    IO (Either ProviderOwnershipFault result)
withRecordedClaim session key owned claim continue = do
    outcome <-
        enterReportedObject session (ownedInstanceName owned) OriginAbsent $ \entered -> do
            recorded <-
                recordReportedOrigin
                    entered
                    claim
                    (publishFreshRecord (providerTape session) key)
            traverse continue recorded
    pure (carryClause outcome)

-- | Bind clause 3's identity and answer with the outcome that describes it.
bindIdentity ::
    ProtectedSession session ->
    RecordKey ->
    Recorded session object ->
    ObjectIdentity ->
    outcome ->
    IO (Either ProviderOwnershipFault outcome)
bindIdentity session key recorded identity outcome = do
    bound <- bindReportedIdentity recorded identity (publishBoundRecord (providerTape session) key)
    pure (fmap (const outcome) (carryClauseFault bound))

interpret :: HostConfig -> HostCommand -> IO (Either String CapturedRun)
interpret = interpretHostCommand

reported :: Either ProviderReportFault value -> Either ProviderOwnershipFault value
reported = either (Left . ProviderOwnershipReport) Right
