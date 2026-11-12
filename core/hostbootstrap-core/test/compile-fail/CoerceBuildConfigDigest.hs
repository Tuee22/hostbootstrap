module CoerceBuildConfigDigest (forge) where
import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Build (BuildConfigDigest)
forge :: Text -> BuildConfigDigest
forge = coerce
