{-# LANGUAGE OverloadedStrings #-}

module HarnessSpec (tests, runHarnessAcquireProbe) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, finally, throwIO, try)
import Control.Monad (when)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Harness
import HostBootstrap.Harness.Ownership (protectedRunOwnership)
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitSuccess, exitWith)
import System.Process (spawnProcess, waitForProcess)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "HarnessSpec"
        [ testGroup "per-case isolation + teardown" matrixCases
        , testGroup "typed test matrix" typedMatrixCases
        , testGroup "test-suite selection" suiteCases
        , testGroup "test-data ownership" ownershipCases
        , testGroup "single execution representation" representationCases
        ]

matrixCases :: [TestTree]
matrixCases =
    [ testCase "teardown runs for every case, even when the body fails" $ do
        tornDown <- newIORef []
        let seams =
                Seams
                    { seamSetup = pure . T.unpack . caseIdText . caseId
                    , seamRun = \_ c ->
                        if caseId c == cid "boom" then ioError (userError "kaboom") else pure Pass
                    , seamTeardown = \env _ -> modifyIORef' tornDown (env :)
                    }
        report <- runMatrix seams [fixtureCase "ok", fixtureCase "boom"]
        td <- readIORef tornDown
        assertBool "both cases torn down" ("ok" `elem` td && "boom" `elem` td)
        lookup "ok" (reportResults report) @?= Just Pass
        -- A throwing case *body* is an engine-classified lifecycle break, not the
        -- project's own assertion verdict, so it is a distinct outcome.
        case lookup "boom" (reportResults report) of
            Just (LifecycleFailed msg) ->
                assertBool ("failure mentions the cause: " ++ msg) ("kaboom" `isInfixOf` msg)
            other -> assertFailure ("expected boom to be LifecycleFailed, got " ++ show other)
        allPassed report @?= False
    , testCase "a throwing setup fails that case without crashing the matrix" $ do
        let seams =
                Seams
                    { seamSetup = \c ->
                        if caseId c == cid "boom" then ioError (userError "setup-kaboom") else pure (caseId c)
                    , seamRun = \_ _ -> pure Pass
                    , seamTeardown = \_ _ -> pure ()
                    }
        report <- runMatrix seams [fixtureCase "boom", fixtureCase "ok"]
        case lookup "boom" (reportResults report) of
            Just (LifecycleFailed msg) ->
                assertBool ("setup failure surfaced: " ++ msg) ("setup-kaboom" `isInfixOf` msg)
            other -> assertFailure ("expected boom to be LifecycleFailed, got " ++ show other)
        lookup "ok" (reportResults report) @?= Just Pass
    ]

