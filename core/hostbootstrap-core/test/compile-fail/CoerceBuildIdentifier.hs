module CoerceBuildIdentifier (forge) where
import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Build (BuildIdentifier)
forge :: Text -> BuildIdentifier
forge = coerce
