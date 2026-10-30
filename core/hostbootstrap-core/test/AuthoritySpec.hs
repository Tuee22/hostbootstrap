{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The protected store, root/command authority, and the project-wide
lifecycle mode and run leases.

These cases run against a real filesystem and a real kernel lock: the exclusive
entry is proved by contending with an out-of-process @flock@, not by modelling
one. Every mode, lease, and invocation decision is a compare-and-swap over a
durable record, so the crash cases here are the ones an interrupted run
actually leaves behind.
-}
module AuthoritySpec (tests, runEntryProbe, runLivenessProbe, runLivenessInheritanceProbe, runModeProfileProbe, runCommandReservationProbe) where

import Control.Concurrent (forkFinally, forkIO, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (IOException, SomeException, bracket_, displayException, finally, mask, throwIO, try)
import Control.Monad (forM_, replicateM)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (toLower)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, nub, sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TextIO
import Data.Word (Word64)
import Expect (expectRight)
import qualified Fixture
import HostBootstrap.Authority
import qualified HostBootstrap.Authority.ProjectPlan as ProjectAuthority
import qualified HostBootstrap.Authority.Testing as AuthorityFixture
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec), ProjectCodec)
import HostBootstrap.Config.Schema (ValidatedConfig, VerifiedConfigWire, validatedConfigValue, withValidatedConfig)
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import qualified HostBootstrap.Lifecycle.Context as LifecycleContext
import HostBootstrap.Lifecycle.Mode
import HostBootstrap.Lifecycle.Session (
    ProjectJournalState (ClosedProject, ClosingProject),
    SessionError (SessionProjectClosing, SessionStillOpen),
    VerifiedAllSessionsClosed,
    admissionPlanDigest,
    beginClosingProject,
    openOperationSession,
    openProjectJournal,
    readProjectJournalState,
    recordClosedProject,
    verifyAllSessionsClosed,
 )
import HostBootstrap.Lift (localContext)
import HostBootstrap.ProjectPlan (
    PlanDraft,
    PlannedResourceKind (ClusterResourceKind),
    ProjectPlan,
    forward,
    planDraftsFromValidatedBuilder,
    plannedResourceFrame,
    plannedResourceKey,
    plannedStepOperationKey,
    renderSnapshot,
    stablePlanSnapshotDigest,
    stablePlanSnapshotRoot,
    withPlannedResourceOfKind,
 )
import HostBootstrap.ProjectPlan.Construct (withProjectPlan)
import HostBootstrap.ProjectPlan.Frame (withCurrentFrame)
import HostBootstrap.ProjectPlan.Snapshot (withPersistedPlanSnapshot)
import HostBootstrap.ProjectRoot (canonicalProjectRootPath, withCanonicalProjectRoot)
import HostBootstrap.Protected
import HostBootstrap.Reconcile (
    CanonicalPlanSnapshot,
    canonicalPlanSnapshotBytes,
    canonicalPlanSnapshotConfigDigest,
    canonicalPlanSnapshotDigest,
    canonicalPlanSnapshotSpecDigest,
    lifecyclePlanDigest,
    lifecyclePlanFromProjectPlan,
    lifecyclePlanSnapshot,
    renderResourceRecordBundle,
    resourceRecordKey,
    withLifecyclePlanForConfig,
 )
import HostBootstrap.Step (
    StepFrame (..),
    StepObservation (StepChanged),
    StepPlan,
    contextInitStep,
    deployKindStep,
    deployVMStep,
    descendsVia,
    implementedAt,
    mkStepImplementationRevision,
    mkStepPlan,
    operationKeyText,
 )
import qualified SessionSpec as TransactionFixture
import SealedExportInventory (pinnedExportLists)
import qualified SourceGuard
import System.Directory (
    copyFile,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getCurrentDirectory,
    listDirectory,
    renameDirectory,
 )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitSuccess, exitWith)
