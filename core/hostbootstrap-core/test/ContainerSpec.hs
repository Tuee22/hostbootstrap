{-# LANGUAGE OverloadedStrings #-}

module ContainerSpec (tests) where

import HostBootstrap.Config.Schema (Resources (..), StaticBase (..))
import HostBootstrap.Container (dockerBuildArgs, projectImageTag)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ContainerSpec"
    [ testCase "projectImageTag is <project>:local" $
        projectImageTag sb @?= "demo:local",
      testCase "dockerBuildArgs builds the dockerfile FROM the base, tagged, from ." $
        dockerBuildArgs sb "base:tag"
          @?= ["build", "-f", "docker/Dockerfile", "--build-arg", "BASE_IMAGE=base:tag", "-t", "demo:local", "."]
    ]
  where
    sb =
      StaticBase
        { project = "demo",
          dockerfile = "docker/Dockerfile",
          resources = Resources 4 "8GiB" "20GiB"
        }
