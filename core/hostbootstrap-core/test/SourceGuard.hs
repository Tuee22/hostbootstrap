{- | The suites' one toolkit for reading this repository's own sources.

Two halves, and both are here for the same reason. The lexical half parses
Haskell import and export declarations, using the standard lexer so comments
and string literals cannot create a false import; source pragmas,
package-qualified imports, qualifiers, and multiline imports are all
accepted. The structural half locates the package, walks its source tree, and
reads one field out of its description.

A source guard is an assertion about a set of modules, so a guard that is
wrong about which modules it enumerated asserts nothing, and does so
silently. One reader means two guards over the same field cannot disagree
about what the field says.
-}
module SourceGuard (
    -- * Lexical
    haskellImports,
    firstPartyImportItems,
    haskellDefinitionNames,
    haskellDefinitionTokens,
    nullaryDataConstructorNames,
    recordFieldNames,
    haskellTokens,
    importsModule,
    moduleImportTokens,
    moduleExportTokens,
    countHaskellIdentifier,
    countHaskellTokenSequence,
    unproducedAuthorityErrorConstructors,
    countPosixAbsoluteLiteralApplications,
    repoRelativePath,
    repoRelativeModuleName,

    -- * Structural
    withPackageSourceIn,
    listHaskellSources,
    readHaskellSources,
    readPackageDescription,
    librarySourceDirs,
    libraryModulePath,
    readLibrarySources,
    transitiveHostBootstrapImports,
    ComponentStanza (..),
    componentStanzas,
    namedStanza,
    fieldValues,
    commonWarningsOptions,
    listComponentSources,
    listTestSources,
    forEachTestSourceBut,
    mainLibraryStanza,
    fieldModules,
    significantHaskellLineCount,
    indentation,
    trim,
    normalizeWhitespace,
)
where

import Control.Monad (filterM, forM_)
import Data.Char (isAlphaNum, isDigit, isLower, isSpace, isUpper, toLower)
import Data.List (groupBy, intercalate, isPrefixOf, isSuffixOf, nub, sort, sortOn)
import HostBootstrap.DocValidator (findRepoRoot)
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory)
import System.FilePath (dropExtension, makeRelative, normalise, splitDirectories, takeExtension, (<.>), (</>))
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

{- | Find AuthorityError alternatives without a closed construction witness.

This deliberately recognizes only the current simple sum and named value
bindings. A witness is an applied, balanced @pure (Left (Constructor ...))@
following @=@ or @->@, or the complete closed verb-parser equation. Types,
imports, the declaration and renderer, and patterns alone are not evidence.
Unrecognized sum shapes refuse; unrecognized expression styles owe a witness.
-}
unproducedAuthorityErrorConstructors :: [(String, String)] -> Either String [String]
unproducedAuthorityErrorConstructors sources = do
    constructors <- case declarations of
        [fields] -> traverse constructor (splitAlternatives (takeWhile (/= "deriving") fields))
        [] -> Left "AuthorityError declaration missing"
        _ -> Left "AuthorityError declaration ambiguous"
    if null constructors || length (nub (map fst constructors)) /= length constructors
        then Left "AuthorityError alternatives are empty or duplicated"
        else Right [name | (name, arity) <- constructors, not (any (produces name arity) values)]
  where
    blocks = concatMap (sourceBlocks . snd) sources
    declarations = [fields | "data" : "AuthorityError" : "=" : fields <- blocks]
    values = [tokens | tokens@(name : rest) <- blocks, valueName name, name /= "authorityErrorMessage", take 1 rest /= ["::"]]
    valueName name = case name of
        first : _ -> (isLower first || first == '_') && name `notElem`
            ["module", "import", "data", "newtype", "type", "class", "instance", "deriving", "foreign", "default", "infix", "infixl", "infixr", "pattern"]
        [] -> False
    constructor (name : fields)
        | isModuleSegment name && all isModuleSegment fields = Right (name, length fields)
    constructor _ = Left "AuthorityError must be a simple prefix-constructor sum"
    splitAlternatives tokens = case break (== "|") tokens of
        (alternative, _ : rest) -> alternative : splitAlternatives rest
        (alternative, []) -> [alternative]
    produces name arity tokens = expressionWitness name arity tokens
        || (name == "AuthorityUnknownVerb" && arity == 1 && tokens == verbParser)
    verbParser = haskellTokens $ unlines
        [ "parseProjectVerb raw = case raw of"
        , "  \"up\" -> Right (SomeProjectVerb ProjectUp)"
        , "  \"down\" -> Right (SomeProjectVerb ProjectDown)"
        , "  \"destroy\" -> Right (SomeProjectVerb ProjectDestroy)"
        , "  _ -> Left (AuthorityUnknownVerb raw)"
        ]