import System.FilePath (takeDirectory, takeExtension, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.IO (hFlush, hGetLine, hPutStrLn, stderr, stdout)
import System.Process (CreateProcess (std_err, std_out), StdStream (CreatePipe), cleanupProcess, createProcess, getProcessExitCode, proc, readProcessWithExitCode, spawnProcess, terminateProcess, waitForProcess)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Read (readMaybe)
import Unsafe.Coerce (unsafeCoerce)

{- | The out-of-process half of the exclusive-entry case: open the same store
and attempt its entry without blocking. Exit 0 when the entry was acquired, 3
when another holder has it, 4 when the store could not be opened at all.
-}
runEntryProbe :: FilePath -> IO ()
runEntryProbe storeRoot = do
    opened <- openProtectedStore storeRoot
    case opened of
        Left _ -> exitWith (ExitFailure 4)
        Right store -> do
            outcome <- tryProtectedEntry store (\_ -> pure (Right ()))
            case outcome of
                Right (Just ()) -> exitSuccess
                Right Nothing -> exitWith (ExitFailure 3)
                Left _ -> exitWith (ExitFailure 4)

-- | Exit 0 for an acquired liveness extent, 3 for contention, and 4 for a refusal.
runLivenessProbe :: FilePath -> String -> IO ()
runLivenessProbe storeRoot name = do
    opened <- openProtectedStore storeRoot
    case opened of
        Left _ -> exitWith (ExitFailure 4)
        Right store -> do
            outcome <- withRunLiveness store (Text.pack name) (pure ())
            case outcome of
                Right (Just ()) -> exitSuccess
                Right Nothing -> exitWith (ExitFailure 3)
                Left _ -> exitWith (ExitFailure 4)

-- | Remain alive after the parent leaves its liveness extent.
runLivenessInheritanceProbe :: IO ()
runLivenessInheritanceProbe = threadDelay 10000000

-- | Rebuild the recorded reservation after announcing readiness. The parent
-- holds the store entry until both process and thread contenders are ready.
runCommandReservationProbe :: FilePath -> String -> String -> String -> IO ()
runCommandReservationProbe storeRoot rawEpoch planDigest frameKey =
    case readMaybe rawEpoch :: Maybe Integer of
        Just word | word > 0 && word <= toInteger (maxBound :: Word64) -> do
            opened <- openProtectedStore storeRoot
            case opened of
                Left failure -> failed (show failure)
                Right store -> do
                    putStrLn "ready"
                    hFlush stdout
                    attempted <- try @SomeException $
                        rebuildAndReserveCommand store (fromInteger word) ProjectUp Execute (Text.pack planDigest) (Text.pack frameKey)
                    case attempted of
                        Right (Right _) -> exitSuccess
                        Right (Left AuthorityInvocationConsumed{}) -> exitWith (ExitFailure 3)
                        Right (Left failure) -> failed (show failure)
                        Left failure -> failed (displayException failure)
        _ -> failed "the command-reservation probe requires a positive broker epoch"
  where
    failed reason = hPutStrLn stderr reason >> exitWith (ExitFailure 4)

{- | The out-of-process half of the **cross-profile** exclusion: open the same
project's store in a separate process and attempt the named lifecycle profile.

The composite root brackets take the mode inside one exclusive entry and then
release the entry, so by the time a holder's body runs, the only thing a
competitor can contend on is the durable mode record. That is what makes this a
cross-*profile* probe rather than a second exclusive-entry probe: the competitor
reaches the mode compare-and-swap and is refused there, by name.

Its only report is its own outcome — exit 0 when it took the profile, 3 when the
mode refused it (with the held/wanted pair written to @reasonPath@), 4 otherwise.
It never reports what the holder is doing, so no read-only lease observer is
introduced (§ EE).
-}
runModeProfileProbe :: FilePath -> String -> FilePath -> IO ()
runModeProfileProbe storeRoot profile reasonPath = do
    opened <- openProtectedStore storeRoot
    case opened of
        Left _ -> exitWith (ExitFailure 4)
        Right store ->
            Fixture.withFixtureInstalledProject $ \project ->
                report =<< attempt store project
  where
    attempt store project = case profile of
        "production" ->
            withProductionRoot store project ProjectUp (\_ -> pure (Right ()))
        "oversized-snapshot" -> withProtectedEntry' store $ \session -> do
            inspected <- inspectPlanSnapshot session project (Text.replicate 48 "A")
            pure $ case inspected of
                Left (ModeStoreFailure (ProtectedInvalid _)) -> Right ()
                Left failure -> Left failure
                Right _ -> Left (ModeInvalidIdentity "an oversized snapshot address was admitted")
        "harness" -> do
            swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
            case swept of
                Left failure -> pure (Left failure)
                Right proof ->
                    withHarnessRoot
                        store
                        project
                        ProjectUp
                        (satisfiedPreconditions project)
                        proof
                        (\_ -> pure (Right ()))
        _ -> pure (Left (ModeInvalidIdentity (Text.pack ("unknown profile " <> profile))))

    report (Right ()) = exitSuccess
    report (Left failure@(ModeHeldByAnother held wanted)) = do
        writeFile reasonPath (Text.unpack held <> "\t" <> Text.unpack wanted)
        failure `seq` exitWith (ExitFailure 3)
    report (Left failure) = do
        writeFile reasonPath (Text.unpack (modeErrorMessage failure))
        exitWith (ExitFailure 4)

tests :: TestTree
tests =
    testGroup
        "AuthoritySpec"
        [ testGroup "the protected store" storeCases
        , testGroup "root and command authority" authorityCases
        , testGroup "the one-use reservation kernel" commandReservationCases
        , testGroup "project mode and run leases" modeCases
        , testGroup "invocation and terminal close" closeCases
        , testGroup "abandoned-run recovery" recoveryCases
        , testGroup "plan migration" migrationCases
        , testGroup "library source discovery" librarySourceDiscoveryCases
        , testGroup "authority error construction witnesses" authorityErrorConstructionCases
        , testGroup "transitive library imports" libraryImportClosureCases
        , testGroup "sealed public export surfaces" sealedExportSurfaceCases
        ]

sealedExportSurfaceCases :: [TestTree]
sealedExportSurfaceCases =
    [ testCase "every exposed sealed importer and local sealed surface has one exact export pin" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            packageDescription <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            sources <- SourceGuard.readLibrarySources packageRoot packageDescription
            let inventory = [(name, SourceGuard.repoRelativePath packageRoot path, source) | (name, path, source) <- sources]
            checkSealedExportInventory
                ["HostBootstrap.Ensure.GuestBootstrap", "HostBootstrap.Lift.Context", "HostBootstrap.RegistryPlan"]
                packageDescription inventory pinnedExportLists
                @?= Right ()
    , testCase "every named library unit is explicitly private" $
        SourceGuard.readPackageDescription >>= (\packageDescription -> checkPrivateLibraries packageDescription @?= Right ())
    , testCase "a main-library hidden importer is discovered" $
        check [] description [public ["import HostBootstrap.Hidden"]] pin @?= Right ()
    , testCase "qualified package imports from a private unit are discovered" $
        check [] description [public ["import qualified \"private-unit\" HostBootstrap.Private as Private"]] pin @?= Right ()
    , testCase "an exposed facade with no sealed import needs no pin" $
        check [] description [public ["import Data.Text"]] [] @?= Right ()
    , testCase "comments and strings cannot manufacture a sealed importer" $
        check [] description [public ["-- import HostBootstrap.Hidden", "quoted = \"import HostBootstrap.Private\""]] [] @?= Right ()
    , testCase "a newly exposed sealed importer cannot escape the inventory" $
        check [] (description <> "  exposed-modules: HostBootstrap.New\n")
            [public ["import HostBootstrap.Hidden"], node "HostBootstrap.New" "src/new.hs" "extra" ["import HostBootstrap.Hidden"]] pin
            @?= Left "sealed export inventory modules differ; missing: [\"HostBootstrap.New\"]; stale: []"
    , testCase "a missing pin refuses with the missing module" $
        check [] description [public ["import HostBootstrap.Hidden"]] []
            @?= Left "sealed export inventory modules differ; missing: [\"HostBootstrap.Public\"]; stale: []"
    , testCase "a duplicate pin is refused before map lookup could hide it" $
        check [] description [public ["import HostBootstrap.Hidden"]] (pin <> pin)
            @?= Left "duplicate sealed export inventory modules: [\"HostBootstrap.Public\"]"
    , testCase "a stale pin is refused" $
        check [] description [public []] pin
            @?= Left "sealed export inventory modules differ; missing: []; stale: [\"HostBootstrap.Public\"]"
    , testCase "an added export changes the exact pinned token list" $
        check [] description [node "HostBootstrap.Public" "src/public.hs" "Opaque, safeValue, minted" ["import HostBootstrap.Hidden"]] pin
            @?= Left "sealed export list changed: HostBootstrap.Public (src/public.hs)"
    , testCase "constructor exports and export order remain part of the pin" $ do
        check [] description [node "HostBootstrap.Public" "src/public.hs" "Opaque (..), safeValue" ["import HostBootstrap.Hidden"]] pin
            @?= Left "sealed export list changed: HostBootstrap.Public (src/public.hs)"
        check [] description [node "HostBootstrap.Public" "src/public.hs" "safeValue, Opaque" ["import HostBootstrap.Hidden"]] pin
            @?= Left "sealed export list changed: HostBootstrap.Public (src/public.hs)"
    , testCase "an implicit export list refuses instead of pinning everything" $
        check [] description [("HostBootstrap.Public", "src/public.hs", "module HostBootstrap.Public where\nimport HostBootstrap.Hidden\n")] pin
            @?= Left "sealed facade has no explicit export list: HostBootstrap.Public (src/public.hs)"
    , testCase "missing and ambiguous exposed source homes refuse" $ do
        check [] description [] pin @?= Left "exposed module source missing: HostBootstrap.Public"
        check [] description [public [], node "HostBootstrap.Public" "internal/public.hs" "Opaque, safeValue" []] pin
            @?= Left "exposed module source ambiguous: HostBootstrap.Public"
    , testCase "a local sealed surface is pinned through the explicit supplement" $
        check ["HostBootstrap.Public"] description [public []] pin @?= Right ()
    , testCase "a supplemental surface must still be exposed" $
        check ["HostBootstrap.Absent"] description [public []] []
            @?= Left "supplemental sealed surface is not exposed: HostBootstrap.Absent"
    , testCase "private visibility accepts case-neutral field spelling" $
        checkPrivateLibraries description @?= Right ()
    , testCase "a new public unit cannot hide behind the fixture compiler's visibility" $
        checkPrivateLibraries (description <> "library new-unit\n  visibility: public\n")
            @?= Left "named library is not explicitly private: library new-unit"
    , testCase "a missing private declaration is refused" $
        checkPrivateLibraries (description <> "library missing-visibility\n  hs-source-dirs: internal/missing\n")
            @?= Left "named library is not explicitly private: library missing-visibility"
    ]
  where
    check = checkSealedExportInventory
    pin = [("HostBootstrap.Public", "Opaque, safeValue")]
    public = node "HostBootstrap.Public" "src/public.hs" "Opaque, safeValue"
    node name path exports imports = (name, path, unlines (("module " <> name <> " (" <> exports <> ") where") : imports))
    description = unlines
        [ "library private-unit"
        , "  ViSiBiLiTy: private"
        , "  exposed-modules: HostBootstrap.Private"
        , "  other-modules: HostBootstrap.Private.Hidden"
        , "library"
        , "  exposed-modules: HostBootstrap.Public"
        , "  other-modules: HostBootstrap.Hidden"
        ]

-- | Match the complete dynamic facade set before inspecting any export list.
-- Expected text contains only reviewed exports, never a digest of whole files.
checkSealedExportInventory ::
    [String] -> String -> [(String, FilePath, String)] -> [(String, String)] -> Either String ()
checkSealedExportInventory supplemental description sources pins = do
    mainLibrary <- maybe (Left "the main library stanza is absent") Right (SourceGuard.mainLibraryStanza description)
    let exposed = SourceGuard.fieldModules "exposed-modules" mainLibrary
        privateModules = concat
            [ SourceGuard.fieldModules field body
            | (_, body) <- namedLibraryBodies description
            , field <- ["exposed-modules", "other-modules"]
            ]
        hidden = SourceGuard.fieldModules "other-modules" mainLibrary <> privateModules
        names = map fst pins
        duplicates = sort [name | name <- nub names, length (filter (== name) names) > 1]
    if null duplicates then Right () else Left ("duplicate sealed export inventory modules: " <> show duplicates)
    mapM_ (\name -> if name `elem` exposed then Right () else Left ("supplemental sealed surface is not exposed: " <> name)) supplemental
    publicSources <- traverse sourceFor exposed
    let required = sort . nub $ supplemental <>
            [ name
            | (name, _, source) <- publicSources
            , any (`elem` hidden) (SourceGuard.haskellImports source)
            ]
        missing = filter (`notElem` names) required
        stale = sort (filter (`notElem` required) names)
    if null missing && null stale
        then mapM_ check [entry | entry@(name, _, _) <- publicSources, name `elem` required]
        else Left ("sealed export inventory modules differ; missing: " <> show missing <> "; stale: " <> show stale)
  where
    sourceFor name = case [entry | entry@(observed, _, _) <- sources, observed == name] of
        [entry] -> Right entry
        [] -> Left ("exposed module source missing: " <> name)
        _ -> Left ("exposed module source ambiguous: " <> name)
    check (name, path, source) = do
        expected <- maybe (Left ("sealed export pin missing: " <> name)) Right (lookup name pins)
        observed <- maybe (Left ("sealed facade has no explicit export list: " <> name <> " (" <> path <> ")")) Right
            (SourceGuard.moduleExportTokens name source)
        if observed == SourceGuard.haskellTokens expected
            then Right ()
            else Left ("sealed export list changed: " <> name <> " (" <> path <> ")")

namedLibraryBodies :: String -> [(String, String)]
namedLibraryBodies description =
    [ (header, SourceGuard.componentBody component)
    | component <- SourceGuard.componentStanzas description
    , let header = SourceGuard.componentHeader component
    , "library" : _name : _ <- [map (map toLower) (words header)]
    ]

checkPrivateLibraries :: String -> Either String ()
checkPrivateLibraries description =
    mapM_ check (namedLibraryBodies description)
  where
    check (name, body)
        | SourceGuard.fieldValues "visibility" body == ["private"] = Right ()
        | otherwise = Left ("named library is not explicitly private: " <> name)

libraryImportClosureCases :: [TestTree]
libraryImportClosureCases =
    [ testCase "a direct configuration import is in the closure" $
        run [rootNode ["import HostBootstrap.Config.Vocab"], node "HostBootstrap.Config.Vocab" "src/HostBootstrap/Config/Vocab.hs" []]
            @?= Right [("HostBootstrap.Config.Vocab", "src/HostBootstrap/Config/Vocab.hs")]
    , testCase "a qualified reconcile import is in the closure" $
        run [rootNode ["import qualified HostBootstrap.Reconcile as Reconcile"], node "HostBootstrap.Reconcile" "src/HostBootstrap/Reconcile.hs" []]
            @?= Right [("HostBootstrap.Reconcile", "src/HostBootstrap/Reconcile.hs")]
    , testCase "transitive dependencies resolve through private library roots" $
        run
            [ rootNode ["import HostBootstrap.Ownership.Private"]
            , node "HostBootstrap.Ownership.Private" "internal/ownership/Private.hs" ["import HostBootstrap.Effect.Private"]
            , node "HostBootstrap.Effect.Private" "internal/effect/Private.hs" ["import qualified HostBootstrap.Config.Vocab as Config"]
            , node "HostBootstrap.Config.Vocab" "src/HostBootstrap/Config/Vocab.hs" []
            ] @?= Right
                [ ("HostBootstrap.Config.Vocab", "src/HostBootstrap/Config/Vocab.hs")
                , ("HostBootstrap.Effect.Private", "internal/effect/Private.hs")
                , ("HostBootstrap.Ownership.Private", "internal/ownership/Private.hs")
                ]
    , testCase "a cycle back to the root does not discard a later leaf" $
        run
            [ rootNode ["import HostBootstrap.PrivateA"]
            , node "HostBootstrap.PrivateA" "internal/a.hs" ["import HostBootstrap.PrivateB"]
            , node "HostBootstrap.PrivateB" "internal/b.hs" ["import HostBootstrap.Root", "import HostBootstrap.ZLeaf"]
            , node "HostBootstrap.ZLeaf" "src/leaf.hs" []
            ] @?= Right [("HostBootstrap.PrivateA", "internal/a.hs"), ("HostBootstrap.PrivateB", "internal/b.hs"), ("HostBootstrap.ZLeaf", "src/leaf.hs")]
    , testCase "a diamond visits each dependency once in sorted order" $
        run
            [ rootNode ["import HostBootstrap.Right", "import HostBootstrap.Left"]
            , node "HostBootstrap.Left" "src/left.hs" ["import HostBootstrap.Shared"]
            , node "HostBootstrap.Right" "src/right.hs" ["import HostBootstrap.Shared"]
            , node "HostBootstrap.Shared" "internal/shared.hs" []
            ] @?= Right [("HostBootstrap.Left", "src/left.hs"), ("HostBootstrap.Right", "src/right.hs"), ("HostBootstrap.Shared", "internal/shared.hs")]
    , testCase "an unresolved dependency names its private importer and path" $
        run [rootNode ["import HostBootstrap.Private"], node "HostBootstrap.Private" "internal/private.hs" ["import HostBootstrap.Missing"]]
            @?= Left "HostBootstrap module missing: HostBootstrap.Missing imported by HostBootstrap.Private (internal/private.hs)"
    , testCase "an ambiguous dependency names its importer and candidate paths" $
        run [rootNode ["import HostBootstrap.Duplicate"], node "HostBootstrap.Duplicate" "src/duplicate.hs" [], node "HostBootstrap.Duplicate" "internal/duplicate.hs" []]
            @?= Left ("HostBootstrap module ambiguous: HostBootstrap.Duplicate imported by " <> root <> " (" <> rootPath <> "); candidates: " <> show (["internal/duplicate.hs", "src/duplicate.hs"] :: [FilePath]))
    , testCase "an unresolved root refuses" $
        run [] @?= Left ("HostBootstrap module missing: " <> root <> " (root)")
    , testCase "an ambiguous root refuses" $
        run [rootNode [], node root "src/root.hs" []]
            @?= Left ("HostBootstrap module ambiguous: " <> root <> " (root); candidates: " <> show [rootPath, "src/root.hs"])
    , testCase "external namespaces and quoted or commented imports are ignored" $
        run [rootNode ["import Data.Text", "import System.Directory", "import HostBootstrapper.Library", "-- import HostBootstrap.Missing", "quoted = \"import HostBootstrap.Missing\""]]
            @?= Right []
    ]
  where
    root = "HostBootstrap.Root"
    rootPath = "internal/authority/HostBootstrap/Root.hs"
    node name path imports = (name, path, unlines (("module " <> name <> " where") : imports))
    rootNode = node root rootPath
    run inventory = SourceGuard.transitiveHostBootstrapImports inventory root

authorityErrorConstructionCases :: [TestTree]
authorityErrorConstructionCases =
    [ testCase "every declared AuthorityError has a production construction witness" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            sources <- SourceGuard.readLibrarySources packageRoot description
            check [(name, source) | (name, _, source) <- sources] @?= Right []
    , testCase "named RHS construction may live in another library module" $
        check [("Declaration", declaration), ("Producer", "produce = pure (Left (Unused reason))\n")] @?= Right []
    , testCase "case RHS construction is recognized" $
        check (fixture ["produce input = case input of", "  Nothing -> pure (Left (Unused reason))"]) @?= Right []
    , testCase "balanced argument groups and literal delimiters are recognized" $ do
        check (fixture ["produce = pure (Left (Unused (Text.pack reason)))"]) @?= Right []
        check (fixture ["produce = pure (Left (Unused \")\"))"]) @?= Right []
    , testCase "the complete closed verb parser is a construction witness" $
        check [("Parser", parserDeclaration <> parser)] @?= Right []
    , testCase "a changed verb parser has no implicit bare-Left exception" $
        check [("Parser", parserDeclaration <> parser <> "  extra -> Left (AuthorityUnknownVerb extra)\n")]
            @?= Right ["AuthorityUnknownVerb"]
    , testCase "every constructor argument is required" $ do
        let two body = [("Fixture", "data AuthorityError = Two Text Text\n" <> body)]
        check (two "produce = pure (Left (Two first))\n") @?= Right ["Two"]
        check (two "produce = pure (Left (Two first second))\n") @?= Right []
    , testCase "a missing declaration refuses" $
        check [("Fixture", "produce = pure (Left (Unused reason))\n")] @?= Left "AuthorityError declaration missing"
    , testCase "ambiguous declarations refuse" $
        check [("First", declaration), ("Second", declaration)] @?= Left "AuthorityError declaration ambiguous"
    , testCase "an unsupported constructor shape refuses" $
        check [("Fixture", "data AuthorityError = Unused (Maybe Text)\n")]
            @?= Left "AuthorityError must be a simple prefix-constructor sum"
    ]
        <> [ testCase label $ check (fixture body) @?= Right ["Unused"]
           | (label, body) <-
                [ ("a declaration alone is not construction", [])
                , ("the renderer is excluded even when it constructs", ["authorityErrorMessage failure = pure (Left (Unused reason))"])
                , ("a function pattern is not construction", ["observe (Unused reason) = reason"])
                , ("a case pattern is not construction", ["observe value = case value of", "  Unused reason -> reason"])
                , ("a lambda pattern is not construction", ["observe = \\(Unused reason) -> reason"])
                , ("a view pattern is not construction", ["observe (id -> Left (Unused reason)) = reason"])
                , ("a bare Left pattern is not construction", ["observe (Left (Unused reason)) = reason"])
                , ("a shadowed pure function binder is not construction", ["pure (Left (Unused reason)) = reason", "pure _ = \"fallback\""])
                , ("an import alone is not construction", ["import Foreign (Unused)"])
                , ("comments cannot manufacture expression anchors", ["-- produce = pure (Left (Unused reason))", "{- nested {- comment -}", "produce = pure (Left (Unused reason))", "-}"])
                , ("a string is not construction", ["quoted = \"= pure (Left (Unused reason))\""])
                , ("a type signature is not construction", ["observe :: a -> pure (Left (Unused reason))"])
                , ("a type synonym is not construction", ["type Mention pure reason = pure (Left (Unused reason))"])
                , ("an unapplied constructor is not construction", ["produce = pure (Left (Unused))"])
                , ("an unbalanced construction is not evidence", ["produce = pure (Left (Unused reason)"])
                , ("mismatched nested delimiters are not evidence", ["produce = pure (Left (Unused [reason)))"])
                , ("an unrecognized expression style fails closed", ["produce = pure $ Left (Unused reason)"])
                ]
           ]
  where
    check = SourceGuard.unproducedAuthorityErrorConstructors
    declaration = "data AuthorityError = Unused Text\n"
    fixture body = [("Fixture", declaration <> unlines body)]
    parserDeclaration = "data AuthorityError = AuthorityUnknownVerb Text\n"
    parser = unlines
        [ "parseProjectVerb raw = case raw of"
        , "  \"up\" -> Right (SomeProjectVerb ProjectUp)"
        , "  \"down\" -> Right (SomeProjectVerb ProjectDown)"
        , "  \"destroy\" -> Right (SomeProjectVerb ProjectDestroy)"
        , "  _ -> Left (AuthorityUnknownVerb raw)"
        ]

librarySourceDiscoveryCases :: [TestTree]
librarySourceDiscoveryCases =
    [ testCase "module lookup follows a private library home and deduplicates shared roots" $
        withSystemTempDirectory "hostbootstrap-library-source-home" $ \packageRoot -> do
            let description = unlines
                    [ "common shared"
                    , "  hs-source-dirs: src"
                    , "library"
                    , "  import: shared"
                    , "  hs-source-dirs: src/."
                    , "library earlier-private"
                    , "  hs-source-dirs: src"
                    , "library authority-private"
                    , "  hs-source-dirs: internal/authority"
                    , "executable helper"
                    , "  hs-source-dirs: app"
                    , "test-suite checks"
                    , "  hs-source-dirs: test"
                    ]
            public <- writeFixtureModule packageRoot "src" "HostBootstrap.Public"
            kernel <- writeFixtureModule packageRoot ("internal" </> "authority") "HostBootstrap.Authority.Kernel"
            _ <- writeFixtureModule packageRoot "app" "Ignored.Application"
            _ <- writeFixtureModule packageRoot "test" "Ignored.Test"
            SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Authority.Kernel" >>= (@?= kernel)
            SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Public" >>= (@?= public)
            sources <- SourceGuard.readLibrarySources packageRoot description
            [(name, path) | (name, path, _) <- sources]
                @?= [("HostBootstrap.Authority.Kernel", kernel), ("HostBootstrap.Public", public)]
    , testCase "module lookup refuses a missing home" $
        withSystemTempDirectory "hostbootstrap-library-source-missing" $ \packageRoot -> do
            _ <- writeFixtureModule packageRoot "src" "HostBootstrap.Present"
            assertSourceDiscoveryFailure "library module source missing: HostBootstrap.Missing" $
                SourceGuard.libraryModulePath packageRoot "library\n  hs-source-dirs: src\n" "HostBootstrap.Missing"
    , testCase "module lookup and inventory refuse two physical homes for one identity" $
        withSystemTempDirectory "hostbootstrap-library-source-ambiguous" $ \packageRoot -> do
            let description = "library\n  hs-source-dirs: src\nlibrary private\n  hs-source-dirs: internal/authority\n"
            _ <- writeFixtureModule packageRoot "src" "HostBootstrap.Duplicate"
            _ <- writeFixtureModule packageRoot ("internal" </> "authority") "HostBootstrap.Duplicate"
            assertSourceDiscoveryFailure "library module source ambiguous: HostBootstrap.Duplicate" $
                SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Duplicate"
            assertSourceDiscoveryFailure "library module source ambiguous:" $
                SourceGuard.readLibrarySources packageRoot description
    , testCase "module lookup refuses a file declaring another module" $
        withSystemTempDirectory "hostbootstrap-library-source-declaration" $ \packageRoot -> do
            path <- writeFixtureModule packageRoot "src" "HostBootstrap.Expected"
            writeFile path "module HostBootstrap.Foreign where\n"
            assertSourceDiscoveryFailure "library source does not declare HostBootstrap.Expected:" $
                SourceGuard.libraryModulePath packageRoot "library\n  hs-source-dirs: src\n" "HostBootstrap.Expected"
    ]
  where
    writeFixtureModule :: FilePath -> FilePath -> String -> IO FilePath
    writeFixtureModule packageRoot sourceDir name = do
        let path = packageRoot </> sourceDir </> foldr (</>) "" (splitName name) <> ".hs"
        createDirectoryIfMissing True (takeDirectory path)
        writeFile path ("module " <> name <> " where\n")
        pure path
    splitName name = case break (== '.') name of
        (segment, '.' : remaining) -> segment : splitName remaining
        (segment, []) -> [segment]
        _ -> []

assertSourceDiscoveryFailure :: String -> IO result -> IO ()
assertSourceDiscoveryFailure expected action = do
    observed <- try (action >> pure ())
    case observed of
        Left (failure :: SomeException) ->
            assertBool ("unexpected source discovery failure: " <> displayException failure)
                (expected `isInfixOf` displayException failure)
        Right () -> assertFailure ("source discovery unexpectedly accepted " <> expected)

-- The protected store ----------------------------------------------------------

storeCases :: [TestTree]
storeCases =
    [ testCase "run liveness is close-on-exec and cannot be retained by a provider child" $
        withSystemTempDirectory "hostbootstrap-liveness-inheritance" $ \root -> do
            store <- either (assertFailure . show) pure =<< openProtectedStore root
            self <- getExecutablePath
            launched <-
                withRunLiveness store "inheritance-probe" $
                    spawnProcess self ["--hostbootstrap-liveness-inheritance-probe"]
            case launched of
                Right (Just probe) -> do
                    reacquired <-
                        withRunLiveness store "inheritance-probe" (getProcessExitCode probe >>= (@?= Nothing))
                            `finally` do
                                terminateProcess probe
                                _ <- waitForProcess probe
                                pure ()
                    reacquired @?= Right (Just ())
                Left failure -> assertFailure ("the first liveness owner failed: " ++ show failure)
                Right Nothing -> assertFailure "the first liveness owner was unexpectedly refused"
    , testCase "a live liveness holder refuses an out-of-process peer" $
        withSystemTempDirectory "hostbootstrap-liveness-peer" $ \root -> do
            store <- expectRight =<< openProtectedStore root
            self <- getExecutablePath
            let probe = do
                    (status, output, diagnostic) <-
                        readProcessWithExitCode self ["--hostbootstrap-liveness-probe", root, "peer-probe"] ""
                    output @?= ""
                    diagnostic @?= ""
                    pure status
            held <- withRunLiveness store "peer-probe" probe
            held @?= Right (Just (ExitFailure 3))
            probe >>= (@?= ExitSuccess)
    , testCase "a liveness name that could escape the store is refused" $
        withSystemTempDirectory "hostbootstrap-liveness-invalid" $ \workspace -> do
            let root = workspace </> "store"
                names = ["../escape", "a/b", "a\\b", "C:x", Text.pack (workspace </> "outside"), ""]
                snapshot = (,) <$> (sort <$> listDirectory workspace) <*> (sort <$> listDirectory root)
            store <- expectRight =<< openProtectedStore root
            before <- snapshot
            forM_ names $ \name -> do
                invoked <- newIORef False
                outcome <- withRunLiveness store name (writeIORef invoked True)
                case outcome of
                    Left (ProtectedInvalid _) -> pure ()
                    other -> assertFailure ("expected an invalid liveness name " <> show name <> ", got " <> show other)
                readIORef invoked >>= (@?= False)
                snapshot >>= (@?= before)
                doesDirectoryExist (root </> "liveness") >>= (@?= False)
    , testCase "an interrupted liveness extent releases its lock" $
        withSystemTempDirectory "hostbootstrap-liveness-interrupted" $ \root -> do
            store <- expectRight =<< openProtectedStore root
            interrupted <- timeout 100000 (withRunLiveness store "interrupted" (threadDelay 10000000))
            interrupted @?= Nothing
            withRunLiveness store "interrupted" (pure ()) >>= (@?= Right (Just ()))
            forM_ [0 .. 199] $ \micros -> do
                _ <- timeout micros (withRunLiveness store "interrupted" (pure ()))
                withRunLiveness store "interrupted" (pure ()) >>= (@?= Right (Just ()))
    , testCase "liveness body exceptions propagate unchanged and release the lock" $
        withSystemTempDirectory "hostbootstrap-liveness-exception" $ \root -> do
            store <- expectRight =<< openProtectedStore root
            let failure = userError "the liveness body failed"
            outcome <- try (withRunLiveness store "body-failure" (throwIO failure)) :: IO (Either IOException (Either ProtectedError (Maybe ())))
            outcome @?= Left failure
            withRunLiveness store "body-failure" (pure ()) >>= (@?= Right (Just ()))
    , testCase "a record round-trips through one exclusive entry" $
        withStore $ \store -> do
            key <- expectKey "alpha"
            written <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "first"
            recordVersionWord <$> written @?= Right 1
            observed <-
                withProtectedEntry store $ \session ->
                    readProtectedRecord session key
            fmap (fmap protectedRecordBytes) observed @?= Right (Just "first")
            assertNoRecordTemporaries store
    , testCase "a write against a stale version is refused and changes nothing" $
        withStore $ \store -> do
            key <- expectKey "beta"
            first <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "one"
            stale <- either (assertFailure . show) pure first
            _ <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key (ExpectVersion stale) "two"
            racing <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key (ExpectVersion stale) "three"
            case racing of
                Right version ->
                    assertFailure ("expected a version mismatch, wrote " <> show version)
                Left failure -> case failure of
                    ProtectedVersionMismatch{} -> pure ()
                    other -> assertFailure ("expected a version mismatch, got " <> show other)
            observed <-
                withProtectedEntry store $ \session ->
                    readProtectedRecord session key
            fmap (fmap protectedRecordBytes) observed @?= Right (Just "two")
            assertNoRecordTemporaries store
    , testCase "a create-if-absent write refuses an already published record" $
        withStore $ \store -> do
            key <- expectKey "gamma"
            _ <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "one"
            again <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "two"
            assertBool "the second create is refused" (isLeft again)
            assertNoRecordTemporaries store
    , testCase "a losing create contender can reread exact bytes but cannot replace a collision" $
        withStore $ \store -> do
            key <- expectKey "prepared-lower-boundary"
            first <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "canonical-prepared-row"
            version <- either (assertFailure . show) pure first
            identical <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "canonical-prepared-row"
            assertBool "the identical create contender still loses the CAS" (isLeft identical)
            exact <-
                withProtectedEntry store $ \session ->
                    readProtectedRecord session key
            case exact of
                Right (Just record) -> do
                    protectedRecordVersion record @?= version
                    protectedRecordBytes record @?= "canonical-prepared-row"
                other -> assertFailure ("expected exact durable readback, got " <> show other)
            collision <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "conflicting-row"
            assertBool "the conflicting create contender is refused" (isLeft collision)
            unchanged <-
                withProtectedEntry store $ \session ->
                    readProtectedRecord session key
            fmap (fmap protectedRecordBytes) unchanged
                @?= Right (Just "canonical-prepared-row")
            assertNoRecordTemporaries store
    , testCase "a conditional delete removes only the observed version" $
        withStore $ \store -> do
            key <- expectKey "delta"
            first <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "one"
            stale <- either (assertFailure . show) pure first
            second <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key (ExpectVersion stale) "two"
            current <- either (assertFailure . show) pure second
            refused <-
                withProtectedEntry store $ \session ->
                    compareAndDeleteProtectedRecord session key (ExpectVersion stale)
            refused @?= Left (ProtectedVersionMismatch (recordKeyText key) (Just stale) (Just current))
            observed <-
                withProtectedEntry store $ \session ->
                    readProtectedRecord session key
            fmap (fmap protectedRecordBytes) observed @?= Right (Just "two")
            removed <-
                withProtectedEntry store $ \session ->
                    compareAndDeleteProtectedRecord session key (ExpectVersion current)
            removed @?= Right ()
            absent <- withProtectedEntry store (\session -> readProtectedRecord session key)
            absent @?= Right Nothing
            missingVersion <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key (ExpectVersion current) "must not be created"
            missingVersion @?= Left (ProtectedVersionMismatch (recordKeyText key) (Just current) Nothing)
            stillAbsent <- withProtectedEntry store (\session -> readProtectedRecord session key)
            stillAbsent @?= Right Nothing
            assertNoRecordTemporaries store
    , testCase "the store identity survives reopening and names one store" $
        withStore $ \store -> do
            let identityPath = protectedStoreRoot store </> "store.identity"
            original <- ByteString.readFile identityPath
            original
                @?= "hbps2 "
                    <> TextEncoding.encodeUtf8 (protectedStoreIdentityText (protectedStoreIdentity store))
                    <> "\n"
            reopened <- openProtectedStore (protectedStoreRoot store)
            case reopened of
                Left failure -> assertFailure (show failure)
                Right again ->
                    protectedStoreIdentity again @?= protectedStoreIdentity store
            ByteString.readFile identityPath >>= (@?= original)
    , testCase "an out-of-process holder is excluded while the entry is held" $
        withStore $ \store -> do
            self <- getExecutablePath
            contended <-
                withProtectedEntry store $ \_ ->
                    Right <$> probeEntry self (protectedStoreRoot store)
            contended @?= Right Contended
            free <- probeEntry self (protectedStoreRoot store)
            free @?= Acquired
    , testCase "a malformed record is reported, never silently ignored" $
        withStore $ \store -> do
            key <- expectKey "torn"
            _ <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "one"
            writeFile (protectedStoreRoot store </> "records" </> "torn.rec") "garbage"
            observed <-
                withProtectedEntry store $ \session ->
                    readProtectedRecord session key
            case observed of
                Left (ProtectedMalformedRecord _ _) -> pure ()
                other -> assertFailure ("expected a malformed-record error, got " <> show other)
    , testCase "a key that could escape the store is rejected" $ do
        assertBool "a traversal key is rejected" (isLeft (mkRecordKey "../escape"))
        assertBool "an empty key is rejected" (isLeft (mkRecordKey ""))
        assertBool "a dotfile key is rejected" (isLeft (mkRecordKey ".hidden"))
        forM_ ["a/b", "x/../../escape", "a\\b", "C:x"] $ \key ->
            case mkRecordKey key of
                Left (ProtectedInvalid reason) ->
                    assertBool ("key alphabet refusal is missing: " <> show reason) ("may contain only" `Text.isInfixOf` reason)
                other -> assertFailure ("expected an alphabet refusal for " <> show key <> ", got " <> show other)
    ]
        <> protectedRecordNameCases
        <> protectedMalformedHeaderCases
        <> protectedEntryThreadCases
        <> protectedSessionExtentCases
        <> protectedIdentityCases
        <> protectedDurabilityCases

-- Root and command authority ------------------------------------------------------

rootGateIdentityCase :: Bool -> TestTree
rootGateIdentityCase foreignRoot = testCase label $
    Fixture.withFixtureInstalledProject $ \verifiedProject -> do
        let exercise :: InstalledProjectIdentity projectId -> IO ()
            exercise rootProject = withSystemTempDirectory "hostbootstrap-root-identity" $ \directory -> do
                rooted <- withCanonicalProjectRoot (directory </> "fixture.dhall") directory $ \canonicalRoot -> do
                    let rootPath = canonicalProjectRootPath canonicalRoot
                        supplied = Fixture.defaultProjectConfig (installedProjectName rootProject) (Text.pack rootPath) Context.HostOrchestrator
                    store <- expectRight =<< openProtectedStore (rootPath </> ".hostbootstrap" </> "authority" </> Text.unpack (installedProjectName rootProject))
                    opened <- withProductionRoot store rootProject ProjectUp $ \production -> do
                        let rootAuthority = productionRootAuthority production
                            unbound = productionRootUnboundLease production
                        profileAction <- expectRight =<< withProductionLifecycleProfile
                            (rootScopeAuthority rootAuthority)
                            (productionActiveMode (productionRootModeLease production))
                            unbound
                            ( \profile -> withProductionProjectCodec @Fixture.ProjectConfig $ \codec -> do
                                validated <- withValidatedConfig codec supplied $ \_ config -> do
                                    gateSteps <- expectRight (mkStepPlan [contextInitStep "root identity" (StepFrame (Text.unpack (Context.currentFrame (Fixture.context supplied))) "Host orchestrator") (const (pure StepChanged))])
                                    drafts <- expectRight (planDraftsFromValidatedBuilder canonicalRoot config (\_ _ -> Right gateSteps))
                                    planAction <- expectRight $ withProjectPlan profile canonicalRoot config drafts $ \plan -> do
                                        persisted <- withPersistedPlanSnapshot rootAuthority unbound plan $ \verified bound binding lease _ -> do
                                            contextual <- LifecycleContext.withValidatedLifecycleContext canonicalRoot store plan (Fixture.context supplied) $ \lifecycleContext -> do
                                                frameAction <- expectRight $ withCurrentFrame plan (Fixture.context supplied) $ \_ frame _ ->
                                                    withAcquisitionJournal rootAuthority lease bound binding plan $ \journal -> do
                                                        cursored <- withLifecycleCursor journal frame ProjectUp Prepare $ \prepareCursor -> do
                                                            executed <- withExecuteLifecycleCursor prepareCursor $ \cursor -> do
                                                                before <- protectedStoreImage store
                                                                -- Both openers refer to the same real plan/frame. Only the
                                                                -- fresh phantom from the second public opener is aligned.
                                                                admitted <- ProjectAuthority.authorizeRootProject rootAuthority ProjectUp verified bound binding lease plan journal (unsafeCoerce cursor) lifecycleContext verifiedProject
                                                                if foreignRoot then do
                                                                    (() <$ admitted) @?= Left (AuthorityStoreNotOurs (installedProjectName verifiedProject) (installedProjectName rootProject))
                                                                    protectedStoreImage store >>= (@?= before)
                                                                else do
                                                                    _ <- expectRight admitted
                                                                    after <- protectedStoreImage store
                                                                    let invocations = filter (Text.isPrefixOf "invocation." . (\(key, _, _) -> key))
                                                                    length (invocations after) @?= length (invocations before) + 1
                                                            expectRight executed
                                                        expectRight cursored
                                                expectRight =<< frameAction
                                            expectRight contextual
                                        expectRight persisted
                                    planAction
                                expectRight validated
                            )
                        profileAction
                        pure (Right ())
                    expectRight opened
                expectRight rooted
        if foreignRoot then do
            let otherName = if installedProjectName verifiedProject == "other-project" then "foreign-project" else "other-project"
            exerciseForeign <- expectRight (AuthorityFixture.withInstalledProjectKernel otherName exercise)
            exerciseForeign
        else exercise verifiedProject
  where
    label = if foreignRoot
        then "the root gate refuses a foreign root against the independently verified executable identity without writes"
        else "the root gate reserves with the matching independently verified executable identity"

exactProjectUpAuthorityCases :: [TestTree]
exactProjectUpAuthorityCases =
    [ rootGateIdentityCase False
    , rootGateIdentityCase True
    , testCase "the generic root gate consumes one exact root lifecycle context for every closed verb" $ do
        cwd <- getCurrentDirectory
        repoRoot <-
            findRepoRoot cwd
                >>= maybe (assertFailure "could not locate repository root") pure
        source <-
            TextIO.readFile
                ( repoRoot
                    </> "core"
                    </> "hostbootstrap-core"
                    </> "src"
                    </> "HostBootstrap"
                    </> "Authority"
                    </> "ProjectPlan.hs"
                )
        let normalized = Text.unwords (Text.words source)
            require fragment =
                assertBool
                    ("the generic root gate lost " ++ Text.unpack fragment)
                    (fragment `Text.isInfixOf` normalized)
        mapM_
            require
            [ "authorizeRootProject :: RootInvocationAuthority scope brokerGeneration verb -> ProjectVerb verb ->"
            , "LifecycleCursor scope planId frame brokerGeneration verb phase -> ValidatedLifecycleContext scope specDigest planId configId frame -> InstalledProjectIdentity projectId ->"
            , "reserveCurrentLifecycleCommandKernel project journal cursor"
            , "rootProject = installedProjectName project"
            , "rootProject /= rootAuthorityProjectName root"
            , "AuthorityStoreNotOurs rootProject (rootAuthorityProjectName root)"
            , "withValidatedRootLifecycleContext lifecycleContext"
            , "expectedVerb = projectVerbName verb"
            , "requireText \"root project verb\" expectedVerb"
            , "requireText \"cursor project verb\" expectedVerb"
            , "requireText \"journal project verb\" expectedVerb"
            ]
        assertBool
            "the former Up-only root gate must be absent"
            (not ("authorizeProjectUp" `Text.isInfixOf` source))
    , testCase "reverse-root reservation replay is closed, root-only, and version-stable" $ do
        source <- SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Authority.Kernel" >>= TextIO.readFile
        let normalized = Text.unwords (Text.words source)
            require fragment =
                assertBool
                    ("the reverse-root reservation gate lost " ++ Text.unpack fragment)
                    (fragment `Text.isInfixOf` normalized)
            commandAuthoritySection =
                fst
                    ( Text.breakOn
                        "instance Show (CommandAuthority"
                        (snd (Text.breakOn "data CommandAuthority" normalized))
                    )
            reservationIdentitySection =
                fst
                    ( Text.breakOn
                        "brokerCounterKey ::"
                        (snd (Text.breakOn "reservationIdentity ::" normalized))
                    )
            replayPolicy =
                Text.unpack . fst . Text.breakOn "reservationIdentity ::" . snd $
                    Text.breakOn "reverseRootReplayEligible ::" source
        mapM_
            require
            [ "data CommandReservation scope planId frame brokerGeneration verb phase = CommandReservation Text Text Text Text (BrokerEpoch brokerGeneration) (ProjectVerb verb) (LifecyclePhase phase) Bool"
            , "phase (reverseRootReplayEligible (rootAuthorityVerb root) phase)"
            , "Right (Just record) | protectedRecordBytes record == identity , replayEligible -> deliver (protectedRecordVersion record)"
            , "| protectedRecordBytes record == identity -> pure (Left (AuthorityInvocationConsumed invocation))"
            , "Right version -> do readback <- readProtectedRecord session recordKey"
            , "protectedRecordVersion record == version , protectedRecordBytes record == identity -> deliver (protectedRecordVersion record)"
            , "Right _ -> pure (Left (AuthorityReservationConflict invocation))"
            , "invocation = \"command-\" <> sha256Hex identity"
            , "Text.pack (show (recordVersionWord version))"
            , "invocationKey identity"
            ]
        SourceGuard.haskellTokens replayPolicy @?= SourceGuard.haskellTokens
            (unlines
                [ "reverseRootReplayEligible :: ProjectVerb verb -> LifecyclePhase phase -> Bool"
                , "reverseRootReplayEligible ProjectUp Prepare = False"
                , "reverseRootReplayEligible ProjectUp Execute = False"
                , "reverseRootReplayEligible ProjectUp Teardown = False"
                , "reverseRootReplayEligible ProjectDown Prepare = False"
                , "reverseRootReplayEligible ProjectDown Execute = False"
                , "reverseRootReplayEligible ProjectDown Teardown = True"
                , "reverseRootReplayEligible ProjectDestroy Prepare = False"
                , "reverseRootReplayEligible ProjectDestroy Execute = False"
                , "reverseRootReplayEligible ProjectDestroy Teardown = True"
                ])
        assertBool
            "replay policy leaked into CommandAuthority rather than its private reservation"
            (not ("Bool" `Text.isInfixOf` commandAuthoritySection))
        Text.count "field (" reservationIdentitySection @?= 7
        mapM_
            ( \fragment ->
                assertBool
                    ("canonical reservation identity gained " ++ Text.unpack fragment)
                    (not (fragment `Text.isInfixOf` reservationIdentitySection))
            )
            ["replayEligible", "decode", "caller", "wire"]
    ]

foreignOsPrincipalCase :: Bool -> TestTree
foreignOsPrincipalCase existing =
    testCase label $
        withStore $ \storeA ->
            withStore $ \storeB -> do
                assertBool "the fixture stores share an identity" (protectedStoreIdentity storeA /= protectedStoreIdentity storeB)
                principalA <- expectRight =<< withAuthorityEntry storeA verifyOsPrincipal
                admitted <- Fixture.withFixtureInstalledProject $ \project ->
                    withProductionRoot storeB project ProjectUp $ \productionRoot -> do
                        principalB <- expectRight =<< withAuthorityEntry storeB verifyOsPrincipal
                        callbacks <- newIORef (0 :: Int)
                        let epoch = rootAuthorityEpoch (productionRootAuthority productionRoot)
                            use _ = do
                                atomicModifyIORef' callbacks (\count -> (count + 1, ()))
                                pure (Right ())
                            enter principal =
                                withAuthorityEntry storeB $ \session ->
                                    if existing
                                        then
                                            AuthorityFixture.withExistingVerifiedRootInvocationKernel
                                                AuthorityFixture.ProductionRootScope
                                                session
                                                project
                                                principal
                                                epoch
                                                ProjectUp
                                                use
                                        else
                                            AuthorityFixture.withVerifiedRootInvocationKernel
                                                AuthorityFixture.ProductionRootScope
                                                session
                                                project
                                                principal
                                                epoch
                                                ProjectUp
                                                use
                        before <- protectedStoreImage storeB
                        matching <- enter principalB
                        matching @?= Right ()
                        readIORef callbacks >>= (@?= 1)
                        protectedStoreImage storeB >>= (@?= before)
                        writeIORef callbacks 0
                        refused <- enter principalA
                        refused
                            @?= Left
                                (AuthorityOperatorRefused "the operator authorization was issued for a different protected store")
                        readIORef callbacks >>= (@?= 0)
                        protectedStoreImage storeB >>= (@?= before)
                        pure (Right ())
                admitted @?= Right ()
  where
    label
        | existing = "existing root admission refuses an OS principal issued by another store"
        | otherwise = "fresh root admission refuses an OS principal issued by another store"

foreignStoreEpochCase :: Bool -> TestTree
foreignStoreEpochCase existing =
    testCase label $
        withStore $ \storeA ->
            withStore $ \storeB -> do
                assertBool "the fixture stores share an identity" (protectedStoreIdentity storeA /= protectedStoreIdentity storeB)
                admitted <- Fixture.withFixtureInstalledProject $ \project ->
                    withProductionRoot storeA project ProjectUp $ \rootA ->
                        withProductionRoot storeB project ProjectUp $ \rootB -> do
                            assertForeignEpochRefused
                                existing
                                storeB
                                project
                                (rootAuthorityEpoch (productionRootAuthority rootB))
                                (rootAuthorityEpoch (productionRootAuthority rootA))
                            pure (Right ())
                admitted @?= Right ()
  where
    label
        | existing = "existing root admission refuses an epoch allocated in another store"
        | otherwise = "fresh root admission refuses an epoch allocated in another store"

foreignProjectEpochCase :: Bool -> TestTree
foreignProjectEpochCase existing =
    testCase label $
        withStore $ \storeB -> do
            admitted <- Fixture.withFixtureInstalledProject $ \project -> do
                let otherName = if installedProjectName project == "other-project" then "foreign-project" else "other-project"
                exercise <- expectRight $
                    AuthorityFixture.withInstalledProjectKernel otherName $ \otherProject ->
                        withFreshFixtureEpoch storeB otherProject $ \foreignEpoch ->
                            withProductionRoot storeB project ProjectUp $ \rootB -> do
                                assertForeignEpochRefused
                                    existing
                                    storeB
                                    project
                                    (rootAuthorityEpoch (productionRootAuthority rootB))
                                    foreignEpoch
                                pure (Right ())
                exercise
            admitted @?= Right ()
  where
    label
        | existing = "existing root admission refuses an epoch allocated for another project in the same store"
        | otherwise = "fresh root admission refuses an epoch allocated for another project in the same store"

-- | Release the allocation entry before the fixture callback re-enters its store.
withFreshFixtureEpoch ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    (forall brokerGeneration. BrokerEpoch brokerGeneration -> IO result) ->
    IO result
withFreshFixtureEpoch store project use = do
    action <- expectRight =<<
        withAuthorityEntry store (\session ->
            AuthorityFixture.withFreshBrokerEpochKernel session project $ \epoch ->
                pure (Right (use epoch)))
    action

assertForeignEpochRefused ::
    Bool ->
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    BrokerEpoch matchingGeneration ->
    BrokerEpoch foreignGeneration ->
    IO ()
assertForeignEpochRefused existing store project matchingEpoch foreignEpoch = do
    brokerEpochWord foreignEpoch @?= brokerEpochWord matchingEpoch
    principal <- expectRight =<< withAuthorityEntry store verifyOsPrincipal
    callbacks <- newIORef (0 :: Int)
    let use _ = do
            atomicModifyIORef' callbacks (\count -> (count + 1, ()))
            pure (Right ())
        enter :: BrokerEpoch brokerGeneration -> IO (Either AuthorityError ())
        enter epoch =
            withAuthorityEntry store $ \session ->
                if existing
                    then
                        AuthorityFixture.withExistingVerifiedRootInvocationKernel
                            AuthorityFixture.ProductionRootScope
                            session
                            project
                            principal
                            epoch
                            ProjectUp
                            use
                    else
                        AuthorityFixture.withVerifiedRootInvocationKernel
                            AuthorityFixture.ProductionRootScope
                            session
                            project
                            principal
                            epoch
                            ProjectUp
                            use
    before <- protectedStoreImage store
    matching <- enter matchingEpoch
    matching @?= Right ()
    readIORef callbacks >>= (@?= 1)
    protectedStoreImage store >>= (@?= before)
    writeIORef callbacks 0
    refused <- enter foreignEpoch
    refused
        @?= Left
            ( AuthorityEpochOriginMismatch
                (installedProjectName project)
                (protectedStoreIdentityText (protectedStoreIdentity store))
            )
    readIORef callbacks >>= (@?= 0)
    protectedStoreImage store >>= (@?= before)

type ReservationEvidence = (Text, RecordKey, ByteString.ByteString)

-- | Allocate and bind once, then return only the word that a new session must
-- reify. No protected session or competing allocation crosses this boundary.
initializeReservationStore :: ProtectedStore -> IO Word64
initializeReservationStore store =
    Fixture.withFixtureInstalledProject $ \project ->
        expectRight =<< withAuthorityEntry store (\session -> do
            principal <- expectRight =<< verifyOsPrincipal session
            AuthorityFixture.withFreshBrokerEpochKernel session project $ \epoch ->
                AuthorityFixture.withVerifiedRootInvocationKernel
                    AuthorityFixture.ProductionRootScope session project principal epoch ProjectUp
                    (\_ -> pure (Right (brokerEpochWord epoch))))

withRecordedReservationRoot ::
    ProtectedStore -> Word64 -> ProjectVerb verb ->
    ( forall session projectId brokerGeneration.
      ProtectedSession session -> InstalledProjectIdentity projectId -> BrokerEpoch brokerGeneration ->
      RootInvocationAuthority (Production projectId) brokerGeneration verb -> IO (Either AuthorityError result)
    ) ->
    IO (Either AuthorityError result)
withRecordedReservationRoot store recorded verb use =
    Fixture.withFixtureInstalledProject $ \project ->
        withAuthorityEntry store $ \session -> do
            principal <- verifyOsPrincipal session
            case principal of
                Left failure -> pure (Left failure)
                Right verified ->
                    AuthorityFixture.withReifiedAllocatedBrokerEpochKernel session project recorded $ \epoch ->
                        AuthorityFixture.withExistingVerifiedRootInvocationKernel
                            AuthorityFixture.ProductionRootScope session project verified epoch verb
                            (use session project epoch)

rebuildAndReserveCommand ::
    ProtectedStore -> Word64 -> ProjectVerb verb -> LifecyclePhase phase -> Text -> Text ->
    IO (Either AuthorityError ReservationEvidence)
rebuildAndReserveCommand = rebuildAndReserveCommandWith (pure ())

rebuildAndReserveCommandWith ::
    IO () -> ProtectedStore -> Word64 -> ProjectVerb verb -> LifecyclePhase phase -> Text -> Text ->
    IO (Either AuthorityError ReservationEvidence)
rebuildAndReserveCommandWith delivered store recorded verb phase planDigest frameKey =
    withRecordedReservationRoot store recorded verb $ \session project epoch root -> do
        let identity = AuthorityFixture.reservationIdentity
                (installedProjectName project) (protectedStoreIdentityText (protectedStoreIdentity store))
                planDigest frameKey epoch verb phase
        case AuthorityFixture.invocationKey identity of
            Left failure -> pure (Left failure)
            Right key ->
                AuthorityFixture.reserveCommandInvocationKernel session project
                    (AuthorityFixture.commandReservationKernel root planDigest phase frameKey)
                    (\authority -> delivered >> pure (Right (invocationIdText (commandAuthorityInvocation authority), key, identity)))

reservationInvocationBase :: ReservationEvidence -> Text
reservationInvocationBase (_, key, _) = "command-" <> Text.drop (Text.length "invocation.") (recordKeyText key)

reservationRows :: [(Text, Word64, ByteString.ByteString)] -> [(Text, Word64, ByteString.ByteString)]
reservationRows = filter (Text.isPrefixOf "invocation." . (\(key, _, _) -> key))

assertReservationCount :: ProtectedStore -> Int -> IO ()
assertReservationCount store count = length . reservationRows <$> protectedStoreImage store >>= (@?= count)

commandReservationCases :: [TestTree]
commandReservationCases =
    [ testCase "two ready threads reserve one identical invocation exactly once" reservationThreadRaceCase
    , testCase "a ready process and thread reserve one identical invocation exactly once" reservationProcessRaceCase
    , reservationDistinctMemberCase "plan digest" $ \store epoch -> rebuildAndReserveCommand store epoch ProjectUp Execute "plan-d2" "frame-f"
    , reservationDistinctMemberCase "frame" $ \store epoch -> rebuildAndReserveCommand store epoch ProjectUp Execute "plan-d" "frame-f2"
    , reservationDistinctMemberCase "phase" $ \store epoch -> rebuildAndReserveCommand store epoch ProjectUp Prepare "plan-d" "frame-f"
    , reservationDistinctMemberCase "verb" $ \store epoch -> rebuildAndReserveCommand store epoch ProjectDown Execute "plan-d" "frame-f"
    , reservationDistinctMemberCase "epoch" $ \store _ -> do
        next <- initializeReservationStore store
        rebuildAndReserveCommand store next ProjectUp Execute "plan-d" "frame-f"
    , testCase "another store changes the reservation identity at the same allocated epoch" $
        withStore $ \firstStore -> withStore $ \secondStore -> do
            firstEpoch <- initializeReservationStore firstStore
            secondEpoch <- initializeReservationStore secondStore
            secondEpoch @?= firstEpoch
            first <- expectRight =<< rebuildAndReserveCommand firstStore firstEpoch ProjectUp Execute "plan-d" "frame-f"
            second <- expectRight =<< rebuildAndReserveCommand secondStore secondEpoch ProjectUp Execute "plan-d" "frame-f"
            assertDistinctReservation first second
            assertReservationCount firstStore 1
            assertReservationCount secondStore 1
    , testCase "the project member changes canonical reservation bytes and key independently" $
        withStore $ \store -> do
            recorded <- initializeReservationStore store
            recorded @?= 1
            checked <- withRecordedReservationRoot store recorded ProjectUp $ \_session project epoch _root -> do
                let projectName = installedProjectName project
                    otherProject = if projectName == "other-project" then "foreign-project" else "other-project"
                    identity name = AuthorityFixture.reservationIdentity name
                        (protectedStoreIdentityText (protectedStoreIdentity store)) "plan-d" "frame-f" epoch ProjectUp Execute
                    first = identity projectName
                    second = identity otherProject
                assertBool "different projects shared canonical bytes" (first /= second)
                firstKey <- expectRight (AuthorityFixture.invocationKey first)
                secondKey <- expectRight (AuthorityFixture.invocationKey second)
                assertBool "different projects shared an invocation key" (firstKey /= secondKey)
                let golden = AuthorityFixture.reservationIdentity "project-a" "store-a" "plan-d" "frame-f" epoch ProjectUp Execute
                golden @?= "9:project-a7:store-a6:plan-d7:frame-f1:12:up7:execute"
                goldenKey <- expectRight (AuthorityFixture.invocationKey golden)
                recordKeyText goldenKey @?= "invocation.34e252c355cbd9eee9ac0cc9410de50f4311857b17ae4ffe1e24ac01eb62c050"
                pure (Right ())
            checked @?= Right ()
            assertReservationCount store 0
    , testCase "a foreign installed project refuses before reservation or callback" reservationProjectMismatchCase
    , testCase "a reservation refuses a different session store before callback" reservationWrongStoreCase
    , reservationConflictCase "up Execute" ProjectUp Execute
    , reservationConflictCase "down Teardown" ProjectDown Teardown
    , reservationConflictCase "destroy Teardown" ProjectDestroy Teardown
    , reservationReplayCase "up Execute is consumed" ProjectUp Execute False
    , reservationReplayCase "down Teardown replays its exact version" ProjectDown Teardown True
    , reservationReplayCase "destroy Teardown replays its exact version" ProjectDestroy Teardown True
    ]

reservationDistinctMemberCase :: String -> (ProtectedStore -> Word64 -> IO (Either AuthorityError ReservationEvidence)) -> TestTree
reservationDistinctMemberCase member changed = testCase ("changing only " <> member <> " names a second invocation") $
    withStore $ \store -> do
        recorded <- initializeReservationStore store
        first <- expectRight =<< rebuildAndReserveCommand store recorded ProjectUp Execute "plan-d" "frame-f"
        second <- expectRight =<< changed store recorded
        assertDistinctReservation first second
        assertReservationCount store 2

assertDistinctReservation :: ReservationEvidence -> ReservationEvidence -> IO ()
assertDistinctReservation (firstInvocation, firstKey, firstBytes) (secondInvocation, secondKey, secondBytes) = do
    assertBool "the changed member shared an invocation" (firstInvocation /= secondInvocation)
    assertBool "the changed member shared a record key" (firstKey /= secondKey)
    assertBool "the changed member shared canonical bytes" (firstBytes /= secondBytes)

reservationProjectMismatchCase :: IO ()
reservationProjectMismatchCase = withStore $ \store -> do
    recorded <- initializeReservationStore store
    projectName <- Fixture.fixtureExecutableName
    let otherName = if projectName == "other-project" then "foreign-project" else "other-project"
    before <- protectedStoreImage store
    callbacks <- newIORef (0 :: Int)
    refused <- withRecordedReservationRoot store recorded ProjectUp $ \session project _epoch root -> do
        reserve <- expectRight $ AuthorityFixture.withInstalledProjectKernel otherName $ \otherProject ->
            AuthorityFixture.reserveCommandInvocationKernel session otherProject
                (AuthorityFixture.commandReservationKernel root "plan-d" Execute "frame-f")
                (\_ -> atomicModifyIORef' callbacks (\count -> (count + 1, ())) >> pure (Right ()))
        outcome <- reserve
        outcome @?= Left (AuthorityStoreNotOurs otherName (installedProjectName project))
        pure outcome
    refused @?= Left (AuthorityStoreNotOurs otherName projectName)
    readIORef callbacks >>= (@?= 0)
    protectedStoreImage store >>= (@?= before)

reservationWrongStoreCase :: IO ()
reservationWrongStoreCase = withStore $ \storeA -> withStore $ \storeB -> do
    recorded <- initializeReservationStore storeA
    beforeA <- protectedStoreImage storeA
    beforeB <- protectedStoreImage storeB
    callbacks <- newIORef (0 :: Int)
    refused <- withRecordedReservationRoot storeA recorded ProjectUp $ \_session project _epoch root ->
        withAuthorityEntry storeB $ \sessionB ->
            AuthorityFixture.reserveCommandInvocationKernel sessionB project
                (AuthorityFixture.commandReservationKernel root "plan-d" Execute "frame-f")
                (\_ -> atomicModifyIORef' callbacks (\count -> (count + 1, ())) >> pure (Right ()))
    refused @?= Left (AuthorityWrongStore (protectedStoreIdentityText (protectedStoreIdentity storeA)) (protectedStoreIdentityText (protectedStoreIdentity storeB)))
    readIORef callbacks >>= (@?= 0)
    protectedStoreImage storeA >>= (@?= beforeA)
    protectedStoreImage storeB >>= (@?= beforeB)

reservationConflictCase :: String -> ProjectVerb verb -> LifecyclePhase phase -> TestTree
reservationConflictCase label verb phase = testCase (label <> " refuses changed bytes at its own invocation key") $
    withStore $ \store -> do
        recorded <- initializeReservationStore store
        first@(_, key, _) <- expectRight =<< rebuildAndReserveCommand store recorded verb phase "plan-d" "frame-f"
        rewritten <- withProtectedEntry store $ \session -> do
            present <- expectRight =<< readProtectedRecord session key
            record <- maybe (assertFailure "the reserved invocation disappeared") pure present
            compareAndSwapProtectedRecord session key (ExpectVersion (protectedRecordVersion record)) "different canonical identity"
        _ <- expectRight rewritten
        before <- protectedStoreImage store
        callbacks <- newIORef (0 :: Int)
        refused <- rebuildAndReserveCommandWith
            (atomicModifyIORef' callbacks (\count -> (count + 1, ())))
            store recorded verb phase "plan-d" "frame-f"
        refused @?= Left (AuthorityReservationConflict (reservationInvocationBase first))
        readIORef callbacks >>= (@?= 0)
        protectedStoreImage store >>= (@?= before)

reservationReplayCase :: String -> ProjectVerb verb -> LifecyclePhase phase -> Bool -> TestTree
reservationReplayCase label verb phase replay = testCase label $
    withStore $ \store -> do
        recorded <- initializeReservationStore store
        first <- expectRight =<< rebuildAndReserveCommand store recorded verb phase "plan-d" "frame-f"
        before <- protectedStoreImage store
        callbacks <- newIORef (0 :: Int)
        second <- rebuildAndReserveCommandWith
            (atomicModifyIORef' callbacks (\count -> (count + 1, ())))
            store recorded verb phase "plan-d" "frame-f"
        second @?= if replay then Right first else Left (AuthorityInvocationConsumed (reservationInvocationBase first))
        readIORef callbacks >>= (@?= if replay then 1 else 0)
        protectedStoreImage store >>= (@?= before)

awaitReservation :: String -> IO result -> IO result
awaitReservation label action = timeout 30000000 action >>= maybe (assertFailure (label <> " timed out")) pure

reservationThreadRaceCase :: IO ()
reservationThreadRaceCase = withStore $ \store -> mask $ \restore -> do
    recorded <- initializeReservationStore store
    ready <- newEmptyMVar
    results <- replicateM 2 newEmptyMVar
    workers <- newIORef []
    let cleanup = readIORef workers >>= mapM_ killThread
    (do
        entered <- withAuthorityEntry store $ \_session -> do
            forM_ results $ \result -> do
                worker <- forkFinally
                    (restore (putMVar ready () >> rebuildAndReserveCommand store recorded ProjectUp Execute "plan-d" "frame-f"))
                    (putMVar result)
                atomicModifyIORef' workers (\threads -> (worker : threads, ()))
            _ <- restore (awaitReservation "both thread contenders" (replicateM 2 (takeMVar ready)))
            pure (Right ())
        expectRight entered
        restore $ do
            outcomes <- awaitReservation "thread reservation outcomes" (traverse takeMVar results)
            completed <- traverse (either (assertFailure . displayException) pure) outcomes
            case [winner | Right winner <- completed] of
                [winner] -> [failure | Left failure <- completed] @?= [AuthorityInvocationConsumed (reservationInvocationBase winner)]
                winners -> assertFailure ("expected exactly one thread winner, got " <> show winners)
            assertReservationCount store 1
      ) `finally` cleanup

reservationProcessRaceCase :: IO ()
reservationProcessRaceCase = withStore $ \store -> mask $ \restore -> do
    recorded <- initializeReservationStore store
    executable <- getExecutablePath
    parentReady <- newEmptyMVar
    parentResult <- newEmptyMVar
    workers <- newIORef []
    childRef <- newIORef Nothing
    let cleanup =
            (readIORef workers >>= mapM_ killThread)
                `finally` (readIORef childRef >>= maybe (pure ()) cleanupProcess)
    (do
        entered <- withAuthorityEntry store $ \_session -> do
            child@(_, output, _, _) <- createProcess
                (proc executable ["--hostbootstrap-command-reservation-probe", protectedStoreRoot store, show recorded, "plan-d", "frame-f"])
                    {std_out = CreatePipe, std_err = CreatePipe}
            writeIORef childRef (Just child)
            worker <- forkFinally
                (restore (putMVar parentReady () >> rebuildAndReserveCommand store recorded ProjectUp Execute "plan-d" "frame-f"))
                (putMVar parentResult)
            atomicModifyIORef' workers (\threads -> (worker : threads, ()))
            restore $ do
                handle <- maybe (assertFailure "the probe has no stdout pipe") pure output
                awaitReservation "the child readiness handshake" (hGetLine handle) >>= (@?= "ready")
                awaitReservation "the parent contender readiness" (takeMVar parentReady)
            pure (Right ())
        expectRight entered
        (_, output, errors, process) <- readIORef childRef >>= maybe (assertFailure "the reservation probe was not created") pure
        restore $ do
            parent <- awaitReservation "the parent reservation" (takeMVar parentResult)
                >>= either (assertFailure . displayException) pure
            code <- awaitReservation "the reservation probe exit" (waitForProcess process)
            remaining <- maybe (assertFailure "the probe lost stdout") ByteString.hGetContents output
            diagnostic <- maybe (assertFailure "the probe has no stderr pipe") ByteString.hGetContents errors
            assertBool ("unexpected reservation probe exit " <> show code <> ": " <> ByteStringChar8.unpack diagnostic)
                (code == ExitSuccess || code == ExitFailure 3)
            remaining @?= ByteString.empty
            diagnostic @?= ByteString.empty
            case parent of
                Right _ -> code @?= ExitFailure 3
                Left (AuthorityInvocationConsumed invocation) -> do
                    code @?= ExitSuccess
                    rows <- reservationRows <$> protectedStoreImage store
                    case rows of
                        [(key, _, _)] -> invocation @?= "command-" <> Text.drop (Text.length "invocation.") key
                        other -> assertFailure ("the winning child left an unexpected inventory: " <> show other)
                Left failure -> assertFailure ("the parent failed outside the one-use refusal: " <> show failure)
            assertReservationCount store 1
      ) `finally` cleanup

authorityFixtureTokens :: [String]
authorityFixtureTokens =
    [ "RootScopeWitness", "(", "ProductionRootScope", ")", ","
    , "commandReservationKernel", ","
    , "invocationKey", ","
    , "reservationIdentity", ","
    , "reserveCommandInvocationKernel", ","
    , "rootScopeProjectName", ","
    , "rootScopeStoreIdentity", ","
    , "rootScopeEpochWord", ","
    , "withExistingVerifiedRootInvocationKernel", ","
    , "withFreshBrokerEpochKernel", ","
    , "withInstalledProjectKernel", ","
    , "withReifiedAllocatedBrokerEpochKernel", ","
    , "withVerifiedRootInvocationKernel", ","
    ]

authorityCases :: [TestTree]
authorityCases =
    exactProjectUpAuthorityCases
        <> [ foreignOsPrincipalCase False
           , foreignOsPrincipalCase True
           , foreignStoreEpochCase False
           , foreignStoreEpochCase True
           , foreignProjectEpochCase False
           , foreignProjectEpochCase True
           , testCase "installed identity matches the normalized invoked executable" $ do
                executable <- getExecutablePath
                let invoked = normalizeExecutableIdentity executable
                outcome <-
                    withInstalledProjectIdentity
                        invoked
                        (pure . installedProjectName)
                outcome @?= Right invoked
           , testCase "installed identity refuses an empty name before executable matching" $ do
                outcome <- withInstalledProjectIdentity "" (pure . installedProjectName)
                outcome @?= Left (AuthorityInvalidIdentity "the installed project name must not be empty")
           , testCase "installed identity refuses a 65-character name before executable matching" $ do
                outcome <- withInstalledProjectIdentity (Text.replicate 65 "a") (pure . installedProjectName)
                outcome @?= Left (AuthorityInvalidIdentity "the installed project name must be at most 64 characters")
           , testCase "a 64-character installed identity reaches executable matching" $ do
                invoked <- normalizeExecutableIdentity <$> getExecutablePath
                let declared = Text.replicate 64 (if "a" `Text.isPrefixOf` invoked then "b" else "a")
                outcome <- withInstalledProjectIdentity declared (pure . installedProjectName)
                outcome @?= Left
                    (AuthorityInvalidIdentity
                        ("the declared project name " <> declared <> " does not match the invoked executable " <> invoked))
           , testCase "installed identity normalizes the Windows executable suffix" $ do
                normalizeExecutableIdentity "/installed/authority-project.ExE"
                    @?= "authority-project"
           , testCase "installed identity refuses a different declared project" $ do
                executable <- getExecutablePath
                let invoked = normalizeExecutableIdentity executable
                outcome <-
                    withInstalledProjectIdentity
                        "declared-project"
                        (pure . installedProjectName)
                case outcome of
                    Left (AuthorityInvalidIdentity reason) ->
                        assertBool "the refusal names both identities" $
                            "declared-project" `Text.isInfixOf` reason
                                && invoked `Text.isInfixOf` reason
                    other -> assertFailure ("expected an executable-identity refusal, got " <> show other)
           , testCase "installed identity refuses a non-stable project name" $ do
                outcome <-
                    withInstalledProjectIdentity
                        "not.a.stable.name"
                        (pure . installedProjectName)
                case outcome of
                    Left (AuthorityInvalidIdentity reason) ->
                        assertBool "the stable-name grammar made the decision" $
                            "may contain only alphanumerics, '-', and '_'" `Text.isInfixOf` reason
                                && "not.a.stable.name" `Text.isInfixOf` reason
                    other -> assertFailure ("expected an invalid stable name, got " <> show other)
           , testCase "installed identity refuses non-ASCII record names" $ do
                outcome <-
                    withInstalledProjectIdentity
                        "authority-λ"
                        (pure . installedProjectName)
                case outcome of
                    Left (AuthorityInvalidIdentity reason) ->
                        assertBool "the ASCII stable-name grammar made the decision" $
                            "may contain only alphanumerics, '-', and '_'" `Text.isInfixOf` reason
                                && "authority-λ" `Text.isInfixOf` reason
                    other -> assertFailure ("expected a non-ASCII identity refusal, got " <> show other)
           , testCase "OS-principal evidence names the exact protected store" $
                withStore $ \store -> do
                    outcome <- withAuthorityEntry store verifyOsPrincipal
                    case outcome of
                        Left failure -> assertFailure (show failure)
                        Right principal ->
                            assertBool "the evidence retained this store identity" $
                                protectedStoreIdentityText (protectedStoreIdentity store)
                                    `Text.isInfixOf` Text.pack (show principal)
           , testCase "OS-principal verification refuses an unavailable records directory" $
                withStore $ \store -> do
                    outcome <-
                        withAuthorityEntry store $ \session -> do
                            let recordsRoot = sessionStoreRoot session </> "records"
                                unavailableRoot = recordsRoot <> ".operator-refusal"
                            bracket_
                                (renameDirectory recordsRoot unavailableRoot)
                                (renameDirectory unavailableRoot recordsRoot)
                                (verifyOsPrincipal session)
                    case outcome of
                        Left (AuthorityOperatorRefused _) -> pure ()
                        other -> assertFailure ("expected an OS-principal refusal, got " <> show other)
           , testCase "broker generations advance monotonically" $
                withStore $ \store ->
                    Fixture.withFixtureInstalledProject $ \project -> do
                        first <-
                            withProductionRoot store project ProjectUp $ \root ->
                                pure (Right (brokerEpochWord (rootAuthorityEpoch (productionRootAuthority root))))
                        second <-
                            withProductionRoot store project ProjectUp $ \root ->
                                pure (Right (brokerEpochWord (rootAuthorityEpoch (productionRootAuthority root))))
                        first @?= Right 1
                        second @?= Right 2
           , testCase "a malformed broker counter refuses instead of reusing a generation" $
                withStore $ \store ->
                    Fixture.withFixtureInstalledProject $ \project -> do
                        key <-
                            expectKey
                                ("broker." <> installedProjectName project <> ".generation")
                        seeded <-
                            withProtectedEntry store $ \session ->
                                compareAndSwapProtectedRecord session key ExpectAbsent "not-a-counter"
                        assertBool "the malformed counter was seeded" (isRight seeded)
                        outcome <-
                            withProductionRoot store project ProjectUp (\_ -> pure (Right ()))
                        case outcome of
                            Left (ModeAuthorityFailure (AuthorityInvalidIdentity reason)) ->
                                assertBool "the refusal names the malformed counter" ("malformed" `Text.isInfixOf` reason)
                            other -> assertFailure ("expected a malformed-counter refusal, got " <> show other)
           , testCase "an exhausted broker counter refuses instead of wrapping" $
                withStore $ \store ->
                    Fixture.withFixtureInstalledProject $ \project -> do
                        key <-
                            expectKey
                                ("broker." <> installedProjectName project <> ".generation")
                        seeded <-
                            withProtectedEntry store $ \session ->
                                compareAndSwapProtectedRecord
                                    session
                                    key
                                    ExpectAbsent
                                    (ByteStringChar8.pack (show (maxBound :: Word64)))
                        assertBool "the exhausted broker counter was seeded" (isRight seeded)
                        outcome <-
                            withProductionRoot store project ProjectUp (\_ -> pure (Right ()))
                        case outcome of
                            Left (ModeAuthorityFailure (AuthorityInvalidIdentity reason)) ->
                                assertBool "the refusal names exhaustion" ("exhausted" `Text.isInfixOf` reason)
                            other -> assertFailure ("expected an exhausted-counter refusal, got " <> show other)
           , testCase "broker counters are separated by store" $
                withStore $ \firstStore ->
                    withStore $ \secondStore ->
                        Fixture.withFixtureInstalledProject $ \project -> do
                            first <-
                                withProductionRoot firstStore project ProjectUp $ \root ->
                                    pure
                                        ( Right
                                            (brokerEpochWord (rootAuthorityEpoch (productionRootAuthority root)))
                                        )
                            second <-
                                withProductionRoot secondStore project ProjectUp $ \root ->
                                    pure
                                        ( Right
                                            (brokerEpochWord (rootAuthorityEpoch (productionRootAuthority root)))
                                        )
                            first @?= Right 1
                            second @?= Right 1
           , testCase "the root gate retains the installed project name" $
                withStore $ \store ->
                    withRoot store ProjectUp $ \project _session root -> do
                        projectVerbName (rootAuthorityVerb root) @?= "up"
                        rootAuthorityProjectName root @?= installedProjectName project
                        pure (Right ())
           , testCase "root scope projection retains the project, store, and second broker epoch" $
                withStore $ \store ->
                    Fixture.withFixtureInstalledProject $ \project -> do
                        let expectedProject = installedProjectName project
                            expectedStore = protectedStoreIdentityText (protectedStoreIdentity store)
                        assertBool "the fixture project and store identities coincide" (expectedProject /= expectedStore)
                        first <-
                            withProductionRoot store project ProjectUp $ \productionRoot ->
                                pure (Right (brokerEpochWord (rootAuthorityEpoch (productionRootAuthority productionRoot))))
                        first @?= Right 1
                        second <-
                            withProductionRoot store project ProjectUp $ \productionRoot -> do
                                let root = productionRootAuthority productionRoot
                                    scope = rootScopeAuthority root
                                    expectedEpoch = brokerEpochWord (rootAuthorityEpoch root)
                                expectedEpoch @?= 2
                                AuthorityFixture.rootScopeProjectName scope @?= expectedProject
                                AuthorityFixture.rootScopeStoreIdentity scope @?= expectedStore
                                AuthorityFixture.rootScopeEpochWord scope @?= expectedEpoch
                                pure (Right ())
                        second @?= Right ()
           , testCase "command authority matches only the protected store that issued its epoch" $
                withStore $ \storeA ->
                    withStore $ \storeB -> do
                        assertBool "the fixture stores share an identity" (protectedStoreIdentity storeA /= protectedStoreIdentity storeB)
                        outcome <- Fixture.withFixtureInstalledProject $ \project ->
                            withAuthorityEntry storeA $ \session -> do
                                principal <- expectRight =<< verifyOsPrincipal session
                                AuthorityFixture.withFreshBrokerEpochKernel session project $ \epoch ->
                                    AuthorityFixture.withVerifiedRootInvocationKernel
                                        AuthorityFixture.ProductionRootScope
                                        session
                                        project
                                        principal
                                        epoch
                                        ProjectUp
                                        $ \root ->
                                            AuthorityFixture.reserveCommandInvocationKernel
                                                session
                                                project
                                                (AuthorityFixture.commandReservationKernel root "plan-d" Execute "frame-f")
                                                $ \authority -> do
                                                    commandAuthorityMatchesStore authority storeA @?= True
                                                    commandAuthorityMatchesStore authority storeB @?= False
                                                    pure (Right ())
                        outcome @?= Right ()
           , testCase "authority representations have one private home and a narrow test-only seam" $
                SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                    description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                    let requiredStanza name = maybe (assertFailure ("missing stanza: " <> name)) pure
                            (SourceGuard.namedStanza name description)
                        modules = ["HostBootstrap.Authority.Kernel", "HostBootstrap.Authority.Testing", "HostBootstrap.ProjectScope"]
                    private <- requiredStanza "library authority-internal"
                    SourceGuard.fieldValues "visibility" private @?= ["private"]
                    SourceGuard.fieldValues "hs-source-dirs" private @?= ["internal/authority"]
                    sort (SourceGuard.fieldModules "exposed-modules" private) @?= modules
                    SourceGuard.fieldModules "other-modules" private @?= []
                    mainLibrary <- requiredStanza "library"
                    coreTests <- requiredStanza "test-suite hostbootstrap-core-test"
                    forM_ [mainLibrary, coreTests] $ \component ->
                        assertBool "the authority consumers depend on the same private unit"
                            ("hostbootstrap-core:authority-internal" `elem` SourceGuard.fieldValues "build-depends" component)
                    forM_ ["exposed-modules", "other-modules"] $ \field ->
                        assertBool ("authority type definitions are duplicated in main-library " <> field)
                            (all (`notElem` SourceGuard.fieldModules field mainLibrary) modules)
                    filter (`elem` modules) (SourceGuard.fieldModules "reexported-modules" mainLibrary)
                        @?= ["HostBootstrap.ProjectScope"]
                    forM_
                        [ ("HostBootstrap.Authority.Kernel", "internal/authority/HostBootstrap/Authority/Kernel.hs")
                        , ("HostBootstrap.Authority.Testing", "internal/authority/HostBootstrap/Authority/Testing.hs")
                        , ("HostBootstrap.ProjectScope", "internal/authority/HostBootstrap/ProjectScope.hs")
                        ] $ \(name, expectedPath) -> do
                            path <- SourceGuard.libraryModulePath packageRoot description name
                            SourceGuard.repoRelativePath packageRoot path @?= expectedPath
                    seamPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Authority.Testing"
                    seam <- readFile seamPath
                    SourceGuard.moduleExportTokens "HostBootstrap.Authority.Testing" seam
                        @?= Just authorityFixtureTokens
                    SourceGuard.moduleImportTokens "HostBootstrap.Authority.Kernel" seam
                        @?= Just authorityFixtureTokens
           , testCase "only the verified facade calls the installed-identity kernel outside its exact private fixture reexport" $
                SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                    description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                    sources <- SourceGuard.readLibrarySources packageRoot description
                    let sites =
                            [ (name, SourceGuard.repoRelativePath packageRoot path, count)
                            | (name, path, source) <- sources
                            , let count = SourceGuard.countHaskellIdentifier "withInstalledProjectKernel" source
                            , count > 0
                            ]
                        requiredSource name = maybe (assertFailure ("module source missing: " <> name)) pure
                            (lookup name [(moduleName, source) | (moduleName, _, source) <- sources])
                    sort sites @?=
                        [ ("HostBootstrap.Authority", "src/HostBootstrap/Authority.hs", 2)
                        , ("HostBootstrap.Authority.Kernel", "internal/authority/HostBootstrap/Authority/Kernel.hs", 3)
                        , ("HostBootstrap.Authority.Testing", "internal/authority/HostBootstrap/Authority/Testing.hs", 2)
                        ]
                    kernel <- requiredSource "HostBootstrap.Authority.Kernel"
                    SourceGuard.countHaskellTokenSequence ["withInstalledProjectKernel", "::"] kernel @?= 1
                    SourceGuard.countHaskellTokenSequence ["withInstalledProjectKernel", "raw", "use"] kernel @?= 1
                    facade <- requiredSource "HostBootstrap.Authority"
                    SourceGuard.countHaskellTokenSequence ["case", "withInstalledProjectKernel", "declared"] facade @?= 1
                    seam <- requiredSource "HostBootstrap.Authority.Testing"
                    SourceGuard.moduleExportTokens "HostBootstrap.Authority.Testing" seam
                        @?= Just authorityFixtureTokens
                    SourceGuard.moduleImportTokens "HostBootstrap.Authority.Kernel" seam
                        @?= Just authorityFixtureTokens
                    sessionSource <- requiredSource "HostBootstrap.Lifecycle.Session"
                    let bridge = Text.unpack . fst . Text.breakOn "\ncursorBinding ::" . snd $
                            Text.breakOn "reserveCurrentLifecycleCommandKernel ::" (Text.pack sessionSource)
                    mapM_
                        (\name -> SourceGuard.countHaskellIdentifier name bridge @?= 1)
                        [ "withProtectedEntry", "validateJournalCursorSource"
                        , "requireExactCursorSource", "requireExactCurrentLifecycleCursor"
                        ]
                    SourceGuard.countHaskellIdentifier "validateLive" bridge @?= 2
                    SourceGuard.countHaskellTokenSequence
                        ["reserveCurrentLifecycleCommandKernel", "::", "forall", "projectId", "scope", "planId", "frame", "brokerGeneration", "verb", "phase", ".", "InstalledProjectIdentity", "projectId", "->"]
                        bridge @?= 1
                    SourceGuard.countHaskellTokenSequence
                        ["reserveCommandInvocationKernel", "session", "project", "reservation"] bridge @?= 1
           , testCase "only allocated-generation recovery sites call the broker-epoch reifier" $
                SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                    description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                    sources <- SourceGuard.readLibrarySources packageRoot description
                    let reifier = "withReifiedAllocatedBrokerEpochKernel"
                        sites =
                            [ (name, SourceGuard.repoRelativePath packageRoot path, count)
                            | (name, path, source) <- sources
                            , let count = SourceGuard.countHaskellIdentifier reifier source
                            , count > 0
                            ]
                        requiredSource name = maybe (assertFailure ("module source missing: " <> name)) pure
                            (lookup name [(moduleName, source) | (moduleName, _, source) <- sources])
                        occursOnce source fragment =
                            SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens fragment) source @?= 1
                    sort sites @?=
                        [ ("HostBootstrap.Authority.Kernel", "internal/authority/HostBootstrap/Authority/Kernel.hs", 3)
                        , ("HostBootstrap.Authority.Testing", "internal/authority/HostBootstrap/Authority/Testing.hs", 2)
                        , ("HostBootstrap.Lifecycle.Mode", "src/HostBootstrap/Lifecycle/Mode.hs", 3)
                        ]
                    kernel <- requiredSource "HostBootstrap.Authority.Kernel"
                    exports <- maybe (assertFailure "the authority kernel has no explicit export list") pure
                        (SourceGuard.moduleExportTokens "HostBootstrap.Authority.Kernel" kernel)
                    filter (== reifier) exports @?= [reifier]
                    occursOnce kernel "withReifiedAllocatedBrokerEpochKernel ::"
                    occursOnce kernel "withReifiedAllocatedBrokerEpochKernel session project recorded use"
                    mode <- requiredSource "HostBootstrap.Lifecycle.Mode"
                    imported <- maybe (assertFailure "Mode has no exact authority-kernel import list") pure
                        (SourceGuard.moduleImportTokens "HostBootstrap.Authority.Kernel" mode)
                    filter (== reifier) imported @?= [reifier]
                    occursOnce mode "withReifiedAllocatedBrokerEpochKernel session project target $ \\epoch -> pure (Right (converge verified canonical epoch))"
                    occursOnce mode "withRecordedEpoch session project recorded use = do outcome <- withReifiedAllocatedBrokerEpochKernel session project recorded (fmap Right . use)"
                    seam <- requiredSource "HostBootstrap.Authority.Testing"
                    SourceGuard.countHaskellIdentifier reifier seam @?= 2
                    SourceGuard.moduleExportTokens "HostBootstrap.Authority.Testing" seam @?= Just authorityFixtureTokens
                    SourceGuard.moduleImportTokens "HostBootstrap.Authority.Kernel" seam @?= Just authorityFixtureTokens
           , testCase "the authority kernel has a closed package-internal importer set" $ do
                cwd <- getCurrentDirectory
                root <- findRepoRoot cwd >>= maybe (assertFailure "could not locate the repository root") pure
                let packageRoot = root </> "core" </> "hostbootstrap-core"
                    sourceRoot = packageRoot </> "src"
                    expected =
                        [ ("HostBootstrap.Authority", "src/HostBootstrap/Authority.hs")
                        , ("HostBootstrap.Authority.ProjectPlan", "src/HostBootstrap/Authority/ProjectPlan.hs")
                        , ("HostBootstrap.Authority.Testing", "internal/authority/HostBootstrap/Authority/Testing.hs")
                        , ("HostBootstrap.Command.LifecycleEntry", "src/HostBootstrap/Command/LifecycleEntry.hs")
                        , ("HostBootstrap.Handoff", "src/HostBootstrap/Handoff.hs")
                        , ("HostBootstrap.Handoff.Runtime", "src/HostBootstrap/Handoff/Runtime.hs")
                        , ("HostBootstrap.Lifecycle.Mode", "src/HostBootstrap/Lifecycle/Mode.hs")
                        , ("HostBootstrap.Lifecycle.RootedPlan", "src/HostBootstrap/Lifecycle/RootedPlan.hs")
                        , ("HostBootstrap.Lifecycle.Session", "src/HostBootstrap/Lifecycle/Session.hs")
                        , ("HostBootstrap.ProjectPlan.Snapshot", "src/HostBootstrap/ProjectPlan/Snapshot.hs")
                        , ("HostBootstrap.Teardown.Internal", "src/HostBootstrap/Teardown/Internal.hs")
                        ]
                description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                kernelPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Authority.Kernel"
                sources <- SourceGuard.readLibrarySources packageRoot description
                let importers =
                        [ (name, SourceGuard.repoRelativePath packageRoot path)
                        | (name, path, source) <- sources
                        , "HostBootstrap.Authority.Kernel" `elem` SourceGuard.haskellImports source
                        ]
                    childReservationCallers =
                        [ (name, SourceGuard.repoRelativePath packageRoot path)
                        | (name, path, source) <- sources
                        , SourceGuard.countHaskellIdentifier "childCommandReservationKernel" source > 0
                        ]
                sort importers @?= expected
                sort childReservationCallers @?= []
                closureKernel <- readFile kernelPath
                closure <- readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Closure.hs")
                mapM_
                    ( \name -> do
                        SourceGuard.countHaskellIdentifier name ("value = " <> name) @?= 1
                        SourceGuard.countHaskellIdentifier name (closureKernel <> closure) @?= 0
                    )
                    ["ProductionCloseRoot", "destroyCloseRoot", "preEffectCloseRoot", "productionCloseRootVerb"]
                facade <- TextIO.readFile (sourceRoot </> "HostBootstrap" </> "Authority.hs")
                authorityFacadeExports facade
                    @?= Right
                        [ "VerbUp"
                        , "VerbDown"
                        , "VerbDestroy"
                        , "ProjectVerb (..)"
                        , "projectVerbName"
                        , "SomeProjectVerb (..)"
                        , "parseProjectVerb"
                        , "PreparePhase"
                        , "ExecutePhase"
                        , "TeardownPhase"
                        , "LifecyclePhase (..)"
                        , "lifecyclePhaseName"
                        , "InstalledProjectIdentity"
                        , "withInstalledProjectIdentity"
                        , "normalizeExecutableIdentity"
                        , "installedProjectName"
                        , "VerifiedOsPrincipal"
                        , "verifyOsPrincipal"
                        , "BrokerEpoch"
                        , "brokerEpochWord"
                        , "RootInvocationAuthority"
                        , "RootScopeAuthority"
                        , "rootScopeAuthority"
                        , "rootAuthorityVerb"
                        , "rootAuthorityEpoch"
                        , "rootAuthorityProjectName"
                        , "CommandAuthority"
                        , "commandAuthorityVerb"
                        , "commandAuthorityPhase"
                        , "commandAuthorityFrame"
                        , "commandAuthorityEpoch"
                        , "commandAuthorityInvocation"
                        , "commandAuthorityMatchesStore"
                        , "InvocationId"
                        , "invocationIdText"
                        , "AuthorityError (..)"
                        , "authorityErrorMessage"
                        ]
                compatibilityExists <-
                    doesFileExist
                        (sourceRoot </> "HostBootstrap" </> "Config" </> "InstalledProject.hs")
                assertBool "the configuration compatibility module is absent" (not compatibilityExists)
                cabal <- TextIO.readFile (root </> "core" </> "hostbootstrap-core" </> "hostbootstrap-core.cabal")
                assertBool "the configuration compatibility module is not exposed" $
                    not ("HostBootstrap.Config.InstalledProject" `Text.isInfixOf` cabal)
                kernel <- TextIO.readFile kernelPath
                assertBool "the kernel has no caller-fixed installed-identity escape" $
                    not ("installedProjectForKernel" `Text.isInfixOf` kernel)
                dependencies <- either assertFailure pure $
                    SourceGuard.transitiveHostBootstrapImports
                        [(name, SourceGuard.repoRelativePath packageRoot path, body) | (name, path, body) <- sources]
                        "HostBootstrap.Authority.Kernel"
                filter (\(name, _) -> Text.isPrefixOf "HostBootstrap.Config" (Text.pack name)) dependencies @?= []
                filter (\(name, _) -> Text.isPrefixOf "HostBootstrap.Reconcile" (Text.pack name)) dependencies @?= []
                projectPlanAuthority <-
                    TextIO.readFile
                        (sourceRoot </> "HostBootstrap" </> "Authority" </> "ProjectPlan.hs")
                assertBool "the caller-selected lifecycle-plan authority gate is absent" $
                    not ("authorizeProjectCommand" `Text.isInfixOf` projectPlanAuthority)
                assertBool "the Production compatibility authority gate is absent" $
                    not ("authorizeProductionProjectCommand" `Text.isInfixOf` projectPlanAuthority)
           , testCase "a store already bound to another project refuses this one" $
                withStore $ \store -> do
                    key <- expectKey "authority.binding"
                    seeded <-
                        withProtectedEntry store $ \session ->
                            compareAndSwapProtectedRecord
                                session
                                key
                                ExpectAbsent
                                (TextEncoding.encodeUtf8 "other-project")
                    assertBool "the foreign project binding was seeded" (isRight seeded)
                    Fixture.withFixtureInstalledProject $ \project -> do
                        outcome <- withProductionRoot store project ProjectUp (\_ -> pure (Right ()))
                        case outcome of
                            Left (ModeAuthorityFailure (AuthorityStoreNotOurs expected observed)) -> do
                                expected @?= installedProjectName project
                                observed @?= "other-project"
                            other -> assertFailure ("expected a store-binding refusal, got " <> show other)
           , testCase "a malformed authority binding refuses root admission" $
                withStore $ \store -> do
                    key <- expectKey "authority.binding"
                    seeded <-
                        withProtectedEntry store $ \session ->
                            compareAndSwapProtectedRecord
                                session
                                key
                                ExpectAbsent
                                (ByteString.pack [0xff])
                    assertBool "the malformed authority binding was seeded" (isRight seeded)
                    outcome <-
                        Fixture.withFixtureInstalledProject $ \project ->
                            withProductionRoot store project ProjectUp (\_ -> pure (Right ()))
                    case outcome of
                        Left (ModeAuthorityFailure AuthorityMalformedBinding{}) -> pure ()
                        other -> assertFailure ("expected a malformed-binding refusal, got " <> show other)
           , testCase "the verb vocabulary is closed" $ do
                case parseProjectVerb "up" of
                    Right (SomeProjectVerb verb) -> projectVerbName verb @?= "up"
                    other -> assertFailure ("expected the up verb, got " <> show other)
                case parseProjectVerb "down" of
                    Right (SomeProjectVerb verb) -> projectVerbName verb @?= "down"
                    other -> assertFailure ("expected the down verb, got " <> show other)
                case parseProjectVerb "destroy" of
                    Right (SomeProjectVerb verb) -> projectVerbName verb @?= "destroy"
                    other -> assertFailure ("expected the destroy verb, got " <> show other)
                case parseProjectVerb "deploy" of
                    Left (AuthorityUnknownVerb raw) -> raw @?= "deploy"
                    other -> assertFailure ("expected an unknown verb, got " <> show other)
           , testCase "pre-effect closure rechecks acquisition after authorization" $
                withStore $ \store ->
                    Fixture.withFixtureInstalledProject $ \project -> do
                        outcome <- withProductionRoot store project ProjectUp $ \root -> do
                            authorization <- authorizeProductionPreEffect root >>= either (assertFailure . show) pure
                            withProtectedEntry' store $ \session -> do
                                key <- either (assertFailure . show) pure (mkRecordKey ("acquisition." <> installedProjectName project <> recordTupleSeparator <> "production" <> recordTupleSeparator <> "late"))
                                _ <- compareAndSwapProtectedRecord session key ExpectAbsent "acquisition began"
                                result <- releaseProductionMode session project authorization
                                case result of
                                    Left (ModeEffectsRecorded _) -> pure ()
                                    other -> assertFailure ("expected late acquisition refusal, got " <> show other)
                                modeKey <- either (assertFailure . show) pure (mkRecordKey ("mode." <> installedProjectName project))
                                mode <- readProtectedRecord session modeKey
                                case mode of
                                    Right (Just _) -> pure ()
                                    other -> assertFailure ("Production must remain held, got " <> show other)
                                pure (Right ())
                        outcome @?= Right ()
           ]

-- Project mode and run leases ---------------------------------------------------------

encodedInstalledIdentityCase :: TestTree
encodedInstalledIdentityCase = testCase "actual case and underscore executable identities retain exact broker and mode records" $
    withSystemTempDirectory "hostbootstrap-encoded-project" $ \directory -> do
        executable <- getExecutablePath
        names <- traverse
            ( \(ordinal, identity) -> do
                let parent = directory </> show ordinal
                    copied = parent </> Text.unpack identity <> takeExtension executable
                    storeRoot = parent </> "authority"
                    reason = parent </> "reason"
                createDirectoryIfMissing True parent
                copyFile executable copied
                mapM_
                    ( \_ -> do
                        (code, output, errors) <- readProcessWithExitCode copied ["--hostbootstrap-mode-profile-probe", storeRoot, "production", reason] ""
                        code @?= ExitSuccess
                        output @?= ""
                        errors @?= ""
                    )
                    [1 :: Int, 2]
                store <- expectRight =<< openProtectedStore storeRoot
                encoded <- expectRight (mkRecordName identity)
                image <- protectedStoreImage store
                if Text.length identity == 64 then do
                    (code, output, errors) <- readProcessWithExitCode copied ["--hostbootstrap-mode-profile-probe", storeRoot, "oversized-snapshot", reason] ""
                    (code, output, errors) @?= (ExitSuccess, "", "")
                    protectedStoreImage store >>= (@?= image)
                else pure ()
                let broker = "broker." <> encoded <> ".generation"
                    mode = "mode." <> encoded
                    lease = "lease." <> encoded <> recordTupleSeparator <> "production"
                    profile = "profile." <> encoded <> recordTupleSeparator <> "production"
                -- Each root admission initializes the available profile slot for
                -- the exact epoch and lease version, even before profile consumption.
                map (\(key, _, _) -> key) image @?= sort ["authority.binding", broker, mode, lease, profile]
                lookup "authority.binding" [(key, bytes) | (key, _, bytes) <- image] @?= Just (TextEncoding.encodeUtf8 identity)
                lookup broker [(key, bytes) | (key, _, bytes) <- image] @?= Just "2"
                lookup mode [(key, bytes) | (key, _, bytes) <- image] @?= Just "production\t2"
                lookup profile [(key, bytes) | (key, _, bytes) <- image] @?= Just "available\t2\t2"
                pure encoded
            )
            (zip [0 :: Int ..] ["Build_A", "build_a", "BuildA", "builda", Text.replicate 64 "A"])
        Map.size (Map.fromList [(Text.toLower name, ()) | name <- names]) @?= length names

asciiRunRecoveryCase :: TestTree
asciiRunRecoveryCase = testCase "durable ASCII runs recover their exact decoded case" $
    withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
        encodedProject <- expectRight (mkRecordName (installedProjectName project))
        encodedRun <- expectRight (mkRecordName "Run-A")
        leaseKey <- expectKey ("lease." <> encodedProject <> recordTupleSeparator <> encodedRun)
        modeKey <- expectKey ("mode." <> encodedProject)
        _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session leaseKey ExpectAbsent "unbound\t1")
        _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session modeKey ExpectAbsent "harness\t1\tRun-A")
        seen <- newIORef []
        recovered <- recoverAbandonedHarnessRuns store project
            (\lease -> writeIORef seen [incompleteRunLeaseRunText lease] >> pure (Right ()))
            neverResolves
        closedAbandonedHarnessRunsCount <$> recovered @?= Right 1
        readIORef seen >>= (@?= ["Run-A"])
        observed <- expectRight =<< readModeRecord store leaseKey
        fmap protectedRecordBytes observed @?= Just "closed\t1"
        readModeRecord store modeKey >>= (@?= Right Nothing)

noncanonicalRunRecoveryCase :: TestTree
noncanonicalRunRecoveryCase = testCase "even a closed lease refuses a noncanonical encoded run suffix" $
    withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
        encoded <- expectRight (mkRecordName (installedProjectName project))
        key <- expectKey ("lease." <> encoded <> recordTupleSeparator <> "_")
        _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent "closed\t1")
        before <- protectedStoreImage store
        recovered <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
        case recovered of
            Left failure -> failure @?= ModeMalformedRecord (recordKeyText key)
            Right _ -> assertFailure "a noncanonical closed run was silently ignored"
        protectedStoreImage store >>= (@?= before)

malformedUnicodeRunCase :: TestTree
malformedUnicodeRunCase = testCase "a durable non-ASCII run refuses before key construction and body entry" $
    withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
        encodedProject <- expectRight (mkRecordName (installedProjectName project))
        key <- expectKey ("mode." <> encodedProject)
        _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent (ByteStringChar8.pack "harness\t1\t\233"))
        before <- readModeRecord store key
        entered <- newIORef False
        refused <- withProductionRoot store project ProjectUp (\_ -> writeIORef entered True >> pure (Right ()))
        refused @?= Left (ModeMalformedRecord (recordKeyText key))
        readIORef entered >>= (@?= False)
        readModeRecord store key >>= (@?= before)
        beforeImage <- protectedStoreImage store
        inspected <- withProtectedEntry' store (\session -> inspectPlanSnapshot session project "é")
        case inspected of
            Left (ModeInvalidIdentity _) -> pure ()
            other -> assertFailure ("expected typed non-ASCII run refusal, got " <> show other)
        protectedStoreImage store >>= (@?= beforeImage)

