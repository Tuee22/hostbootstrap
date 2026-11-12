module CoerceReceivedActivationManifest (forge) where
import Data.Coerce (coerce)
import HostBootstrap.Activation (ActivationManifest, ReceivedActivationManifest)
forge :: ActivationManifest -> ReceivedActivationManifest
forge = coerce
