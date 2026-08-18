{- | Absence guards for the harness-portability and evidence shapes.

§ N builds every binary host-native, so the host static gate must prove the same
contracts on every supported outer host realization (§ JJ). Three shapes break
that quietly rather than loudly: a spec that decodes a source file through the
host's active code page, a guard that compares a native-separator path against a
forward-slash literal, and a host tool fixture written as a POSIX-absolute
literal. Each passes on a POSIX host and, on a Windows one, either fails or —
worse — asserts something weaker than it reads as asserting.

Two more shapes break what a green run is worth rather than where it runs
(§ NN). A module the package description excludes on one host takes its cases
with it, so a family shrinks and the total still reads green; and an executable
a spec writes onto the suite's own @PATH@ makes production resolve the spec's
answer rather than the host's, which is the gate agreeing with a shape
production never takes.

Each case names the rationale entry under @DEVELOPMENT_PLAN/rationale.md@
§ Gates and validation that explains why the shape is wrong, and asserts only
that the shape is absent. None of them substitutes for the gate: the gate proves
the suite runs on a host, and these keep a known-bad shape from returning to it.
-}
module PortabilitySpec (tests) where

import Control.Monad (forM_)
import Data.Char (isSpace)
import Data.List (isInfixOf, isSuffixOf, sort)
import HostBootstrap.DocValidator (findRepoRoot)
import SourceGuard
    ( countHaskellIdentifier
    , countHaskellTokenSequence
    , countPosixAbsoluteLiteralApplications
    , importsModule
    , moduleImportTokens
    )
