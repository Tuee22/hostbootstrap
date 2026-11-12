module CoerceBuildFrameName (forge) where
import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Build (BuildFrameName)
forge :: Text -> BuildFrameName
forge = coerce
