module RelabelAbsExe where

import HostBootstrap.HostTool (AbsExe, absExePath)

relabel :: AbsExe -> AbsExe
relabel executable = executable{absExePath = "docker"}
