-- | The mechanical documentation validator (Phase-0 quality-gate deliverable).
--
-- 'validateRepo' walks the governed @documents/@ suite, the governed root
-- documents (@README.md@, @AGENTS.md@, @CLAUDE.md@), and the @DEVELOPMENT_PLAN/@
-- phase plan, and returns the structural violations defined by
-- @documents/documentation_standards.md § Validation@:
--
--   * required metadata lines for governed @documents/@ content
--   * required structure for the broad doctrine docs (architecture suite)
--   * governed root-document metadata lines
--   * relative-link resolution for governed docs, root docs, and phase docs
--   * root @README.md@ references to both @documents/@ and @DEVELOPMENT_PLAN/@
--   * @DEVELOPMENT_PLAN/@ phase docs retaining @## Documentation Requirements@
--   * @snake_case@ file naming under @documents/@ (only @README.md@ is exempt)
--   * the canonical @documents/@ taxonomy (no top-level category outside the
--     declared set)
--
-- The individual checks are exported so the same mechanical floor can be reused
-- across the project family (the reusable family doc-floor). It runs through the
-- project's canonical code-check via the @hostbootstrap-core-test@ suite
-- (exercised by @DocValidatorSpec@).
module HostBootstrap.DocValidator
  ( Violation (..),
    validateRepo,
    renderViolation,
    findRepoRoot,
    allowedTaxonomy,

    -- * Reusable per-check functions (the family doc-floor)
    checkGovernedMeta,
    checkRootDoc,
    checkBroadDoctrine,
    checkDocRequirements,
    checkLinks,
    checkReadmeRefs,
    checkNaming,
    checkTaxonomy,
  )
where

import Control.Monad (filterM, foldM)
import Data.Char (isDigit)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, sort, sortOn)
import System.Directory
  ( doesDirectoryExist,
    doesFileExist,
    listDirectory,
  )
import System.FilePath
  ( addTrailingPathSeparator,
    makeRelative,
    normalise,
    takeDirectory,
    takeExtension,
    takeFileName,
    (</>),
  )

-- | A single structural violation: the offending file (repo-relative) and a
-- one-line description.
data Violation = Violation
  { vFile :: FilePath,
    vMessage :: String
  }
  deriving (Eq, Show)

renderViolation :: Violation -> String
renderViolation v = vFile v ++ ": " ++ vMessage v

-- | Validate the governed documentation under @root@. Returns an empty list
-- when the suite conforms.
validateRepo :: FilePath -> IO [Violation]
validateRepo root = do
  docFiles <- listMarkdown (root </> "documents")
  planFiles <- listMarkdown (root </> "DEVELOPMENT_PLAN")
  let rootDocs = map (root </>) ["README.md", "AGENTS.md", "CLAUDE.md"]
      phaseDocs = filter isPhaseDoc planFiles
      architectureDocs = filter (isUnderDirectory (root </> "documents" </> "architecture")) docFiles
  metaV <- concatMapM (checkGovernedMeta root) docFiles
  rootV <- concatMapM (checkRootDoc root) rootDocs
  broadV <- concatMapM (checkBroadDoctrine root) architectureDocs
  reqV <- concatMapM (checkDocRequirements root) phaseDocs
  existingRootDocs <- filterM doesFileExist rootDocs
  linkV <- concatMapM (checkLinks root) (docFiles ++ planFiles ++ existingRootDocs)
  readmeV <- checkReadmeRefs root
  let namingV = concatMap (checkNaming root) docFiles
  taxonomyV <- checkTaxonomy root
  pure
    ( sortOn
        (\v -> (vFile v, vMessage v))
        (metaV ++ rootV ++ broadV ++ reqV ++ linkV ++ readmeV ++ namingV ++ taxonomyV)
    )

-- | Locate the repository root by walking up from @start@ until a directory
-- containing both @documents/@ and @DEVELOPMENT_PLAN/@ is found.
findRepoRoot :: FilePath -> IO (Maybe FilePath)
findRepoRoot start = go (normalise start) (32 :: Int)
  where
    go _ 0 = pure Nothing
    go dir n = do
      hasDocs <- doesDirectoryExist (dir </> "documents")
      hasPlan <- doesDirectoryExist (dir </> "DEVELOPMENT_PLAN")
      if hasDocs && hasPlan
        then pure (Just dir)
        else
          let parent = takeDirectory dir
           in if parent == dir then pure Nothing else go parent (n - 1)

-- ---------------------------------------------------------------------------
-- Individual checks
-- ---------------------------------------------------------------------------

