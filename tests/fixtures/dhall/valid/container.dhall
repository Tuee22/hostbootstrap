let container =
      H.Model.Container
        H.Container::{
        , dockerfile = "docker/demo.Dockerfile"
        , mounts = [ H.Mount::{ host = "./.data", container = "/opt/demo/.data" } ]
        }

in  H.config
      { project = "demo"
      , substrates =
        [ H.entry H.Substrate.LinuxCpu (H.cluster container) ]
      }
