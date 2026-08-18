{-# LANGUAGE ScopedTypeVariables #-}

module DocValidatorSpec (tests) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import HostBootstrap.DocValidator
  ( findRepoRoot,
    renderViolation,
    validateRepo,
  )
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hSetEncoding, utf8, withFile)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
  writeUtf8
    (root </> "documents" </> "architecture" </> "broken.md")
    (unlines ["Not a heading", "[dangling](does_not_exist.md)"])
  -- README missing the DEVELOPMENT_PLAN reference and not a proper root block.
  writeUtf8 (root </> "README.md") (unlines ["# hostbootstrap", "see documents/ only"])
  writeUtf8 (root </> "AGENTS.md") (unlines ["# Agents", "**Status**: Governed entry document", "**Supersedes**: N/A", "**Canonical homes**: x", "> **Purpose**: y"])
  writeUtf8 (root </> "CLAUDE.md") (unlines ["# Claude", "**Status**: Governed entry document", "**Supersedes**: N/A", "**Canonical homes**: x", "> **Purpose**: y"])
  -- The cross-phase table deliberately omits phase 9, duplicates phase 12,
  -- contains one malformed row, and disagrees with phase 10's local header.
  -- This proves status harmony cannot pass merely because a table exists.
  writeUtf8
    (root </> "DEVELOPMENT_PLAN" </> "README.md")
    ( unlines
        [ "# Development Plan",
          "",
          "## Current Phase Status",
          "",
          "| # | Phase | Status | Substrate | Open |",
          "|---|-------|--------|-----------|------|",
          "| 10 | [Doctrine](phase-10-doctrine.md) | Done | linux-cpu | — |",
          "| 12 | [Later](phase-12-later.md) | Planned | linux-cpu | — |",
          "| 12 | [Later duplicate](phase-12-later.md) | Planned | linux-cpu | — |",
          "| banana | no phase link | Maybe | linux-cpu | — |",
          "",
          "## Notes",
          ""
        ]
    )
  -- A phase doc missing its Documentation Requirements section and every § G
  -- header field. Its number is 9, so with no phase-0..8 present the numbering
  -- check also fires on the gap.
  writeUtf8 (root </> "DEVELOPMENT_PLAN" </> "phase-9-x.md") (unlines ["# the canonical-quantities-and-reconcile-results phase", "body"])
  -- A phase doc that violates every plan-doctrine rule at once (§ A, § C, § G,
  -- § II): it depends on a HIGHER-numbered phase, declares two non-baseline
  -- substrates, carries a reversal in a sprint title, gives that sprint a
  -- `Blocked by` field, tags it with a status outside the closed vocabulary, and
  -- leaves an Active sprint's Remaining Work empty.
  writeUtf8
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
  -- An Active phase with no phase-level Remaining Work at all, and (below) one
  -- whose section carries the drifted spelling. 94w C requires the section; the
  -- spelling is what makes one defect report as one correction rather than as a
  -- second missing section.
  writeUtf8
    (root </> "DEVELOPMENT_PLAN" </> "phase-13-no-remaining.md")
    ( unlines
        [ "# Phase 13 — active, owing nothing it says",
          "",
          "**Status**: Active",
          "**Depends on**: none",
          "**Substrates**: linux-cpu",
          "**Gate**: none",
          "",
          "## Documentation Requirements",
          ""
        ]
    )
  writeUtf8
    (root </> "DEVELOPMENT_PLAN" </> "phase-14-drifted-heading.md")
    ( unlines
        [ "# Phase 14 — active, with the drifted heading",
          "",
          "**Status**: Active",
          "**Depends on**: none",
          "**Substrates**: linux-cpu",
          "**Gate**: none",
          "",
          "## Phase Remaining Work",
          "",
          "Everything.",
          "",
          "## Documentation Requirements",
          ""
        ]
    )
  -- A phase whose sprints break the Done-sprint rules two different ways: one
  -- Done sprint still declares work, and another has no Remaining Work section
  -- at all. Its phase-level section is deliberately present and non-empty, so
  -- neither Done-sprint violation can be confused with a phase-level one.
  writeUtf8
    (root </> "DEVELOPMENT_PLAN" </> "phase-11-done-sprints.md")
    ( unlines
        [ "# Phase 11 — Done sprints that are not done",
          "",
          "**Status**: Active",
          "**Depends on**: none",
          "**Substrates**: linux-cpu",
          "**Gate**: none",
          "",
          "## Sprints",
          "",
          "### Sprint 11.1: a sprint that still owes work [Done]",
          "",
          "**Status**: Done",
          "",
          "#### Remaining Work",
          "",
          "Waits on the [later phase](phase-12-later.md).",
          "",
          "### Sprint 11.2: a sprint with no section at all [Done]",
          "",
          "**Status**: Done",
          "",
          "#### Validation",
          "",
          "The [later phase](phase-12-later.md) confirms it live.",
          "",
          "## Remaining Work",
          "",
          "Closes when the [later phase](phase-12-later.md) lands.",
          "",
          "## Documentation Requirements",
          ""
        ]
    )
  writeUtf8
    (root </> "DEVELOPMENT_PLAN" </> "phase-12-later.md")
    (unlines ["# Phase 12 — later", "", "**Status**: Planned", "**Depends on**: none", "**Substrates**: linux-cpu", "**Gate**: none", "", "## Documentation Requirements", ""])
  -- A mis-named governed doc (not snake_case) under a valid category; it carries
  -- a complete metadata block so only the naming check fires on it.
  writeUtf8
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
  writeUtf8
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
  -- A minimal standards document. Only the contract sections beneath the
  -- hostbootstrap-Specific Contracts heading owe an owning phase; the core
  -- principles above it are doctrine about how the plan is written and own no
  -- phase, so a check that flagged them would be flagging the wrong thing.
  writeUtf8
    (root </> "DEVELOPMENT_PLAN" </> "development_plan_standards.md")
    ( unlines
        [ "# Standards",
          "",
          "## Core Principles",
          "",
          "### A. A principle that owns no phase",
          "",
          "Doctrine, not a contract.",
          "",
          "## hostbootstrap-Specific Contracts",
          "",
          "### K. An owned contract",
          "",
          "**Owning phase**: [doctrine](phase-10-doctrine.md)",
          "",
          "Body.",
          "",
          "### N. A contract that only mentions a phase",
          "",
          "The [doctrine phase](phase-10-doctrine.md) is cited here, but nothing",
          "says it owns this.",
          ""
        ]
    )
  -- A legacy ledger with one unowned row, one naming a phase that does not
  -- exist. \194\167 I permits the ledger only because every row names a deleting
  -- phase; a row without one is a standing cleanup obligation, which is the
  -- repair log the section forbids, and a row with two is the same failure
  -- wearing a different hat, because neither phase's completion empties it.
  -- The two-owner row's targets both resolve, so the arity violation is proved
  -- to fire independently of the resolution one.
  writeUtf8
    (root </> "DEVELOPMENT_PLAN" </> "legacy_tracking_for_deletion.md")
    ( unlines
        [ "# Legacy",
          "",
          "| Shape | Location | Why | Deleted by |",
          "|---|---|---|---|",
          "| a shape | `src/X.hs` | reason | nobody in particular |",
          "| another | `src/Y.hs` | reason | [a phase](phase-99-missing.md) |",
          "| a third | `src/Z.hs` | a phase cited here does not count "
            ++ "([not this one](phase-10-doctrine.md)) "
            ++ "| [one](phase-10-doctrine.md) and [two](phase-12-later.md) |"
        ]
    )
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
      "Current Phase Status table is missing phase 9 row",
      "duplicate Current Phase Status row for phase number 12",
      "malformed Current Phase Status row",
      "phase status mismatch for phase 10: README has Done but the phase header has Blocked",
      "depends on phase 12, which is not strictly lower",
      "phase declares more than one non-baseline substrate",
      "phase narrative reverses earlier work",
      "sprint carries a '**Blocked by**' field",
      "sprint title has no [Done|Active|Planned] tag",
      "an Active Sprint 10.1 has an empty '#### Remaining Work' section",
      -- \194\167 I: a ledger row must name a deleting phase, and it must resolve.
      "legacy ledger row names no deleting phase",
      "legacy ledger row names an unresolvable deleting phase: phase-99-missing.md",
      "legacy ledger row names 2 deleting phases",
      -- 94w C and 94w G: a Done sprint owes nothing and says so.
      "Done Sprint 11.1 declares remaining work",
      "Done Sprint 11.2 has no '#### Remaining Work' section",
      -- 94w C: an Active phase owes a section, spelled one way.
      "an Active phase has no '## Remaining Work' section",
      "phase-level remaining work is headed '## Phase Remaining Work'",
      -- 94w A: a Remaining Work section never cites a later phase.
      "Sprint 11.1's '#### Remaining Work' cites phase 12",
      "the phase's '## Remaining Work' cites phase 12",
      -- Each contract names its owning phase, in a declared field.
      "contract section N names no owning phase"
    ]
    expect
  -- Scope is the whole precision of that check. Sprint 11.2's Validation cites
  -- the same later phase and must stay legal, so exactly two citations are
  -- reported: a third would mean the check reads sections it has no business in.
  length (filter ("cites phase 12" `isInfixOf`) msgs) @?= 2
  -- The two scopings of that check, each proved by an absence. A core principle
  -- is not asked for an owner, and a contract that merely cites a phase is not
  -- credited with naming one -- the second is what makes the declared field
  -- worth requiring at all.
  forM_ ["contract section A ", "contract section K "] $ \needle ->
    assertBool
      ("no violation should mention " ++ show needle ++ ":" ++ unlines msgs)
      (not (any (needle `isInfixOf`) msgs))
  -- The arity check reads the Deleted by cell only. The third row cites a phase
  -- in its Why column too, and that citation must not be counted: a row reported
  -- as naming three deleting phases would mean the scoping is not there.
  assertBool
    ("the Why column must not count toward the deleting-phase arity:" ++ unlines msgs)
    (not (any ("names 3 deleting phases" `isInfixOf`) msgs))

writeUtf8 :: FilePath -> String -> IO ()
writeUtf8 path content =
  withFile path WriteMode $ \handle -> do
    hSetEncoding handle utf8
    TextIO.hPutStr handle (Text.pack content)
