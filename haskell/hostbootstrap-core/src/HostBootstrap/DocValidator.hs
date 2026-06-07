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
--
-- It runs through the project's canonical code-check via the
-- @hostbootstrap-core-test@ suite (exercised by @DocValidatorSpec@).
module HostBootstrap.DocValidator
  ( Violation (..),
    validateRepo,
    renderViolation,
    findRepoRoot,
  )
where

import Control.Monad (filterM, foldM)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, sortOn)
import System.Directory
  ( doesDirectoryExist,
    doesFileExist,
    listDirectory,
  )
import System.FilePath
  ( makeRelative,
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
      architectureDocs = filter (("documents/architecture/" `isInfixOf`) . normalise) docFiles
  metaV <- concatMapM (checkGovernedMeta root) docFiles
  rootV <- concatMapM (checkRootDoc root) rootDocs
  broadV <- concatMapM (checkBroadDoctrine root) architectureDocs
  reqV <- concatMapM (checkDocRequirements root) phaseDocs
  linkV <- concatMapM (checkLinks root) (docFiles ++ planFiles ++ rootDocs)
  readmeV <- checkReadmeRefs root
  pure (sortOn (\v -> (vFile v, vMessage v)) (metaV ++ rootV ++ broadV ++ reqV ++ linkV ++ readmeV))

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
  contents <- readFile readme
  let rel = rrel root readme
  pure $
    concat
      [ [Violation rel "root README.md does not reference documents/" | not ("documents/" `isInfixOf` contents)],
        [Violation rel "root README.md does not reference DEVELOPMENT_PLAN/" | not ("DEVELOPMENT_PLAN/" `isInfixOf` contents)]
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
      pure (filter ((== ".md") . takeExtension) files ++ nested)

rrel :: FilePath -> FilePath -> FilePath
rrel root = makeRelative (normalise root) . normalise

trim :: String -> String
trim = trimStart . reverse . trimStart . reverse

trimStart :: String -> String
trimStart = dropWhile (`elem` (" \t" :: String))

concatMapM :: (Monad m) => (a -> m [b]) -> [a] -> m [b]
concatMapM f xs = concat <$> mapM f xs
