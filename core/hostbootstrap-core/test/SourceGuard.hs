-- | The suites' one toolkit for reading this repository's own sources.
--
-- Two halves, and both are here for the same reason. The lexical half parses
-- Haskell import and export declarations, using the standard lexer so comments
-- and string literals cannot create a false import; source pragmas,
-- package-qualified imports, qualifiers, and multiline imports are all
-- accepted. The structural half locates the package, walks its source tree, and
-- reads one field out of its description.
--
-- A source guard is an assertion about a set of modules, so a guard that is
-- wrong about which modules it enumerated asserts nothing, and does so
-- silently. One reader means two guards over the same field cannot disagree
-- about what the field says.
module SourceGuard
    ( -- * Lexical
      haskellImports
    , haskellTokens
    , importsModule
    , moduleImportTokens
    , moduleExportTokens
    , countHaskellIdentifier
    , countHaskellTokenSequence
    , countPosixAbsoluteLiteralApplications
    , repoRelativePath
    , repoRelativeModuleName

      -- * Structural
    , withPackageSourceIn
    , listHaskellSources
    , readHaskellSources
    , mainLibraryStanza
    , fieldModules
    , significantHaskellLineCount
    , indentation
    , trim
    , normalizeWhitespace
    )
where

import Data.Char (isAlphaNum, isSpace, isUpper)
import Data.List (intercalate, isPrefixOf, sort, stripPrefix)
import HostBootstrap.DocValidator (findRepoRoot)
import System.Directory (doesDirectoryExist, getCurrentDirectory, listDirectory)
import System.FilePath (dropExtension, makeRelative, normalise, takeExtension, (</>))
import Test.Tasty.HUnit (assertFailure)

{- | Run an action with this package's root and one source root beneath it.

Every source guard starts the same way: find the repository, name the package,
name the directory under it whose modules the guard is about. *segments* names
that directory relative to the package root, so a guard over the internal
ownership library and one over @src@ differ in the one thing they actually
differ in.
-}
withPackageSourceIn :: [FilePath] -> (FilePath -> FilePath -> IO result) -> IO result
withPackageSourceIn segments use = do
    cwd <- getCurrentDirectory
    repoRoot <-
        findRepoRoot cwd
            >>= maybe (assertFailure ("could not locate repo root from " <> cwd)) pure
    let packageRoot = repoRoot </> "core" </> "hostbootstrap-core"
    use packageRoot (foldl (</>) packageRoot segments)

-- | Every @.hs@ file under *directory*, depth-first in sorted order.
listHaskellSources :: FilePath -> IO [FilePath]
listHaskellSources directory = do
    entries <- sort <$> listDirectory directory
    fmap concat . traverse descend $ entries
  where
    descend entry = do
        let path = directory </> entry
        nested <- doesDirectoryExist path
        if nested
            then listHaskellSources path
            else pure [path | takeExtension path == ".hs"]

-- | 'listHaskellSources', paired with each file's contents.
readHaskellSources :: FilePath -> IO [(FilePath, String)]
readHaskellSources directory = do
    paths <- listHaskellSources directory
    traverse (\path -> (,) path <$> readFile path) paths

{- | The body of the package description's /unnamed/ main library stanza.

A named library (@library effect-internal@) is a different component with its
own module list, so the header must be the bare word.
-}
mainLibraryStanza :: String -> Maybe String
mainLibraryStanza description =
    case dropWhile ((/= "library") . trim) (lines description) of
        [] -> Nothing
        _library : rest -> Just (unlines (takeWhile isLibraryContinuation rest))
  where
    isLibraryContinuation [] = True
    isLibraryContinuation line@(firstCharacter : _) =
        null (trim line) || isSpace firstCharacter

{- | Every @HostBootstrap.*@ module named by one field of a stanza.

*field* is spelled with its colon (@"exposed-modules:"@). A value may begin on
the field's own line and continue on any line indented past it, which is both
layouts Cabal permits — reading only one of them is how two copies of this
function came to enumerate two different module sets from one file.
-}
fieldModules :: String -> String -> [String]
fieldModules field = go . lines
  where
    go [] = []
    go (line : rest)
        | Just inline <- stripPrefix field (trim line) =
            let fieldIndent = indentation line
                (continuation, remaining) =
                    span
                        (\next -> null (trim next) || indentation next > fieldIndent)
                        rest
             in moduleTokens (inline : continuation) <> go remaining
        | otherwise = go rest

    moduleTokens =
        filter ("HostBootstrap." `isPrefixOf`)
            . map (filter (/= ','))
            . words
            . unlines

