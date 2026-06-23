{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module DhallGenSpec (tests) where

import Control.Exception (SomeException, try)
import Data.List (find)
import qualified Data.Text as T
import qualified Dhall
import qualified Dhall.Core
import Fixture (projectConfigSchemaText)
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Dhall.Gen
  ( ConfigArtifact (..),
    coreArtifacts,
    deployConfigText,
    reflectedSchema,
    renderValue,
    schemaUnion,
  )
import HostBootstrap.DocValidator (findRepoRoot)
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | The absolute path of @Core.dhall@, usable as a Dhall import in test source.
corePath :: FilePath -> T.Text
corePath root = T.pack (root </> "core" </> "hostbootstrap-core" </> "dhall" </> "Core.dhall")

withRoot :: (FilePath -> IO ()) -> IO ()
withRoot k = do
  cwd <- getCurrentDirectory
  mroot <- findRepoRoot cwd
  maybe (assertFailure ("could not locate repo root from " ++ cwd)) k mroot

tests :: TestTree
tests =
  testGroup
    "DhallGenSpec"
    [ testGroup "Core.dhall budget helpers" budgetCases,
      testGroup "reflected schemas + registry" registryCases,
      testGroup "config render round-trip + budget assert" renderCases,
      testGroup "SecretRef vocabulary anti-drift + round-trip" secretRefCases
    ]

artifact :: T.Text -> ConfigArtifact
artifact name = case find ((== name) . artifactName) coreArtifacts of
  Just a -> a
  Nothing -> error ("no core artifact named " ++ T.unpack name)

registryCases :: [TestTree]
registryCases =
  [ testCase "a rendered value decodes against its own reflected schema" $ do
      -- annotate the render with the reflected schema; if they agree it decodes.
      let a = artifact "budget"
      v <-
        Dhall.input
          (Dhall.auto :: Dhall.Decoder V.Budget)
          (renderText a <> " : " <> schemaText a)
      v @?= V.Budget 4 8 20,
    testCase "reflectedSchema is the record type the decoder accepts" $ do
      -- structural: the schema parses as a Dhall type and admits a fresh value.
      decoded <-
        Dhall.input
          (Dhall.auto :: Dhall.Decoder V.PodResources)
          ( "{ replicas = 3, cpuRequest = 1, cpuLimit = 2, memoryRequest = 1, memoryLimit = 2 } : "
              <> reflectedSchema @V.PodResources
          )
      decoded @?= V.PodResources 3 1 2 1 2,
    testCase "schemaUnion lists every in-scope artifact" $ do
      let u = schemaUnion coreArtifacts
      mapM_
        (\n -> assertBool ("union names " ++ T.unpack n) (n `T.isInfixOf` u))
        ["budget", "podResources", "kindNode"]
      assertBool "union carries reflected Natural fields" ("Natural" `T.isInfixOf` u),
    testCase "config schema matches the committed CI snapshot" $ withRoot $ \root -> do
      let goldenPath = root </> "core" </> "hostbootstrap-core" </> "test" </> "golden" </> "config_schema.dhall"
      golden <- readFile goldenPath
      let emitted =
            schemaUnion coreArtifacts
              <> "\n\n-- projectConfig\n"
              <> projectConfigSchemaText
      -- A decoder-type change that is not re-snapshotted fails this diff.
      T.stripEnd emitted @?= T.stripEnd (T.pack golden)
  ]

renderCases :: [TestTree]
renderCases =
  [ testCase "render -> decode -> re-render is byte-identical" $ do
      let rendered = renderValue (V.KindNode 4 8 20)
      v <- Dhall.input (Dhall.auto :: Dhall.Decoder V.KindNode) rendered
      v @?= V.KindNode 4 8 20
      renderValue v @?= rendered,
    testCase "an in-budget deploy config type-checks (carries the fitsWithin assert)" $ withRoot $ \root -> do
      -- budget cpu=4 mem=8; pods replicas=2 × (cpuLimit=1, memoryLimit=2) = cpu 2, mem 4 → fits.
      let okText = deployConfigText (corePath root) (V.Budget 4 8 20) [V.PodResources 2 1 1 1 2]
      _ <- Dhall.inputExpr okText
      pure (),
    testCase "an over-budget deploy config fails to type-check (the assert fires)" $ withRoot $ \root -> do
      -- budget cpu=2; pods replicas=3 × cpuLimit=2 = cpu 6 → over → assert False === True fails.
      let badText = deployConfigText (corePath root) (V.Budget 2 4 20) [V.PodResources 3 1 2 1 2]
      result <- try (Dhall.inputExpr badText >> pure ()) :: IO (Either SomeException ())
      assertBool "over-budget deploy is rejected" (either (const True) (const False) result)
  ]

secretRefCases :: [TestTree]
secretRefCases =
  [ testCase "the SecretRef Haskell mirror reflects to Core.dhall's SecretRef" $ withRoot $ \root -> do
      -- Anti-drift: the reflected union type the @ToDhall SecretRef@ encoder
      -- injects to must be judgmentally equal to @Core.dhall@'s @SecretRef@.
      reflected <- Dhall.inputExpr (reflectedSchema @V.SecretRef)
      core <- Dhall.inputExpr ("(" <> corePath root <> ").SecretRef")
      assertBool
        ( "reflected SecretRef\n  "
            <> T.unpack (Dhall.Core.pretty (Dhall.Core.normalize reflected))
            <> "\ndiffers from Core.dhall SecretRef\n  "
            <> T.unpack (Dhall.Core.pretty (Dhall.Core.normalize core))
        )
        (Dhall.Core.judgmentallyEqual reflected core),
    testCase "a Vault SecretRef encodes to Dhall and decodes back unchanged" $ do
      let v = V.Vault (V.VaultRef "secret" "app/db" "password")
      decoded <- Dhall.input (Dhall.auto :: Dhall.Decoder V.SecretRef) (renderValue v)
      decoded @?= v,
    testCase "a TestPlaintext SecretRef encodes to Dhall and decodes back unchanged" $ do
      let v = V.TestPlaintext "hunter2"
      decoded <- Dhall.input (Dhall.auto :: Dhall.Decoder V.SecretRef) (renderValue v)
      decoded @?= v,
    testCase "the TransitKey and Prompt alternatives round-trip too" $ do
      let tk = V.TransitKey "app-signing-key"
          pr = V.Prompt "database password"
      dtk <- Dhall.input (Dhall.auto :: Dhall.Decoder V.SecretRef) (renderValue tk)
      dpr <- Dhall.input (Dhall.auto :: Dhall.Decoder V.SecretRef) (renderValue pr)
      dtk @?= tk
      dpr @?= pr,
    testCase "a SecretRef value decodes against Core.dhall's SecretRef type" $ withRoot $ \root -> do
      -- The rendered value, annotated with the *Core.dhall* type (not the
      -- reflected one), still type-checks and decodes — proving the shared shape.
      let v = V.Vault (V.VaultRef "secret" "app/db" "password")
      decoded <-
        Dhall.input
          (Dhall.auto :: Dhall.Decoder V.SecretRef)
          (renderValue v <> " : (" <> corePath root <> ").SecretRef")
      decoded @?= v
  ]

budgetCases :: [TestTree]
budgetCases =
  [ testCase "Budget/fitsWithin accepts an under-budget pod set" $ withRoot $ \root -> do
      ok <-
        Dhall.input
          Dhall.bool
          ( "let C = "
              <> corePath root
              <> " in C.fitsWithin { cpu = 4, memory = 8, storage = 20 }"
              <> " [ { replicas = 2, cpuRequest = 1, cpuLimit = 1, memoryRequest = 1, memoryLimit = 2 } ]"
          )
      ok @?= True,
    testCase "Budget/fitsWithin rejects an over-budget pod set" $ withRoot $ \root -> do
      ok <-
        Dhall.input
          Dhall.bool
          ( "let C = "
              <> corePath root
              <> " in C.fitsWithin { cpu = 2, memory = 4, storage = 20 }"
              <> " [ { replicas = 3, cpuRequest = 1, cpuLimit = 2, memoryRequest = 1, memoryLimit = 4 } ]"
          )
      ok @?= False,
    testCase "Budget/split divides proportionally by weight (floor)" $ withRoot $ \root -> do
      parts <-
        Dhall.input
          (Dhall.list Dhall.auto)
          ("let C = " <> corePath root <> " in C.split { cpu = 10, memory = 20, storage = 40 } [ 1, 1 ]") ::
          IO [V.Budget]
      parts @?= [V.Budget 5 10 20, V.Budget 5 10 20],
    testCase "Budget/split floors uneven weights and stays within budget" $ withRoot $ \root -> do
      parts <-
        Dhall.input
          (Dhall.list Dhall.auto)
          ("let C = " <> corePath root <> " in C.split { cpu = 7, memory = 7, storage = 7 } [ 1, 2 ]") ::
          IO [V.Budget]
      -- 7*1/3 = 2 (floor), 7*2/3 = 4 (floor); the floors never exceed the budget.
      parts @?= [V.Budget 2 2 2, V.Budget 4 4 4]
  ]
