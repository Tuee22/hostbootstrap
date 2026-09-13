{-# LANGUAGE OverloadedStrings #-}

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
subject> this transaction publishes".

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
    publishFreshRecord,
    publishBoundRecord,
    forgetRecord,
    readRecordUnder,

    -- * Carrying the two faults into a domain's own sum
    OwnershipCarrier (..),
    carryClause,
    carryStore,
) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import HostBootstrap.Ownership.Object (
    OriginRecord,
    OwnershipFault (OwnershipMalformed, OwnershipProbeFailed),
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

{- | Publish this transaction's record under a key nothing else holds.

Idempotent within the transaction: a record already present whose kind and
origin are this one's is this transaction's own earlier write, because the
binding is the single field a later step adds. Anything else under the key
belongs to someone else and is refused rather than overwritten.
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
            | otherwise -> pure (extendsThisRecord subject record (protectedRecordBytes stored))
  where
    bytes = renderOriginRecord record

{- | Publish the bound record against the exact version the store now holds.

Read back inside the same exclusive entry rather than carried out of the
publication continuation, so the store stays the one place a record version
lives.
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
            | otherwise -> do
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
  where
    bytes = renderOriginRecord record

{- | Remove the record under this key, if one is there.

An absent record is the settled state this asks for, so it is success rather
than a refusal: a release that ran twice reports the same thing both times.
-}
forgetRecord ::
    RecordTape session ->
    RecordKey ->
    IO (Either OwnershipFault ())
forgetRecord (RecordTape session subject) key = do
    current <- readProtectedRecord session key
    case current of
        Left failure -> pure (Left (storeFault ("read " <> subjectRecord subject) failure))
        Right Nothing -> pure (Right ())
        Right (Just stored) -> do
            forgotten <-
                compareAndDeleteProtectedRecord
                    session
                    key
                    (ExpectVersion (protectedRecordVersion stored))
            pure
                ( either
                    (Left . storeFault ("forget " <> subjectRecord subject))
                    (const (Right ()))
                    forgotten
                )

{- | Read the record under this key back, decoded, in the owner's own error sum.

A store failure and a malformed record are different answers and stay so: the
first says the store could not be read, the second that what it held is not a
record. Collapsing them would lose the distinction every caller's refusal makes.
-}
readRecordUnder ::
    (OwnershipCarrier fault) =>
    RecordTape session ->
    RecordKey ->
    IO (Either fault (Maybe OriginRecord))
readRecordUnder (RecordTape session _subject) key = do
    stored <- readProtectedRecord session key
    pure $ case stored of
        Left failure -> Left (fromStoreFault failure)
        Right Nothing -> Right Nothing
        Right (Just record) ->
            case parseOriginRecord (protectedRecordBytes record) of
                Left fault -> Left (fromClauseFault fault)
                Right decoded -> Right (Just decoded)

{- | Whether the record already under this key is this transaction's own.

The binding is the one field a later step of the same transaction adds, so it is
the one field this comparison ignores.
-}
extendsThisRecord :: RecordSubject -> OriginRecord -> ByteString -> Either OwnershipFault ()
extendsThisRecord subject record stored = case parseOriginRecord stored of
    Left _ -> Left (foreignRecord subject)
    Right held
        | originRecordKind held == originRecordKind record
        , originRecordOrigin held == originRecordOrigin record ->
            Right ()
        | otherwise -> Left (foreignRecord subject)

foreignRecord :: RecordSubject -> OwnershipFault
foreignRecord subject =
    OwnershipMalformed
        ( "the durable record under this key is not "
            <> subjectRecord subject
            <> " this transaction publishes"
        )

{- | How one domain's error sum carries the two faults beneath it.

The clause producers answer in 'OwnershipFault' and the store answers in
'ProtectedError', while each owner's continuations answer in its own richer sum.
Ten modules were writing both liftings out; one class per domain replaces them,
and 'carryClause' and 'carryStore' are then written once rather than per owner.
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
carryStore :: (OwnershipCarrier fault) => Either OwnershipFault result -> Either fault result
carryStore = either (Left . fromClauseFault) Right
