module ConstructCoordinatorDigest (construct) where
import Data.Text (Text)
import HostBootstrap.Build (CoordinatorDigest (..))
construct :: Text -> CoordinatorDigest
construct = CoordinatorDigest