expressionWitness :: String -> Int -> [String] -> Bool
expressionWitness name arity = scan
  where
    scan (anchor : "pure" : "(" : "Left" : "(" : constructor : remaining)
        | anchor `elem` ["=", "->"], constructor == name
        , Just (arguments, ")" : _) <- balancedTokens ")" remaining
        , Just count <- argumentCount arguments, count == arity = True
    scan (_ : remaining) = scan remaining
    scan [] = False
    argumentCount [] = Just 0
    argumentCount (opening : remaining)
        | Just closing <- lookup opening [("(", ")"), ("[", "]")] = do
            (_, rest) <- balancedTokens closing remaining
            (1 +) <$> argumentCount rest
        | first : _ <- opening
        , isAlphaNum first || first `elem` "_\"'" = (1 +) <$> argumentCount remaining
    argumentCount _ = Nothing

-- The opening delimiter has already been consumed. Literals are lexer tokens,
-- so punctuation inside a string cannot balance an expression.
balancedTokens :: String -> [String] -> Maybe ([String], [String])
balancedTokens closing = go [closing] []
  where
    go (expected : stack) reversed (token : remaining)
        | token == expected = if null stack
            then Just (reverse reversed, remaining)
            else go stack (token : reversed) remaining
        | Just next <- lookup token [("(", ")"), ("[", "]"), ("{", "}")] =
            go (next : expected : stack) (token : reversed) remaining
        | token `notElem` [")", "]", "}"] = go (expected : stack) (token : reversed) remaining
    go _ _ _ = Nothing

-- Closed top-level blocks keep signatures and function patterns distinct from
-- expression witnesses. Mask comments before splitting so their layout cannot
-- create a spurious declaration; keep literal tokens intact.
sourceBlocks :: String -> [[String]]
sourceBlocks = map haskellTokens . sourceTextBlocks

sourceTextBlocks :: String -> [String]
sourceTextBlocks = map unlines . blocks . lines . maskHaskellComments
  where
    blocks [] = []
    blocks (line : remaining)
        | all isSpace line = blocks remaining
        | indentation line /= 0 = blocks remaining
        | otherwise = let (body, rest) = continuation (balance 0 line) remaining
                       in (line : body) : blocks rest
    continuation _depth [] = ([], [])
    continuation depth pending@(line : remaining)
        | all isSpace line || indentation line > 0 || depth > 0 =
            let (body, rest) = continuation (balance depth line) remaining
             in (line : body, rest)
        | otherwise = ([], pending)
    balance :: Int -> String -> Int
    balance depth = foldl step depth . haskellTokens
    step depth token
        | token `elem` ["(", "[", "{"] = depth + 1
        | token `elem` [")", "]", "}"] = max 0 (depth - 1)
        | otherwise = depth

maskHaskellComments :: String -> String
maskHaskellComments = mask
  where
    mask [] = []
    mask ('-' : '-' : remaining) = "  " <> lineComment remaining
    mask ('{' : '-' : remaining) = "  " <> blockComment 1 remaining
    mask source@(character : remaining)
        | isSpace character = character : mask remaining
        | [(token, rest)] <- lex source, not (null token), rest /= source = token <> mask rest
        | otherwise = character : mask remaining
    blank '\n' = '\n'
    blank _ = ' '
    lineComment [] = []
    lineComment ('\n' : remaining) = '\n' : maskHaskellComments remaining
    lineComment (_ : remaining) = ' ' : lineComment remaining
    blockComment :: Int -> String -> String
    blockComment _ [] = []
    blockComment depth ('{' : '-' : remaining) = "  " <> blockComment (depth + 1) remaining
    blockComment depth ('-' : '}' : remaining)
        | depth == 1 = "  " <> maskHaskellComments remaining
        | otherwise = "  " <> blockComment (depth - 1) remaining
    blockComment depth (character : remaining) = blank character : blockComment depth remaining

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

