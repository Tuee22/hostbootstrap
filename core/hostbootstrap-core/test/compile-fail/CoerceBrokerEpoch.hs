module CoerceBrokerEpoch where

import Data.Coerce (coerce)
import HostBootstrap.Authority

data EpochA
data EpochB

wrongEpoch :: BrokerEpoch EpochA -> BrokerEpoch EpochB
wrongEpoch = coerce
