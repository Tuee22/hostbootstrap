-- The reusable hostbootstrap-core Dhall vocabulary (L0).
--
-- Every project composes its rich project/deploy and per-case test configs from
-- this vocabulary: `let C = ./Core.dhall in ...` — embedded and extended, never
-- redefined (see development_plan_standards.md § T). The record/union TYPES are
-- the shape the project binary reflects from its Haskell decoders (an anti-drift
-- test asserts the two agree). The budget FUNCTIONS (`Budget/fitsWithin`,
-- `Budget/split`) are hand-written here and drift-controlled by evaluation tests.
--
-- This file is self-contained (no Prelude import) so it evaluates with no network
-- access, both in-process via the Haskell `dhall` library and via `dhall-to-json`.

let Resources = { cpu : Natural, memory : Text, storage : Text }

-- A numeric resource budget in canonical units (whole CPU cores; memory and
-- storage in caller-consistent whole units, e.g. MiB / GiB).
let Budget = { cpu : Natural, memory : Natural, storage : Natural }

-- One Kubernetes-style workload's request/limit footprint, replicated.
let PodResources =
      { replicas : Natural
      , cpuRequest : Natural
      , cpuLimit : Natural
      , memoryRequest : Natural
      , memoryLimit : Natural
      }

-- The cap applied to a kind node container (Linux cordon).
let KindNode = { cpus : Natural, memory : Natural, storage : Natural }

let Mount = { source : Text, target : Text, readOnly : Bool }

let Substrate = < AppleSilicon | LinuxCpu | LinuxGpu >

let RunModel = < OneShot | HostNative | HostDaemon | Cluster >

let ClusterProfile = < Production | Test : Text >

-- A typed pointer to a secret's *source* — never the secret material itself.
-- `Vault` names a KV path + field; `TransitKey` a Vault Transit key name;
-- `Prompt` a label the caller resolves interactively; `TestPlaintext` an
-- inline literal used only in test configs. This is a pure shape — the core
-- carries no Vault dependency.
let SecretRef =
      < Vault : { mount : Text, path : Text, field : Text }
      | TransitKey : Text
      | Prompt : Text
      | TestPlaintext : Text
      >

let Weight = Natural

-- a <= b, without the Prelude.
let lessThanEqual =
      \(a : Natural) -> \(b : Natural) -> Natural/isZero (Natural/subtract b a)

let sumNat =
      \(xs : List Natural) ->
        List/fold
          Natural
          xs
          Natural
          (\(x : Natural) -> \(acc : Natural) -> x + acc)
          0

let mapList =
      \(A : Type) ->
      \(B : Type) ->
      \(f : A -> B) ->
      \(xs : List A) ->
        List/fold A xs (List B) (\(x : A) -> \(acc : List B) -> [ f x ] # acc) ([] : List B)

-- Floor division n / d (d > 0) by bounded repeated subtraction.
let divFloor =
      \(n : Natural) ->
      \(d : Natural) ->
        ( Natural/fold
            n
            { q : Natural, r : Natural }
            ( \(acc : { q : Natural, r : Natural }) ->
                if    lessThanEqual d acc.r
                then  { q = acc.q + 1, r = Natural/subtract d acc.r }
                else  acc
            )
            { q = 0, r = n }
        ).q

-- The total cpu / memory a pod set claims (replicas × limit, summed).
let totalCpu =
      \(pods : List PodResources) ->
        sumNat (mapList PodResources Natural (\(p : PodResources) -> p.replicas * p.cpuLimit) pods)

let totalMemory =
      \(pods : List PodResources) ->
        sumNat (mapList PodResources Natural (\(p : PodResources) -> p.replicas * p.memoryLimit) pods)

-- Does the concurrent pod set fit within the budget? (the assertion every
-- generated config carries, so an over-budget config fails to type-check).
let fitsWithin =
      \(b : Budget) ->
      \(pods : List PodResources) ->
            lessThanEqual (totalCpu pods) b.cpu
        &&  lessThanEqual (totalMemory pods) b.memory

-- Split a budget proportionally across weights (floor division).
let split =
      \(b : Budget) ->
      \(weights : List Weight) ->
        let total = sumNat weights
        in  mapList
              Weight
              Budget
              ( \(w : Weight) ->
                  { cpu = divFloor (b.cpu * w) total
                  , memory = divFloor (b.memory * w) total
                  , storage = divFloor (b.storage * w) total
                  }
              )
              weights

in  { Resources
    , Budget
    , PodResources
    , KindNode
    , Mount
    , Substrate
    , RunModel
    , ClusterProfile
    , SecretRef
    , Weight
    , lessThanEqual
    , divFloor
    , fitsWithin
    , split
    , `Budget/fitsWithin` = fitsWithin
    , `Budget/split` = split
    }