readPackageDescription :: IO String
readPackageDescription =
    withPackageSourceIn [] $ \packageRoot _ ->
        readFile (packageRoot </> "hostbootstrap-core.cabal")

-- | One component and the source directories its own and imported fields name.
data ComponentStanza = ComponentStanza
    { componentHeader :: String
    , componentBody :: String
    , componentSourceDirs :: [FilePath]
    }
    deriving (Eq, Show)

-- | Every library, executable, test, benchmark, and foreign-library component.
componentStanzas :: String -> [ComponentStanza]
componentStanzas description =
    [ ComponentStanza header body (if null directories then ["."] else nub directories)
    | (header, body) <- stanzaBlocks description
    , stanzaKind header /= "common"
    , let directories = sourceDirectories [] body
    ]
  where
    sourceDirectories visited body =
        fieldValues "hs-source-dirs" body
            <> concat
                [ sourceDirectories (name : visited) imported
                | name <- fieldValues "import" body
                , name `notElem` visited
                , Just imported <- [namedStanza ("common " <> name) description]
                ]

-- | Effective source directories of every library, including private units.
librarySourceDirs :: String -> [FilePath]
librarySourceDirs description = sort . nub $
    [ normalise directory
    | component <- componentStanzas description
    , stanzaKind (componentHeader component) == "library"
    , directory <- componentSourceDirs component
    ]

-- | Resolve one module's unique physical home, independent of its library unit.
libraryModulePath :: FilePath -> String -> String -> IO FilePath
libraryModulePath packageRoot description moduleName = do
    candidates <- filterM doesFileExist . sort . nub $
        [normalise (packageRoot </> directory </> moduleSourcePath moduleName) | directory <- librarySourceDirs description]
    case candidates of
        [path] -> do
            source <- readFile path
            case declaredModuleName source of
                Just declared | declared == moduleName -> pure path
                _ -> assertFailure ("library source does not declare " <> moduleName <> ": " <> path)
        [] -> assertFailure ("library module source missing: " <> moduleName)
        paths -> assertFailure ("library module source ambiguous: " <> moduleName <> " " <> show paths)

-- | Every physical library source once, retaining its declared module identity.
-- Overlapping stanzas can share roots; two different files cannot own one name.
readLibrarySources :: FilePath -> String -> IO [(String, FilePath, String)]
readLibrarySources packageRoot description = do
    paths <- sort . nub . map normalise . concat <$> traverse
        (listHaskellSources . (packageRoot </>)) (librarySourceDirs description)
    sources <- traverse readSource paths
    let grouped = groupBy (\left right -> sourceName left == sourceName right) (sortOn sourceName sources)
        ambiguous = [[path | (_, path, _) <- group] | group <- grouped, length group > 1]
    if null ambiguous
        then pure (sortOn (splitDirectories . moduleSourcePath . sourceName) sources)
        else assertFailure ("library module source ambiguous: " <> show ambiguous)
  where
    sourceName (name, _, _) = name
    readSource path = do
        source <- readFile path
        case declaredModuleName source of
            Just name -> pure (name, path, source)
            Nothing -> assertFailure ("library source has no module declaration: " <> path)

{- | The sorted strict HostBootstrap dependency closure of one library module.

The inventory is the caller's 'readLibrarySources' result. Paths are retained
verbatim for diagnostics; callers can normalize them with 'repoRelativePath'.
Every visited module must have exactly one inventory entry. External imports
are outside this closure, while an unresolved package import always refuses.
-}
transitiveHostBootstrapImports :: [(String, FilePath, String)] -> String -> Either String [(String, FilePath)]
transitiveHostBootstrapImports inventory root = walk [(Nothing, root)] []
  where
    walk [] visited = Right (sortOn fst (filter ((/= root) . fst) visited))
    walk ((origin, name) : pending) visited
        | name `elem` map fst visited = walk pending visited
        | otherwise = do
            (path, source) <- resolve origin name
            let dependencies = sort . nub . filter packageImport $ haskellImports source
                next = [(Just (name, path), dependency) | dependency <- dependencies]
            walk (next <> pending) ((name, path) : visited)
    packageImport name = name == "HostBootstrap" || "HostBootstrap." `isPrefixOf` name
    resolve origin name =
        case [(path, source) | (observed, path, source) <- inventory, observed == name] of
            [source] -> Right source
            [] -> Left ("HostBootstrap module missing: " <> name <> provenance origin)
            sources -> Left
                ( "HostBootstrap module ambiguous: " <> name <> provenance origin
                    <> "; candidates: " <> show (sort (map fst sources))
                )
    provenance Nothing = " (root)"
    provenance (Just (importer, path)) = " imported by " <> importer <> " (" <> path <> ")"

