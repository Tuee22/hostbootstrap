{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Package-private semantic lifecycle completion.

Canonical reports and acknowledgements remain descriptive bytes until the
exact live or rehydrated handoff state admits them. The constructors stay
hidden, and every effectful continuation is fixed-unit so no retained report,
offer, token, binding, or reverse-descent state can escape.
-}
module HostBootstrap.Handoff.Completion
    ( LifecycleCompletion
    , withAcknowledgedForwardLifecycleCompletionKernel
    , withAcknowledgedBoundReverseLifecycleCompletionKernel
    , withRehydratedAcknowledgedReverseLifecycleCompletionKernel
    , withLifecycleCompletionKernel
    )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Authority (VerbUp)
import qualified HostBootstrap.Handoff as Handoff
import HostBootstrap.Handoff.Internal (recoverySigningKernel)
import HostBootstrap.Teardown
    ( SubtreeSettled
    , TeardownError
    , teardownErrorMessage
    , teardownObservationsFromWire
    )
import HostBootstrap.Teardown.Internal
    ( ReverseDescent
    , withRehydratedAdoptedReverseDescentKernel
    , withVerifiedBoundReverseDescentObservationsKernel
    , withVerifiedBoundReverseDescentReportKernel
    )

{- | Evidence that an exact canonical lifecycle report was durably
acknowledged after its semantic proof was validated.
-}
data LifecycleCompletion proof scope brokerGeneration verb where
    ForwardLifecycleCompletion ::
        ByteString ->
        ByteString ->
        LifecycleCompletion () scope brokerGeneration VerbUp
    ReverseLifecycleCompletion ::
        ByteString ->
        ByteString ->
        SubtreeSettled scope planId frame verb ->
        LifecycleCompletion
            (SubtreeSettled scope planId frame verb)
            scope brokerGeneration verb

type role LifecycleCompletion nominal nominal nominal nominal

