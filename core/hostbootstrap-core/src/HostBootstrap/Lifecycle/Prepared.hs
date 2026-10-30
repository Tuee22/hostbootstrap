{-# LANGUAGE OverloadedStrings #-}

{- | The durable half of a prepare, owned below both the session machinery that
records it and the reconcile machinery that consumes it.

'HostBootstrap.Lifecycle.Session' runs the prepare compare-and-swap and
'HostBootstrap.Reconcile' mints the prepared operation/preconditions pair, but
the module dependency runs @Session -> Authority -> Reconcile@, so neither can
name a type the other owns.  The evidence therefore lives here, in the one
module both can import (§ EE).

'PreparedGate' hides its constructor and exposes ordinary coordinate readers.
The local production producer, @Lifecycle.Session.withPreparedGate@, checks the
open journal permit, open session, operation registration, broker generation,
live fence and recorded phase. It publishes the unknown phase transactionally,
re-reads the committed operation record and only then mints the gate. The journal
version comes from that record; the producer checks or selects the other
coordinates.

'recordDurableUnknown' remains a lower-level writer of caller-supplied fields.
It performs the protected compare-and-swap and takes the gate's journal version
from its result; it does not perform the session producer's admission checks.

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

    -- * The retained durable writer
    recordDurableUnknown,

    -- * Record encoding
    encodeFields,
    decodeFields,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Digest (frameWire, sha256Hex)
import HostBootstrap.Lifecycle.Prepared.Internal (
    GateAttempt (GateAttempt),
    GateFence (GateFence),
    GateJournalVersion (GateJournalVersion),
    GateOperationKey (GateOperationKey),
    GatePlanDigest (GatePlanDigest),
    GateSession (GateSession),
    PreparedGate,
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

{- | Join fields with tabs and encode their exact UTF-8 spelling.

For a nonempty list of delimiter-free fields, 'decodeFields' recovers that list.
This encoder does not validate fields: admission belongs to the producer. An
empty list and a singleton empty field both encode as empty bytes.
-}
encodeFields :: [Text] -> ByteString
encodeFields = TextEncoding.encodeUtf8 . Text.intercalate "\t"

{- | Decode UTF-8 strictly and split on tabs without trimming.

Invalid UTF-8 yields the record readers' existing empty-list failure sentinel.
-}
decodeFields :: ByteString -> [Text]
decodeFields = either (const []) (Text.splitOn "\t") . TextEncoding.decodeUtf8'

{- | Publish caller-supplied phase, session, fence and attempt fields, then mint
a gate with the journal version returned by that protected compare-and-swap.

The caller supplies the record key and all other gate coordinates. This
lower-level writer needs a 'ProtectedSession' inside an exclusive entry, but
does not perform the journal-permit, session, registration, broker or fence
checks of the local production producer, @Lifecycle.Session.withPreparedGate@.
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
