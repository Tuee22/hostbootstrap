-- Backward-compat: a project may still bind its own `H`; it shadows the
-- CLI-injected `let H = env:HOSTBOOTSTRAP_PACKAGE` and renders identically.
let H = env:HOSTBOOTSTRAP_PACKAGE

in  H.config
      { project = "demo"
      , substrates =
        [ H.entry
            H.Substrate.LinuxCpu
            (H.Model.Container H.Container::{ dockerfile = "docker/demo.Dockerfile" })
        ]
      }