typedMatrixCases :: [TestTree]
typedMatrixCases =
    [ testCase "validated IDs reject empty, malformed, and reserved values" $ do
        mkCaseId "" @?= Left EmptyCaseId
        mkCaseId "all" @?= Left (ReservedCaseId "all")
        mkCaseId "has space" @?= Left (InvalidCaseId "has space")
        mkVariantId "" @?= Left EmptyVariantId
        mkVariantId "has space" @?= Left (InvalidVariantId "has space")
    , testCase "construction rejects every incomplete or ambiguous relation" $ do
        mkTestMatrix [] [draft "v0" ()] [] @?= Left EmptyCaseRegistry
        (mkTestMatrix [cid "a"] [] [] :: Either TestMatrixError (TestMatrix ())) @?= Left EmptyVariantRegistry
        mkTestMatrix [cid "a", cid "a"] [draft "v0" ()] [(cid "a", [vid "v0"])] @?= Left (DuplicateCaseIds [cid "a"])
        mkTestMatrix [cid "a"] [draft "v0" (), draft "v0" ()] [(cid "a", [vid "v0"])] @?= Left (DuplicateVariantIds [vid "v0"])
        mkTestMatrix [cid "a", cid "b"] [draft "v0" ()] [(cid "a", [vid "v0"])] @?= Left (MissingCaseRows [cid "b"])
        mkTestMatrix [cid "a"] [draft "v0" ()] [(cid "a", [vid "v0"]), (cid "a", [vid "v0"])] @?= Left (DuplicateCaseRows [cid "a"])
        mkTestMatrix [cid "a"] [draft "v0" ()] [(cid "a", [vid "v0"]), (cid "b", [vid "v0"])] @?= Left (UnknownCaseRows [cid "b"])
        mkTestMatrix [cid "a"] [draft "v0" ()] [(cid "a", [])] @?= Left (EmptyVariantRow (cid "a"))
        mkTestMatrix [cid "a"] [draft "v0" ()] [(cid "a", [vid "missing"])] @?= Left (UnknownVariantReferences [(cid "a", vid "missing")])
        mkTestMatrix [cid "a"] [draft "v0" ()] [(cid "a", [vid "v0", vid "v0"])] @?= Left (DuplicateVariantPairs [(cid "a", vid "v0")])
        mkTestMatrix [cid "a"] [draft "v0" (), draft "orphan" ()] [(cid "a", [vid "v0"])] @?= Left (OrphanVariants [vid "orphan"])
    , testCase "selection preserves sharing and distinct variants without duplication" $ do
        matrix <-
            either (assertFailure . show) pure $
                mkTestMatrix
                    [cid "a", cid "b"]
                    [draft "shared" ("shared-value" :: T.Text), draft "extra" "extra-value"]
                    [(cid "a", [vid "shared", vid "extra"]), (cid "b", [vid "shared"])]
        selected <- either (assertFailure . show) pure (selectTestMatrix (selector "all") matrix)
        map (variantDraftId . selectedVariantDraft) selected @?= [vid "shared", vid "extra"]
        map selectedVariantCaseIds selected @?= [cid "a" :| [cid "b"], cid "a" :| []]
        one <- either (assertFailure . show) pure (selectTestMatrix (selector "b") matrix)
        map (variantDraftId . selectedVariantDraft) one @?= [vid "shared"]
        map selectedVariantCaseIds one @?= [cid "b" :| []]
        selectTestMatrix (selector "missing") matrix @?= Left (UnknownSelectedCase (cid "missing"))
    ]

