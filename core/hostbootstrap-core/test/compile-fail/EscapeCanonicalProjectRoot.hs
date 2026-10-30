module EscapeCanonicalProjectRoot where

import HostBootstrap.ProjectRoot

escaped :: FilePath -> FilePath -> IO (Either ProjectRootError (CanonicalProjectRoot scope escapedRoot))
escaped config root = withCanonicalProjectRoot config root pure