moduleSourcePath :: String -> FilePath
moduleSourcePath moduleName = foldr (</>) "" (segments moduleName) <.> "hs"
  where
    segments name = case break (== '.') name of
        (segment, '.' : remaining) -> segment : segments remaining
        (segment, []) -> [segment]
        _ -> []

declaredModuleName :: String -> Maybe String
declaredModuleName = findModule . haskellTokens
  where
    findModule ("module" : remaining) = parseModuleName remaining
    findModule (_ : remaining) = findModule remaining
    findModule [] = Nothing

-- | The body of the exact named stanza, or the unnamed @library@ stanza.
namedStanza :: String -> String -> Maybe String
namedStanza header =
    lookup (map toLower (normalizeWhitespace header))
        . map (\(observed, body) -> (map toLower observed, body))
        . stanzaBlocks

stanzaBlocks :: String -> [(String, String)]
stanzaBlocks = go . lines
  where
    go [] = []
    go (line : rest)
        | indentation line == 0
        , let header = normalizeWhitespace (cabalLine line)
        , stanzaKind header `elem` ["library", "executable", "test-suite", "benchmark", "foreign-library", "common"] =
            let (body, remaining) = span continuation rest
             in (header, unlines body) : go remaining
        | otherwise = go rest

    continuation line = null (cabalLine line) || indentation line > 0

stanzaKind :: String -> String
stanzaKind = map toLower . takeWhile (not . isSpace)

-- | Values from every occurrence of a field, on its own or continuation lines.
fieldValues :: String -> String -> [String]
fieldValues field = go . lines
  where
    expected = map toLower (takeWhile (/= ':') (trim field))
    go [] = []
    go (line : rest)
        | (name, ':' : inline) <- break (== ':') (cabalLine line)
        , map toLower (trim name) == expected =
            let fieldIndent = indentation line
                (continuation, remaining) =
                    span
                        (\next -> null (cabalLine next) || indentation next > fieldIndent)
                        rest
             in tokens (inline : map cabalLine continuation) <> go remaining
        | otherwise = go rest

    tokens = words . map (\character -> if character == ',' then ' ' else character) . unlines

-- Cabal comments occupy whole lines or follow whitespace in these descriptions.
cabalLine :: String -> String
cabalLine = unwords . takeWhile (not . isPrefixOf "--") . words

-- | All option tokens the shared @common warnings@ stanza declares.
commonWarningsOptions :: String -> String
commonWarningsOptions description =
    maybe "" (unwords . fieldValues "ghc-options") (namedStanza "common warnings" description)

-- | The source walker shared by component enumeration and test-source guards.
listComponentSources :: FilePath -> ComponentStanza -> IO [FilePath]
listComponentSources packageRoot component = do
    sources <- concat <$> traverse (listHaskellSources . (packageRoot </>)) (componentSourceDirs component)
    pure . sort . nub $
        [ path
        | path <- sources
        , stanzaKind (componentHeader component) /= "test-suite"
            || "compile-fail" `notElem` splitDirectories (makeRelative packageRoot path)
        ]

-- | All test-suite source directories, recursively, without compile-fail inputs.
listTestSources :: FilePath -> String -> IO [FilePath]
listTestSources packageRoot description =
    fmap (sort . nub . concat) . traverse (listComponentSources packageRoot) $
        filter ((== "test-suite") . stanzaKind . componentHeader) (componentStanzas description)

-- | Run a guard over every test source, optionally excusing its one owning file.
forEachTestSourceBut :: FilePath -> (FilePath -> String -> IO ()) -> IO ()
forEachTestSourceBut owner check =
    withPackageSourceIn [] $ \packageRoot _ -> do
        description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
        paths <- listTestSources packageRoot description
        forM_ paths $ \path -> do
            let relative = repoRelativePath packageRoot path
            if relative == owner || relative == "test/" <> owner
                then pure ()
                else readFile path >>= check relative