suiteCases :: [TestTree]
suiteCases =
    [ testCase "emptySuite `all` renders 0/0 passed" $ do
        outcome <- runSuiteSelection passthroughOwnership emptySuite []
        case outcome of
            Right report -> assertBool "report card shows 0/0" ("0/0 passed" `isInfixOf` reportCard report)
            Left err -> assertFailure ("expected Right, got Left " ++ err)
    , testCase "the report card names each outcome distinctly, not one FAIL for all" $ do
        -- § Y/§ Z: an operator scanning the card must be able to tell a broken
        -- assertion from a refusal from a lifecycle break from leaked state.
        let card =
                reportCard
                    ( Report
                        [ ("passing", Pass)
                        , ("asserted", Fail "the marker was absent")
                        , ("refused", Refused "a production cluster is running")
                        , ("broken", LifecycleFailed "kind create cluster failed")
                        , ("teardown", TeardownFailed "the VM did not stop")
                        ]
                    )
        assertBool ("counts only the pass: " ++ card) ("1/5 passed" `isInfixOf` card)
        mapM_
            (\expected -> assertBool ("card contains " ++ expected ++ ":\n" ++ card) (expected `isInfixOf` card))
            [ "PASS    passing"
            , "FAIL    asserted — the marker was absent"
            , "REFUSED refused — a production cluster is running"
            , "BROKEN  broken — kind create cluster failed"
            , "LEAKED? teardown — the VM did not stop"
            ]
        -- Every non-passing outcome is counted as a failure, and no outcome is
        -- silently treated as success.
        map
            caseResultPassed
            [Pass, Fail "x", Refused "x", LifecycleFailed "x", TeardownFailed "x"]
            @?= [True, False, False, False, False]
    , testCase "`all` runs the whole matrix (rows labeled by variant)" $ do
        outcome <- runSuiteSelection passthroughOwnership twoCaseSuite [variant ["a", "b"] "v0"]
        case outcome of
            Right (Report rs) -> map fst rs @?= ["[v0] a", "[v0] b"]
            Left err -> assertFailure ("expected Right, got Left " ++ err)
    , testCase "a named case runs only that case" $ do
        outcome <- runSuiteSelection passthroughOwnership twoCaseSuite [variant ["b"] "v0"]
        case outcome of
            Right (Report rs) -> map fst rs @?= ["[v0] b"]
            Left err -> assertFailure ("expected Right, got Left " ++ err)
    , testCase "two variants loop with full teardown + spin-up, aggregating labeled rows" $ do
        events <- newIORef []
        let record e = modifyIORef' events (e :)
            suite =
                TestSuite
                    (pure (Right ()))
                    (\ident -> record ("up:" ++ T.unpack (variantIdText ident)) >> pure ident)
                    [fixtureCase "a"]
                    (\ident _ -> record ("assert:" ++ T.unpack (variantIdText ident)) >> pure Pass)
                    (record "down")
        outcome <- runSuiteSelection passthroughOwnership suite [variant ["a"] "v0", variant ["a"] "v1"]
        seen <- reverse <$> readIORef events
        case outcome of
            Right (Report rs) -> map fst rs @?= ["[v0] a", "[v1] a"]
            Left err -> assertFailure ("expected Right, got Left " ++ err)
        -- Each variant fully completes (up -> assert -> down) before the next starts.
        seen @?= ["up:v0", "assert:v0", "down", "up:v1", "assert:v1", "down"]
    , testCase "a failed bring-up still runs teardown and isolates the variant" $ do
        events <- newIORef []
        let record e = modifyIORef' events (e :)
            -- v0's bring-up throws; v1's succeeds. v0 must still tear down, fail its
            -- case, and NOT abort v1.
            suite =
                TestSuite
                    (pure (Right ()))
                    ( \label ->
                        if label == vid "v0"
                            then record "up:v0-boom" >> ioError (userError "project up kaboom")
                            else record ("up:" ++ T.unpack (variantIdText label)) >> pure label
                    )
                    [fixtureCase "a"]
                    (\label _ -> record ("assert:" ++ T.unpack (variantIdText label)) >> pure Pass)
                    (record "down")
        outcome <- runSuiteSelection passthroughOwnership suite [variant ["a"] "v0", variant ["a"] "v1"]
        seen <- reverse <$> readIORef events
        case outcome of
            Right (Report rs) -> do
                -- v0's case Fails (bring-up), v1's case Passes — the loop was not aborted.
                lookup "[v0] a" rs
                    @?= Just (LifecycleFailed "bring-up failed: user error (project up kaboom)")
                lookup "[v1] a" rs @?= Just Pass
            Left err -> assertFailure ("expected Right, got Left " ++ err)
        -- v0 tore down despite its failed bring-up; v1 ran normally.
        seen @?= ["up:v0-boom", "down", "up:v1", "assert:v1", "down"]
    , testCase "a failed teardown fails that variant instead of hiding a leak" $ do
        downCount <- newIORef (0 :: Int)
        let tearDown = do
                modifyIORef' downCount (+ 1)
                count <- readIORef downCount
                when (count == 1) (ioError (userError "destroy left managed state"))
            suite =
                TestSuite
                    (pure (Right ()))
                    pure
                    [fixtureCase "a"]
                    (\_ _ -> pure Pass)
                    tearDown
        outcome <- runSuiteSelection passthroughOwnership suite [variant ["a"] "v0", variant ["a"] "v1"]
        case outcome of
            Right (Report rs) -> do
                -- The assertions themselves passed; the *teardown* is what broke,
                -- so the per-case row is preserved and the variant carries a
                -- distinct TeardownFailed row that makes the report red.
                lookup "[v0] a" rs @?= Just Pass
                case lookup "[v0] teardown" rs of
                    Just (TeardownFailed msg) ->
                        assertBool
                            "teardown cause is reported"
                            ("destroy left managed state" `isInfixOf` msg)
                    other -> assertFailure ("expected v0 TeardownFailed, got " ++ show other)
                lookup "[v1] a" rs @?= Just Pass
                lookup "[v1] teardown" rs @?= Nothing
                allPassed (Report rs) @?= False
            Left err -> assertFailure ("expected Right, got Left " ++ err)
    , testCase "a safety refusal never tears down state the harness did not own" $ do
        teardownCalls <- newIORef (0 :: Int)
        configEntries <- newIORef (0 :: Int)
        configExits <- newIORef (0 :: Int)
        let suite =
                TestSuite
                    (pure (Right ()))
                    (\_ -> throwIO (SafetyRefusal "pre-existing managed VM"))
                    [fixtureCase "a"]
                    (\_ _ -> pure Pass)
                    (modifyIORef' teardownCalls (+ 1))
            withConfig body = do
                modifyIORef' configEntries (+ 1)
                body `finally` modifyIORef' configExits (+ 1)
        outcome <- runSuiteSelection passthroughOwnership suite [ConfigVariant (vid "v0") (cid "a" :| []) withConfig]
        case outcome of
            Right (Report rs) ->
                -- A refusal is its own outcome: it is not an assertion failure and
                -- not a lifecycle break, and it carries the bare reason.
                lookup "[v0] a" rs @?= Just (Refused "pre-existing managed VM")
            Left err -> assertFailure ("expected Right, got Left " ++ err)
        readIORef teardownCalls >>= (@?= 0)
        readIORef configEntries >>= (@?= 1)
        readIORef configExits >>= (@?= 1)
    , testCase "a bring-up LifecycleFailure renders its cause, never a bare ExitFailure 1" $ do
        -- The peer of the SafetyRefusal case (development_plan_standards § CC): a
        -- lifecycle step that throws a structured 'LifecycleFailure' must reach the
        -- report card as its carried reason (via 'displayException'), never the
        -- message-less "ExitFailure 1" a bare `die` would collapse to.
        let cause = "durable alias collision: /var/tmp/hostbootstrap-demo-data"
            suite =
                TestSuite
                    (pure (Right ()))
                    (\_ -> throwIO (LifecycleFailure cause))
                    [fixtureCase "a"]
                    (\_ _ -> pure Pass)
                    (pure ())
        outcome <- runSuiteSelection passthroughOwnership suite [variant ["a"] "v0"]
        case outcome of
            Right (Report rs) ->
                case lookup "[v0] a" rs of
                    Just (LifecycleFailed msg) -> do
                        assertBool ("carries the cause: " ++ msg) (cause `isInfixOf` msg)
                        assertBool ("no bare ExitFailure: " ++ msg) (not ("ExitFailure" `isInfixOf` msg))
                        assertBool ("no leaked marker: " ++ msg) (not (lifecycleFailureMarker `isInfixOf` msg))
                    other -> assertFailure ("expected a legible lifecycle failure, got " ++ show other)
            Left err -> assertFailure ("expected Right, got Left " ++ err)
    ]
  where
    -- A stack-driven suite (label-aware bring-up, passing assertions) — exercises
    -- `runSuiteSelection`'s case selection over the new TestSuite shape.
    twoCaseSuite =
        TestSuite
            (pure (Right ()))
            pure
            [fixtureCase "a", fixtureCase "b"]
            (\_ _ -> pure Pass)
            (pure ())
    variant :: [T.Text] -> T.Text -> ConfigVariant
    variant cases label = ConfigVariant (vid label) (nonEmptyCaseIds cases) id

{- | The engine's ownership seam under test: the exclusive-run bracket is
supplied by the command layer, so these cases exercise selection, isolation, and
reporting without taking real project-wide ownership of the working directory.
'protectedRunOwnership' is exercised separately below.
-}
passthroughOwnership :: HarnessRunOwnership
passthroughOwnership = HarnessRunOwnership (fmap Right)

{- | The out-of-process half of the concurrency case: attempt one full harness
run reservation against the same state root and HOLD it while the body runs, so
competitors overlap the winner rather than queueing behind it.

Exit 0 when the run was acquired, 3 when it was refused. The refusal reason is
printed so the racing test can report which exclusion fired.
-}
runHarnessAcquireProbe :: FilePath -> FilePath -> IO ()
runHarnessAcquireProbe stateRoot reasonPath = do
    let ownership =
            protectedRunOwnership
                "hostbootstrap-demo"
                stateRoot
                (stateRoot </> "nonexistent-sibling-dir")
                (stateRoot </> ".test_data")
    outcome <-
        runWithOwnedRun ownership $
            -- Hold the reservation long enough that every competitor's attempt
            -- overlaps it. A reservation only one process can see at a time is
            -- not the property under test.
            threadDelay 3000000
    case outcome of
        Right () -> exitSuccess
        Left reason -> do
            writeFile reasonPath reason
            exitWith (ExitFailure 3)

ownershipCases :: [TestTree]
ownershipCases =
    [ testCase "self-created .test_data is removed; a found one is preserved" $ do
        selfCreatedTestDataRemoval False testDataRoot @?= [testDataRoot]
        selfCreatedTestDataRemoval True testDataRoot @?= []
    , testCase "the owned durable root is a per-run generation under .test_data" $
        withSystemTempDirectory "hostbootstrap-test-data" $ \root -> do
            let parent = root </> ".test_data"
                ownership = protectedRunOwnership "hostbootstrap-demo" root root parent
            -- Observed from inside the bracket: the generation only exists while
            -- the run holds it.
            observed <-
                runWithOwnedRun ownership $ do
                    generations <- listDirectory parent
                    kinds <-
                        mapM (\name -> doesDirectoryExist (parent </> name)) generations
                    pure (generations, kinds)
            case observed of
                Left err -> assertFailure ("the run was refused: " ++ err)
                Right (generations, kinds) -> do
                    -- Exactly one generation exists while the run holds it, and
                    -- it is named by the run's generative id, not by `.data` or
                    -- the shared parent (§ Z).
                    length generations @?= 1
                    kinds @?= [True]
    , testCase "an owned run releases its generation and keeps the .test_data parent" $
        withSystemTempDirectory "hostbootstrap-test-data" $ \root -> do
            let parent = root </> ".test_data"
                ownership = protectedRunOwnership "hostbootstrap-demo" root root parent
            outcome <-
                try (runWithOwnedRun ownership (throwIO (userError "seeded failure"))) ::
                    IO (Either SomeException (Either String ()))
            assertBool "body exception propagated" (either (const True) (const False) outcome)
            -- The generation is gone; the shared parent is scaffolding the run
            -- never owned, so it is neither bound to a receipt nor removed.
            doesDirectoryExist parent >>= (@?= True)
            listDirectory parent >>= (@?= [])
    , testCase "a run interrupted mid-body does not block the next run" $
        withSystemTempDirectory "hostbootstrap-test-data" $ \root -> do
            let parent = root </> ".test_data"
                ownership = protectedRunOwnership "hostbootstrap-demo" root root parent
            -- The first run dies inside the body: its mode and lease records are
            -- left behind exactly as a hard kill leaves them.
            _ <-
                try (runWithOwnedRun ownership (throwIO (userError "killed"))) ::
                    IO (Either SomeException (Either String ()))
            -- The next run's sweep classifies and closes that abandoned lease
            -- rather than refusing with an unrecoverable lock directory.
            second <- runWithOwnedRun ownership (pure ("second run" :: String))
            second @?= Right "second run"
            -- The abandoned predecessor's generation was reclaimed by that
            -- sweep, so no orphan generation accumulates across runs.
            listDirectory parent >>= (@?= [])
    , testCase "racing harnesses converge on exactly one authoritative acquisition" $
        withSystemTempDirectory "hostbootstrap-race" $ \root -> do
            self <- getExecutablePath
            -- Four real processes, started together, each attempting the whole
            -- production reservation (sweep -> mode+lease -> data root) against
            -- one state root.
            let reasonFile n = root </> ("refusal-" ++ show n)
            handles <-
                mapM
                    ( \n ->
                        spawnProcess
                            self
                            ["--hostbootstrap-harness-acquire-probe", root, reasonFile n]
                    )
                    [1 :: Int .. 4]
            codes <- mapM waitForProcess handles
            let acquired = length [() | ExitSuccess <- codes]
                refused = length [() | ExitFailure 3 <- codes]
                other = [code | code <- codes, code /= ExitSuccess, code /= ExitFailure 3]
            assertBool ("no probe may fail unexpectedly: " ++ show other) (null other)
            acquired @?= 1
            refused @?= 3
            -- Every loser must be refused by a *stated* exclusion, never by a
            -- silent failure.
            reasons <-
                mapM
                    ( \n -> do
                        present <- doesFileExist (reasonFile n)
                        if present then readFile (reasonFile n) else pure ""
                    )
                    [1 :: Int .. 4]
            length (filter (not . null) reasons) @?= 3
            -- The winner released everything, so the parent is empty again.
            listDirectory (root </> ".test_data") >>= (@?= [])
    , testCase "consecutive runs own disjoint generations" $
        withSystemTempDirectory "hostbootstrap-test-data" $ \root -> do
            let parent = root </> ".test_data"
                ownership = protectedRunOwnership "hostbootstrap-demo" root root parent
                observe = runWithOwnedRun ownership (listDirectory parent)
            first <- observe
            second <- observe
            case (first, second) of
                (Right [one], Right [two]) ->
                    assertBool
                        "each run names its own generation"
                        (one /= two)
                _ ->
                    assertFailure
                        ("each run must own exactly one generation: " ++ show (first, second))
    ]

representationCases :: [TestTree]
representationCases =
    [ testCase "the harness and Core.dhall contain no parallel execution selector" $ do
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        harness <- TIO.readFile (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "Harness.hs")
        core <- TIO.readFile (root </> "core" </> "hostbootstrap-core" </> "dhall" </> "Core.dhall")
        let selectorType = "Run" <> "Model"
        mapM_
            (\token -> assertBool "Harness.hs must not define a parallel execution selector" (not (token `T.isInfixOf` harness)))
            ["data " <> selectorType, "data " <> selectorType <> "Key", "select" <> selectorType, "data Topology"]
        assertBool "Core.dhall must not define a parallel execution union" (not (("let " <> selectorType) `T.isInfixOf` core))
    , testCase "typed drafts stay pure and dead/stringly matrix plumbing is absent" $ do
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        harness <- TIO.readFile (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "Harness.hs")
        command <- TIO.readFile (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "Command.hs")
        demoConfig <- TIO.readFile (root </> "demo" </> "src" </> "HostBootstrapDemo" </> "Config.hs")
        fixture <- TIO.readFile (root </> "core" </> "hostbootstrap-core" </> "test" </> "Fixture.hs")
        assertBool "VariantDraft is exactly stable identity plus a pure typed payload" ("data VariantDraft a = VariantDraft VariantId a" `T.isInfixOf` harness)
        assertBool "VariantDraft constructor remains opaque" (not ("VariantDraft (..)" `T.isInfixOf` harness))
        assertBool "the engine receives typed selections, not a raw String selector" (not ("[ConfigVariant] ->\n    String ->" `T.isInfixOf` harness))
        assertBool "the command boundary parses the typed selector" ("parseCaseSelector" `T.isInfixOf` command)
        let deadField = "test" <> "Suites"
        assertBool "demo TestConfig has no dead suite list" (not (deadField `T.isInfixOf` demoConfig))
        assertBool "generic fixture TestConfig has no dead suite list" (not (deadField `T.isInfixOf` fixture))
    ]

cid :: T.Text -> CaseId
cid value = either (error . show) id (mkCaseId value)

vid :: T.Text -> VariantId
vid value = either (error . show) id (mkVariantId value)

draft :: T.Text -> a -> VariantDraft a
draft ident = variantDraft (vid ident)

selector :: T.Text -> CaseSelector
selector value = either (error . show) id (parseCaseSelector value)

fixtureCase :: T.Text -> Case
fixtureCase ident = Case (cid ident) 1 False

nonEmptyCaseIds :: [T.Text] -> NonEmpty CaseId
nonEmptyCaseIds (first : rest) = cid first :| map cid rest
nonEmptyCaseIds [] = error "test ConfigVariant needs at least one case"
