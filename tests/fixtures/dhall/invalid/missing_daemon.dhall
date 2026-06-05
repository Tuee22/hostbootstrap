-- HostDaemon requires `daemon`; omitting it is a Dhall type error.
let bad =
      H.Model.HostDaemon
        H.HostDaemon::{=}

in  H.config
      { project = "demo"
      , substrates = [ H.entry H.Substrate.AppleSilicon (H.cluster bad) ]
      }
