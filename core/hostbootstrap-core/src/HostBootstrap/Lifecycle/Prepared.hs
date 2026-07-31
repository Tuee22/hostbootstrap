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

    -- * Its sole producer
    recordDurableUnknown,

    -- * Record encoding
    encodeFields,
    decodeFields,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
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
encodeFields :: [Text] -> ByteString
encodeFields = ByteStringChar8.pack . Text.unpack . Text.intercalate "\t"

decodeFields :: ByteString -> [Text]
decodeFields = Text.splitOn "\t" . Text.pack . ByteStringChar8.unpack

-- ---------------------------------------------------------------------------
-- The gate

{- | Proof that one operation's unknown phase was durably recorded before its
backend call, carrying the exact identities and indices that write established.

The constructor is private and no accessor rebuilds it, so the plan, operation,
fence epoch, attempt, and journal version an adapter is prepared against are the
store's, never literals at the call site.
-}
data PreparedGate = PreparedGate
    { preparedGatePlan :: Text
    -- ^ the plan digest whose journal recorded the unknown phase
    , preparedGateOperation :: Text
    -- ^ the operation key it was recorded under
    , preparedGateSession :: Text
    -- ^ the operation session that recorded it
    , preparedGateFence :: Word64
    -- ^ the authoritative fence epoch observed at prepare time
    , preparedGateAttempt :: Word64
    -- ^ this operation's attempt number, one past the recorded one
    , preparedGateJournalVersion :: Word64
    -- ^ the version the unknown-phase write returned
    }
    deriving (Eq, Show)

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
                PreparedGate
                    { preparedGatePlan = plan
                    , preparedGateOperation = operation
                    , preparedGateSession = sessionId
                    , preparedGateFence = fence
                    , preparedGateAttempt = attempt
                    , preparedGateJournalVersion = recordVersionWord journalVersion
                    }