malformedModeRecordCase :: String -> ByteString.ByteString -> TestTree
malformedModeRecordCase name payload = testCase name $
    withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
        -- Obtain genuine sweep evidence before introducing the malformed mode.
        swept <- expectRight =<< recoverAbandonedHarnessRuns store project neverResolves neverResolves
        encodedProject <- expectRight (mkRecordName (installedProjectName project))
        key <- expectKey ("mode." <> encodedProject)
        _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent payload)
        observed <- expectRight =<< readModeRecord store key
        before <- maybe (assertFailure "the malformed mode fixture was not recorded") pure observed
        protectedRecordBytes before @?= payload
        callbacks <- newIORef (0 :: Int)
        let enter _ = do
                atomicModifyIORef' callbacks (\count -> (count + 1, ()))
                pure (Right ())
            assertRefused result = do
                result @?= Left (ModeMalformedRecord (recordKeyText key))
                readIORef callbacks >>= (@?= 0)
                afterObserved <- expectRight =<< readModeRecord store key
                after <- maybe (assertFailure "the refused root removed the malformed mode") pure afterObserved
                protectedRecordBytes after @?= protectedRecordBytes before
                protectedRecordVersion after @?= protectedRecordVersion before
        production <- withProductionRoot store project ProjectUp enter
        assertRefused production
        harness <- withHarnessRoot store project ProjectUp (satisfiedPreconditions project) swept enter
        assertRefused harness