import System.Directory (doesDirectoryExist, getCurrentDirectory, listDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "PortabilitySpec"
        [ testCase "the suite driver fixes the locale encoding before the runner starts" $ do
            -- A frozen source digest, a significant-line budget, and a governed
            -- golden containing a section sign are properties of a file's own
            -- bytes. Decoded through the active code page they become
            -- properties of the host instead, which is a suite that agrees with
            -- itself only where it was written.
            driver <- readTestSource "Spec.hs"
            importsModule "GHC.IO.Encoding" driver @?= True
            moduleImportTokens "GHC.IO.Encoding" driver
                @?= Just ["setLocaleEncoding", ",", "utf8"]
            -- Applied, not merely imported: the import list separates the two
            -- names with a comma, so an adjacent pair is the call itself.
            countHaskellTokenSequence ["setLocaleEncoding", "utf8"] driver @?= 1
        , testCase "the separator rewrite lives in exactly one harness module" $
            forEachTestSourceBut "SourceGuard.hs" $ \name source -> do
                let observed = countHaskellIdentifier backslashLiteral source
                if observed == 0
                    then pure ()
                    else
                        assertFailure
                            ( name
                                ++ " defines "
                                ++ show observed
                                ++ " separator rewrites of its own:"
                                ++ " use SourceGuard.repoRelativePath"
                            )
        , testCase "only the harness helper turns a source path into a comparable name" $
            forEachTestSourceBut "SourceGuard.hs" $ \name source -> do
                let observed = countHaskellIdentifier "makeRelative" source
                if observed == 0
                    then pure ()
                    else
                        assertFailure
                            ( name
                                ++ " names makeRelative "
                                ++ show observed
                                ++ " times; a raw relative path carries the host's own"
                                ++ " separator, so use SourceGuard.repoRelativePath"
                                ++ " or SourceGuard.repoRelativeModuleName"
                            )
        , testCase "no frozen digest is derived from a locale-decoded read" $
            forEachTestSourceBut "" $ \name source -> do
                let observed = sum (map (`countHaskellTokenSequence` source) reencodedDigestSequences)
                if observed == 0
                    then pure ()
                    else
                        assertFailure
                            ( name
                                ++ " takes "
                                ++ show observed
                                ++ " digests of a re-encoded value; a frozen source digest is"
                                ++ " a digest of the file's own bytes, so read the bytes rather"
                                ++ " than decoding through the gate host's code page and"
                                ++ " re-encoding"
                            )
        , testCase "no host tool fixture bypasses the fixture-path constructor" $
            forEachTestSourceBut "" $ \name source -> do
                let observed =
                        countPosixAbsoluteLiteralApplications "mkAbsExe" source
                            + countPosixAbsoluteLiteralApplications "mustAbs" source
                if observed == 0
                    then pure ()
                    else
                        assertFailure
                            ( name
                                ++ " builds "
                                ++ show observed
                                ++ " host tool paths from POSIX-absolute literals,"
                                ++ " which the total AbsExe constructor refuses on a Windows host:"
                                ++ " use PlatformPath.hostFixturePath"
                            )
        , testCase "no host condition decides which modules the package builds" $ do
            -- A module a Cabal 'os' or 'arch' condition excludes is not a
            -- weaker expectation on that host; it is no expectation at all, and
            -- the cases it carried leave with it. The family shrinks, the total
            -- stays green, and nothing in the run says so. A platform row is
            -- therefore built everywhere and stubbed to a total refusal where it
            -- cannot apply, and only the platform library it binds to is
            -- conditional.
            description <- readPackageDescription
            let offending = hostConditionalFields description
            if null offending
                then pure ()
                else
                    assertFailure
                        ( "the package description lets a host condition decide "
                            ++ show offending
                            ++ "; only build-depends may be host-conditional, because a"
                            ++ " platform row is compiled on every gate host and refuses"
                            ++ " where it cannot apply"
                        )
        , testCase "no spec points the suite's own PATH at an executable it wrote" $
            forEachTestSourceBut "" $ \name source -> do
                let observed =
                        sum
                            [ countHaskellTokenSequence [setter, pathVariable] source
                            | setter <- ["setEnv", "unsetEnv"]
                            ]
                if observed == 0
                    then pure ()
                    else
                        assertFailure
                            ( name
                                ++ " renames the suite process's own PATH "
                                ++ show observed
                                ++ " times; production resolves a host tool by absolute path"
                                ++ " from typed configuration, so a spec that makes PATH"
                                ++ " resolve to an executable it wrote is testing its own"
                                ++ " answer rather than the host's"
                            )
        , testCase "no lifecycle module installs a thread-local crash point" $ do
            -- What an interrupted transaction leaves is a value, so a fixture
            -- writes that value through the store and re-enters the ordinary
            -- entry point. A coordinator that carried a crash point instead
            -- would ship a spoofable path to operators, and a gate driving it
            -- would agree with a shape production never takes.
            sources <- productionSources
            forM_ sources $ \(name, source) -> do
                let observed = sum (map (`countHaskellIdentifier` source) crashPointNames)
                if observed == 0
                    then pure ()
                    else
                        assertFailure
                            ( name
                                ++ " names a transaction crash point "
                                ++ show observed
                                ++ " times; the durable state an interruption leaves is a"
                                ++ " record, so a fixture writes the record rather than"
                                ++ " asking the coordinator to throw"
                            )
        ]

{- | The crash-injection vocabulary the redo coordinator no longer has.

Spelled as string literals for the same reason the guards above are: the lexer
yields a quoted literal as one token, so this module is not itself an
occurrence of the shape it forbids.
-}
crashPointNames :: [String]
crashPointNames =
    [ "checkFailpoint"
    , "installedFailpoints"
    , "withTransactionFailpoint"
    , "TransactionFailpoint"
    , "TransactionInterrupted"
    ]

{- | Every Haskell source the package ships, by file name.

The suite's own modules are excluded deliberately: a guard about what
production carries must not be satisfied or broken by what a fixture carries.
-}
productionSources :: IO [(FilePath, String)]
productionSources = do
    cwd <- getCurrentDirectory
    root <- findRepoRoot cwd >>= maybe (assertFailure "could not locate the repository root") pure
    let packageRoot = root </> "core" </> "hostbootstrap-core"
    concat
        <$> traverse
            (\directory -> haskellSourcesUnder (packageRoot </> directory))
            ["src", "app", "internal"]

haskellSourcesUnder :: FilePath -> IO [(FilePath, String)]
haskellSourcesUnder directory = do
    entries <- sort <$> listDirectory directory
    concat <$> traverse descend entries
  where
    descend name = do
        let path = directory </> name
        nested <- doesDirectoryExist path
        if nested
            then haskellSourcesUnder path
            else
                if ".hs" `isSuffixOf` name
                    then do
                        source <- readFile path
                        pure [(name, source)]
                    else pure []

{- | The @PATH@ environment name as the lexer yields it.

Spelled as a string literal, so this module is not itself an occurrence of the
shape the guard above forbids.
-}
pathVariable :: String
pathVariable = "\"PATH\""

{- | Every field a Cabal @os@ or @arch@ condition decides.

A conditional @build-depends@ is admitted and nothing else: binding to @unix@ on
one host and @Win32@ on another is how one row reaches two kernels, whereas
deciding @exposed-modules@, @other-modules@, or @buildable@ decides whether a
subject exists at all.

The parse is indentation-based, which is what the field layout of a package
description is. A conditional block owns the lines indented past its @if@, and
an @else@ at the same indentation opens the other half of the same condition.
-}
hostConditionalFields :: String -> [String]
hostConditionalFields = go . map (\line -> (indentOf line, trim line)) . lines
  where
    go [] = []
    go ((column, text) : rest)
        | isHostCondition text =
            let (body, remaining) = span ((> column) . fst) rest
             in offenders body ++ afterCondition column remaining
        | otherwise = go rest

    -- The 'else' half of a host condition is governed by the same condition.
    afterCondition column ((elseColumn, "else") : rest)
        | elseColumn == column =
            let (body, remaining) = span ((> column) . fst) rest
             in offenders body ++ afterCondition column remaining
    afterCondition _ rest = go rest

    offenders body =
        [ field
        | field <- map (fieldName . snd) body
        , field `notElem` ["", "build-depends"]
        ]

    isHostCondition text =
        take 3 text == "if " && ("os(" `isInfixOf` text || "arch(" `isInfixOf` text)

    fieldName text =
        case break (== ':') text of
            (name, ':' : _)
                | all (\character -> character `elem` ("abcdefghijklmnopqrstuvwxyz-" :: String)) name
                , not (null name) ->
                    name
            _ -> ""

    indentOf line = length (takeWhile (== ' ') line)

    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

readPackageDescription :: IO String
readPackageDescription = do
    cwd <- getCurrentDirectory
    root <- findRepoRoot cwd >>= maybe (assertFailure "could not locate the repository root") pure
    readFile
        ( root
            </> "core"
            </> "hostbootstrap-core"
            </> "hostbootstrap-core.cabal"
        )

{- | A digest taken of a re-encoded value, as the lexer yields it.

A frozen source digest names what a file is, so it is taken from that file's own
bytes. Taken instead from a locale-decoded read that is then re-encoded, it
becomes a property of the gate host's code page and newline translation, and a
freeze means a different thing on each gate host (§ JJ). Only a decoded read
needs the re-encoding, so the two digest helpers a spec freezes a governed source
with are paired here with every alias the suite imports the encoder under.

Spelled as string literals, so this module is not itself an occurrence of the
shape the guard above forbids: the lexer yields a quoted literal as one token.
-}
reencodedDigestSequences :: [[String]]
reencodedDigestSequences =
    [ [digest, "(", alias, ".", "encodeUtf8"]
    | digest <- ["childConfigDigest", "sha256Text"]
    , alias <- ["TextEncoding", "Text", "T"]
    ]

{- | The backslash character literal as the lexer yields it.

Spelled as a string literal, so this module is not itself an occurrence of the
shape the guard above forbids.
-}
backslashLiteral :: String
backslashLiteral = "'\\\\'"

{- | Run a guard over every test module, excusing at most the one module that
owns the shape.
-}
forEachTestSourceBut :: FilePath -> (FilePath -> String -> IO ()) -> IO ()
forEachTestSourceBut owner check = do
    root <- testRoot
    entries <- listDirectory root
    let sources = sort (filter (\name -> ".hs" `isSuffixOf` name && name /= owner) entries)
    forM_ sources $ \name -> do
        source <- readFile (root </> name)
        check name source

readTestSource :: FilePath -> IO String
readTestSource name = do
    root <- testRoot
    readFile (root </> name)

testRoot :: IO FilePath
testRoot = do
    cwd <- getCurrentDirectory
    root <- findRepoRoot cwd >>= maybe (assertFailure "could not locate the repository root") pure
    pure (root </> "core" </> "hostbootstrap-core" </> "test")
