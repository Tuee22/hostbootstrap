{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The one standardized, Dhall-driven test harness.

Every project's tests run through this single L0 engine: 'runMatrix' drives a
list of generated per-case configs, each spinning up an isolated, budget-sliced
environment that tears down while preserving production @.data@. The harness is
parameterized by a 'Seams' record (the default seams do a one-shot container
run; cluster projects supply kind/Helm seams), and the app supplies only the
case matrix (see @development_plan_standards.md § S, § T@).

The isolation/profile derivation, the prefix delete-guard, the budget slicing,
and the report aggregation are pure so never-touch-production is mechanical and
unit-tested; 'runMatrix' is the thin IO loop that guarantees teardown.
-}
module HostBootstrap.Harness (
    Case (..),
    CaseResult (..),
    Report (..),
    Seams (..),
    TestSuite (..),
    emptySuite,
    testSuiteCaseIds,
    testSuiteCaseCount,
    allCasesSelector,
    runSuiteSelection,
    RunModel (..),
    Topology (..),
    RunModelKey (..),
    testCaseProfile,
    guardTestDelete,
    GuardError (..),
    sliceBudget,
    splitByWeight,
    selectRunModel,
    OneShotSpec (..),
    oneShotRunArgs,
    runMatrix,
    reportCard,
    allPassed,
    defaultSeams,
    oneShotSeams,
)
where

import Control.Exception (SomeException, try)
import Control.Exception.Safe (finally)
import Data.List (intercalate, isPrefixOf, partition)
import qualified Data.Text as T
import HostBootstrap.Cluster.Lifecycle (ClusterProfile (TestCase))
import qualified HostBootstrap.Config.Vocab as Vocab
import HostBootstrap.Ensure (runTool)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Docker))
import Numeric.Natural (Natural)
import System.Exit (ExitCode (ExitSuccess))

{- | A test case: an id, a budget-slicing weight, and whether it is indivisible
(e.g. a GPU case that cannot share a device and runs serially at full budget).
-}
data Case = Case
    { caseId :: String
    , caseWeight :: Natural
    , caseIndivisible :: Bool
    }
    deriving (Eq, Show)

-- | The outcome of one case.
data CaseResult = Pass | Fail String
    deriving (Eq, Show)

-- | The aggregated matrix report.
newtype Report = Report {reportResults :: [(String, CaseResult)]}
    deriving (Eq, Show)

{- | The seam record the harness is parameterized by. The app supplies how to set
up the isolated per-case environment, run the case body, and tear it down; the
harness guarantees teardown runs.
-}
data Seams env = Seams
    { seamSetup :: Case -> IO env
    , seamRun :: env -> Case -> IO CaseResult
    , seamTeardown :: env -> Case -> IO ()
    }

{- | The four run-models the wider system selects between (never declared in
Dhall; see 'selectRunModel').
-}
data RunModel = OneShot | HostNative | HostDaemon | Cluster
    deriving (Eq, Show)

-- | The generated topology — the spine of the run-model selection key.
data Topology = ContainerOnly | ClusterTopology | DaemonTopology
    deriving (Eq, Show)

{- | The run-model selection key: @(verb × detected-substrate × library-layer ×
generated-topology)@ collapsed to the two dimensions that decide the model —
the generated topology and whether a host-native build+exec is in force.
-}
data RunModelKey = RunModelKey
    { keyTopology :: Topology
    , keyHostNative :: Bool
    }
    deriving (Eq, Show)

{- | The isolated per-case cluster profile (@<project>-test-<case>@, data under
@./.test_data/<case>/@). Pure.
-}
testCaseProfile :: Case -> ClusterProfile
testCaseProfile c = TestCase (caseId c)

-- | A delete-guard error: a name that does not carry the test prefix.
data GuardError = NotPrefixed {guardPrefix :: String, guardName :: String}
    deriving (Eq, Show)

{- | The parameterized prefix delete-guard: the test-profile teardown refuses any
cluster name not carrying the project-supplied test prefix, so a harness run can
never delete a production cluster. Pure.
-}
guardTestDelete :: String -> String -> Either GuardError String
guardTestDelete prefix name
    | prefix `isPrefixOf` name = Right name
    | otherwise = Left (NotPrefixed prefix name)