{- | Lines of Haskell that are neither blank nor comment.

A module's size budget is about the code in it, so a header comment explaining
why the module is small must not make it large.
-}
significantHaskellLineCount :: String -> Int
significantHaskellLineCount = length . filter (not . all isSpace) . stripComments 0 . lines
  where
    stripComments :: Int -> [String] -> [String]
    stripComments _ [] = []
    stripComments depth (sourceLine : remaining) =
        let (nextDepth, code) = go depth sourceLine
         in code : stripComments nextDepth remaining

    go :: Int -> String -> (Int, String)
    go depth [] = (depth, [])
    go 0 ('-' : '-' : _) = (0, [])
    go 0 ('{' : '-' : '#' : remaining) =
        let (nextDepth, code) = go 0 remaining
         in (nextDepth, "{-#" <> code)
    go depth ('{' : '-' : remaining) = go (depth + 1) remaining
    go depth ('-' : '}' : remaining)
        | depth > 0 = go (depth - 1) remaining
    go 0 (character : remaining) =
        let (nextDepth, code) = go 0 remaining
         in (nextDepth, character : code)
    go depth (_ : remaining) = go depth remaining

indentation :: String -> Int
indentation = length . takeWhile isSpace

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

normalizeWhitespace :: String -> String
normalizeWhitespace = unwords . words

{- | Render a source path as a repo-relative path with canonical @\/@ separators.

An import allow-list, an importer set, and a module-ownership list all name
modules by path, and 'makeRelative' returns the host's own separator. A list
written with forward slashes therefore names the intended modules on a POSIX
outer host and nothing at all on a Windows one, which turns a real boundary
guard into a host-shaped one (§ JJ).

This is the one way a guard turns an absolute source path into the name it
compares, so the same list names the same modules on every supported outer host
realization.
-}
repoRelativePath :: FilePath -> FilePath -> FilePath
repoRelativePath sourceRoot = map forwardSlash . normalise . makeRelative sourceRoot
  where
    forwardSlash '\\' = '/'
    forwardSlash character = character

{- | Render a source path as the module name that file declares.

The same reason as 'repoRelativePath': a module-ownership list names modules,
and the path a host hands back names them with the host's own separator.
-}
repoRelativeModuleName :: FilePath -> FilePath -> String
repoRelativeModuleName sourceRoot =
    intercalate "." . splitOnSlash . dropExtension . repoRelativePath sourceRoot
  where
    splitOnSlash path =
        case break (== '/') path of
            (segment, _slash : rest) -> segment : splitOnSlash rest
            (segment, []) -> [segment]

importsModule :: String -> String -> Bool
importsModule imported = elem imported . haskellImports

{- | Return the explicit import-list tokens for exactly one import of a module.

Comments, strings, pragmas, package qualifiers, and layout are handled by the
same lexical pass as 'haskellImports'.  'Nothing' means that the named module is
absent, imported without an explicit list, or imported more than once; all
three shapes fail an exact boundary guard.
-}
moduleImportTokens :: String -> String -> Maybe [String]
moduleImportTokens expected source =
    case matchingImports (haskellTokens source) of
        [Just imported] -> Just imported
        _ -> Nothing
  where
    matchingImports [] = []
    matchingImports ("import" : remaining) =
        case parseModuleNameWithRest (dropImportDecorators remaining) of
            Just (observed, afterName)
                | observed == expected -> explicitImportList afterName : matchingImports remaining
                | otherwise -> matchingImports remaining
            Nothing -> matchingImports remaining
    matchingImports (_ : remaining) = matchingImports remaining

    explicitImportList afterName =
        case dropPostModuleDecorators afterName of
            "(" : afterOpen -> takeImportList (1 :: Int) [] afterOpen
            _ -> Nothing

    takeImportList _depth _reversed [] = Nothing
    takeImportList depth reversed ("(" : remaining) =
        takeImportList (depth + 1) ("(" : reversed) remaining
    takeImportList depth reversed (")" : remaining)
        | depth == 1 = Just (reverse reversed)
        | otherwise = takeImportList (depth - 1) (")" : reversed) remaining
    takeImportList depth reversed (token : remaining) =
        takeImportList depth (token : reversed) remaining

    dropPostModuleDecorators ("qualified" : remaining) =
        dropPostModuleDecorators remaining
    dropPostModuleDecorators ("as" : remaining) =
        case parseModuleNameWithRest remaining of
            Just (_, afterAlias) -> dropPostModuleDecorators afterAlias
            Nothing -> remaining
    dropPostModuleDecorators remaining = remaining

countHaskellIdentifier :: String -> String -> Int
countHaskellIdentifier identifier = length . filter (== identifier) . haskellTokens

{- | Count applications of one named function directly to a POSIX-absolute
string literal.

The same lexical pass the import guards use removes comments and treats a string
literal as one token, so a shell-quoting helper that merely mentions a slash
inside a larger literal is not a match and a commented-out example is not either.
-}
countPosixAbsoluteLiteralApplications :: String -> String -> Int
countPosixAbsoluteLiteralApplications name = count . haskellTokens
  where
    count (applied : argument : remaining)
        | applied == name && isPosixAbsoluteLiteral argument =
            1 + count (argument : remaining)
        | otherwise = count (argument : remaining)
    count _ = 0

    isPosixAbsoluteLiteral token =
        isQuotedToken token && take 2 token == "\"/"

