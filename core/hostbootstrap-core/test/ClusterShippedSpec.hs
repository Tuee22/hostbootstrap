{-# LANGUAGE OverloadedStrings #-}

{- | The closed read-only transaction that re-observes a cluster exposure in
the provider frame.

The codec cases are total applications. The backend's successful exact-runtime
observation is covered against a real protected store and real fixture process
in "ClusterBackendSpec". Here one absent-record refusal enters the far
interpreter directly and another crosses a real child process before that
interpreter runs.
-}
module ClusterShippedSpec (tests) where

import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import HostBootstrap.Cluster.Shipped
import HostBootstrap.Handoff.Transaction (withFrameChildTransaction)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.Lift (localContext, mkSelfRef)
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import System.Directory (canonicalizePath)
import System.Environment (getExecutablePath)
import System.Info (os)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "ClusterShippedSpec"
        [ testGroup "the request and response wire" codecCases
        , testGroup "the far-frame observation" observationCases
        ]

codecCases :: [TestTree]
codecCases =
    [ testCase "one canonical request round-trips exactly" $ do
        let request = encodeShippedClusterExposureRequest "/var/tmp/demo/cluster/kind/state" "demo-test-run-1" "accelerator"
        (request >>= decodeShippedClusterExposureRequest)
            @?= Right ("/var/tmp/demo/cluster/kind/state", "demo-test-run-1", "accelerator")
    , testCase "invalid and unbounded request fields are refused" $ do
        let invalid =
                [ encodeShippedClusterExposureRequest "relative/state" "demo" "web"
                , encodeShippedClusterExposureRequest "/" "demo" "web"
                , encodeShippedClusterExposureRequest "/var/tmp/state/" "demo" "web"
                , encodeShippedClusterExposureRequest "/var/tmp/../state" "demo" "web"
                , encodeShippedClusterExposureRequest "/var/tmp/state" "bad cluster" "web"
                , encodeShippedClusterExposureRequest "/var/tmp/state" "demo" "bad/service"
                , encodeShippedClusterExposureRequest ("/" <> replicate 2050 'a') "demo" "web"
                ]
        assertBool "an invalid request was admitted" (all (either (const True) (const False)) invalid)
    , testCase "trailing bytes are refused rather than ignored" $ do
        request <- either (assertFailure . Text.unpack) pure (encodeShippedClusterExposureRequest "/var/tmp/state" "demo" "web")
        assertBool
            "a request with a trailing field was admitted"
            (either (const True) (const False) (decodeShippedClusterExposureRequest (request <> "\0extra")))
    , testCase "a foreign transaction prefix falls through" $ do
        interpretShippedClusterExposure "hostbootstrap/ownership/request/v1" >>= (@?= Nothing)
    , testCase "a recognized malformed request is a far-frame refusal" $ do
        request <- either (assertFailure . Text.unpack) pure (encodeShippedClusterExposureRequest "/var/tmp/state" "demo" "web")
        interpreted <- interpretShippedClusterExposure (request <> "\0extra")
        case interpreted of
            Just (Left _) -> pure ()
            other -> assertFailure ("expected a recognized refusal, got " <> show other)
    , testCase "only a canonical bounded port is a response" $ do
        assertBool
            "foreign bytes decoded as a response"
            (either (const True) (const False) (decodeShippedClusterExposureResponse "41000"))
    ]

observationCases :: [TestTree]
observationCases =
    [ testCase "the far interpreter names an absent durable exposure as a refusal" $
        withAbsentRequest $ \request -> do
            interpreted <- interpretShippedClusterExposure request
            case interpreted of
                Just (Left refusal) -> assertBool "the refusal lost the absent exposure fact" ("absent" `Text.isInfixOf` refusal)
                other -> assertFailure ("expected an absent-record refusal, got " <> show other)
    , testCase "an observation refusal crosses a real frame-child process" $
        withAbsentRequest $ \request -> do
            self <- getExecutablePath
            crossed <-
                withFrameChildTransaction
                    unresolvedHostConfig
                    (mkSelfRef self self)
                    localContext
                    request
            case crossed of
                Left refusal -> assertBool "the crossing lost the far-frame refusal" ("absent" `Text.isInfixOf` refusal || "not absolute" `Text.isInfixOf` refusal)
                Right _ -> assertFailure "an absent recorded exposure crossed as a successful response"
    ]

withAbsentRequest :: (ByteString.ByteString -> IO result) -> IO result
withAbsentRequest consume =
    withSystemTempDirectory "hostbootstrap-cluster-exposure-absent" $ \temporary -> do
        canonical <- canonicalizePath temporary
        let stateDirectory
                | os == "mingw32" = "/var/tmp/hostbootstrap-cluster-exposure-absent"
                | otherwise = canonical
        request <-
            either
                (assertFailure . Text.unpack)
                pure
                (encodeShippedClusterExposureRequest stateDirectory "demo" "web")
        consume request

unresolvedHostConfig :: HostConfig
unresolvedHostConfig =
    HostConfig
        { hcSubstrate = Substrate LinuxCpu Amd64
        , hcToolPaths = Map.empty
        }