{- | Split a budget proportionally across weights by floor division (the Haskell
mirror of @Core.dhall@ @split@; an empty/zero total yields zero slices).
-}
splitByWeight :: Vocab.Budget -> [Natural] -> [Vocab.Budget]
splitByWeight b weights =
    let total = sum weights
     in map
            ( \w ->
                if total == 0
                    then Vocab.Budget 0 0 0
                    else Vocab.Budget (b.cpu * w `div` total) (b.memory * w `div` total) (b.storage * w `div` total)
            )
            weights

{- | Slice the project budget across the case matrix: divisible cases share the
budget proportionally to weight (concurrent); indivisible (e.g. GPU) cases each
get the **full** budget and run serially at concurrency 1. Pure.
-}
sliceBudget :: Vocab.Budget -> [Case] -> [(Case, Vocab.Budget)]
sliceBudget budget cases =
    let (indivisible, divisible) = partition caseIndivisible cases
        slices = splitByWeight budget (map caseWeight divisible)
     in zip divisible slices ++ [(c, budget) | c <- indivisible]

{- | Select the run-model from the (collapsed) selection key. The generated
topology is the spine; a host-native build+exec promotes a container-only
topology to 'HostNative'. Never declared in Dhall. Pure.
-}
selectRunModel :: RunModelKey -> RunModel
selectRunModel key = case keyTopology key of
    ClusterTopology -> Cluster
    DaemonTopology -> HostDaemon
    ContainerOnly -> if keyHostNative key then HostNative else OneShot

{- | The inputs to a 'OneShot' container run: the image, the in-container
command, the budget caps (CPU cores and memory bytes), the bind mounts, and
whether to allocate a TTY.
-}
data OneShotSpec = OneShotSpec
    { oneShotImage :: String
    , oneShotCommand :: [String]
    , oneShotCpus :: Natural
    , oneShotMemoryBytes :: Integer
    , oneShotMounts :: [Vocab.Mount]
    , oneShotInteractive :: Bool
    }
    deriving (Eq, Show)

{- | The L0 'OneShot' model's @docker run --rm@ argv, budget-capped (@--cpus@ /
@--memory@) and mount-bound. Pure, so the argv is unit-tested; the IO seam
that runs it is app-supplied (it carries the resolved 'HostBootstrap.HostConfig'
and the resolved Docker tool). The default container-run seam ('defaultSeams')
ships in L0; this builder is what a real OneShot seam runs.
-}
oneShotRunArgs :: OneShotSpec -> [String]
oneShotRunArgs s =
    ["run", "--rm"]
        ++ ["-it" | oneShotInteractive s]
        ++ ["--cpus", show (oneShotCpus s), "--memory", show (oneShotMemoryBytes s)]
        ++ concatMap mountArg (oneShotMounts s)
        ++ [oneShotImage s]
        ++ oneShotCommand s
  where
    mountArg m =
        [ "-v"
        , T.unpack (Vocab.source m) ++ ":" ++ T.unpack (Vocab.target m) ++ (if Vocab.readOnly m then ":ro" else "")
        ]

{- | Drive the case matrix: per case run setup → body → teardown, guaranteeing
teardown via 'finally' (the body's exception is recorded as a 'Fail', not
leaked), and aggregate a 'Report'. A throwing /setup/ is isolated too — it
fails that one case (there is nothing to tear down, since setup did not
complete) rather than crashing the whole matrix.
-}
runMatrix :: Seams env -> [Case] -> IO Report
runMatrix seams cases = Report <$> mapM runOne cases
  where
    runOne c = do
        esetup <- try (seamSetup seams c)
        case esetup of
            Left (err :: SomeException) -> pure (caseId c, Fail ("setup: " ++ show err))
            Right env -> do
                result <-
                    (try (seamRun seams env c) :: IO (Either SomeException CaseResult))
                        `finally` seamTeardown seams env c
                pure (caseId c, either (Fail . show) id result)

