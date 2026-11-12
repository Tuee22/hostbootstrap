module ConstructBuildSourceDigest (construct) where
import Data.Text (Text)
import HostBootstrap.Build (BuildSourceDigest (..))
construct :: Text -> BuildSourceDigest
construct = BuildSourceDigest
