H.configWithDevelopment
      True
      { project = "demo"
      , substrates =
        [ H.entry
            H.Substrate.LinuxCpu
            ( H.Model.Container
                H.Container::{ dockerfile = "docker/demo.Dockerfile" }
            )
        ]
      }
