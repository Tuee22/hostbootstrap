--| hostbootstrap project-config schema (Dhall).
--
-- A project's `hostbootstrap.dhall` imports this package and builds a typed
-- value. A project declares one entry per hardware substrate: Apple Silicon,
-- Linux CPU, and/or Linux GPU. Each substrate entry selects either a cluster
-- lifecycle or a no-cluster lifecycle, and then selects exactly one execution
-- model: `Container`, `HostBinary`, or `HostDaemon`.
--
-- Illegal states are unrepresentable at the type level: only `HostDaemon` has
-- a daemon command, only `Container` has bind mounts, and no model exposes
-- explicit build or handoff commands. hostbootstrap derives those commands
-- from the project name.

let Substrate = < AppleSilicon | LinuxCpu | LinuxGpu >

let Mount = { host : Text, container : Text, ro : Bool }

let CtrArtifact = { dockerfile : Text }

let Container = { dockerfile : Text, mounts : List Mount }

let HostBinary = { container : Optional CtrArtifact }

let HostDaemon = { daemon : Text, container : Optional CtrArtifact }

let Model =
      < Container : Container | HostBinary : HostBinary | HostDaemon : HostDaemon >

let RModel =
      { tag : Text
      , container : Optional Container
      , hostBinary : Optional HostBinary
      , hostDaemon : Optional HostDaemon
      }

let Lifecycle = < Cluster : Model | NoCluster : Model >

let RLifecycle =
      { tag : Text
      , cluster : Optional RModel
      , noCluster : Optional RModel
      }

let RTarget = { substrate : Text, lifecycle : RLifecycle }

let ConfigInput = { project : Text, substrates : List RTarget }

let Config = { project : Text, substrates : List RTarget }

let renderModel
    : Model -> RModel
    = \(m : Model) ->
        merge
          { Container =
              \(c : Container) ->
                { tag = "Container"
                , container = Some c
                , hostBinary = None HostBinary
                , hostDaemon = None HostDaemon
                }
          , HostBinary =
              \(b : HostBinary) ->
                { tag = "HostBinary"
                , container = None Container
                , hostBinary = Some b
                , hostDaemon = None HostDaemon
                }
          , HostDaemon =
              \(d : HostDaemon) ->
                { tag = "HostDaemon"
                , container = None Container
                , hostBinary = None HostBinary
                , hostDaemon = Some d
                }
          }
          m

let renderLifecycle
    : Lifecycle -> RLifecycle
    = \(l : Lifecycle) ->
        merge
          { Cluster =
              \(m : Model) ->
                { tag = "Cluster"
                , cluster = Some (renderModel m)
                , noCluster = None RModel
                }
          , NoCluster =
              \(m : Model) ->
                { tag = "NoCluster"
                , cluster = None RModel
                , noCluster = Some (renderModel m)
                }
          }
          l

let renderSubstrate
    : Substrate -> Text
    = \(s : Substrate) ->
        merge
          { AppleSilicon = "apple-silicon"
          , LinuxCpu = "linux-cpu"
          , LinuxGpu = "linux-gpu"
          }
          s

let entry
    : Substrate -> Lifecycle -> RTarget
    = \(s : Substrate) ->
      \(l : Lifecycle) ->
        { substrate = renderSubstrate s, lifecycle = renderLifecycle l }

let cluster
    : Model -> Lifecycle
    = \(m : Model) -> Lifecycle.Cluster m

let noCluster
    : Model -> Lifecycle
    = \(m : Model) -> Lifecycle.NoCluster m

let config
    : ConfigInput -> Config
    = \(c : ConfigInput) -> c

in  { Substrate
    , Mount = { Type = Mount, default = { ro = False } }
    , CtrArtifact
    , Container = { Type = Container, default = { mounts = [] : List Mount } }
    , HostBinary = { Type = HostBinary, default = { container = None CtrArtifact } }
    , HostDaemon = { Type = HostDaemon, default = { container = None CtrArtifact } }
    , Model
    , Lifecycle
    , entry
    , cluster
    , noCluster
    , config
    }
