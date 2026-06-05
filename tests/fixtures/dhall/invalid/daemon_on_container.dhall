-- `daemon` is only valid on HostDaemon, never Container.
let bad =
      H.Model.Container
        H.Container::{ dockerfile = "docker/demo.Dockerfile", daemon = "serve" }

in  H.config
      { project = "demo"
      , substrates = [ H.entry H.Substrate.LinuxCpu (H.cluster bad) ]
      }
