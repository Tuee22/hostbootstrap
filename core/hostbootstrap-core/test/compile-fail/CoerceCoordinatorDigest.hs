module CoerceCoordinatorDigest (forge) where
import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Build (CoordinatorDigest)
forge :: Text -> CoordinatorDigest
forge = coerce
