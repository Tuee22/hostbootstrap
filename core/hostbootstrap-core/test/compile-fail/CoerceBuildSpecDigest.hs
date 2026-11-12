module CoerceBuildSpecDigest (forge) where
import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Build (BuildSpecDigest)
forge :: Text -> BuildSpecDigest
forge = coerce
