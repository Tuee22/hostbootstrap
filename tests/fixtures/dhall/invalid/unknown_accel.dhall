-- `Gpu` is not a constructor of `Accel` (<Cpu | Cuda | Metal>); this aborts
-- with `Missing constructor: Gpu`.
H.config
      { project = "demo"
      , targets =
        [ H.target
            H.Accel.Gpu
            (H.Model.Container H.Container::{ dockerfile = "d" })
        ]
      }
