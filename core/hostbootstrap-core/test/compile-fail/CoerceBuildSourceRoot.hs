module CoerceBuildSourceRoot (forge) where
import Data.Coerce (coerce)
import HostBootstrap.Build (BuildSourceRoot)
forge :: FilePath -> BuildSourceRoot
forge = coerce