nonAsciiRunIngressCase :: TestTree
nonAsciiRunIngressCase = testCase "snapshot inspection refuses a non-ASCII run at ingress" $
    withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
        before <- protectedStoreImage store
        inspected <- withProtectedEntry' store (\session -> inspectPlanSnapshot session project "ő-run")
        case inspected of
            Left failure -> failure @?= ModeInvalidIdentity "a run id may contain only ASCII alphanumerics and '-': ő-run"
            Right observed -> assertFailure ("a non-ASCII run reached snapshot inspection: " <> show observed)
        protectedStoreImage store >>= (@?= before)

nonAsciiCloseKeyIngressCase :: TestTree
nonAsciiCloseKeyIngressCase = testCase "invocation close keys refuse a non-ASCII character at ingress" $ do
    mkInvocationCloseKey "ő-close"
        @?= Left (ModeInvalidIdentity "an invocation close key may contain only alphanumerics, '-' and '.': ő-close")
    invocationCloseKeyText <$> mkInvocationCloseKey "A1-close.key" @?= Right "A1-close.key"

noncanonicalModeNumberCases :: TestTree
noncanonicalModeNumberCases =
    testGroup "noncanonical mode numbers refuse both public roots"
        [ malformedModeRecordCase label ("production\t" <> raw)
        | (label, raw) <-
            [ ("a negative epoch", "-1")
            , ("an explicit positive sign", "+1")
            , ("an epoch exceeding Word64", "18446744073709551617")
            , ("an epoch exceeding twenty digits", "100000000000000000000")
            , ("a parenthesized epoch", "(1)")
            , ("a hexadecimal epoch", "0x1")
            , ("an epoch with a leading zero", "01")
            , ("leading epoch whitespace", " 1")
            , ("trailing epoch whitespace", "1 ")
            , ("a trailing epoch newline", "1\n")
            ]
        ]

canonicalModeNumberCase :: TestTree
canonicalModeNumberCase = testCase "canonical mode epochs include zero and the maximum Word64" $
    forM_ ["0", "18446744073709551615"] $ \raw ->
        withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
            encodedProject <- expectRight (mkRecordName (installedProjectName project))
            key <- expectKey ("mode." <> encodedProject)
            _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent ("production\t" <> raw))
            callbacks <- newIORef (0 :: Int)
            admitted <- withProductionRoot store project ProjectUp $ \_ -> do
                atomicModifyIORef' callbacks (\count -> (count + 1, ()))
                pure (Right ())
            admitted @?= Right ()
            readIORef callbacks >>= (@?= 1)

malformedUnboundLeaseNumberCase :: TestTree
malformedUnboundLeaseNumberCase = testCase "an unbound Production lease refuses a negative epoch without changing its record" $
    withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
        encodedProject <- expectRight (mkRecordName (installedProjectName project))
        key <- expectKey ("lease." <> encodedProject <> recordTupleSeparator <> "production")
        _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent "unbound\t-1")
        observed <- expectRight =<< readModeRecord store key
        before <- maybe (assertFailure "the malformed lease fixture was not recorded") pure observed
        protectedRecordBytes before @?= "unbound\t-1"
        callbacks <- newIORef (0 :: Int)
        refused <- withProductionRoot store project ProjectUp $ \_ -> do
            atomicModifyIORef' callbacks (\count -> (count + 1, ()))
            pure (Right ())
        refused @?= Left (ModeMalformedRecord (recordKeyText key))
        readIORef callbacks >>= (@?= 0)
        afterObserved <- expectRight =<< readModeRecord store key
        after <- maybe (assertFailure "the refused root removed the malformed lease") pure afterObserved
        protectedRecordBytes after @?= protectedRecordBytes before
        protectedRecordVersion after @?= protectedRecordVersion before

durableFieldCodecCase :: TestTree
durableFieldCodecCase = testCase "durable field codecs preserve exact UTF-8 without Char8 conversion or trimming" $
    -- See DEVELOPMENT_PLAN/rationale.md#durable-record-fields-preserve-exact-utf-8.
    -- Writer evidence names its actual UTF-8 primitive, not an unexercised
    -- public Unicode writer. Decoder behavior also has public recovery cases.
    SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
        description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
        path <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Lifecycle.Mode"
        bytes <- ByteString.readFile path
        source <- either (assertFailure . show) (pure . Text.unpack) (TextEncoding.decodeUtf8' bytes)
        encoder <- expectRight (SourceGuard.haskellDefinitionTokens "encodeFields" source)
        decoder <- expectRight (SourceGuard.haskellDefinitionTokens "decodeFields" source)
        exact <- expectRight (SourceGuard.haskellDefinitionTokens "exactFields" source)
        assertBool "the durable field writer uses UTF-8" (SourceGuard.haskellTokens "TextEncoding.encodeUtf8" `isInfixOf` encoder)
        assertBool "the durable field reader decodes UTF-8 strictly" (any (SourceGuard.haskellTokens "TextEncoding.decodeUtf8'" `isInfixOf`) [decoder, exact])
        forM_
            [ "ByteStringChar8.pack", "ByteStringChar8.unpack"
            , "Data.ByteString.Char8.pack", "Data.ByteString.Char8.unpack"
            , "Text.strip", "Data.Text.strip"
            ]
            ( \forbidden ->
                assertBool
                    ("the private durable field codecs contain " <> forbidden)
                    (all (\definition -> not (SourceGuard.haskellTokens forbidden `isInfixOf` definition)) [encoder, decoder, exact])
            )

legacySnapshotRecordCase :: String -> ByteString.ByteString -> TestTree
legacySnapshotRecordCase label payload = testCase label $
    withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
        outcome <- withProductionRoot store project ProjectUp $ \root -> do
            let unbound = productionRootUnboundLease root
                run = unboundRunLeaseRunText unbound
            encodedProject <- expectRight (mkRecordName (installedProjectName project))
            encodedRun <- expectRight (mkRecordName run)
            key <- expectKey ("snapshot." <> encodedProject <> recordTupleSeparator <> encodedRun)
            _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent payload)
            observed <- expectRight =<< readModeRecord store key
            record <- maybe (assertFailure "the legacy snapshot fixture was not recorded") pure observed
            protectedRecordBytes record @?= payload
            before <- protectedStoreImage store
            inspected <- withProtectedEntry' store (\session -> inspectPlanSnapshot session project run)
            inspected @?= Left (ModeMalformedRecord (recordKeyText key))
            protectedStoreImage store >>= (@?= before)
            callbacks <- newIORef (0 :: Int)
            verified <- verifyPlanSnapshot unbound $ \_ -> do
                atomicModifyIORef' callbacks (\count -> (count + 1, ()))
                pure (Right ())
            verified @?= Left (ModeMalformedRecord (recordKeyText key))
            readIORef callbacks >>= (@?= 0)
            protectedStoreImage store >>= (@?= before)
            pure (Right ())
        outcome @?= Right ()

absentCanonicalMaterialCase :: TestTree
absentCanonicalMaterialCase = testCase "a framed snapshot without canonical material remains generically readable" $
    withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
        outcome <- withProductionRoot store project ProjectUp $ \root -> do
            let unbound = productionRootUnboundLease root
                run = unboundRunLeaseRunText unbound
                field bytes = Builder.word64BE (fromIntegral (ByteString.length bytes)) <> Builder.byteString bytes
                payload = LazyByteString.toStrict . Builder.toLazyByteString $
                    Builder.byteString "HOSTBOOTSTRAP-SNAPSHOT"
                        <> Builder.word64BE 1
                        <> Builder.word64BE 1
                        <> field "compat-spec"
                        <> field "compat-plan"
                        <> Builder.word8 0
            encodedProject <- expectRight (mkRecordName (installedProjectName project))
            encodedRun <- expectRight (mkRecordName run)
            key <- expectKey ("snapshot." <> encodedProject <> recordTupleSeparator <> encodedRun)
            _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent payload)
            observed <- expectRight =<< readModeRecord store key
            record <- maybe (assertFailure "the tag-zero snapshot fixture was not recorded") pure observed
            protectedRecordBytes record @?= payload
            before <- protectedStoreImage store
            inspected <- expectRight =<< withProtectedEntry' store (\session -> inspectPlanSnapshot session project run)
            planSnapshotViewRevision inspected @?= 1
            planSnapshotViewSpecDigest inspected @?= "compat-spec"
            planSnapshotViewPlanDigest inspected @?= "compat-plan"
            planSnapshotViewConfigDigest inspected @?= Nothing
            planSnapshotViewCanonicalBytes inspected @?= Nothing
            protectedStoreImage store >>= (@?= before)
            callbacks <- newIORef (0 :: Int)
            verified <- verifyPlanSnapshot unbound $ \snapshot -> do
                atomicModifyIORef' callbacks (\count -> (count + 1, ()))
                pure (Right (planSnapshotRevision snapshot, planSnapshotSpecDigest snapshot, planSnapshotPlanDigest snapshot, planSnapshotConfigDigest snapshot, planSnapshotCanonicalBytes snapshot))
            verified @?= Right (1, "compat-spec", "compat-plan", Nothing, Nothing)
            readIORef callbacks >>= (@?= 1)
            readModeRecord store key >>= (@?= Right (Just record))
            protectedStoreImage store >>= (@?= before)
            pure (Right ())
        outcome @?= Right ()

canonicalSnapshotBoundaryCase :: TestTree
canonicalSnapshotBoundaryCase = testCase "the library has one canonical snapshot writer and no alternate snapshot decoder" $
    -- See DEVELOPMENT_PLAN/rationale.md#snapshot-writers-consume-canonical-plans.
    -- A removed definition is held across every library unit, rather than by
    -- importing a name that no longer exists as a constructor-boundary fixture.
    SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
        description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
        sources <- SourceGuard.readLibrarySources packageRoot description
        forM_ sources $ \(name, _, source) -> do
            definitions <- expectRight (SourceGuard.haskellDefinitionNames source)
            -- Implicit exports expose only declarations, already checked here.
            let exports = maybe [] id (SourceGuard.moduleExportTokens name source)
            forM_ ["persistPlanSnapshot", "decodeLegacySnapshotRecord"] $ \removed -> do
                assertBool (name <> " defines " <> removed) (removed `notElem` definitions)
                assertBool (name <> " exports " <> removed) (removed `notElem` exports)

productionLeaseStateRefusalCase :: String -> ProjectVerb verb -> ByteString.ByteString -> Text -> TestTree
productionLeaseStateRefusalCase label verb payload state = testCase label $
    withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
        -- These valid wire inputs exercise classification, not the execution of
        -- a migration or a closing transition.
        encodedProject <- expectRight (mkRecordName (installedProjectName project))
        key <- expectKey ("lease." <> encodedProject <> recordTupleSeparator <> "production")
        _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent payload)
        before <- protectedStoreImage store
        entries <- newIORef (0 :: Int)
        refused <- withProductionRoot store project verb $ \_ -> do
            atomicModifyIORef' entries (\count -> (count + 1, ()))
            pure (Right ())
        refused @?= Left (ModeLeaseNotBindable "production" state)
        readIORef entries >>= (@?= 0)
        protectedStoreImage store >>= (@?= before)

closeProductionPreEffect :: ProtectedStore -> InstalledProjectIdentity projectId -> IO Word64
closeProductionPreEffect store project = do
    closed <- withProductionRoot store project ProjectUp $ \root -> do
        authorization <- expectRight =<< authorizeProductionPreEffect root
        released <- withProtectedEntry' store (\session -> releaseProductionMode session project authorization)
        released @?= Right ()
        pure (Right (brokerEpochWord (projectModeLeaseEpoch (productionRootModeLease root))))
    expectRight closed

closedProductionUpCase :: TestTree
closedProductionUpCase = testCase "a genuinely closed Production run can rearm through Up" $
    withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
        oldEpoch <- closeProductionPreEffect store project
        encodedProject <- expectRight (mkRecordName (installedProjectName project))
        leaseKey <- expectKey ("lease." <> encodedProject <> recordTupleSeparator <> "production")
        modeKey <- expectKey ("mode." <> encodedProject)
        profileKey <- expectKey ("profile." <> encodedProject <> recordTupleSeparator <> "production")
        beforeObserved <- expectRight =<< readModeRecord store leaseKey
        before <- maybe (assertFailure "the closed Production lease is missing") pure beforeObserved
        protectedRecordBytes before @?= "closed\t" <> ByteStringChar8.pack (show oldEpoch)
        readModeRecord store modeKey >>= (@?= Right Nothing)
        entries <- newIORef (0 :: Int)
        rearmed <- withProductionRoot store project ProjectUp $ \root -> do
            atomicModifyIORef' entries (\count -> (count + 1, ()))
            projectModeLeaseName (productionRootModeLease root) @?= "production"
            unboundRunLeaseRunText (productionRootUnboundLease root) @?= "production"
            pure (Right (brokerEpochWord (projectModeLeaseEpoch (productionRootModeLease root))))
        newEpoch <- expectRight rearmed
        readIORef entries >>= (@?= 1)
        assertBool "rearming did not allocate a fresh epoch" (newEpoch > oldEpoch)
        afterObserved <- expectRight =<< readModeRecord store leaseKey
        after <- maybe (assertFailure "the rearmed Production lease is missing") pure afterObserved
        protectedRecordBytes after @?= "unbound\t" <> ByteStringChar8.pack (show newEpoch)
        modeObserved <- expectRight =<< readModeRecord store modeKey
        mode <- maybe (assertFailure "the rearmed Production mode is missing") pure modeObserved
        protectedRecordBytes mode @?= "production\t" <> ByteStringChar8.pack (show newEpoch)
        profileObserved <- expectRight =<< readModeRecord store profileKey
        profile <- maybe (assertFailure "the rearmed Production profile is missing") pure profileObserved
        protectedRecordBytes profile
            @?= "available\t" <> ByteStringChar8.pack (show newEpoch)
                <> "\t" <> ByteStringChar8.pack (show (recordVersionWord (protectedRecordVersion after)))

harnessBeforeClosedProductionCase :: TestTree
harnessBeforeClosedProductionCase = testCase "a live Harness takes priority over the older closed Production lease" $
    withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
        oldEpoch <- closeProductionPreEffect store project
        encodedProject <- expectRight (mkRecordName (installedProjectName project))
        key <- expectKey ("lease." <> encodedProject <> recordTupleSeparator <> "production")
        outcome <- withFreshHarnessRoot store project $ \root -> do
            observed <- expectRight =<< readModeRecord store key
            record <- maybe (assertFailure "the older closed Production lease is missing") pure observed
            protectedRecordBytes record @?= "closed\t" <> ByteStringChar8.pack (show oldEpoch)
            entries <- newIORef (0 :: Int)
            let assertModePriority :: forall verb. ProjectVerb verb -> IO ()
                assertModePriority verb = do
                    before <- protectedStoreImage store
                    refused <- withProductionRoot store project verb $ \_ -> do
                        atomicModifyIORef' entries (\count -> (count + 1, ()))
                        pure (Right ())
                    refused @?= Left (ModeHeldByAnother ("harness:" <> runIdText (harnessRootRunId root)) "production")
                    readIORef entries >>= (@?= 0)
                    protectedStoreImage store >>= (@?= before)
            assertModePriority ProjectDown
            assertModePriority ProjectDestroy
            pure (Right ())
        outcome @?= Right ()

data ProfileLeaseMutation = BindProfileLease | CloseProfileLease | ReversionProfileLease

