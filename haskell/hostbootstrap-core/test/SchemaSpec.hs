{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SchemaSpec (tests) where

import Control.Exception (SomeException, try)
import qualified Data.Text as T
import qualified Dhall
import qualified Dhall.Core as Core
import HostBootstrap.Config.Schema
  ( Resources (..),
    StaticBase (..),
    decodeStaticBaseFile,
    decodeStaticBaseText,
  )
import HostBootstrap.DocValidator (findRepoRoot)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

validConfig :: String
validConfig =
  unlines
    [ "{ project = \"demo\"",
      ", dockerfile = \"docker/demo.Dockerfile\"",
      ", resources = { cpu = 4, memory = \"8GiB\", storage = \"20GiB\" }",
      "}"
    ]

expected :: StaticBase
expected =
  StaticBase
    { project = "demo",
      dockerfile = "docker/demo.Dockerfile",
      resources = Resources {cpu = 4, memory = "8GiB", storage = "20GiB"}
    }

tests :: TestTree
tests =
  testGroup
    "SchemaSpec"
    [ testCase "decodes a valid static-base config" $ do
        decoded <- decodeStaticBaseText (toText validConfig)
        decoded @?= expected,
      testCase "a malformed config fails with a typed error" $ do
        result <- try (decodeStaticBaseText "{ project = \"x\" }") :: IO (Either SomeException StaticBase)
        case result of
          Left _ -> pure ()
          Right s -> assertFailure ("expected a decode error, got " ++ show s),
      testCase "a wrong-typed field fails with a typed error" $ do
        result <-
          try (decodeStaticBaseText (toText badTypeConfig)) ::
            IO (Either SomeException StaticBase)
        assertBool "expected a decode error for cpu : Text" (isLeft result),
      testCase "decodes the canonical example.dhall fixture" decodeFixture,
      testCase "Type.dhall and the Python package.dhall Config share one shape (anti-drift)" antiDrift
    ]
  where
    badTypeConfig =
      unlines
        [ "{ project = \"demo\"",
          ", dockerfile = \"d\"",
          ", resources = { cpu = \"four\", memory = \"8GiB\", storage = \"20GiB\" }",
          "}"
        ]

decodeFixture :: IO ()
decodeFixture = do
  cwd <- getCurrentDirectory
  mroot <- findRepoRoot cwd
  case mroot of
    Nothing -> assertFailure ("could not locate repo root from " ++ cwd)
    Just root -> do
      let path = root </> "haskell" </> "hostbootstrap-core" </> "dhall" </> "example.dhall"
      exists <- doesFileExist path
      assertBool ("fixture exists: " ++ path) exists
      decoded <- decodeStaticBaseFile path
      decoded @?= expected

-- | The anti-drift guarantee (see @development_plan_standards.md § Q@): the
-- Haskell-side static-base record type (@dhall/Type.dhall@) and the Python-side
-- @dhall/package.dhall@ @Config@ field must denote the same Dhall type, so the
-- pre-binary Python read and the in-process Haskell decoder cannot diverge. Both
-- are imported, type-checked, and normalised by the @dhall@ library, then
-- compared judgmentally (record types are field-order-insensitive).
antiDrift :: IO ()
antiDrift = do
  cwd <- getCurrentDirectory
  mroot <- findRepoRoot cwd
  case mroot of
    Nothing -> assertFailure ("could not locate repo root from " ++ cwd)
    Just root -> do
      let typeDhall = root </> "haskell" </> "hostbootstrap-core" </> "dhall" </> "Type.dhall"
          packageDhall = root </> "python" </> "hostbootstrap" </> "dhall" </> "package.dhall"
      haskExpr <- Dhall.inputExpr (T.pack typeDhall)
      pyExpr <- Dhall.inputExpr (T.pack ("(" <> packageDhall <> ").Config"))
      assertBool
        ( "Type.dhall and package.dhall.Config differ:\n  Type.dhall = "
            <> show haskExpr
            <> "\n  package.dhall.Config = "
            <> show pyExpr
        )
        (Core.judgmentallyEqual haskExpr pyExpr)

toText :: String -> T.Text
toText = T.pack

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
