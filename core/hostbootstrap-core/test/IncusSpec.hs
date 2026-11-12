{-# LANGUAGE OverloadedStrings #-}

module IncusSpec (tests) where

import Data.List (isPrefixOf)
import HostBootstrap.Cluster.Cordon (incusSizingArgs)
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Incus
import qualified SourceGuard
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

vm :: IncusVM
vm = IncusVM{vmName = "hostbootstrap-demo-vm", vmImage = "images:ubuntu/24.04"}

tests :: TestTree
tests =
    testGroup
        "IncusSpec"
        [ testGroup "VM argv builders" argvCases
        , testGroup "incusSizingArgs" sizingCases
        , testGroup "provider realization boundary" providerBoundaryCases
        ]

argvCases :: [TestTree]
argvCases =
    [ testCase "exec dispatches a bare in-VM command through one incus exec" $
        execVMArgs vm ["docker", "info"]
            @?= ["exec", "hostbootstrap-demo-vm", "--", "docker", "info"]
    , testCase "file push targets <name><dst>" $
        pushFileArgs vm "./wrapper.pyz" "/root/wrapper.pyz"
            @?= ["file", "push", "./wrapper.pyz", "hostbootstrap-demo-vm/root/wrapper.pyz"]
    ]

sizingCases :: [TestTree]
sizingCases =
    [ testCase "incus sizing cordons cpu/memory/storage at the VM wall" $
        incusSizingArgs (ResourceEnvelope{cpu = 6, memory = "10GiB", storage = "40GiB"})
            @?= Right ["limits.cpu=6", "limits.memory=10GiB", "root,size=40GiB"]
    ]

providerBoundaryCases :: [TestTree]
providerBoundaryCases =
    [ testCase "Incus consumes and reexports exactly the lower target/renderer pair" $ do
        source <- providerSource "Incus.hs"
        hostBootstrapImports source @?= ["HostBootstrap.Lift.Context"]
        fmap withoutCommas (SourceGuard.moduleImportTokens "HostBootstrap.Lift.Context" source)
            @?= Just ["IncusVM", "(", "..", ")", "execVMArgs"]
        fmap withoutCommas (SourceGuard.moduleExportTokens "HostBootstrap.Incus" source)
            @?= Just ["IncusVM", "(", "..", ")", "execVMArgs", "pushFileArgs"]
        SourceGuard.countHaskellTokenSequence ["data", "IncusVM"] source @?= 0
        SourceGuard.countHaskellTokenSequence ["newtype", "IncusVM"] source @?= 0
        SourceGuard.countHaskellTokenSequence ["execVMArgs", "::"] source @?= 0
        assertNoParallelLift source
    ]

providerSource :: FilePath -> IO String
providerSource sourceFile = do
    cwd <- getCurrentDirectory
    root <- findRepoRoot cwd >>= maybe (fail ("could not locate repository root from " ++ cwd)) pure
    readFile (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> sourceFile)

hostBootstrapImports :: String -> [String]
hostBootstrapImports = filter ("HostBootstrap." `isPrefixOf`) . SourceGuard.haskellImports

withoutCommas :: [String] -> [String]
withoutCommas = filter (/= ",")

assertNoParallelLift :: String -> IO ()
assertNoParallelLift source =
    mapM_
        ( \identifier ->
            SourceGuard.countHaskellIdentifier identifier source
                @?= 0
        )
        ["foldLift", "foldLeaf", "LiftContext", "DispatchLocal", "DispatchTool", "SubstrateProvider"]
