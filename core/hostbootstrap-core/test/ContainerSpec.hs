{-# LANGUAGE OverloadedStrings #-}

module ContainerSpec (tests) where

import HostBootstrap.Config.Schema (defaultProjectConfig)
import HostBootstrap.Container (dockerBuildArgs, projectImageTag)
import qualified HostBootstrap.Context as Context
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
    sb = defaultProjectConfig "demo" "." Context.HostOrchestrator
