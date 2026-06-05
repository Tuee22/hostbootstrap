H.configWithDevelopment
      True
      { project = "demo"
      , targets =
        [ H.target
            H.Accel.Cpu
            ( H.Model.Container
                H.Container::{ dockerfile = "docker/demo.Dockerfile" }
            )
        ]
      }
