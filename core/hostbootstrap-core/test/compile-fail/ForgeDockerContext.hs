-- | Callers cannot construct an arbitrary Docker context name.
module ForgeDockerContext where

import HostBootstrap.Ensure.Colima.Command

bad = DockerContextName "default"
