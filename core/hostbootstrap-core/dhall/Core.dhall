-- The reusable hostbootstrap-core Dhall vocabulary (L0).
--
-- Every project composes its rich project/deploy and per-case test configs from
-- this vocabulary: `let C = ./Core.dhall in ...` — embedded and extended, never
-- redefined (see development_plan_standards.md § T). This whole file is
-- hand-written: nothing generates it. The record/union TYPES are held equal to
-- the schema the project binary reflects from its Haskell decoders by an
-- anti-drift test, which reads the direction the other way round from
-- generation -- Haskell is the comparand, not the source. The budget FUNCTIONS
-- (`Budget/fitsWithin`, `Budget/split`) have no Haskell counterpart at all and
-- are drift-controlled by evaluation tests.
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

-- Production has pointers only. The Harness wire is deliberately distinct:
-- inline fixture material is untrusted until matching run authority converts
-- it into a harness-scoped Haskell value.
let ProductionSecretRef =
      < Vault : { mount : Text, path : Text, field : Text }
      | TransitKey : Text
      | Prompt : Text
      >

let HarnessSecretRef =
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

-- Floor division n / d by bounded repeated subtraction.
--
-- PARTIAL at d = 0, where the guard `0 <= r` never fails and the result is n.
-- It is deliberately NOT exported: `split` is its only caller and passes a zero
-- divisor only when the dividend is also zero (every weight is zero, so every
-- `b.field * w` is zero), for which the answer 0 is correct. Exporting it would
-- make the one input it cannot answer reachable by a caller with no way to learn
-- that from its type.
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

-- Is every pod's request within its own limit? Kubernetes refuses that pair at
-- apply time; refusing it here makes the config that would be rejected fail to
-- type-check instead.
let requestsWithinLimits =
      \(pods : List PodResources) ->
        List/fold
          PodResources
          pods
          Bool
          ( \(p : PodResources) ->
            \(acc : Bool) ->
                  lessThanEqual p.cpuRequest p.cpuLimit
              &&  lessThanEqual p.memoryRequest p.memoryLimit
              &&  acc
          )
          True

-- Does the concurrent pod set fit within the budget, and does each pod's request
-- fit within its own limit? (the assertion every generated config carries, so an
-- over-budget or self-contradictory config fails to type-check).
let fitsWithin =
      \(b : Budget) ->
      \(pods : List PodResources) ->
            lessThanEqual (totalCpu pods) b.cpu
        &&  lessThanEqual (totalMemory pods) b.memory
        &&  requestsWithinLimits pods

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
    , ProductionSecretRef
    , HarnessSecretRef
    , Weight
    , lessThanEqual
    , requestsWithinLimits
    , fitsWithin
    , split
    , `Budget/fitsWithin` = fitsWithin
    , `Budget/split` = split
    }