checkGovernedMeta :: FilePath -> FilePath -> IO [Violation]
checkGovernedMeta root file = do
  ls <- readLines file
  let rel = rrel root file
      missing label present = [Violation rel ("missing " ++ label) | not present]
  pure $
    concat
      [ [Violation rel "first non-empty line is not a '# Title' heading" | not (firstIsTitle ls)],
        missing "**Status**: line" (anyLineStarts "**Status**:" ls),
        missing "**Supersedes**: line" (anyLineStarts "**Supersedes**:" ls),
        missing "**Referenced by**: line" (anyLineStarts "**Referenced by**:" ls),
        missing "> **Purpose**: blockquote" (anyLineStarts "> **Purpose**:" ls),
        [Violation rel "YAML front-matter is no longer permitted" | hasYamlFrontMatter ls]
      ]

checkRootDoc :: FilePath -> FilePath -> IO [Violation]
checkRootDoc root file = do
  exists <- doesFileExist file
  if not exists
    then pure [Violation (rrel root file) "required root document is missing"]
    else checkRootDocPresent root file

checkRootDocPresent :: FilePath -> FilePath -> IO [Violation]
checkRootDocPresent root file = do
  ls <- readLines file
  let rel = rrel root file
      name = takeFileName file
      expectedStatus
        | name == "README.md" = "Governed orientation document"
        | otherwise = "Governed entry document"
      statusOk = any (\l -> ("**Status**:" `isPrefixOf` trimStart l) && (expectedStatus `isInfixOf` l)) ls
      missing label present = [Violation rel ("missing " ++ label) | not present]
  pure $
    concat
      [ [Violation rel "first non-empty line is not a '# Title' heading" | not (firstIsTitle ls)],
        [Violation rel ("**Status**: must read '" ++ expectedStatus ++ "'") | not statusOk],
        missing "**Supersedes**: line" (anyLineStarts "**Supersedes**:" ls),
        missing "**Canonical homes**: line" (anyLineStarts "**Canonical homes**:" ls),
        missing "> **Purpose**: blockquote" (anyLineStarts "> **Purpose**:" ls)
      ]

checkBroadDoctrine :: FilePath -> FilePath -> IO [Violation]
checkBroadDoctrine root file = do
  ls <- readLines file
  let rel = rrel root file
      hasSummary = anyLineStarts "## TL;DR" ls || anyLineStarts "## Executive Summary" ls
  pure [Violation rel "broad doctrine doc missing '## TL;DR' or '## Executive Summary'" | not hasSummary]

checkDocRequirements :: FilePath -> FilePath -> IO [Violation]
checkDocRequirements root file = do
  ls <- readLines file
  let rel = rrel root file
  pure [Violation rel "phase document missing '## Documentation Requirements' section" | not (anyLineStarts "## Documentation Requirements" ls)]

checkReadmeRefs :: FilePath -> IO [Violation]
checkReadmeRefs root = do
  let readme = root </> "README.md"
      rel = rrel root readme
  exists <- doesFileExist readme
  if not exists
    then pure [Violation rel "required root document is missing"]
    else do
      contents <- readFile readme
      pure $
        concat
          [ [Violation rel "root README.md does not reference documents/" | not ("documents/" `isInfixOf` contents)],
            [Violation rel "root README.md does not reference DEVELOPMENT_PLAN/" | not ("DEVELOPMENT_PLAN/" `isInfixOf` contents)]
          ]

-- | The canonical top-level categories under @documents/@. A directory outside
-- this set is a taxonomy violation; adding a category requires updating
-- @documents/documentation_standards.md § Taxonomy@ and this list in the same
-- change (see @development_plan_standards.md@).
allowedTaxonomy :: [String]
allowedTaxonomy = ["architecture", "engineering", "operations", "languages"]

-- | Governed @documents/@ files use lowercase @snake_case@ names with a @.md@
-- suffix; @README.md@ is the only permitted exception under @documents/@ (the
-- other ALL-CAPS root names live at the repository root). Pure.
checkNaming :: FilePath -> FilePath -> [Violation]
checkNaming root file =
  let rel = rrel root file
      name = takeFileName file
   in [ Violation rel ("file name is not lowercase snake_case: " ++ name)
        | name /= "README.md",
          not (isSnakeCaseMd name)
      ]

-- | A name is @snake_case.md@ when the stem is non-empty and uses only
-- lowercase letters, digits, and underscores.
isSnakeCaseMd :: String -> Bool
isSnakeCaseMd name =
  case reverse <$> stripPrefix' "dm." (reverse name) of
    Nothing -> False
    Just stem -> not (null stem) && all isSnakeChar stem
  where
    isSnakeChar c = isDigit c || c == '_' || (c >= 'a' && c <= 'z')
    stripPrefix' p s = if p `isPrefixOf` s then Just (drop (length p) s) else Nothing

