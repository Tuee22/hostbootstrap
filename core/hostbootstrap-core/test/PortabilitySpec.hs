{- | The harness holds byte, path, component, and observed-case contracts on every host.

Each refusal names its entry under DEVELOPMENT_PLAN/rationale.md. Structural
readers and source traversal belong to SourceGuard; this module states the
contracts those readers must establish.
-}
module PortabilitySpec (tests) where

import Control.Monad (forM_, unless)
import Data.Char (isAlpha, toLower)
import Data.List (isInfixOf, isPrefixOf, nub, tails)
import PlatformPath (hostFixturePath)
import qualified SourceGuard as Source
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure))
import System.FilePath (isAbsolute, takeDirectory, (</>))
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)
import Text.Read (readMaybe)

tests :: TestTree
tests =
    testGroup
        "PortabilitySpec"
        [ testCase "the suite driver fixes the locale encoding before the runner starts" $ do
            driver <- readTestSource "Spec.hs"
            assertBool sourceRationale (Source.importsModule "GHC.IO.Encoding" driver)
            let body = dropMain (Source.haskellTokens driver)
                locale = tokenPositions ["setLocaleEncoding", "utf8"] body
                effects = concatMap (\name -> tokenPositions [name] body) ["getArgs", "readFile", "defaultMain"]
            assertBool sourceRationale (["do", "setLocaleEncoding", "utf8"] `isPrefixOf` body)
            case locale of
                [position] -> assertBool sourceRationale (not (null effects) && all (> position) effects)
                _ -> assertFailure (sourceRationale <> ": expected one locale application, observed " <> show locale)
        , testCase "a separator rewrite lives only in SourceGuard and PlatformPath" $
            Source.forEachTestSourceBut "" $ \name source ->
                unless (name `elem` ["test/SourceGuard.hs", "test/PlatformPath.hs"]) $
                    assertEqual (fixtureRationale <> ": " <> name) 0 (separatorOccurrences source)
        , testCase "separator detection covers literals, splitDirectories, and POSIX imports" $
            forM_
                [ "x = " <> show (toEnum 92 :: Char)
                , "x = " <> show [toEnum 92 :: Char]
                , "x = splitDirectories path"
                , "import qualified System.FilePath.Posix as Posix"
                ]
                (\source -> assertEqual fixtureRationale 1 (separatorOccurrences source))
        , testCase "a quoted separator helper name is not an identifier" $
            assertEqual fixtureRationale 0 (separatorOccurrences "name = \"splitDirectories\"")
        , testCase "only the harness helper turns a source path into a comparable name" $
            Source.forEachTestSourceBut "SourceGuard.hs" $ \name source ->
                assertEqual (fixtureRationale <> ": " <> name) 0 (Source.countHaskellIdentifier "makeRelative" source)
        , testCase "no frozen digest is derived from a locale-decoded read" $
            Source.forEachTestSourceBut "" $ \name source ->
                assertEqual (sourceRationale <> ": " <> name) 0 (reencodedDigestCount source)
        , testCase "digest detection covers application, composition, and dollar application" $
            forM_
                [ "digest = childConfigDigest (TextEncoding.encodeUtf8 source)"
                , "digest = childConfigDigest . TextEncoding.encodeUtf8 . Text.pack"
                , "digest = sha256Text $ Text.encodeUtf8 source"
                , "digest = childConfigDigest $ transform (raw) <> Text.encodeUtf8 source"
                , "digest = childConfigDigest . a . b . c . d . e . f . g . h . i . Text.encodeUtf8"
                ]
                (\source -> assertEqual sourceRationale 1 (reencodedDigestCount source))
        , testCase "digest detection leaves byte digests and unrelated encodings alone" $
            forM_
                [ "fields = [TextEncoding.encodeUtf8 (childConfigDigest request), TextEncoding.encodeUtf8 session]"
                , "value <- pure (sha256Text bytes)\npure (Text.encodeUtf8 unrelated)"
                , "digest = childConfigDigest $ request\nother = Text.encodeUtf8 unrelated"
                ]
                (\source -> assertEqual sourceRationale 0 (reencodedDigestCount source))
        , testCase "no host tool fixture bypasses the fixture-path constructor" $
            Source.forEachTestSourceBut "" $ \name source -> do
                let observed = Source.countPosixAbsoluteLiteralApplications "mkAbsExe" source + Source.countPosixAbsoluteLiteralApplications "mustAbs" source
                assertEqual (fixtureRationale <> ": " <> name) 0 observed
        , testCase "hostFixturePath is absolute for a drive-letter segment" $
            forM_ ["D:/x", "/D:/x", "D:x", "/D:x", "D:", "D:" <> [toEnum 92] <> "x"] $ \named ->
                assertBool (fixtureRationale <> ": " <> show named) (isAbsolute (hostFixturePath named))
        , testCase "an unrecognized probe flag is refused" $ do
            executable <- getExecutablePath
            (status, output, diagnostic) <- readProcessWithExitCode executable ["--hostbootstrap-no-such-probe"] ""
            assertEqual skippedRationale (ExitFailure 97) status
            assertEqual skippedRationale "" output
            assertBool skippedRationale ("unrecognized probe:" `isInfixOf` diagnostic)
        , testCase "no host condition decides which modules the package builds" $ do
            description <- Source.readPackageDescription
            assertEqual skippedRationale [] (hostConditionalFields description)
        , testCase "host condition fields include elif, flags, and mixed field case" $
            forM_
                [ ("if flag(x)\n  build-depends: base\nelif os(windows)\n  other-modules: Hidden\n", ["other-modules"])
                , ("if os(windows)\n  Buildable: False\n", ["buildable"])
                , ("if flag(live)\n  buildable: False\n", ["buildable"])
                , ("if arch(aarch64)\n  Exposed-Modules: Hidden\n", ["exposed-modules"])
                , ("if !os(windows)\n  Build-Depends: unix\n", [])
                ]
                (\(source, expected) -> assertEqual skippedRationale expected (hostConditionalFields source))
        , testCase "no spec binds PATH outside the allow-list" $ do
            allowedSource <- readTestSource "RecursiveLifecycleSpec.hs"
            let allowedBody = bindingBody "recursiveFixtureEnvironment" allowedSource
                allowedCount = pathBindingCount allowedBody
            assertBool (fakeRationale <> ": the process-transport fixture allow-list entry is stale") (allowedCount > 0)
            Source.forEachTestSourceBut "" $ \name source -> do
                let excused = if name == "test/RecursiveLifecycleSpec.hs" then allowedCount else 0
                assertEqual (fakeRationale <> ": " <> name) excused (pathBindingCount source)
        , testCase "PATH binding detection distinguishes writes and tuple bindings from lookup" $ do
            forM_
                [ "setEnv \"PATH\" dir"
                , "unsetEnv \"PATH\""
                , "[(\"PATH\", tools)]"
                , "[(\"Path\", tools)]"
                , "(proc exe []){env = Just [(\"PATH\", tools)]}"
                ]
                (\source -> assertEqual fakeRationale 1 (pathBindingCount source))
            assertEqual fakeRationale 0 (pathBindingCount "lookup \"PATH\" inherited")
        , testCase "no lifecycle module installs a thread-local crash point" $
            Source.withPackageSourceIn [] $ \packageRoot _ -> do
                sources <- concat <$> traverse (Source.readHaskellSources . (packageRoot </>)) ["src", "app", "internal"]
                forM_ sources $ \(name, source) ->
                    assertEqual (fakeRationale <> ": " <> name) 0 (sum (map (`Source.countHaskellIdentifier` source) crashPointNames))
        , testCase "the build description carries the warning policy the gate asserts" $
            forEachPackage $ \_ description ->
                forM_ requiredWarningFlags $ \flag ->
                    assertBool (warningRationale <> ": missing " <> flag) (flag `elem` words (Source.commonWarningsOptions description))
        , testCase "every component imports the warning stanza and none overrides it" $
            forEachPackage $ \_ description ->
                forM_ (Source.componentStanzas description) $ \component -> do
                    let body = Source.componentBody component
                        label = warningRationale <> ": " <> Source.componentHeader component
                    assertBool label ("warnings" `elem` Source.fieldValues "import" body)
                    assertEqual label [] (filter (weakensPolicy (words (Source.commonWarningsOptions description))) (Source.fieldValues "ghc-options" body))
        , testCase "no module suppresses a warning the policy asserts" $
            forEachPackage $ \packageRoot description -> do
                paths <- nub . concat <$> traverse (Source.listComponentSources packageRoot) (Source.componentStanzas description)
                forM_ paths $ \path -> do
                    source <- readFile path
                    assertBool (warningRationale <> ": " <> path) (not (hasOptionsPragma source))
        , testCase "warning pragma detection handles both accepted pragma names" $ do
            forM_ ["{-# OPTIONS_GHC -Wno-missing-signatures #-}", "{-# options_ghc -Wwarn #-}", "{-# OPTIONS -Wwarn #-}"] $ \source ->
                assertBool warningRationale (hasOptionsPragma source)
            assertBool warningRationale (not (hasOptionsPragma "x = \"{-# OPTIONS_GHC -Wwarn #-}\""))
        , testCase "warning overrides are matched as whole policy flags" $ do
            forM_ ["-Wwarn", "-Wno-error", "-Wno-error=partial-fields", "-Wno-partial-fields"] $ \flag ->
                assertBool warningRationale (weakensPolicy requiredWarningFlags flag)
            assertBool warningRationale (not (weakensPolicy requiredWarningFlags "-Werror=unused-imports"))
        , testCase "every component declares exactly the module files under its source directories" $
            forEachPackage $ \packageRoot description -> do
                let components = Source.componentStanzas description
                inventories <- traverse (\component -> (,) component <$> Source.listComponentSources packageRoot component) components
                forM_ inventories $ \(component, paths) -> do
                    forM_ (declaredModules component) $ \name ->
                        assertBool (skippedRationale <> ": missing declared module " <> name <> " in " <> Source.componentHeader component) (any (declaresModuleAt packageRoot component name) paths)
                    forM_ (Source.fieldValues "main-is" (Source.componentBody component)) $ \mainFile ->
                        assertBool (skippedRationale <> ": missing main-is " <> mainFile) (any (isMainSource packageRoot component mainFile) paths)
                    forM_ paths $ \path ->
                        assertBool (skippedRationale <> ": undeclared source " <> path) (any (ownsSource packageRoot path) inventories)
        , testCase "the shared stanza reader accepts inline, continued, and common source fields" $ do
            let description = "common shared\n  hs-source-dirs: internal\nlibrary private\n  import: shared\n  Exposed-Modules: HostBootstrap.A,HostBootstrap.A.Internal\n    Main\n  ghc-options: -Werror\ntest-suite suite\n  hs-source-dirs: test provider-live\n  other-modules: ConditionalCase, Expect\n"
                components = Source.componentStanzas description
            assertEqual skippedRationale ["library private", "test-suite suite"] (map Source.componentHeader components)
            assertEqual skippedRationale [["internal"], ["test", "provider-live"]] (map Source.componentSourceDirs components)
            case components of
                [library, suite] -> do
                    assertEqual skippedRationale ["HostBootstrap.A", "HostBootstrap.A.Internal", "Main"] (Source.fieldModules "exposed-modules" (Source.componentBody library))
                    assertEqual skippedRationale ["ConditionalCase", "Expect"] (Source.fieldModules "OTHER-MODULES:" (Source.componentBody suite))
                _ -> assertFailure (skippedRationale <> ": wrong synthetic components " <> show components)
        , testCase "module enumeration distinguishes a module from its nested module" $ do
            let packageRoot = hostFixturePath "package"
                component = Source.ComponentStanza "library" "exposed-modules: HostBootstrap.A.Internal" ["src"]
                nested = packageRoot </> "src" </> "HostBootstrap" </> "A" </> "Internal.hs"
            assertBool skippedRationale (declaresModuleAt packageRoot component "HostBootstrap.A.Internal" nested)
            assertBool skippedRationale (not (declaresModuleAt packageRoot component "HostBootstrap.A" nested))
        , testCase "each portability guard names an existing rationale heading" $
            Source.withPackageSourceIn [] $ \packageRoot _ -> do
                rationale <- readFile (takeDirectory (takeDirectory packageRoot) </> "DEVELOPMENT_PLAN" </> "rationale.md")
                forM_ rationaleHeadings $ \heading ->
                    assertBool (heading <> ": missing rationale heading") (("### " <> heading) `elem` lines rationale)
        ]

