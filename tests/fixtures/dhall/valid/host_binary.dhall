let hostBinary = H.Model.HostBinary H.HostBinary::{=}

in  H.config
      { project = "demo"
      , substrates =
        [ H.entry H.Substrate.LinuxCpu (H.cluster hostBinary) ]
      }