profileLeaseRefusalCases :: [TestTree]
profileLeaseRefusalCases = concat
    [ [ productionCase label mutation diagnostic, harnessCase label mutation diagnostic ]
    | (label, mutation, diagnostic) <-
        [ ("a genuinely bound lease", BindProfileLease, "the lifecycle profile lease is bound, not unbound")
        , ("a closed lease", CloseProfileLease, "the lifecycle profile lease is closed, not unbound")
        , ("a re-versioned unbound lease", ReversionProfileLease, "the lifecycle profile lease record version does not match the unbound lease")
        ]
    ]
  where
    productionCase label mutation diagnostic = testCase ("a Production profile refuses " <> label <> " without consuming its slot") $
        withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
            outcome <- withProductionRoot store project ProjectUp $ \root -> do
                let mode = productionRootModeLease root
                    unbound = productionRootUnboundLease root
                assertProfileLeaseRefusal store (installedProjectName project) (brokerEpochWord (projectModeLeaseEpoch mode)) unbound mutation diagnostic $
                    \action -> withProductionLifecycleProfile (rootScopeAuthority (productionRootAuthority root)) (productionActiveMode mode) unbound (const action)
                pure (Right ())
            outcome @?= Right ()
    harnessCase label mutation diagnostic = testCase ("a Harness profile refuses " <> label <> " without consuming its slot") $
        withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
            outcome <- withFreshHarnessRoot store project $ \root -> do
                let mode = harnessRootModeLease root
                    unbound = harnessRootUnboundLease root
                assertProfileLeaseRefusal store (installedProjectName project) (brokerEpochWord (projectModeLeaseEpoch mode)) unbound mutation diagnostic $
                    \action -> withHarnessLifecycleProfile (rootScopeAuthority (harnessRootAuthority root)) (harnessRootHarnessAuthority root) (harnessRootRunId root) (harnessActiveMode mode) unbound (const action)
                pure (Right ())
            outcome @?= Right ()

assertProfileLeaseRefusal ::
    ProtectedStore -> Text -> Word64 -> UnboundRunLease scope brokerGeneration ->
    ProfileLeaseMutation -> Text ->
    (IO () -> IO (Either AuthorityError (IO ()))) -> IO ()