sourceRationale, fixtureRationale, skippedRationale, fakeRationale, warningRationale :: String
sourceRationale = "A source-byte guard reads bytes, because a locale-decoded read freezes the wrong thing"
fixtureRationale = "A host fixture is absolute on its own host, because a POSIX literal asserts a platform"
skippedRationale = "A skipped case is worse than a failing one, because the total does not change"
fakeRationale = "A fake is a symptom of an effect that swallowed a decision"
warningRationale = "The warning policy belongs to the package, not to the caller"

rationaleHeadings :: [String]
rationaleHeadings = [sourceRationale, fixtureRationale, skippedRationale, fakeRationale, warningRationale]

requiredWarningFlags :: [String]
requiredWarningFlags = ["-Werror", "-Wpartial-fields"]

crashPointNames :: [String]
crashPointNames = ["checkFailpoint", "installedFailpoints", "withTransactionFailpoint", "TransactionFailpoint", "TransactionInterrupted"]

readTestSource :: FilePath -> IO String
readTestSource name = Source.withPackageSourceIn ["test"] $ \_ directory -> readFile (directory </> name)

forEachPackage :: (FilePath -> String -> IO ()) -> IO ()
forEachPackage use = Source.withPackageSourceIn [] $ \packageRoot _ -> do
    description <- Source.readPackageDescription
    use packageRoot description
    let demoRoot = takeDirectory (takeDirectory packageRoot) </> "demo"
    demoDescription <- readFile (demoRoot </> "hostbootstrap-demo.cabal")
    use demoRoot demoDescription

