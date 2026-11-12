module ConstructBuildSourceRoot (construct) where
import HostBootstrap.Build (BuildSourceRoot (..))
construct :: FilePath -> BuildSourceRoot
construct = BuildSourceRoot
