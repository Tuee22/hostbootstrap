module ReadActivationBrokerVerificationKey where

import Data.ByteString (ByteString)
import HostBootstrap.Activation

-- A verifier must be installed before broker construction; no broker-derived
-- verification-key export exists.
brokerVerificationKey :: ActivationBroker scope brokerGeneration verb -> ByteString
brokerVerificationKey = activationBrokerKey