dropMain :: [String] -> [String]
dropMain tokens = case dropWhile (not . (["main", "="] `isPrefixOf`)) (tails tokens) of
    [] -> []
    body : _ -> drop 2 body

tokenPositions :: [String] -> [String] -> [Int]
tokenPositions wanted tokens = [index | (index, suffix) <- zip [0 ..] (tails tokens), wanted `isPrefixOf` suffix]

separatorOccurrences :: String -> Int
separatorOccurrences source =
    length [() | token <- Source.haskellTokens source, (readMaybe token :: Maybe Char) == Just (toEnum 92) || (readMaybe token :: Maybe String) == Just [toEnum 92]]
        + Source.countHaskellIdentifier "splitDirectories" source
        + if Source.importsModule "System.FilePath.Posix" source then 1 else 0

reencodedDigestCount :: String -> Int
reencodedDigestCount source =
    length
        [ ()
        | token : rest <- tails (Source.haskellTokens source)
        , token `elem` ["childConfigDigest", "sha256Text"]
        , "encodeUtf8" `elem` digestArgument rest
        ]
  where
    digestArgument ("(" : rest) = expression 1 1 rest
    digestArgument ("." : rest) = expression 0 0 rest
    digestArgument ("$" : rest) = expression 0 0 rest
    digestArgument _ = []
    expression :: Int -> Int -> [String] -> [String]
    expression _ _ [] = []
    expression boundary depth (token : rest)
        | boundary == 0, depth == 0, token `elem` [")", "]", "}", ",", ";", "=", "<-"] = []
        | boundary == 1, depth == 1, token == ")" = []
        | token `elem` ["(", "[", "{"] = token : expression boundary (depth + 1) rest
        | token `elem` [")", "]", "}"] = token : expression boundary (depth - 1) rest
        | otherwise = token : expression boundary depth rest

