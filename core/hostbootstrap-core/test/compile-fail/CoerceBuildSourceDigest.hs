module CoerceBuildSourceDigest (forge) where
import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Build (BuildSourceDigest)
forge :: Text -> BuildSourceDigest
forge = coerce