assertProfileLeaseRefusal store project epoch unbound mutation diagnostic open = do
    encodedProject <- expectRight (mkRecordName project)
    encodedRun <- expectRight (mkRecordName (unboundRunLeaseRunText unbound))
    leaseKey <- expectKey ("lease." <> encodedProject <> recordTupleSeparator <> encodedRun)
    slotKey <- expectKey ("profile." <> encodedProject <> recordTupleSeparator <> encodedRun)
    lease <- profileFixtureRecord store leaseKey
    slot <- profileFixtureRecord store slotKey
    let fields = TextEncoding.encodeUtf8 . Text.intercalate "\t"
        epochText = Text.pack (show epoch)
        leaseVersion = protectedRecordVersion lease
        available = fields ["available", epochText, Text.pack (show (recordVersionWord leaseVersion))]
    protectedRecordBytes lease @?= fields ["unbound", epochText]
    protectedRecordBytes slot @?= available
    case mutation of
        BindProfileLease -> do
            _ <- expectRight =<< persistCanonicalPlanSnapshot unbound 1 modeTestSnapshot
            bound <- verifyPlanSnapshot unbound $ \snapshot -> do
                _ <- expectRight =<< bindRunLease unbound snapshot (\_ -> pure ())
                pure (Right ())
            bound @?= Right ()
        CloseProfileLease -> do
            _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session leaseKey (ExpectVersion leaseVersion) (fields ["closed", epochText]))
            pure ()
        ReversionProfileLease -> do
            _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session leaseKey (ExpectVersion leaseVersion) (protectedRecordBytes lease))
            pure ()
    changed <- profileFixtureRecord store leaseKey
    assertBool "the lease mutation did not advance its record version" (recordVersionWord (protectedRecordVersion changed) > recordVersionWord leaseVersion)
    protectedRecordBytes changed @?= case mutation of
        BindProfileLease -> fields ["bound", epochText, canonicalPlanSnapshotSpecDigest modeTestSnapshot, closePlanDigest]
        CloseProfileLease -> fields ["closed", epochText]
        ReversionProfileLease -> protectedRecordBytes lease
    profileFixtureRecord store slotKey >>= (@?= slot)
    before <- protectedStoreImage store
    entries <- newIORef (0 :: Int)
    opened <- open (atomicModifyIORef' entries (\count -> (count + 1, ())))
    -- A public profile callback is pure and may return IO. Execute any Right
    -- action so a mistaken admission cannot pass a zero-callback assertion.
    executed <- traverse id opened
    executed @?= Left (AuthorityMalformedBinding diagnostic)
    readIORef entries >>= (@?= 0)
    after <- profileFixtureRecord store slotKey
    protectedRecordBytes after @?= available
    protectedRecordVersion after @?= protectedRecordVersion slot
    protectedStoreImage store >>= (@?= before)

profileFixtureRecord :: ProtectedStore -> RecordKey -> IO ProtectedRecord
profileFixtureRecord store key = do
    observed <- expectRight =<< readModeRecord store key
    maybe (assertFailure ("missing profile fixture record: " <> Text.unpack (recordKeyText key))) pure observed

pendingDestroyProfileCase :: TestTree
pendingDestroyProfileCase = testCase "a recognized Pending Destroy intent refuses a profile while its matching Terminal permits one" $
    withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
        outcome <- withProductionRoot store project ProjectUp $ \root -> do
            let mode = productionRootModeLease root
                unbound = productionRootUnboundLease root
                epoch = brokerEpochWord (projectModeLeaseEpoch mode)
                text = TextEncoding.encodeUtf8
                word :: Word64 -> ByteString.ByteString
                word = text . Text.pack . show
                fields = text . Text.intercalate "\t"
                open consume = withProductionLifecycleProfile (rootScopeAuthority (productionRootAuthority root)) (productionActiveMode mode) unbound consume
            encodedProject <- expectRight (mkRecordName (installedProjectName project))
            modeKey <- expectKey ("mode." <> encodedProject)
            leaseKey <- expectKey ("lease." <> encodedProject <> recordTupleSeparator <> "production")
            slotKey <- expectKey ("profile." <> encodedProject <> recordTupleSeparator <> "production")
            intentKey <- expectKey ("reverse-root." <> encodedProject <> ".production")
            acquisitionKey <- expectKey "fixture.profile-acquisition"
            cursorKey <- expectKey "fixture.profile-cursor"
            -- These two ordinary records supply live key/version/byte inputs.
            -- They are not acquisition/cursor authority or a reverse lifecycle.
            _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session acquisitionKey ExpectAbsent "ordinary acquisition fixture")
            _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session cursorKey ExpectAbsent "ordinary cursor fixture")
            acquisition <- profileFixtureRecord store acquisitionKey
            cursor <- profileFixtureRecord store cursorKey
            modeRecord <- profileFixtureRecord store modeKey
            lease <- profileFixtureRecord store leaseKey
            slot <- profileFixtureRecord store slotKey
            let leaseVersion = recordVersionWord (protectedRecordVersion lease)
                available = fields ["available", Text.pack (show epoch), Text.pack (show leaseVersion)]
                common =
                    [ text (installedProjectName project)
                    , text (protectedStoreIdentityText (protectedStoreIdentity store))
                    , "production"
                    , word 1
                    , text (canonicalPlanSnapshotSpecDigest modeTestSnapshot)
                    , text (canonicalPlanSnapshotConfigDigest modeTestSnapshot)
                    , text closePlanDigest
                    , canonicalPlanSnapshotBytes modeTestSnapshot
                    , word epoch
                    , text (recordKeyText acquisitionKey)
                    , word (recordVersionWord (protectedRecordVersion acquisition))
                    , protectedRecordBytes acquisition
                    , text (recordKeyText cursorKey)
                    , word (recordVersionWord (protectedRecordVersion cursor))
                    , protectedRecordBytes cursor
                    , "host"
                    , word 0
                    , word (recordVersionWord (protectedRecordVersion modeRecord))
                    , protectedRecordBytes modeRecord
                    , word leaseVersion
                    , protectedRecordBytes lease
                    ]
                target = epoch + 1
                pendingFields = ["pending", "destroy"] <> common
                terminalFields = ["terminal", "destroy"] <> common <>
                    [ word target
                    , word (recordVersionWord (protectedRecordVersion modeRecord) + 1)
                    , fields ["production", Text.pack (show target)]
                    , word (leaseVersion + 1)
                    , fields ["bound", Text.pack (show target), canonicalPlanSnapshotSpecDigest modeTestSnapshot, closePlanDigest]
                    ]
            unboundRunLeaseRunText unbound @?= "production"
            protectedRecordBytes slot @?= available
            length pendingFields @?= 23
            length terminalFields @?= 28
            pendingVersion <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session intentKey ExpectAbsent (profileIntentFrame pendingFields))
            beforePending <- protectedStoreImage store
            entries <- newIORef (0 :: Int)
            pending <- open (const (atomicModifyIORef' entries (\count -> (count + 1, ()))))
            executed <- traverse id pending
            let reason = "ordinary lifecycle admission is unavailable: " <> modeErrorMessage ModeReverseRootInProgress
            executed @?= Left (AuthorityMalformedBinding reason)
            assertBool "the refusal lost the reverse-root cause" ("a durable reverse-root intent owns ordinary lifecycle admission" `Text.isInfixOf` reason)
            readIORef entries >>= (@?= 0)
            profileFixtureRecord store slotKey >>= (@?= slot)
            protectedStoreImage store >>= (@?= beforePending)
            -- The same common fields must be recognized as Terminal. Without
            -- this control, malformed bytes could satisfy the Pending refusal.
            _ <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session intentKey (ExpectVersion pendingVersion) (profileIntentFrame terminalFields))
            beforeTerminal <- protectedStoreImage store
            terminal <- open $ \profile -> do
                lifecycleProfileName profile @?= "production"
                lifecycleProfileEpoch profile @?= epoch
                atomicModifyIORef' entries (\count -> (count + 1, ()))
            completed <- traverse id terminal
            completed @?= Right ()
            readIORef entries >>= (@?= 1)
            consumed <- profileFixtureRecord store slotKey
            protectedRecordBytes consumed @?= fields ["consumed", Text.pack (show epoch), Text.pack (show leaseVersion)]
            assertBool "the profile slot was not consumed by CAS" (recordVersionWord (protectedRecordVersion consumed) > recordVersionWord (protectedRecordVersion slot))
            afterTerminal <- protectedStoreImage store
            let withoutSlot = filter (\(key, _, _) -> key /= recordKeyText slotKey)
            withoutSlot afterTerminal @?= withoutSlot beforeTerminal
            pure (Right ())
        outcome @?= Right ()

profileIntentFrame :: [ByteString.ByteString] -> ByteString.ByteString
profileIntentFrame values = LazyByteString.toStrict . Builder.toLazyByteString $
    Builder.byteString "HOSTBOOTSTRAP-REVERSE-ROOT"
        <> Builder.word64BE 1
        <> Builder.word64BE (fromIntegral (length values))
        <> foldMap (\bytes -> Builder.word64BE (fromIntegral (ByteString.length bytes)) <> Builder.byteString bytes) values

modeCases :: [TestTree]
modeCases =
    [ encodedInstalledIdentityCase
    , asciiRunRecoveryCase
    , malformedUnicodeRunCase
    , malformedModeRecordCase
        "a malformed mode payload refuses both public roots without changing its record"
        "not-a-mode"
    , malformedModeRecordCase
        "a 49-character harness run refuses both public roots without changing its record"
        ("harness\t1\t" <> ByteStringChar8.replicate 49 'A')
    , nonAsciiRunIngressCase
    , nonAsciiCloseKeyIngressCase
    , noncanonicalModeNumberCases
    , canonicalModeNumberCase
    , malformedUnboundLeaseNumberCase
    , durableFieldCodecCase
    , legacySnapshotRecordCase
        "inspection and verification refuse an ordinary tab-separated snapshot"
        "1\tspec-1\tplan-1"
    , legacySnapshotRecordCase
        "inspection and verification refuse an overflowing tab-separated snapshot revision"
        "18446744073709551617\tspec-1\tplan-1"
    , absentCanonicalMaterialCase
    , canonicalSnapshotBoundaryCase
    , productionLeaseStateRefusalCase
        "a closed Production lease refuses Down without changing any record"
        ProjectDown "closed\t1" "closed"
    , productionLeaseStateRefusalCase
        "a closed Production lease refuses Destroy without changing any record"
        ProjectDestroy "closed\t1" "closed"
    , productionLeaseStateRefusalCase
        "a frozen Production lease refuses fresh Up without changing any record"
        ProjectUp "frozen\t1\tmigration-key\tset-digest\told-spec\told-plan\tnew-spec\tnew-plan" "frozen"
    , productionLeaseStateRefusalCase
        "a migrated Production lease refuses fresh Up without changing any record"
        ProjectUp "migrated\t1\tmigration-key\tset-digest\told-spec\told-plan\tnew-spec\tnew-plan" "migrated-bound"
    , closedProductionUpCase
    , harnessBeforeClosedProductionCase
    , testGroup "lifecycle profiles require their exact live unbound lease" profileLeaseRefusalCases
    , pendingDestroyProfileCase
    , noncanonicalRunRecoveryCase
    , productionCloseRecoveryCase 0
    , productionCloseRecoveryCase 1
    , productionCloseRecoveryCase 2
    , productionCloseRecoveryCase 3
    , testCase "pre-effect Production closure refuses another protected store" $
        withStore $ \firstStore -> withStore $ \secondStore ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <- withProductionRoot firstStore project ProjectUp $ \root -> do
                    authorization <- authorizeProductionPreEffect root >>= either (assertFailure . show) pure
                    withProtectedEntry' secondStore $ \session -> do
                        before <- listProtectedRecords session
                        result <- releaseProductionMode session project authorization
                        case result of
                            Left (ModeEvidenceMismatch _ _ _) -> pure ()
                            other -> assertFailure ("expected store substitution refusal, got " <> show other)
                        after <- listProtectedRecords session
                        after @?= before
                        pure (Right ())
                outcome @?= Right ()
    , testCase "the Production bracket closes a true pre-effect exception" $
        withStore $ \store -> Fixture.withFixtureInstalledProject $ \project -> do
            outcome <- try (withProductionRoot store project ProjectUp (\_ -> throwIO (userError "pre-effect fixture"))) :: IO (Either IOException (Either ModeError ()))
            case outcome of
                Left _ -> pure ()
                Right other -> assertFailure ("expected the original exception, got " <> show other)
            checked <- withProtectedEntry' store $ \session -> do
                key <- either (assertFailure . show) pure (mkRecordKey ("mode." <> installedProjectName project))
                readProtectedRecord session key >>= (@?= Right Nothing)
                pure (Right ())
            checked @?= Right ()
    , testCase "production takes the mode and retains it across a second entry" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                encodedProject <- expectRight (mkRecordName (installedProjectName project))
                key <- expectKey ("mode." <> encodedProject)
                let assertProductionRecord epoch = do
                        observed <- expectRight =<< readModeRecord store key
                        record <- maybe (assertFailure "Production mode was released after root entry") pure observed
                        protectedRecordBytes record @?= "production\t" <> ByteStringChar8.pack (show epoch)
                first <-
                    withProductionRoot store project ProjectUp $ \root -> do
                        let lease = productionRootModeLease root
                        pure (Right (projectModeLeaseName lease, brokerEpochWord (projectModeLeaseEpoch lease)))
                (firstName, firstEpoch) <- expectRight first
                firstName @?= "production"
                assertProductionRecord firstEpoch
                again <-
                    withProductionRoot store project ProjectDown $ \root -> do
                        let lease = productionRootModeLease root
                        pure (Right (projectModeLeaseName lease, brokerEpochWord (projectModeLeaseEpoch lease)))
                (secondName, secondEpoch) <- expectRight again
                secondName @?= "production"
                assertProductionRecord secondEpoch
    , testCase "a mismatched mode cannot reach the harness planner or snapshot write" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                production <-
                    withProductionRoot store project ProjectUp $ \_ -> pure (Right ())
                production @?= Right ()
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left failure -> assertFailure (show failure)
                    Right proof -> do
                        outcome <-
                            withHarnessRoot
                                store
                                project
                                ProjectUp
                                (satisfiedPreconditions project)
                                proof
                                ( \_ ->
                                    assertFailure "the mismatched mode reached the harness planner" ::
                                        IO (Either ModeError ())
                                )
                        case outcome of
                            Left (ModeHeldByAnother held requested) -> do
                                held @?= "production"
                                assertBool
                                    "the requested mode is the harness run"
                                    ("harness:" `isPrefix` requested)
                            other ->
                                assertFailure ("expected a mode conflict, got " <> show other)
                        snapshots <-
                            withProtectedEntry' store $ \session -> do
                                records <- listProtectedRecords session
                                pure $ case records of
                                    Left failure -> Left (ModeStoreFailure failure)
                                    Right keys ->
                                        Right
                                            ( filter
                                                ( ( ( "snapshot."
                                                        <> installedProjectName project
                                                        <> recordTupleSeparator
                                                    )
                                                        `Text.isPrefixOf`
                                                  )
                                                    . recordKeyText
                                                )
                                                keys
                                            )
                        snapshots @?= Right []
    , testCase "the harness bracket refuses when a production config exists" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project ->
                withSystemTempDirectory "hostbootstrap-sibling" $ \siblingDirectory -> do
                    writeFile
                        ( siblingDirectory
                            </> Text.unpack (installedProjectName project) <> ".dhall"
                        )
                        "{=}"
                    swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                    proof <- either (assertFailure . show) pure swept
                    outcome <-
                        withHarnessRoot
                            store
                            project
                            ProjectUp
                            (harnessPreconditions project siblingDirectory (pure False))
                            proof
                            (\_ -> pure (Right ()))
                    case outcome of
                        Left (ModeHarnessRefused (ProductionConfigPresent _)) -> pure ()
                        other -> assertFailure ("expected a safety refusal, got " <> show other)
    , testCase "a lease cannot be bound without a persisted plan snapshot" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        let unbound = productionRootUnboundLease root
                         in do
                                observed <- verifyPlanSnapshot unbound (\_ -> pure (Right ()))
                                case observed of
                                    Left (ModeSnapshotMissing named) -> do
                                        named @?= unboundRunLeaseRunText unbound
                                        pure (Right ())
                                    other ->
                                        assertFailure
                                            ("expected a missing snapshot, got " <> show other)
                outcome @?= Right ()
    , testCase "a fresh binding proves no recovery is owed" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withBoundSnapshot root $ \snapshot -> do
                            planDigest <-
                                expectRight
                                    =<< bindRunLease
                                        (productionRootUnboundLease root)
                                        snapshot
                                        ( \bound -> do
                                            _ <- expectRight (withProjectUpMigrationProfile (productionRootAuthority root) (productionRootModeLease root) bound snapshot)
                                            pure (boundRunLeasePlanDigest bound)
                                        )
                            pure (Right planDigest)
                outcome @?= Right closePlanDigest
    , testCase "a second Production root preserves an existing bound lease and snapshot" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                let runName = "production"
                leaseKey <-
                    expectKey
                        ( "lease."
                            <> installedProjectName project
                            <> recordTupleSeparator
                            <> runName
                        )
                snapshotKey <-
                    expectKey
                        ( "snapshot."
                            <> installedProjectName project
                            <> recordTupleSeparator
                            <> runName
                        )
                bound <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withBoundSnapshot root $ \snapshot -> do
                            _ <-
                                expectRight
                                    =<< bindRunLease
                                        (productionRootUnboundLease root)
                                        snapshot
                                        (\_ -> pure ())
                            pure (Right ())
                bound @?= Right ()
                beforeLeaseObserved <- expectRight =<< readModeRecord store leaseKey
                beforeLease <-
                    maybe (assertFailure "the bound Production lease disappeared") pure beforeLeaseObserved
                beforeSnapshotObserved <- expectRight =<< readModeRecord store snapshotKey
                beforeSnapshot <-
                    maybe (assertFailure "the Production snapshot disappeared") pure beforeSnapshotObserved
                entries <- newIORef (0 :: Int)
                beforeImage <- protectedStoreImage store
                refused <-
                    withProductionRoot store project ProjectUp $ \_ -> do
                        atomicModifyIORef' entries (\count -> (count + 1, ()))
                        pure (Right ())
                afterImage <- protectedStoreImage store
                case refused of
                    Left (ModeLeaseNotBindable run state) -> do
                        run @?= runName
                        state @?= "bound"
                    other ->
                        assertFailure
                            ("expected a bound-lease root refusal, got " <> show other)
                readIORef entries >>= (@?= 0)
                afterLeaseObserved <- expectRight =<< readModeRecord store leaseKey
                afterLease <-
                    maybe (assertFailure "the refused root removed the bound lease") pure afterLeaseObserved
                protectedRecordVersion afterLease @?= protectedRecordVersion beforeLease
                protectedRecordBytes afterLease @?= protectedRecordBytes beforeLease
                afterSnapshotObserved <- expectRight =<< readModeRecord store snapshotKey
                afterSnapshot <-
                    maybe (assertFailure "the refused root removed the snapshot") pure afterSnapshotObserved
                protectedRecordVersion afterSnapshot @?= protectedRecordVersion beforeSnapshot
                protectedRecordBytes afterSnapshot @?= protectedRecordBytes beforeSnapshot
                afterImage @?= beforeImage
    , testCase "a Production root preserves and refuses a malformed lease record" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                leaseKey <-
                    expectKey
                        ( "lease."
                            <> installedProjectName project
                            <> recordTupleSeparator <> "production"
                        )
                _ <-
                    expectRight
                        =<< withProtectedEntry'
                            store
                            ( \session -> do
                                written <-
                                    compareAndSwapProtectedRecord
                                        session
                                        leaseKey
                                        ExpectAbsent
                                        "not-a-lease"
                                pure
                                    ( either
                                        (Left . ModeStoreFailure)
                                        (const (Right ()))
                                        written
                                    )
                            )
                beforeObserved <- expectRight =<< readModeRecord store leaseKey
                before <-
                    maybe (assertFailure "the malformed Production lease disappeared") pure beforeObserved
                entries <- newIORef (0 :: Int)
                beforeImage <- protectedStoreImage store
                refused <-
                    withProductionRoot store project ProjectUp $ \_ -> do
                        atomicModifyIORef' entries (\count -> (count + 1, ()))
                        pure (Right ())
                afterImage <- protectedStoreImage store
                case refused of
                    Left (ModeMalformedRecord key) -> key @?= recordKeyText leaseKey
                    other ->
                        assertFailure
                            ("expected a malformed-lease root refusal, got " <> show other)
                readIORef entries >>= (@?= 0)
                afterObserved <- expectRight =<< readModeRecord store leaseKey
                after <-
                    maybe (assertFailure "the refused root removed the malformed lease") pure afterObserved
                protectedRecordVersion after @?= protectedRecordVersion before
                protectedRecordBytes after @?= protectedRecordBytes before
                afterImage @?= beforeImage
    , testCase "rebinding an already-bound lease is not a fresh transition" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withBoundSnapshot root $ \snapshot -> do
                            let unbound = productionRootUnboundLease root
                            first <- bindRunLease unbound snapshot (\_ -> pure ())
                            _ <- expectRight first
                            second <- bindRunLease unbound snapshot (\_ -> pure ())
                            case second of
                                Left conflict -> do
                                    leaseConflictMessage conflict @?= modeErrorMessage (ModeLeaseNotBindable "production" "bound")
                                    pure (Right ())
                                Right () -> assertFailure "the second binding must not be fresh"
                outcome @?= Right ()
    , testCase "a plan snapshot is byte-identically idempotent and immutable" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        do
                            let unbound = productionRootUnboundLease root
                                runName = unboundRunLeaseRunText unbound
                            key <-
                                expectKey
                                    ( "snapshot."
                                        <> installedProjectName project
                                        <> recordTupleSeparator
                                        <> runName
                                    )
                            _ <- expectRight =<< persistCanonicalPlanSnapshot unbound 1 modeTestSnapshot
                            firstObserved <- expectRight =<< readModeRecord store key
                            first <-
                                maybe
                                    (assertFailure "the first snapshot write was absent")
                                    pure
                                    firstObserved
                            -- Repeating the exact bytes is success without a
                            -- replacement write or record-version advance.
                            _ <- expectRight =<< persistCanonicalPlanSnapshot unbound 1 modeTestSnapshot
                            identicalObserved <- expectRight =<< readModeRecord store key
                            identical <-
                                maybe
                                    (assertFailure "the idempotent snapshot disappeared")
                                    pure
                                    identicalObserved
                            protectedRecordVersion identical @?= protectedRecordVersion first
                            protectedRecordBytes identical @?= protectedRecordBytes first
                            -- A differing revision is rejected at
                            -- persistence, before lease binding can reinterpret
                            -- the same run as a replacement plan.
                            substituted <-
                                persistCanonicalPlanSnapshot unbound 2 modeTestSnapshot
                            case substituted of
                                Left (ModeSnapshotMismatch expected observed) -> do
                                    let description revision =
                                            "revision " <> revision
                                                <> ", spec " <> canonicalPlanSnapshotSpecDigest modeTestSnapshot
                                                <> ", plan " <> closePlanDigest
                                                <> ", config config-1"
                                    expected @?= description "2"
                                    observed @?= description "1"
                                other ->
                                    assertFailure
                                        ("expected immutable snapshot refusal, got " <> show other)
                            unchangedObserved <- expectRight =<< readModeRecord store key
                            unchanged <-
                                maybe
                                    (assertFailure "the refused snapshot disappeared")
                                    pure
                                    unchangedObserved
                            protectedRecordVersion unchanged @?= protectedRecordVersion first
                            protectedRecordBytes unchanged @?= protectedRecordBytes first
                            verified <-
                                verifyPlanSnapshot unbound $ \snapshot ->
                                    pure
                                        ( Right
                                            ( planSnapshotRevision snapshot
                                            , planSnapshotSpecDigest snapshot
                                            , planSnapshotPlanDigest snapshot
                                            )
                                        )
                            verified @?= Right (1, canonicalPlanSnapshotSpecDigest modeTestSnapshot, closePlanDigest)
                            pure (Right ())
                outcome @?= Right ()
    , testCase "a canonical snapshot persists exact bytes and refuses config/topology substitution" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        do
                            let unbound = productionRootUnboundLease root
                                runName = unboundRunLeaseRunText unbound
                                firstSnapshot = canonicalTestSnapshot "config-a"
                                configReplacement = canonicalTestSnapshot "config-b"
                                topologyReplacement =
                                    canonicalTestSnapshotFor "config-a" alternateTestStepPlan
                            key <-
                                expectKey
                                    ( "snapshot."
                                        <> installedProjectName project
                                        <> recordTupleSeparator
                                        <> runName
                                    )
                            _ <-
                                expectRight
                                    =<< persistCanonicalPlanSnapshot
                                        unbound
                                        1
                                        firstSnapshot
                            firstObserved <- expectRight =<< readModeRecord store key
                            firstRecord <-
                                maybe
                                    (assertFailure "the canonical snapshot write was absent")
                                    pure
                                    firstObserved
                            inspected <- expectRight =<< withProtectedEntry' store (\session -> inspectPlanSnapshot session project runName)
                            planSnapshotViewRevision inspected @?= 1
                            planSnapshotViewSpecDigest inspected @?= canonicalPlanSnapshotSpecDigest firstSnapshot
                            planSnapshotViewPlanDigest inspected @?= canonicalPlanSnapshotDigest firstSnapshot
                            planSnapshotViewConfigDigest inspected @?= Just "config-a"
                            planSnapshotViewCanonicalBytes inspected @?= Just (canonicalPlanSnapshotBytes firstSnapshot)
                            readModeRecord store key >>= (@?= Right (Just firstRecord))
                            _ <-
                                expectRight
                                    =<< persistCanonicalPlanSnapshot
                                        unbound
                                        1
                                        firstSnapshot
                            identicalObserved <- expectRight =<< readModeRecord store key
                            identicalRecord <-
                                maybe
                                    (assertFailure "the idempotent canonical snapshot disappeared")
                                    pure
                                    identicalObserved
                            protectedRecordVersion identicalRecord @?= protectedRecordVersion firstRecord
                            protectedRecordBytes identicalRecord @?= protectedRecordBytes firstRecord
                            substituted <-
                                persistCanonicalPlanSnapshot
                                    unbound
                                    1
                                    configReplacement
                            case substituted of
                                Left (ModeSnapshotMismatch _ _) -> pure ()
                                other ->
                                    assertFailure
                                        ("expected canonical substitution refusal, got " <> show other)
                            topologySubstituted <-
                                persistCanonicalPlanSnapshot
                                    unbound
                                    1
                                    topologyReplacement
                            case topologySubstituted of
                                Left (ModeSnapshotMismatch _ _) -> pure ()
                                other ->
                                    assertFailure
                                        ("expected topology substitution refusal, got " <> show other)
                            verified <-
                                verifyPlanSnapshot unbound $ \snapshot ->
                                    pure
                                        ( Right
                                            ( planSnapshotSpecDigest snapshot
                                            , planSnapshotPlanDigest snapshot
                                            , planSnapshotConfigDigest snapshot
                                            , planSnapshotCanonicalBytes snapshot
                                            )
                                        )
                            verified
                                @?= Right
                                    ( canonicalPlanSnapshotSpecDigest firstSnapshot
                                    , canonicalPlanSnapshotDigest firstSnapshot
                                    , Just "config-a"
                                    , Just (canonicalPlanSnapshotBytes firstSnapshot)
                                    )
                            unchangedObserved <- expectRight =<< readModeRecord store key
                            unchangedRecord <-
                                maybe
                                    (assertFailure "the refused canonical snapshot disappeared")
                                    pure
                                    unchangedObserved
                            protectedRecordVersion unchangedRecord @?= protectedRecordVersion firstRecord
                            protectedRecordBytes unchangedRecord @?= protectedRecordBytes firstRecord
                            pure (Right ())
                outcome @?= Right ()
    , testCase "a hostile canonical frame length is rejected before allocation" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        do
                            let unbound = productionRootUnboundLease root
                                runName = unboundRunLeaseRunText unbound
                                hostile =
                                    LazyByteString.toStrict
                                        ( Builder.toLazyByteString
                                            ( Builder.byteString "HOSTBOOTSTRAP-SNAPSHOT"
                                                <> Builder.word64BE 1
                                                <> Builder.word64BE 1
                                                <> Builder.word64BE maxBound
                                            )
                                        )
                            key <-
                                expectKey
                                    ( "snapshot."
                                        <> installedProjectName project
                                        <> recordTupleSeparator
                                        <> runName
                                    )
                            _ <-
                                expectRight
                                    =<< withProtectedEntry'
                                        store
                                        ( \session -> do
                                            written <-
                                                compareAndSwapProtectedRecord
                                                    session
                                                    key
                                                    ExpectAbsent
                                                    hostile
                                            pure (either (Left . ModeStoreFailure) (const (Right ())) written)
                                        )
                            decoded <-
                                verifyPlanSnapshot unbound (\_ -> pure (Right ()))
                            case decoded of
                                Left (ModeMalformedRecord malformedKey) -> do
                                    malformedKey @?= recordKeyText key
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected bounded malformed-record refusal, got " <> show other)
                outcome @?= Right ()
    , testCase "a Production profile consumes its exact protected slot once" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root -> do
                        let modeLease = productionRootModeLease root
                            active = productionActiveMode modeLease
                            expectedEpoch = brokerEpochWord (projectModeLeaseEpoch modeLease)
                            expectedProject = installedProjectName project
                            expectedStore =
                                protectedStoreIdentityText (protectedStoreIdentity store)
                            expectedInvocation =
                                "lifecycle-profile:"
                                    <> installedProjectName project
                                    <> ":production"
                            open =
                                withProductionLifecycleProfile
                                    (rootScopeAuthority (productionRootAuthority root))
                                    active
                                    (productionRootUnboundLease root)
                        projectModeLeaseName modeLease @?= "production"
                        brokerEpochWord (activeProjectModeEpoch active) @?= expectedEpoch
                        first <-
                            expectRight
                                =<< open
                                    ( \profile ->
                                        ( lifecycleProfileName profile
                                        , lifecycleProfileEpoch profile
                                        , lifecycleProfileProjectName profile
                                        , lifecycleProfileStoreIdentity profile
                                        )
                                    )
                        first @?= ("production", expectedEpoch, expectedProject, expectedStore)
                        second <- open (const ())
                        case second of
                            Left (AuthorityInvocationConsumed invocation) ->
                                invocation @?= expectedInvocation
                            other ->
                                assertFailure
                                    ("expected the Production profile slot to be consumed, got " <> show other)
                        pure (Right ())
                outcome @?= Right ()
    , testCase "a second Production profile opener with the same evidence is refused" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcomes <- newEmptyMVar
                outcome <-
                    withProductionRoot store project ProjectUp $ \root -> do
                        let modeLease = productionRootModeLease root
                            active = productionActiveMode modeLease
                            expectedEpoch = brokerEpochWord (projectModeLeaseEpoch modeLease)
                            open =
                                withProductionLifecycleProfile
                                    (rootScopeAuthority (productionRootAuthority root))
                                    active
                                    (productionRootUnboundLease root)
                            worker = do
                                opened <-
                                    open (\profile -> (lifecycleProfileName profile, lifecycleProfileEpoch profile))
                                putMVar outcomes opened
                        _ <- forkIO worker
                        _ <- forkIO worker
                        results <- replicateM 2 (takeMVar outcomes)
                        [value | Right value <- results] @?= [("production", expectedEpoch)]
                        case [failure | Left failure <- results] of
                            [AuthorityInvocationConsumed _] -> pure ()
                            failures ->
                                assertFailure
                                    ("expected one consumed Production opener, got " <> show failures)
                        pure (Right ())
                outcome @?= Right ()
    , testCase "a Harness profile consumes its exact run slot once" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withFreshHarnessRoot store project $ \root -> do
                        let authority = harnessRootHarnessAuthority root
                            run = harnessRootRunId root
                            modeLease = harnessRootModeLease root
                            active = harnessActiveMode modeLease
                            expectedName = "harness:" <> runIdText run
                            expectedEpoch = brokerEpochWord (projectModeLeaseEpoch modeLease)
                            expectedProject = installedProjectName project
                            expectedStore =
                                protectedStoreIdentityText (protectedStoreIdentity store)
                            expectedInvocation =
                                "lifecycle-profile:"
                                    <> installedProjectName project
                                    <> ":"
                                    <> runIdText run
                            open =
                                withHarnessLifecycleProfile
                                    (rootScopeAuthority (harnessRootAuthority root))
                                    authority
                                    run
                                    active
                                    (harnessRootUnboundLease root)
                        projectModeLeaseName modeLease @?= expectedName
                        brokerEpochWord (activeProjectModeEpoch active) @?= expectedEpoch
                        first <-
                            expectRight
                                =<< open
                                    ( \profile ->
                                        ( lifecycleProfileName profile
                                        , lifecycleProfileEpoch profile
                                        , lifecycleProfileProjectName profile
                                        , lifecycleProfileStoreIdentity profile
                                        )
                                    )
                        first @?= (expectedName, expectedEpoch, expectedProject, expectedStore)
                        second <- open (const ())
                        case second of
                            Left (AuthorityInvocationConsumed invocation) ->
                                invocation @?= expectedInvocation
                            other ->
                                assertFailure
                                    ("expected the Harness profile slot to be consumed, got " <> show other)
                        pure (Right ())
                outcome @?= Right ()
    , testCase "a second Harness profile opener with the same evidence is refused" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcomes <- newEmptyMVar
                outcome <-
                    withFreshHarnessRoot store project $ \root -> do
                        let authority = harnessRootHarnessAuthority root
                            run = harnessRootRunId root
                            modeLease = harnessRootModeLease root
                            active = harnessActiveMode modeLease
                            expectedName = "harness:" <> runIdText run
                            expectedEpoch = brokerEpochWord (projectModeLeaseEpoch modeLease)
                            open =
                                withHarnessLifecycleProfile
                                    (rootScopeAuthority (harnessRootAuthority root))
                                    authority
                                    run
                                    active
                                    (harnessRootUnboundLease root)
                            worker = do
                                opened <-
                                    open (\profile -> (lifecycleProfileName profile, lifecycleProfileEpoch profile))
                                putMVar outcomes opened
                        _ <- forkIO worker
                        _ <- forkIO worker
                        results <- replicateM 2 (takeMVar outcomes)
                        [value | Right value <- results] @?= [(expectedName, expectedEpoch)]
                        case [failure | Left failure <- results] of
                            [AuthorityInvocationConsumed _] -> pure ()
                            failures ->
                                assertFailure
                                    ("expected one consumed Harness opener, got " <> show failures)
                        pure (Right ())
                outcome @?= Right ()
    , testCase "the normal unbound no-resource proof refuses same-run acquisition ownership" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withFreshHarnessRoot store project $ \root -> do
                        let run = runIdText (harnessRootRunId root)
                        acquisitionKey <-
                            writeAcquisitionShapedRecord
                                store
                                project
                                run
                                "normal-unbound"
                                "malformed-normal-acquisition"
                        refused <-
                            verifyNoProjectResourcesAcquired
                                (harnessRootUnboundLease root)
                        case refused of
                            Left (ModeEffectsRecorded recorded) ->
                                recorded @?= recordKeyText acquisitionKey
                            other ->
                                assertFailure
                                    ("expected the normal unbound proof to refuse, got " <> show other)
                        persisted <-
                            withProtectedEntry store $ \session ->
                                readProtectedRecord session acquisitionKey
                        fmap (fmap protectedRecordBytes) persisted
                            @?= Right (Just "malformed-normal-acquisition")
                        pure (Right ())
                outcome @?= Right ()
    , testCase "a journal-only bound run remains classified pre-resource" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withFreshHarnessRoot store project $ \root -> do
                        let run = runIdText (harnessRootRunId root)
                            unbound = harnessRootUnboundLease root
                        _ <- expectRight =<< persistCanonicalPlanSnapshot unbound 1 modeTestSnapshot
                        verifyPlanSnapshot unbound $ \snapshot -> do
                            bound <- expectRight =<< bindRunLease unbound snapshot pure
                            acquisitionKey <-
                                writeAcquisitionShapedRecord
                                    store
                                    project
                                    run
                                    "41"
                                    "journal-with-no-resource-effect"
                            preResource <- verifyBoundRunHasNoProjectResourcesAcquired bound
                            _ <- either (assertFailure . show) pure preResource
                            persisted <-
                                withProtectedEntry store $ \session ->
                                    readProtectedRecord session acquisitionKey
                            fmap (fmap protectedRecordBytes) persisted
                                @?= Right (Just "journal-with-no-resource-effect")
                            pure (Right ())
                outcome @?= Right ()
    , testCase "retained Production closure cannot release a successor epoch" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <- withProductionRoot store project ProjectUp $ \first -> do
                    old <- authorizeProductionPreEffect first >>= either (assertFailure . show) pure
                    withProductionRoot store project ProjectUp $ \second -> do
                        fresh <- authorizeProductionPreEffect second >>= either (assertFailure . show) pure
                        withProtectedEntry' store $ \session -> do
                            stale <- releaseProductionMode session project old
                            case stale of
                                Left (ModeEpochMismatch _ _) -> pure ()
                                other -> assertFailure ("expected stale epoch refusal, got " <> show other)
                            releaseProductionMode session project fresh
                outcome @?= Right ()
    , testCase "production mode is released, so a harness run may then start" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                _ <-
                    withProductionRoot store project ProjectDestroy $ \root -> do
                        evidence <- authorizeProductionPreEffect root
                        preEffect <- either (assertFailure . show) pure evidence
                        withProtectedEntry' store $ \session -> do
                            released <- releaseProductionMode session project preEffect
                            released @?= Right ()
                            pure (Right ())
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                proof <- either (assertFailure . show) pure swept
                outcome <-
                    withHarnessRoot
                        store
                        project
                        ProjectUp
                        (satisfiedPreconditions project)
                        proof
                        (\root -> pure (Right (projectModeLeaseName (harnessRootModeLease root))))
                case outcome of
                    Right held | "harness:" `Text.isPrefixOf` held -> pure ()
                    other -> assertFailure ("expected harness mode, got " <> show other)
    ]

-- Every prefix includes the point after mode deletion but before coordinator
-- commit. Recovery through both Session and ordinary Mode admission converges
-- on the same versions, and a second read performs no additional close.
productionCloseRecoveryCase :: Int -> TestTree
productionCloseRecoveryCase prefix =
    testCase ("Production closure recovers after " <> show prefix <> " materialized targets") $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <- withProductionRoot store project ProjectUp $ \root -> do
                    authorization <- authorizeProductionPreEffect root >>= either (assertFailure . show) pure
                    (restored, planDigest, verify) <- TransactionFixture.withInterruptedProductionTransaction prefix store $ do
                        result <- withProtectedEntry' store $ \session -> releaseProductionMode session project authorization
                        result @?= Right ()
                    if even prefix
                        then do
                            swept <- recoverAbandonedHarnessRuns restored project neverResolves neverResolves
                            _ <- either (assertFailure . show) pure swept
                            pure ()
                        else do
                            state <- withProtectedEntry restored $ \session -> Right <$> readProjectJournalState session planDigest
                            state @?= Right (Right ClosedProject)
                    verify
                    retried <- withProtectedEntry' restored $ \session -> releaseProductionMode session project authorization
                    retried @?= Right ()
                    verify
                    state <- withProtectedEntry restored $ \session -> Right <$> readProjectJournalState session planDigest
                    state @?= Right (Right ClosedProject)
                    verify
                    pure (Right ())
                outcome @?= Right ()

-- Abandoned-run recovery ------------------------------------------------------------------

recoveryCases :: [TestTree]
recoveryCases =
    [ testCase "an abandoned unbound lease is swept and its mode released" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                -- Simulate a killed harness run: the bracket recorded its mode
                -- and unbound lease and then died without closing either.
                _ <- abandonHarnessRun store project
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left failure -> assertFailure (show failure)
                    Right proof -> closedAbandonedHarnessRunsCount proof @?= 1
    , testCase "a new harness run is refused while an abandoned lease is unresolved" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                _ <- abandonBoundHarnessRun store project
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left (ModeRecoveryRequired _) -> pure ()
                    other -> assertFailure ("expected required recovery, got " <> show other)
    , testCase "a bound abandoned lease is resolved through the caller's fold" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                _ <- abandonBoundHarnessRun store project
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease ->
                        withAbandonedHarnessRun store project lease (resolveNothingAcquired store project)
                case swept of
                    Left failure -> assertFailure (show failure)
                    Right proof -> closedAbandonedHarnessRunsCount proof @?= 1
    , -- The reopening the sweep's bound callback needs. Before it existed the
      -- bound branch classified the run and closed it through a bare 'RunId', so
      -- nothing said who was allowed to resolve it and no authority was minted
      -- for the branches that cannot be resolved yet.
      testCase "reopening an abandoned bound run yields destroy-only authority on a fresh generation" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                (run, abandonedEpoch) <- abandonBoundHarnessRun store project
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease ->
                        withAbandonedHarnessRun store project lease $ \reopened -> do
                            runIdText (abandonedHarnessRunId reopened) @?= run
                            -- The exact old snapshot, read back durably rather
                            -- than reconstructed from the current config.
                            let snapshot = abandonedHarnessSnapshot reopened
                            planSnapshotRunText snapshot @?= run
                            planSnapshotSpecDigest snapshot @?= canonicalPlanSnapshotSpecDigest modeTestSnapshot
                            planSnapshotPlanDigest snapshot @?= closePlanDigest
                            -- The already-bound lease, not a rebinding: same run,
                            -- same digests.
                            let bound = abandonedHarnessBoundLease reopened
                            boundRunLeaseRunText bound @?= run
                            boundRunLeaseSpecDigest bound @?= canonicalPlanSnapshotSpecDigest modeTestSnapshot
                            boundRunLeasePlanDigest bound @?= closePlanDigest
                            -- Recovery may release and never acquire.
                            projectVerbName
                                (rootAuthorityVerb (abandonedHarnessDestroyRoot reopened))
                                @?= "destroy"
                            -- Its close authority says it is recovery's, not the
                            -- live run's.
                            let closeRoot = abandonedHarnessCloseRoot reopened
                            harnessCloseRootOrigin closeRoot @?= RecoveredHarnessClose
                            runIdText (harnessCloseRootRun closeRoot) @?= run
                            -- The mode is still the abandoned run's own, and every
                            -- yielded value sits on a strictly fresher broker
                            -- generation, so the dead run's permits are fenced out
                            -- rather than resumed.
                            let modeLease = abandonedHarnessModeLease reopened
                                reopenedEpoch = brokerEpochWord (projectModeLeaseEpoch modeLease)
                            projectModeLeaseName modeLease @?= "harness:" <> run
                            assertBool
                                ( "generation "
                                    <> show reopenedEpoch
                                    <> " must be fresher than the abandoned "
                                    <> show abandonedEpoch
                                )
                                (reopenedEpoch > abandonedEpoch)
                            pure (Right ())
                -- Reopening resolves nothing on its own, so the sweep still
                -- refuses: the recheck is what makes a no-op callback fail.
                case swept of
                    Left (ModeRecoveryRequired named) ->
                        assertBool
                            ("the refusal names the run: " <> Text.unpack named)
                            (run `Text.isInfixOf` named)
                    other -> assertFailure ("expected required recovery, got " <> show other)
    , testCase "an unbound lease cannot be reopened; only the sweep may close it" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                _ <- abandonHarnessRun store project
                swept <-
                    recoverAbandonedHarnessRuns
                        store
                        project
                        ( \lease -> do
                            refused <-
                                withAbandonedHarnessRun store project lease (\_ -> pure (Right ()))
                            case refused of
                                -- No snapshot exists, so there is nothing to
                                -- reopen: 'verifyUnboundLeaseHasNoEffects' is the
                                -- only route for this kind.
                                Left (ModeLeaseNotBindable _ state) -> do
                                    state @?= "unbound"
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected an unbound refusal, got " <> show other)
                        )
                        neverResolves
                proof <- either (assertFailure . show) pure swept
                closedAbandonedHarnessRunsCount proof @?= 1
    , -- The exhaustive first branch: a run that persisted its Closing epoch is a
      -- close to resume, never normal revision recovery, and reopening must say
      -- so with the exact epoch rather than leave the caller to guess.
      testCase "a persisted closing epoch is reopened as the closing branch" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                (run, _) <-
                    abandonBoundHarnessRunWith store project $ \run ->
                        withProtectedEntry' store $ \session ->
                            recordHarnessClosingEpoch session project run 9
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease ->
                        withAbandonedHarnessRun store project lease $ \reopened ->
                            case abandonedHarnessRecovery reopened of
                                HarnessPersistedClosing epoch -> do
                                    epoch @?= 9
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected the closing branch, got " <> show other)
                -- The callback resolved nothing, so the sweep's recheck still
                -- refuses and names the run.
                case swept of
                    Left (ModeRecoveryRequired named) ->
                        assertBool
                            ("the refusal names the run: " <> Text.unpack named)
                            (run `Text.isInfixOf` named)
                    other -> assertFailure ("expected required recovery, got " <> show other)
    , {- The close was already authorized after settled destroy:
      'authorizeHarnessClose' persists the epoch before terminal finalization so
      the remaining gap is resumable. Recovery therefore finishes that close
      rather than reopening the run — and it can only finish the exact close the
      dead run persisted. -}
      testCase "a persisted closing epoch is resumed, and only at its own epoch" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                (run, _) <-
                    abandonBoundHarnessRunWith store project $ \run ->
                        withProtectedEntry' store $ \session ->
                            recordHarnessClosingEpoch session project run 9
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease ->
                        withAbandonedHarnessRun store project lease $ \reopened ->
                            case abandonedHarnessRecovery reopened of
                                HarnessPersistedClosing epoch -> do
                                    epoch @?= 9
                                    let resume presented =
                                            withProtectedEntry' store $ \session ->
                                                resumeHarnessClose
                                                    session
                                                    project
                                                    (abandonedHarnessCloseRoot reopened)
                                                    (abandonedHarnessModeLease reopened)
                                                    (abandonedHarnessBoundLease reopened)
                                                    presented
                                    -- an epoch this run never persisted resumes nothing
                                    wrong <- resume (epoch + 1)
                                    case wrong of
                                        Left (ModeEpochMismatch persisted presented) -> do
                                            persisted @?= 9
                                            presented @?= 10
                                        other ->
                                            assertFailure
                                                ("expected an epoch mismatch, got " <> show (() <$ other))
                                    authorization <- expectRight =<< resume epoch
                                    finalized <-
                                        withProtectedEntry' store $ \session ->
                                            finalizeHarnessClose session project authorization
                                    closed <- expectRight finalized
                                    runIdText (closedHarnessProjectRun closed) @?= run
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected the closing branch, got " <> show other)
                -- The resumed close settled the run, so the sweep's recheck sees
                -- an empty set and the next run may start.
                proof <- either (assertFailure . show) pure swept
                closedAbandonedHarnessRunsCount proof @?= 1
    , testCase "a run with no persisted close has nothing to resume" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                _ <- abandonBoundHarnessRun store project
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease ->
                        withAbandonedHarnessRun store project lease $ \reopened -> do
                            refused <-
                                withProtectedEntry' store $ \session ->
                                    resumeHarnessClose
                                        session
                                        project
                                        (abandonedHarnessCloseRoot reopened)
                                        (abandonedHarnessModeLease reopened)
                                        (abandonedHarnessBoundLease reopened)
                                        9
                            case refused of
                                Left (ModeRecoveryRequired _) -> pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected no close to resume, got " <> show (() <$ other))
                case swept of
                    Left (ModeRecoveryRequired _) -> pure ()
                    other -> assertFailure ("expected required recovery, got " <> show other)
    , -- The sweep observed the lease at an earlier store version, so reopening
      -- rechecks it. A lease another resolver already closed is not a run this
      -- opener may reopen.
      testCase "a lease resolved since the sweep observed it cannot be reopened again" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                _ <- abandonBoundHarnessRun store project
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease -> do
                        first <-
                            withAbandonedHarnessRun
                                store
                                project
                                lease
                                (resolveNothingAcquired store project)
                        _ <- expectRight first
                        again <-
                            withAbandonedHarnessRun store project lease (\_ -> pure (Right ()))
                        case again of
                            Left (ModeLeaseNotBindable _ state) -> do
                                state @?= "closed"
                                pure (Right ())
                            other ->
                                assertFailure
                                    ("expected a closed-lease refusal, got " <> show other)
                proof <- either (assertFailure . show) pure swept
                closedAbandonedHarnessRunsCount proof @?= 1
    , testCase "an unbound lease with a recorded effect refuses the no-effect proof" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                run <- abandonHarnessRun store project
                effectKey <-
                    expectKey
                        ( "effect."
                            <> installedProjectName project
                            <> recordTupleSeparator
                            <> run
                            <> recordTupleSeparator <> "vm"
                        )
                _ <-
                    withProtectedEntry store $ \session ->
                        compareAndSwapProtectedRecord session effectKey ExpectAbsent "created"
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left (ModeEffectsRecorded _) -> pure ()
                    other ->
                        assertFailure ("expected a recorded-effect refusal, got " <> show other)
    , testCase "a same-run acquisition row refuses unbound cleanup and remains durable" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                run <- abandonHarnessRun store project
                acquisitionKey <-
                    expectKey
                        ( "acquisition."
                            <> installedProjectName project
                            <> recordTupleSeparator
                            <> run
                            <> recordTupleSeparator <> "not-an-epoch"
                        )
                written <-
                    withProtectedEntry store $ \session ->
                        compareAndSwapProtectedRecord
                            session
                            acquisitionKey
                            ExpectAbsent
                            "malformed-acquisition-payload"
                _ <- either (assertFailure . show) pure written
                before <- protectedStoreImage store
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left (ModeEffectsRecorded recorded) ->
                        recorded @?= recordKeyText acquisitionKey
                    other ->
                        assertFailure
                            ("expected an acquisition-record refusal, got " <> show other)
                after <- protectedStoreImage store
                after @?= before
                persisted <-
                    withProtectedEntry store $ \session ->
                        readProtectedRecord session acquisitionKey
                fmap (fmap protectedRecordBytes) persisted
                    @?= Right (Just "malformed-acquisition-payload")
    , testCase "another run's acquisition row does not block unbound cleanup" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                run <- abandonHarnessRun store project
                otherRunKey <-
                    expectKey
                        ( "acquisition."
                            <> installedProjectName project
                            <> recordTupleSeparator
                            <> run
                            <> "-other" <> recordTupleSeparator <> "17"
                        )
                written <-
                    withProtectedEntry store $ \session ->
                        compareAndSwapProtectedRecord
                            session
                            otherRunKey
                            ExpectAbsent
                            "unrelated-acquisition"
                _ <- either (assertFailure . show) pure written
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                proof <- either (assertFailure . show) pure swept
                closedAbandonedHarnessRunsCount proof @?= 1
                persisted <-
                    withProtectedEntry store $ \session ->
                        readProtectedRecord session otherRunKey
                fmap (fmap protectedRecordBytes) persisted
                    @?= Right (Just "unrelated-acquisition")
    , -- The cross-profile half of the four-process reservation race. Production
      -- has no generative run id and no liveness lock, so its unbound lease is
      -- shaped exactly like an abandoned harness run's. The sweep must not read
      -- it as one: closing a live invocation's lease is the same defect the
      -- harness race exposed, across profiles instead of within one, and here it
      -- would also discard the evidence Production's own bound recovery needs.
      testCase "a live production invocation is never swept, and refuses the harness by mode" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \_root -> do
                        swept <-
                            recoverAbandonedHarnessRuns store project neverResolves neverResolves
                        proof <- either (assertFailure . show) pure swept
                        -- Nothing was abandoned: the only incomplete lease is the
                        -- live Production invocation's, which is not this sweep's
                        -- to resolve.
                        closedAbandonedHarnessRunsCount proof @?= 0
                        refused <-
                            withHarnessRoot
                                store
                                project
                                ProjectUp
                                (satisfiedPreconditions project)
                                proof
                                (\_ -> pure (Right ()))
                        case refused of
                            -- § Z: a harness run against live Production is a
                            -- stated exclusion, not an overlap and not a sweep.
                            Left (ModeHeldByAnother held wanted) -> do
                                held @?= "production"
                                assertBool
                                    ("the harness names itself: " <> Text.unpack wanted)
                                    ("harness:" `Text.isPrefixOf` wanted)
                            other ->
                                assertFailure
                                    ("expected the production mode to refuse, got " <> show other)
                        pure (Right ())
                outcome @?= Right ()
    , -- The control for the two cross-profile races below. Without it, "the
      -- competitor exited 3" proves nothing: a probe that can never take a
      -- profile refuses an empty store just as convincingly as a held one.
      testCase "the competitor process takes either profile when no mode is held" $ do
        executable <- getExecutablePath
        withStore $ \store ->
            probeProfile executable (protectedStoreRoot store) "harness"
                >>= (@?= ProfileAcquired)
        withStore $ \store ->
            probeProfile executable (protectedStoreRoot store) "production"
                >>= (@?= ProfileAcquired)
    , -- The out-of-process half of the cross-profile exclusion. The in-process
      -- case above proves the decision; this one proves it holds against a real
      -- competitor, because the root brackets release the exclusive entry once
      -- the mode transaction commits. What the competitor contends on is
      -- therefore the durable mode record, not the entry.
      testCase "a competitor harness process is refused by live Production, across processes" $ do
        executable <- getExecutablePath
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \_root -> do
                        probed <- probeProfile executable (protectedStoreRoot store) "harness"
                        case probed of
                            ProfileRefusedBy held -> held @?= "production"
                            other ->
                                assertFailure
                                    ("expected the competitor to be refused by production, got " <> show other)
                        pure (Right ())
                outcome @?= Right ()
    , testCase "a competitor production process is refused by a live harness run, across processes" $ do
        executable <- getExecutablePath
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                proof <- either (assertFailure . show) pure swept
                outcome <-
                    withHarnessRoot store project ProjectUp (satisfiedPreconditions project) proof $ \root -> do
                        probed <- probeProfile executable (protectedStoreRoot store) "production"
                        case probed of
                            -- The refusal names the exact run holding the mode,
                            -- so the competitor cannot have been refused by some
                            -- other obstacle that also exits 3.
                            ProfileRefusedBy held ->
                                held @?= "harness:" <> runIdText (harnessRootRunId root)
                            other ->
                                assertFailure
                                    ("expected the competitor to be refused by the harness run, got " <> show other)
                        pure (Right ())
                outcome @?= Right ()
    ]

-- Invocation and terminal close -------------------------------------------------------------

closeCases :: [TestTree]
closeCases =
    [ testCase "Harness short-close refuses a session opened after its no-effect proof" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <- withFreshHarnessRoot store project $ \root -> do
                    let unbound = harnessRootUnboundLease root
                    _ <- expectRight =<< persistCanonicalPlanSnapshot unbound 1 modeTestSnapshot
                    verifyPlanSnapshot unbound $ \snapshot -> do
                        bound <- expectRight =<< bindRunLease unbound snapshot pure
                        preEffect <- expectRight =<< verifyBoundRunHasNoProjectResourcesAcquired bound
                        _ <- withProtectedEntry' store $ \session -> do
                            permit <- expectRight =<< openProjectJournal session closePlanDigest
                            _ <-
                                expectRight
                                    =<< openOperationSession
                                        session
                                        (projectModeLeaseEpoch (harnessRootModeLease root))
                                        closePlanDigest
                                        "late-session"
                                        permit
                            pure (Right ())
                        before <- protectedStoreImage store
                        refused <- withProtectedEntry' store $ \session ->
                            closeHarnessRun
                                session
                                project
                                (currentHarnessCloseRoot root)
                                (harnessRootModeLease root)
                                preEffect
                        case refused of
                            Left (ModeSessionFailure (SessionStillOpen _)) -> pure ()
                            other -> assertFailure ("expected an open-session refusal, got " <> show other)
                        after <- protectedStoreImage store
                        after @?= before
                        pure (Right ())
                outcome @?= Right ()
    , testGroup
        "Harness short-close refuses a record added after its no-effect proof"
        [ testCase label $
            withStore $ \store ->
                Fixture.withFixtureInstalledProject $ \project -> do
                    outcome <- withFreshHarnessRoot store project $ \root -> do
                        let unbound = harnessRootUnboundLease root
                        _ <- expectRight =<< persistCanonicalPlanSnapshot unbound 1 modeTestSnapshot
                        verifyPlanSnapshot unbound $ \snapshot -> do
                            bound <- expectRight =<< bindRunLease unbound snapshot pure
                            preEffect <- expectRight =<< verifyBoundRunHasNoProjectResourcesAcquired bound
                            rawKey <- expectRight (keyText (installedProjectName project) (runIdText (harnessRootRunId root)))
                            effectKey <- expectKey rawKey
                            _ <-
                                expectRight
                                    =<< withProtectedEntry
                                        store
                                        (\session -> compareAndSwapProtectedRecord session effectKey ExpectAbsent "created")
                            before <- protectedStoreImage store
                            refused <- withProtectedEntry' store $ \session ->
                                closeHarnessRun
                                    session
                                    project
                                    (currentHarnessCloseRoot root)
                                    (harnessRootModeLease root)
                                    preEffect
                            refused @?= Left (ModeEffectsRecorded (recordKeyText effectKey))
                            after <- protectedStoreImage store
                            after @?= before
                            pure (Right ())
                    outcome @?= Right ()
        | (label, keyText) <-
            [ ("legacy effect", \project run -> Right ("effect." <> project <> recordTupleSeparator <> run <> recordTupleSeparator <> "vm"))
            , ("canonical resource", \_ _ -> resourceRecordKey closePlanDigest "late-frame" "late-resource")
            ]
        ]
    , testCase "the session-completeness proof refuses while any session is open" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session -> do
                            permit <- expectRight =<< openProjectJournal session closePlanDigest
                            _ <-
                                expectRight
                                    =<< openOperationSession
                                        session
                                        (projectModeLeaseEpoch (productionRootModeLease root))
                                        closePlanDigest
                                        "s1"
                                        permit
                            -- A session that registered NO operations is still a
                            -- member of the set: it is exactly what a kill right
                            -- after open leaves behind.
                            still <-
                                verifyAllSessionsClosedHere session ::
                                    IO (Either SessionError (VerifiedAllSessionsClosed () ()))
                            case still of
                                Left (SessionStillOpen _) -> pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected a still-open refusal, got " <> show other)
                outcome @?= Right ()
    , testCase "a closing project admits no new session, and only its own epoch resumes" $
        withStore $ \store -> do
            outcome <- withProtectedEntry store $ \session -> do
                permit <- expectRight =<< openProjectJournal session closePlanDigest
                _closing <- expectRight =<< beginClosingProject session closePlanDigest 7 permit
                state <- expectRight =<< readProjectJournalState session closePlanDigest
                state @?= ClosingProject 7
                -- Retaining the pre-close Open permit is harmless: it can only
                -- resume the exact persisted closing epoch and the result is a
                -- type-distinct Closing permit.
                resumed <- beginClosingProject session closePlanDigest 7 permit
                assertBool "the same closing epoch resumes idempotently" (not (isLeft resumed))
                second <- beginClosingProject session closePlanDigest 9 permit
                case second of
                    Left (SessionProjectClosing _) -> pure ()
                    other ->
                        assertFailure ("a second closing epoch must refuse, got " <> show other)
                reopened <- openProjectJournal session closePlanDigest
                case reopened of
                    Left (SessionProjectClosing _) -> pure (Right ())
                    other ->
                        assertFailure
                            ("a closing project must refuse a new session, got " <> show other)
            outcome @?= Right ()
    , testCase "only the matching closing epoch can become closed" $
        withStore $ \store -> do
            outcome <- withProtectedEntry store $ \session -> do
                permit <- expectRight =<< openProjectJournal session closePlanDigest
                closing <- expectRight =<< beginClosingProject session closePlanDigest 7 permit
                wrong <- recordClosedProject session closePlanDigest 8 closing
                case wrong of
                    Left (SessionProjectClosing _) -> pure ()
                    other ->
                        assertFailure ("a foreign closing epoch must refuse, got " <> show other)
                closed <- expectRight =<< recordClosedProject session closePlanDigest 7 closing
                state <- expectRight =<< readProjectJournalState session closePlanDigest
                state @?= ClosedProject
                closed `seq` pure (Right ())
            outcome @?= Right ()
    , testCase "closing a production invocation retains production mode" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                closed <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withBoundSnapshot root $ \snapshot -> do
                            bound <-
                                expectRight
                                    =<< bindRunLease
                                        (productionRootUnboundLease root)
                                        snapshot
                                        pure
                            withProtectedEntry' store $ \session -> do
                                sessions <-
                                    expectRight =<< verifyAllSessionsClosedHere session
                                key <- expectCloseKey "close-up-1"
                                completed <-
                                    expectRight
                                        (completeProductionInvocation bound sessions)
                                outcome <-
                                    closeCompletedProductionInvocation
                                        session
                                        project
                                        (productionRootModeLease root)
                                        completed
                                        key
                                case outcome of
                                    Right (ProductionInvocationCloseCommitted done) -> do
                                        productionInvocationClosedRun done
                                            @?= boundRunLeaseRunText bound
                                        pure (Right ())
                                    other ->
                                        assertFailure
                                            ("expected a committed close, got " <> show other)
                closed @?= Right ()
                -- The invocation ended; the PROJECT did not. Production still
                -- holds the mode, which is what makes `down` keep the exclusion,
                -- so a harness run is still refused.
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                proof <- either (assertFailure . show) pure swept
                refused <-
                    withHarnessRoot
                        store
                        project
                        ProjectUp
                        (satisfiedPreconditions project)
                        proof
                        (\_ -> pure (Right ()))
                case refused of
                    Left (ModeHeldByAnother held _) -> held @?= "production"
                    other ->
                        assertFailure
                            ("a harness run must still be refused, got " <> show other)
    , testCase "a pre-effect proof cannot authorize settled close, and its short close releases mode last" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                proof <- sweep store project
                outcome <-
                    withHarnessRoot store project ProjectUp (satisfiedPreconditions project) proof $
                        \root -> do
                            let run = harnessRootRunId root
                                unbound = harnessRootUnboundLease root
                            _ <-
                                expectRight
                                    =<< persistCanonicalPlanSnapshot unbound 1 modeTestSnapshot
                            verifyPlanSnapshot unbound $ \snapshot -> do
                                bound <- expectRight =<< bindRunLease unbound snapshot pure
                                preEffect <-
                                    expectRight
                                        =<< verifyBoundRunHasNoProjectResourcesAcquired bound
                                withProtectedEntry' store $ \session -> do
                                    sessions <-
                                        expectRight =<< verifyAllSessionsClosedHere session
                                    refused <-
                                        authorizeHarnessClose
                                            session
                                            project
                                            (currentHarnessCloseRoot root)
                                            (harnessRootModeLease root)
                                            bound
                                            sessions
                                            preEffect
                                            11
                                    case refused of
                                        Left (ModeClosureMismatch expected observed) -> do
                                            expected @?= "settled destroy"
                                            observed @?= "pre-effect refusal"
                                        other ->
                                            assertFailure
                                                ("expected settled-close evidence refusal, got " <> show other)
                                    expectRight
                                        =<< closeHarnessRun
                                            session
                                            project
                                            (currentHarnessCloseRoot root)
                                            (harnessRootModeLease root)
                                            preEffect
                                    pure (Right (runIdText run))
                firstRun <- expectRight outcome
                -- Mode was released only after the lease closed, so a fresh run
                -- can now take it.
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                next <- either (assertFailure . show) pure swept
                again <-
                    withHarnessRoot
                        store
                        project
                        ProjectUp
                        (satisfiedPreconditions project)
                        next
                        (\root -> pure (Right (runIdText (harnessRootRunId root))))
                secondRun <- expectRight again
                assertBool
                    "successive Harness acquisitions have distinct run identities"
                    (firstRun /= secondRun)
    ]

-- | The plan digest the close cases journal under.
closePlanDigest :: Text
closePlanDigest = canonicalPlanSnapshotDigest modeTestSnapshot

modeTestSnapshot :: CanonicalPlanSnapshot
modeTestSnapshot = canonicalTestSnapshot "config-1"

{- | The completeness proof at this spec's plan digest, with its phantom indices
pinned so each use site does not need an annotation.
-}
verifyAllSessionsClosedHere ::
    ProtectedSession session ->
    IO (Either SessionError (VerifiedAllSessionsClosed scope planId))
verifyAllSessionsClosedHere session = verifyAllSessionsClosed session closePlanDigest

-- Fixtures -------------------------------------------------------------------------------------

withStore :: (ProtectedStore -> IO ()) -> IO ()
withStore use =
    withSystemTempDirectory "hostbootstrap-authority" $ \directory -> do
        opened <- openProtectedStore (directory </> "authority")
        case opened of
            Left failure -> assertFailure (show failure)
            Right store -> use store

withRoot ::
    ProtectedStore ->
    ProjectVerb verb ->
    ( forall projectId session brokerGeneration.
      InstalledProjectIdentity projectId ->
      ProtectedSession session ->
      RootInvocationAuthority (Production projectId) brokerGeneration verb ->
      IO (Either AuthorityError ())
    ) ->
    IO ()
withRoot store verb use = do
    outcome <- Fixture.withFixtureInstalledProject $ \project ->
        withProductionRoot store project verb $ \root -> do
            admitted <-
                withAuthorityEntry store $ \session ->
                    use project session (productionRootAuthority root)
            pure (either (Left . ModeAuthorityFailure) Right admitted)
    case outcome of
        Left failure -> assertFailure (show failure)
        Right () -> pure ()

{- | The authority-error flavoured protected bracket. 'withProtectedEntry'
reports store failures, so a case that works in authority errors wraps them.
-}
withAuthorityEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either AuthorityError result)) ->
    IO (Either AuthorityError result)
