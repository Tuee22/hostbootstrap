{-# LANGUAGE OverloadedStrings #-}

module LiftContextSpec (tests) where

import Control.Monad (forM_)
import Data.List (isPrefixOf, nub, sort)
import qualified Data.Text as T
import HostBootstrap.Config.Vocab (Mount (..))
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Lift.Context
import HostBootstrap.ProjectRoot (
    canonicalDurableHostPath,
    withCanonicalProjectRoot,
 )
import SourceGuard (fieldModules, haskellImports, mainLibraryStanza)
import System.Directory (canonicalizePath, createDirectory, getCurrentDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "LiftContextSpec"
        [ testGroup "VM placement rendering" placementCases
        , testGroup "open VM stack" openVMStackCases
        , testGroup "checked layer reconstruction" checkedContextCases
        , testCase "the local context has no boundary layers" $ do
            liftLayers localContext @?= []
            liftVMStack localContext @?= emptyVMStack
            terminalContainer localContext @?= Nothing
        , testCase "context layers compose outermost-first" $ do
            let incus = IncusVM "incus-vm" "images:ubuntu/24.04"
                lima = LimaVM "lima-vm"
                wsl = Wsl2VM "wsl-vm"
                container =
                    ContainerLift
                        { clImage = "demo:local"
                        , clPlacement = ProviderGuestContainer
                        , clMounts = []
                        , clExtraArgs = []
                        , clRemoveAfter = True
                        , clConfigDelivery = Nothing
                        }
                layers = [ViaVM incus, ViaLimaVM lima, ViaWsl2VM wsl, ViaContainer container]
            expected <- expectContext layers
            inContainer container (inWsl2VM wsl (inLimaVM lima (inVM incus emptyVMStack))) @?= expected
        , testCase "one pure renderer owns each VM transport" $ do
            execVMArgs (IncusVM "incus-vm" "image") ["true"]
                @?= ["exec", "incus-vm", "--", "true"]
            shellVMArgs (LimaVM "lima-vm") ["true"]
                @?= ["shell", "lima-vm", "--", "sudo", "-H", "true"]
            wslExecArgs "wsl-vm" ["true"]
                @?= ["-d", "wsl-vm", "--exec", "true"]
        , testCase "config delivery remains descriptive context data" $ do
            let delivery = ConfigDelivery "/app/demo.dhall" "payload"
                container =
                    ContainerLift
                        { clImage = "demo:local"
                        , clPlacement = ProviderGuestContainer
                        , clMounts = []
                        , clExtraArgs = ["--network=host"]
                        , clRemoveAfter = True
                        , clConfigDelivery = Just delivery
                        }
            let context = inContainer container emptyVMStack
            terminalContainer context @?= Just container
            fmap clConfigDelivery (terminalContainer context) @?= Just (Just delivery)
            liftLayers context @?= [ViaContainer container]
        , testCase "closed contexts preserve record-style Show at application precedence" $ do
            showsPrec 10 localContext "tail" @?= "LiftContext {liftLayers = []}tail"
            showsPrec 11 localContext "tail" @?= "(LiftContext {liftLayers = []})tail"
            show (Just localContext) @?= "Just (LiftContext {liftLayers = []})"
        , testCase "the direct host bind consumes one canonical root projection" $
            withSystemTempDirectory "hostbootstrap-lift-context-root" $ \project -> do
                let buildDir = project </> ".build"
                    configPath = buildDir </> "demo.dhall"
                createDirectory buildDir
                canonicalProject <- canonicalizePath project
                forM_ [False, True] $ \mountReadOnly -> do
                    result <-
                        withCanonicalProjectRoot configPath "." $ \root ->
                            pure
                                ( canonicalHostMount
                                    root
                                    (canonicalDurableHostPath root)
                                    "/workspace/demo/.data"
                                    mountReadOnly
                                )
                    result
                        @?= Right
                            Mount
                                { source = T.pack (canonicalProject </> ".data")
                                , target = "/workspace/demo/.data"
                                , readOnly = mountReadOnly
                                }
        , testCase "the pure context has exactly its lower imports and is public" $ do
            root <- repositoryRoot
            let packageRoot = root </> "core" </> "hostbootstrap-core"
            contextSource <- readFile (packageRoot </> "src" </> "HostBootstrap" </> "Lift" </> "Context.hs")
            hostBootstrapImports contextSource
                @?= [ "HostBootstrap.Config.Vocab"
                    , "HostBootstrap.ProjectRoot"
                    ]
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            assertBool
                "HostBootstrap.Lift.Context is not exposed by the main library"
                ("HostBootstrap.Lift.Context" `elem` fieldModules "exposed-modules:" librarySource)
        ]

placementCases :: [TestTree]
placementCases =
    [ testCase "the named fold and lifecycle placements render their exact policies" $ do
        placementWorkdir foldPlacement @?= Nothing
        placementNonInteractive foldPlacement @?= False
        placementElevated foldPlacement @?= False
        placementWorkdir lifecyclePlacement @?= Just "/"
        placementNonInteractive lifecyclePlacement @?= True
        placementElevated lifecyclePlacement @?= True
        execVMArgsAt foldPlacement checkedIncus ["probe"] @?= ["exec", "incus-vm", "--", "probe"]
        shellVMArgsAt foldPlacement checkedLima ["probe"] @?= ["shell", "lima-vm", "--", "probe"]
        wslExecArgsAt foldPlacement "wsl-vm" ["probe"] @?= ["-d", "wsl-vm", "--exec", "probe"]
        execVMArgsAt lifecyclePlacement checkedIncus ["probe"] @?= ["exec", "incus-vm", "--cwd", "/", "-T", "--", "probe"]
        shellVMArgsAt lifecyclePlacement checkedLima ["probe"] @?= ["shell", "--workdir", "/", "lima-vm", "--", "sudo", "-n", "-H", "probe"]
        wslExecArgsAt lifecyclePlacement "wsl-vm" ["probe"] @?= ["-d", "wsl-vm", "--cd", "/", "--exec", "sudo", "-n", "-H", "probe"]
    ]
        <> [ testCase label $ do
                let arguments = ["probe", "a&b;$c"]
                execVMArgsAt placement checkedIncus arguments @?= incusArguments
                shellVMArgsAt placement checkedLima arguments @?= limaArguments
                wslExecArgsAt placement "wsl-vm" arguments @?= wslArguments
           | (label, placement, incusArguments, limaArguments, wslArguments) <-
                [ ( "no workdir, interactivity, or elevation flags"
                  , VMPlacement Nothing False False
                  , ["exec", "incus-vm", "--", "probe", "a&b;$c"]
                  , ["shell", "lima-vm", "--", "probe", "a&b;$c"]
                  , ["-d", "wsl-vm", "--exec", "probe", "a&b;$c"]
                  )
                , ( "a workdir adds only its provider's workdir arguments"
                  , VMPlacement (Just "/work") False False
                  , ["exec", "incus-vm", "--cwd", "/work", "--", "probe", "a&b;$c"]
                  , ["shell", "--workdir", "/work", "lima-vm", "--", "probe", "a&b;$c"]
                  , ["-d", "wsl-vm", "--cd", "/work", "--exec", "probe", "a&b;$c"]
                  )
                , ( "noninteractive without elevation does not introduce sudo"
                  , VMPlacement Nothing True False
                  , ["exec", "incus-vm", "-T", "--", "probe", "a&b;$c"]
                  , ["shell", "lima-vm", "--", "probe", "a&b;$c"]
                  , ["-d", "wsl-vm", "--exec", "probe", "a&b;$c"]
                  )
                , ( "elevation without noninteractive uses sudo without -n"
                  , VMPlacement Nothing False True
                  , ["exec", "incus-vm", "--", "probe", "a&b;$c"]
                  , ["shell", "lima-vm", "--", "sudo", "-H", "probe", "a&b;$c"]
                  , ["-d", "wsl-vm", "--exec", "sudo", "-H", "probe", "a&b;$c"]
                  )
                , ( "workdir and noninteractive remain independent of elevation"
                  , VMPlacement (Just "/work") True False
                  , ["exec", "incus-vm", "--cwd", "/work", "-T", "--", "probe", "a&b;$c"]
                  , ["shell", "--workdir", "/work", "lima-vm", "--", "probe", "a&b;$c"]
                  , ["-d", "wsl-vm", "--cd", "/work", "--exec", "probe", "a&b;$c"]
                  )
                , ( "workdir and elevation do not imply noninteractive"
                  , VMPlacement (Just "/work") False True
                  , ["exec", "incus-vm", "--cwd", "/work", "--", "probe", "a&b;$c"]
                  , ["shell", "--workdir", "/work", "lima-vm", "--", "sudo", "-H", "probe", "a&b;$c"]
                  , ["-d", "wsl-vm", "--cd", "/work", "--exec", "sudo", "-H", "probe", "a&b;$c"]
                  )
                , ( "noninteractive elevation does not imply a workdir"
                  , VMPlacement Nothing True True
                  , ["exec", "incus-vm", "-T", "--", "probe", "a&b;$c"]
                  , ["shell", "lima-vm", "--", "sudo", "-n", "-H", "probe", "a&b;$c"]
                  , ["-d", "wsl-vm", "--exec", "sudo", "-n", "-H", "probe", "a&b;$c"]
                  )
                , ( "workdir, noninteractive, and elevation combine in fixed order"
                  , VMPlacement (Just "/work") True True
                  , ["exec", "incus-vm", "--cwd", "/work", "-T", "--", "probe", "a&b;$c"]
                  , ["shell", "--workdir", "/work", "lima-vm", "--", "sudo", "-n", "-H", "probe", "a&b;$c"]
                  , ["-d", "wsl-vm", "--cd", "/work", "--exec", "sudo", "-n", "-H", "probe", "a&b;$c"]
                  )
                ]
           ]

openVMStackCases :: [TestTree]
openVMStackCases =
    [ testCase "closing the empty VM stack gives the local context" $ do
        vmContext emptyVMStack @?= localContext
        liftLayers (vmContext emptyVMStack) @?= []
        terminalContainer (vmContext emptyVMStack) @?= Nothing
    , testCase "closing a mixed open stack retains all crossings in outermost-first order" $ do
        let stack = inWsl2VM checkedWsl (inLimaVM checkedLima (inVM checkedIncus emptyVMStack))
            closed = vmContext stack
            layers = [ViaVM checkedIncus, ViaLimaVM checkedLima, ViaWsl2VM checkedWsl]
        liftLayers closed @?= layers
        expected <- expectContext layers
        closed @?= expected
        terminalContainer closed @?= Nothing
        show closed @?= ("LiftContext {liftLayers = " <> show layers <> "}")
        let withContainer = inContainer checkedContainer stack
        expectedContainer <- expectContext (layers <> [ViaContainer checkedContainer])
        withContainer @?= expectedContainer
        liftVMStack withContainer @?= stack
        vmContext (liftVMStack withContainer) @?= closed
    , testCase "each VM builder appends to an existing open prefix" $ do
        let prefix = inVM checkedIncus emptyVMStack
            innerIncus = IncusVM "inner-incus" "different:image"
            rows =
                [ (inVM innerIncus prefix, [ViaVM checkedIncus, ViaVM innerIncus])
                , (inLimaVM checkedLima prefix, [ViaVM checkedIncus, ViaLimaVM checkedLima])
                , (inWsl2VM checkedWsl prefix, [ViaVM checkedIncus, ViaWsl2VM checkedWsl])
                ]
        forM_ rows $ \(stack, expected) -> do
            liftLayers (vmContext stack) @?= expected
            terminalContainer (vmContext stack) @?= Nothing
        liftLayers (vmContext prefix) @?= [ViaVM checkedIncus]
    ]

checkedContextCases :: [TestTree]
checkedContextCases =
    [ testCase ("round-trips " <> label <> " without changing order or presentation") $ do
        let admitted = liftContextFromLayers layers
        admitted @?= Right original
        fmap liftLayers admitted @?= Right layers
        fmap show admitted @?= Right ("LiftContext {liftLayers = " <> show layers <> "}")
        terminalContainer original @?= expectedTerminal
    | (label, layers, expectedTerminal, original) <-
        [ ("an empty context", [], Nothing, localContext)
        , ("an Incus context", [ViaVM checkedIncus], Nothing, vmContext (inVM checkedIncus emptyVMStack))
        , ("a Lima context", [ViaLimaVM checkedLima], Nothing, vmContext (inLimaVM checkedLima emptyVMStack))
        , ("a WSL2 context", [ViaWsl2VM checkedWsl], Nothing, vmContext (inWsl2VM checkedWsl emptyVMStack))
        , ("mixed and repeated VM crossings", checkedVMLayers, Nothing, vmContext checkedVMStack)
        , ("a terminal container", [ViaContainer checkedContainer], Just checkedContainer, inContainer checkedContainer emptyVMStack)
        , ("mixed VMs followed by a container", checkedVMLayers <> [ViaContainer checkedContainer], Just checkedContainer, inContainer checkedContainer checkedVMStack)
        ]
    ]
        -- Sealing removes the former invalid-context view/map inputs. These
        -- lists remain exact reconstruction refusals; the public compiler's
        -- VMLayerAfterContainer fixture holds the builder boundary.
        <> [ testCase ("refuses reconstruction of " <> label) $
                liftContextFromLayers layers @?= Left expected
           | (label, layers, expected) <-
                [ ("an Incus VM after a container", [ViaContainer checkedContainer, ViaVM checkedIncus], afterContainer)
                , ("a Lima VM after a container", [ViaContainer checkedContainer, ViaLimaVM checkedLima], afterContainer)
                , ("a WSL2 VM after a container", [ViaContainer checkedContainer, ViaWsl2VM checkedWsl], afterContainer)
                , ("two containers", [ViaContainer checkedContainer, ViaContainer otherContainer], duplicateContainer)
                , ("a second container after an intervening VM", [ViaContainer checkedContainer, ViaVM checkedIncus, ViaContainer otherContainer], duplicateContainer)
                , ("a VM after two containers", [ViaContainer checkedContainer, ViaContainer otherContainer, ViaWsl2VM checkedWsl], duplicateContainer)
                ]
           ]
        <> [ testCase "empty and VM-only maps preserve the context without calling the mapper" $
                forM_ [[], [ViaVM checkedIncus], [ViaLimaVM checkedLima], [ViaWsl2VM checkedWsl], checkedVMLayers] $ \layers -> do
                    original <- expectContext layers
                    let mapped = mapTerminalContainer (\_ -> error "VM-only context called its mapper") original
                    mapped @?= original
                    show mapped @?= ("LiftContext {liftLayers = " <> show layers <> "}")
                    terminalContainer mapped @?= Nothing
           , testCase "a terminal map changes only its container and preserves every VM crossing" $
                forM_ [[], checkedVMLayers] $ \prefix -> do
                    original <- expectContext (prefix <> [ViaContainer checkedContainer])
                    let mapped = mapTerminalContainer (\container -> container {clImage = clImage container <> ":changed", clRemoveAfter = False}) original
                        changed = checkedContainer {clImage = "checked:image:changed", clRemoveAfter = False}
                        expectedLayers = prefix <> [ViaContainer changed]
                    expected <- expectContext expectedLayers
                    mapped @?= expected
                    liftLayers mapped @?= expectedLayers
                    terminalContainer mapped @?= Just changed
                    liftContextFromLayers (liftLayers mapped) @?= Right mapped
                    show mapped @?= ("LiftContext {liftLayers = " <> show expectedLayers <> "}")
           ]
  where
    afterContainer = "lift context contains a VM layer after a container"
    duplicateContainer = "lift context contains more than one container layer"
    otherContainer = checkedContainer {clImage = "second:image"}

checkedIncus :: IncusVM
checkedIncus = IncusVM "incus-vm" "images:ubuntu/24.04"

checkedLima :: LimaVM
checkedLima = LimaVM "lima-vm"

checkedWsl :: Wsl2VM
checkedWsl = Wsl2VM "wsl-vm"

checkedVMLayers :: [LiftLayer]
checkedVMLayers = [ViaVM checkedIncus, ViaLimaVM checkedLima, ViaWsl2VM checkedWsl, ViaVM checkedIncus]

checkedVMStack :: VMStack
checkedVMStack = inVM checkedIncus (inWsl2VM checkedWsl (inLimaVM checkedLima (inVM checkedIncus emptyVMStack)))

expectContext :: [LiftLayer] -> IO LiftContext
expectContext = either (assertFailure . ("invalid positive context fixture: " <>)) pure . liftContextFromLayers

checkedContainer :: ContainerLift
checkedContainer =
    ContainerLift
        { clImage = "checked:image"
        , clPlacement = ProviderGuestContainer
        , clMounts = [Mount "/host" "/guest" True]
        , clExtraArgs = ["--network=host"]
        , clRemoveAfter = True
        , clConfigDelivery = Just (ConfigDelivery "/app/project.dhall" "projection")
        }

repositoryRoot :: IO FilePath
repositoryRoot = do
    cwd <- getCurrentDirectory
    found <- findRepoRoot cwd
    maybe (fail ("could not locate repository root from " ++ cwd)) pure found

{- | Every @HostBootstrap.*@ module a source imports.

Reads through the shared lexer rather than through @words@ on each line, so a
multiline, @safe@, pragma-decorated, or package-qualified import counts and a
commented-out or quoted one does not.
-}
hostBootstrapImports :: String -> [String]
hostBootstrapImports =
    sort . nub . filter ("HostBootstrap." `isPrefixOf`) . haskellImports
