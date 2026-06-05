let hostDaemon =
      H.Model.HostDaemon
        H.HostDaemon::{
        , daemon = "service --role worker --config dhall/worker.dhall"
        }

in  H.config
      { project = "demo"
      , substrates =
        [ H.entry H.Substrate.AppleSilicon (H.cluster hostDaemon) ]
      }
