module UpdateActivationManifest (update) where
import Data.Text (Text)
import HostBootstrap.Activation (ActivationManifest, manifestRevision)
update :: Text -> ActivationManifest -> ActivationManifest
update revision manifest = manifest{manifestRevision = revision}
