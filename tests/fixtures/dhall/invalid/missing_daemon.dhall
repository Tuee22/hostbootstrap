-- HostDaemon requires `daemon`; omitting it is a Dhall type error.
H.config
      { project = "demo"
      , targets =
        [ H.target
            H.Accel.Metal
            ( H.Model.HostDaemon
                H.HostDaemon::{ build = H.Build::{ cabal = "cabal install exe:demo" } }
            )
        ]
      }
