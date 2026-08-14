{-# LANGUAGE OverloadedStrings #-}

{- | How one frame session ends: a terminal report, and the receipt for it.

The session owner holds the durable row a session *is*, and the node owner
holds what happens inside one while work remains. This module holds the last
two exchanges, and it is separate for the same reason the node owner is: it
reaches a session only through that owner's fixed-unit coordinate fold, so it
never sees the session's record key, version, or row bytes and cannot advance
or rewrite the session itself.

It goes further than the node owner in one direction. It names no
'HostBootstrap.Protected.ProtectedStore' at all. The two durable transitions a
terminal receipt needs — publishing the exact report, and advancing Published
to Received — arrive as continuations from whoever already holds that
capability, so what is owned here is the join and the two digests rather than
the writes. A caller cannot use this module to reach a store it does not
already have.

Neither exchange mints an answer. Both read complete signed response bytes they
are handed, and a signed @Refused@ is an ordinary member of each closed
response family rather than something this module can produce.
-}
module HostBootstrap.Lifecycle.Rooted.Receipt
    ( withRootedTerminalReportKernel
    , withRootedReceiptConfirmationKernel
    )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Handoff
    ( HandoffError
    , childConfigDigest
    , eliminateLifecycleReport
    , handoffErrorMessage
    , maxWireBytes
    )
import HostBootstrap.Handoff.Rooted
    ( rootedLifecycleRequestFromWireKernel
    , rootedLifecycleResponseFromWireKernel
    , withRootedLifecycleRequestKernel
    , withRootedLifecycleResponseKernel
    )
import HostBootstrap.Handoff.Runtime
    ( RecursiveHandoffRuntime
    , withRecursiveHandoffRuntimeKernel
    )
import HostBootstrap.Lifecycle.Rooted
    ( RootedFrameSession
    , withRootedFrameSessionKernel
    )

{- | Publish one exact terminal report, then derive its complete-response digest.

A @CloseFrame@ is the only request that reaches a terminal report, and the
paired @FrameComplete | Refused@ family is the only answer that can carry one.
Everything the request echoes is checked against this session's own coordinates
first — requester path, session token, ordinal, nonce, and the predecessor the
session recorded when it attached — and the report the response carries must
eliminate canonically and name the session's own verb, so a report bound to
another edge's verb is not this frame's terminal report.

The ordering is the deliverable. The exact canonical report is published and
read back through the supplied continuation before the complete signed-response
digest exists, so a receipt can never name a report the root has not durably
held.
-}
withRootedTerminalReportKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ByteString ->
    ByteString ->
    (ByteString -> IO (Either Text ())) ->
    (ByteString -> Text -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withRootedTerminalReportKernel #-}
withRootedTerminalReportKernel runtime session request signedComplete publish use =
    withTerminalRootedSession "close a frame" runtime session $
        \verbName path token ordinal predecessor ->
            case admit verbName path token ordinal predecessor of
                Left failure -> pure (Left failure)
                Right report -> do
                    published <- publish report
                    case published of
                        Left failure -> pure (Left failure)
                        Right () -> use report (childConfigDigest signedComplete)
  where
    admit verbName path token ordinal predecessor = do
        echoed <- terminalRequest True request
        require "the close request echoes another predecessor" (namedPredecessor echoed == predecessor)
        nonce <- echoedRequest "close" path token ordinal echoed
        answer <- terminalResponse True "FrameComplete" signedComplete
        report <- echoedResponse "FrameComplete" path token ordinal nonce answer
        reportVerb <-
            either handoffFailure Right
                ( eliminateLifecycleReport
                    report reportedVerb reportedVerb reportedVerb reportedVerb reportedVerb reportedVerb
                )
        require "the terminal report names another verb" (reportVerb == verbName)
        pure report

    reportedVerb _binding _origin _observations _detail verb = verb

{- | Confirm one terminal receipt against the exact report the close published.

A @ReceiptConfirm@ names its terminal report by carrying, as its predecessor,
the digest of the complete signed @FrameComplete@ bytes the close derived. That
is the only field it could name one with, and no other request family reaches
this transition at all, so nothing else can confirm or receive a terminal
report. Only when that digest is the exact one does the supplied
Published-to-Received compare-and-swap run.

The answer is the paired @ReceiptRecorded | Refused@ family, and a recorded
receipt repeats the same @FrameComplete@ digest in its own body — which is what
lets a child that persists nothing still say which terminal report was
received. An exact retry converges for the same reason: the confirmation
carries no state of its own, and the durable transition it drives is already
idempotent.
-}
withRootedReceiptConfirmationKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ByteString ->
    Text ->
    ByteString ->
    IO (Either Text ()) ->
    (Text -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withRootedReceiptConfirmationKernel #-}
withRootedReceiptConfirmationKernel runtime session request completion signedReceipt receive use =
    withTerminalRootedSession "confirm a terminal receipt" runtime session $
        \_verbName path token ordinal _predecessor ->
            case admit path token ordinal of
                Left failure -> pure (Left failure)
                Right () -> do
                    received <- receive
                    case received of
                        Left failure -> pure (Left failure)
                        Right () -> use (childConfigDigest signedReceipt)
  where
    admit path token ordinal = do
        require "the confirmed completion digest is empty" (not (Text.null completion))
        echoed <- terminalRequest False request
        require "the receipt confirmation names another terminal report"
            (namedPredecessor echoed == Just completion)
        nonce <- echoedRequest "receipt" path token ordinal echoed
        answer <- terminalResponse False "ReceiptRecorded" signedReceipt
        recorded <- echoedResponse "ReceiptRecorded" path token ordinal nonce answer
        require "the recorded receipt repeats another terminal report"
            (recorded == TextEncoding.encodeUtf8 completion)

{- | Admit one attached session's terminal coordinates and its predecessor.

Both exchanges need the same four facts and refuse on the same three grounds,
so they share one admission rather than repeating it. An opened-but-unattached
session has answered no @OpenFrame@ and therefore has no exchange to close, a
keyless nested arm never drives a root transition, and a session with no
recorded predecessor has produced no response for a terminal request to echo.
-}
withTerminalRootedSession ::
    Text ->
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    (Text -> [Text] -> Text -> Word64 -> Maybe Text -> IO (Either Text ())) ->
    IO (Either Text ())
withTerminalRootedSession action runtime session use =
    withRootedFrameSessionKernel session $
        \attached verbName _lineage _catalogIdentity _frame path token _stage ordinal predecessor ->
            withRecursiveHandoffRuntimeKernel runtime $
                \atRoot _project _tag _store _generation _runtimeVerb _keyDigest current ->
                    case admit attached atRoot current predecessor of
                        Left failure -> pure (Left failure)
                        Right () -> use verbName path token ordinal predecessor
  where
    admit attached atRoot current predecessor = do
        require ("an unattached rooted frame session cannot " <> action) attached
        require ("a keyless nested arm cannot " <> action) atRoot
        require "the runtime is not path-agnostic" (isNothing current)
        require "the session has no recorded predecessor" (isJust predecessor)

{- | Decode exactly one terminal request form and refuse every other family. -}
terminalRequest :: Bool -> ByteString -> Either Text ([Text], Text, Word64, ByteString, Maybe Text)
terminalRequest close raw = do
    decoded <- either (Left . receiptFailure) Right (rootedLifecycleRequestFromWireKernel raw)
    withRootedLifecycleRequestKernel
        decoded
        (const outside)
        (\_ _ _ _ _ _ -> outside)
        (\_ _ _ _ _ _ _ -> outside)
        (\_ _ _ _ _ _ _ -> outside)
        (\p s _ o n pre -> if close then Right (p, s, o, n, Just pre) else outside)
        (\p s _ o n pre -> if close then outside else Right (p, s, o, n, Just pre))
  where
    outside =
        Left
            ( receiptFailure
                ( "only a "
                    <> (if close then "CloseFrame" else "ReceiptConfirm")
                    <> " request reaches this rooted terminal transition"
                )
            )

{- | Decode exactly one terminal response form of its closed paired family. -}
terminalResponse :: Bool -> Text -> ByteString -> Either Text ([Text], Text, Word64, ByteString, ByteString)
terminalResponse complete family raw = do
    require ("the signed " <> family <> " response is empty") (not (ByteString.null raw))
    require ("the signed " <> family <> " response exceeds the durable bound")
        (fromIntegral (ByteString.length raw) <= maxWireBytes)
    response <- either (Left . receiptFailure) Right (rootedLifecycleResponseFromWireKernel raw)
    withRootedLifecycleResponseKernel
        response
        (\_ _ _ _ _ _ -> outside)
        (\_ _ _ _ _ _ _ _ _ _ _ -> outside)
        (\_ _ _ _ _ _ _ _ -> outside)
        (\_ _ _ _ _ _ _ _ -> outside)
        (\_ p s _ o n body _ -> if complete then Right (p, s, o, n, body) else outside)
        ( \_ p s _ o n recorded _ ->
            if complete then outside else Right (p, s, o, n, TextEncoding.encodeUtf8 recorded)
        )
        ( \_ _ _ _ _ _ detail _ ->
            Left (receiptFailure ("the rooted terminal request was refused: " <> detail))
        )
  where
    outside =
        Left
            ( receiptFailure
                ("only a paired " <> family <> " or Refused response answers this rooted terminal request")
            )

{- | Require one terminal request to echo this session, and yield its nonce. -}
echoedRequest ::
    Text ->
    [Text] ->
    Text ->
    Word64 ->
    ([Text], Text, Word64, ByteString, Maybe Text) ->
    Either Text ByteString
echoedRequest label path token ordinal (requestPath, requestSession, requestOrdinal, nonce, _) = do
    require ("the " <> label <> " request echoes another requester path") (requestPath == path)
    require ("the " <> label <> " request echoes another session") (requestSession == token)
    require ("the " <> label <> " request echoes another ordinal") (requestOrdinal == ordinal)
    require ("the " <> label <> " request nonce is empty") (not (ByteString.null nonce))
    pure nonce

{- | Require one terminal response to echo the exchange, and yield its body. -}
echoedResponse ::
    Text ->
    [Text] ->
    Text ->
    Word64 ->
    ByteString ->
    ([Text], Text, Word64, ByteString, ByteString) ->
    Either Text ByteString
echoedResponse label path token ordinal nonce (responsePath, responseSession, responseOrdinal, responseNonce, body) = do
    require ("the signed " <> label <> " response echoes another requester path") (responsePath == path)
    require ("the signed " <> label <> " response echoes another session") (responseSession == token)
    require ("the signed " <> label <> " response does not select a successor ordinal")
        (responseOrdinal > ordinal)
    require ("the signed " <> label <> " response echoes another nonce") (responseNonce == nonce)
    require ("the signed " <> label <> " response carries an empty body") (not (ByteString.null body))
    pure body

namedPredecessor :: ([Text], Text, Word64, ByteString, Maybe Text) -> Maybe Text
namedPredecessor (_, _, _, _, predecessor) = predecessor

handoffFailure :: HandoffError -> Either Text result
handoffFailure = Left . receiptFailure . Text.pack . handoffErrorMessage

require :: Text -> Bool -> Either Text ()
require _ True = Right ()
require detail False = Left (receiptFailure detail)

receiptFailure :: Text -> Text
receiptFailure detail = "rooted terminal receipt: " <> detail
