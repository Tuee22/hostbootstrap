module RawProbe where

import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Readiness

-- The public synonym does not expose the private representation constructor.
rawProbe ::
    (HostConfig -> IO (ProbeResult (BackendReady value))) ->
    Probe scope planId resourceId resource dependency probeId value
rawProbe = Probe
