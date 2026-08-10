module RawCanonicalHostMount where

import HostBootstrap.Config.Vocab (Mount)
import HostBootstrap.Lift.Context (canonicalHostMount)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)

badMount :: CanonicalProjectRoot scope rootId -> Mount
badMount root =
    canonicalHostMount
        root
        ("/tmp/project/.data" :: FilePath)
        "/workspace/project/.data"
        False
