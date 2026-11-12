module ConstructSelectedActivationManifest (construct) where
import HostBootstrap.Activation (ActivationManifest, SelectedActivationManifest (..))
construct :: ActivationManifest -> SelectedActivationManifest
construct = SelectedActivationManifest
