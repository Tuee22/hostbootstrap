module ImportHandoffReceiver where

-- Payload classification and both callback-scoped received packages belong to
-- the in-binary lifecycle owner, not to consumers of the public library.
import HostBootstrap.Handoff.Receiver (withReceivedHandoffEdge)

hidden :: ()
hidden = ()
