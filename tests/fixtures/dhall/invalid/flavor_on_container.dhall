-- Base flavor is derived from substrate, so setting `flavor` is rejected.
let bad =
      H.Model.Container
        H.Container::{ dockerfile = "docker/demo.Dockerfile", flavor = "cuda" }

in  H.config
      { project = "demo"
      , substrates = [ H.entry H.Substrate.LinuxCpu (H.cluster bad) ]
      }
