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
  -- A phase doc missing its Documentation Requirements section.
  writeFile (root </> "DEVELOPMENT_PLAN" </> "phase-9-x.md") (unlines ["# Phase 9", "body"])
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
      "category not in the canonical taxonomy"
    ]
    expect
