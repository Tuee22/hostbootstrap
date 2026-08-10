module ForgeActivationBroker where

import HostBootstrap.Activation

-- Only a provisioned root invocation can open an active signing broker.
forgedBroker :: ActivationBroker scope brokerGeneration verb
forgedBroker = ActivationBroker
