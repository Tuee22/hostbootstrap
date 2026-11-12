module ConstructBuilderPath (construct) where
import HostBootstrap.Build (BuilderPath (..))
construct :: FilePath -> BuilderPath
construct = BuilderPath
