{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Constructor-private authority for one authenticated recovery child.

The package retains the complete received descent and the independently
admitted local lifecycle evidence.  Its only eliminator emits a canonical
byte identity; none of the retained authorities can be projected.
-}
module HostBootstrap.Authority.ProjectPlan.Internal
    ( ChildRecoveryOrigin
    , withChildRecoveryOriginKernel
    , childRecoveryOriginFrameNameKernel
    , childRecoveryOriginVerbNameKernel
    , withChildRecoveryTerminalOriginKernel
    )
where

import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Authority
    ( CommandAuthority
    , TeardownPhase
    , brokerEpochWord
    , commandAuthorityEpoch
    , commandAuthorityFrame
    , commandAuthorityInvocation
    , commandAuthorityPhase
    , commandAuthorityVerb
    , invocationIdText
    , lifecyclePhaseName
    , projectVerbName
    )
import HostBootstrap.Handoff
    ( frameWire
    , recoveryWireDigest
    , renderHandoffBinding
    , verifiedHandoffBinding
    )
import HostBootstrap.Handoff.Receiver (ReceivedRecoveryDescent)
import HostBootstrap.Handoff.Receiver.Internal
    ( receivedEdgeHandoff
    , withReceivedRecoveryDescent
    )
import HostBootstrap.Lifecycle.Context (ValidatedLifecycleContext)
import HostBootstrap.Lifecycle.Mode (AcquisitionJournal, LifecycleCursor)
import HostBootstrap.Lifecycle.Plan (planDigestBindingDigestKernel)
import HostBootstrap.Lifecycle.Session
    ( acquisitionJournalRecordVersion
    , lifecycleCursorRecordVersion
    )
import HostBootstrap.ProjectPlan
    ( ProjectPlan
    , renderSnapshot
    , stablePlanSnapshotDigest
    )
import HostBootstrap.ProjectPlan.Snapshot (PlanDigestBinding)
import HostBootstrap.Teardown
    ( TeardownPlan
    , teardownPlanFrameId
    , teardownPlanVerbName
    )

data ChildRecoveryOrigin scope specDigest planDigest brokerGeneration parentFrame
    planId configId childFrame verb where
    ChildRecoveryOrigin ::
        ReceivedRecoveryDescent
            scope brokerGeneration planDigest parentFrame signedChildFrame
            recoveryWireDigest recoveryWireId verb ->
        ProjectPlan scope specDigest planId configId cfg ->
        PlanDigestBinding scope specDigest planDigest planId ->
        ValidatedLifecycleContext scope specDigest planId configId childFrame ->
        TeardownPlan scope planId childFrame verb ->
        AcquisitionJournal scope planId brokerGeneration ->
        LifecycleCursor scope planId childFrame brokerGeneration verb TeardownPhase ->
        CommandAuthority scope planId childFrame brokerGeneration verb TeardownPhase ->
        ChildRecoveryOrigin scope specDigest planDigest brokerGeneration parentFrame
            planId configId childFrame verb

type role ChildRecoveryOrigin nominal nominal nominal nominal nominal nominal nominal nominal nominal

withChildRecoveryOriginKernel ::
    ReceivedRecoveryDescent
        scope brokerGeneration planDigest parentFrame signedChildFrame
        recoveryWireDigest recoveryWireId verb ->
    ProjectPlan scope specDigest planId configId cfg ->
    PlanDigestBinding scope specDigest planDigest planId ->
    ValidatedLifecycleContext scope specDigest planId configId childFrame ->
    TeardownPlan scope planId childFrame verb ->
    AcquisitionJournal scope planId brokerGeneration ->
    LifecycleCursor scope planId childFrame brokerGeneration verb TeardownPhase ->
    CommandAuthority scope planId childFrame brokerGeneration verb TeardownPhase ->
    ( ChildRecoveryOrigin scope specDigest planDigest brokerGeneration parentFrame
        planId configId childFrame verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withChildRecoveryOriginKernel descent plan binding context teardown journal cursor authority use =
    withReceivedRecoveryDescent descent $ \_ _ _ _ _ _ ->
        plan
            `seq` binding
            `seq` context
            `seq` teardown
            `seq` journal
            `seq` cursor
            `seq` authority
            `seq` use
                ( ChildRecoveryOrigin
                    descent plan binding context teardown journal cursor authority
                )

-- | Descriptive local frame; this grants no frame or command authority.
childRecoveryOriginFrameNameKernel ::
    ChildRecoveryOrigin scope specDigest planDigest brokerGeneration parentFrame
        planId configId childFrame verb ->
    Text
childRecoveryOriginFrameNameKernel (ChildRecoveryOrigin _ _ _ _ _ _ _ authority) =
    commandAuthorityFrame authority

-- | Descriptive closed verb; this grants no command authority.
childRecoveryOriginVerbNameKernel ::
    ChildRecoveryOrigin scope specDigest planDigest brokerGeneration parentFrame
        planId configId childFrame verb ->
    Text
childRecoveryOriginVerbNameKernel (ChildRecoveryOrigin _ _ _ _ _ _ _ authority) =
    projectVerbName (commandAuthorityVerb authority)

{- | Emit only the canonical identity of a sealed recovery origin.

The complete signed binding and exact authenticated recovery fields are
length-framed with the independently admitted local plan and command lineage.
The fixed-unit continuation cannot extract any retained evidence.
-}
withChildRecoveryTerminalOriginKernel ::
    ChildRecoveryOrigin scope specDigest planDigest brokerGeneration parentFrame
        planId configId childFrame verb ->
    (ByteString.ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
withChildRecoveryTerminalOriginKernel
    (ChildRecoveryOrigin descent plan digestBinding _ teardown journal cursor authority)
    use =
        withReceivedRecoveryDescent descent $ \edge _ verb adapter _ _ ->
            use . ByteString.concat . map frameWire $
                [ "child-recovery-terminal-origin-v1"
                , "1"
                , renderHandoffBinding (verifiedHandoffBinding (receivedEdgeHandoff edge))
                , text (stablePlanSnapshotDigest (renderSnapshot plan))
                , text (planDigestBindingDigestKernel digestBinding)
                , text (invocationIdText (commandAuthorityInvocation authority))
                , word (acquisitionJournalRecordVersion journal)
                , word (lifecycleCursorRecordVersion cursor)
                , text (commandAuthorityFrame authority)
                , word (brokerEpochWord (commandAuthorityEpoch authority))
                , text (projectVerbName verb)
                , text (projectVerbName (commandAuthorityVerb authority))
                , text (lifecyclePhaseName (commandAuthorityPhase authority))
                , text (teardownPlanFrameId teardown)
                , text (teardownPlanVerbName teardown)
                , text (recoveryWireDigest adapter)
                ]
      where
        text = TextEncoding.encodeUtf8
        word = text . Text.pack . show