withAuthorityEntry store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    pure (either (Left . AuthorityStoreFailure) id outcome)

{- | The mode-error flavoured protected bracket, so a mode case can run several
record operations under one exclusive entry.
-}
withProtectedEntry' ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either ModeError result)) ->
    IO (Either ModeError result)
withProtectedEntry' store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    pure (either (Left . ModeStoreFailure) id outcome)

canonicalTestSnapshot :: Text -> CanonicalPlanSnapshot
canonicalTestSnapshot configDigest =
    canonicalTestSnapshotFor configDigest testStepPlan

canonicalTestSnapshotFor :: Text -> StepPlan -> CanonicalPlanSnapshot
canonicalTestSnapshotFor configDigest plan =
    withProductionProjectCodec @Fixture.ProjectConfig @Fixture.FixtureProject $ \codec ->
        withLifecyclePlanForConfig codec configDigest plan lifecyclePlanSnapshot

testStepPlan :: StepPlan
testStepPlan =
    either
        (error . show)
        id
        ( mkStepPlan
            [ descendsVia localContext (deployVMStep "vm" (StepFrame "host" "Host") (const (pure StepChanged)))
            , contextInitStep "context" (StepFrame "vm" "VM") (const (pure StepChanged))
            ]
        )

alternateTestStepPlan :: StepPlan
alternateTestStepPlan =
    either
        (error . show)
        id
        (mkStepPlan [contextInitStep "context" (StepFrame "host" "Host") (const (pure StepChanged))])

satisfiedPreconditions :: InstalledProjectIdentity projectId -> HarnessPreconditions
satisfiedPreconditions project =
    harnessPreconditions project "/nonexistent-hostbootstrap-dir" (pure False)

{- | A fold callback that resolves nothing, so the sweep must refuse rather than
report a vacuous success.
-}
neverResolves :: VerifiedIncompleteRunLease projectId -> IO (Either ModeError ())
neverResolves _ = pure (Right ())

{- | Resolve a reopened run the one way this sprint can prove is safe: its own
records show it acquired nothing, so its lease and mode close under the
reopening's own 'RecoveredHarnessClose' authority.
-}
resolveNothingAcquired ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    AbandonedHarnessRun projectId oldRunId specDigest planDigest planId brokerGeneration ->
    IO (Either ModeError ())
resolveNothingAcquired store project reopened = do
    proved <-
        verifyBoundRunHasNoProjectResourcesAcquired
            (abandonedHarnessBoundLease reopened)
    case proved of
        Left failure -> pure (Left failure)
        Right evidence ->
            withProtectedEntry' store $ \session ->
                closeHarnessRun
                    session
                    project
                    (abandonedHarnessCloseRoot reopened)
                    (abandonedHarnessModeLease reopened)
                    evidence

{- | Open a harness run and abandon it: the mode and unbound lease are recorded
and never closed, exactly as a hard kill leaves them.
-}
abandonHarnessRun :: ProtectedStore -> InstalledProjectIdentity projectId -> IO Text
abandonHarnessRun store project = do
    proof <- sweep store project
    outcome <-
        withHarnessRoot
            store
            project
            ProjectUp
            (satisfiedPreconditions project)
            proof
            (\root -> pure (Right (runIdText (harnessRootRunId root))))
    either (assertFailure . show) pure outcome

-- | Seed one acquisition-shaped row without relying on its payload codec.
writeAcquisitionShapedRecord ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    Text ->
    Text ->
    ByteString.ByteString ->
    IO RecordKey
writeAcquisitionShapedRecord store project run suffix payload = do
    key <-
        expectKey
            ( "acquisition."
                <> installedProjectName project
                <> recordTupleSeparator
                <> run
                <> recordTupleSeparator
                <> suffix
            )
    written <-
        withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord session key ExpectAbsent payload
    _ <- either (assertFailure . show) pure written
    pure key

{- | Exact key/version/payload image used to prove a refused sweep changed
neither the offending row nor its mode and lease ownership records.
-}
protectedStoreImage :: ProtectedStore -> IO [(Text, Word64, ByteString.ByteString)]
protectedStoreImage store = do
    observed <-
        withProtectedEntry store $ \session -> do
            listed <- listProtectedRecords session
            case listed of
                Left failure -> pure (Left failure)
                Right keys -> do
                    records <- traverse (readProtectedRecord session) keys
                    pure $ do
                        present <- sequence records
                        Right
                            [ ( recordKeyText key
                              , recordVersionWord (protectedRecordVersion record)
                              , protectedRecordBytes record
                              )
                            | (key, Just record) <- zip keys present
                            ]
    either (assertFailure . show) pure observed

-- | The empty-sweep proof a fresh store always yields.
sweep ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    IO (ClosedAbandonedHarnessRuns projectId)
sweep store project = do
    swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
    either (assertFailure . show) pure swept

{- | The same, but bound to a plan snapshot before the kill. It also hands back
the broker generation the abandoned run held, so a reopening can be shown to run
on a strictly fresher one.
-}
abandonBoundHarnessRun ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    IO (Text, Word64)
abandonBoundHarnessRun store project =
    abandonBoundHarnessRunWith store project (\_ -> pure (Right ()))

abandonBoundHarnessRunWith ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    (forall runId. RunId runId -> IO (Either ModeError ())) ->
    IO (Text, Word64)
abandonBoundHarnessRunWith store project afterBinding = do
    proof <- sweep store project
    outcome <-
        withHarnessRoot
            store
            project
            ProjectUp
            (satisfiedPreconditions project)
            proof
            ( \root -> do
                let run = harnessRootRunId root
                    unbound = harnessRootUnboundLease root
                persisted <- persistCanonicalPlanSnapshot unbound 1 modeTestSnapshot
                case persisted of
                    Left failure -> pure (Left failure)
                    Right () ->
                        verifyPlanSnapshot unbound $ \snapshot -> do
                            bound <-
                                bindRunLease
                                    unbound
                                    snapshot
                                    ( \_ ->
                                        pure
                                            ( runIdText run
                                            , brokerEpochWord
                                                (projectModeLeaseEpoch (harnessRootModeLease root))
                                            )
                                    )
                            result <- expectRight bound
                            continued <- afterBinding run
                            pure (fmap (const result) continued)
            )
    either (assertFailure . show) pure outcome

-- Helpers ---------------------------------------------------------------------------------------

{- | Persist a run's plan snapshot and hand back the verified value, which is
the only thing 'bindRunLease' accepts.
-}

-- ---------------------------------------------------------------------------
-- Plan migration

{- | The revision-carry algebra: the profile, the candidate, the freeze, the
activation compare-and-swap, and the configless post-CAS recovery.

The cases are ordered the way the protocol is, and each one names the state a
crash at that point would leave — because the whole reason the protocol has this
many durable steps is that every gap between two of them has to be recoverable.
-}
migrationCases :: [TestTree]
migrationCases =
    [ testCase "the migration profile refuses a recovery-owed binding" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withBoundSnapshot root $ \snapshot -> do
                            let unbound = productionRootUnboundLease root
                            -- Bind once so the second binding is the
                            -- abandoned-invocation case.
                            _ <- expectRight =<< bindRunLease unbound snapshot (\_ -> pure ())
                            second <- bindRunLease unbound snapshot (\_ -> pure ())
                            case second of
                                -- An already-bound lease yields no
                                -- NormalActiveRecovery at all, so a migration
                                -- cannot even be proposed from it.
                                Left _ -> pure (Right ())
                                Right () ->
                                    assertFailure "the second binding must not be fresh"
                outcome @?= Right ()
    , testCase "a migration onto the exact same canonical plan is refused before freeze" $
        Fixture.withFixtureProjectPlanRoot alternateTestStepPlan $ \store project root oldPlan -> do
            opened <-
                withPersistedPlanSnapshot
                    (productionRootAuthority root)
                    (productionRootUnboundLease root)
                    oldPlan
                    ( \verified _boundPlan _binding bound _recovery ->
                        case withProjectUpMigrationProfile (productionRootAuthority root) (productionRootModeLease root) bound verified of
                            Left failure -> pure (Left failure)
                            Right profile -> withProtectedEntry' store $ \session ->
                                withSystemTempDirectory "hostbootstrap-same-migration" $ \directory -> do
                                    rooted <- withCanonicalProjectRoot (directory </> "candidate.dhall") "." $ \candidateRoot ->
                                        withProductionProjectCodec @Fixture.ProjectConfig $ \codec -> do
                                            let value = Fixture.defaultProjectConfig (installedProjectName project) (Text.pack (canonicalProjectRootPath candidateRoot)) Context.HostOrchestrator
                                            validated <- withValidatedConfig codec value $ \wire config -> do
                                                drafts <-
                                                    either (fail . show) pure $
                                                        planDraftsFromValidatedBuilder candidateRoot config (\_ _ -> Right alternateTestStepPlan)
                                                result <- withProspectiveMigrationPlan session project profile bound codec wire config drafts $ \_plan _digest _candidate -> pure (Right ())
                                                pure $ case result of
                                                    Left (ModeSnapshotMismatch expected observed) | expected == observed -> Right ()
                                                    other -> Left (ModeInvalidIdentity (Text.pack ("expected same-plan refusal, got " <> show other)))
                                            either (fail . show) pure validated
                                    either (fail . show) pure rooted
                    )
            either (assertFailure . show) (const (pure ())) opened
    , testCase "the candidate digest is derived from exact plan bytes" $
        withMigrationProfile $ \project _ bound profile session codec wire config drafts ->
            withProspectiveMigrationPlan session project profile bound codec wire config drafts $ \plan _binding candidate -> do
                prospectiveSnapshotPlanDigest candidate @?= stablePlanSnapshotDigest (renderSnapshot plan)
                assertBool "candidate bytes were not retained" (not (ByteString.null (prospectiveSnapshotCanonicalBytes candidate)))
                pure (Right ())
    , testCase "a candidate is persisted, read back, and authorizes nothing" $
        withMigrationProfile $ \project _ bound profile session codec wire config drafts ->
            withProspectiveMigrationPlan session project profile bound codec wire config drafts $ \_plan _binding candidate -> do
                assertBool "candidate spec digest is empty" (not (Text.null (prospectiveSnapshotSpecDigest candidate)))
                -- The stable key names the run and both revisions, so a retry
                -- converges on it rather than proposing a second migration.
                stableMigrationKeyText (prospectiveSnapshotKey candidate)
                    @?= "production." <> migrationProfileOldPlanDigest profile <> "." <> prospectiveSnapshotPlanDigest candidate
                pure (Right ())
    , testCase "a conflicting candidate read-back refuses before freeze" $
        withMigrationProfile $ \project _ bound profile session codec wire config drafts -> do
            first <- withProspectiveMigrationPlan session project profile bound codec wire config drafts $ \_plan _binding _candidate -> pure (Right ())
            _ <- expectRight first
            keys <- expectRight =<< listProtectedRecords session
            key <- case filter (Text.isPrefixOf "prospective." . recordKeyText) keys of
                [found] -> pure found
                _ -> assertFailure "the prospective candidate key was not unique"
            observed <- expectRight =<< readProtectedRecord session key
            record <- maybe (assertFailure "the prospective record disappeared") pure observed
            _ <- expectRight =<< compareAndSwapProtectedRecord session key (ExpectVersion (protectedRecordVersion record)) "conflicting-candidate"
            retried <- withProspectiveMigrationPlan session project profile bound codec wire config drafts $ \_plan _binding _candidate -> pure (Right ())
            case retried of
                Left (ModeSnapshotMismatch _ _) -> pure ()
                other -> assertFailure ("expected conflicting candidate refusal, got " <> show other)
            readRecordedRevisionKind session project bound >>= (@?= NormalRevision)
            pure (Right ())
    , testCase "a config and draft digest mismatch refuses before persistence" $
        withMigrationProfile $ \project _ bound profile session codec _wire config drafts -> do
            let changed = (validatedConfigValue config){Fixture.dockerfile = "changed.Dockerfile"}
            attempted <- withValidatedConfig codec changed $ \changedWire changedConfig ->
                withProspectiveMigrationPlan session project profile bound codec changedWire changedConfig drafts $ \_plan _binding _candidate -> pure (Right ())
            outcome <- either (fail . show) pure attempted
            case outcome of
                Left (ModeInvalidIdentity _) -> pure ()
                other -> assertFailure ("expected config/draft refusal, got " <> show other)
            readRecordedRevisionKind session project bound >>= (@?= NormalRevision)
            pure (Right ())
    , testCase "freezing stops the old revision from being bindable" $
        withMigrationProfile $ \project _ bound profile session codec wire config drafts ->
            withProspectiveMigrationPlan session project profile bound codec wire config drafts $ \_plan _binding candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                retried <- expectRight =<< withPlanMigration session project profile candidate
                let stableKey = "production." <> migrationProfileOldPlanDigest profile <> "." <> prospectiveSnapshotPlanDigest candidate
                stableMigrationKeyText (frozenMigrationKey frozen) @?= stableKey
                assertBool "the frozen exact-set digest is not SHA-256" (Text.length (frozenMigrationRecordSetDigest frozen) == 64)
                frozenMigrationRecordSetDigest retried @?= frozenMigrationRecordSetDigest frozen
                rebuilt <- withRecoveredMigrationPlanSnapshot session project frozen codec wire config drafts $ \plan _binding -> do
                    stablePlanSnapshotDigest (renderSnapshot plan) @?= prospectiveSnapshotPlanDigest candidate
                    pure (Right ())
                _ <- expectRight rebuilt
                -- The recorded kind says the barrier was not crossed.
                kind <- readRecordedRevisionKind session project bound
                kind @?= IncompleteMigration stableKey
                pure (Right ())
    , testCase "the activation compare-and-swap switches the lineage and records it" $
        withMigrationProfile $ \project epoch oldBound profile session codec wire config drafts ->
            withProspectiveMigrationPlan session project profile oldBound codec wire config drafts $ \_plan _binding candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                (bound, barrier) <-
                    expectRight =<< commitMigrationActivation session project frozen epoch
                boundRunLeasePlanDigest bound @?= prospectiveSnapshotPlanDigest candidate
                migrationBarrierOldPlanDigest barrier @?= migrationProfileOldPlanDigest profile
                migrationBarrierNewPlanDigest barrier @?= prospectiveSnapshotPlanDigest candidate
                migrationBarrierRecordSetDigest barrier @?= frozenMigrationRecordSetDigest frozen
                kind <- readRecordedRevisionKind session project bound
                kind @?= CompletedMigration ("production." <> migrationProfileOldPlanDigest profile <> "." <> prospectiveSnapshotPlanDigest candidate)
                pure (Right ())
    , testCase "down cancellation restores only the old-bound lineage and converges" $
        withMigrationProfile $ \project epoch oldBound profile session codec wire config drafts ->
            withProspectiveMigrationPlan session project profile oldBound codec wire config drafts $ \_plan _binding candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                restored <- expectRight =<< cancelIncompletePlanMigrationForTeardown ProjectDown epoch session project frozen
                boundRunLeasePlanDigest restored @?= migrationProfileOldPlanDigest profile
                retried <- expectRight =<< cancelIncompletePlanMigrationForTeardown ProjectDestroy epoch session project frozen
                boundRunLeasePlanDigest retried @?= migrationProfileOldPlanDigest profile
                readRecordedRevisionKind session project restored >>= (@?= NormalRevision)
                pure (Right ())
    , testCase "commit refuses a candidate changed after freeze and retains the old lineage" $
        withMigrationProfile $ \project epoch oldBound profile session codec wire config drafts ->
            withProspectiveMigrationPlan session project profile oldBound codec wire config drafts $ \_plan _binding candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                keys <- expectRight =<< listProtectedRecords session
                candidateKey <- case filter (Text.isPrefixOf "prospective." . recordKeyText) keys of
                    [found] -> pure found
                    _ -> assertFailure "the frozen prospective candidate was not unique"
                record <-
                    maybe (assertFailure "the frozen candidate disappeared") pure
                        =<< (expectRight =<< readProtectedRecord session candidateKey)
                _ <-
                    expectRight
                        =<< compareAndSwapProtectedRecord
                            session
                            candidateKey
                            (ExpectVersion (protectedRecordVersion record))
                            "changed-after-freeze"
                committed <- commitMigrationActivation session project frozen epoch
                case committed of
                    Left (ModeMalformedRecord _) -> pure ()
                    other -> assertFailure ("changed frozen candidate committed: " <> show other)
                readRecordedRevisionKind session project oldBound
                    >>= (@?= IncompleteMigration (stableMigrationKeyText (frozenMigrationKey frozen)))
                pure (Right ())
    , testCase "commit refuses a resource set changed after freeze" $
        withMigrationProfile $ \project epoch oldBound profile session codec wire config drafts ->
            withProspectiveMigrationPlan session project profile oldBound codec wire config drafts $ \_plan _binding candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                keys <- expectRight =<< listProtectedRecords session
                resourceKey <- case filter (Text.isPrefixOf "resource." . recordKeyText) keys of
                    [found] -> pure found
                    _ -> assertFailure "the frozen resource set was not a singleton"
                record <-
                    maybe (assertFailure "the frozen resource disappeared") pure
                        =<< (expectRight =<< readProtectedRecord session resourceKey)
                _ <-
                    expectRight
                        =<< compareAndSwapProtectedRecord
                            session
                            resourceKey
                            (ExpectVersion (protectedRecordVersion record))
                            "changed-after-freeze"
                committed <- commitMigrationActivation session project frozen epoch
                case committed of
                    Left (ModeMalformedRecord _) -> pure ()
                    other -> assertFailure ("changed frozen set committed: " <> show other)
                pure (Right ())
    , testCase "activation is idempotent, so a crash after the swap converges" $
        withMigrationProfile $ \project epoch oldBound profile session codec wire config drafts ->
            withProspectiveMigrationPlan session project profile oldBound codec wire config drafts $ \_plan _binding candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                (_, first) <-
                    expectRight =<< commitMigrationActivation session project frozen epoch
                -- Re-running against the same frozen capability observes the
                -- already-bound candidate and completes rather than refusing.
                (_, second) <-
                    expectRight =<< commitMigrationActivation session project frozen epoch
                migrationBarrierNewPlanDigest first @?= migrationBarrierNewPlanDigest second
                pure (Right ())
    , testCase "activating the plan admits the new revision's broker" $
        withMigrationProfile $ \project epoch oldBound profile session codec wire config drafts ->
            withProspectiveMigrationPlan session project profile oldBound codec wire config drafts $ \candidatePlan candidateBinding candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                (bound, barrier) <-
                    expectRight =<< commitMigrationActivation session project frozen epoch
                admission <- expectRight =<< withFrozenMigrationResourceSet session frozen epoch (activateMigratedPlan session barrier bound epoch candidatePlan candidateBinding)
                admissionPlanDigest admission @?= prospectiveSnapshotPlanDigest candidate
                pure (Right ())
    , testCase "completed-migration recovery loads the candidate from the durable key" $
        withMigrationProfile $ \project epoch oldBound profile session codec wire config drafts ->
            withProspectiveMigrationPlan session project profile oldBound codec wire config drafts $ \_plan _binding candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                (bound, _) <-
                    expectRight =<< commitMigrationActivation session project frozen epoch
                recovered <-
                    withCompletedMigrationRecovery session project bound $ \recoveryProfile barrier recoveredSnapshot oldSnapshot recoveredSet -> do
                        -- Both digests came from the stable key and the lease
                        -- record; no config was consulted.
                        migrationBarrierOldPlanDigest barrier @?= migrationProfileOldPlanDigest profile
                        migrationBarrierNewPlanDigest barrier @?= prospectiveSnapshotPlanDigest candidate
                        planSnapshotPlanDigest recoveredSnapshot @?= prospectiveSnapshotPlanDigest candidate
                        case withMigratedRecoveredProjectFrames recoveredSnapshot oldSnapshot recoveredSet (\_ count -> count + (1 :: Int)) 0 of
                            Left failure -> assertFailure (show failure)
                            Right count -> count @?= 1
                        rebuilt <- withCompletedMigrationPlan session project recoveryProfile bound codec wire config drafts $ \rebuiltBarrier rebuiltPlan rebuiltBinding -> do
                            migrationBarrierNewPlanDigest rebuiltBarrier @?= prospectiveSnapshotPlanDigest candidate
                            stablePlanSnapshotDigest (renderSnapshot rebuiltPlan) @?= prospectiveSnapshotPlanDigest candidate
                            fmap (fmap (const ())) (activateMigratedPlan session rebuiltBarrier bound epoch rebuiltPlan rebuiltBinding recoveredSet)
                        pure rebuilt
                recovered @?= Right ()
                pure (Right ())
    , testCase "completed-plan reconstruction refuses changed inputs and missing candidate state" $
        withMigrationProfile $ \project epoch oldBound profile session codec wire config drafts ->
            withProspectiveMigrationPlan session project profile oldBound codec wire config drafts $ \candidatePlan _binding candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                (bound, _) <- expectRight =<< commitMigrationActivation session project frozen epoch
                withCompletedMigrationRecovery session project bound $ \recoveryProfile _barrier _recoveredSnapshot _oldSnapshot _recoveredSet -> do
                    let changed = (validatedConfigValue config){Fixture.dockerfile = "changed-after-commit.Dockerfile"}
                    changedAttempt <- withValidatedConfig codec changed $ \changedWire changedConfig ->
                        withCompletedMigrationPlan session project recoveryProfile bound codec changedWire changedConfig drafts $ \_ _ _ -> pure (Right ())
                    changedResult <- either (fail . show) pure changedAttempt
                    case changedResult of
                        Left _ -> pure ()
                        other -> assertFailure ("changed config reconstructed the completed plan: " <> show other)
                    withSystemTempDirectory "hostbootstrap-changed-migration-draft" $ \directory -> do
                        rooted <- withCanonicalProjectRoot (directory </> "candidate.dhall") (stablePlanSnapshotRoot (renderSnapshot candidatePlan)) $ \candidateRoot -> do
                            changedDrafts <-
                                either (fail . show) pure $
                                    planDraftsFromValidatedBuilder candidateRoot config (\_ _ -> Right testStepPlan)
                            changedDraftResult <- withCompletedMigrationPlan session project recoveryProfile bound codec wire config changedDrafts $ \_ _ _ -> pure (Right ())
                            case changedDraftResult of
                                Left (ModeInvalidIdentity _) -> pure (Right ())
                                other -> pure (Left (ModeInvalidIdentity (Text.pack ("changed draft reconstructed completed plan: " <> show other))))
                        either (fail . show) pure rooted >>= expectRight
                    keys <- expectRight =<< listProtectedRecords session
                    candidateKey <- case filter (Text.isPrefixOf "prospective." . recordKeyText) keys of
                        [found] -> pure found
                        _ -> assertFailure "the completed candidate key was not unique"
                    observed <- expectRight =<< readProtectedRecord session candidateKey
                    record <- maybe (assertFailure "the completed candidate disappeared") pure observed
                    _ <- expectRight =<< compareAndSwapProtectedRecord session candidateKey (ExpectVersion (protectedRecordVersion record)) "unknown-candidate-version"
                    malformed <- withCompletedMigrationPlan session project recoveryProfile bound codec wire config drafts $ \_ _ _ -> pure (Right ())
                    case malformed of
                        Left (ModeMalformedRecord _) -> pure ()
                        other -> assertFailure ("malformed candidate was accepted: " <> show other)
                    malformedRecord <- maybe (assertFailure "the malformed candidate disappeared") pure =<< (expectRight =<< readProtectedRecord session candidateKey)
                    _ <- expectRight =<< compareAndDeleteProtectedRecord session candidateKey (ExpectVersion (protectedRecordVersion malformedRecord))
                    missing <- withCompletedMigrationPlan session project recoveryProfile bound codec wire config drafts $ \_ _ _ -> pure (Right ())
                    case missing of
                        Left (ModeSnapshotMissing _) -> pure ()
                        other -> assertFailure ("missing candidate was accepted: " <> show other)
                    boundRunLeasePlanDigest bound @?= prospectiveSnapshotPlanDigest candidate
                    pure (Right ())
    , testCase "a run with no completed migration has nothing to recover" $
        withMigrationProfile $ \project _ bound _profile session _codec _wire _config _drafts -> do
            outcome <-
                withCompletedMigrationRecovery
                    session
                    project
                    bound
                    (\_ _ _ _ _ -> pure (Right ()))
            case outcome of
                Left (ModeWrongRecoveryScope expected observed) -> do
                    expected @?= "completed-migration"
                    observed @?= "normal revision"
                    pure (Right ())
                other -> assertFailure ("expected a wrong-scope refusal, got " <> show other)
    ]

