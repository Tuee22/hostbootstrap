module ConstructBuildFrameName (construct) where
import Data.Text (Text)
import HostBootstrap.Build (BuildFrameName (..))
construct :: Text -> BuildFrameName
construct = BuildFrameName
