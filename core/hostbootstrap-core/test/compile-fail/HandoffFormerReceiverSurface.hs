module HandoffFormerReceiverSurface where

-- Sealing Receiver must not be bypassable through the public Handoff facade.
-- The edge and recovery-descent packages, constructors, projections, and folds
-- remain package-private.
import HostBootstrap.Handoff (
    ReceivedEdge,
    ReceivedRecoveryDescent,
    ReceiverError,
    mkReceivedEdge,
    mkReceivedRecoveryDescent,
    receivedEdgeAuthenticatedRootScope,
    receivedEdgeChannel,
    receivedEdgeHandoff,
    receivedEdgeRequestId,
    receiverErrorMessage,
    withReceivedHandoffEdge,
    withReceivedRecoveryDescent,
 )
