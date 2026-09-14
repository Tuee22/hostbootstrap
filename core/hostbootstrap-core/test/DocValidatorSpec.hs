{-# LANGUAGE ScopedTypeVariables #-}

module DocValidatorSpec (tests) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import HostBootstrap.DocValidator (
    checkAcceptanceTerminal,
    checkArchitectureDrift,
    checkEntryDocAgreement,
    checkGateEvidenceLegs,
    checkIdentifierResolution,
    checkLinkAnchors,
    checkPhaseHeaderFields,
    checkRootDocStatus,
    checkGateEvidence,
    checkImplementationPaths,
    checkPhaseOrdering,
    checkSubstrateBudget,
    findRepoRoot,
    renderViolation,
    vFile,
    validateRepo,
 )
import qualified SourceGuard
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hSetEncoding, utf8, withFile)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

{- | The documentation validator runs through the canonical code-check: the
governed @documents/@ suite, root docs, and the @DEVELOPMENT_PLAN/@ phase plan
must conform to @documents/documentation_standards.md@.
-}
tests :: IO TestTree
tests = do
    cwd <- getCurrentDirectory
    mroot <- findRepoRoot cwd
    pure $
        testGroup
            "DocValidatorSpec"
            [ testCase "governed documentation conforms to the standard" (realRepoCase cwd mroot)
            , testCase "validator flags missing metadata, links, and sections" negativeCase
            , testCase "architecture drift guards reject obsolete authority and numeric citations" architectureCase
            , testCase "implementation citations and Done evidence are checked against the tree" citationCase
            , testCase "wrapped header fields are read whole, in the spelling the plan uses" fieldReadingCase
            , testCase "backticked identifiers resolve against the tree, with a reviewed allowlist" identifierCase
            , testCase "a root document may summarize the plan's status and may not contradict it" rootStatusCase
            , testCase "the two entry documents differ only by the declared audience words" entryDocCase
            , testCase "a link fragment names a heading the target document has" anchorCase
            , testCase "a phase header carries no field the standard does not declare" headerFieldCase
            , testCase "an evidence row records every leg its gate names" gateLegCase
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

{- | Build a deliberately broken miniature repo and assert the validator reports
the expected violation classes, proving the checks are not vacuous.
-}
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
            [ "# Development Plan"
            , ""
            , "## Current Phase Status"
            , ""
            , "| # | Phase | Status | Substrate | Open |"
            , "|---|-------|--------|-----------|------|"
            , "| 10 | [Doctrine](phase-10-doctrine.md) | Done | linux-cpu | — |"
            , "| 12 | [Later](phase-12-later.md) | Planned | linux-cpu | — |"
            , "| 12 | [Later duplicate](phase-12-later.md) | Planned | linux-cpu | — |"
            , "| banana | no phase link | Maybe | linux-cpu | — |"
            , ""
            , "## Notes"
            , ""
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
            [ "# Phase 10 — doctrine violations"
            , ""
            , "**Status**: Blocked"
            , "**Depends on**: [Phase 9](phase-9-x.md), [Phase 12](phase-12-later.md)"
            , "**Substrates**: linux-cpu, apple-silicon, nvidia"
            , "**Gate**: none"
            , ""
            , "## Sprints"
            , ""
            , "### Sprint 10.1: Retire the old surface [Superseded]"
            , ""
            , "**Status**: Active"
            , "**Blocked by**: Sprint 12.1"
            , ""
            , "#### Remaining Work"
            , ""
            , "## Documentation Requirements"
            , ""
            ]
        )
    -- An Active phase with no phase-level Remaining Work at all, and (below) one
    -- whose section carries the drifted spelling. 94w C requires the section; the
    -- spelling is what makes one defect report as one correction rather than as a
    -- second missing section.
    writeUtf8
        (root </> "DEVELOPMENT_PLAN" </> "phase-13-no-remaining.md")
        ( unlines
            [ "# Phase 13 — active, owing nothing it says"
            , ""
            , "**Status**: Active"
            , "**Depends on**: none"
            , "**Substrates**: linux-cpu"
            , "**Gate**: none"
            , ""
            , "## Documentation Requirements"
            , ""
            ]
        )
    writeUtf8
        (root </> "DEVELOPMENT_PLAN" </> "phase-14-drifted-heading.md")
        ( unlines
            [ "# Phase 14 — active, with the drifted heading"
            , ""
            , "**Status**: Active"
            , "**Depends on**: none"
            , "**Substrates**: linux-cpu"
            , "**Gate**: none"
            , ""
            , "## Phase Remaining Work"
            , ""
            , "Everything."
            , ""
            , "## Documentation Requirements"
            , ""
            ]
        )
    -- A phase whose sprints break the Done-sprint rules two different ways: one
    -- Done sprint still declares work, and another has no Remaining Work section
    -- at all. Its phase-level section is deliberately present and non-empty, so
    -- neither Done-sprint violation can be confused with a phase-level one.
    writeUtf8
        (root </> "DEVELOPMENT_PLAN" </> "phase-11-done-sprints.md")
        ( unlines
            [ "# Phase 11 — Done sprints that are not done"
            , ""
            , "**Status**: Active"
            , "**Depends on**: none"
            , "**Substrates**: linux-cpu"
            , "**Gate**: none"
            , ""
            , "## Sprints"
            , ""
            , "### Sprint 11.1: a sprint that still owes work [Done]"
            , ""
            , "**Status**: Done"
            , ""
            , "#### Remaining Work"
            , ""
            , "Waits on the [later phase](phase-12-later.md)."
            , ""
            , "### Sprint 11.2: a sprint with no section at all [Done]"
            , ""
            , "**Status**: Done"
            , ""
            , "#### Validation"
            , ""
            , "The [later phase](phase-12-later.md) confirms it live."
            , ""
            , "## Remaining Work"
            , ""
            , "Closes when the [later phase](phase-12-later.md) lands."
            , ""
            , "## Documentation Requirements"
            , ""
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
            [ "# Bad"
            , "**Status**: Authoritative source"
            , "**Supersedes**: N/A"
            , "**Referenced by**: x"
            , "> **Purpose**: y"
            , "## TL;DR"
            , "- z"
            ]
        )
    -- A well-formed architecture doc that intentionally omits TL;DR / Executive
    -- Summary, so the broad-doctrine structure check fires directly.
    writeUtf8
        (root </> "documents" </> "architecture" </> "no_summary.md")
        ( unlines
            [ "# No Summary"
            , "**Status**: Authoritative source"
            , "**Supersedes**: N/A"
            , "**Referenced by**: x"
            , "> **Purpose**: y"
            , "## Current Status"
            , "- z"
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
            [ "# Standards"
            , ""
            , "## Core Principles"
            , ""
            , "### A. A principle that owns no phase"
            , ""
            , "Doctrine, not a contract."
            , ""
            , "## hostbootstrap-Specific Contracts"
            , ""
            , "### K. An owned contract"
            , ""
            , "**Owning phase**: [doctrine](phase-10-doctrine.md)"
            , ""
            , "Body."
            , ""
            , "### N. A contract that only mentions a phase"
            , ""
            , "The [doctrine phase](phase-10-doctrine.md) is cited here, but nothing"
            , "says it owns this."
            , ""
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
            [ "# Legacy"
            , ""
            , "| Shape | Location | Why | Deleted by |"
            , "|---|---|---|---|"
            , "| a shape | `src/X.hs` | reason | nobody in particular |"
            , "| another | `src/Y.hs` | reason | [a phase](phase-99-missing.md) |"
            , "| a third | `src/Z.hs` | a phase cited here does not count "
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
        [ "missing **Status**: line"
        , "first non-empty line is not a '# Title' heading"
        , "unresolved relative link: does_not_exist.md"
        , "does not reference DEVELOPMENT_PLAN/"
        , "phase document missing '## Documentation Requirements' section"
        , "broad doctrine doc missing"
        , "file name is not lowercase snake_case: BadName.md"
        , "category not in the canonical taxonomy"
        , -- Plan doctrine (development_plan_standards.md § A, § C, § G, § II).
          "phase numbering is not contiguous from 0"
        , "phase document missing '**Depends on**:' header field"
        , "phase status is not one of Done|Active|Planned: Blocked"
        , "Current Phase Status table is missing phase 9 row"
        , "duplicate Current Phase Status row for phase number 12"
        , "malformed Current Phase Status row"
        , "phase status mismatch for phase 10: README has Done but the phase header has Blocked"
        , "depends on phase 12, which is not strictly lower"
        , "phase declares more than one non-baseline substrate"
        , "phase narrative reverses earlier work"
        , "sprint carries a '**Blocked by**' field"
        , "sprint title has no [Done|Active|Planned] tag"
        , "an Active Sprint 10.1 has an empty '#### Remaining Work' section"
        , -- \194\167 I: a ledger row must name a deleting phase, and it must resolve.
          "legacy ledger row names no deleting phase"
        , "legacy ledger row names an unresolvable deleting phase: phase-99-missing.md"
        , "legacy ledger row names 2 deleting phases"
        , -- 94w C and 94w G: a Done sprint owes nothing and says so.
          "Done Sprint 11.1 declares remaining work"
        , "Done Sprint 11.2 has no '#### Remaining Work' section"
        , -- 94w C: an Active phase owes a section, spelled one way.
          "an Active phase has no '## Remaining Work' section"
        , "phase-level remaining work is headed '## Phase Remaining Work'"
        , -- 94w A: a Remaining Work section never cites a later phase.
          "Sprint 11.1's '#### Remaining Work' cites phase 12"
        , "the phase's '## Remaining Work' cites phase 12"
        , -- Each contract names its owning phase, in a declared field.
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

{- | The identifier-resolution check fires on a name no source declares, stays
silent on one that resolves, and stays silent on a reviewed allowlist entry.

The positive half matters as much as the negative one: a check that flags every
abbreviation would be turned off within a week, and then the vocabulary it was
installed to catch walks back in.
-}
identifierCase :: IO ()
identifierCase = withSystemTempDirectory "hb-identifier" $ \root -> do
    let source = root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap"
    createDirectoryIfMissing True source
    createDirectoryIfMissing True (root </> "documents" </> "architecture")
    writeUtf8
        (source </> "Example.hs")
        (unlines ["module HostBootstrap.Example where", "", "realProducer :: Int", "realProducer = 1", "", "data RealType = RealType"])
    -- A page naming only things that exist, plus one allowlisted abbreviation.
    writeUtf8
        (root </> "documents" </> "architecture" </> "clean.md")
        (unlines
            [ "# Clean"
            , ""
            , "`RealType` is produced by `realProducer`, and `HostBootstrap.Example` owns both."
            , "The `OneShot` shape is a label rather than a dispatch value."
            , ""
            , "```haskell"
            , "thisIsInsideAFenceAndIsNotChecked :: NoSuchTypeAtAll"
            , "```"
            ]
        )
    checkIdentifierResolution root >>= (@?= [])
    -- The same page with one name nothing declares.
    writeUtf8
        (root </> "documents" </> "architecture" </> "drifted.md")
        (unlines ["# Drifted", "", "The `vanishedProducer` mints a `RealType`."])
    violations <- checkIdentifierResolution root
    let messages = map renderViolation violations
    length messages @?= 1
    assertBool
        ("the refusal names the dead identifier: " ++ unlines messages)
        (any ("vanishedProducer" `isInfixOf`) messages)
    assertBool
        ("the refusal names the allowlist as the reviewed escape: " ++ unlines messages)
        (any ("identifierAllowlist" `isInfixOf`) messages)

{- | A root document that repeats the table's status is compared against it. -}
rootStatusCase :: IO ()
rootStatusCase = withSystemTempDirectory "hb-root-status" $ \root -> do
    createDirectoryIfMissing True (root </> "DEVELOPMENT_PLAN")
    writeUtf8
        (root </> "DEVELOPMENT_PLAN" </> "README.md")
        ( unlines
            [ "# Development Plan"
            , ""
            , "## Current Phase Status"
            , ""
            , "| # | Phase | Status | Substrate | Open |"
            , "|---|-------|--------|-----------|------|"
            , "| 7 | [Seven](phase-7-seven.md) | Done | linux-cpu | — |"
            ]
        )
    -- Pointing at the table without restating it is clean.
    writeUtf8
        (root </> "README.md")
        (unlines ["# hostbootstrap", "", "Status lives in [the plan](DEVELOPMENT_PLAN/README.md); see [seven](DEVELOPMENT_PLAN/phase-7-seven.md)."])
    checkRootDocStatus root >>= (@?= [])
    -- Restating it, wrongly, is not.
    writeUtf8
        (root </> "README.md")
        (unlines ["# hostbootstrap", "", "The [seven phase](DEVELOPMENT_PLAN/phase-7-seven.md) is still Active."])
    messages <- map renderViolation <$> checkRootDocStatus root
    length messages @?= 1
    assertBool
        ("the refusal names both statuses: " ++ unlines messages)
        (any (\m -> "Active" `isInfixOf` m && "Done" `isInfixOf` m) messages)

{- | A one-sided edit to either entry document is a violation. -}
entryDocCase :: IO ()
entryDocCase = withSystemTempDirectory "hb-entry-docs" $ \root -> do
    writeUtf8 (root </> "AGENTS.md") (unlines ["# Agent Instructions", "", "An agent may read AGENTS.md.", "Agents must not commit."])
    writeUtf8 (root </> "CLAUDE.md") (unlines ["# Claude Instructions", "", "An assistant may read CLAUDE.md.", "Assistants must not commit."])
    checkEntryDocAgreement root >>= (@?= [])
    writeUtf8 (root </> "CLAUDE.md") (unlines ["# Claude Instructions", "", "An assistant may read CLAUDE.md.", "Assistants may commit."])
    messages <- map renderViolation <$> checkEntryDocAgreement root
    assertBool
        ("the one-sided edit is reported: " ++ unlines messages)
        (any ("line 4" `isInfixOf`) messages)

{- | A fragment that names no heading is a dead link even though its path resolves. -}
anchorCase :: IO ()
anchorCase = withSystemTempDirectory "hb-anchors" $ \root -> do
    createDirectoryIfMissing True (root </> "documents")
    writeUtf8 (root </> "documents" </> "target.md") (unlines ["# Target", "", "## Consumer project", "", "text"])
    writeUtf8 (root </> "documents" </> "source.md") (unlines ["# Source", "", "See [it](target.md#consumer-project)."])
    checkLinkAnchors root (root </> "documents" </> "source.md") >>= (@?= [])
    writeUtf8 (root </> "documents" </> "source.md") (unlines ["# Source", "", "See [it](target.md#renamed-away)."])
    messages <- map renderViolation <$> checkLinkAnchors root (root </> "documents" </> "source.md")
    length messages @?= 1
    assertBool
        ("the refusal names the fragment: " ++ unlines messages)
        (any ("renamed-away" `isInfixOf`) messages)

{- | An invented phase-header field is a violation even when it reads plausibly. -}
headerFieldCase :: IO ()
headerFieldCase = withSystemTempDirectory "hb-header-fields" $ \root -> do
    createDirectoryIfMissing True (root </> "DEVELOPMENT_PLAN")
    let phase = root </> "DEVELOPMENT_PLAN" </> "phase-3-example.md"
        declared =
            [ "# Phase 3 — example"
            , ""
            , "**Status**: Done"
            , "**Depends on**: Phase 2 (scaffolding)"
            , "**Substrates**: linux-cpu"
            , "**Gate**: `cabal test all` from `core/`"
            , "**Gate kind**: self-verifying"
            , "**Gate evidence**: 2026-01-01 ; a host ; `cabal test all` ; pass ; covers in-gate"
            , ""
            , "> **Purpose**: one sentence."
            , ""
            , "## Phase Objective"
            ]
    writeUtf8 phase (unlines declared)
    checkPhaseHeaderFields root phase >>= (@?= [])
    writeUtf8 phase (unlines (take 3 declared ++ ["**Current sprint**: None — phase complete"] ++ drop 3 declared))
    messages <- map renderViolation <$> checkPhaseHeaderFields root phase
    length messages @?= 1
    assertBool
        ("the refusal names the invented field: " ++ unlines messages)
        (any ("Current sprint" `isInfixOf`) messages)

{- | A composed gate with half its legs recorded is a violation. -}
gateLegCase :: IO ()
gateLegCase = withSystemTempDirectory "hb-gate-legs" $ \root -> do
    createDirectoryIfMissing True (root </> "DEVELOPMENT_PLAN")
    let phase = root </> "DEVELOPMENT_PLAN" </> "phase-4-example.md"
        header row =
            [ "# Phase 4 — example"
            , ""
            , "**Status**: Done"
            , "**Depends on**: Phase 3 (example)"
            , "**Substrates**: linux-cpu"
            , "**Gate**: `cabal test all` from `core/` plus live `hostbootstrap run -- project up`"
            , "**Gate kind**: deferred"
            , row
            , ""
            , "> **Purpose**: one sentence."
            , ""
            , "## Phase Objective"
            ]
    writeUtf8
        phase
        ( unlines
            ( header
                "**Gate evidence**: 2026-01-01 ; a host ; `cabal test all --ghc-options=-Werror` and `hostbootstrap run -- project up` ; pass ; covers abc"
            )
        )
    checkGateEvidenceLegs root phase >>= (@?= [])
    writeUtf8
        phase
        (unlines (header "**Gate evidence**: 2026-01-01 ; a host ; `cabal test all --ghc-options=-Werror` ; pass ; covers abc"))
    messages <- map renderViolation <$> checkGateEvidenceLegs root phase
    length messages @?= 1
    assertBool
        ("the refusal names the unrecorded leg: " ++ unlines messages)
        (any ("project up" `isInfixOf`) messages)

architectureCase :: IO ()
architectureCase = withSystemTempDirectory "hb-architecture-drift" $ \root -> do
    let source = root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap"
    createDirectoryIfMissing True (source </> "Authority" </> "ProjectPlan")
    createDirectoryIfMissing True (source </> "Handoff")
    createDirectoryIfMissing True (source </> "Service")
    createDirectoryIfMissing True (root </> "documents")
    checkArchitectureDrift root >>= (@?= [])
    writeUtf8 (source </> "Authority" </> "ProjectPlan" </> "Internal.hs") "module Obsolete where"
    writeUtf8 (source </> "Handoff" </> "Lifecycle.hs") "module Obsolete where"
    writeUtf8 (source </> "Authority" </> "Kernel.hs") "data ProductionCloseRoot = ProductionCloseRoot"
    writeUtf8 (source </> "Service.hs") "type ServiceHandler fields = fields -> IO ()"
    writeUtf8 (source </> "Service" </> "Internal.hs") "data ServiceAction = LegacyServiceAction (IO ())"
    writeUtf8 (root </> "documents" </> "example.md") "See Phase 17 and its implementation."
    writeUtf8 (source </> "Example.hs") "-- Sprint 17.1 owns this boundary."
    violations <- checkArchitectureDrift root
    let messages = map renderViolation violations
        paths = map (SourceGuard.repoRelativePath root . (root </>) . vFile) violations
    length messages @?= 7
    forM_ ["Authority/ProjectPlan/Internal.hs", "Handoff/Lifecycle.hs", "ProductionCloseRoot", "ServiceHandler", "LegacyServiceAction", "example.md", "Example.hs"] $ \name ->
        assertBool
            ("missing drift refusal for " ++ name ++ ": " ++ unlines messages)
            (any (name `isInfixOf`) (paths ++ messages))
    assertBool
        "every drift refusal names the owning phase to rewrite"
        (all ("rewrite DEVELOPMENT_PLAN/phase-" `isInfixOf`) messages)
    -- A phase's durable name and file link remain valid under renumbering.
    writeUtf8 (root </> "documents" </> "example.md") "See [recursive lifecycle](../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)."
    remaining <- checkArchitectureDrift root
    length remaining @?= 6

{- | The two checks that answer "is this phase still describing the tree?".

Both failures this exercises stood in the real plan: a module relocated between
Cabal stanzas left its citing sprints pointing at a path that no longer existed,
and one phase read Done while carrying no dated run at all. Neither is visible to
any other check here, which is the point — the status bookkeeping stays coherent
either way.
-}
citationCase :: IO ()
citationCase = withSystemTempDirectory "hb-citation-drift" $ \root -> do
    let plan = root </> "DEVELOPMENT_PLAN"
        source = root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap"
        present = "core/hostbootstrap-core/src/HostBootstrap/HostTool.hs"
        dated = "On 2026-09-06 the complete gate passed."
        -- 'readLines' reads lazily, so each variant gets its own document rather
        -- than rewriting one path a still-open handle is holding.
        writeDocument name body = do
            let file = plan </> ("phase-3-" ++ name ++ ".md")
            writeUtf8 file body
            pure file
        document name status implementation validation =
            writeDocument name (phaseDocument status implementation validation)
    createDirectoryIfMissing True plan
    createDirectoryIfMissing True source
    writeUtf8 (source </> "HostTool.hs") "module HostBootstrap.HostTool where"

    -- A Done phase citing a file that is there, with a dated run, satisfies both.
    intact <- document "intact" "Done" present dated
    checkImplementationPaths root intact >>= (@?= [])
    checkGateEvidence root intact >>= (@?= [])

    -- The same sprint after the module moves: the citation is refused by name.
    relocated <- document "relocated" "Done" "core/hostbootstrap-core/src/HostBootstrap/Moved.hs" dated
    moved <- map renderViolation <$> checkImplementationPaths root relocated
    length moved @?= 1
    assertBool
        ("citation refusal names the missing path: " ++ unlines moved)
        (any ("Moved.hs" `isInfixOf`) moved)

    -- A glob names a scope rather than a file, and a directory resolves as itself.
    globbed <- document "globbed" "Done" "core/hostbootstrap-core/src/**" dated
    checkImplementationPaths root globbed >>= (@?= [])
    directory <- document "directory" "Done" "core/hostbootstrap-core/src" dated
    checkImplementationPaths root directory >>= (@?= [])

    -- A Done phase recording no gate evidence at all is refused.
    undated <- writeDocument "undated" (phaseDocumentWith "Done" present "The dated run." "")
    checkGateEvidence root intact >>= (@?= [])
    dateless <-
        map renderViolation
            <$> checkGateEvidence root undated
    length dateless @?= 1
    assertBool
        ("the missing evidence row is named: " ++ unlines dateless)
        (any ("records no '**Gate evidence**' row" `isInfixOf`) dateless)

    -- An impossible calendar date is not a date, however well shaped.
    impossible <-
        writeDocument
            "impossible"
            ( phaseDocumentWith
                "Done"
                present
                "The dated run."
                "**Gate evidence**: 2026-02-30 ; a gate host ; `cabal test all` ; pass ; covers in-gate"
            )
    malformed <- map renderViolation <$> checkGateEvidence root impossible
    length malformed @?= 1
    assertBool
        ("the impossible date is refused: " ++ unlines malformed)
        (any ("is not <date>" `isInfixOf`) malformed)

    -- The same document as an Active phase is owed rather than overdue.
    owed <- document "owed" "Active" present "The dated run."
    checkGateEvidence root owed >>= (@?= [])

-- | The smallest § G-shaped phase document the two checks read.
phaseDocument :: String -> FilePath -> String -> String
phaseDocument status implementation validation = phaseDocumentWith status implementation validation selfVerifyingEvidence

{- | A self-verifying phase's evidence row: its gate is re-executed by the run
that validates the plan, so it covers @in-gate@ rather than a digest.
-}
selfVerifyingEvidence :: String
selfVerifyingEvidence =
    "**Gate evidence**: 2026-09-06 ; a gate host ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate"

phaseDocumentWith :: String -> FilePath -> String -> String -> String
phaseDocumentWith status implementation validation evidence =
    unlines
        [ "# Phase Three \8212 Host tools"
        , ""
        , "**Status**: " ++ status
        , "**Depends on**: none"
        , "**Substrates**: linux-cpu"
        , "**Gate**: `cabal test all --ghc-options=-Werror` from `core/`"
        , "**Gate kind**: self-verifying"
        , evidence
        , ""
        , "## Sprints"
        , ""
        , "### Sprint 3.1: The resolver [" ++ status ++ "]"
        , ""
        , "**Status**: " ++ status
        , "**Implementation**: `" ++ implementation ++ "`"
        , "**Substrates**: linux-cpu"
        , ""
        , "#### Validation"
        , ""
        , validation
        , ""
        , "#### Remaining Work"
        , ""
        , "None."
        , ""
        , "## Remaining Work"
        , ""
        , "None."
        ]

{- | The header fields three checks read, in the shape the plan actually writes them.

Each half of this is a defect that shipped. 'checkPhaseOrdering' matched only
@phase-NN-@ link targets while every @Depends on@ value in the plan is prose, so
the check its own comment calls the one the doctrine rests on fired on nothing.
'checkSubstrateBudget' read one value per document and so covered thirty of the
plan's four hundred and six. Both are read here in the wrapped, prose form the
plan uses, because a fixture written in the form the check already handled would
have passed against the broken code too.
-}
fieldReadingCase :: IO ()
fieldReadingCase = withSystemTempDirectory "hb-field-reading" $ \root -> do
    let plan = root </> "DEVELOPMENT_PLAN"
        document name body = do
            let file = plan </> ("phase-" ++ name ++ ".md")
            writeUtf8 file body
            pure file
    createDirectoryIfMissing True plan

    -- A dependency named in prose, on a continuation line, is still a dependency.
    wrapped <-
        document
            "7-wrapped"
            ( unlines
                [ "# Phase Seven"
                , ""
                , "**Status**: Done"
                , "**Depends on**: Phase 2 (core scaffolding), Phase 4 (protected store),"
                , "Phase 9 (lifecycle modes and run leases)"
                , "**Substrates**: linux-cpu"
                , "**Gate**: `cabal test all`"
                , ""
                , "## Remaining Work"
                , ""
                , "None."
                ]
            )
    forward <- map renderViolation <$> checkPhaseOrdering root wrapped
    length forward @?= 1
    assertBool
        ("the continuation line's forward dependency is reported: " ++ unlines forward)
        (any ("depends on phase 9" `isInfixOf`) forward)

    -- Every **Substrates** declaration is read, not just the header's.
    substrates <-
        document
            "8-substrates"
            ( unlines
                [ "# Phase Eight"
                , ""
                , "**Status**: Done"
                , "**Depends on**: nothing"
                , "**Substrates**: linux-cpu"
                , "**Gate**: `cabal test all`"
                , ""
                , "## Sprints"
                , ""
                , "### Sprint 8.1: A sprint [Done]"
                , ""
                , "**Status**: Done"
                , "**Substrates**: \8212"
                , ""
                , "## Remaining Work"
                , ""
                , "None."
                ]
            )
    vocabulary <- map renderViolation <$> checkSubstrateBudget root substrates
    length vocabulary @?= 1
    assertBool
        ("a sprint's out-of-vocabulary substrate is reported: " ++ unlines vocabulary)
        (any ("substrate declaration is not one of" `isInfixOf`) vocabulary)

    -- Nothing may depend on a phase that declares a non-baseline substrate.
    _ <-
        document
            "6-acceptance"
            ( unlines
                [ "# Phase Nine"
                , ""
                , "**Status**: Done"
                , "**Depends on**: nothing"
                , "**Substrates**: nvidia"
                , "**Gate**: live acceptance"
                , ""
                , "## Remaining Work"
                , ""
                , "None."
                ]
            )
    dependent <-
        document
            "10-dependent"
            ( unlines
                [ "# Phase Ten"
                , ""
                , "**Status**: Done"
                , "**Depends on**: Phase 6 (the accelerator acceptance)"
                , "**Substrates**: linux-cpu"
                , "**Gate**: `cabal test all`"
                , ""
                , "## Remaining Work"
                , ""
                , "None."
                ]
            )
    plan' <- pure [wrapped, substrates, plan </> "phase-6-acceptance.md", dependent]
    terminal <- map renderViolation <$> checkAcceptanceTerminal root plan'
    length terminal @?= 1
    assertBool
        ("the edge into the acceptance phase is reported: " ++ unlines terminal)
        (any ("acceptance phases terminal" `isInfixOf`) terminal)

writeUtf8 :: FilePath -> String -> IO ()
writeUtf8 path content =
    withFile path WriteMode $ \handle -> do
        hSetEncoding handle utf8
        TextIO.hPutStr handle (Text.pack content)
