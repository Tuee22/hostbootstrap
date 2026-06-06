-- `mounts` is only valid on Container, never HostBinary.
let bad =
      H.Model.HostBinary
        H.HostBinary::{ mounts = [] : List H.Mount.Type }

in  H.config
      { project = "demo"
      , substrates = [ H.entry H.Substrate.LinuxCpu (H.cluster bad) ]
      }
