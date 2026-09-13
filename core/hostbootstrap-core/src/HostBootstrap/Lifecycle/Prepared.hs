{-# LANGUAGE OverloadedStrings #-}

{- | The durable half of a prepare, owned below both the session machinery that
records it and the reconcile machinery that consumes it.

'HostBootstrap.Lifecycle.Session' runs the prepare compare-and-swap and
'HostBootstrap.Reconcile' mints the prepared operation/preconditions pair, but
the module dependency runs @Session -> Authority -> Reconcile@, so neither can
name a type the other owns.  The evidence therefore lives here, in the one
module both can import (§ EE).

'PreparedGate' hides its constructor and has exactly one producer,
'recordDurableUnknown', which /performs/ the compare-and-swap that publishes an
operation's unknown phase.  The value cannot exist unless that exact durable
write landed, so an adapter can no longer be reached with a caller-supplied
attempt or journal version: the numbers on the gate are the ones the store
returned.

The gate carries the plan digest and operation key it was recorded under, and
'HostBootstrap.Reconcile.withPreparedOperation' checks both against the plan
descriptor it is preparing.  That is deliberately a value check rather than a
phantom index: a phantom parameter on this type would be freely instantiable by
whoever holds the value, so it would record the binding without enforcing it.
-}
module HostBootstrap.Lifecycle.Prepared (
    -- * The gate
    PreparedGate,
    preparedGatePlan,
    preparedGateOperation,
    preparedGateSession,
    preparedGateFence,
    preparedGateAttempt,
    preparedGateJournalVersion,
    preparedGateFields,
    preparedGateCommitment,

    -- * Its sole producer
    recordDurableUnknown,

    -- * Record encoding
    encodeFields,
    decodeFields,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Digest (frameWire, sha256Hex)
import Data.Word (Word64)
import HostBootstrap.Lifecycle.Prepared.Internal (
    PreparedGate,
    GateAttempt (GateAttempt),
    GateFence (GateFence),
    GateJournalVersion (GateJournalVersion),
    GateOperationKey (GateOperationKey),
    GatePlanDigest (GatePlanDigest),
    GateSession (GateSession),
    mintPreparedGate,
    preparedGateAttempt,
    preparedGateFence,
    preparedGateJournalVersion,
    preparedGateOperation,
    preparedGatePlan,
    preparedGateSession,
 )
import HostBootstrap.Protected (
    Expectation,
    ProtectedError,
    ProtectedSession,
    RecordKey,
    compareAndSwapProtectedRecord,
    recordVersionWord,
 )

-- ---------------------------------------------------------------------------
-- Record encoding

{- | Records are stored as newline-free, tab-separated fields. Field values are
constrained to the record-key alphabet plus a few punctuation characters, so a
value can never introduce a separator and shift the meaning of the fields after
it.
-}
{- | The six fields a gate commits to, in the one order every committer uses.

Two backends projected these fields independently and then hashed them
differently — one length-framed and digested, the other joined with a colon —
so one question had two answers, differing where nobody compared them. The
projection lives beside the gate because the gate is what it is about.
-}
preparedGateFields :: PreparedGate -> [Text]
preparedGateFields gate =
    [ preparedGatePlan gate
    , preparedGateOperation gate
    , preparedGateSession gate
    , Text.pack (show (preparedGateFence gate))
    , Text.pack (show (preparedGateAttempt gate))
    , Text.pack (show (preparedGateJournalVersion gate))
    ]

{- | The one commitment to a prepared gate.

Length-framed and digested rather than joined with a separator: a separator that
can appear inside a field admits two different gates with the same commitment,
and the fields here include an operation key and a session name that this
library does not constrain to exclude one. Framing removes the question rather
than answering it per-field.
-}
preparedGateCommitment :: PreparedGate -> Text
preparedGateCommitment gate =
    sha256Hex
        ( ByteString.concat
            (map (frameWire . TextEncoding.encodeUtf8) ("hostbootstrap/prepared-gate/v1" : preparedGateFields gate))
        )

encodeFields :: [Text] -> ByteString
encodeFields = ByteStringChar8.pack . Text.unpack . Text.intercalate "\t"

decodeFields :: ByteString -> [Text]
decodeFields = Text.splitOn "\t" . Text.pack . ByteStringChar8.unpack

{- | Publish one operation's unknown phase and mint the gate from the version
that write returned.

This is the only 'PreparedGate' producer.  It writes the exact four-field record
layout the session recovery classifier reads back — phase, session, fence,
attempt — so the bytes on disk and the indices on the gate cannot disagree, and
it needs a 'ProtectedSession', which exists only inside an exclusive protected
entry (§ EE clause 1).
-}
recordDurableUnknown ::
    ProtectedSession session ->
    -- | the operation's record
    RecordKey ->
    -- | the version this write must land against
    Expectation ->
    -- | the unknown phase to publish before the backend call
    Text ->
    -- | the plan digest this operation belongs to
    Text ->
    -- | the operation key
    Text ->
    -- | the recording operation session
    Text ->
    -- | the authoritative fence epoch
    Word64 ->
    -- | this attempt
    Word64 ->
    IO (Either ProtectedError PreparedGate)
recordDurableUnknown session key expectation phase plan operation sessionId fence attempt = do
    written <-
        compareAndSwapProtectedRecord
            session
            key
            expectation
            ( encodeFields
                [ phase
                , sessionId
                , Text.pack (show fence)
                , Text.pack (show attempt)
                ]
            )
    pure $ case written of
        Left failure -> Left failure
        Right journalVersion ->
            Right
                ( mintPreparedGate
                    (GatePlanDigest plan)
                    (GateOperationKey operation)
                    (GateSession sessionId)
                    (GateFence fence)
                    (GateAttempt attempt)
                    (GateJournalVersion (recordVersionWord journalVersion))
                )
