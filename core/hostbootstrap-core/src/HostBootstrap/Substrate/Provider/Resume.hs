{-# LANGUAGE OverloadedStrings #-}

{- | Where a provider ownership transaction stands, as one value.

The four clauses are one transaction but not one process. A run publishes its
durable record, launches an instance through the one interpreter (§ KK), and
binds the identity the provider answers with — and it can die between any two of
those. What the next entry does is decided entirely by three facts: the record
the protected store holds, the observation the provider's report produced
("HostBootstrap.Substrate.Provider.Report"), and the claim the instance carries.

This module is that decision, and it is a __total function of those three
values__. That matters because the interval between clause 2 and clause 3 is
precisely the interval a live test cannot reliably enter: reaching it needs a
process to die at an exact instruction. Written as a function it needs nothing
of the sort — every standing and every conflict is reached by handing it a value
(§ NN).

One vocabulary answers every verb. Provision, readiness, and release do not each
ask a differently shaped question; they ask the same one and act differently on
the answer. Written per verb, the three would drift in exactly the places nobody
compares — which of them treats a vanished instance as a conflict, which treats
an unclaimed one as adoptable.
-}
module HostBootstrap.Substrate.Provider.Resume (
    -- * Where the transaction stands
    ProviderStanding (..),
    standingClaim,
    standingIdentity,

    -- * Why it stands nowhere
    ProviderStandingConflict (..),
    providerStandingConflictMessage,

    -- * The decision
    providerStanding,
)
where

import Data.Text (Text)
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    ObjectKind (OwnedDirectory, OwnedFile, ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OriginRecord,
    OwnerClaim,
    objectIdentityText,
    originRecordBinding,
    originRecordKind,
    originRecordOrigin,
    ownerClaimText,
 )
import HostBootstrap.Substrate.Provider.Report (
    ProviderConfigValue (ProviderConfigUnset, ProviderConfigValue),
 )

-- ---------------------------------------------------------------------------
-- Where the transaction stands

{- | The four places a provider transaction can legitimately stand.

They are the four prefixes of the one clause order, and nothing else is
reachable: a record cannot exist without clause 1 having been held, a binding
cannot exist without a record, and an instance this project owns cannot exist
without a claim naming the record that made it.
-}
data ProviderStanding
    = -- | no record and no instance: nothing has happened yet
      NothingDone
    | -- | clause 2 is durable and the creating command has not taken effect
      OriginRecorded OwnerClaim
    | -- | the instance exists under this record's claim and clause 3 is not held
      InstanceCreated OwnerClaim ObjectIdentity
    | -- | clauses 1 through 3 are held: this is this record's instance
      InstanceOwned OwnerClaim ObjectIdentity
    deriving (Eq, Show)

-- | The claim the record names, where there is a record.
standingClaim :: ProviderStanding -> Maybe OwnerClaim
standingClaim NothingDone = Nothing
standingClaim (OriginRecorded claim) = Just claim
standingClaim (InstanceCreated claim _) = Just claim
standingClaim (InstanceOwned claim _) = Just claim

-- | The identity the provider answered with, where there is an instance.
standingIdentity :: ProviderStanding -> Maybe ObjectIdentity
standingIdentity NothingDone = Nothing
standingIdentity (OriginRecorded _) = Nothing
standingIdentity (InstanceCreated _ identity) = Just identity
standingIdentity (InstanceOwned _ identity) = Just identity

-- ---------------------------------------------------------------------------
-- Why it stands nowhere

{- | The closed set of states that are not a standing.

Each is a case where continuing would mean owning something this project did not
make. None is resolved here: a conflict is reported with both sides so an
operator learns which of them happened, because the seam's own rule is that a
conflict is reported rather than resolved.
-}
data ProviderStandingConflict
    = -- | an instance exists and no durable record claims it
      InstanceUnderNoRecord ObjectIdentity
    | -- | the instance carries a claim that is not this record's
      InstanceUnderAnotherClaim Text Text
    | -- | the record is bound and a different instance stands at the name
      InstanceReplaced ObjectIdentity ObjectIdentity
    | -- | the record is bound and its instance is gone
      InstanceVanished ObjectIdentity
    | -- | the record under this key describes something else entirely
      RecordNotAClaimedObject Text
    | -- | the record names an instance that was there before it
      RecordNamesAPriorInstance ObjectIdentity
    deriving (Eq, Show)

-- | One rendering, so a driver never writes a second description of a conflict.
providerStandingConflictMessage :: ProviderStandingConflict -> Text
providerStandingConflictMessage conflict = case conflict of
    InstanceUnderNoRecord observed ->
        "the provider names an instance "
            <> objectIdentityText observed
            <> " that no durable record claims, and this transaction adopts nothing it finds"
    InstanceUnderAnotherClaim expected observed ->
        "the instance carries the claim "
            <> observed
            <> " rather than this record's "
            <> expected
    InstanceReplaced expected observed ->
        "this record is bound to "
            <> objectIdentityText expected
            <> " and the provider now names "
            <> objectIdentityText observed
            <> " at the same instance"
    InstanceVanished expected ->
        "this record is bound to "
            <> objectIdentityText expected
            <> " and the provider names no instance at all"
    RecordNotAClaimedObject described ->
        "the record under this key describes " <> described
    RecordNamesAPriorInstance observed ->
        "the record names the prior instance "
            <> objectIdentityText observed
            <> ", so it was published over something it did not create"

-- ---------------------------------------------------------------------------
-- The decision

{- | Where this transaction stands, from the three facts that decide it.

The claim comparison is what makes the outcome-unknown window resolvable. An
instance that exists without carrying this record's claim is not this record's
instance, however much it looks like one: the name is the same by construction —
it is the name the plan declares — and the claim is the only thing that
distinguishes an instance this record created from one an earlier record left
behind.

An unset claim is therefore not a lenient case. The instance carries no tag at
all, which means nothing this project made it, so it is reported with the same
conflict as an instance carrying somebody else's.
-}
providerStanding ::
    -- | the durable record the protected store holds under this object's key
    Maybe OriginRecord ->
    -- | what the provider's report says is there
    Origin ->
    -- | the claim the instance carries, as the provider reported it
    ProviderConfigValue ->
    Either ProviderStandingConflict ProviderStanding
providerStanding Nothing observed _ = case observed of
    OriginAbsent -> Right NothingDone
    OriginPresent identity -> Left (InstanceUnderNoRecord identity)
providerStanding (Just record) observed carried = do
    claim <- claimOf record
    priorlessRecord record
    case (originRecordBinding record, observed) of
        (Nothing, OriginAbsent) -> Right (OriginRecorded claim)
        (Nothing, OriginPresent identity) ->
            InstanceCreated claim identity <$ sameClaim claim carried
        (Just bound, OriginAbsent) -> Left (InstanceVanished bound)
        (Just bound, OriginPresent identity)
            | identity /= bound -> Left (InstanceReplaced bound identity)
            | otherwise -> InstanceOwned claim bound <$ sameClaim claim carried

{- | The claim this record names, or the reason it names none.

A record under this key that describes a directory or a file was written by
another owner, and reading it as though it were this one's is exactly how a
driver comes to act on somebody else's record.
-}
claimOf :: OriginRecord -> Either ProviderStandingConflict OwnerClaim
claimOf record = case originRecordKind record of
    ReportedObject claim -> Right claim
    OwnedDirectory -> Left (RecordNotAClaimedObject "a directory")
    OwnedFile _ -> Left (RecordNotAClaimedObject "a file")

{- | A claimed-object record always records an absence.

Clause 1 refuses to record over an instance it found, so a record naming a prior
identity is one this vocabulary did not write.
-}
priorlessRecord :: OriginRecord -> Either ProviderStandingConflict ()
priorlessRecord record = case originRecordOrigin record of
    OriginAbsent -> Right ()
    OriginPresent identity -> Left (RecordNamesAPriorInstance identity)

{- | Require that the instance carries exactly this record's claim. -}
sameClaim :: OwnerClaim -> ProviderConfigValue -> Either ProviderStandingConflict ()
sameClaim claim carried = case carried of
    ProviderConfigValue observed
        | observed == ownerClaimText claim -> Right ()
        | otherwise -> Left (InstanceUnderAnotherClaim (ownerClaimText claim) observed)
    ProviderConfigUnset ->
        Left (InstanceUnderAnotherClaim (ownerClaimText claim) unclaimedInstance)

{- | What a conflict reads when the instance carries no claim at all.

A distinct word rather than an empty one, because "carries nothing" and "carries
the empty string" are different reports and an operator reading the refusal
needs to know which.
-}
unclaimedInstance :: Text
unclaimedInstance = "no claim at all"
