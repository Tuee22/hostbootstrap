module ImportHandoffReceiverInternal where

-- Raw relay channels and request identifiers are package-private. Public code
-- receives only the opaque edge and can derive a sealed BrokerLink from it.
import HostBootstrap.Handoff.Receiver.Internal