{- | The body of the package description's /unnamed/ main library stanza.

A named library (@library effect-internal@) is a different component with its
own module list, so the header must be the bare word.
-}
mainLibraryStanza :: String -> Maybe String
mainLibraryStanza = namedStanza "library"

{- | Every module named by one field of a stanza.

*field* may include its colon (@"exposed-modules:"@); names are case-neutral. A value may begin on
the field's own line and continue on any line indented past it, which is both
layouts Cabal permits — reading only one of them is how two copies of this
function came to enumerate two different module sets from one file.
-}
fieldModules :: String -> String -> [String]
fieldModules field = filter isModuleName . fieldValues field
  where
    isModuleName name = case break (== '.') name of
        (segment, _dot : rest) -> isModuleSegment segment && isModuleName rest
        (segment, []) -> isModuleSegment segment

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

{- | First-party modules and the names their plain import lists probe.

The closed fixture grammar is @f@, @T@, @T(children)@ and @T(..)@. A whole
module import has no item names. Decorated first-party imports and unfamiliar
items refuse explicitly; external imports are outside this inventory.
-}
firstPartyImportItems :: String -> Either String [(String, [String])]
firstPartyImportItems = collect . haskellTokens
  where
    collect [] = Right []
    collect ("foreign" : "import" : remaining) = collect remaining
    collect ("import" : remaining) = case parseModuleNameWithRest (dropImportDecorators remaining) of
        Just (name, afterName)
            | packageModule name -> do
                if dropImportDecorators remaining == remaining
                    then pure ()
                    else Left ("unsupported first-party import decorators: " <> name)
                (items, rest) <- case afterName of
                    "(" : afterOpen -> case balancedTokens ")" afterOpen of
                        Just (tokens, afterClose) -> do
                            names <- importItems tokens
                            pure (names, afterClose)
                        Nothing -> Left ("unbalanced first-party import list: " <> name)
                    decorator : _ | decorator `elem` ["qualified", "as", "hiding"] ->
                        Left ("unsupported first-party import decorators: " <> name)
                    _ -> Right ([], afterName)
                ((name, items) :) <$> collect rest
        Just (_, afterName) -> collect afterName
        Nothing -> Left "unsupported import declaration header"
    collect (_ : remaining) = collect remaining
    packageModule name = name == "HostBootstrap" || "HostBootstrap." `isPrefixOf` name
    importItems tokens = splitTokenGroups "," tokens >>= groups item
    groups _ [] = Right []
    groups _ [[]] = Right [] -- An empty list or a final trailing comma.
    groups parse (first : remaining) = (<>) <$> parse first <*> groups parse remaining
    item [name] | plainIdentifier name = Right [name]
    item [parent, "(", "..", ")"] | isModuleSegment parent = Right [parent]
    item (parent : "(" : remaining)
        | isModuleSegment parent
        , Just (children, []) <- balancedTokens ")" remaining = do
            childGroups <- splitTokenGroups "," children
            names <- groups (fmap pure . child) childGroups
            if null names then Left "an explicit child list is empty" else Right (parent : names)
    item tokens = Left ("unsupported first-party import item: " <> show tokens)
    child [name] | plainIdentifier name = Right name
    child tokens = Left ("unsupported first-party import child: " <> show tokens)

