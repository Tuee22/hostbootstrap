{-# LANGUAGE OverloadedStrings #-}

module IncusSpec (tests) where

import Data.Either (isLeft)
import Data.List (isInfixOf, isPrefixOf)
import HostBootstrap.Cluster.Cordon (incusSizingArgs)
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Incus
import qualified SourceGuard
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

vm :: IncusVM
vm = IncusVM {vmName = "hostbootstrap-demo-vm", vmImage = "images:ubuntu/24.04"}

tests :: TestTree
tests =
  testGroup
    "IncusSpec"
    [ testGroup "VM argv builders" argvCases,
      testGroup "name-prefix delete-guard" guardCases,
      testGroup "incusSizingArgs" sizingCases,
      testGroup "provider realization boundary" providerBoundaryCases
    ]

argvCases :: [TestTree]
argvCases =
  [ testCase "launch builds an image+name --vm argv with sizing appended" $
      createVMArgs vm ["limits.cpu=6"]
        @?= ["launch", "images:ubuntu/24.04", "hostbootstrap-demo-vm", "--vm", "limits.cpu=6"],
    testCase "launch preserves the complete sized Incus wall" $
      createVMArgs
        vm
        ["-c", "limits.cpu=6", "-c", "limits.memory=10GiB", "-d", "root,size=40GiB"]
        @?= [ "launch",
              "images:ubuntu/24.04",
              "hostbootstrap-demo-vm",
              "--vm",
              "-c",
              "limits.cpu=6",
              "-c",
              "limits.memory=10GiB",
              "-d",
              "root,size=40GiB"
            ],
    testCase "start makes existing-instance bring-up an explicit lifecycle operation" $
      startVMArgs vm @?= ["start", "hostbootstrap-demo-vm"],
    testCase "exec dispatches a bare in-VM command through one incus exec" $
      execVMArgs vm ["docker", "info"]
        @?= ["exec", "hostbootstrap-demo-vm", "--", "docker", "info"],
    testCase "file push targets <name><dst>" $
      pushFileArgs vm "./wrapper.pyz" "/root/wrapper.pyz"
        @?= ["file", "push", "./wrapper.pyz", "hostbootstrap-demo-vm/root/wrapper.pyz"],
    testCase "device list targets the named instance" $
      deviceListArgs vm
        @?= ["config", "device", "list", "hostbootstrap-demo-vm"],
    testCase "disk device shares a host directory at the requested guest path" $
      addDiskDeviceArgs vm "durable-data" "/srv/demo/.data" "/srv/demo/.data"
        @?= [ "config",
              "device",
              "add",
              "hostbootstrap-demo-vm",
              "durable-data",
              "disk",
              "source=/srv/demo/.data",
              "path=/srv/demo/.data"
            ],
    testCase "stop halts the VM without deleting it (project down)" $
      stopVMArgs vm @?= ["stop", "hostbootstrap-demo-vm"]
  ]

guardCases :: [TestTree]
guardCases =
  [ testCase "a prefixed VM name is destroyable" $
      destroyVMArgs "hostbootstrap-demo-" vm
        @?= Right ["delete", "hostbootstrap-demo-vm", "--force"],
    testCase "a non-prefixed VM name is refused" $
      assertBool "refuses to delete" (isLeft (destroyVMArgs "other-prefix-" vm))
  ]

sizingCases :: [TestTree]
sizingCases =
  [ testCase "incus sizing cordons cpu/memory/storage at the VM wall" $
      incusSizingArgs (ResourceEnvelope {cpu = 6, memory = "10GiB", storage = "40GiB"})
        @?= Right ["limits.cpu=6", "limits.memory=10GiB", "root,size=40GiB"]
  ]

providerBoundaryCases :: [TestTree]
providerBoundaryCases =
  [ testCase "Incus consumes and reexports exactly the lower target/renderer pair" $ do
      source <- providerSource "Incus.hs"
      -- Two lower modules, and only two: the frame's own target and renderer,
      -- and the shared frame table this row's destructive delete goes through
      -- (§ LL). Both are below the realization, which is what this guard is for.
      hostBootstrapImports source
        @?= ["HostBootstrap.Lift.Context", "HostBootstrap.Substrate.Frame"]
      fmap withoutCommas (SourceGuard.moduleImportTokens "HostBootstrap.Lift.Context" source)
        @?= Just ["IncusVM", "(", "..", ")", "execVMArgs"]
      fmap withoutCommas (SourceGuard.moduleImportTokens "HostBootstrap.Substrate.Frame" source)
        @?= Just ["FrameNoun", "(", "IncusInstance", ")", "guardedDeleteArgs"]
      exports <-
        maybe
          (fail "HostBootstrap.Incus must have an explicit export list")
          pure
          (SourceGuard.moduleExportTokens "HostBootstrap.Incus" source)
      assertBool "IncusVM (..) is not reexported" (["IncusVM", "(", "..", ")"] `isInfixOf` exports)
      assertBool "execVMArgs is not reexported" ("execVMArgs" `elem` exports)
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
