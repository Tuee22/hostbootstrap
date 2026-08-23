{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleDependencySpec (tests) where

import Data.Either (isLeft)
import qualified Data.ByteString.Char8 as ByteString
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Lifecycle.Dependency.Internal
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

data Scope
data Plan

tests :: TestTree
tests =
    testGroup
        "runtime dependency package"
        [ testCase "provider and cluster domains render separately and open exactly" $ do
            provider <- expectRight providerPackage
            cluster <- expectRight clusterPackage
            assertBool "domains rendered identically" (renderRuntimeDependencyPackage provider /= renderRuntimeDependencyPackage cluster)
            withProviderRuntimeDependencyPackage "plan" "scope" "resource" "frame" "origin" 7 "journal" "receipt" providerRoute 99 provider id
                @?= Right providerRoute
            withClusterRuntimeDependencyPackage "plan" "scope" "resource" "frame" "origin" 7 "journal" "receipt" clusterRoute 99 cluster id
                @?= Right clusterRoute
            assertBool
                "a cluster package opened through the provider domain"
                (isLeft (withProviderRuntimeDependencyPackage "plan" "scope" "resource" "frame" "origin" 7 "journal" "receipt" clusterRoute 99 cluster id))
            request <- expectRight (runtimeDependencyProbeRequest provider "nonce-1")
            withRuntimeDependencyProbeRequest provider request id @?= Right "nonce-1"
            let response = renderRuntimeDependencyProbeResponse provider "nonce-1" 7
            verifyRuntimeDependencyProbeResponse provider "nonce-1" response @?= Right 7
            assertBool "another nonce accepted the response" (isLeft (verifyRuntimeDependencyProbeResponse provider "nonce-2" response))
            assertBool "another commitment accepted the response" (isLeft (verifyRuntimeDependencyProbeResponse cluster "nonce-1" response))
            assertBool "a malformed request was accepted" (isLeft (withRuntimeDependencyProbeRequest provider (ByteString.pack "3:bad") id))
        , testCase "provider package and probe outcomes have canonical golden bytes" $ do
            package <- expectRight providerPackage
            let packageGolden = ByteString.pack "35:hostbootstrap/runtime-dependency/v18:provider4:plan5:scope8:resource5:frame6:origin1:77:journal7:receipt26:runtime://provider/reprobe3:100"
                requestGolden = ByteString.pack "41:hostbootstrap/runtime-dependency-probe/v1141:35:hostbootstrap/runtime-dependency/v18:provider4:plan5:scope8:resource5:frame6:origin1:77:journal7:receipt26:runtime://provider/reprobe3:1007:nonce-1"
                responseGolden = ByteString.pack "50:hostbootstrap/runtime-dependency-probe-response/v1141:35:hostbootstrap/runtime-dependency/v18:provider4:plan5:scope8:resource5:frame6:origin1:77:journal7:receipt26:runtime://provider/reprobe3:1007:nonce-11:7"
                refusalGolden = ByteString.pack "49:hostbootstrap/runtime-dependency-probe-refused/v1141:35:hostbootstrap/runtime-dependency/v18:provider4:plan5:scope8:resource5:frame6:origin1:77:journal7:receipt26:runtime://provider/reprobe3:1007:nonce-111:unavailable"
            runtimeDependencyPackageWire package @?= packageGolden
            decoded <- expectRight (runtimeDependencyPackageFromWire packageGolden)
            renderRuntimeDependencyPackage decoded @?= renderRuntimeDependencyPackage package
            request <- expectRight (runtimeDependencyProbeRequest package "nonce-1")
            request @?= requestGolden
            renderRuntimeDependencyProbeResponse package "nonce-1" 7 @?= responseGolden
            refusal <- expectRight (renderRuntimeDependencyProbeRefusal package "nonce-1" "unavailable")
            refusal @?= refusalGolden
            verifyRuntimeDependencyProbeOutcome package "nonce-1" responseGolden @?= Right (Right 7)
            verifyRuntimeDependencyProbeOutcome package "nonce-1" refusalGolden @?= Right (Left "unavailable")
        , testCase "package and probe decoders refuse noncanonical, substituted, and oversized bytes" $ do
            package <- expectRight providerPackage
            cluster <- expectRight clusterPackage
            let wire = runtimeDependencyPackageWire package
            mapM_
                (assertBool "a malformed package was accepted" . isLeft . runtimeDependencyPackageFromWire)
                [ wire <> "0:"
                , ByteString.pack "035:" <> ByteString.drop 3 wire
                , ByteString.replicate (64 * 1024 + 1) 'x'
                ]
            request <- expectRight (runtimeDependencyProbeRequest package "nonce-1")
            assertBool "a changed package accepted the request" (isLeft (withRuntimeDependencyProbeRequest cluster request id))
            refusal <- expectRight (renderRuntimeDependencyProbeRefusal package "nonce-1" "unavailable")
            assertBool "a replayed nonce accepted the refusal" (isLeft (verifyRuntimeDependencyProbeOutcome package "nonce-2" refusal))
            assertBool "an empty refusal was encoded" (isLeft (renderRuntimeDependencyProbeRefusal package "nonce-1" ""))
            assertBool "an oversized nonce was encoded" (isLeft (runtimeDependencyProbeRequest package (Text.replicate 129 "n")))
        , testCase "every commitment and the exclusive expiry are checked before opening" $ do
            package <- expectRight providerPackage
            let opens plan scope resource frame origin generation journal receipt route now =
                    withProviderRuntimeDependencyPackage plan scope resource frame origin generation journal receipt route now package id
            mapM_
                (assertBool "a mismatched dependency coordinate opened" . isLeft)
                [ opens "wrong" "scope" "resource" "frame" "origin" 7 "journal" "receipt" providerRoute 99
                , opens "plan" "wrong" "resource" "frame" "origin" 7 "journal" "receipt" providerRoute 99
                , opens "plan" "scope" "wrong" "frame" "origin" 7 "journal" "receipt" providerRoute 99
                , opens "plan" "scope" "resource" "wrong" "origin" 7 "journal" "receipt" providerRoute 99
                , opens "plan" "scope" "resource" "frame" "wrong" 7 "journal" "receipt" providerRoute 99
                , opens "plan" "scope" "resource" "frame" "origin" 8 "journal" "receipt" providerRoute 99
                , opens "plan" "scope" "resource" "frame" "origin" 7 "wrong" "receipt" providerRoute 99
                , opens "plan" "scope" "resource" "frame" "origin" 7 "journal" "wrong" providerRoute 99
                , opens "plan" "scope" "resource" "frame" "origin" 7 "journal" "receipt" "runtime://provider/wrong" 99
                , opens "plan" "scope" "resource" "frame" "origin" 7 "journal" "receipt" providerRoute 100
                ]
        , testCase "cluster successor coordinates check domain, identity, generation, route, and expiry" $ do
            package <- expectRight clusterPackage
            let opens plan scope resource frame origin generation route now =
                    withClusterRuntimeDependencyCoordinates plan scope resource frame origin generation route now package id
            opens "plan" "scope" "resource" "frame" "origin" 7 clusterRoute 99 @?= Right clusterRoute
            mapM_
                (assertBool "a mismatched cluster coordinate opened" . isLeft)
                [ opens "wrong" "scope" "resource" "frame" "origin" 7 clusterRoute 99
                , opens "plan" "wrong" "resource" "frame" "origin" 7 clusterRoute 99
                , opens "plan" "scope" "wrong" "frame" "origin" 7 clusterRoute 99
                , opens "plan" "scope" "resource" "wrong" "origin" 7 clusterRoute 99
                , opens "plan" "scope" "resource" "frame" "wrong" 7 clusterRoute 99
                , opens "plan" "scope" "resource" "frame" "origin" 8 clusterRoute 99
                , opens "plan" "scope" "resource" "frame" "origin" 7 "runtime://cluster/wrong" 99
                , opens "plan" "scope" "resource" "frame" "origin" 7 clusterRoute 100
                ]
        , testCase "construction refuses malformed domains, generations, expiry, and routes" $ do
            assertBool "zero generation was accepted" (isLeft (mkProvider 0 providerRoute 100))
            assertBool "zero expiry was accepted" (isLeft (mkProvider 7 providerRoute 0))
            assertBool "wrong-domain route was accepted" (isLeft (mkProvider 7 clusterRoute 100))
            assertBool
                "oversized route was accepted"
                (isLeft (mkProvider 7 ("runtime://provider/" <> Text.replicate 600 "x") 100))
        , testCase "the leaf is acyclic and execution owns distinct canonical and live registry fields" $ do
            cwd <- getCurrentDirectory
            root <- findRepoRoot cwd >>= maybe (assertFailure "repository root not found") pure
            let sourceRoot = root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "Lifecycle"
            dependencySource <- readFile (sourceRoot </> "Dependency" </> "Internal.hs")
            executionSource <- readFile (sourceRoot </> "Execution" </> "Internal.hs")
            handoffSource <- readFile (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "Handoff.hs")
            let packageDeclaration =
                    unlines
                        ( takeWhile (not . isPrefixOf "type role RuntimeDependencyPackage")
                            (dropWhile (not . isPrefixOf "data RuntimeDependencyPackage") (lines dependencySource))
                        )
                providerWireSection =
                    unlines
                        ( takeWhile (not . isPrefixOf "withAuthenticatedProviderDependencyProbeRequest ::")
                            (dropWhile (not . isPrefixOf "providerDependencyPackageFields ::") (lines handoffSource))
                        )
            mapM_
                (\forbidden -> assertBool ("canonical package retains forbidden witness " ++ forbidden) (not (forbidden `isInfixOf` packageDeclaration)))
                [ "ManagedProviderHandle"
                , "ManagedProviderShareHandle"
                , "RunningProviderDependency"
                , "ClusterReadiness"
                , "PreparedGate"
                ]
            mapM_
                (\forbidden -> assertBool ("dependency leaf imports " ++ forbidden) (not (("import " ++ forbidden) `isInfixOf` dependencySource)))
                [ "HostBootstrap.Reconcile"
                , "HostBootstrap.ProjectPlan"
                , "HostBootstrap.Substrate.Provider"
                , "HostBootstrap.Cluster.Reconcile"
                , "HostBootstrap.Lifecycle.Execution.Internal"
                ]
            assertBool "runtime dependency indices are not nominal" ("type role RuntimeDependencyPackage nominal nominal" `isInfixOf` dependencySource)
            assertBool "canonical and live registries are not distinct tuple fields" ("packages, services" `Text.isInfixOf` Text.pack executionSource)
            assertBool "a live service does not check exact canonical membership before running" ("if package `notElem` canonical then pure (Left" `Text.isInfixOf` Text.unwords (Text.words (Text.pack executionSource)))
            assertBool "StepRuntime does not retain a second registry copy" ("(ResourceCarrier scope planId)" `Text.isInfixOf` Text.pack executionSource)
            mapM_
                (\forbidden -> assertBool ("provider wire serializes forbidden authority " ++ forbidden) (not (forbidden `isInfixOf` providerWireSection)))
                [ "ManagedProviderHandle"
                , "ManagedProviderShareHandle"
                , "RunningProviderDependency"
                , "ClusterReadiness"
                , "OwnershipReceipt"
                , "PreparedGate"
                , "IO ("
                , "service"
                , "closure"
                , "command"
                , "secret"
                ]
        ]

providerRoute, clusterRoute :: Text.Text
providerRoute = "runtime://provider/reprobe"
clusterRoute = "runtime://cluster/reprobe"

providerPackage :: Either Text.Text (RuntimeDependencyPackage Scope Plan)
providerPackage = mkProvider 7 providerRoute 100

clusterPackage :: Either Text.Text (RuntimeDependencyPackage Scope Plan)
clusterPackage =
    mkClusterRuntimeDependencyPackage "plan" "scope" "resource" "frame" "origin" 7 "journal" "receipt" clusterRoute 100

mkProvider :: Word64 -> Text.Text -> Word64 -> Either Text.Text (RuntimeDependencyPackage Scope Plan)
mkProvider generation route expiry =
    mkProviderRuntimeDependencyPackage "plan" "scope" "resource" "frame" "origin" generation "journal" "receipt" route expiry

expectRight :: (Show failure) => Either failure value -> IO value
expectRight = either (assertFailure . show) pure
