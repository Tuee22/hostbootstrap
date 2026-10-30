-- The reusable hostbootstrap-core Dhall vocabulary (L0).
--
-- Higher vocabulary layers and standalone numeric artifacts import this file
-- with `let C = ./Core.dhall in ...`, extending rather than redefining its types
-- (see development_plan_standards.md § T). Runtime <project>.dhall and the single
-- <project>.test.dhall are rendered from Haskell codecs and do not import it.
-- example.dhall is the byte-exact renderProjectConfig golden; its ContextKind,
-- ProviderKind, and CommandClass unions are context unions, not exports here.
--
-- This file is hand-written: nothing generates it. DhallGenSpec holds every
-- exported type judgmentally equal to its Haskell codec's reflected schema.
-- The budget functions (`Budget/fitsWithin`, `Budget/split`) are hand-written
-- and drift-controlled by evaluation tests.
--
-- This file is self-contained (no Prelude import) so it evaluates with no network
-- access. Runtime decoding runs in-process through the Haskell `dhall` library.

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

-- Is every pod's CPU and memory request within its own limit? This returns a
-- Bool; a standalone artifact can assert that the result is True.
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

-- Do concurrent CPU/memory limits fit the budget, and requests fit their own
-- limits? Storage is not compared. Only standalone numeric artifacts, such as
-- deployConfigText output, carry `assert : C.fitsWithin ... === True`.
-- Runtime project/test configs carry text quantities and no resolved pod set.
-- Cluster.Budget's verifyPlannedWorkloadFit and withBudgetPartition own the
-- authoritative plan-indexed workload fit and partition.
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
