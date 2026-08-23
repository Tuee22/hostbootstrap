{-# LANGUAGE OverloadedStrings #-}

module LiftContextSpec (tests) where

import Data.Char (isSpace)
import Data.List (isPrefixOf, nub, sort)
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import HostBootstrap.Config.Vocab (Mount (..))
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Lift.Context
import HostBootstrap.ProjectRoot (
    canonicalDurableHostPath,
    withCanonicalProjectRoot,
 )
import System.Directory (canonicalizePath, createDirectory, getCurrentDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "LiftContextSpec"
        [ testCase "the local context has no boundary layers" $
            localContext @?= LiftContext []
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
            inContainer container (inWsl2VM wsl (inLimaVM lima (inVM incus localContext)))
                @?= LiftContext
                    [ ViaVM incus
                    , ViaLimaVM lima
                    , ViaWsl2VM wsl
                    , ViaContainer container
                    ]
        , testCase "one pure renderer owns each VM transport" $ do
            execVMArgs (IncusVM "incus-vm" "image") ["true"]
                @?= ["exec", "incus-vm", "--", "true"]
            shellVMArgs (LimaVM "lima-vm") ["true"]
                @?= ["shell", "lima-vm", "--", "sudo", "-H", "true"]
            wslExecArgs "wsl-vm" ["true"]
                @?= ["-d", "wsl-vm", "--", "true"]
        , testCase "config delivery remains descriptive context data" $
            let delivery = ConfigDelivery "/app/demo.dhall" "/app/demo" "payload"
                container =
                    ContainerLift
                        { clImage = "demo:local"
                        , clPlacement = ProviderGuestContainer
                        , clMounts = []
                        , clExtraArgs = ["--network=host"]
                        , clRemoveAfter = True
                        , clConfigDelivery = Just delivery
                        }
             in LiftContext [ViaContainer container]
                    @?= inContainer container localContext
        , testCase "the direct host bind consumes one canonical root projection" $
            withSystemTempDirectory "hostbootstrap-lift-context-root" $ \project -> do
                let buildDir = project </> ".build"
                    configPath = buildDir </> "demo.dhall"
                createDirectory buildDir
                canonicalProject <- canonicalizePath project
                result <-
                    withCanonicalProjectRoot configPath "." $ \root ->
                        pure
                            ( canonicalHostMount
                                root
                                (canonicalDurableHostPath root)
                                "/workspace/demo/.data"
                                False
                            )
                result
                    @?= Right
                        Mount
                            { source = T.pack (canonicalProject </> ".data")
                            , target = "/workspace/demo/.data"
                            , readOnly = False
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

repositoryRoot :: IO FilePath
repositoryRoot = do
    cwd <- getCurrentDirectory
    found <- findRepoRoot cwd
    maybe (fail ("could not locate repository root from " ++ cwd)) pure found

hostBootstrapImports :: String -> [String]
hostBootstrapImports = sort . nub . mapMaybe importedModule . lines
  where
    importedModule line =
        case words line of
            "import" : "qualified" : moduleName : _ -> hostBootstrapModule moduleName
            "import" : moduleName : _ -> hostBootstrapModule moduleName
            _ -> Nothing

    hostBootstrapModule moduleName
        | "HostBootstrap." `isPrefixOf` moduleName = Just moduleName
        | otherwise = Nothing

mainLibraryStanza :: String -> Maybe String
mainLibraryStanza cabalText =
    case dropWhile ((/= "library") . trim) (lines cabalText) of
        [] -> Nothing
        _library : rest -> Just (unlines (takeWhile isLibraryContinuation rest))
  where
    isLibraryContinuation [] = True
    isLibraryContinuation line@(firstCharacter : _) =
        null (trim line) || isSpace firstCharacter

fieldModules :: String -> String -> [String]
fieldModules field = go . lines
  where
    go [] = []
    go (line : rest)
        | trim line == field =
            let fieldIndent = indentation line
                (continuation, remaining) =
                    span
                        (\next -> null (trim next) || indentation next > fieldIndent)
                        rest
             in moduleTokens continuation ++ go remaining
        | otherwise = go rest

    moduleTokens =
        filter ("HostBootstrap." `isPrefixOf`)
            . map (filter (/= ','))
            . words
            . unlines

indentation :: String -> Int
indentation = length . takeWhile isSpace

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace
