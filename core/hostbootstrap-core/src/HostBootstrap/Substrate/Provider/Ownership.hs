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
patch (§ NN). A source guard holds the absence.
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
    attachOwnedShare,
    execInOwnedInstance,

    -- * The observation every clause is held against
    observeOwnedInstanceOrigin,
)
where

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
    localContext,
 )
import HostBootstrap.Ownership.Clause (Bound, Recorded, Releasable, recordedEvidence)
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
    parseOriginRecord,
    renderOriginRecord,
 )
import HostBootstrap.Ownership.Primitive (
    bindReportedIdentity,
    enterReportedObject,
    recordReportedOrigin,
    releaseReportedObject,
    reobserveReportedIdentity,
 )
import Data.ByteString (ByteString)
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    RecordKey,
    compareAndDeleteProtectedRecord,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    protectedErrorMessage,
    readProtectedRecord,
    recordKeyText,
 )
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
    startInstanceCommand,
    stopInstanceCommand,
 )
import HostBootstrap.Substrate.Provider.Report (
    ProviderConfigValue (ProviderConfigUnset, ProviderConfigValue),
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
    ProviderStandingConflict (InstanceReplaced),
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
ownedInstanceRecordKey = mkRecordKey . Text.pack . ownedInstanceName

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
provisionOwnedInstance cfg session key owned = do
    entered <- standingOf cfg session key owned
    case entered of
        Left fault -> pure (Left fault)
        Right (standing, _) -> case standing of
            InstanceOwned _ identity -> pure (Right (ProvisionAlreadyOwned identity))
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
    probe <- execInOwnedInstance cfg session key owned ["true"]
    pure $ case probe of
        Right run -> case classifyProviderReport providerReportLineBound (Right run) of
            Right _ -> Right answered
            Left (ProviderCommandExited _ diagnostic) -> Right (ReadyNotAnswering diagnostic)
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

{- | What stopping observed. -}
data ProviderStopOutcome
    = -- | the instance was running and this entry stopped it
      StopStopped ObjectIdentity
    | -- | the instance was already stopped
      StopAlreadyStopped ObjectIdentity
    | -- | the provider still reports it running after the stop it accepted
      StopStillRunning Text
    deriving (Eq, Show)

{- | Stop the owned instance, re-observing the bound identity around the act.

Stopping is not destructive, so it carries no name guard: what it carries is the
same standing every other transaction does, taken before the stop and again
after it, because a stop issued against a standing nobody rechecked is a
mutation of whatever now stands at the name.
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

{- | What deleting observed. -}
data ProviderDeleteOutcome
    = -- | the instance and every record of it are gone, and this entry did it
      DeleteRemoved
    | -- | there was nothing to remove and no record to forget
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
        Left fault -> pure (Left fault)
        Right (NothingDone, _) -> pure (Right DeleteAlreadyRemoved)
        Right (OriginRecorded _, _) -> forgetUnboundRecord session key
        Right (InstanceCreated _ _, _) -> pure (Left (notYetOwned owned))
        Right (InstanceOwned _ identity, observation) ->
            case fmap listedState (observedListing observation) of
                Nothing -> pure (Left (unlistedOwnedInstance owned))
                Just ProviderRunning -> pure (Right DeleteStillPresent)
                Just ProviderStopped ->
                    withBoundInstance session key owned identity $ \bound ->
                        case reobserveReportedIdentity bound (OriginPresent identity) of
                            Left fault -> pure (Left (ProviderOwnershipClause fault))
                            Right releasable -> removeInstance cfg session key owned identity releasable

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
    forgotten <- forgetRecord session key
    pure (fmap (const DeleteAlreadyRemoved) (collapseFault forgotten))

removeInstance ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    ObjectIdentity ->
    Releasable session object ->
    IO (Either ProviderOwnershipFault ProviderDeleteOutcome)
removeInstance cfg session key owned identity releasable = do
    shares <- releasableShares cfg session key owned
    case shares of
        Left fault -> pure (Left fault)
        Right pending -> case deleteInstanceCommand (ownedInstanceGuardPrefix owned) (ownedInstanceName owned) of
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
                                                releaseReportedObject releasable OriginAbsent (const (forgetRecord session key))
                                            pure (fmap (const DeleteRemoved) (collapseFault forgotten))

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
ownedShareRecordKey share =
    mkRecordKey (Text.pack (shareRecordKeyText (ownedShareInstance share) (ownedShareDevice share)))

shareRecordKeyText :: OwnedProviderInstance -> String -> String
shareRecordKeyText owned device = ownedInstanceName owned <> "." <> device

-- | The claim this run stamps on its share record.
ownedShareClaim :: OwnedProviderShare -> OwnerClaim
ownedShareClaim = mkOwnerClaim . TextEncoding.encodeUtf8 . ownedShareOwner

{- | What attaching observed. -}
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
                    stored <- readRecordUnder session shareKey
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
                                                (bindShare session shareKey recorded identity ShareRepaired)
                                    ShareDeviceOwned _ -> pure (Right ShareAlreadyAttached)
  where
    owned = ownedShareInstance share

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
                            (bindShare session shareKey recorded identity ShareAttached)

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
            Right ProviderConfigUnset -> Right ""
            Right (ProviderConfigValue value) -> Right (Text.unpack value)

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
                    (ReportedObject (ownedShareClaim share))
                    (publishFreshRecord session key)
            traverse continue recorded
    pure (collapseClause outcome)

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

{- | Every share record under this instance, re-observed and made releasable.

Taken before the instance is removed, because clause 4 re-observes the object it
bound and a device inside a deleted instance cannot be re-observed at all.
-}
releasableShares ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedProviderInstance ->
    IO (Either ProviderOwnershipFault [RecordKey])
releasableShares cfg session key owned = do
    keys <- listProtectedRecords session
    case keys of
        Left failure -> pure (Left (ProviderOwnershipStore failure))
        Right present -> do
            let mine =
                    sort
                        [ candidate
                        | candidate <- present
                        , (recordKeyText key <> ".") `Text.isPrefixOf` recordKeyText candidate
                        ]
            observed <- traverse (observeShareRecord cfg session owned) mine
            pure (fmap (const mine) (sequence_ observed))

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
observeShareRecord cfg session owned candidate = do
    stored <- readRecordUnder session candidate
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
                            (deviceOfRecordKey owned candidate)
                            ""
                            ""
                            ""
                        )
                pure $ case observed of
                    Left fault -> Left fault
                    Right OriginAbsent -> Left (shareConflict bound OriginAbsent)
                    Right (OriginPresent _) -> Right ()

deviceOfRecordKey :: OwnedProviderInstance -> RecordKey -> String
deviceOfRecordKey owned candidate =
    drop (length (ownedInstanceName owned) + 1) (Text.unpack (recordKeyText candidate))

-- | Forget every share record whose device the instance's removal took with it.
forgetReleasableShares ::
    ProtectedSession session ->
    [RecordKey] ->
    IO (Either ProviderOwnershipFault ())
forgetReleasableShares session = fmap sequence_ . traverse forget
  where
    forget candidate = collapseFault <$> forgetRecord session candidate

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
    [String] ->
    IO (Either ProviderOwnershipFault CapturedRun)
execInOwnedInstance cfg session key owned argv = do
    before <- ownedStanding cfg session key owned
    case before of
        Left fault -> pure (Left fault)
        Right (identity, _) -> do
            captured <- interpret cfg (guestCommand owned argv)
            after <- ownedStanding cfg session key owned
            pure $ case after of
                Left fault -> Left fault
                Right (settled, _)
                    | settled /= identity -> Left (replacedUnderGuestCommand identity settled)
                    | otherwise -> case captured of
                        Left refusal -> Left (ProviderOwnershipReport (ProviderCommandUnrun (Text.pack refusal)))
                        Right run -> Right run

guestCommand :: OwnedProviderInstance -> [String] -> HostCommand
guestCommand owned argv =
    foldLeafCommand
        (inVM (IncusVM (ownedInstanceName owned) (ownedInstanceImage owned)) localContext)
        (RawCmd argv)

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

The publication and the binding are both idempotent, so a re-entry re-asserts
exactly the facts the first entry established rather than discovering that its
own record is in the way.
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
    withRecordedOrigin session key owned $ \recorded -> do
        bound <- bindReportedIdentity recorded identity (publishBoundRecord session key)
        case collapseFault bound of
            Left fault -> pure (Left fault)
            Right token -> continue token

-- | Forget one durable record, whatever version the store currently holds.
forgetRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either OwnershipFault ())
forgetRecord session key = do
    current <- readProtectedRecord session key
    case current of
        Left failure -> pure (Left (storeFault "read the provider origin record" failure))
        Right Nothing -> pure (Right ())
        Right (Just stored) -> do
            forgotten <-
                compareAndDeleteProtectedRecord
                    session
                    key
                    (ExpectVersion (protectedRecordVersion stored))
            pure
                ( either
                    (Left . storeFault "forget the provider origin record")
                    (const (Right ()))
                    forgotten
                )

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
            stored <- readRecordUnder session key
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
    outcome <-
        enterReportedObject session (ownedInstanceName owned) OriginAbsent $ \entered -> do
            recorded <-
                recordReportedOrigin
                    entered
                    (ReportedObject (ownedInstanceClaim owned))
                    (publishFreshRecord session key)
            traverse continue recorded
    pure (collapseClause outcome)

{- | Bind clause 3's identity and answer with the outcome that describes it. -}
bindIdentity ::
    ProtectedSession session ->
    RecordKey ->
    Recorded session object ->
    ObjectIdentity ->
    outcome ->
    IO (Either ProviderOwnershipFault outcome)
bindIdentity session key recorded identity outcome = do
    bound <- bindReportedIdentity recorded identity (publishBoundRecord session key)
    pure (fmap (const outcome) (collapseFault bound))

{- | Publish clause 2's record, or accept the one this transaction already wrote.

Idempotent on purpose. A resumed entry has to mint its token honestly: a first
attempt is the compare-and-swap from absent, and a resumed one checks that what is
already there is this transaction's own record, so either way the token asserts
the one fact it names — this record is durable.

"This transaction's own" is the kind and the origin, not the bytes. A re-entry
over an instance a previous entry already /bound/ finds a record carrying clause
3's identity as well, and that record does not say something different: it says
the same thing plus one more fact this same transaction established. Comparing
bytes alone would refuse the re-entry every release and every dependent
transaction has to make. A record naming a different kind or a different prior
origin is somebody else's and is refused rather than replaced.
-}
publishFreshRecord ::
    ProtectedSession session ->
    RecordKey ->
    OriginRecord ->
    IO (Either OwnershipFault ())
publishFreshRecord session key record = do
    existing <- readProtectedRecord session key
    case existing of
        Left failure -> pure (Left (storeFault "read the provider origin record" failure))
        Right Nothing -> do
            written <- compareAndSwapProtectedRecord session key ExpectAbsent bytes
            pure
                ( either
                    (Left . storeFault "publish the provider origin record")
                    (const (Right ()))
                    written
                )
        Right (Just stored)
            | protectedRecordBytes stored == bytes -> pure (Right ())
            | otherwise -> pure (extendsThisRecord record (protectedRecordBytes stored) key)
  where
    bytes = renderOriginRecord record

{- | Whether the record already under this key is this transaction's own.

The binding is the one field a later step of the same transaction adds, so it is
the one field this comparison ignores.
-}
extendsThisRecord :: OriginRecord -> ByteString -> RecordKey -> Either OwnershipFault ()
extendsThisRecord record stored key = case parseOriginRecord stored of
    Left _ -> Left (foreignRecord key)
    Right held
        | originRecordKind held == originRecordKind record
        , originRecordOrigin held == originRecordOrigin record ->
            Right ()
        | otherwise -> Left (foreignRecord key)

{- | Publish the bound record against the exact version the store now holds.

Read back inside the same exclusive entry rather than carried out of the
publication continuation, so the store stays the one place a record version
lives.
-}
publishBoundRecord ::
    ProtectedSession session ->
    RecordKey ->
    OriginRecord ->
    IO (Either OwnershipFault ())
publishBoundRecord session key record = do
    current <- readProtectedRecord session key
    case current of
        Left failure -> pure (Left (storeFault "read the provider origin record" failure))
        Right Nothing ->
            pure
                ( Left
                    ( OwnershipProbeFailed
                        "bind the provider instance identity"
                        "the origin record vanished inside the exclusive entry"
                    )
                )
        Right (Just stored)
            | protectedRecordBytes stored == bytes -> pure (Right ())
            | otherwise -> do
                written <-
                    compareAndSwapProtectedRecord
                        session
                        key
                        (ExpectVersion (protectedRecordVersion stored))
                        bytes
                pure
                    ( either
                        (Left . storeFault "bind the provider instance identity")
                        (const (Right ()))
                        written
                    )
  where
    bytes = renderOriginRecord record

readRecordUnder ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either ProviderOwnershipFault (Maybe OriginRecord))
readRecordUnder session key = do
    stored <- readProtectedRecord session key
    pure $ case stored of
        Left failure -> Left (ProviderOwnershipStore failure)
        Right Nothing -> Right Nothing
        Right (Just record) ->
            case parseOriginRecord (protectedRecordBytes record) of
                Left fault -> Left (ProviderOwnershipClause fault)
                Right decoded -> Right (Just decoded)

foreignRecord :: RecordKey -> OwnershipFault
foreignRecord _key =
    OwnershipMalformed
        "the durable record under this instance's key is not the one this transaction publishes"

storeFault :: Text -> ProtectedError -> OwnershipFault
storeFault operation failure = OwnershipProbeFailed operation (protectedErrorMessage failure)

interpret :: HostConfig -> HostCommand -> IO (Either String CapturedRun)
interpret = interpretHostCommand

reported :: Either ProviderReportFault value -> Either ProviderOwnershipFault value
reported = either (Left . ProviderOwnershipReport) Right

{- | Carry the seam's own fault into this module's sum, keeping an inner refusal.

The clause producers answer in @'OwnershipFault'@ and the continuations beneath
them answer in this module's richer sum, so the two nest. Collapsing them here —
once — is what keeps every caller from writing its own.
-}
collapseClause ::
    Either OwnershipFault (Either ProviderOwnershipFault result) ->
    Either ProviderOwnershipFault result
collapseClause (Left fault) = Left (ProviderOwnershipClause fault)
collapseClause (Right inner) = inner

collapseFault :: Either OwnershipFault result -> Either ProviderOwnershipFault result
collapseFault = either (Left . ProviderOwnershipClause) Right