{- | Acknowledge a canonical forward report against one exact offer.

Refused and failed reports run the same durable action but create no semantic
completion evidence.
-}
withAcknowledgedForwardLifecycleCompletionKernel ::
    Handoff.HandoffOffer scope brokerGeneration ->
    ByteString ->
    (ByteString -> ByteString -> IO (Either Text ())) ->
    (LifecycleCompletion () scope brokerGeneration VerbUp -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withAcknowledgedForwardLifecycleCompletionKernel #-}
withAcknowledgedForwardLifecycleCompletionKernel offer report persist use =
    case Handoff.eliminateLifecycleReport report completed refused failed wrong wrong wrong of
        Left failure -> pure (Left (handoffFailure failure))
        Right action -> action
  where
    expected = Handoff.renderHandoffBinding (Handoff.handoffOfferBinding offer)
    completed binding _ _ _ _ =
        requireBinding expected binding $
            acknowledge report persist $ \ack ->
                use (ForwardLifecycleCompletion report ack)
    refused binding _ _ detail _ =
        requireBinding expected binding (acknowledgeWithoutProof "refused" detail)
    failed binding _ _ detail _ =
        requireBinding expected binding (acknowledgeWithoutProof "failed" detail)
    wrong _ _ _ _ _ = pure (Left "lifecycle completion: a forward offer refuses a reverse report")
    acknowledgeWithoutProof status detail = do
        acknowledged <- acknowledge report persist (const (pure (Right ())))
        pure $ case acknowledged of
            Left failure -> Left failure
            Right () -> Left ("lifecycle completion: the forward child " <> status <> ": " <> detail)

{- | Validate and acknowledge one canonical reverse report against live Bound
state. Completed reports alone invoke the retained observation verifier and
mint evidence; refused and failed reports use the no-proof exact Bound check.
-}
withAcknowledgedBoundReverseLifecycleCompletionKernel ::
    ReverseDescent (Handoff.HandoffOffer scope brokerGeneration)
        scope planId parentFrame childFrame brokerGeneration verb descentId ->
    ByteString ->
    (ByteString -> ByteString -> IO (Either Text ())) ->
    ( LifecycleCompletion
        (SubtreeSettled scope planId childFrame verb)
        scope brokerGeneration verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withAcknowledgedBoundReverseLifecycleCompletionKernel #-}
withAcknowledgedBoundReverseLifecycleCompletionKernel bound report persist use =
    withBoundReverseLifecycleCompletionKernel bound report (acknowledge report persist) use

withBoundReverseLifecycleCompletionKernel ::
    ReverseDescent (Handoff.HandoffOffer scope brokerGeneration)
        scope planId parentFrame childFrame brokerGeneration verb descentId ->
    ByteString ->
    ((ByteString -> IO (Either Text ())) -> IO (Either Text ())) ->
    ( LifecycleCompletion
        (SubtreeSettled scope planId childFrame verb)
        scope brokerGeneration verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withBoundReverseLifecycleCompletionKernel bound report acknowledgeReport use =
    case Handoff.eliminateLifecycleReport report wrong wrong wrong completed refused failed of
        Left failure -> pure (Left (handoffFailure failure))
        Right action -> action
  where
    completed binding _ observations _ verb =
        case teardownObservationsFromWire observations of
            Left failure -> pure (Left (Text.pack (teardownErrorMessage failure)))
            Right rows ->
                withVerifiedBoundReverseDescentObservationsKernel
                    bound binding verb rows $ \settled ->
                        acknowledgeReport $ \ack ->
                            use (ReverseLifecycleCompletion report ack settled)
    refused binding _ _ _ verb =
        withVerifiedBoundReverseDescentReportKernel bound binding verb $
            acknowledgeReport (const (pure (Right ())))
    failed = refused
    wrong _ _ _ _ _ = pure (Left "lifecycle completion: a reverse descent refuses a forward report")

{- | Rehydrate exact Bound and parent Adopted state without reopening a token
or map, then enter the same common reverse acknowledgement path.
-}
withRehydratedAcknowledgedReverseLifecycleCompletionKernel ::
    ReverseDescent ()
        scope planId parentFrame childFrame brokerGeneration verb descentId ->
    ByteString ->
    ( LifecycleCompletion
        (SubtreeSettled scope planId childFrame verb)
        scope brokerGeneration verb ->
      IO (Either Text ())
    ) ->
    IO
        ( Either
            ( TeardownError
            , ReverseDescent ()
                scope planId parentFrame childFrame brokerGeneration verb descentId
            )
            (Either Text ())
        )
{-# OPAQUE withRehydratedAcknowledgedReverseLifecycleCompletionKernel #-}
withRehydratedAcknowledgedReverseLifecycleCompletionKernel prepared report use =
    withRehydratedAdoptedReverseDescentKernel
        recoverySigningKernel
        prepared
        report
        (\bound acknowledgement ->
            withBoundReverseLifecycleCompletionKernel
                bound report (\continue -> continue acknowledgement) use
        )

{- | Eliminate semantic completion without exposing its retained wire identity. -}
withLifecycleCompletionKernel ::
    LifecycleCompletion proof scope brokerGeneration verb ->
    (proof -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withLifecycleCompletionKernel #-}
withLifecycleCompletionKernel completion = case completion of
    ForwardLifecycleCompletion report acknowledgement ->
        case report `seq` acknowledgement `seq` () of
            () -> \use -> use ()
    ReverseLifecycleCompletion report acknowledgement proof ->
        case report `seq` acknowledgement `seq` proof `seq` () of
            () -> \use -> use proof

acknowledge ::
    ByteString ->
    (ByteString -> ByteString -> IO (Either Text ())) ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
acknowledge report persist use =
    case Handoff.renderLifecycleAcknowledgement report of
        Left failure -> pure (Left (handoffFailure failure))
        Right ack -> do
            stored <- persist report ack
            case stored of
                Left failure -> pure (Left failure)
                Right () -> ack `seq` use ack

requireBinding :: ByteString -> ByteString -> IO (Either Text ()) -> IO (Either Text ())
requireBinding expected observed action
    | observed == expected = action
    | otherwise = pure (Left "lifecycle completion: the report binding differs from the exact offer")

handoffFailure :: Handoff.HandoffError -> Text
handoffFailure = Text.pack . Handoff.handoffErrorMessage
