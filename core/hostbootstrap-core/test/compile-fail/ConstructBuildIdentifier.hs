module ConstructBuildIdentifier (construct) where
import Data.Text (Text)
import HostBootstrap.Build (BuildIdentifier (..))
construct :: Text -> BuildIdentifier
construct = BuildIdentifier
