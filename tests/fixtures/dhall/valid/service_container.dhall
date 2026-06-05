H.config
      { project = "demo"
      , targets =
        [ H.target
            H.Accel.Cpu
            ( H.Model.Container
                H.Container::{
                , dockerfile = "docker/demo.Dockerfile"
                , service = True
                , mounts =
                  [ H.Mount::{ host = "./.data", container = "/opt/demo/.data" }
                  , H.Mount::{
                    , host = "/var/run/docker.sock"
                    , container = "/var/run/docker.sock"
                    }
                  ]
                }
            )
        ]
      }
