--| hostbootstrap project-config schema (Dhall).
--
-- A project's `hostbootstrap.dhall` imports this package and builds a typed
-- value. A project declares a list of **targets**, each pairing an acceleration
-- requirement (`Accel`) with exactly one execution model — `Container`,
-- `HostBinary`, or `HostDaemon`. The host is detected at runtime and the CLI
-- selects the target whose `Accel` the host can satisfy (capability
-- subsumption: `Cpu` runs everywhere, `Cuda` needs an NVIDIA host, `Metal`
-- needs Apple silicon).
--
-- Illegal states are unrepresentable at the type level: a project never names a
-- host, so a CUDA-on-Apple / Metal-on-Linux pairing cannot be written. Each
-- model variant is a distinct record type, so only `HostDaemon` has a `daemon`
-- field (and it is required), only `Container` has `service`/`mounts`, only
-- `HostBinary` has `handoff`. The base-image family is *derived* from `Accel`,
-- so there is no `flavor` field to set inconsistently.
--
-- `dhall-to-json` strips union tags, so `target` lowers the model union into a
-- self-describing record carrying an explicit `tag` plus one populated payload.
-- The hostbootstrap CLI reads that JSON.

let Accel = < Cpu | Cuda | Metal >

let Mount = { host : Text, container : Text, ro : Bool }

let HostReqs = { ghc : Bool }

let Build = { cabal : Text, host : HostReqs }

let Handoff = { up : Text, down : Text, delete : Optional Text }

let CtrArtifact = { dockerfile : Text }

let Container = { dockerfile : Text, service : Bool, mounts : List Mount }

let HostBinary =
      { build : Build, container : Optional CtrArtifact, handoff : Handoff }

let HostDaemon = { build : Build, daemon : Text, container : Optional CtrArtifact }

let Model =
      < Container : Container | HostBinary : HostBinary | HostDaemon : HostDaemon >

let RModel =
      { tag : Text
      , container : Optional Container
      , hostBinary : Optional HostBinary
      , hostDaemon : Optional HostDaemon
      }

let RTarget = { accel : Text, model : RModel }

let ConfigInput = { project : Text, targets : List RTarget }

let Config = { project : Text, development : Bool, targets : List RTarget }

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

let renderAccel
    : Accel -> Text
    = \(a : Accel) ->
        merge { Cpu = "cpu", Cuda = "cuda", Metal = "metal" } a

let target
    : Accel -> Model -> RTarget
    = \(a : Accel) ->
      \(m : Model) ->
        { accel = renderAccel a, model = renderModel m }

let renderConfig
    : Bool -> ConfigInput -> Config
    = \(development : Bool) ->
      \(c : ConfigInput) ->
        { project = c.project, development = development, targets = c.targets }

let config
    : ConfigInput -> Config
    = renderConfig False

let configWithDevelopment
    : Bool -> ConfigInput -> Config
    = renderConfig

in  { Accel
    , Mount = { Type = Mount, default = { ro = False } }
    , HostReqs = { Type = HostReqs, default = { ghc = False } }
    , Build = { Type = Build, default = { host = { ghc = False } } }
    , Handoff = { Type = Handoff, default = { delete = None Text } }
    , CtrArtifact
    , Container =
      { Type = Container, default = { service = False, mounts = [] : List Mount } }
    , HostBinary = { Type = HostBinary, default = { container = None CtrArtifact } }
    , HostDaemon = { Type = HostDaemon, default = { container = None CtrArtifact } }
    , Model
    , target
    , config
    , configWithDevelopment
    }
