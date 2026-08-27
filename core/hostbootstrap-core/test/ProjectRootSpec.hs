{-# LANGUAGE OverloadedStrings #-}

module ProjectRootSpec (tests) where

import qualified Data.Text as T
import HostBootstrap.Config.Vocab (Mount (..))
import HostBootstrap.Lift (canonicalHostMount)
import HostBootstrap.ProjectRoot (
    ProjectRootError (..),
    canonicalDurableHostPath,
    canonicalHostPathValue,
    canonicalHostSubPath,
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import System.Directory (canonicalizePath, createDirectory, createDirectoryIfMissing, createDirectoryLink, withCurrentDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Info (os)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "ProjectRootSpec"
        [ {- A run-scoped durable root is not a fixed name, so the segments are
          supplied — and each one is checked to be a single ordinary component.
          A segment that could climb out would hand a trusted host adapter a path
          the root never admitted. -}
          testCase "a host subpath stays under the admitted root, or is refused" $
            withSystemTempDirectory "hostbootstrap-subpath" $ \workspace -> do
                let configPath = workspace </> ".build" </> "demo.dhall"
                createDirectoryIfMissing True (workspace </> ".build")
                expected <- canonicalizePath workspace
                admitted <-
                    withCanonicalProjectRoot configPath "." $ \root -> do
                        let under segments = fmap canonicalHostPathValue (canonicalHostSubPath root segments)
                        -- the production durable root is the one-segment case
                        under [".data"] @?= Right (canonicalHostPathValue (canonicalDurableHostPath root))
                        -- a run-scoped generation is two ordinary segments
                        under [".test_data", "run-42"]
                            @?= Right (expected </> ".test_data" </> "run-42")
                        -- and every way out is refused by name
                        under [".."] @?= Left (ProjectRootSegmentUnsafe "..")
                        under ["."] @?= Left (ProjectRootSegmentUnsafe ".")
                        under [""] @?= Left (ProjectRootSegmentUnsafe "")
                        under ["a/b"] @?= Left (ProjectRootSegmentUnsafe "a/b")
                        under ["a\\b"] @?= Left (ProjectRootSegmentUnsafe "a\\b")
                        under ["C:"] @?= Left (ProjectRootSegmentUnsafe "C:")
                        under [".test_data", ".."] @?= Left (ProjectRootSegmentUnsafe "..")
                        under [] @?= Left (ProjectRootSegmentUnsafe "<no segments>")
                        pure ()
                admitted @?= Right ()
        , testCase "relative roots resolve against the config-owned anchor, independent of cwd" $
            withSystemTempDirectory "hostbootstrap-project-root" $ \workspace -> do
                let project = workspace </> "project"
                    buildDir = project </> ".build"
                    other = workspace </> "other"
                    configPath = buildDir </> "demo.dhall"
                createDirectoryIfMissing True buildDir
                createDirectory other
                expected <- canonicalizePath project
                result <-
                    withCurrentDirectory other $
                        withCanonicalProjectRoot configPath "." (pure . canonicalProjectRootPath)
                result @?= Right expected
        , testCase "a missing root fails before the callback" $
            withSystemTempDirectory "hostbootstrap-project-root-missing" $ \project -> do
                let buildDir = project </> ".build"
                    configPath = buildDir </> "demo.dhall"
                    missing = project </> "missing"
                createDirectory buildDir
                result <- withCanonicalProjectRoot configPath "missing" (const (pure ()))
                result @?= Left (ProjectRootMissing missing)
        , testCase "a file cannot be admitted as a project root" $
            withSystemTempDirectory "hostbootstrap-project-root-file" $ \project -> do
                let buildDir = project </> ".build"
                    configPath = buildDir </> "demo.dhall"
                    wrongKind = project </> "not-a-directory"
                createDirectory buildDir
                writeFile wrongKind "not a directory"
                result <- withCanonicalProjectRoot configPath "not-a-directory" (const (pure ()))
                result @?= Left (ProjectRootNotDirectory wrongKind)
        , testCase "a relative root cannot escape the config-owned project anchor" $
            withSystemTempDirectory "hostbootstrap-project-root-escape" $ \workspace -> do
                let project = workspace </> "project"
                    buildDir = project </> ".build"
                    outside = workspace </> "outside"
                    configPath = buildDir </> "demo.dhall"
                createDirectoryIfMissing True buildDir
                createDirectory outside
                canonicalOutside <- canonicalizePath outside
                canonicalProject <- canonicalizePath project
                result <- withCanonicalProjectRoot configPath "../outside" (const (pure ()))
                result @?= Left (ProjectRootEscapesAnchor canonicalOutside canonicalProject)
        , testCase "a replaced relative root cannot redirect admission outside the project anchor" $
            if os == "mingw32"
                then pure ()
                else
                    withSystemTempDirectory "hostbootstrap-project-root-replaced" $ \workspace -> do
                        let project = workspace </> "project"
                            buildDir = project </> ".build"
                            outside = workspace </> "outside"
                            redirected = project </> "root"
                            configPath = buildDir </> "demo.dhall"
                        createDirectoryIfMissing True buildDir
                        createDirectory outside
                        createDirectoryLink outside redirected
                        canonicalOutside <- canonicalizePath outside
                        canonicalProject <- canonicalizePath project
                        result <- withCanonicalProjectRoot configPath "root" (const (pure ()))
                        result @?= Left (ProjectRootEscapesAnchor canonicalOutside canonicalProject)
        , testCase "the direct host bind consumes the canonical .data projection" $
            withSystemTempDirectory "hostbootstrap-project-root-bind" $ \project -> do
                let buildDir = project </> ".build"
                    configPath = buildDir </> "demo.dhall"
                createDirectory buildDir
                canonicalProject <- canonicalizePath project
                result <-
                    withCanonicalProjectRoot configPath "." $ \root ->
                        pure (canonicalHostMount root (canonicalDurableHostPath root) "/workspace/demo/.data" False)
                result
                    @?= Right
                        Mount
                            { source = T.pack (canonicalProject </> ".data")
                            , target = "/workspace/demo/.data"
                            , readOnly = False
                            }
        ]
