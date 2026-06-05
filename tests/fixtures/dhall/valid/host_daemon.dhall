H.config
      { project = "demo"
      , targets =
        [ H.target
            H.Accel.Metal
            ( H.Model.HostDaemon
                H.HostDaemon::{
                , build = H.Build::{
                  , cabal = "cabal install --installdir .build exe:demo"
                  , host = H.HostReqs::{ ghc = True }
                  }
                , daemon = ".build/demo inference --serve"
                }
            )
        ]
      }