-- | Every immediate subdirectory of @documents/@ must be a declared taxonomy
-- category ('allowedTaxonomy'). Files directly under @documents/@ (the suite
-- @README.md@ and @documentation_standards.md@) are unconstrained here.
checkTaxonomy :: FilePath -> IO [Violation]
checkTaxonomy root = do
  let docsDir = root </> "documents"
  exists <- doesDirectoryExist docsDir
  if not exists
    then pure []
    else do
      entries <- listDirectory docsDir
      subdirs <- filterM (doesDirectoryExist . (docsDir </>)) entries
      pure
        [ Violation
            ("documents" </> d)
            ("documents/ category not in the canonical taxonomy " ++ show allowedTaxonomy)
          | d <- subdirs,
            d `notElem` allowedTaxonomy
        ]

checkLinks :: FilePath -> FilePath -> IO [Violation]
checkLinks root file = do
  ls <- readLines file
  let rel = rrel root file
      targets = concatMap extractLinkTargets (stripFencedCode ls)
      checkable = filter isCheckableTarget targets
  foldM (step rel) [] checkable
  where
    step rel acc target = do
      let dropAnchor = takeWhile (/= '#') target
          resolved = normalise (takeDirectory file </> dropAnchor)
      existsF <- doesFileExist resolved
      existsD <- doesDirectoryExist resolved
      pure $
        if existsF || existsD
          then acc
          else acc ++ [Violation rel ("unresolved relative link: " ++ target)]

-- ---------------------------------------------------------------------------
-- Link extraction
-- ---------------------------------------------------------------------------

-- | A target is checkable when it is a relative in-repo path: not an external
-- URL, not a pure anchor, and not a placeholder ("...", angle brackets, spaces).
isCheckableTarget :: String -> Bool
isCheckableTarget t =
  not (null t)
    && not (any (`isPrefixOf` t) ["http://", "https://", "mailto:", "#", "/"])
    && not ("..." `isInfixOf` t)
    && not (any (`elem` ("<> " :: String)) t)
    && takeWhile (/= '#') t /= ""

-- | Extract every @](target)@ target from a line.
extractLinkTargets :: String -> [String]
extractLinkTargets = go
  where
    go [] = []
    go (']' : '(' : rest) =
      let (target, rest') = break (== ')') rest
       in target : go (drop 1 rest')
    go (_ : rest) = go rest

-- | Drop lines inside fenced code blocks (``` fences) so example links in the
-- standards docs are not treated as real references.
stripFencedCode :: [String] -> [String]
stripFencedCode = go False
  where
    go _ [] = []
    go inside (l : rest)
      | "```" `isPrefixOf` trimStart l = go (not inside) rest
      | inside = go inside rest
      | otherwise = l : go inside rest

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

isPhaseDoc :: FilePath -> Bool
isPhaseDoc f = "phase-" `isPrefixOf` takeFileName f && ".md" `isSuffixOf` f

firstIsTitle :: [String] -> Bool
firstIsTitle ls = case dropWhile (null . trim) ls of
  (l : _) -> "# " `isPrefixOf` l
  [] -> False

hasYamlFrontMatter :: [String] -> Bool
hasYamlFrontMatter ls = case dropWhile (null . trim) ls of
  (l : _) -> trim l == "---"
  [] -> False

anyLineStarts :: String -> [String] -> Bool
anyLineStarts p = any ((p `isPrefixOf`) . trimStart)

readLines :: FilePath -> IO [String]
readLines f = lines <$> readFile f

-- | Recursively list @.md@ files under a directory (sorted, repo-stable).
listMarkdown :: FilePath -> IO [FilePath]
listMarkdown dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- listDirectory dir
      let paths = map (dir </>) entries
      files <- filterM doesFileExist paths
      subdirs <- filterM doesDirectoryExist paths
      nested <- concatMapM listMarkdown subdirs
      pure (sort (filter ((== ".md") . takeExtension) files ++ nested))

rrel :: FilePath -> FilePath -> FilePath
rrel root = makeRelative (normalise root) . normalise

trim :: String -> String
trim = trimStart . reverse . trimStart . reverse

trimStart :: String -> String
trimStart = dropWhile (`elem` (" \t" :: String))

concatMapM :: (Monad m) => (a -> m [b]) -> [a] -> m [b]
concatMapM f xs = concat <$> mapM f xs

isUnderDirectory :: FilePath -> FilePath -> Bool
isUnderDirectory parent child =
  let prefix = addTrailingPathSeparator (normalise parent)
      candidate = normalise child
   in prefix `isPrefixOf` candidate