pathBindingCount :: String -> Int
pathBindingCount source = length [() | suffix <- tails (Source.haskellTokens source), binds suffix]
  where
    isPath token = fmap (map toLower) (readMaybe token :: Maybe String) == Just "path"
    binds (setter : variable : _) | setter `elem` ["setEnv", "unsetEnv"] = isPath variable
    binds ("(" : variable : "," : _) = isPath variable
    binds _ = False

bindingBody :: String -> String -> String
bindingBody name source = case dropWhile (\line -> not (name `isPrefixOf` line && "=" `elem` Source.haskellTokens line)) (lines source) of
    [] -> ""
    first : rest -> unlines (first : takeWhile (\line -> null (Source.trim line) || Source.indentation line > 0) rest)

hasOptionsPragma :: String -> Bool
hasOptionsPragma source = any options (tails (Source.haskellTokens source))
  where
    options ("-#" : name : _) = map toLower name `elem` ["options_ghc", "options"]
    options _ = False

weakensPolicy :: [String] -> String -> Bool
weakensPolicy policy flag =
    flag `elem` ["-Wwarn", "-Wno-error"]
        || "-Wno-error=" `isPrefixOf` flag
        || flag `elem` ["-Wno-" <> drop 2 enabled | enabled <- policy, "-W" `isPrefixOf` enabled]

