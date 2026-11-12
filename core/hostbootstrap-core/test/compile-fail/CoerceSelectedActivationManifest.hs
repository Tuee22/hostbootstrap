module CoerceSelectedActivationManifest (forge) where
import Data.Coerce (coerce)
import HostBootstrap.Activation (ActivationManifest, SelectedActivationManifest)
forge :: ActivationManifest -> SelectedActivationManifest
forge = coerce