withMigrationProfile ::
    ( forall projectId brokerGeneration oldSpecDigest oldPlanDigest session newSpecDigest configDigest configId.
      InstalledProjectIdentity projectId ->
      BrokerEpoch brokerGeneration ->
      BoundRunLease
        (Production projectId)
        oldSpecDigest
        oldPlanDigest
        brokerGeneration ->
      ProjectUpMigrationProfile
        projectId
        oldSpecDigest
        oldPlanDigest
        brokerGeneration ->
      ProtectedSession session ->
      ProjectCodec (Production projectId) newSpecDigest Fixture.ProjectConfig ->
      VerifiedConfigWire (Production projectId) configDigest configId ->
      ValidatedConfig (Production projectId) newSpecDigest configId (Fixture.ProjectConfig (Production projectId)) ->
      NonEmpty (PlanDraft (Production projectId) newSpecDigest (Fixture.ProjectConfig (Production projectId))) ->
      IO (Either ModeError ())
    ) ->
    IO ()
withMigrationProfile use =
    Fixture.withFixtureProjectPlanRoot migrationOldStepPlan $ \store project root oldPlan -> do
        outcome <-
            withPersistedPlanSnapshot
                (productionRootAuthority root)
                (productionRootUnboundLease root)
                oldPlan
                ( \snapshot _boundPlan _binding bound _recovery -> do
                    writeMigrationResourceRecords store oldPlan
                    case withProjectUpMigrationProfile (productionRootAuthority root) (productionRootModeLease root) bound snapshot of
                        Left failure -> pure (Left failure)
                        Right profile ->
                            withProtectedEntry' store $ \session ->
                                withSystemTempDirectory "hostbootstrap-migration-candidate" $ \directory -> do
                                    rooted <- withCanonicalProjectRoot (directory </> "candidate.dhall") "." $ \candidateRoot ->
                                        withProductionProjectCodec @Fixture.ProjectConfig $ \codec -> do
                                            let value = Fixture.defaultProjectConfig (installedProjectName project) (Text.pack (canonicalProjectRootPath candidateRoot)) Context.HostOrchestrator
                                            validated <- withValidatedConfig codec value $ \wire config -> do
                                                drafts <-
                                                    either (fail . show) pure $
                                                        planDraftsFromValidatedBuilder candidateRoot config (\_ _ -> Right migrationCandidateStepPlan)
                                                use project (rootAuthorityEpoch (productionRootAuthority root)) bound profile session codec wire config drafts
                                            either fail pure validated
                                    either (fail . show) pure rooted
                )
        either (assertFailure . show) (either (assertFailure . show) pure) outcome

migrationOldStepPlan :: StepPlan
migrationOldStepPlan =
    either (error . show) id $
        mkStepPlan [deployKindStep "cluster" (StepFrame "host" "Host") (const (pure StepChanged))]

migrationCandidateStepPlan :: StepPlan
migrationCandidateStepPlan =
    either (error . show) id $
        mkStepPlan
            [ implementedAt
                (either error id (mkStepImplementationRevision 2))
                (deployKindStep "cluster" (StepFrame "host" "Host") (const (pure StepChanged)))
            ]

writeMigrationResourceRecords ::
    ProtectedStore ->
    ProjectPlan scope specDigest planId configId cfg ->
    IO ()
writeMigrationResourceRecords store plan = case NonEmpty.toList (forward plan) of
    [node] ->
        either (assertFailure . show) id $
            withPlannedResourceOfKind plan ClusterResourceKind (plannedStepOperationKey node) $ \planned -> do
                let lifecycle = lifecyclePlanFromProjectPlan plan
                    operation = Text.pack (operationKeyText (plannedStepOperationKey node))
                bytes <-
                    either (assertFailure . show) pure $
                        renderResourceRecordBundle lifecycle planned 1 operation 1 "running" "adapter-v1" True
                rawKey <-
                    either (assertFailure . show) pure $
                        resourceRecordKey (lifecyclePlanDigest lifecycle) (plannedResourceFrame planned) (plannedResourceKey planned)
                key <- either (assertFailure . show) pure (mkRecordKey rawKey)
                written <- withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent bytes
                either (assertFailure . show) (const (pure ())) written
    _ -> assertFailure "the migration old-plan fixture is not a singleton"

-- | The recorded migration side of the barrier, read back off the durable record.
readRecordedRevisionKind ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    BoundRunLease
        (Production projectId)
        specDigest
        planDigest
        brokerGeneration ->
    IO OpenRevisionKind
readRecordedRevisionKind session project bound = do
    observed <- readRecordedOpenRevisionKind session project bound
    expectRight observed

withBoundSnapshot ::
    ProductionRoot projectId brokerGeneration verb ->
    ( forall specDigest planDigest.
      VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withBoundSnapshot root use = do
    let unbound = productionRootUnboundLease root
    persisted <- persistCanonicalPlanSnapshot unbound 1 modeTestSnapshot
    case persisted of
        Left failure -> pure (Left failure)
        Right () -> verifyPlanSnapshot unbound use

withFreshHarnessRoot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ( forall runId brokerGeneration.
      HarnessRoot projectId runId brokerGeneration VerbUp ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withFreshHarnessRoot store project use = do
    swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
    case swept of
        Left failure -> pure (Left failure)
        Right proof ->
            withHarnessRoot
                store
                project
                ProjectUp
                (satisfiedPreconditions project)
                proof
                use

readModeRecord ::
    ProtectedStore ->
    RecordKey ->
    IO (Either ModeError (Maybe ProtectedRecord))
readModeRecord store key =
    withProtectedEntry' store $ \session -> do
        observed <- readProtectedRecord session key
        pure (either (Left . ModeStoreFailure) Right observed)

expectCloseKey :: Text -> IO InvocationCloseKey
expectCloseKey raw = case mkInvocationCloseKey raw of
    Left failure -> assertFailure (show failure)
    Right key -> pure key

expectKey :: Text -> IO RecordKey
expectKey raw = case mkRecordKey raw of
    Left failure -> assertFailure (show failure)
    Right key -> pure key

authorityFacadeExports :: Text -> Either Text [Text]
authorityFacadeExports source = do
    afterMarker <-
        maybe
            (Left "the Authority module header is absent")
            (Right . Text.drop (Text.length marker))
            (nonEmptySuffix marker source)
    let (body, closing) = Text.breakOn "\n) where" afterMarker
    if Text.null closing
        then Left "the Authority export list terminator is absent"
        else
            Right
                [ Text.dropWhileEnd (== ',') (Text.strip line)
                | line <- Text.lines body
                , not (Text.null (Text.strip line))
                ]
  where
    marker = "module HostBootstrap.Authority ("
    nonEmptySuffix needle haystack =
        let suffix = snd (Text.breakOn needle haystack)
         in if Text.null suffix then Nothing else Just suffix

isLeft :: Either failure success -> Bool
isLeft (Left _) = True
isLeft _ = False

isRight :: Either failure success -> Bool
isRight (Right _) = True
isRight _ = False

isPrefix :: Text -> Text -> Bool
isPrefix = Text.isPrefixOf

-- | What a separate process observed when it attempted the same entry.
data EntryProbe = Acquired | Contended | ProbeFailed String
    deriving (Eq, Show)

{- | Attempt the store's exclusive entry from a *different process*, using the
production primitive rather than a lookalike: the test executable re-invokes
itself with the probe argument 'Spec.hs' dispatches.
-}
probeEntry :: FilePath -> FilePath -> IO EntryProbe
probeEntry executable storeRoot = do
    (code, out, err) <-
        readProcessWithExitCode executable ["--hostbootstrap-protected-entry-probe", storeRoot] ""
    pure $ case code of
        ExitSuccess -> Acquired
        ExitFailure 3 -> Contended
        ExitFailure other -> ProbeFailed (show other <> " " <> out <> " " <> err)

{- | What a separate process observed when it attempted a lifecycle profile
against this project's store. 'ProfileRefusedBy' carries the mode name the
competitor was refused by — its own observation, not the holder's state.
-}
data ProfileProbe
    = ProfileAcquired
    | ProfileRefusedBy Text
    | ProfileProbeFailed String
    deriving (Eq, Show)

-- | Attempt a lifecycle profile from a *different process*.
probeProfile :: FilePath -> FilePath -> String -> IO ProfileProbe
probeProfile executable storeRoot profile =
    withSystemTempDirectory "hostbootstrap-profile-probe" $ \directory -> do
        let reasonPath = directory </> "reason"
        (code, out, err) <-
            readProcessWithExitCode
                executable
                ["--hostbootstrap-mode-profile-probe", storeRoot, profile, reasonPath]
                ""
        case code of
            ExitSuccess -> pure ProfileAcquired
            ExitFailure 3 -> do
                reason <- readFile reasonPath
                pure $ case Text.splitOn "\t" (Text.pack reason) of
                    (held : _) -> ProfileRefusedBy held
                    [] -> ProfileProbeFailed reason
            ExitFailure other -> do
                reason <- readReasonIfPresent reasonPath
                pure (ProfileProbeFailed (show other <> " " <> reason <> " " <> out <> " " <> err))

readReasonIfPresent :: FilePath -> IO String
readReasonIfPresent path = do
    present <- doesFileExist path
    if present then readFile path else pure ""

protectedRecordNameCases :: [TestTree]
protectedRecordNameCases =
    [ testCase "record names refuse every ambiguous segment" $
        forM_ ["", "a//b", "/a", "a/", "a.b", "a.b:c", ":b", "a:", "a:.b", "a:b.", "a:b./c", "a:b..c", "a:b:c", "a b", "é", "namespace:٣"] $ \identity ->
            case mkRecordName identity of
                Left (ProtectedInvalid _) -> pure ()
                other -> assertFailure ("expected an ambiguous-name refusal for " <> show identity <> ", got " <> show other)
    , testCase "record keys are ASCII, case-free and filesystem-distinct" $ do
        forM_ ["Alpha", "é", "٣", "nul", "CON", "com1.rec", "lpt9.extra", "a.", Text.replicate 201 "a"] $ \raw ->
            case mkRecordKey raw of
                Left (ProtectedInvalid _) -> pure ()
                other -> assertFailure ("expected a filesystem-key refusal for " <> show raw <> ", got " <> show other)
        forM_ ["alpha-1_b.c", "com10", "prefix.nul", Text.replicate 200 "a"] $ \raw ->
            fmap recordKeyText (mkRecordKey raw) @?= Right raw
    , testCase "record names are injective and invertible" $ do
        let admitted =
                [ (identity, encoded)
                | identity <- recordNameEnumerationInputs "ab.:A_"
                , Right encoded <- [mkRecordName identity]
                ]
            collisions =
                Map.filter ((> 1) . length)
                    (Map.fromListWith (<>) [(Text.toLower encoded, [identity]) | (identity, encoded) <- admitted])
        assertBool "the enumeration admitted no identities" (not (null admitted))
        forM_ admitted $ \(identity, encoded) -> do
            recordNameIdentity encoded @?= identity
            assertBool "an encoded identity contains the tuple separator" (not (recordTupleSeparator `Text.isInfixOf` encoded))
        collisions @?= Map.empty
    , testCase "scalar identity fields refuse path injection and share the canonical segment codec" $ do
        assertBool "the namespaced path is a valid whole identity" (isRight (mkRecordName "cluster:a/b"))
        case mkRecordSegment "cluster:a/b" of
            Left (ProtectedInvalid _) -> pure ()
            other -> assertFailure ("the scalar field admitted a path: " <> show other)
        mkRecordSegment "Cluster:Build_A.v2" @?= mkRecordName "Cluster:Build_A.v2"
    , testCase "case-variant record names stay distinct" $ do
        let encodings =
                [ ("project:Build", "project._build")
                , ("project:build", "project.build")
                , ("a_b", "a__b")
                , ("aB", "a_b")
                , ("Project:Build_A/Core:Run", "_project._build___a.._core._run")
                ]
        forM_ encodings $ \(identity, encoded) -> do
            mkRecordName identity @?= Right encoded
            recordNameIdentity encoded @?= identity
        upper <- expectRight (mkRecordName "project:Build")
        lower <- expectRight (mkRecordName "project:build")
        underscore <- expectRight (mkRecordName "a_b")
        escaped <- expectRight (mkRecordName "aB")
        assertBool "case folding merged the project identities" (Text.toLower upper /= Text.toLower lower)
        assertBool "the underscore collided with an uppercase escape" (Text.toLower underscore /= Text.toLower escaped)
    , testCase "case-variant identities keep separate durable records" $
        withStore $ \store -> do
            let identities =
                    [ ("project:Build", "uppercase operation")
                    , ("project:build", "lowercase operation")
                    , ("a_b", "literal underscore")
                    , ("aB", "escaped uppercase")
                    ]
            forM_ identities $ \(identity, bytes) -> do
                key <- expectRight (mkRecordName identity >>= mkRecordKey)
                written <- withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent bytes
                recordVersionWord <$> written @?= Right 1
            forM_ identities $ \(identity, bytes) -> do
                key <- expectRight (mkRecordName identity >>= mkRecordKey)
                observed <- withProtectedEntry store $ \session -> readProtectedRecord session key
                fmap (fmap protectedRecordBytes) observed @?= Right (Just bytes)
            listed <- withProtectedEntry store listProtectedRecords
            length <$> listed @?= Right (length identities)
    ]

-- A source guard holds ordering and cleanup scope. Host power loss and a
-- mid-write disk failure cannot be reproduced through the store's public API.
protectedDurabilityCases :: [TestTree]
protectedDurabilityCases =
    [ testCase "a maximum-length record key publishes and replaces beyond MAX_PATH" $
        withSystemTempDirectory "hostbootstrap-long-record" $ \temporary -> do
            let root = temporary </> ("store-" <> replicate 80 'x')
                rawKey = Text.replicate 200 "a"
                destination = root </> "records" </> (Text.unpack rawKey <> ".rec")
            assertBool "the fixture does not cross the Windows path bound" (length destination > 260)
            store <- expectRight =<< openProtectedStore root
            key <- expectKey rawKey
            first <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent "first complete record")
            second <- expectRight =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key (ExpectVersion first) "replacement complete record")
            recordVersionWord second @?= 2
            observed <- withProtectedEntry store (\session -> readProtectedRecord session key)
            fmap (fmap protectedRecordBytes) observed @?= Right (Just "replacement complete record")
            reopened <- expectRight =<< openProtectedStore root
            protectedStoreIdentity reopened @?= protectedStoreIdentity store
            assertNoRecordTemporaries store
    , testCase "publishBytes syncs before it renames and cleans up every failure" $ do
        source <-
            SourceGuard.withPackageSourceIn ["internal", "ownership"] $ \_ sourceRoot ->
                readFile (sourceRoot </> "HostBootstrap" </> "Protected.hs")
        let publisher =
                [ "publishBytes :: FilePath -> ByteString -> IO ()"
                , "publishBytes destination bytes = do"
                , "stamp <- getMonotonicTimeNSec"
                , "let temporary = destination <.> (\"tmp-\" <> showHex64 stamp)"
                , "( do"
                , "withFile temporary IO.WriteMode $ \\handle -> do"
                , "ByteString.hPut handle bytes"
                , "hFlush handle"
                , "syncPublishedFile temporary"
                , "renamePublishedFile temporary destination"
                , "syncPublishedParent destination"
                , ") `onException` Safe.catchIO (removeFile temporary) (const (pure ()))"
                , "syncPublishedFile :: FilePath -> IO ()"
                ]
            platformSync =
                [ "syncPublishedFile :: FilePath -> IO ()"
                , "#if defined(mingw32_HOST_OS)"
                , "syncPublishedFile path = do"
                , "nativePath <- windowsPublishedPath path"
                , "bracket (createFile nativePath gENERIC_WRITE fILE_SHARE_READ Nothing oPEN_EXISTING fILE_ATTRIBUTE_NORMAL Nothing) closeHandle flushFileBuffers"
                , "#else"
                , "syncPublishedFile path ="
                , "bracket (openFd path ReadWrite defaultFileFlags{cloexec = True}) closeFd syncPublishedDescriptor"
                , "#endif"
                , "renamePublishedFile :: FilePath -> FilePath -> IO ()"
                , "#if defined(mingw32_HOST_OS)"
                , "renamePublishedFile source destination = do"
                , "nativeSource <- windowsPublishedPath source"
                , "nativeDestination <- windowsPublishedPath destination"
                , "moveFileEx nativeSource (Just nativeDestination) (mOVEFILE_REPLACE_EXISTING .|. moveFileWriteThrough)"
                , "windowsPublishedPath :: FilePath -> IO FilePath"
                , "windowsPublishedPath path"
                , "| isPrefixOf \"\\\\\\\\?\\\\\" path || isPrefixOf \"\\\\\\\\.\\\\\" path = pure path"
                , "| otherwise = do"
                , "absolute <- getFullPathName path"
                , "pure $"
                , "if isPrefixOf \"\\\\\\\\\" absolute"
                , "then \"\\\\\\\\?\\\\UNC\\\\\" <> drop 2 absolute"
                , "else \"\\\\\\\\?\\\\\" <> absolute"
                , "foreign import capi unsafe \"windows.h value MOVEFILE_WRITE_THROUGH\""
                , "moveFileWriteThrough :: MoveFileFlag"
                , "#else"
                , "renamePublishedFile = renameFile"
                , "#endif"
                , "syncPublishedParent :: FilePath -> IO ()"
                , "#if defined(mingw32_HOST_OS)"
                , "syncPublishedParent _destination = pure ()"
                , "#else"
                , "syncPublishedParent destination = do"
                , "bracket (openFd (takeDirectory destination) ReadOnly defaultFileFlags{cloexec = True}) closeFd fileSynchronise"
                , "#if defined(darwin_HOST_OS)"
                , "syncPublishedFile destination"
                , "#endif"
                , "#endif"
                , "#if !defined(mingw32_HOST_OS)"
                , "syncPublishedDescriptor :: Fd -> IO ()"
                , "#if defined(darwin_HOST_OS)"
                , "syncPublishedDescriptor (Fd descriptor) ="
                , "throwErrnoIfMinus1_ \"fcntl(F_FULLFSYNC)\" (c_fcntlFullSync descriptor fullFsyncCommand)"
                , "foreign import capi safe \"fcntl.h fcntl\""
                , "c_fcntlFullSync :: CInt -> CInt -> IO CInt"
                , "foreign import capi unsafe \"fcntl.h value F_FULLFSYNC\""
                , "fullFsyncCommand :: CInt"
                , "#else"
                , "syncPublishedDescriptor = fileSynchronise"
                , "#endif"
                , "#endif"
                , "data ProtectedError"
                ]
        -- Both declaration boundaries are included: a write before the handler,
        -- an early close/sync return, or a swallowed sync failure changes the
        -- complete action, rather than merely leaving ordered names elsewhere.
        forM_ [publisher, platformSync] $ \fragment ->
            SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens (unlines fragment)) source @?= 1
    ]

assertNoRecordTemporaries :: ProtectedStore -> IO ()
assertNoRecordTemporaries store = do
    entries <- listDirectory (protectedStoreRoot store </> "records")
    filter (Text.isInfixOf ".rec.tmp-" . Text.pack) entries @?= []

protectedIdentityCases :: [TestTree]
protectedIdentityCases =
    [ testCase "incompatible store identities refuse without changing any file" $
        forM_ identityFixtures $ \(envelope, reason) ->
            withSystemTempDirectory "hostbootstrap-store-identity-refusal" $ \root -> do
                createDirectoryIfMissing True (root </> "records")
                let files =
                        [ ("store.lock", "existing lock bytes")
                        , ("sentinel", "unrelated file bytes")
                        , ("records" </> "_b.rec", "hbps1 1\nliteral underscore record\n")
                        , ("records" </> "b.rec", "hbps1 3\nother record\n")
                        ]
                            <> maybe [] (\bytes -> [("store.identity", bytes)]) envelope
                    snapshot = do
                        rootEntries <- sort <$> listDirectory root
                        recordEntries <- sort <$> listDirectory (root </> "records")
                        contents <- traverse (\(path, _) -> (,) path <$> ByteString.readFile (root </> path)) files
                        pure (rootEntries, recordEntries, contents)
                forM_ files $ \(path, bytes) -> ByteString.writeFile (root </> path) bytes
                before <- snapshot
                opened <- openProtectedStore root
                case opened of
                    Left failure -> failure @?= ProtectedInvalid reason
                    Right _ -> assertFailure ("an incompatible identity envelope was admitted: " <> show envelope)
                snapshot >>= (@?= before)
    , testCase "an empty identity is refused even without records" $
        withSystemTempDirectory "hostbootstrap-empty-store-identity" $ \root -> do
            createDirectoryIfMissing True (root </> "records")
            ByteString.writeFile (root </> "store.identity") ""
            opened <- openProtectedStore root
            case opened of
                Left failure -> failure @?= ProtectedInvalid incompatibleReason
                Right _ -> assertFailure "an empty identity was replaced with a fresh store"
            ByteString.readFile (root </> "store.identity") >>= (@?= "")
            sort <$> listDirectory root >>= (@?= ["records", "store.identity"])
    , testCase "a current identity envelope preserves its opaque nonce" $
        forM_ ["replacement-store-origin", "nonce-λ"] $ \nonce ->
            withSystemTempDirectory "hostbootstrap-current-store-identity" $ \root -> do
                let envelope = TextEncoding.encodeUtf8 ("hbps2 " <> nonce <> "\n")
                ByteString.writeFile (root </> "store.identity") envelope
                store <- expectRight =<< openProtectedStore root
                protectedStoreIdentityText (protectedStoreIdentity store) @?= nonce
                reopened <- expectRight =<< openProtectedStore root
                protectedStoreIdentity reopened @?= protectedStoreIdentity store
                ByteString.readFile (root </> "store.identity") >>= (@?= envelope)
    ]
  where
    incompatibleReason = "the protected store identity envelope is incompatible with record-name encoding hbps2"
    identityFixtures :: [(Maybe ByteString.ByteString, Text)]
    identityFixtures =
        [ (Just "hbps-old-nonce\n", incompatibleReason)
        , (Just "hbps9 nonce\n", incompatibleReason)
        , (Just "", incompatibleReason)
        , (Just "hbps2 \n", incompatibleReason)
        , (Just "hbps2 nonce", incompatibleReason)
        , (Just "hbps2 nonce\nextra\n", incompatibleReason)
        , (Just "hbps2 two nonces\n", incompatibleReason)
        , (Just (ByteString.pack [255]), incompatibleReason)
        , (Nothing, "the protected store identity envelope is missing from a populated store")
        ]

recordNameEnumerationInputs :: [Char] -> [Text]
recordNameEnumerationInputs alphabet =
    [ Text.intercalate "/" path
    | pathLength <- [1, 2]
    , path <- replicateM pathLength segments
    ]
  where
    segments = [Text.pack segment | width <- [1, 2, 3], segment <- replicateM width alphabet]

protectedMalformedHeaderCases :: [TestTree]
protectedMalformedHeaderCases =
    [ testCase "every malformed record header is refused" $
        withStore $ \store -> do
            key <- expectKey "malformed-header"
            forM_
                [ ("garbage", "the record has no header terminator")
                , ("xxxx 1\nbody", "unknown record magic")
                , ("hbps1 0\nbody", "the record version is not a positive integer")
                , ("hbps1 -3\nbody", "the record version is not a positive integer")
                , ("hbps1 x\nbody", "the record version is not a positive integer")
                , ("hbps1\nbody", "the record header is not <magic> <version>")
                , ("hbps1 1 2\nbody", "the record header is not <magic> <version>")
                ]
                $ \(bytes, reason) -> do
                    ByteString.writeFile (protectedStoreRoot store </> "records" </> "malformed-header.rec") bytes
                    observed <- withProtectedEntry store (\session -> readProtectedRecord session key)
                    observed @?= Left (ProtectedMalformedRecord (recordKeyText key) reason)
    ]

protectedEntryThreadCases :: [TestTree]
protectedEntryThreadCases =
    [ testCase "the protected entry refuses re-entry from its holder" $
        withStore $ \store -> do
            result <- timeout 1000000 $
                withProtectedEntry store $ \_ -> do
                    nested <- withProtectedEntry store (\_ -> pure (Right ()))
                    assertReentryRefusal nested
                    attempted <- tryProtectedEntry store (\_ -> pure (Right ()))
                    assertReentryRefusal attempted
                    pure (Right ())
            result @?= Just (Right ())
    , testCase "an in-process peer thread sees the held entry as contention" $
        withStore $ \store -> do
            entered <- newEmptyMVar
            release <- newEmptyMVar
            completed <- newEmptyMVar
            _ <- forkIO $ do
                held <- withProtectedEntry store $ \_ -> do
                    putMVar entered ()
                    takeMVar release
                    pure (Right ())
                putMVar completed held
            let releasePeer = do
                    putMVar release ()
                    finished <- timeout 2000000 (takeMVar completed)
                    finished @?= Just (Right ())
            ( do
                started <- timeout 2000000 (takeMVar entered)
                started @?= Just ()
                contended <- timeout 1000000 (tryProtectedEntry store (\_ -> pure (Right ())))
                contended @?= Just (Right Nothing)
                ) `finally` releasePeer
            available <- timeout 1000000 (tryProtectedEntry store (\_ -> pure (Right ())))
            available @?= Just (Right (Just ()))
    ]

assertReentryRefusal :: Either ProtectedError result -> IO ()
assertReentryRefusal result = case result of
    Left (ProtectedInvalid reason) ->
        assertBool ("expected a re-entry refusal, got " <> show reason) ("not re-entrant" `Text.isInfixOf` reason)
    Left other -> assertFailure ("expected ProtectedInvalid, got " <> show other)
    Right _ -> assertFailure "the holder entered its own store again"

protectedSessionExtentCases :: [TestTree]
protectedSessionExtentCases =
    [ testCase "escaped protected IO actions are refused after entry exit" $
        withSessionExtentStore $ \store key version -> do
            captured <- withProtectedEntry store (\session -> pure (Right (protectedSessionActions session key version)))
            actions <- either (assertFailure . show) pure captured
            assertSessionActionsRefused "no longer live" actions
            assertSessionRecordUnchanged store key
    , testCase "a successful nonblocking entry revokes its escaped IO actions" $
        withSessionExtentStore $ \store key version -> do
            captured <- tryProtectedEntry store (\session -> pure (Right (protectedSessionActions session key version)))
            case captured of
                Right (Just actions) -> assertSessionActionsRefused "no longer live" actions
                Right Nothing -> assertFailure "the unheld store was unexpectedly contended"
                Left failure -> assertFailure (show failure)
            assertSessionRecordUnchanged store key
    , testCase "a later entry cannot revive escaped protected IO actions" $
        withSessionExtentStore $ \store key version -> do
            captured <- withProtectedEntry store (\session -> pure (Right (protectedSessionActions session key version)))
            actions <- either (assertFailure . show) pure captured
            later <- withProtectedEntry store $ \_ -> do
                assertSessionActionsRefused "no longer live" actions
                pure (Right ())
            later @?= Right ()
            assertSessionRecordUnchanged store key
    , testCase "a failed entry revokes captured protected IO actions before unlocking" $
        withSessionExtentStore $ \store key version -> do
            retained <- newIORef Nothing
            outcome <- withProtectedEntry store $ \session -> do
                writeIORef retained (Just (protectedSessionActions session key version))
                ioError (userError "session-body-failed")
            case outcome of
                Left (ProtectedIOFailure _ reason) ->
                    assertBool ("body failure was rewritten: " <> show reason) ("session-body-failed" `Text.isInfixOf` reason)
                Left other -> assertFailure ("expected the entry's IO failure, got " <> show other)
                Right () -> assertFailure "the failing entry returned successfully"
            assertRetainedSessionRefused retained
            assertSessionRecordUnchanged store key
    , testCase "an interrupted entry revokes captured protected IO actions before unlocking" $
        withSessionExtentStore $ \store key version -> do
            retained <- newIORef Nothing
            outcome <- timeout 100000 $
                withProtectedEntry store $ \session -> do
                    writeIORef retained (Just (protectedSessionActions session key version))
                    threadDelay 10000000
                    pure (Right ())
            outcome @?= Nothing
            assertRetainedSessionRefused retained
            assertSessionRecordUnchanged store key
    , testCase "a live protected session refuses record operations from a foreign thread" $
        withSessionExtentStore $ \store key version -> do
            held <- withProtectedEntry store $ \session -> do
                finished <- newEmptyMVar
                _ <- forkIO $ do
                    observed <- mapM (\(label, action) -> (,) label <$> action) (protectedSessionActions session key version)
                    putMVar finished observed
                peer <- timeout 2000000 (takeMVar finished)
                case peer of
                    Nothing -> assertFailure "the peer's record operations blocked inside the live entry"
                    Just outcomes -> forM_ outcomes (uncurry (assertSessionRefusal "another thread"))
                original <- readProtectedRecord session key
                fmap (fmap protectedRecordBytes) original @?= Right (Just "original")
                pure (Right ())
            held @?= Right ()
            assertSessionRecordUnchanged store key
    ]

type CapturedProtectedActions = [(String, IO (Either ProtectedError ()))]

withSessionExtentStore :: (ProtectedStore -> RecordKey -> RecordVersion -> IO ()) -> IO ()
withSessionExtentStore use = withStore $ \store -> do
    key <- expectKey "session-extent"
    written <- withProtectedEntry store $ \session ->
        compareAndSwapProtectedRecord session key ExpectAbsent "original"
    version <- either (assertFailure . show) pure written
    use store key version

protectedSessionActions :: ProtectedSession session -> RecordKey -> RecordVersion -> CapturedProtectedActions
protectedSessionActions session key version =
    [ ("read", discardProtectedValue (readProtectedRecord session key))
    , ("list", discardProtectedValue (listProtectedRecords session))
    , ("write", discardProtectedValue (compareAndSwapProtectedRecord session key (ExpectVersion version) "escaped write"))
    , ("delete", compareAndDeleteProtectedRecord session key (ExpectVersion version))
    , ("writable probe", verifyProtectedStoreWritable session)
    ]

discardProtectedValue :: IO (Either ProtectedError value) -> IO (Either ProtectedError ())
discardProtectedValue = fmap (fmap (const ()))

assertSessionActionsRefused :: Text -> CapturedProtectedActions -> IO ()
assertSessionActionsRefused reason actions =
    forM_ actions $ \(label, action) -> action >>= assertSessionRefusal reason label

assertSessionRefusal :: Text -> String -> Either ProtectedError () -> IO ()
assertSessionRefusal expected label observed = case observed of
    Left (ProtectedInvalid reason) ->
        assertBool (label <> " returned a different session refusal: " <> show reason) (expected `Text.isInfixOf` reason)
    other -> assertFailure (label <> " did not refuse the session: " <> show other)

assertRetainedSessionRefused :: IORef (Maybe CapturedProtectedActions) -> IO ()
assertRetainedSessionRefused retained = do
    actions <- readIORef retained
    case actions of
        Nothing -> assertFailure "the entry did not capture its ordinary IO actions"
        Just captured -> assertSessionActionsRefused "no longer live" captured

assertSessionRecordUnchanged :: ProtectedStore -> RecordKey -> IO ()
assertSessionRecordUnchanged store key = do
    observed <- withProtectedEntry store (\session -> readProtectedRecord session key)
    fmap (fmap protectedRecordBytes) observed @?= Right (Just "original")
