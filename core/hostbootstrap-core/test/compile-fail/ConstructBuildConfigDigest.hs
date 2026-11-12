module ConstructBuildConfigDigest (construct) where
import Data.Text (Text)
import HostBootstrap.Build (BuildConfigDigest (..))
construct :: Text -> BuildConfigDigest
construct = BuildConfigDigest
