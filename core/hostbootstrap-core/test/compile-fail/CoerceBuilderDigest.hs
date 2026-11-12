module CoerceBuilderDigest (forge) where
import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Build (BuilderDigest)
forge :: Text -> BuilderDigest
forge = coerce
