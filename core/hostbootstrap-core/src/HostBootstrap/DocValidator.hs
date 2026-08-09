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
--   * relative-link resolution for governed docs, root docs, and all
--     @DEVELOPMENT_PLAN/@ docs
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

    -- * Plan-doctrine checks (development_plan_standards.md § A, § C, § G, § II)
    checkPhaseNumbering,
    checkPhaseHeader,
    checkPhaseOrdering,
    checkNoReversal,
    checkSprintStructure,
    checkSubstrateBudget,
    checkLegacyLedger,
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
  -- Plan doctrine (§ A, § C, § G, § II). The phase set is validated as a whole
  -- for contiguity, then each document individually.
  let numberingV = checkPhaseNumbering root phaseDocs
  headerV <- concatMapM (checkPhaseHeader root) phaseDocs
  orderingV <- concatMapM (checkPhaseOrdering root) phaseDocs
  reversalV <- concatMapM (checkNoReversal root) phaseDocs
  sprintV <- concatMapM (checkSprintStructure root) phaseDocs
  substrateV <- concatMapM (checkSubstrateBudget root) phaseDocs
  ledgerV <- checkLegacyLedger root
  pure
    ( sortOn
        (\v -> (vFile v, vMessage v))
        ( metaV
            ++ rootV
            ++ broadV
            ++ reqV
            ++ linkV
            ++ readmeV
            ++ namingV
            ++ taxonomyV
            ++ ledgerV
            ++ numberingV
            ++ headerV
            ++ orderingV
            ++ reversalV
            ++ sprintV
            ++ substrateV
        )
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

-- ---------------------------------------------------------------------------
-- Plan doctrine
--
-- @development_plan_standards.md@ § A makes phase numbers the execution order,
-- so these checks are what stop the plan from drifting back into a repair log
-- whose numbering means nothing. They are mechanical on purpose: the doctrine is
-- only real if a violation fails the build.
-- ---------------------------------------------------------------------------

{- | § E: the @phase-NN-*.md@ set is contiguous from 0 with no gaps and no
duplicates. A gap means a phase was deleted without renumbering; a duplicate
means two documents claim one execution position.
-}
checkPhaseNumbering :: FilePath -> [FilePath] -> [Violation]
checkPhaseNumbering root phaseDocs =
  duplicates ++ gaps
  where
    numbered = [(n, f) | f <- phaseDocs, Just n <- [phaseNumberOf f]]
    ns = sort (map fst numbered)
    rel = rrel root
    duplicates =
      [ Violation (rel f) ("duplicate phase number " ++ show n)
      | (n, f) <- numbered,
        length (filter (== n) ns) > 1
      ]
    gaps = case ns of
      [] -> []
      _ ->
        [ Violation "DEVELOPMENT_PLAN" ("phase numbering is not contiguous from 0: missing " ++ show missing)
        | let missing = [0 .. maximum ns] `without` ns,
          not (null missing)
        ]
    without xs ys = [x | x <- xs, x `notElem` ys]

{- | § G: a phase document carries the required header fields. @Depends on@ and
@Substrates@ are what the ordering and substrate-budget checks read, so a missing
field is a hole in both.
-}
checkPhaseHeader :: FilePath -> FilePath -> IO [Violation]
checkPhaseHeader root file = do
  ls <- readLines file
  let rel = rrel root file
      missing field =
        [ Violation rel ("phase document missing '**" ++ field ++ "**:' header field")
        | not (any (\l -> ("**" ++ field ++ "**:") `isPrefixOf` trim l) ls)
        ]
      badStatus =
        [ Violation rel ("phase status is not one of Done|Active|Planned: " ++ observed)
        | Just observed <- [fieldValue "Status" ls],
          observed `notElem` ["Done", "Active", "Planned"]
        ]
  pure (concatMap missing ["Status", "Depends on", "Substrates", "Gate"] ++ badStatus)

{- | § A: a phase depends only on strictly lower-numbered phases.

This is the check the whole doctrine rests on. The @Depends on@ field names
phases, and every @phase-NN-@ link in it must resolve to a number below this
document's own.
-}
checkPhaseOrdering :: FilePath -> FilePath -> IO [Violation]
checkPhaseOrdering root file = do
  ls <- readLines file
  let rel = rrel root file
  pure $ case (phaseNumberOf file, fieldValue "Depends on" ls) of
    (Just self, Just raw) ->
      [ Violation
          rel
          ( "phase "
              ++ show self
              ++ " depends on phase "
              ++ show dep
              ++ ", which is not strictly lower"
          )
      | dep <- referencedPhaseNumbers raw,
        dep >= self
      ]
    _ -> []

{- | § A: the narrative is strictly additive, so no phase document announces a
removal, a retirement, or a correction. A hit here means a reversal crept back
in, and the fix is to rewrite the phase that introduced the surface.
-}
checkNoReversal :: FilePath -> FilePath -> IO [Violation]
checkNoReversal root file = do
  ls <- readLines file
  let rel = rrel root file
      -- Only sprint titles and phase titles are scanned. Prose legitimately says
      -- "release removes the directory"; a *title* that announces a removal is
      -- the signal that a phase is undoing an earlier one.
      titles = [l | l <- ls, "### Sprint " `isPrefixOf` trim l || "# Phase " `isPrefixOf` trim l]
  pure
    [ Violation rel ("phase narrative reverses earlier work: " ++ word ++ " in " ++ trim l)
    | l <- titles,
      word <- reversalVocabulary,
      word `isInfixOf` l
    ]

{- | The vocabulary that marks a phase as undoing another (§ A).

Deliberately narrow. @Reopen@ is /not/ here: reopening an abandoned run is the
recovery phase's own domain vocabulary, and banning the word would force a worse
title rather than catch a reversal. The phase-reopening case this check exists
for is already covered by @Superseded@ and @Historical@, and by the ordering
check — a genuine reopening shows up as a dependency that is not strictly lower.
-}
reversalVocabulary :: [String]
reversalVocabulary =
  [ "Historical",
    "Superseded",
    "Retire",
    "Retired",
    "Deprecat",
    "Remove the",
    "Removal of",
    "Corrected",
    "Reproduced"
  ]

{- | § C and § G: every sprint declares a status from the closed vocabulary, an
@Active@ sprint has a non-empty @#### Remaining Work@, and no sprint carries a
@Blocked by@ field (there is nothing later to wait on).
-}
checkSprintStructure :: FilePath -> FilePath -> IO [Violation]
checkSprintStructure root file = do
  ls <- readLines file
  let rel = rrel root file
      blocked =
        [ Violation rel "sprint carries a '**Blocked by**' field, but a phase depends only on lower phases"
        | any (\l -> "**Blocked by**:" `isPrefixOf` trim l) ls
        ]
      titles =
        [ (title, trim (drop 1 (dropWhile (/= '[') title)))
        | l <- ls,
          "### Sprint " `isPrefixOf` trim l,
          let title = trim l
        ]
      badTag =
        [ Violation rel ("sprint title has no [Done|Active|Planned] tag: " ++ title)
        | (title, tag) <- titles,
          takeWhile (/= ']') tag `notElem` ["Done", "Active", "Planned"]
        ]
      activeWithoutWork =
        [ Violation rel "an Active sprint has an empty '#### Remaining Work' section"
        | any emptyActiveRemaining (sprintBlocks ls)
        ]
  pure (blocked ++ badTag ++ activeWithoutWork)
  where
    emptyActiveRemaining block =
      any (\l -> "**Status**: Active" `isPrefixOf` trim l) block
        && null (filter (not . null . trim) (remainingWorkBody block))
    -- The section body stops at the next heading of any level. Without that
    -- bound, a phase's trailing '## Documentation Requirements' counts as content
    -- and this check is vacuous for the last sprint of every phase.
    remainingWorkBody block =
      takeWhile (not . isHeading) (drop 1 (dropWhile (not . isPrefixOf "#### Remaining Work" . trim) block))
    isHeading l = "#" `isPrefixOf` trim l

{- | § II: a phase declares at most one substrate beyond the @linux-cpu@
baseline, so no phase is unclosable on a single machine.
-}
checkSubstrateBudget :: FilePath -> FilePath -> IO [Violation]
checkSubstrateBudget root file = do
  ls <- readLines file
  let rel = rrel root file
  pure $ case fieldValue "Substrates" ls of
    Nothing -> []
    Just raw ->
      let special = [s | s <- ["apple-silicon", "nvidia", "windows"], s `isInfixOf` raw]
       in [ Violation
              rel
              ("phase declares more than one non-baseline substrate: " ++ unwords special)
          | length special > 1
          ]

{- | § I: every row of the legacy ledger names a __deleting phase__ that resolves.

The ledger is permitted only because it records repository state — code still
standing that the architecture does not want — rather than a plan obligation. An
unowned row is exactly how that distinction collapses: with no phase whose
completion removes it, a row becomes a standing cleanup obligation, which is the
repair log § A forbids. So a row whose link does not resolve to a real phase
document fails the build, and the ledger's absence is not a violation because an
empty ledger is the healthy end state.
-}
checkLegacyLedger :: FilePath -> IO [Violation]
checkLegacyLedger root = do
  let ledger = root </> "DEVELOPMENT_PLAN" </> "legacy_tracking_for_deletion.md"
      rel = rrel root ledger
  exists <- doesFileExist ledger
  if not exists
    then pure []
    else do
      ls <- readLines ledger
      let rows = [l | l <- ls, "|" `isPrefixOf` trimStart l, isTrackedRow l]
      concatMapM (rowViolations root rel) rows

{- | A table row that tracks a shape, as opposed to the header or its separator.
A tracked row has the four columns the ledger declares and is not the header.
-}
isTrackedRow :: String -> Bool
isTrackedRow l =
  length (filter (== '|') l) >= 5
    && not ("| Shape" `isPrefixOf` trimStart l)
    && not ("|---" `isPrefixOf` filter (/= ' ') (trimStart l))

-- | The deleting phase a row names must resolve to a phase document.
rowViolations :: FilePath -> FilePath -> String -> IO [Violation]
rowViolations root rel row =
  case linkTargets row of
    [] ->
      pure
        [ Violation
            rel
            "legacy ledger row names no deleting phase; § I requires every row to name one"
        ]
    targets -> concatMapM (resolveTarget root rel) targets
  where
    resolveTarget r f target = do
      let candidate = r </> "DEVELOPMENT_PLAN" </> target
      present <- doesFileExist candidate
      pure
        [ Violation f ("legacy ledger row names an unresolvable deleting phase: " ++ target)
        | not present
        ]

-- | Markdown link targets in one line, unadorned by anchors or titles.
linkTargets :: String -> [String]
linkTargets = go
  where
    go [] = []
    go (c : rest)
      | c == '(' =
          let (target, remainder) = break (== ')') rest
           in [takeWhile (/= '#') target | isPhaseTarget target] ++ go remainder
      | otherwise = go rest
    isPhaseTarget t = "phase-" `isPrefixOf` t && ".md" `isInfixOf` t

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

-- | The execution position a phase document's filename declares.
phaseNumberOf :: FilePath -> Maybe Int
phaseNumberOf f = case span isDigit (drop (length ("phase-" :: String)) (takeFileName f)) of
  (digits@(_ : _), '-' : _) -> Just (read digits)
  _ -> Nothing

{- | The value of a @**Field**: value@ header line, trimmed. Only the first
occurrence is read, so a sprint-level field cannot shadow the phase header.
-}
fieldValue :: String -> [String] -> Maybe String
fieldValue field ls = case [trim (drop (length prefix) (trim l)) | l <- ls, prefix `isPrefixOf` trim l] of
  (v : _) -> Just v
  [] -> Nothing
  where
    prefix = "**" ++ field ++ "**:"

{- | Every phase number a @Depends on@ value mentions, read out of its
@phase-NN-@ links. Prose without a link contributes nothing, which is why § G
requires the field to link.
-}
referencedPhaseNumbers :: String -> [Int]
referencedPhaseNumbers = go
  where
    go [] = []
    go s@(_ : rest) = case stripPrefix' "phase-" s of
      Just after -> case span isDigit after of
        (digits@(_ : _), '-' : _) -> read digits : go rest
        _ -> go rest
      Nothing -> go rest
    stripPrefix' p xs
      | p `isPrefixOf` xs = Just (drop (length p) xs)
      | otherwise = Nothing

{- | Split a phase document into its sprint blocks, each running from its
@### Sprint@ heading to the next one.
-}
sprintBlocks :: [String] -> [[String]]
sprintBlocks ls = case dropWhile (not . isSprintHeading) ls of
  [] -> []
  (h : rest) ->
    let (body, remaining) = break isSprintHeading rest
     in (h : body) : sprintBlocks remaining
  where
    isSprintHeading l = "### Sprint " `isPrefixOf` trim l

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
