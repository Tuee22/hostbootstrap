module ForgeProtocolMessage where

import HostBootstrap.Handoff

-- Only the validating protocolMessage smart constructor can build a frame.
forgedMessage :: ProtocolMessage
forgedMessage = ProtocolMessage OfferTag 1 []
