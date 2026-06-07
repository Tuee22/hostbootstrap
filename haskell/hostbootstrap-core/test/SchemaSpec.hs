{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SchemaSpec (tests) where

import Control.Exception (SomeException, try)
import qualified Data.Text as T
import HostBootstrap.Config.Schema
  ( Resources (..),
    Skeleton (..),
    decodeSkeletonFile,
    decodeSkeletonText,
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

expected :: Skeleton
expected =
  Skeleton
    { project = "demo",
      dockerfile = "docker/demo.Dockerfile",
      resources = Resources {cpu = 4, memory = "8GiB", storage = "20GiB"}
    }

tests :: TestTree
tests =
  testGroup
    "SchemaSpec"
    [ testCase "decodes a valid skeletal config" $ do
        decoded <- decodeSkeletonText (toText validConfig)
        decoded @?= expected,
      testCase "a malformed config fails with a typed error" $ do
        result <- try (decodeSkeletonText "{ project = \"x\" }") :: IO (Either SomeException Skeleton)
        case result of
          Left _ -> pure ()
          Right s -> assertFailure ("expected a decode error, got " ++ show s),
      testCase "a wrong-typed field fails with a typed error" $ do
        result <-
          try (decodeSkeletonText (toText badTypeConfig)) ::
            IO (Either SomeException Skeleton)
        assertBool "expected a decode error for cpu : Text" (isLeft result),
      testCase "decodes the canonical example.dhall fixture" decodeFixture
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
      decoded <- decodeSkeletonFile path
      decoded @?= expected

toText :: String -> T.Text
toText = T.pack

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
