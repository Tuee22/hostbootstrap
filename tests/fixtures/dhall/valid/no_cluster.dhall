let container =
      H.Model.Container
        H.Container::{ dockerfile = "docker/demo.Dockerfile" }

in  H.config
      { project = "demo"
      , substrates =
        [ H.entry H.Substrate.AppleSilicon (H.noCluster container)
        , H.entry H.Substrate.LinuxCpu (H.noCluster container)
        , H.entry H.Substrate.LinuxGpu (H.noCluster container)
        ]
      }