-- | Names in genuine top-level definition positions, independent of exports.
--
-- Imports, signatures alone, role annotations, instance implementations and
-- expression/pattern/type occurrences cannot manufacture definitions. The
-- closed declaration grammar covers this tree and refuses unfamiliar shapes.
haskellDefinitionNames :: String -> Either String [String]
haskellDefinitionNames source = sort . nub . concat <$> traverse declaration blocks
  where
    blocks = sourceTextBlocks . unlines . cppLines . lines . maskHaskellComments $ source
    cppLines [] = []
    cppLines (line : remaining) = case dropWhile isSpace line of
        '#' : _ -> directive line remaining
        _ -> line : cppLines remaining
    directive line remaining = "" : case reverse (dropWhile isSpace (reverse line)) of
        continued | "\\" `isSuffixOf` continued -> case remaining of
            next : rest -> directive next rest
            [] -> []
        _ -> cppLines remaining
    declaration block = case haskellTokens block of
        [] -> Right []
        "{" : "-#" : _ -> Right []
        keyword : _ | keyword `elem` ["module", "import", "where", "instance", "deriving", "infix", "infixl", "infixr", "default"] -> Right []
        "type" : "role" : _ -> Right []
        "type" : "instance" : _ -> Right []
        "type" : "family" : remaining -> typeName remaining
        "type" : remaining -> typeName remaining
        "data" : remaining -> dataNames block remaining
        "newtype" : remaining -> dataNames block remaining
        "class" : remaining -> do
            name <- typeName remaining
            members <- nestedBlocks block >>= traverse classMember
            pure (name <> concat members)
        "foreign" : "import" : remaining -> do
            (header, rest) <- breakTokenLevel ["::"] remaining
            case (reverse header, rest) of
                (name : _, "::" : _) | valueIdentifier name -> Right [name]
                _ -> Left "unsupported foreign-import binder"
        "foreign" : "export" : _ -> Right []
        tokens -> valueDefinition tokens
    typeName tokens = do
        (header, _) <- breakTokenLevel ["=", "where"] tokens
        (_, context) <- breakTokenLevel ["=>"] header
        case (header, context) of
            (name : _, []) | isModuleSegment name -> Right [name]
            _ -> Left ("unsupported type/class definition: " <> show (take 12 tokens))
    dataNames block remaining = do
        name <- typeName remaining
        (_, body) <- breakTokenLevel ["=", "where", "deriving"] remaining
        constructors <- case body of
            "=" : alternatives -> do
                (fields, _) <- breakTokenLevel ["deriving"] alternatives
                splitTokenGroups "|" fields >>= fmap concat . traverse prefixConstructor
            "where" : _ -> nestedBlocks block >>= fmap concat . traverse gadtConstructor
            [] -> Right []
            "deriving" : _ -> Right []
            _ -> Left "unsupported data/newtype declaration"
        pure (name <> constructors)
    prefixConstructor tokens = do
        remaining <- case tokens of
            "forall" : quantified -> do
                (_, afterBinder) <- breakTokenLevel ["."] quantified
                case afterBinder of
                    "." : afterDot -> Right afterDot
                    _ -> Left "an existential constructor has no binder terminator"
            _ -> Right tokens
        (_, context) <- breakTokenLevel ["=>"] remaining
        case (remaining, context) of
            (name : fields, []) | isModuleSegment name -> (name :) <$> recordLabels fields
            _ -> Left ("unsupported prefix constructor: " <> show (take 12 remaining))
    gadtConstructor block = do
        (names, rest) <- breakTokenLevel ["::"] (haskellTokens block)
        constructors <- commaNames isModuleSegment names
        case rest of
            "::" : fields -> (constructors <>) <$> recordLabels fields
            _ -> Left "unsupported GADT constructor declaration"
    classMember block = case haskellTokens block of
        "type" : "family" : remaining -> typeName remaining
        "type" : remaining -> typeName remaining
        tokens -> do
            (names, rest) <- breakTokenLevel ["::", "=", "|"] tokens
            case rest of
                "::" : _ -> commaNames valueIdentifier names
                _ -> valueDefinition tokens
    valueDefinition tokens@(name : remaining) | valueIdentifier name = do
        (arguments, rest) <- breakTokenLevel ["::", "=", "where", "|"] remaining
        case rest of
            "::" : _ -> Right []
            "=" : _ -> prefixArguments arguments >> Right [name]
            "|" : guards -> do
                prefixArguments arguments
                (_, equation) <- breakTokenLevel ["=", "where"] guards
                case equation of
                    "=" : _ -> Right [name]
                    _ -> Left "a guarded value has no equation"
            _ -> Left ("unsupported value definition: " <> show (take 12 tokens))
    valueDefinition tokens = Left ("unsupported top-level declaration: " <> show (take 12 tokens))
    prefixArguments [] = Right ()
    prefixArguments (opening : remaining)
        | Just closing <- lookup opening [("(", ")"), ("[", "]"), ("{", "}")] =
            case balancedTokens closing remaining of
                Just (_, rest) -> prefixArguments rest
                Nothing -> Left "unbalanced prefix argument pattern"
        | isModuleSegment opening, "." : rest <- remaining = qualifiedPattern rest
        | plainIdentifier opening || opening `elem` ["_", "@"] || literal opening = prefixArguments remaining
        | otherwise = Left ("unsupported infix/non-prefix value lhs: " <> show opening)
    qualifiedPattern (name : "." : remaining) | isModuleSegment name = qualifiedPattern remaining
    qualifiedPattern (name : remaining) | isModuleSegment name = prefixArguments remaining
    qualifiedPattern _ = Left "unsupported qualified argument pattern"
    literal (first : _) = isDigit first || first `elem` "\"'"
    literal [] = False
    nestedBlocks block = case dropWhile (not . elem "where" . haskellTokens) (lines block) of
        header : body -> case dropWhile (/= "where") (haskellTokens header) of
            ["where"] -> case [indentation line | line <- body, not (all isSpace line)] of
                first : remaining -> Right (sourceTextBlocks (unlines (map (drop (foldl min first remaining)) body)))
                [] -> Right []
            _ -> Left "unsupported inline class/GADT body"
        [] -> Left "a class/GADT declaration has no where line"

