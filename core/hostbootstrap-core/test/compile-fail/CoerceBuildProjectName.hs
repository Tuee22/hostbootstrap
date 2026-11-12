module CoerceBuildProjectName (forge) where
import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Build (BuildProjectName)
forge :: Text -> BuildProjectName
forge = coerce
