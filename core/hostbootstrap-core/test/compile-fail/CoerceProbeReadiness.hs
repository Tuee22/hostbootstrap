module CoerceProbeReadiness where

import Data.Coerce (coerce)
import HostBootstrap.Readiness (ClusterApiReady, GpuPluginReady)
import HostBootstrap.Reconcile (ClusterResource, DependencyProbe)

bad :: DependencyProbe scope planId clusterId ClusterResource ClusterApiReady ->
    DependencyProbe scope planId clusterId ClusterResource GpuPluginReady
bad = coerce
