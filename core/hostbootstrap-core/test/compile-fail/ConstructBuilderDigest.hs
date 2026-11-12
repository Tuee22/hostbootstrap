module ConstructBuilderDigest (construct) where
import Data.Text (Text)
import HostBootstrap.Build (BuilderDigest (..))
construct :: Text -> BuilderDigest
construct = BuilderDigest
