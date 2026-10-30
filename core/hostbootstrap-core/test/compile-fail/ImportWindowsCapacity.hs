module ImportWindowsCapacity where

import HostBootstrap.Cluster.Cordon.WindowsCapacity (readWindowsLogicalProcessors)

-- Native capacity bindings belong to the private kernel.
blocked = readWindowsLogicalProcessors