countHaskellTokenSequence :: [String] -> String -> Int
countHaskellTokenSequence [] _source = 0
countHaskellTokenSequence expected source = count (haskellTokens source)
  where
    count [] = 0
    count remaining@(_ : rest)
        | expected `isPrefixOfTokens` remaining = 1 + count (drop (length expected) remaining)
        | otherwise = count rest

    isPrefixOfTokens [] _ = True
    isPrefixOfTokens _ [] = False
    isPrefixOfTokens (wanted : wantedRest) (observed : observedRest) =
        wanted == observed && isPrefixOfTokens wantedRest observedRest

{- | Return the explicit export-list tokens for one module declaration.

Comments, strings, pragmas, and layout cannot create a false export because the
same lexical pass used by the import guards removes them first.  'Nothing'
means the named module is absent or uses an implicit export list.
-}
moduleExportTokens :: String -> String -> Maybe [String]
moduleExportTokens expected = findModule . haskellTokens
  where
    findModule [] = Nothing
    findModule ("module" : remaining) =
        case parseModuleNameWithRest remaining of
            Just (observed, afterName)
                | observed == expected ->
                    case afterName of
                        "(" : afterOpen -> takeExports (1 :: Int) [] afterOpen
                        _ -> Nothing
                | otherwise -> findModule afterName
            Nothing -> findModule remaining
    findModule (_ : remaining) = findModule remaining

    takeExports _depth _reversed [] = Nothing
    takeExports depth reversed ("(" : remaining) =
        takeExports (depth + 1) ("(" : reversed) remaining
    takeExports depth reversed (")" : remaining)
        | depth == 1 = Just (reverse reversed)
        | otherwise = takeExports (depth - 1) (")" : reversed) remaining
    takeExports depth reversed (token : remaining) =
        takeExports depth (token : reversed) remaining

haskellImports :: String -> [String]
haskellImports = collect . haskellTokens
  where
    collect [] = []
    collect ("import" : remaining) =
        case importedModule remaining of
            Just moduleName -> moduleName : collect remaining
            Nothing -> collect remaining
    collect (_ : remaining) = collect remaining

{- | The source as the Haskell lexer yields it, comments removed.

A quoted literal is one token and a pragma opens as @{@ then @-#@, so a guard
built on this list cannot be fooled by a commented-out or quoted occurrence of
the shape it forbids.
-}
haskellTokens :: String -> [String]
haskellTokens source =
    case dropWhile isSpace source of
        "" -> []
        '-' : '-' : remaining -> haskellTokens (dropLineComment remaining)
        '{' : '-' : '#' : remaining -> "{" : "-#" : haskellTokens remaining
        '{' : '-' : remaining -> haskellTokens (dropBlockComment 1 remaining)
        significant ->
            case lex significant of
                [(token, remaining)]
                    | not (null token) && remaining /= significant -> token : haskellTokens remaining
                _ -> haskellTokens (drop 1 significant)

dropLineComment :: String -> String
dropLineComment source =
    case dropWhile (/= '\n') source of
        _newline : remaining -> remaining
        [] -> []

dropBlockComment :: Int -> String -> String
dropBlockComment _depth [] = []
dropBlockComment depth ('{' : '-' : remaining) =
    dropBlockComment (depth + 1) remaining
dropBlockComment depth ('-' : '}' : remaining)
    | depth == 1 = remaining
    | otherwise = dropBlockComment (depth - 1) remaining
dropBlockComment depth (_ : remaining) = dropBlockComment depth remaining

importedModule :: [String] -> Maybe String
importedModule = parseModuleName . dropImportDecorators

dropImportDecorators :: [String] -> [String]
dropImportDecorators ("safe" : remaining) = dropImportDecorators remaining
dropImportDecorators ("qualified" : remaining) = dropImportDecorators remaining
dropImportDecorators ("{" : "-#" : remaining) =
    dropImportDecorators (dropImportPragma remaining)
dropImportDecorators (packageName : remaining)
    | isQuotedToken packageName = dropImportDecorators remaining
dropImportDecorators remaining = remaining

dropImportPragma :: [String] -> [String]
dropImportPragma ("#-" : "}" : remaining) = remaining
dropImportPragma (_ : remaining) = dropImportPragma remaining
dropImportPragma [] = []

isQuotedToken :: String -> Bool
isQuotedToken ('"' : remaining) =
    case reverse remaining of
        '"' : _ -> True
        _ -> False
isQuotedToken _ = False

parseModuleName :: [String] -> Maybe String
parseModuleName = fmap fst . parseModuleNameWithRest

parseModuleNameWithRest :: [String] -> Maybe (String, [String])
parseModuleNameWithRest (firstSegment : remaining)
    | isModuleSegment firstSegment =
        Just (intercalate "." (reverse segments), afterModule)
  where
    (segments, afterModule) = gather [firstSegment] remaining
    gather collected ("." : segment : rest)
        | isModuleSegment segment = gather (segment : collected) rest
    gather collected rest = (collected, rest)
parseModuleNameWithRest _ = Nothing

isModuleSegment :: String -> Bool
isModuleSegment segment =
    case segment of
        firstCharacter : remaining ->
            isUpper firstCharacter
                && all (\character -> isAlphaNum character || character == '_' || character == '\'') remaining
        [] -> False
