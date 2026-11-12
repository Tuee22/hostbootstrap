module ConstructHostServiceInstance (construct) where
import Data.Text (Text)
import HostBootstrap.Activation (MeasuredInstance (HostServiceInstance))
construct :: Text -> MeasuredInstance
construct nonce = HostServiceInstance nonce
