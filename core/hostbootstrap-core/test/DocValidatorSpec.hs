{-# LANGUAGE ScopedTypeVariables #-}

module DocValidatorSpec (tests) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import HostBootstrap.DocValidator
  ( findRepoRoot,
    renderViolation,
    validateRepo,
  )
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

-- | The documentation validator runs through the canonical code-check: the
-- governed @documents/@ suite, root docs, and the @DEVELOPMENT_PLAN/@ phase plan
-- must conform to @documents/documentation_standards.md@.
tests :: IO TestTree
tests = do
  cwd <- getCurrentDirectory
  mroot <- findRepoRoot cwd
  pure $
    testGroup
      "DocValidatorSpec"
      [ testCase "governed documentation conforms to the standard" (realRepoCase cwd mroot),
        testCase "validator flags missing metadata, links, and sections" negativeCase
      ]

realRepoCase :: FilePath -> Maybe FilePath -> IO ()
realRepoCase cwd mroot = case mroot of
  Nothing ->
    assertFailure ("could not locate repo root (documents/ + DEVELOPMENT_PLAN/) from " ++ cwd)
  Just root -> do
    violations <- validateRepo root
    case violations of
      [] -> pure ()
      vs ->
        assertFailure $
          "documentation validator found "
            ++ show (length vs)
            ++ " violation(s):\n"
            ++ unlines (map renderViolation vs)

-- | Build a deliberately broken miniature repo and assert the validator reports
-- the expected violation classes, proving the checks are not vacuous.
negativeCase :: IO ()
negativeCase = withSystemTempDirectory "hb-docval" $ \root -> do
  createDirectoryIfMissing True (root </> "documents" </> "architecture")
  createDirectoryIfMissing True (root </> "DEVELOPMENT_PLAN")
  -- A governed doc missing every metadata line and with a broken link.
  writeFile
    (root </> "documents" </> "architecture" </> "broken.md")
    (unlines ["Not a heading", "[dangling](does_not_exist.md)"])
  -- README missing the DEVELOPMENT_PLAN reference and not a proper root block.
  writeFile (root </> "README.md") (unlines ["# hostbootstrap", "see documents/ only"])
  writeFile (root </> "AGENTS.md") (unlines ["# Agents", "**Status**: Governed entry document", "**Supersedes**: N/A", "**Canonical homes**: x", "> **Purpose**: y"])
  writeFile (root </> "CLAUDE.md") (unlines ["# Claude", "**Status**: Governed entry document", "**Supersedes**: N/A", "**Canonical homes**: x", "> **Purpose**: y"])
  -- A phase doc missing its Documentation Requirements section and every § G
  -- header field. Its number is 9, so with no phase-0..8 present the numbering
  -- check also fires on the gap.
  writeFile (root </> "DEVELOPMENT_PLAN" </> "phase-9-x.md") (unlines ["# the canonical-quantities-and-reconcile-results phase", "body"])
  -- A phase doc that violates every plan-doctrine rule at once (§ A, § C, § G,
  -- § II): it depends on a HIGHER-numbered phase, declares two non-baseline
  -- substrates, carries a reversal in a sprint title, gives that sprint a
  -- `Blocked by` field, tags it with a status outside the closed vocabulary, and
  -- leaves an Active sprint's Remaining Work empty.
  writeFile
    (root </> "DEVELOPMENT_PLAN" </> "phase-10-doctrine.md")
    ( unlines
        [ "# Phase 10 — doctrine violations",
          "",
          "**Status**: Blocked",
          "**Depends on**: [Phase 9](phase-9-x.md), [Phase 12](phase-12-later.md)",
          "**Substrates**: linux-cpu, apple-silicon, nvidia",
          "**Gate**: none",
          "",
          "## Sprints",
          "",
          "### Sprint 10.1: Retire the old surface [Superseded]",
          "",
          "**Status**: Active",
          "**Blocked by**: Sprint 12.1",
          "",
          "#### Remaining Work",
          "",
          "## Documentation Requirements",
          ""
        ]
    )
  writeFile
    (root </> "DEVELOPMENT_PLAN" </> "phase-12-later.md")
    (unlines ["# Phase 12 — later", "", "**Status**: Planned", "**Depends on**: none", "**Substrates**: linux-cpu", "**Gate**: none", "", "## Documentation Requirements", ""])
  -- A mis-named governed doc (not snake_case) under a valid category; it carries
  -- a complete metadata block so only the naming check fires on it.
  writeFile
    (root </> "documents" </> "architecture" </> "BadName.md")
    ( unlines
        [ "# Bad",
          "**Status**: Authoritative source",
          "**Supersedes**: N/A",
          "**Referenced by**: x",
          "> **Purpose**: y",
          "## TL;DR",
          "- z"
        ]
    )
  -- A well-formed architecture doc that intentionally omits TL;DR / Executive
  -- Summary, so the broad-doctrine structure check fires directly.
  writeFile
    (root </> "documents" </> "architecture" </> "no_summary.md")
    ( unlines
        [ "# No Summary",
          "**Status**: Authoritative source",
          "**Supersedes**: N/A",
          "**Referenced by**: x",
          "> **Purpose**: y",
          "## Current Status",
          "- z"
        ]
    )
  -- A documents/ category outside the canonical taxonomy.
  createDirectoryIfMissing True (root </> "documents" </> "reference")
  violations <- validateRepo root
  let msgs = map renderViolation violations
      expect needle =
        assertBool
          ("expected a violation matching " ++ show needle ++ " in:\n" ++ unlines msgs)
          (any (needle `isInfixOf`) msgs)
  forM_
    [ "missing **Status**: line",
      "first non-empty line is not a '# Title' heading",
      "unresolved relative link: does_not_exist.md",
      "does not reference DEVELOPMENT_PLAN/",
      "phase document missing '## Documentation Requirements' section",
      "broad doctrine doc missing",
      "file name is not lowercase snake_case: BadName.md",
      "category not in the canonical taxonomy",
      -- Plan doctrine (development_plan_standards.md § A, § C, § G, § II).
      "phase numbering is not contiguous from 0",
      "phase document missing '**Depends on**:' header field",
      "phase status is not one of Done|Active|Planned: Blocked",
      "depends on phase 12, which is not strictly lower",
      "phase declares more than one non-baseline substrate",
      "phase narrative reverses earlier work",
      "sprint carries a '**Blocked by**' field",
      "sprint title has no [Done|Active|Planned] tag",
      "an Active sprint has an empty '#### Remaining Work' section"
    ]
    expect
