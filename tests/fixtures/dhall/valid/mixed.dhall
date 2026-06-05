let container =
      H.Model.Container
        H.Container::{ dockerfile = "docker/demo.Dockerfile" }

let hostBinary = H.Model.HostBinary H.HostBinary::{=}

let hostDaemon =
      H.Model.HostDaemon
        H.HostDaemon::{
        , daemon = "service --role worker --config dhall/worker.dhall"
        }

in  H.config
      { project = "demo"
      , substrates =
        [ H.entry H.Substrate.AppleSilicon (H.cluster hostDaemon)
        , H.entry H.Substrate.LinuxCpu (H.cluster container)
        , H.entry H.Substrate.LinuxGpu (H.noCluster hostBinary)
        ]
      }
