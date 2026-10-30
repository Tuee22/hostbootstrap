module DockerProbeForCluster where

import HostBootstrap.ProjectPlan (ClusterResource, DockerResource)
import HostBootstrap.Readiness (BackendProbeKey (DockerDaemonProbe))

-- A Docker daemon key cannot select readiness for a planned cluster resource.
wrongKey :: BackendProbeKey ClusterResource dependency
wrongKey = DockerDaemonProbe
