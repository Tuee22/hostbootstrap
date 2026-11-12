module ConstructReceivedActivationManifest (construct) where
import HostBootstrap.Activation (ActivationManifest, ReceivedActivationManifest (..))
construct :: ActivationManifest -> ReceivedActivationManifest
construct = ReceivedActivationManifest
