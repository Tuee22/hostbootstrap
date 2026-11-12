module ConstructKubernetesInstance (construct) where
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Activation (MeasuredInstance (KubernetesInstance))
construct :: Text -> Word64 -> MeasuredInstance
construct uid restarts = KubernetesInstance uid restarts