{- | The default L0 seams: a one-shot container run (the 'OneShot' model). Setup
and teardown are no-ops because a one-shot @docker run --rm@ leaves nothing to
clean up; a cluster project supplies kind/Helm seams instead. The body is a
project-supplied closure in real use; this stub passes so the bare binary's
empty matrix runs cleanly.
-}
defaultSeams :: Seams ()
defaultSeams =
    Seams
        { seamSetup = \_ -> pure ()
        , seamRun = \_ _ -> pure Pass
        , seamTeardown = \_ _ -> pure ()
        }

{- | A project's complete test surface: its 'Seams' (with the per-project env type
hidden behind the existential) and the 'Case' matrix they drive. A project
supplies one 'TestSuite' to 'HostBootstrap.CLI.runHostBootstrapCLI'; the
inherited @test@ verb selects over it ('runSuiteSelection'). The bare binary
ships 'emptySuite' through its explicit bare entrypoint.
-}
data TestSuite = forall env. TestSuite (Seams env) [Case]

{- | The empty suite the bare @hostbootstrap@ binary ships: the trivial
'defaultSeams' over no cases, so @test all@ renders @0/0 passed@.
-}
emptySuite :: TestSuite
emptySuite = TestSuite defaultSeams []

{- | The case ids in a suite. Used by the CLI layer to reject accidental empty or
duplicate project suites before command dispatch.
-}
testSuiteCaseIds :: TestSuite -> [String]
testSuiteCaseIds (TestSuite _ cases) = map caseId cases

-- | The number of cases in a suite.
testSuiteCaseCount :: TestSuite -> Int
testSuiteCaseCount = length . testSuiteCaseIds

{- | The reserved selector that runs the whole matrix. It is always available on
every binary (injected by the inherited @test@ verb), so a project may not name
a case @all@.
-}
allCasesSelector :: String
allCasesSelector = "all"

{- | Resolve a @test@ selector against a suite and run the chosen case(s):
'allCasesSelector' runs the whole matrix; any other value runs the single case
with that id; an unknown id is a 'Left' naming the valid case ids plus @all@,
so the inherited @test@ verb can fail fast. The selection happens inside the
existential unwrap, where the 'Seams' env type stays hidden.
-}
runSuiteSelection :: TestSuite -> String -> IO (Either String Report)
runSuiteSelection (TestSuite seams cases) selector
    | selector == allCasesSelector = Right <$> runMatrix seams cases
    | otherwise = case filter ((== selector) . caseId) cases of
        [] -> pure (Left unknown)
        chosen -> Right <$> runMatrix seams chosen
  where
    unknown =
        "unknown test case "
            ++ show selector
            ++ "; available: "
            ++ intercalate ", " (map caseId cases ++ [allCasesSelector])

{- | The real L0 'OneShot' container-run seam: each case runs @docker run --rm@
(budget-capped via 'oneShotRunArgs') through the resolved Docker tool, passing
iff the container exits zero. The app supplies the resolved 'HostConfig' and a
per-case 'OneShotSpec'; there is no setup/teardown because a @--rm@ run is
self-cleaning. The IO is wired here (like @cluster up@); the live container run
is exercised in real runs. 'defaultSeams' remains the trivial pass-through for
the bare binary's empty matrix.
-}
oneShotSeams :: HostConfig -> (Case -> OneShotSpec) -> Seams ()
oneShotSeams cfg specFor =
    Seams
        { seamSetup = \_ -> pure ()
        , seamRun = \_ c -> do
            result <- runTool cfg Docker (oneShotRunArgs (specFor c))
            pure $ case result of
                Right (ExitSuccess, _, _) -> Pass
                Right (_, _, err) -> Fail err
                Left err -> Fail err
        , seamTeardown = \_ _ -> pure ()
        }

-- | Whether every case passed.
allPassed :: Report -> Bool
allPassed (Report rs) = all ((== Pass) . snd) rs

-- | Render a human-readable report card.
reportCard :: Report -> String
reportCard (Report rs) =
    unlines
        ( ("test report: " ++ show (length (filter ((== Pass) . snd) rs)) ++ "/" ++ show (length rs) ++ " passed")
            : map line rs
        )
  where
    line (cid, Pass) = "  PASS " ++ cid
    line (cid, Fail msg) = "  FAIL " ++ cid ++ " — " ++ msg
