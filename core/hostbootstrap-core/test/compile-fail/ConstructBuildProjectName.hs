module ConstructBuildProjectName (construct) where
import Data.Text (Text)
import HostBootstrap.Build (BuildProjectName (..))
construct :: Text -> BuildProjectName
construct = BuildProjectName
