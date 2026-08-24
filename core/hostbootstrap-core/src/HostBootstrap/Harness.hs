{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

{- | The one standardized, Dhall-driven test harness.

Every project's tests run through this single L0 engine: per message variant it
generates **one** run config and brings a single test stack up, then drives that
variant's chosen cases against the shared, already-up environment via 'runMatrix'
(whose per-case 'Seams' are built internally by @assertSeams@), tearing the stack
down once per variant while preserving production @.data@. The harness is
parameterized by a 'Seams' record for the live-stack assertions, and the app
supplies only the case matrix and assertion environment (see
@development_plan_standards.md § S, § T@).  Lifecycle setup and reversal are
supplied by the command boundary from the exact Harness-scoped project plan;
they are not project-owned test-suite callbacks.

The self-created-data removal decision and report aggregation are pure;
'runMatrix' is the thin IO loop that guarantees teardown. Execution shape comes
only from the project's lifecycle step plan, never from a parallel harness
selector.
-}
module HostBootstrap.Harness (
    CaseId,
    caseIdText,
    mkCaseId,
    VariantId,
    variantIdText,
    mkVariantId,
    IdentifierError (..),
    CaseSelector,
    parseCaseSelector,
    VariantDraft,
    variantDraft,
    variantDraftId,
    variantDraftValue,
    TestMatrix,
    TestMatrixError (..),
    mkTestMatrix,
    emptyTestMatrix,
    testMatrixCaseIds,
    testMatrixVariantIds,
    SelectedVariant,
    selectedVariantDraft,
    selectedVariantCaseIds,
    selectTestMatrix,
    Case (..),
    CaseLifecycle (..),
    AssertionPhase (..),
    CaseResult (..),
    caseResultPassed,
    caseResultLabel,
    caseResultReason,
    Report (..),
    Seams (..),
    TestSuite (..),
    emptySuite,
    testSuiteCaseIds,
    testSuiteCaseCount,
    allCasesSelector,
    HarnessLifecycle,
    runHarnessForward,
    runHarnessRestart,
    runHarnessReverse,
    ConfigVariant (..),
    SafetyRefusal (..),
    safetyRefusalMarker,
    LifecycleFailure (..),
    lifecycleFailureMarker,
    conflictObservationMarker,
    unsupportedObservationMarker,
    refusedObservationMarker,
    classifyLifecycleReason,
    runSuiteSelection,
    testSafetyPreconditions,
    testDataRoot,
    testDataGeneration,
    selfCreatedTestDataRemoval,
    HarnessRunCleanupFailure (..),
    HarnessRunOwnership (..),
    runMatrix,
    reportCard,
    allPassed,
)
where

import Control.Exception (Exception, SomeAsyncException, SomeException, displayException, fromException, tryJust)
import Control.Exception.Safe (finally)
import Data.Char (isAlphaNum)
import Data.List (group, isInfixOf, sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import HostBootstrap.Harness.Lifecycle.Internal (
    HarnessLifecycle,
    runHarnessForward,
    runHarnessRestart,
    runHarnessReverse,
 )
import HostBootstrap.Step (
    conflictObservationMarker,
    refusedObservationMarker,
    unsupportedObservationMarker,
 )
import Numeric.Natural (Natural)
import System.FilePath ((</>))

{- | A validated, stable test-case identity. Construction rejects empty,
reserved, or malformed text; the constructor remains private so every value has
passed the same boundary.
-}
newtype CaseId = CaseId T.Text
    deriving (Eq, Ord)

instance Show CaseId where
    show = show . caseIdText

caseIdText :: CaseId -> T.Text
caseIdText (CaseId value) = value

{- | A validated, stable configuration-variant identity. It is reporting and
configuration identity only: it grants no lifecycle ownership.
-}
newtype VariantId = VariantId T.Text
    deriving (Eq, Ord)

instance Show VariantId where
    show = show . variantIdText

variantIdText :: VariantId -> T.Text
variantIdText (VariantId value) = value

data IdentifierError
    = EmptyCaseId
    | InvalidCaseId T.Text
    | ReservedCaseId T.Text
    | EmptyVariantId
    | InvalidVariantId T.Text
    deriving (Eq, Show)

mkCaseId :: T.Text -> Either IdentifierError CaseId
mkCaseId raw
    | T.null raw = Left EmptyCaseId
    | raw == T.pack allCasesSelector = Left (ReservedCaseId raw)
    | not (validIdentifier raw) = Left (InvalidCaseId raw)
    | otherwise = Right (CaseId raw)

mkVariantId :: T.Text -> Either IdentifierError VariantId
mkVariantId raw
    | T.null raw = Left EmptyVariantId
    | not (validIdentifier raw) = Left (InvalidVariantId raw)
    | otherwise = Right (VariantId raw)

validIdentifier :: T.Text -> Bool
validIdentifier value =
    case T.uncons value of
        Nothing -> False
        Just (first, rest) -> isAlphaNum first && T.all validRest rest
  where
    validRest c = isAlphaNum c || c `elem` ("-._" :: String)

data CaseSelector = AllCases | SelectedCase CaseId
    deriving (Eq, Show)

parseCaseSelector :: T.Text -> Either IdentifierError CaseSelector
parseCaseSelector raw
    | raw == T.pack allCasesSelector = Right AllCases
    | otherwise = SelectedCase <$> mkCaseId raw

{- | A pure project-owned variant declaration. The payload may carry typed
configuration inputs, but the draft itself contains no run, plan, rendered
config, lease, or cleanup action.
-}
data VariantDraft a = VariantDraft VariantId a
    deriving (Eq, Show)

variantDraft :: VariantId -> a -> VariantDraft a
variantDraft = VariantDraft

variantDraftId :: VariantDraft a -> VariantId
variantDraftId (VariantDraft ident _) = ident

variantDraftValue :: VariantDraft a -> a
variantDraftValue (VariantDraft _ value) = value

{- | Construction failures for the opaque total case-to-variant relation.
Every error is discovered before the harness performs a mutation.
-}
data TestMatrixError
    = EmptyCaseRegistry
    | DuplicateCaseIds [CaseId]
    | EmptyVariantRegistry
    | DuplicateVariantIds [VariantId]
    | MissingCaseRows [CaseId]
    | UnknownCaseRows [CaseId]
    | DuplicateCaseRows [CaseId]
    | EmptyVariantRow CaseId
    | UnknownVariantReferences [(CaseId, VariantId)]
    | DuplicateVariantPairs [(CaseId, VariantId)]
    | OrphanVariants [VariantId]
    | UnknownSelectedCase CaseId
    | {- | A project projected its variant set from decoded configuration and one
      declaration is not a valid identity. The matrix is where a project's own
      config becomes the run's variants, so a malformed declaration is a matrix
      construction error — discovered before any mutation, like every other
      member of this type.
      -}
      InvalidVariantDeclaration IdentifierError
    deriving (Eq, Show)

data TestMatrix a = TestMatrix
    { matrixCases :: [CaseId]
    , matrixVariants :: [VariantDraft a]
    , matrixRows :: [(CaseId, NonEmpty VariantId)]
    }
    deriving (Eq, Show)

{- | The sole validated matrix constructor. Input rows deliberately use lists so
an empty row can be diagnosed rather than made unrepresentable only at a caller.
-}
mkTestMatrix ::
    [CaseId] ->
    [VariantDraft a] ->
    [(CaseId, [VariantId])] ->
    Either TestMatrixError (TestMatrix a)
mkTestMatrix caseRegistry variantRegistry rows = do
    nonEmptyCases <- maybe (Left EmptyCaseRegistry) Right (NE.nonEmpty caseRegistry)
    let duplicateCases = duplicates caseRegistry
    unlessEither (null duplicateCases) (DuplicateCaseIds duplicateCases)
    nonEmptyVariants <- maybe (Left EmptyVariantRegistry) Right (NE.nonEmpty variantRegistry)
    let variantIds = map variantDraftId variantRegistry
        duplicateVariants = duplicates variantIds
    unlessEither (null duplicateVariants) (DuplicateVariantIds duplicateVariants)
    let rowCaseIds = map fst rows
        duplicateRows = duplicates rowCaseIds
        missingRows = filter (`notElem` rowCaseIds) caseRegistry
        unknownRows = filter (`notElem` caseRegistry) rowCaseIds
    unlessEither (null duplicateRows) (DuplicateCaseRows duplicateRows)
    unlessEither (null missingRows) (MissingCaseRows missingRows)
    unlessEither (null unknownRows) (UnknownCaseRows unknownRows)
    case [cid | (cid, refs) <- rows, null refs] of
        cid : _ -> Left (EmptyVariantRow cid)
        [] -> pure ()
    let unknownRefs =
            [ (cid, vid)
            | (cid, refs) <- rows
            , vid <- refs
            , vid `notElem` variantIds
            ]
        duplicatePairs =
            concatMap
                (\(cid, refs) -> map (cid,) (duplicates refs))
                rows
    unlessEither (null unknownRefs) (UnknownVariantReferences unknownRefs)
    unlessEither (null duplicatePairs) (DuplicateVariantPairs duplicatePairs)
    let referenced = concatMap snd rows
        orphans = filter (`notElem` referenced) variantIds
    unlessEither (null orphans) (OrphanVariants orphans)
    totalRows <-
        traverse
            (\(cid, refs) -> maybe (Left (EmptyVariantRow cid)) (\nonEmptyRefs -> Right (cid, nonEmptyRefs)) (NE.nonEmpty refs))
            rows
    nonEmptyCases `seq` nonEmptyVariants `seq` pure (TestMatrix caseRegistry variantRegistry totalRows)

{- | Bare-core-only empty matrix. Real project specs are rejected when their
Haskell suite is empty and cannot construct this through 'mkTestMatrix'.
-}
emptyTestMatrix :: TestMatrix ()
emptyTestMatrix = TestMatrix [] [] []

testMatrixCaseIds :: TestMatrix a -> [CaseId]
testMatrixCaseIds (TestMatrix cases _ _) = cases

testMatrixVariantIds :: TestMatrix a -> [VariantId]
testMatrixVariantIds (TestMatrix _ variants _) = map variantDraftId variants

data SelectedVariant a = SelectedVariant (VariantDraft a) (NonEmpty CaseId)
    deriving (Eq, Show)

selectedVariantDraft :: SelectedVariant a -> VariantDraft a
selectedVariantDraft (SelectedVariant draft _) = draft

selectedVariantCaseIds :: SelectedVariant a -> NonEmpty CaseId
selectedVariantCaseIds (SelectedVariant _ cases) = cases

{- | Project one case or the complete registry from an already-total matrix.
Variants retain registry order and are emitted once even when shared by cases.
-}
selectTestMatrix :: CaseSelector -> TestMatrix a -> Either TestMatrixError [SelectedVariant a]
selectTestMatrix selector (TestMatrix cases variants rows) = do
    chosenCases <-
        case selector of
            AllCases -> Right cases
            SelectedCase cid
                | cid `elem` cases -> Right [cid]
                | otherwise -> Left (UnknownSelectedCase cid)
    pure (mapMaybe (selectedFor chosenCases) variants)
  where
    selectedFor chosenCases draft =
        SelectedVariant draft
            <$> NE.nonEmpty
                [ cid
                | cid <- chosenCases
                , Just refs <- [lookup cid rows]
                , variantDraftId draft `elem` NE.toList refs
                ]

unlessEither :: Bool -> e -> Either e ()
unlessEither condition err
    | condition = Right ()
    | otherwise = Left err

duplicates :: (Ord a) => [a] -> [a]
duplicates = foldr duplicate [] . group . sort
  where
    duplicate (value : _ : _) rest = value : rest
    duplicate _ rest = rest

{- | A test case: an id, a budget-slicing weight, and whether it is indivisible
(e.g. a GPU case that cannot share a device and runs serially at full budget).
-}
data CaseLifecycle
    = AssertOnce
    | AssertAcrossRestart
    deriving (Eq, Show)

data AssertionPhase
    = BeforeRestart
    | AfterRestart
    deriving (Eq, Show)

data Case = Case
    { caseId :: CaseId
    , caseWeight :: Natural
    , caseIndivisible :: Bool
    , caseLifecycle :: CaseLifecycle
    }
    deriving (Eq, Show)

{- | The outcome of one case.

Non-passing outcomes are __distinct__, not one flattened failure string
(development_plan_standards § Y, § Z): "the assertion said no", "we refused
before touching operator state", "the lifecycle broke", and "cleanup broke" have
different operator consequences, so the report card names which one happened
instead of leaving the reader to parse a prefix.

'Fail' is the project's own verdict; every other non-passing constructor is the
engine's classification of a lifecycle outcome, so a project assertion cannot
label itself a refusal or a teardown failure.
-}
data CaseResult
    = Pass
    | -- | The case's own assertion said no.
      Fail String
    | {- | A post-ensure safety probe found pre-existing operator state. Nothing
      was acquired, so nothing is torn down and no foreign state is touched.
      -}
      Refused String
    | {- | An attempted lifecycle operation failed. The run's owned state is torn
      down; the cause is the reason, never a bare exit code (§ CC).
      -}
      LifecycleFailed String
    | {- | A node observed a conflict: the resource it names exists and is not
      what this run's plan describes. An operator resolves it; a rerun will
      observe the same thing.
      -}
      Conflicted String
    | {- | A node's backend cannot represent it on this substrate. The lane was
      not run rather than run and broken, so it reads as skipped.
      -}
      Unsupported String
    | {- | Cleanup failed. The variant is red rather than green with leaked
      state, and the reason names what could not be released.
      -}
      TeardownFailed String
    deriving (Eq, Show)

{- | Whether an outcome is a pass. Total, so adding an outcome cannot silently
be counted as success.
-}
caseResultPassed :: CaseResult -> Bool
caseResultPassed outcome = case outcome of
    Pass -> True
    Fail _ -> False
    Refused _ -> False
    -- A skipped lane did not do what was asked, so it is not a pass. It is a
    -- distinct row so an operator can tell it from a broken one.
    Conflicted _ -> False
    Unsupported _ -> False
    LifecycleFailed _ -> False
    TeardownFailed _ -> False

{- | The fixed-width report-card label for an outcome. Distinct labels are the
point: an operator scanning a report can tell a broken assertion from a refusal
from leaked state without reading the reason.
-}
caseResultLabel :: CaseResult -> String
caseResultLabel outcome = case outcome of
    Pass -> "PASS     "
    Fail _ -> "FAIL     "
    Refused _ -> "REFUSED  "
    Conflicted _ -> "CONFLICT "
    Unsupported _ -> "SKIPPED  "
    LifecycleFailed _ -> "BROKEN   "
    TeardownFailed _ -> "LEAKED?  "

-- | The reason an outcome carries, if it carries one.
caseResultReason :: CaseResult -> Maybe String
caseResultReason outcome = case outcome of
    Pass -> Nothing
    Fail reason -> Just reason
    Refused reason -> Just reason
    Conflicted reason -> Just reason
    Unsupported reason -> Just reason
    LifecycleFailed reason -> Just reason
    TeardownFailed reason -> Just reason

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

{- | The canonical durable directory for test runs (development_plan_standards § Z):
test durable storage is always @.test_data@, **never** @.data@.

This is the shared /parent/ only. A run never owns this directory: it owns the
per-run generation @.test_data\/\<runId\>@ underneath it, derived by
'testDataGeneration'. The parent is ordinary project scaffolding — created if
missing, never bound to a receipt and never removed — so two runs cannot contend
for the same durable object, and a crashed predecessor's generation is
identifiable by name as well as by kernel identity.
-}
testDataRoot :: FilePath
testDataRoot = ".test_data"

{- | The durable generation one harness run owns: @.test_data\/\<runId\>@
(development_plan_standards § Z). The run identity is generative, so no two runs
— concurrent or sequential — can name the same generation, and the terminal
close projection releases exactly the generation its own @runId@ names.
-}
testDataGeneration :: FilePath -> T.Text -> FilePath
testDataGeneration parent run = parent </> T.unpack run

{- | The **self-created-only** delete-guard removal set for a run's @.test_data@
directory (development_plan_standards § Z): a directory this run created is
removed on teardown; a directory that already existed is **preserved** (mirroring
the never-delete-@.data@ invariant — the harness never deletes a config or data
directory it merely /found/). Pure, so the guard is unit-tested.
-}
selfCreatedTestDataRemoval :: Bool -> FilePath -> [FilePath]
selfCreatedTestDataRemoval preexisting path = [path | not preexisting]

{- | The exclusive-run-ownership bracket the engine runs its variants inside.

The engine deliberately does not implement ownership itself: the protected
store, project-wide mode, run lease, and abandoned-run sweep live in
"HostBootstrap.Harness.Ownership", which the command layer builds from the
project the binary *is*. The engine only requires that *some* bracket takes
ownership before a variant runs and releases it afterwards, and that a refusal
is a 'Left' rather than an exception.
-}
data HarnessRunCleanupFailure
    = -- | The run's exact generated data-root identity could not be released.
      HarnessDataRootCleanupFailed String
    | -- | The run's own generated-config ownership record could not be settled.
      HarnessGeneratedConfigCleanupFailed String
    | -- | The run lease and project-wide Harness mode could not be closed.
      HarnessModeCloseFailed String
    deriving (Eq, Show)

newtype HarnessRunOwnership authority = HarnessRunOwnership
    { runWithOwnedRun ::
        forall result.
        -- The value is supplied only after the ownership bracket acquires the
        -- generative root. Production uses an opaque typed root; unit seams may
        -- use a simpler witness while exercising engine behavior.
        (authority -> IO result) ->
        -- Acquisition refusals are the outer 'Left'. Once the body completes,
        -- its result is retained even when the finalizer reports that ownership
        -- remains unresolved; the engine renders that failure as teardown and
        -- must not start a later variant.
        IO (Either String (result, Maybe HarnessRunCleanupFailure))
    }

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
        esetup <- trySynchronousIO (seamSetup seams c)
        case esetup of
            Left (err :: SomeException) ->
                pure (renderCaseId c, LifecycleFailed ("setup: " ++ displayException err))
            Right env -> do
                result <-
                    trySynchronousIO (seamRun seams env c)
                        `finally` seamTeardown seams env c
                pure (renderCaseId c, either (LifecycleFailed . displayException) id result)
    renderCaseId = T.unpack . caseIdText . caseId

{- | A project's complete assertion surface (development_plan_standards § W,
§ Z).  The suite owns no lifecycle callback: the command boundary retains one
exact Harness-scoped project plan per variant and supplies its common forward
and reverse interpreters through 'ConfigVariant'.  A project supplies only:

  1. the two hard fail-fast safety preconditions (§ Z): @Right ()@ to proceed,
     @Left reason@ to refuse before any side effect — built with
     'testSafetyPreconditions';
  2. an assertion-environment opener, run after the common forward interpreter
     has brought the exact variant plan up;
  3. the 'Case' matrix the assertions cover; and
  4. the per-case assertion against that live stack; and
  5. a post-reverse assertion that verifies the exact plan's owned resources
     are absent after the common reverse interpreter succeeds.

The existential @env@ hides the per-project assertion environment.  Removing
lifecycle actions from this type is the structural single-representation
boundary: a 'TestSuite' cannot supply a second top-level bring-up or teardown
path.  The bare binary ships 'emptySuite' through its explicit bare entrypoint.
-}
data TestSuite
    = forall env.
        TestSuite
        (IO (Either String ()))
        (AssertionPhase -> VariantId -> IO env)
        [Case]
        (env -> Case -> IO CaseResult)
        (IO ())

{- | The empty suite the bare @hostbootstrap@ binary ships: no safety obstacle, a
trivial assertion environment over no cases, so @test run all@ renders @0/0 passed@.
-}
emptySuite :: TestSuite
emptySuite = TestSuite (pure (Right ())) (\_ _ -> pure ()) [] (\_ _ -> pure Pass) (pure ())

{- | The case ids in a suite. Used by the CLI layer to reject accidental empty or
duplicate project suites before command dispatch.
-}
testSuiteCaseIds :: TestSuite -> [CaseId]
testSuiteCaseIds (TestSuite _ _ cases _ _) = map caseId cases

-- | The number of cases in a suite.
testSuiteCaseCount :: TestSuite -> Int
testSuiteCaseCount = length . testSuiteCaseIds

{- | The reserved selector that runs the whole matrix. It is always available on
every binary (injected by the inherited @test@ verb), so a project may not name
a case @all@.
-}
allCasesSelector :: String
allCasesSelector = "all"

{- | One already-selected test-config variant the command layer supplies to
'runSuiteSelection': its stable identity, non-empty typed case selection, and
the rank-2 bracket that owns the generated @<project>.dhall@ while retaining one
exact Harness project plan.  The bracket supplies that plan's common lifecycle
actions and removes the generated config only after the engine has interpreted
both directions.
-}
data ConfigVariant authority = ConfigVariant
    { variantId :: VariantId
    , variantCaseIds :: NonEmpty CaseId
    , variantWithLifecycle ::
        forall a.
        authority ->
        (HarnessLifecycle -> IO a) ->
        IO a
    }

{- | A post-ensure safety probe discovered pre-existing operator state. Cleanup
must not run because the harness never acquired ownership of that state.
-}
newtype SafetyRefusal = SafetyRefusal {safetyRefusalReason :: String}
    deriving (Eq)

instance Show SafetyRefusal where
    show (SafetyRefusal reason) = safetyRefusalMarker ++ " " ++ reason

instance Exception SafetyRefusal

safetyRefusalMarker :: String
safetyRefusalMarker = "HOSTBOOTSTRAP_SAFETY_REFUSAL:"

{- | Classify one lifecycle failure's cause into the outcome it actually was.

An interpreted chain stops on the first node that did not reach its target state
and reports that node's own row, so the reason a bring-up failure carries already
names which of the three it was. The marker constants are owned by
'HostBootstrap.Step.StepObservation' and re-exported here, so rendering and
classification share one lower-level vocabulary.

'Nothing' is the honest answer for a cause that names none of them: it is an
ordinary lifecycle failure and the caller renders it as such rather than guessing.
-}
classifyLifecycleReason :: String -> Maybe CaseResult
classifyLifecycleReason reason
    | conflictObservationMarker `isInfixOf` reason = Just (Conflicted reason)
    | unsupportedObservationMarker `isInfixOf` reason = Just (Unsupported reason)
    | refusedObservationMarker `isInfixOf` reason = Just (Refused reason)
    | otherwise = Nothing

{- | A structured bring-up failure carrying its cause across the self-reference
subprocess boundary and the harness catch — the peer of 'SafetyRefusal'
(development_plan_standards § CC). A lifecycle step that fails throws this instead
of a message-less @die@ ('System.Exit.die' throws @ExitFailure 1@ with no cause),
so the report card renders the reason via 'displayException' rather than the
literal @"ExitFailure 1"@. Its 'Show' prints the 'lifecycleFailureMarker' so the
cause survives the subprocess round-trip exactly as 'SafetyRefusal' does: a parent
runner detects the marker in the child's stderr and re-raises the carried reason
(never a bare exit code). 'displayException' is the marker-free cause the harness
report card renders.
-}
newtype LifecycleFailure = LifecycleFailure {lifecycleFailureReason :: String}
    deriving (Eq)

instance Show LifecycleFailure where
    show (LifecycleFailure reason) = lifecycleFailureMarker ++ " " ++ reason

instance Exception LifecycleFailure where
    displayException (LifecycleFailure reason) = reason

lifecycleFailureMarker :: String
lifecycleFailureMarker = "HOSTBOOTSTRAP_LIFECYCLE_FAILURE:"

{- | The suite-level half of the hard fail-fast safety preconditions
(development_plan_standards § Z): refuse if a production cluster is already
running. The caller supplies the detector, since "running" is
substrate/tool-specific, and core cannot know how to perform it.

The other half — refuse if a production @<project>.dhall@ already exists — is
deliberately __not__ here. It used to be checked in three places, and this one
(like the command layer's) ran before the ownership bracket, so an interrupted
run's own generated config made the next run refuse /before/
'HostBootstrap.Lifecycle.Mode.recoverAbandonedHarnessRuns' could resolve it: the
recovery machinery was unreachable in exactly the case it was built for. The
authoritative check is 'HostBootstrap.Lifecycle.Mode.harnessPreconditions',
which derives its subject from installed project identity — a caller cannot
claim a config is absent — and runs inside the protected transaction that takes
the mode, after the sweep (the test-harness-and-run-ownership phase).

Pure obstacle reporting: returns @Right ()@ only when the obstacle is absent.
-}
testSafetyPreconditions :: IO Bool -> IO (Either String ())
testSafetyPreconditions productionClusterRunning = do
    running <- productionClusterRunning
    pure $
        if running
            then Left "a production cluster is already running; refusing to touch production state"
            else Right ()

{- | Enforce the safety preconditions, then loop over the typed matrix selection
the command layer supplies.  For each variant the exact-plan bracket generates
the run config, invokes the common forward interpreter, opens the suite's
assertion environment, runs the selected assertions, invokes the common reverse
interpreter, and finally releases the generated config.  Selector parsing and
total-matrix projection occur before this engine.  A refused safety precondition
is a 'Left' and **no plan, config, or lifecycle effect is opened**.  The per-case
loop reuses 'runMatrix', so the harness owns no second bring-up path (§ W).

Each 'ConfigVariant' is supplied by the command layer from the project's @tcfg@,
scope-aware restricted assembler, and one exact Harness 'ProjectPlan'.  Its
bracket runs after the safety precondition and encloses forward interpretation,
assertions, reverse interpretation, and generated-config release.  The safety
precondition is checked once up front; the per-variant reports are aggregated
into one 'Report', each row identified by its stable variant ID.
-}
runSuiteSelection ::
    HarnessRunOwnership authority ->
    TestSuite ->
    [ConfigVariant authority] ->
    IO (Either String Report)
runSuiteSelection ownership (TestSuite safety openAssertions cases assertCase assertReversed) variants = do
    safe <- safety
    case safe of
        Left reason -> pure (Left ("test run refused: " ++ reason))
        -- Every distinct config variant receives its own generative run lease
        -- and `.test_data/<runId>` lifetime (§ Z). Cases sharing a variant share
        -- that stack; the next variant cannot start until the preceding ownership
        -- bracket has resolved. Each variant's generated config and lifecycle are
        -- nested inside that bracket, and the resulting reports are concatenated.
        Right () -> do
            variantReports <- runVariants variants
            pure (Right (Report (concatMap reportResults variantReports)))
  where
    runVariants [] = pure []
    runVariants (cv : rest) = do
        (report, cleanupFailure) <- safeRunVariant cv
        case cleanupFailure of
            Nothing -> (report :) <$> runVariants rest
            Just failure ->
                -- A failed finalizer has not proved the prior lease closed. Do
                -- not even enter another ownership bracket; preserve a total
                -- report by refusing every still-unstarted variant.
                pure (report : map (blockedByCleanup failure) rest)
    -- A whole variant is isolated, including its ownership acquisition. An
    -- ownership refusal is a structured refusal for that variant; an unexpected
    -- exception anywhere in the bracket/config/lifecycle fails only that variant.
    -- In both cases the loop can continue only after the ownership bracket has
    -- returned, so no two variants overlap one project-wide mode lease.
    safeRunVariant cv@(ConfigVariant ident selected _) = do
        let chosen = casesFor selected
        e <-
            trySynchronousIO
                ( runWithOwnedRun ownership $ \ownedAuthority ->
                    runVariant chosen cv ownedAuthority
                )
        pure $ case e of
            Right (Right (report, Nothing)) -> (report, Nothing)
            Right (Right (report, Just failure)) ->
                ( addRows report (reportResults (labelReport ident (Report [cleanupFailureRow failure])))
                , Just failure
                )
            Right (Left reason) ->
                ( labelReport
                    ident
                    (allOutcomes chosen (Refused ("ownership refused: " ++ reason)))
                , Nothing
                )
            Left err ->
                ( labelReport
                    ident
                    (allOutcomes chosen (LifecycleFailed ("variant failed: " ++ displayException err)))
                , Nothing
                )
    blockedByCleanup failure (ConfigVariant ident selected _) =
        labelReport
            ident
            ( allOutcomes
                (casesFor selected)
                ( Refused
                    ( "prior variant ownership cleanup is unresolved; refusing to start this variant: "
                        ++ cleanupFailureReason failure
                    )
                )
            )
    -- Forward interpretation is **inside** the exact plan's guaranteed reverse
    -- path.  A non-refusal failure still drives the same plan's reverse
    -- projection before the variant reports red.  'safeRunVariant' catches
    -- anything that escapes, so later variants can run only after the ownership
    -- bracket has resolved.
    runVariant chosen (ConfigVariant ident _ withLifecycle) ownedAuthority =
        labelReport ident
            <$> withLifecycle
                ownedAuthority
                (runFrame chosen ident)
    runFrame chosen ident lifecycle = do
        forwarded <- trySynchronousIO (runHarnessForward lifecycle)
        case forwarded of
            Left err ->
                case fromException err :: Maybe SafetyRefusal of
                    -- A refusal proven to precede acquisition has an empty
                    -- rollback set (§ Y), so teardown deliberately does not run
                    -- and the operator's state is not touched.
                    Just refusal ->
                        pure (allOutcomes chosen (Refused (safetyRefusalReason refusal)))
                    -- Render the CAUSE, not @show err@: a 'LifecycleFailure' (or any
                    -- structured exception) surfaces its reason via 'displayException'
                    -- rather than collapsing to the literal @"ExitFailure 1"@ a
                    -- message-less @die@ would print (development_plan_standards § CC).
                    -- What the failing node observed is already in the cause,
                    -- so the row it produces is that node's own outcome rather
                    -- than one undifferentiated BROKEN (§ Y).
                    Nothing ->
                        withReverse
                            lifecycle
                            chosen
                            ( pure
                                ( allOutcomes
                                    chosen
                                    (forwardOutcome (displayException err))
                                )
                            )
            Right () ->
                withReverse lifecycle chosen $ do
                    initial <- runAssertions BeforeRestart chosen ident
                    let restartCases = filter ((== AssertAcrossRestart) . caseLifecycle) chosen
                    if null restartCases || not (casesPassed restartCases initial)
                        then pure initial
                        else do
                            restarted <- trySynchronousIO (runHarnessRestart lifecycle)
                            case restarted of
                                Left err ->
                                    pure
                                        ( replaceCaseRows
                                            initial
                                            restartCases
                                            (LifecycleFailed ("same-run restart failed: " ++ displayException err))
                                        )
                                Right () -> do
                                    after <- runAssertions AfterRestart restartCases ident
                                    pure (mergeCaseRows initial after)
    runAssertions phase selectedCases ident = do
        eenv <- trySynchronousIO (openAssertions phase ident)
        case eenv of
            Left err -> pure (variantBroke selectedCases err)
            Right env -> runMatrix (assertSeams env) selectedCases
    casesPassed selectedCases (Report rows) =
        all
            ( \selectedCase ->
                lookup (T.unpack (caseIdText (caseId selectedCase))) rows == Just Pass
            )
            selectedCases
    replaceCaseRows (Report rows) selectedCases outcome =
        Report
            [ if rowId `elem` selectedIds then (rowId, outcome) else row
            | row@(rowId, _) <- rows
            ]
      where
        selectedIds = map (T.unpack . caseIdText . caseId) selectedCases
    mergeCaseRows (Report initialRows) (Report replacementRows) =
        Report
            [ maybe row (rowId,) (lookup rowId replacementRows)
            | row@(rowId, _) <- initialRows
            ]
    {- Reverse interpretation always runs after acquisition.  The suite's
    post-reverse assertion runs only after that interpreter returns success, so
    it can verify absence without becoming a lifecycle effect.  Either failure is a
    \*distinct* outcome appended to the variant's rows: cleanup that broke makes
    the variant red with the cause named, rather than a green report hiding
    leaked state (§ Z). The per-case results are preserved, because "the
    assertions passed but the stack did not come down" is exactly what an
    operator needs to read. -}
    withReverse lifecycle chosen body = do
        ran <- trySynchronousIO body
        torn <- trySynchronousIO (runHarnessReverse lifecycle >> assertReversed)
        pure $ case (ran, torn) of
            (Right report, Right ()) -> report
            (Right report, Left err) -> addRows report [teardownRow err]
            (Left err, Right ()) -> variantBroke chosen err
            (Left err, Left tornErr) ->
                addRows (variantBroke chosen err) [teardownRow tornErr]
    forwardOutcome cause =
        case classifyLifecycleReason cause of
            Just classified -> classified
            Nothing -> LifecycleFailed ("bring-up failed: " ++ cause)
    variantBroke chosen err =
        allOutcomes chosen (LifecycleFailed ("variant failed: " ++ displayException err))
    teardownRow err = ("teardown", TeardownFailed (displayException err))
    cleanupFailureRow failure = case failure of
        HarnessDataRootCleanupFailed reason ->
            ("data-root cleanup", TeardownFailed reason)
        HarnessGeneratedConfigCleanupFailed reason ->
            ("generated-config cleanup", TeardownFailed reason)
        HarnessModeCloseFailed reason ->
            ("mode close", TeardownFailed reason)
    cleanupFailureReason failure = case failure of
        HarnessDataRootCleanupFailed reason -> "data-root cleanup failed: " ++ reason
        HarnessGeneratedConfigCleanupFailed reason ->
            "generated-config cleanup failed: " ++ reason
        HarnessModeCloseFailed reason -> "mode close failed: " ++ reason
    addRows (Report rs) extra = Report (rs ++ extra)
    -- Every chosen case carries one engine-classified outcome (the bring-up or
    -- variant failure), so the whole variant reports the same structured reason.
    allOutcomes chosen outcome =
        Report [(T.unpack (caseIdText (caseId c)), outcome) | c <- chosen]
    casesFor selected =
        [c | c <- cases, caseId c `elem` NE.toList selected]
    -- Reuse the per-case loop: the common forward interpreter produced the live
    -- stack shared by every assertion; plan reversal is variant-wide, so the
    -- per-case teardown is a no-op.
    assertSeams env =
        Seams
            { seamSetup = \_ -> pure env
            , seamRun = assertCase
            , seamTeardown = \_ _ -> pure ()
            }
    -- Prefix each case id with the stable variant ID so the aggregated report card
    -- attributes every row to the variant it ran under.
    labelReport ident (Report rs) =
        Report [("[" ++ T.unpack (variantIdText ident) ++ "] " ++ cid, r) | (cid, r) <- rs]

{- | Catch synchronous failures while allowing cancellation and user interrupts
to propagate through the surrounding cleanup brackets.
-}
trySynchronousIO :: IO a -> IO (Either SomeException a)
trySynchronousIO = tryJust $ \err ->
    case fromException err :: Maybe SomeAsyncException of
        Just _ -> Nothing
        Nothing -> Just err

-- | Whether every case passed.
allPassed :: Report -> Bool
allPassed (Report rs) = all (caseResultPassed . snd) rs

-- | Render a human-readable report card.
reportCard :: Report -> String
reportCard (Report rs) =
    unlines
        ( ( "test report: "
                ++ show (length (filter (caseResultPassed . snd) rs))
                ++ "/"
                ++ show (length rs)
                ++ " passed"
          )
            : map line rs
        )
  where
    line (cid, outcome) =
        "  "
            ++ caseResultLabel outcome
            ++ cid
            ++ maybe "" (" — " ++) (caseResultReason outcome)
