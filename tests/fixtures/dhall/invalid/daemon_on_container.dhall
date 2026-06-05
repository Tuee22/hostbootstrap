-- A Container has no `daemon` field, so this is a Dhall type error.
H.config
      { project = "demo"
      , targets =
        [ H.target
            H.Accel.Cpu
            ( H.Model.Container
                H.Container::{ dockerfile = "d", daemon = ".build/demo serve" }
            )
        ]
      }
