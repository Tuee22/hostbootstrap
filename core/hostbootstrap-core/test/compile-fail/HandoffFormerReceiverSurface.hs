module HandoffFormerReceiverSurface where

-- Sealing Receiver must not be bypassable through the public Handoff facade.
-- This list covers the former expectation/edge API and the recovery package,
-- constructors, projections, and folds that remain package-private.
import HostBootstrap.Handoff
    ( ReceivedEdge
    , ReceivedRecoveryDescent
    , ReceiverError
    , ReceiverExpectation
    , mkReceivedEdge
    , mkReceivedRecoveryDescent
    , receivedEdgeBinding
    , receivedEdgeChannel
    , receivedEdgeConfig
    , receivedEdgeAuthenticatedRootScope
    , receivedEdgeHandoff
    , receivedEdgeRequestId
    , receiverErrorMessage
    , withReceivedHandoffEdge
    , withReceivedRecoveryDescent
    )
