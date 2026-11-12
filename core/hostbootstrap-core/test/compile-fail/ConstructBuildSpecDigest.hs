module ConstructBuildSpecDigest (construct) where
import Data.Text (Text)
import HostBootstrap.Build (BuildSpecDigest (..))
construct :: Text -> BuildSpecDigest
construct = BuildSpecDigest