declaredModules :: Source.ComponentStanza -> [String]
declaredModules component = Source.fieldModules "exposed-modules" body <> Source.fieldModules "other-modules" body
  where
    body = Source.componentBody component

declaresModuleAt :: FilePath -> Source.ComponentStanza -> String -> FilePath -> Bool
declaresModuleAt packageRoot component name path = any (\directory -> Source.repoRelativeModuleName (packageRoot </> directory) path == name) (Source.componentSourceDirs component)

ownsSource :: FilePath -> FilePath -> (Source.ComponentStanza, [FilePath]) -> Bool
ownsSource packageRoot path (component, paths) =
    path `elem` paths
        && (any (\name -> declaresModuleAt packageRoot component name path) (declaredModules component)
            || any (\mainFile -> isMainSource packageRoot component mainFile path) (Source.fieldValues "main-is" (Source.componentBody component)))

isMainSource :: FilePath -> Source.ComponentStanza -> FilePath -> FilePath -> Bool
isMainSource packageRoot component mainFile path =
    any (\directory -> Source.repoRelativePath packageRoot path == Source.repoRelativePath packageRoot (packageRoot </> directory </> mainFile)) (Source.componentSourceDirs component)

hostConditionalFields :: String -> [String]
hostConditionalFields = go . filter (not . null . snd) . map (\line -> (Source.indentation line, map toLower (Source.trim line))) . lines
  where
    go [] = []
    go ((column, text) : rest)
        | isHostCondition text =
            let (body, remaining) = span ((> column) . fst) rest
             in offenders body <> afterCondition column remaining
        | otherwise = go rest
    afterCondition column ((elseColumn, "else") : rest)
        | elseColumn == column =
            let (body, remaining) = span ((> column) . fst) rest
             in offenders body <> afterCondition column remaining
    afterCondition _ rest = go rest
    offenders body = [field | (_, text) <- body, let field = fieldName text, field `notElem` ["", "build-depends"]]
    isHostCondition text = any (`isPrefixOf` text) ["if ", "elif "] && any (`isInfixOf` text) ["os(", "arch(", "flag("]
    fieldName text = case break (== ':') text of
        (name, ':' : _) | not (null name), all (\character -> isAlpha character || character == '-') name -> name
        _ -> ""
