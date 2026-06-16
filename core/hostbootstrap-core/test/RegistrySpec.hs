{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the Docker Hub credential model ('HostBootstrap.Registry'): the
-- credential carries only the Docker Hub auth (never the host's other registry
-- secrets), it never prints its payload, and the ephemeral-forwarding wrapper
-- never embeds the secret (it travels on @stdin@, not in the script).
module RegistrySpec (tests) where

import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Text as T
import HostBootstrap.Registry
  ( dockerAuthStdinWrapper,
    dockerHubAuthFromConfig,
    registryAuthEnvVar,
    registryConfigPayload,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- A host config.json logged in to Docker Hub AND a private registry. The Docker
-- Hub secrets are the only ones that should ever be forwarded.
multiRegistryConfig :: BL.ByteString
multiRegistryConfig =
  BL.concat
    [ "{\"auths\":{",
      "\"https://index.docker.io/v1/\":{\"auth\":\"ZG9ja2VyOnB1bGw=\",\"identitytoken\":\"HUB-IDENTITY-TOKEN\"},",
      "\"localhost:30002\":{\"auth\":\"cHJpdmF0ZTpzZWNyZXQ=\"}",
      "}}"
    ]

has :: T.Text -> T.Text -> Bool
has = T.isInfixOf

hasStr :: T.Text -> String -> Bool
hasStr needle haystack = T.isInfixOf needle (T.pack haystack)

present :: BL.ByteString -> Bool
present = maybe False (const True) . dockerHubAuthFromConfig

tests :: TestTree
tests =
  testGroup
    "RegistrySpec"
    [ testGroup
        "dockerHubAuthFromConfig projects out only the Docker Hub auth"
        [ testCase "keeps the index.docker.io entry and its token" $ do
            let payload = fmap registryConfigPayload (dockerHubAuthFromConfig multiRegistryConfig)
            assertBool "payload present" (payload /= Nothing)
            assertBool "carries the Docker Hub registry key" (maybe False (has "index.docker.io") payload)
            assertBool "carries the Docker Hub auth value" (maybe False (has "ZG9ja2VyOnB1bGw=") payload)
            assertBool "carries the Docker Hub identity token" (maybe False (has "HUB-IDENTITY-TOKEN") payload),
          testCase "drops the host's other registry credentials" $ do
            let payload = fmap registryConfigPayload (dockerHubAuthFromConfig multiRegistryConfig)
            assertBool "drops the private registry host" (maybe False (not . has "localhost:30002") payload)
            assertBool "drops the private registry secret" (maybe False (not . has "cHJpdmF0ZTpzZWNyZXQ=") payload)
        ],
      testGroup
        "no Docker Hub credential yields Nothing (anonymous fallback)"
        [ testCase "empty object" $ present "{}" @?= False,
          testCase "auths without a Docker Hub entry" $
            present "{\"auths\":{\"localhost:30002\":{\"auth\":\"eA==\"}}}" @?= False,
          testCase "invalid JSON" $ present "not-json" @?= False
        ],
      testCase "the credential never leaks through Show" $
        case dockerHubAuthFromConfig multiRegistryConfig of
          Nothing -> assertBool "expected a credential" False
          Just auth -> do
            show auth @?= "RegistryAuth <redacted>"
            assertBool "shown form omits the identity token" (not (hasStr "HUB-IDENTITY-TOKEN" (show auth))),
      testGroup
        "the stdin wrapper forwards ephemerally and embeds no secret"
        [ testCase "materialises and scrubs a transient DOCKER_CONFIG" $ do
            let script = dockerAuthStdinWrapper "docker build ."
            assertBool "creates a temp dir" (hasStr "mktemp -d" script)
            assertBool "reads the payload from stdin" (hasStr "cat >" script)
            assertBool "points DOCKER_CONFIG at it" (hasStr "DOCKER_CONFIG=" script)
            assertBool "removes it on exit" (hasStr "trap" script && hasStr "rm -rf" script)
            assertBool "runs the inner command" (hasStr "docker build ." script),
          testCase "the wrapper script is pure (no secret embedded)" $ do
            let script = dockerAuthStdinWrapper "docker build ."
            assertBool
              "wrapper carries no auth material"
              (not (hasStr "HUB-IDENTITY-TOKEN" script) && not (hasStr "ZG9ja2VyOnB1bGw=" script))
        ],
      testCase "the forwarding env var name is stable" $
        registryAuthEnvVar @?= "HOSTBOOTSTRAP_REGISTRY_AUTH"
    ]
