{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

{- | One owner's durable origin-record operations, over one session and one subject.

The four-clause algebra is genuinely shared: every owner enters, records, binds
and releases through the one seam. What each owner supplied /to/ that seam was
not — publish a fresh record, publish the bound one, forget it, read it back —
and five owners had written the same four operations out by hand, differing only
in the words their refusals use.

They had drifted. Two copies produced different refusals for the same condition:
one named "this instance's key" and took a 'RecordKey' argument it never
printed, the other named "this key" and took none. The tape resolves that
deliberately. The key parameter is gone, because a parameter no message reads is
one a caller cannot get right or wrong; and the refusal names the /subject/,
which is the distinction the longer wording was reaching for. Every owner's
refusal therefore reads "the durable record under this key is not <its own
subject> this transaction publishes". A well-formed foreign record is occupied;
an uninterpretable envelope or origin body is malformed and stays intact.

The tape is not the clause algebra and grants nothing: it reads and writes one
key inside an exclusive entry a caller already holds. Which records may be
written, and in what order, is the seam's decision and stays there.
-}
module HostBootstrap.Ownership.Tape (
    -- * What an owner calls its records
    RecordSubject (..),

    -- * The tape
    RecordTape,
    recordTape,
    StoredOriginRecord,
    storedOriginRecord,
    storedRecordVersion,
    readStoredRecordUnder,
    publishFreshRecord,
    publishBoundRecord,
    forgetRecord,
    forgetRecordAtVersion,
    readRecordUnder,
    readVersionedRecordUnder,
    readRawRecordUnder,
    publishAbsentRawRecord,

    -- * Carrying clause results into a domain's own sum
    OwnershipCarrier (..),
    carryClause,
    carryClauseFault,
) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import HostBootstrap.Ownership.Object (
    OriginRecord,
    OwnershipFault (OwnershipOccupied, OwnershipProbeFailed),
    originRecord,
    originRecordKind,
    originRecordOrigin,
    parseOriginRecord,
    renderOriginRecord,
    storeFault,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    RecordKey,
    RecordVersion,
    compareAndDeleteProtectedRecord,
    compareAndSwapProtectedRecord,
    readProtectedRecord,
 )

{- | What one owner calls the object its records are about.

Two phrases, because a store failure is reported against the operation it
happened during and an owner has two: reading or writing its record, and binding
the identity it observed. Naming them here is what lets one implementation
answer in each owner's own words.
-}
data RecordSubject = RecordSubject
    { subjectRecord :: Text
    -- ^ e.g. @"the provider origin record"@
    , subjectBinding :: Text
    -- ^ e.g. @"bind the provider instance identity"@
    }
    deriving (Eq, Show)

-- | One owner's tape: the exclusive entry it holds, and what it calls its records.
data RecordTape session = RecordTape (ProtectedSession session) RecordSubject

recordTape :: ProtectedSession session -> RecordSubject -> RecordTape session
recordTape = RecordTape

{- | An origin body and its exact version, returned by this entry's store read.

Only readStoredRecordUnder mints this evidence. The nominal session index
prevents both passing it into another protected entry and coercing that index.
Plain decoded origin data remains useful for inspection, but carries no such
store-read provenance.
-}
type role StoredOriginRecord nominal

data StoredOriginRecord session = StoredOriginRecord RecordVersion OriginRecord
    deriving (Eq, Show)

-- These are ordinary functions: exported record selectors would allow a
-- caller to update a sealed read into an in-memory record or version.
storedRecordVersion :: StoredOriginRecord session -> RecordVersion
storedRecordVersion (StoredOriginRecord version _) = version

storedOriginRecord :: StoredOriginRecord session -> OriginRecord
storedOriginRecord (StoredOriginRecord _ record) = record

{- | Read the existing versioned decoder and seal its result to this entry.

Absence and both existing error layers are preserved. There is no second
decoder and no producer from a caller-supplied body or version.
-}
readStoredRecordUnder ::
    (OwnershipCarrier fault) =>
    RecordTape session ->
    RecordKey ->
    IO (Either fault (Maybe (StoredOriginRecord session)))
readStoredRecordUnder tape key =
    fmap (fmap (fmap (uncurry StoredOriginRecord))) (readVersionedRecordUnder tape key)

{- | Publish this transaction's record under a key nothing else holds.

Idempotent only over the exact bytes this write would publish. Even a record
with this kind and origin belongs to another transaction when it already
carries a binding; no fresh publication adopts that binding. A foreign record
is occupied and an uninterpretable body is malformed, both left intact.
-}
publishFreshRecord ::
    RecordTape session ->
    RecordKey ->
    OriginRecord ->
    IO (Either OwnershipFault ())
publishFreshRecord (RecordTape session subject) key record = do
    existing <- readProtectedRecord session key
    case existing of
        Left failure -> pure (Left (storeFault ("read " <> subjectRecord subject) failure))
        Right Nothing -> do
            written <- compareAndSwapProtectedRecord session key ExpectAbsent bytes
            pure
                ( either
                    (Left . storeFault ("publish " <> subjectRecord subject))
                    (const (Right ()))
                    written
                )
        Right (Just stored)
            | protectedRecordBytes stored == bytes -> pure (Right ())
            | otherwise -> pure (refuseOtherRecord subject (protectedRecordBytes stored))
  where
    bytes = renderOriginRecord record

{- | Publish the bound record against the exact version the store now holds.

Read back inside the same exclusive entry rather than carried out of the
publication continuation. Swap only over this record's exact unbound form;
identical bound bytes are already settled and keep their version. Any other
stored binding belongs to another transaction and is left intact.
-}
publishBoundRecord ::
    RecordTape session ->
    RecordKey ->
    OriginRecord ->
    IO (Either OwnershipFault ())
publishBoundRecord (RecordTape session subject) key record = do
    current <- readProtectedRecord session key
    case current of
        Left failure -> pure (Left (storeFault ("read " <> subjectRecord subject) failure))
        Right Nothing ->
            pure
                ( Left
                    ( OwnershipProbeFailed
                        (subjectBinding subject)
                        "the origin record vanished inside the exclusive entry"
                    )
                )
        Right (Just stored)
            | protectedRecordBytes stored == bytes -> pure (Right ())
            | protectedRecordBytes stored == unboundBytes -> do
                written <-
                    compareAndSwapProtectedRecord
                        session
                        key
                        (ExpectVersion (protectedRecordVersion stored))
                        bytes
                pure
                    ( either
                        (Left . storeFault (subjectBinding subject))
                        (const (Right ()))
                        written
                    )
            | otherwise -> pure (refuseOtherRecord subject (protectedRecordBytes stored))
  where
    bytes = renderOriginRecord record
    unboundBytes = renderOriginRecord (originRecord (originRecordKind record) (originRecordOrigin record))

{- | Remove the record under this key, if one is there.

An absent record is the settled state this asks for, so it is success rather
than a refusal: a release that ran twice reports the same thing both times.
An uninterpretable origin body is refused before deletion, preserving its bytes.
-}
forgetRecord ::
    RecordTape session ->
    RecordKey ->
    IO (Either OwnershipFault ())
forgetRecord tape key = forgetMatchingRecord tape key Nothing

{- | Forget only the version a caller read before its intervening work.

Absence is a version conflict here, rather than the settled state ordinary
forget accepts. Malformed envelopes and bodies are preserved on either route.
-}
forgetRecordAtVersion ::
    RecordTape session ->
    RecordKey ->
    RecordVersion ->
    IO (Either OwnershipFault ())
forgetRecordAtVersion tape key version = forgetMatchingRecord tape key (Just version)

-- | One read, origin validation and version-conditional delete for both forget routes.
forgetMatchingRecord ::
    RecordTape session ->
    RecordKey ->
    Maybe RecordVersion ->
    IO (Either OwnershipFault ())
forgetMatchingRecord (RecordTape session subject) key requested = do
    current <- readProtectedRecord session key
    case current of
        Left failure -> pure (Left (storeFault ("read " <> subjectRecord subject) failure))
        Right Nothing -> maybe (pure (Right ())) deleteExpected requested
        Right (Just stored) -> case parseOriginRecord (protectedRecordBytes stored) of
            Left fault -> pure (Left fault)
            Right _ -> deleteExpected (maybe (protectedRecordVersion stored) id requested)
  where
    deleteExpected version = do
        forgotten <- compareAndDeleteProtectedRecord session key (ExpectVersion version)
        pure
            ( either
                (Left . storeFault ("forget " <> subjectRecord subject))
                (const (Right ()))
                forgotten
            )

{- | Read the protected envelope without interpreting its origin body.

Acquisition uses presence alone to refuse an unsettled key. The store error
retains its domain constructor through 'fromStoreFault', just as decoded
read-back does; malformed origin bodies are interpreted only by the decoder.
-}
readRawRecordUnder ::
    (OwnershipCarrier fault) =>
    RecordTape session ->
    RecordKey ->
    IO (Either fault (Maybe ProtectedRecord))
readRawRecordUnder (RecordTape session _subject) key = do
    stored <- readProtectedRecord session key
    pure (either (Left . fromStoreFault) Right stored)

{- | Publish an ordinary metadata body only where no protected record exists.

The caller already holds this tape's exclusive entry. This operation grants no
origin or native-identity evidence and never replaces an existing record. Store
refusals retain the owner's error constructor, as raw reads do.
-}
publishAbsentRawRecord ::
    (OwnershipCarrier fault) =>
    RecordTape session ->
    RecordKey ->
    ByteString ->
    IO (Either fault ())
publishAbsentRawRecord (RecordTape session _subject) key bytes =
    fmap (either (Left . fromStoreFault) (const (Right ())))
        (compareAndSwapProtectedRecord session key ExpectAbsent bytes)

{- | Read the record under this key back, decoded, in the owner's own error sum.

A store failure is carried through fromStoreFault; an origin-body parse fault
through fromClauseFault. Publish and forget already deliver OwnershipFault,
including store failures classified by storeFault, so their bare carrier uses
fromClauseFault. The carrier preserves these declared domain error layers.
-}
readRecordUnder ::
    (OwnershipCarrier fault) =>
    RecordTape session ->
    RecordKey ->
    IO (Either fault (Maybe OriginRecord))
readRecordUnder tape key =
    fmap (fmap (fmap snd)) (readVersionedRecordUnder tape key)

{- | Decode the origin and retain the exact protected version from the same read.

A caller can carry this version across an external act and require it at forget,
without reading a second envelope or owning a second origin decoder.
-}
readVersionedRecordUnder ::
    (OwnershipCarrier fault) =>
    RecordTape session ->
    RecordKey ->
    IO (Either fault (Maybe (RecordVersion, OriginRecord)))
readVersionedRecordUnder tape key = do
    stored <- readRawRecordUnder tape key
    pure $ case stored of
        Left failure -> Left failure
        Right Nothing -> Right Nothing
        Right (Just record) ->
            case parseOriginRecord (protectedRecordBytes record) of
                Left fault -> Left (fromClauseFault fault)
                Right decoded -> Right (Just (protectedRecordVersion record, decoded))

-- | Refuse a different stored record without confusing occupancy with corruption.
refuseOtherRecord :: RecordSubject -> ByteString -> Either OwnershipFault ()
refuseOtherRecord subject stored = do
    _ <- parseOriginRecord stored
    Left (foreignRecord subject)

foreignRecord :: RecordSubject -> OwnershipFault
foreignRecord subject =
    OwnershipOccupied
        ( "the durable record under this key is not "
            <> subjectRecord subject
            <> " this transaction publishes"
        )

{- | How one domain's error sum carries the two faults beneath it.

The clause producers answer in 'OwnershipFault' and the store answers in
'ProtectedError', while each owner's continuations answer in its own richer sum.
Ten modules were writing both liftings out; one class per domain replaces them,
and 'carryClause' and 'carryClauseFault' are then written once rather than per owner.
-}
class OwnershipCarrier fault where
    fromClauseFault :: OwnershipFault -> fault
    fromStoreFault :: ProtectedError -> fault

{- | The seam's own fault sum carries both faults too.

An owner with no richer sum than the seam's — the shipped row answers in
'OwnershipFault' directly, because a transaction that crossed a frame has no
domain above it — reads its records through the same tape as everyone else
rather than through a fifth hand-written adapter.
-}
instance OwnershipCarrier OwnershipFault where
    fromClauseFault = id
    fromStoreFault = storeFault "read the durable ownership record"

{- | Collapse a clause producer's refusal and the continuation beneath it.

The clause producers answer in 'OwnershipFault' and their continuations in the
domain's own sum, so the two nest. Collapsing them here — once — is what keeps
every caller from writing its own.
-}
carryClause ::
    (OwnershipCarrier fault) =>
    Either OwnershipFault (Either fault result) ->
    Either fault result
carryClause (Left fault) = Left (fromClauseFault fault)
carryClause (Right inner) = inner

-- | Carry a clause refusal alone into the domain's sum.
carryClauseFault :: (OwnershipCarrier fault) => Either OwnershipFault result -> Either fault result
carryClauseFault = either (Left . fromClauseFault) Right