{- | Tokens of one complete, uniquely defined prefix value binding.

The existing declaration reader distinguishes equations from signatures; the
block reader retains guards and local bindings while excluding neighbouring
definitions. Missing, ambiguous, and unsupported bindings refuse.
-}
haskellDefinitionTokens :: String -> String -> Either String [String]
haskellDefinitionTokens wanted source
    | not (valueIdentifier wanted) = Left ("unsupported value name: " <> wanted)
    | otherwise = do
        definitions <- traverse inspect candidates
        case [tokens | (names, tokens) <- definitions, wanted `elem` names] of
            [tokens] -> Right tokens
            [] -> Left ("value definition missing: " <> wanted)
            _ -> Left ("value definition is ambiguous: " <> wanted)
  where
    candidates =
        [ block
        | block <- sourceTextBlocks source
        , name : _ <- [haskellTokens block]
        , name == wanted
        ]
    inspect block = do
        names <- haskellDefinitionNames block
        let tokens = haskellTokens block
        _ <- breakTokenLevel [] tokens
        pure (names, tokens)

{- | Ordered constructors of one unparameterized ordinary nullary data sum.

The shared declaration blocks exclude comments and neighbouring definitions.
Payloads, records, GADTs, duplicate constructors and unfamiliar deriving syntax
refuse rather than yielding a partial vocabulary.
-}
nullaryDataConstructorNames :: String -> String -> Either String [String]
nullaryDataConstructorNames wanted source
    | not (isModuleSegment wanted) = Left ("unsupported data name: " <> wanted)
    | otherwise = case declarations of
        [tokens] -> do
            _ <- breakTokenLevel [] tokens
            fields <- case tokens of
                "data" : name : "=" : remaining | name == wanted -> Right remaining
                _ -> Left "expected an unparameterized ordinary data declaration"
            (alternatives, trailing) <- breakTokenLevel ["deriving"] fields
            derivingClause trailing
            constructors <- splitTokenGroups "|" alternatives >>= traverse nullary
            if null constructors || length constructors /= length (nub constructors)
                then Left "a nullary data sum must have nonempty unique constructors"
                else Right constructors
        [] -> Left ("data declaration missing: " <> wanted)
        _ -> Left ("data declaration is ambiguous: " <> wanted)
  where
    declarations =
        [ tokens
        | block <- sourceTextBlocks source
        , let tokens = haskellTokens block
        , keyword : name : _ <- [tokens]
        , keyword `elem` ["data", "newtype"]
        , name == wanted
        ]
    nullary [name] | isModuleSegment name = Right name
    nullary _ = Left "expected a nullary prefix constructor"
    derivingClause [] = Right ()
    derivingClause ["deriving", name] | isModuleSegment name = Right ()
    derivingClause ("deriving" : "(" : remaining) = case balancedTokens ")" remaining of
        Just (classes, []) -> do
            names <- commaNames isModuleSegment classes
            if null names then Left "an empty deriving clause is unsupported" else Right ()
        _ -> Left "malformed deriving clause"
    derivingClause _ = Left "unsupported deriving clause"

plainIdentifier :: String -> Bool
plainIdentifier name = isModuleSegment name || valueIdentifier name

valueIdentifier :: String -> Bool
valueIdentifier (first : remaining) = (isLower first || first == '_')
    && all (\character -> isAlphaNum character || character `elem` "_'") remaining
    && (first : remaining) `notElem`
        ["_", "case", "class", "data", "default", "deriving", "do", "else", "foreign", "if", "import", "in", "infix", "infixl", "infixr", "let", "module", "newtype", "of", "then", "type", "where", "pattern", "forall"]
