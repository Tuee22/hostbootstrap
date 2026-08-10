-- | Lexical helpers for dependency-direction source guards.
--
-- These parse only Haskell import declarations, but deliberately use the
-- standard lexer so comments and string literals cannot create false imports.
-- Source pragmas, package-qualified imports, qualifiers, and multiline imports
-- are all accepted.
module SourceGuard
    ( haskellImports
    , importsModule
    , moduleImportTokens
    , moduleExportTokens
    , countHaskellIdentifier
    , countHaskellTokenSequence
    )
where

import Data.Char (isAlphaNum, isSpace, isUpper)
import Data.List (intercalate)

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
