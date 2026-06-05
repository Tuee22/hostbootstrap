-- `FreeBsd` is not a constructor of `Substrate`; this aborts during Dhall type-checking.
let container =
      H.Model.Container
        H.Container::{ dockerfile = "docker/demo.Dockerfile" }

in  H.config
      { project = "demo"
      , substrates =
        [ H.entry H.Substrate.FreeBsd (H.cluster container) ]
      }