valueIdentifier [] = False

-- Delimiters inside balanced groups do not separate declarations or fields.
breakTokenLevel :: [String] -> [String] -> Either String ([String], [String])
breakTokenLevel delimiters = go []
  where
    go reversed [] = Right (reverse reversed, [])
    go reversed remaining@(token : rest)
        | token `elem` delimiters = Right (reverse reversed, remaining)
        | Just closing <- lookup token [("(", ")"), ("[", "]"), ("{", "}")] =
            case balancedTokens closing rest of
                Just (inside, afterClose) -> go (reverse (token : inside <> [closing]) <> reversed) afterClose
                Nothing -> Left "unbalanced declaration tokens"
        | token `elem` [")", "]", "}"] = Left "unexpected closing declaration delimiter"
        | otherwise = go (token : reversed) rest

splitTokenGroups :: String -> [String] -> Either String [[String]]
splitTokenGroups separator tokens = do
    (first, rest) <- breakTokenLevel [separator] tokens
    case rest of
        _separator : remaining -> (first :) <$> splitTokenGroups separator remaining
        [] -> Right [first]

commaNames :: (String -> Bool) -> [String] -> Either String [String]
commaNames accepts tokens = do
    groups <- splitTokenGroups "," tokens
    traverse one groups
  where
    one [name] | accepts name = Right name
    one group = Left ("unsupported declaration binder list: " <> show group)

-- | Ordered labels of one uniquely named, single-constructor record declaration.
-- Other declaration shapes refuse rather than yielding a partial field inventory.
recordFieldNames :: String -> String -> Either String [String]
recordFieldNames wanted source =
    case declarations of
        [remaining] -> do
            (_, body) <- breakTokenLevel ["=", "where"] remaining
            alternatives <- case body of
                "=" : tokens -> fst <$> breakTokenLevel ["deriving"] tokens
                _ -> Left ("record declaration has no ordinary constructor: " <> wanted)
            constructors <- splitTokenGroups "|" alternatives
            fields <- case constructors of
                [constructor : "{" : tokens] | isModuleSegment constructor ->
                    case balancedTokens "}" tokens of
                        Just (inside, []) -> recordLabels ("{" : inside <> ["}"])
                        _ -> Left ("record constructor is unbalanced or has extra fields: " <> wanted)
                _ -> Left ("record declaration must have one record constructor: " <> wanted)
            if length fields == length (nub fields)
                then Right fields
                else Left ("record declaration repeats a field: " <> wanted)
        [] -> Left ("record declaration missing: " <> wanted)
        _ -> Left ("record declaration is ambiguous: " <> wanted)
  where
    declarations =
        [ remaining
        | keyword : name : remaining <- sourceBlocks source
        , keyword `elem` ["data", "newtype"]
        , name == wanted
        ]

recordLabels :: [String] -> Either String [String]
recordLabels [] = Right []
recordLabels (opening : remaining)
    | Just closing <- lookup opening [("(", ")"), ("[", "]"), ("{", "}")] =
        case balancedTokens closing remaining of
            Just (inside, afterClose) -> do
                labels <- if opening == "{" then fields [] inside else Right []
                (labels <>) <$> recordLabels afterClose
            Nothing -> Left "unbalanced constructor field tokens"
    | opening `elem` [")", "]", "}"] = Left "unexpected closing constructor field delimiter"
    | otherwise = recordLabels remaining
  where
    fields pending tokens = do
        (names, rest) <- breakTokenLevel ["::", ","] tokens
        case rest of
            "," : afterComma -> do
                group <- commaNames valueIdentifier names
                fields (pending <> group) afterComma
            "::" : fieldType -> do
                group <- commaNames valueIdentifier names
                (declaredType, tailFields) <- breakTokenLevel [","] fieldType
                if null declaredType
                    then Left "a record label has an empty type declaration"
                    else do
                        more <- case tailFields of
                            "," : afterComma -> fields [] afterComma
                            [] -> Right []
                            _ -> Left "unsupported record field separator"
                        pure (pending <> group <> more)
            [] | null names && null pending -> Right []
            _ -> Left "a record label has no type declaration"

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
