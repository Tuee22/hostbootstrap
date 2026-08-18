module LimaSpec (tests) where

import Data.Either (isLeft)
import Data.List (isInfixOf, isPrefixOf)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Lima
import qualified SourceGuard
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

vm :: LimaVM
vm = LimaVM "hostbootstrap-demo-vm"

tests :: TestTree
tests =
    testGroup
        "LimaSpec"
        [ testGroup "VM argv builders" argvCases
        , testGroup "name-prefix delete-guard" guardCases
        , testGroup "provider realization boundary" providerBoundaryCases
        ]

argvCases :: [TestTree]
argvCases =
    [ testCase "start uses the named Ubuntu 24.04 template" $
        startVMArgs vm ["--cpus", "4", "--memory", "8", "--disk", "20"]
            @?= ["start", "-y", "--timeout", "15m", "--name=hostbootstrap-demo-vm", "--containerd", "none", "--cpus", "4", "--memory", "8", "--disk", "20", "template:ubuntu-24.04"]
    , testCase "writable host share replaces the default home mount at create" $ do
        writableMountArgs "/Users/me/demo/.data"
            @?= ["--mount-only", "/Users/me/demo/.data:w"]
        startVMArgs
            vm
            (["--cpus", "4", "--memory", "8", "--disk", "20"] ++ writableMountArgs "/Users/me/demo/.data")
            @?= [ "start"
                , "-y"
                , "--timeout"
                , "15m"
                , "--name=hostbootstrap-demo-vm"
                , "--containerd"
                , "none"
                , "--cpus"
                , "4"
                , "--memory"
                , "8"
                , "--disk"
                , "20"
                , "--mount-only"
                , "/Users/me/demo/.data:w"
                , "template:ubuntu-24.04"
                ]
    , testCase "stop halts the named instance without deleting it (project down)" $
        stopVMArgs vm @?= ["stop", "hostbootstrap-demo-vm"]
    , testCase "shell dispatches a root in-VM command through limactl shell" $
        shellVMArgs vm ["docker", "info"]
            @?= ["shell", "hostbootstrap-demo-vm", "--", "sudo", "-H", "docker", "info"]
    , testCase "copy targets the named instance" $
        copyToVMArgs vm "/tmp/src.tgz" "/tmp/src.tgz"
            @?= ["copy", "/tmp/src.tgz", "hostbootstrap-demo-vm:/tmp/src.tgz"]
    , testCase "status targets the named instance" $
        statusVMArgs vm @?= ["list", "--format", "json", "hostbootstrap-demo-vm"]
    ]

guardCases :: [TestTree]
guardCases =
    [ testCase "a prefixed VM name is destroyable" $
        deleteVMArgs "hostbootstrap-demo-" vm
            @?= Right ["delete", "hostbootstrap-demo-vm", "--force"]
    , testCase "a non-prefixed instance is refused" $
        assertBool "refuses to delete" (isLeft (deleteVMArgs "other-prefix-" vm))
    ]

providerBoundaryCases :: [TestTree]
providerBoundaryCases =
    [ testCase "Lima consumes and reexports exactly the lower target/renderer pair" $ do
        source <- providerSource "Lima.hs"
        -- Two lower modules, and only two: the frame's own target and renderer,
        -- and the shared frame table this row's destructive delete goes through
        -- (§ LL). Both are below the realization, which is what this guard is for.
        hostBootstrapImports source
            @?= ["HostBootstrap.Lift.Context", "HostBootstrap.Substrate.Frame"]
        fmap withoutCommas (SourceGuard.moduleImportTokens "HostBootstrap.Lift.Context" source)
            @?= Just ["LimaVM", "(", "..", ")", "shellVMArgs"]
        fmap withoutCommas (SourceGuard.moduleImportTokens "HostBootstrap.Substrate.Frame" source)
            @?= Just ["FrameNoun", "(", "LimaInstance", ")", "guardedDeleteArgs"]
        exports <-
            maybe
                (fail "HostBootstrap.Lima must have an explicit export list")
                pure
                (SourceGuard.moduleExportTokens "HostBootstrap.Lima" source)
        assertBool "LimaVM (..) is not reexported" (["LimaVM", "(", "..", ")"] `isInfixOf` exports)
        assertBool "shellVMArgs is not reexported" ("shellVMArgs" `elem` exports)
        SourceGuard.countHaskellTokenSequence ["data", "LimaVM"] source @?= 0
        SourceGuard.countHaskellTokenSequence ["newtype", "LimaVM"] source @?= 0
        SourceGuard.countHaskellTokenSequence ["shellVMArgs", "::"] source @?= 0
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
