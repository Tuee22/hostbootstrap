module MemorySourceAsCpu where

import HostBootstrap.Cluster.Cordon.Foundation (
    CapacityReadPlan (CapacityReadPlan),
    CpuSource,
    MemorySource (ProcMemAvailable),
    StorageSource (PosixFreeStorage),
 )

-- The CPU slot accepts a CPU source, even when the other slots are valid.
wrongDimension :: CapacityReadPlan
wrongDimension = CapacityReadPlan ProcMemAvailable ProcMemAvailable (PosixFreeStorage "/")
