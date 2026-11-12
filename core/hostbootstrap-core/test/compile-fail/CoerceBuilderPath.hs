module CoerceBuilderPath (forge) where
import Data.Coerce (coerce)
import HostBootstrap.Build (BuilderPath)
forge :: FilePath -> BuilderPath
forge = coerce
