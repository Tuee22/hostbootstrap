-- `flavor` was removed from Container: the base family is derived from the
-- target's Accel, so setting it (and referencing the deleted `H.Flavor`) is a
-- Dhall type error. CUDA-on-CPU is now unrepresentable.
H.config
      { project = "demo"
      , targets =
        [ H.target
            H.Accel.Cpu
            ( H.Model.Container
                H.Container::{ dockerfile = "d", flavor = H.Flavor.Cuda }
            )
        ]
      }
