H.config
      { project = "demo"
      , targets =
        [ H.target
            H.Accel.Cpu
            ( H.Model.HostBinary
                H.HostBinary::{
                , build = H.Build::{
                  , cabal =
                      "cabal install --installdir .build --install-method=copy --overwrite-policy=always exe:demo"
                  }
                , handoff = H.Handoff::{
                  , up = ".build/demo cluster up"
                  , down = ".build/demo cluster down"
                  }
                }
            )
        ]
      }
