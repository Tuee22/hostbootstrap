{-# LANGUAGE CPP #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Build-invocation authority for the in-Dockerfile gate.

Every case measures real files in a real temporary tree and signs with a real
Ed25519 keypair, because the whole point of this gate is that the signed
description and the locally measured reality must agree.
-}
module BuildAuthoritySpec (tests, buildPosixFilesSupported, buildUnpairedNameSupported) where

import ConditionalCase (conditionalCase)
import Control.Exception (IOException, finally, try)
import Control.Monad (forM_, unless)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import qualified Crypto.PubKey.Ed25519 as Ed25519
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Char (ord)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Build
import HostBootstrap.Handoff (frameWire)
import HostBootstrap.Ownership.Object (OwnershipFault (OwnershipUnsupported))
import HostBootstrap.Ownership.Posix (posixOwnershipRow)
import HostBootstrap.Ownership.Primitive (OwnershipPrimitive (rowCreateFile), withOwnershipRow)
import HostBootstrap.Ownership.Windows (windowsOwnershipRow)
import GHC.IO.Exception (IOErrorType (InvalidArgument))
import qualified SourceGuard
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory, removeFile, removePathForcibly, renameFile)
import qualified System.Directory.OsPath as NativeDirectory
import qualified System.File.OsPath as NativeFile
import System.FilePath ((</>))
import System.IO.Error (ioeGetErrorType)
import System.IO.Temp (withSystemTempDirectory)
import System.IO.Unsafe (unsafePerformIO)
import System.Info (os)
import qualified System.OsPath as OsPath
import System.Timeout (timeout)
#ifndef mingw32_HOST_OS
import qualified System.Posix.Files as Posix
#endif
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "BuildAuthoritySpec"
        [ testGroup "provisioned keys" keyTests
        , testGroup "project coordinate" projectCoordinateTests
        , testGroup "specification coordinate" specCoordinateTests
        , testGroup "config coordinate" configCoordinateTests
        , testGroup "identifier coordinate" identifierCoordinateTests
        , testGroup "source-digest coordinate" sourceDigestCoordinateTests
        , testGroup "coordinator coordinate" coordinatorCoordinateTests
        , testGroup "builder coordinate" builderCoordinateTests
        , testGroup "frame coordinate" frameCoordinateTests
        , testGroup "source-root coordinate" sourceRootCoordinateTests
        , testGroup "builder-path coordinate" builderPathCoordinateTests
        , testGroup "source measurement" measurementTests
        , testGroup "POSIX native source files" posixFileTests
        , testGroup "Windows unpaired source names" unpairedNameTests
        , testGroup "filesystem exception contracts" filesystemExceptionTests
        , testGroup "the coordinator channel" channelTests
        , testGroup "verification" verificationTests
        ]

-- ---------------------------------------------------------------------------
-- Provisioned identity

keyTests :: [TestTree]
keyTests =
    [ testCase "signing and verification keys are provisioned through separate files" $
        withSystemTempDirectory "hostbootstrap-build-keys" $ \root -> do
            let signingPath = root </> "coordinator.key"
                verificationPath = root </> "coordinator.pub"
            ByteString.writeFile signingPath fixtureSigningSeed
            signingKey <- expectIO =<< installedBuildSigningKey signingPath
            let provisionedVerificationKey = buildSigningVerificationKey signingKey
            ByteString.writeFile
                verificationPath
                (buildVerificationKeyBytes provisionedVerificationKey)
            installedVerificationKey <- expectIO =<< installedBuildVerificationKey verificationPath
            buildVerificationKeyBytes installedVerificationKey
                @?= buildVerificationKeyBytes provisionedVerificationKey
    , testCase "a malformed signing seed is refused" $
        case buildSigningKeyFromBytes "short" of
            Left (BuildSigningKeyInvalid _) -> pure ()
            other -> assertFailure ("expected an invalid signing key, got " <> show other)
    , testCase "a malformed installed verification key is refused" $
        withSystemTempDirectory "hostbootstrap-build-keys" $ \root -> do
            let path = root </> "coordinator.pub"
            ByteString.writeFile path "short"
            outcome <- installedBuildVerificationKey path
            case outcome of
                Left (BuildVerificationKeyInvalid _) -> pure ()
                other -> assertFailure ("expected an invalid verification key, got " <> show other)
    , testCase "missing provisioned keys are typed refusals" $
        withSystemTempDirectory "hostbootstrap-build-keys" $ \root -> do
            signing <- installedBuildSigningKey (root </> "missing.key")
            case signing of
                Left (BuildSigningKeyUnavailable _) -> pure ()
                other -> assertFailure ("expected an unavailable signing key, got " <> show other)
            verification <- installedBuildVerificationKey (root </> "missing.pub")
            case verification of
                Left (BuildVerificationKeyUnavailable _) -> pure ()
                other -> assertFailure ("expected an unavailable verification key, got " <> show other)
    ]

-- ---------------------------------------------------------------------------
-- Measurement

measurementTests :: [TestTree]
measurementTests =
    [ testCase "the same tree measures the same digest twice" $
        withSourceTree $ \root -> do
            first <- expectIO =<< measureSourceDigest root
            second <- expectIO =<< measureSourceDigest root
            first @?= second
    , testCase "changed contents change the digest" $
        withSourceTree $ \root -> do
            before <- expectIO =<< measureSourceDigest root
            ByteString.writeFile (root </> "src" </> "Main.hs") "main = pure ()\n-- edited"
            after <- expectIO =<< measureSourceDigest root
            assertBool "the digest moved" (before /= after)
    , testCase "moving bytes to a different name changes the digest" $
        withSourceTree $ \root -> do
            before <- expectIO =<< measureSourceDigest root
            contents <- ByteString.readFile (root </> "src" </> "Main.hs")
            listDirectory (root </> "src") >>= (@?= ["Main.hs"])
            renameFile (root </> "src" </> "Main.hs") (root </> "src" </> "Renamed.hs")
            doesFileExist (root </> "src" </> "Main.hs") >>= (@?= False)
            listDirectory (root </> "src") >>= (@?= ["Renamed.hs"])
            ByteString.readFile (root </> "src" </> "Renamed.hs") >>= (@?= contents)
            after <- expectIO =<< measureSourceDigest root
            -- Path and contents are both bound, so relocating bytes is visible.
            assertBool "the digest moved" (before /= after)
    , testCase "distinct non-ASCII filenames do not collide" $
        withSystemTempDirectory "hostbootstrap-build-unicode" $ \root -> do
            let first = root </> "first"
                second = root </> "second"
            createDirectoryIfMissing True first
            createDirectoryIfMissing True second
            -- These code points have the same low eight bits. Char8 path
            -- encoding therefore collapsed them even though UTF-8 does not.
            ByteString.writeFile (first </> "\x4e00.hs") "same contents"
            ByteString.writeFile (second </> "\x4f00.hs") "same contents"
            firstDigest <- expectIO =<< measureSourceDigest first
            secondDigest <- expectIO =<< measureSourceDigest second
            assertBool "the Unicode path bytes remain distinct" (firstDigest /= secondDigest)
    , testCase "the same nested tree under different roots has the same digest" $
        withSourceTree $ \first -> withSourceTree $ \second -> do
            assertBool "the actual temporary roots differ" (first /= second)
            firstDigest <- expectIO =<< measureSourceDigest first
            secondDigest <- expectIO =<< measureSourceDigest second
            firstDigest @?= secondDigest
    , testCase "two-file names and contents match the independent framed-byte golden" $
        withSystemTempDirectory "hostbootstrap-build-golden" $ \root -> do
            createDirectoryIfMissing True (root </> "src")
            ByteString.writeFile (root </> "a.hs") "x"
            ByteString.writeFile (root </> "src" </> "b.hs") "y"
            measureSourceDigest root
                >>= (@?= Right "375d43f1879bc0c1510f6ccfd2c0cbbf1606367308be6f5b21266a1429cbf842")
    , testCase "ordinary Unicode names share the cross-host canonical-byte golden" $
        withSystemTempDirectory "hostbootstrap-build-unicode-golden" $ \root -> do
            createDirectoryIfMissing True (root </> "\x4e00")
            ByteString.writeFile (root </> "\x03bb.hs") "x"
            ByteString.writeFile (root </> "\x4e00" </> "\x1f600.hs") "y"
            measureSourceDigest root
                >>= (@?= Right "be72e391ed23e1a4cfc9fd89a7637692e0d66ac4e89eba0dbf931f50dfa3294c")
    , testCase "a non-BMP filename retains the same literal byte golden" $
        withSystemTempDirectory "hostbootstrap-build-non-bmp" $ \root -> do
            ByteString.writeFile (root </> "\x1f600.hs") "x"
            measureSourceDigest root
                >>= (@?= Right "f6884489278af0d011505bfbc6f4a1d3c95872e13744031d4906c9e9c7a82b61")
    , testCase "framing distinguishes a name-content boundary shift" $
        withSystemTempDirectory "hostbootstrap-build-boundary-a" $ \first ->
            withSystemTempDirectory "hostbootstrap-build-boundary-ab" $ \second -> do
                ByteString.writeFile (first </> "a") "bc"
                ByteString.writeFile (second </> "ab") "c"
                one <- expectIO =<< measureSourceDigest first
                two <- expectIO =<< measureSourceDigest second
                one @?= "3fafa1cf2f19a7c1129beb20cf0983f73a489a221fc0dd2f16d1be292d089205"
                two @?= "601d5476e2ccfe2c87a2bba7a322659734a05749d5b5aa781f513e4912db0d5f"
                assertBool "moving the framing boundary changes the digest" (one /= two)
    , testCase "an absent source root is a refusal, not an empty-tree digest" $
        withSystemTempDirectory "hostbootstrap-build" $ \directory -> do
            outcome <- measureSourceDigest (directory </> "not-here")
            case outcome of
                Left (BuildSourceUnavailable _) -> pure ()
                other -> assertFailure ("expected a source refusal, got " <> show other)
    , testCase "an absent binary is a refusal, not a skipped comparison" $
        withSystemTempDirectory "hostbootstrap-build" $ \directory -> do
            outcome <- measureBinaryDigest (directory </> "no-binary")
            case outcome of
                Left (BuildBinaryUnavailable _) -> pure ()
                other -> assertFailure ("expected a binary refusal, got " <> show other)
    ]

-- ---------------------------------------------------------------------------
-- Independent binding bytes and observed compatibility literals.
builderPathCoordinateTests :: [TestTree]
builderPathCoordinateTests =
    [ testCase "the builder-path role retains empty, relative and absolute descriptive paths" $
        forM_ ["", "relative/builder", "/absolute/builder", "C:\\bin\\builder", "builder\"line\n\\path"] $ \value -> do
            let path = builderPathFromFilePath value
            builderPathFilePath path @?= value
            showsPrec 11 path "" @?= showsPrec 11 value ""
    ]

sourceRootCoordinateTests :: [TestTree]
sourceRootCoordinateTests =
    [ testCase "the source-root role retains empty, relative and absolute descriptive paths" $
        forM_ ["", "relative/root", "/absolute/root", "C:\\source\\root", "root\"line\n\\path"] $ \value -> do
            let root = buildSourceRootFromFilePath value
            buildSourceRootFilePath root @?= value
            showsPrec 11 root "" @?= showsPrec 11 value ""
    ]

frameCoordinateTests :: [TestTree]
frameCoordinateTests =
    [ testCase "the frame role accepts arbitrary and empty descriptive text before verification" $
        forM_ ["", " ", "not a container name", "frame\"line\n\\path"] $ \value -> do
            let name = buildFrameNameFromText value
                binding = literalBuildBinding{buildFrameName = name}
            buildFrameNameText name @?= value
            buildFrameNameText (buildFrameName binding) @?= value
            showsPrec 11 name "" @?= showsPrec 11 value ""
    ]

builderCoordinateTests :: [TestTree]
builderCoordinateTests =
    [ testCase "the builder role accepts descriptive text without validity or provenance checks" $
        forM_ ["", " ", "not hexadecimal", "builder\"line\n\\path"] $ \value -> do
            let digest = builderDigestFromText value
                binding = literalBuildBinding{buildBuilderDigest = digest}
            builderDigestText digest @?= value
            builderDigestText (buildBuilderDigest binding) @?= value
            showsPrec 11 digest "" @?= showsPrec 11 value ""
    ]

coordinatorCoordinateTests :: [TestTree]
coordinatorCoordinateTests =
    [ testCase "the coordinator role accepts descriptive text without validity or provenance checks" $
        forM_ ["", " ", "not hexadecimal", "coordinator\"line\n\\path"] $ \value -> do
            let digest = coordinatorDigestFromText value
                binding = literalBuildBinding{buildCoordinatorDigest = digest}
            coordinatorDigestText digest @?= value
            coordinatorDigestText (buildCoordinatorDigest binding) @?= value
            showsPrec 11 digest "" @?= showsPrec 11 value ""
    ]

sourceDigestCoordinateTests :: [TestTree]
sourceDigestCoordinateTests =
    [ testCase "the source-digest role accepts descriptive text without format or provenance checks" $
        forM_ ["", " ", "not hexadecimal", "source\"line\n\\path"] $ \value -> do
            let digest = buildSourceDigestFromText value
                binding = literalBuildBinding{buildSourceDigest = digest}
            buildSourceDigestText digest @?= value
            buildSourceDigestText (buildSourceDigest binding) @?= value
            showsPrec 11 digest "" @?= showsPrec 11 value ""
    ]

identifierCoordinateTests :: [TestTree]
identifierCoordinateTests =
    [ testCase "the identifier role accepts descriptive text including an empty value" $
        forM_ ["", " ", "not a generated id", "id\"line\n\\path"] $ \value -> do
            let identifier = buildIdentifierFromText value
                binding = literalBuildBinding{buildIdentifier = identifier}
            buildIdentifierText identifier @?= value
            buildIdentifierText (buildIdentifier binding) @?= value
            showsPrec 11 identifier "" @?= showsPrec 11 value ""
    ]

configCoordinateTests :: [TestTree]
configCoordinateTests =
    [ testCase "the config role accepts descriptive text without new validation" $
        forM_ ["", " ", "not hexadecimal", "config\"line\n\\path"] $ \value -> do
            let config = buildConfigDigestFromText value
            buildConfigDigestText config @?= value
            showsPrec 11 config "" @?= showsPrec 11 value ""
    ]

specCoordinateTests :: [TestTree]
specCoordinateTests =
    [ testCase "the specification role accepts descriptive text without new validation" $
        forM_ ["", " ", "not hexadecimal", "spec\"line\n\\path"] $ \value -> do
            let spec = buildSpecDigestFromText value
            buildSpecDigestText spec @?= value
            showsPrec 11 spec "" @?= showsPrec 11 value ""
    ]

projectCoordinateTests :: [TestTree]
projectCoordinateTests =
    [ testCase "the project role accepts arbitrary descriptive text without new validation" $
        forM_ ["", " ", "not hex", "project\"line\n\\path"] $ \value -> do
            let project = buildProjectNameFromText value
            buildProjectNameText project @?= value
            showsPrec 11 project "" @?= showsPrec 11 value ""
    , testCase "independent binding bytes, Show and signature vectors remain exact" $ do
        let escaped = literalBuildBinding{buildProjectName = buildProjectNameFromText "project\"line\n\\path"}
        renderBuildBinding literalBuildBinding @?= literalBuildBindingWire
        renderBuildBinding escaped @?= literalEscapedBuildBindingWire
        buildBindingObservations "base" literalBuildBinding
            ++ buildBindingObservations "escaped" escaped
            @?= literalBuildBindingObservations
        key <- expectIO (buildSigningKeyFromBytes fixtureSigningSeed)
        withBuildCoordinator key (coordinatorDigestFromText "coordinator-digest") $ \coordinator -> do
            show coordinator @?= "BuildCoordinator <signing> coordinator-digest"
            grant <- expectIO =<< signBuildGrant coordinator literalBuildBinding
            buildGrantSignature grant @?= literalBuildBindingSignature
    ]

buildBindingObservations :: String -> BuildBinding -> [(String, String)]
buildBindingObservations label binding =
    [ (label ++ "/0", showsPrec 0 binding "")
    , (label ++ "/10", showsPrec 10 binding "")
    , (label ++ "/11", showsPrec 11 binding "")
    , (label ++ "/maybe", show (Just binding))
    , (label ++ "/list", show [binding])
    , (label ++ "/project", Text.unpack (buildProjectNameText (buildProjectName binding)))
    ]

literalBuildBinding :: BuildBinding
literalBuildBinding =
    BuildBinding
        { buildProjectName = buildProjectNameFromText "hostbootstrap-demo"
        , buildSpecDigest = buildSpecDigestFromText "spec-1"
        , buildConfigDigest = buildConfigDigestFromText "config-1"
        , buildIdentifier = buildIdentifierFromText "build-7"
        , buildSourceDigest = buildSourceDigestFromText "source-digest"
        , buildCoordinatorDigest = coordinatorDigestFromText "coordinator-digest"
        , buildBuilderDigest = builderDigestFromText "builder-digest"
        , buildFrameName = buildFrameNameFromText "image-build-container-0"
        }

literalBuildBindingWire :: ByteString
literalBuildBindingWire =
    ByteString.pack
        [ 0, 0, 0, 0, 0, 0, 0, 18, 104, 111, 115, 116, 98, 111, 111, 116
        , 115, 116, 114, 97, 112, 45, 100, 101, 109, 111, 0, 0, 0, 0, 0, 0
        , 0, 6, 115, 112, 101, 99, 45, 49, 0, 0, 0, 0, 0, 0, 0, 8
        , 99, 111, 110, 102, 105, 103, 45, 49, 0, 0, 0, 0, 0, 0, 0, 7
        , 98, 117, 105, 108, 100, 45, 55, 0, 0, 0, 0, 0, 0, 0, 13, 115
        , 111, 117, 114, 99, 101, 45, 100, 105, 103, 101, 115, 116, 0, 0, 0, 0
        , 0, 0, 0, 18, 99, 111, 111, 114, 100, 105, 110, 97, 116, 111, 114, 45
        , 100, 105, 103, 101, 115, 116, 0, 0, 0, 0, 0, 0, 0, 14, 98, 117
        , 105, 108, 100, 101, 114, 45, 100, 105, 103, 101, 115, 116, 0, 0, 0, 0
        , 0, 0, 0, 23, 105, 109, 97, 103, 101, 45, 98, 117, 105, 108, 100, 45
        , 99, 111, 110, 116, 97, 105, 110, 101, 114, 45, 48
        ]

literalEscapedBuildBindingWire :: ByteString
literalEscapedBuildBindingWire =
    ByteString.pack
        [ 0, 0, 0, 0, 0, 0, 0, 18, 112, 114, 111, 106, 101, 99, 116, 34
        , 108, 105, 110, 101, 10, 92, 112, 97, 116, 104, 0, 0, 0, 0, 0, 0
        , 0, 6, 115, 112, 101, 99, 45, 49, 0, 0, 0, 0, 0, 0, 0, 8
        , 99, 111, 110, 102, 105, 103, 45, 49, 0, 0, 0, 0, 0, 0, 0, 7
        , 98, 117, 105, 108, 100, 45, 55, 0, 0, 0, 0, 0, 0, 0, 13, 115
        , 111, 117, 114, 99, 101, 45, 100, 105, 103, 101, 115, 116, 0, 0, 0, 0
        , 0, 0, 0, 18, 99, 111, 111, 114, 100, 105, 110, 97, 116, 111, 114, 45
        , 100, 105, 103, 101, 115, 116, 0, 0, 0, 0, 0, 0, 0, 14, 98, 117
        , 105, 108, 100, 101, 114, 45, 100, 105, 103, 101, 115, 116, 0, 0, 0, 0
        , 0, 0, 0, 23, 105, 109, 97, 103, 101, 45, 98, 117, 105, 108, 100, 45
        , 99, 111, 110, 116, 97, 105, 110, 101, 114, 45, 48
        ]

literalBuildBindingSignature :: ByteString
literalBuildBindingSignature =
    ByteString.pack
        [ 36, 175, 178, 224, 22, 163, 6, 245, 171, 173, 63, 179, 89, 121, 130, 206
        , 108, 243, 4, 117, 17, 117, 160, 100, 122, 75, 80, 129, 54, 245, 146, 171
        , 237, 204, 129, 42, 191, 112, 79, 163, 110, 186, 41, 246, 191, 22, 237, 167
        , 138, 64, 77, 250, 228, 59, 61, 174, 89, 74, 68, 48, 213, 202, 236, 11
        ]

literalBuildBindingObservations :: [(String, String)]
literalBuildBindingObservations =
    [ ("base/0", "BuildBinding {buildProjectName = \"hostbootstrap-demo\", buildSpecDigest = \"spec-1\", buildConfigDigest = \"config-1\", buildIdentifier = \"build-7\", buildSourceDigest = \"source-digest\", buildCoordinatorDigest = \"coordinator-digest\", buildBuilderDigest = \"builder-digest\", buildFrameName = \"image-build-container-0\"}")
    , ("base/10", "BuildBinding {buildProjectName = \"hostbootstrap-demo\", buildSpecDigest = \"spec-1\", buildConfigDigest = \"config-1\", buildIdentifier = \"build-7\", buildSourceDigest = \"source-digest\", buildCoordinatorDigest = \"coordinator-digest\", buildBuilderDigest = \"builder-digest\", buildFrameName = \"image-build-container-0\"}")
    , ("base/11", "(BuildBinding {buildProjectName = \"hostbootstrap-demo\", buildSpecDigest = \"spec-1\", buildConfigDigest = \"config-1\", buildIdentifier = \"build-7\", buildSourceDigest = \"source-digest\", buildCoordinatorDigest = \"coordinator-digest\", buildBuilderDigest = \"builder-digest\", buildFrameName = \"image-build-container-0\"})")
    , ("base/maybe", "Just (BuildBinding {buildProjectName = \"hostbootstrap-demo\", buildSpecDigest = \"spec-1\", buildConfigDigest = \"config-1\", buildIdentifier = \"build-7\", buildSourceDigest = \"source-digest\", buildCoordinatorDigest = \"coordinator-digest\", buildBuilderDigest = \"builder-digest\", buildFrameName = \"image-build-container-0\"})")
    , ("base/list", "[BuildBinding {buildProjectName = \"hostbootstrap-demo\", buildSpecDigest = \"spec-1\", buildConfigDigest = \"config-1\", buildIdentifier = \"build-7\", buildSourceDigest = \"source-digest\", buildCoordinatorDigest = \"coordinator-digest\", buildBuilderDigest = \"builder-digest\", buildFrameName = \"image-build-container-0\"}]")
    , ("base/project", "hostbootstrap-demo")
    , ("escaped/0", "BuildBinding {buildProjectName = \"project\\\"line\\n\\\\path\", buildSpecDigest = \"spec-1\", buildConfigDigest = \"config-1\", buildIdentifier = \"build-7\", buildSourceDigest = \"source-digest\", buildCoordinatorDigest = \"coordinator-digest\", buildBuilderDigest = \"builder-digest\", buildFrameName = \"image-build-container-0\"}")
    , ("escaped/10", "BuildBinding {buildProjectName = \"project\\\"line\\n\\\\path\", buildSpecDigest = \"spec-1\", buildConfigDigest = \"config-1\", buildIdentifier = \"build-7\", buildSourceDigest = \"source-digest\", buildCoordinatorDigest = \"coordinator-digest\", buildBuilderDigest = \"builder-digest\", buildFrameName = \"image-build-container-0\"}")
    , ("escaped/11", "(BuildBinding {buildProjectName = \"project\\\"line\\n\\\\path\", buildSpecDigest = \"spec-1\", buildConfigDigest = \"config-1\", buildIdentifier = \"build-7\", buildSourceDigest = \"source-digest\", buildCoordinatorDigest = \"coordinator-digest\", buildBuilderDigest = \"builder-digest\", buildFrameName = \"image-build-container-0\"})")
    , ("escaped/maybe", "Just (BuildBinding {buildProjectName = \"project\\\"line\\n\\\\path\", buildSpecDigest = \"spec-1\", buildConfigDigest = \"config-1\", buildIdentifier = \"build-7\", buildSourceDigest = \"source-digest\", buildCoordinatorDigest = \"coordinator-digest\", buildBuilderDigest = \"builder-digest\", buildFrameName = \"image-build-container-0\"})")
    , ("escaped/list", "[BuildBinding {buildProjectName = \"project\\\"line\\n\\\\path\", buildSpecDigest = \"spec-1\", buildConfigDigest = \"config-1\", buildIdentifier = \"build-7\", buildSourceDigest = \"source-digest\", buildCoordinatorDigest = \"coordinator-digest\", buildBuilderDigest = \"builder-digest\", buildFrameName = \"image-build-container-0\"}]")
    , ("escaped/project", "project\"line\n\\path")
    ]

-- Native filename and regular-file subjects

buildPosixFilesSupported :: Bool
buildPosixFilesSupported = os /= "mingw32"

posixFileTests :: [TestTree]
posixFileTests =
    [ row "undecodable single-byte source names retain different exact bytes" $
        withNativeSourceName ['\xfe'] $ \first firstUnits ->
            withNativeSourceName ['\xff'] $ \second secondUnits -> do
                firstUnits @?= [[254]]
                secondUnits @?= [[255]]
                one <- expectIO =<< measureSourceDigest first
                two <- expectIO =<< measureSourceDigest second
                one @?= "45b4bb32659a55371649a4ac518b564bd14f382c8823b7490dd0c0e099eafe65"
                two @?= "2fbbe717df9b8115c78d82c8682f988cffec4f871c6033b128e1cbefe57b386f"
                assertBool "the actual raw filename bytes are not conflated" (one /= two)
    , row "a source FIFO refuses before a blocking read" $
        withSystemTempDirectory "hostbootstrap-build-source-fifo" $ \root -> do
            createSourceFifo (root </> "pipe")
            bounded <- timeout 5000000 (measureSourceDigest root)
            case bounded of
                Nothing -> assertFailure "source FIFO measurement exceeded five seconds"
                Just outcome -> outcome
                    @?= Left (BuildSourceUnavailable "non-regular source entry: \"pipe\"")
    , row "a builder FIFO refuses before a blocking read" $
        withSystemTempDirectory "hostbootstrap-build-binary-fifo" $ \root -> do
            let path = root </> "builder-pipe"
            createSourceFifo path
            bounded <- timeout 5000000 (measureBinaryDigest path)
            case bounded of
                Nothing -> assertFailure "builder FIFO measurement exceeded five seconds"
                Just outcome -> outcome
                    @?= Left (BuildBinaryUnavailable ("non-regular binary path: " <> Text.pack path))
    ]
  where
    row label action = conditionalCase
        ["BuildAuthoritySpec", "POSIX native source files"] buildPosixFilesSupported label action $ do
            os @?= "mingw32"
            withSystemTempDirectory "hostbootstrap-build-posix-refusal" $ \root -> do
                outcome <- withOwnershipRow posixOwnershipRow $ \primitive ->
                    rowCreateFile primitive (root </> "posix-capability-control") "x"
                outcome @?= Left (OwnershipUnsupported
                    "the POSIX ownership row needs lstat identity, O_NOFOLLOW opens, fcntl record locks, and link(2), none of which this host supplies")
                doesFileExist (root </> "posix-capability-control") >>= (@?= False)
            putStrLn "Unsupported: the actual POSIX capability row refuses this host; no Build FIFO or raw-byte case ran"

createSourceFifo :: FilePath -> IO ()
#ifndef mingw32_HOST_OS
createSourceFifo path = Posix.createNamedPipe path Posix.ownerModes
#else
createSourceFifo _ = assertFailure "a POSIX FIFO action ran on Windows"
#endif

withNativeSourceName :: String -> (FilePath -> [[Int]] -> IO ()) -> IO ()
withNativeSourceName units use =
    withSystemTempDirectory "hostbootstrap-build-native-name" $ \root -> do
        nativeRoot <- OsPath.encodeFS root
        let path = nativeRoot OsPath.</> OsPath.pack (map OsPath.unsafeFromChar units)
        NativeFile.writeFile' path "x"
        (do
            names <- NativeDirectory.listDirectory nativeRoot
            let actualUnits = sort (map (map (ord . OsPath.toChar) . OsPath.unpack) names)
            use root actualUnits)
            `finally` NativeDirectory.removeFile path

data BuildNameCapability
    = BuildNameAvailable
    | BuildNameNotWindows
    | BuildNameRefused [Int] IOException
    | BuildNameProbeFailed String

{-# NOINLINE buildNameCapability #-}
buildNameCapability :: BuildNameCapability
buildNameCapability = unsafePerformIO $
    if os /= "mingw32"
        then pure BuildNameNotWindows
        else do
            result <- try @IOException $
                withSystemTempDirectory "hostbootstrap-build-name-capability" $ \root -> do
                    nativeRoot <- OsPath.encodeFS root
                    let name units = nativeRoot OsPath.</> OsPath.pack (map OsPath.unsafeFromChar units)
                        control = name "ascii-control"
                        replacement = name ['\xfffd']
                        unpaired = name ['\xd800']
                    NativeFile.writeFile' control "x"
                    (do
                        contents <- NativeFile.readFile' control
                        unless (contents == "x") (ioError (userError "native ASCII filename control changed bytes"))
                        NativeFile.writeFile' replacement "x"
                        (do
                            created <- try @IOException (NativeFile.writeFile' unpaired "x")
                            case created of
                                Left failure
                                    | ioeGetErrorType failure == InvalidArgument ->
                                        pure (BuildNameRefused [0xd800] failure)
                                    | otherwise -> pure (BuildNameProbeFailed (show failure))
                                Right () ->
                                    (do
                                        names <- NativeDirectory.listDirectory nativeRoot
                                        let observed = sort (map (map (ord . OsPath.toChar) . OsPath.unpack) names)
                                            expected = sort [map ord "ascii-control", [0xd800], [0xfffd]]
                                        unless (observed == expected)
                                            (ioError (userError "native enumeration conflated the unpaired and replacement names"))
                                        pure BuildNameAvailable)
                                        `finally` NativeDirectory.removeFile unpaired)
                            `finally` NativeDirectory.removeFile replacement)
                        `finally` NativeDirectory.removeFile control
            pure (either (BuildNameProbeFailed . show) id result)

buildUnpairedNameSupported :: Bool
buildUnpairedNameSupported = case buildNameCapability of
    BuildNameAvailable -> True
    _ -> False

unpairedNameTests :: [TestTree]
unpairedNameTests =
    [ conditionalCase ["BuildAuthoritySpec", "Windows unpaired source names"] buildUnpairedNameSupported
        "an actual unpaired UTF-16 name differs from the replacement character" (
            withNativeSourceName ['\xd800'] $ \first firstUnits ->
                withNativeSourceName ['\xfffd'] $ \second secondUnits -> do
                    firstUnits @?= [[0xd800]]
                    secondUnits @?= [[0xfffd]]
                    assertBool "enumerated actual native names are distinct" (firstUnits /= secondUnits)
                    one <- expectIO =<< measureSourceDigest first
                    two <- expectIO =<< measureSourceDigest second
                    one @?= "b7c6df9b518e26f98f22edd7e81a6085b9dde04488b3c17b93afb43d19e4e27e"
                    two @?= "8c649f29c32a64ad84f015b4a57d4ef2caf482ea490774e80b261b9a0e8d2a72"
                    assertBool "unpaired native units are not replaced in the digest" (one /= two)
        ) $ case buildNameCapability of
            BuildNameNotWindows -> do
                assertBool "the Windows-only row was refused on Windows" (os /= "mingw32")
                withSystemTempDirectory "hostbootstrap-build-windows-refusal" $ \root -> do
                    outcome <- withOwnershipRow windowsOwnershipRow $ \primitive ->
                        rowCreateFile primitive (root </> "windows-capability-control") "x"
                    outcome @?= Left (OwnershipUnsupported
                        "the Windows ownership row needs GetFileInformationByHandle identity, LockFileEx byte-range locks, reparse-point opens, and CreateHardLinkW, none of which this host supplies")
                    doesFileExist (root </> "windows-capability-control") >>= (@?= False)
                putStrLn "Unsupported: the actual Windows capability row refuses this host; no UTF-16 source-name case ran"
            BuildNameRefused units failure -> do
                os @?= "mingw32"
                units @?= [0xd800]
                ioeGetErrorType failure @?= InvalidArgument
                putStrLn "Unsupported: the actual filesystem refused an unpaired UTF-16 filename with InvalidArgument"
            BuildNameProbeFailed reason -> assertFailure ("native filename capability probe failed: " <> reason)
            BuildNameAvailable -> assertFailure "the filesystem accepted the name but selected the refusal branch"
    ]

filesystemExceptionTests :: [TestTree]
filesystemExceptionTests =
    [ testCase "Build filesystem catches preserve asynchronous cancellation" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            description <- SourceGuard.readPackageDescription
            path <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Build"
            bytes <- ByteString.readFile path
            source <- either (assertFailure . show) (pure . Text.unpack) (TextEncoding.decodeUtf8' bytes)
            forM_ ["loadBuildKey", "measureSourceDigest", "measureBinaryDigest", "readBuildChannel"] $ \name -> do
                clauses <- either assertFailure pure (SourceGuard.haskellDefinitionClauseTokens name source)
                let tokens = concat clauses
                assertBool (name <> " does not catch IOException") ("IOException" `elem` tokens)
                assertBool (name <> " catches asynchronous exceptions") ("SomeException" `notElem` tokens)
                length (filter (== "try") tokens) @?= 1
            SourceGuard.countHaskellIdentifier "SomeException" source @?= 0
    ]

-- ---------------------------------------------------------------------------
-- Channel

channelTests :: [TestTree]
channelTests =
    [ testCase "a rendered channel round-trips" $
        withFixture $ \fixture -> do
            let path = fixtureRoot fixture </> "channel.bin"
            ByteString.writeFile path (renderBuildChannel (fixtureChannel fixture))
            decoded <- expectIO =<< readBuildChannel path
            channelBinding decoded @?= channelBinding (fixtureChannel fixture)
            buildGrantSignature (channelGrant decoded)
                @?= buildGrantSignature (channelGrant (fixtureChannel fixture))
    , testCase "malformed channel bytes have five exact decoder refusals" $
        withFixture $ \fixture -> do
            let channel = fixtureChannel fixture
                full = renderBuildChannel channel
                path = fixtureRoot fixture </> "decoder-table.bin"
                projectPrefix = frameWire (TextEncoding.encodeUtf8 (buildProjectNameText (buildProjectName (channelBinding channel))))
                cases =
                    [ ("short header", ByteString.take 3 full, "truncated channel")
                    , ("truncated field body", ByteString.pack [0, 0, 0, 0, 0, 0, 0, 2] <> "x", "truncated channel field")
                    , ("maximum Word64 length", ByteString.replicate 8 255,
                        "handoff: declared frame of 18446744073709551615 bytes exceeds the 8388608-byte limit")
                    , ("non-UTF-8 field", frameWire (ByteString.singleton 255)
                            <> ByteString.drop (ByteString.length projectPrefix) full,
                        "a channel field is not valid UTF-8")
                    , ("trailing signature bytes", full <> "xyz", "missing or malformed signature frame")
                    ]
            ByteString.writeFile path full
            accepted <- expectIO =<< readBuildChannel path
            channelBinding accepted @?= channelBinding channel
            buildGrantSignature (channelGrant accepted) @?= buildGrantSignature (channelGrant channel)
            forM_ cases $ \(label, bytes, expected) -> do
                ByteString.writeFile path bytes
                outcome <- readBuildChannel path
                let observed = () <$ outcome
                assertBool (label <> ": " <> show observed)
                    (observed == Left (BuildChannelMalformed expected))
    , testCase "an absent channel is exactly BuildChannelUnavailable" $
        withSystemTempDirectory "hostbootstrap-build" $ \directory -> do
            outcome <- readBuildChannel (directory </> "absent-channel")
            case outcome of
                Left (BuildChannelUnavailable _) -> pure ()
                other -> assertFailure ("expected an unavailable channel, got " <> show other)
    , testCase "a truncated channel is malformed, not partially accepted" $
        withFixture $ \fixture -> do
            let path = fixtureRoot fixture </> "channel.bin"
                full = renderBuildChannel (fixtureChannel fixture)
            ByteString.writeFile path (ByteString.take (ByteString.length full - 5) full)
            outcome <- readBuildChannel path
            case outcome of
                Left (BuildChannelMalformed _) -> pure ()
                other -> assertFailure ("expected a malformed channel, got " <> show other)
    ]

-- ---------------------------------------------------------------------------
-- Verification

verificationTests :: [TestTree]
verificationTests =
    [ testCase "an authenticated build yields the frame and its two phase authorities" $
        withFixture $ \fixture -> do
            verified <-
                verifyFixture fixture (fixtureChannel fixture) $ \frame authority -> do
                    imageBuildFrameName frame @?= "image-build-container-0"
                    buildAuthorityBuildId authority @?= "build-7"
                    buildAuthoritySourceDigest authority
                        @?= buildSourceDigestText (buildSourceDigest (channelBinding (fixtureChannel fixture)))
                    show frame @?= "ImageBuildFrame image-build-container-0"
                    show authority @?= "BuildInvocationAuthority build-7"
                    checkAuthority <- expectIO =<< authorizeCheckCode frame authority
                    buildAuthority <- expectIO =<< authorizeBuildPhase frame authority
                    buildCommandAuthorityPhase checkAuthority @?= CheckCodePhase
                    buildCommandAuthorityPhase buildAuthority @?= BuildPhase
                    show checkAuthority @?= "BuildCommandAuthority CheckCodePhase image-build-container-0"
                    show buildAuthority @?= "BuildCommandAuthority BuildPhase image-build-container-0"
            _ <- expectIO verified
            pure ()
    , testCase "each narrow build phase is at most once on one returned authority" $
        withFixture $ \fixture -> do
            verified <-
                verifyFixture fixture (fixtureChannel fixture) $ \frame authority -> do
                    _ <- expectIO =<< authorizeCheckCode frame authority
                    duplicate <- authorizeCheckCode frame authority
                    case duplicate of
                        Left (BuildPhaseAlreadyAuthorized CheckCodePhase) -> pure ()
                        other -> assertFailure ("expected a consumed phase, got " <> show other)
            _ <- expectIO verified
            pure ()
    , testCase "a grant for another project is refused" $
        withFixture $ \fixture -> do
            tampered <- rebind fixture (\b -> b{buildProjectName = buildProjectNameFromText "other-project"})
            outcome <- verifyFixture fixture tampered ignoreVerified
            expectMismatch "project" outcome
    , testCase "a grant naming a different config digest is refused" $
        withFixture $ \fixture -> do
            tampered <- rebind fixture (\b -> b{buildConfigDigest = buildConfigDigestFromText "0000"})
            outcome <- verifyFixture fixture tampered ignoreVerified
            expectMismatch "config digest" outcome
    , testCase "a grant naming another finalized spec is refused" $
        withFixture $ \fixture -> do
            tampered <- rebind fixture (\b -> b{buildSpecDigest = buildSpecDigestFromText "spec-other"})
            outcome <- verifyFixture fixture tampered ignoreVerified
            expectMismatch "spec digest" outcome
    , testCase "a grant naming another coordinator binary is refused" $
        withFixture $ \fixture -> do
            outcome <-
                verifyBuildInvocation
                    (fixtureKey fixture)
                    (buildProjectNameFromText (fixtureProject fixture))
                    (buildSpecDigestFromText (fixtureSpecDigest fixture))
                    (buildConfigDigestFromText (fixtureConfigDigest fixture))
                    (coordinatorDigestFromText "coordinator-other")
                    (buildSourceRootFromFilePath (fixtureSource fixture))
                    (builderPathFromFilePath (fixtureBuilder fixture))
                    (fixtureChannel fixture)
                    ignoreVerified
            expectMismatch "coordinator binary" outcome
    , testCase "a grant describing different sources is refused" $
        withFixture $ \fixture -> do
            -- The grant is genuinely signed; it simply claims a source digest
            -- that is not what the build context actually contains.
            tampered <- rebind fixture (\b -> b{buildSourceDigest = buildSourceDigestFromText "deadbeef"})
            outcome <- verifyFixture fixture tampered ignoreVerified
            expectMismatch "source digest" outcome
    , testCase "sources edited after signing are refused" $
        withFixture $ \fixture -> do
            ByteString.writeFile (fixtureSource fixture </> "src" </> "Main.hs") "main = evil"
            outcome <- verifyFixture fixture (fixtureChannel fixture) ignoreVerified
            expectMismatch "source digest" outcome
    , testCase "a grant minted for another builder cannot authorize this one" $
        withFixture $ \fixture -> do
            tampered <- rebind fixture (\b -> b{buildBuilderDigest = builderDigestFromText "not-this-builder"})
            outcome <- verifyFixture fixture tampered ignoreVerified
            expectMismatch "builder binary" outcome
    , testCase "another coordinator's key does not authenticate this grant" $
        withFixture $ \fixture -> do
            otherSigningKey <- expectIO (buildSigningKeyFromBytes otherSigningSeed)
            let path = fixtureRoot fixture </> "other.pub"
            ByteString.writeFile
                path
                (buildVerificationKeyBytes (buildSigningVerificationKey otherSigningKey))
            key <- expectIO =<< installedBuildVerificationKey path
            outcome <-
                verifyBuildInvocation
                    key
                    (buildProjectNameFromText (fixtureProject fixture))
                    (buildSpecDigestFromText (fixtureSpecDigest fixture))
                    (buildConfigDigestFromText (fixtureConfigDigest fixture))
                    (coordinatorDigestFromText (fixtureCoordinatorDigest fixture))
                    (buildSourceRootFromFilePath (fixtureSource fixture))
                    (builderPathFromFilePath (fixtureBuilder fixture))
                    (fixtureChannel fixture)
                    ignoreVerified
            case outcome of
                Left (BuildSignatureInvalid _) -> pure ()
                other -> assertFailure ("expected a signature refusal, got " <> show other)
    , testCase "a coordinator refuses to sign a binding attributed to another coordinator" $
        withFixture $ \fixture -> do
            otherSigningKey <- expectIO (buildSigningKeyFromBytes otherSigningSeed)
            withBuildCoordinator otherSigningKey (coordinatorDigestFromText "some-other-coordinator") $ \other -> do
                outcome <- signBuildGrant other (channelBinding (fixtureChannel fixture))
                outcome @?= Left (BuildIdentityMismatch "coordinator" "coordinator-digest" "some-other-coordinator")
    , testCase "the exact hostbootstrap/build/v1 domain authenticates" $
        withFixture $ \fixture -> do
            channel <- externallySignedChannel fixture "hostbootstrap/build/v1"
            outcome <- verifyFixture fixture channel ignoreVerified
            _ <- expectIO outcome
            pure ()
    , testCase "a signature under another protocol domain is refused" $
        withFixture $ \fixture -> do
            channel <- externallySignedChannel fixture "hostbootstrap/build/v0"
            outcome <- verifyFixture fixture channel ignoreVerified
            case outcome of
                Left (BuildSignatureInvalid _) -> pure ()
                other -> assertFailure ("expected a domain-separated signature refusal, got " <> show other)
    , testCase "an existentially retained coordinator expires after its callback" $ do
        signingKey <- expectIO (buildSigningKeyFromBytes fixtureSigningSeed)
        escaped <-
            withBuildCoordinator signingKey (coordinatorDigestFromText "coordinator-digest") $
                pure . EscapedBuildCoordinator
        case escaped of
            EscapedBuildCoordinator coordinator -> do
                outcome <- signBuildGrant coordinator expiryBinding
                outcome @?= Left BuildCoordinatorExpired
    , testCase "removing the builder after a valid signed setup is an exact refusal" $
        withFixture $ \fixture -> do
            accepted <- verifyFixture fixture (fixtureChannel fixture) ignoreVerified
            _ <- expectIO accepted
            removeFile (fixtureBuilder fixture)
            calls <- newIORef (0 :: Int)
            refused <- verifyFixture fixture (fixtureChannel fixture)
                (\_ _ -> modifyIORef' calls (+ 1))
            refused @?= Left (BuildBinaryUnavailable (Text.pack (fixtureBuilder fixture)))
            readIORef calls >>= (@?= 0)
    , testCase "removing the source root after a valid signed setup is an exact refusal" $
        withFixture $ \fixture -> do
            accepted <- verifyFixture fixture (fixtureChannel fixture) ignoreVerified
            _ <- expectIO accepted
            removePathForcibly (fixtureSource fixture)
            calls <- newIORef (0 :: Int)
            refused <- verifyFixture fixture (fixtureChannel fixture)
                (\_ _ -> modifyIORef' calls (+ 1))
            refused @?= Left (BuildSourceUnavailable (Text.pack (fixtureSource fixture)))
            readIORef calls >>= (@?= 0)
    , testCase "the reader accepts an empty frame name and verification refuses it exactly" $
        withFixture $ \fixture -> do
            accepted <- verifyFixture fixture (fixtureChannel fixture) ignoreVerified
            _ <- expectIO accepted
            channel <- rebind fixture (\binding -> binding{buildFrameName = buildFrameNameFromText ""})
            let path = fixtureRoot fixture </> "empty-frame-channel.bin"
            ByteString.writeFile path (renderBuildChannel channel)
            decoded <- expectIO =<< readBuildChannel path
            channelBinding decoded @?= channelBinding channel
            calls <- newIORef (0 :: Int)
            refused <- verifyFixture fixture decoded (\_ _ -> modifyIORef' calls (+ 1))
            refused @?= Left (BuildChannelMalformed "the image-build frame is empty")
            readIORef calls >>= (@?= 0)
    , testCase "a 63-byte signature reaches the verifier's exact parse refusal" $
        withFixture $ \fixture -> do
            acceptedCalls <- newIORef (0 :: Int)
            accepted <- verifyFixture fixture (fixtureChannel fixture)
                (\_ _ -> modifyIORef' acceptedCalls (+ 1))
            accepted @?= Right ()
            readIORef acceptedCalls >>= (@?= 1)
            let original = fixtureChannel fixture
                binding = channelBinding original
                signature = buildGrantSignature (channelGrant original)
                path = fixtureRoot fixture </> "signature-63-channel.bin"
            ByteString.length signature @?= 64
            ByteString.writeFile path (renderBuildBinding binding <> frameWire (ByteString.take 63 signature))
            decoded <- expectIO =<< readBuildChannel path
            channelBinding decoded @?= binding
            ByteString.length (buildGrantSignature (channelGrant decoded)) @?= 63
            calls <- newIORef (0 :: Int)
            refused <- verifyFixture fixture decoded (\_ _ -> modifyIORef' calls (+ 1))
            refused @?= Left (BuildSignatureInvalid "CryptoError_SecretKeyStructureInvalid")
            readIORef calls >>= (@?= 0)
    , testCase "the reader accepts an empty build id and verification refuses it exactly" $
        withFixture $ \fixture -> do
            _ <- expectIO =<< verifyFixture fixture (fixtureChannel fixture) ignoreVerified
            channel <- rebind fixture (\b -> b{buildIdentifier = buildIdentifierFromText ""})
            let path = fixtureRoot fixture </> "empty-id-channel.bin"
            ByteString.writeFile path (renderBuildChannel channel)
            decoded <- expectIO =<< readBuildChannel path
            channelBinding decoded @?= channelBinding channel
            calls <- newIORef (0 :: Int)
            refused <- verifyFixture fixture decoded (\_ _ -> modifyIORef' calls (+ 1))
            refused @?= Left (BuildChannelMalformed "the build id is empty")
            readIORef calls >>= (@?= 0)
    ]

expectMismatch ::
    (Show value) =>
    Text ->
    Either BuildError value ->
    IO ()
expectMismatch expected outcome = case outcome of
    Left (BuildIdentityMismatch what _ _) -> what @?= expected
    other -> assertFailure ("expected a " <> Text.unpack expected <> " mismatch, got " <> show other)

-- ---------------------------------------------------------------------------
-- Fixtures

data Fixture = Fixture
    { fixtureRoot :: FilePath
    , fixtureSource :: FilePath
    , fixtureBuilder :: FilePath
    , fixtureProject :: Text
    , fixtureSpecDigest :: Text
    , fixtureConfigDigest :: Text
    , fixtureCoordinatorDigest :: Text
    , fixtureBuilderDigest :: Text
    , fixtureKey :: BuildVerificationKey
    , fixtureChannel :: BuildChannel
    , fixtureResign :: BuildBinding -> IO BuildChannel
    }

{- | A real source tree, a real builder file, separately installed long-lived
signing/verification keys, and a genuinely signed channel describing all of
them. The verification key is derived and installed before the coordinator
bracket is created.
-}
withFixture :: (Fixture -> IO ()) -> IO ()
withFixture use =
    withSystemTempDirectory "hostbootstrap-build" $ \root -> do
        let source = root </> "context"
            builder = root </> "hostbootstrap-demo"
            signingKeyPath = root </> "coordinator.key"
            verificationKeyPath = root </> "coordinator.pub"
        writeSourceTree source
        ByteString.writeFile builder "ELF-ish builder bytes"
        ByteString.writeFile signingKeyPath fixtureSigningSeed
        sourceDigest <- expectIO =<< measureSourceDigest source
        builderDigest <- expectIO =<< measureBinaryDigest builder
        signingKey <- expectIO =<< installedBuildSigningKey signingKeyPath
        let provisionedVerificationKey = buildSigningVerificationKey signingKey
        ByteString.writeFile
            verificationKeyPath
            (buildVerificationKeyBytes provisionedVerificationKey)
        verificationKey <- expectIO =<< installedBuildVerificationKey verificationKeyPath
        let coordinatorDigest = "coordinator-digest"
            binding =
                BuildBinding
                    { buildProjectName = buildProjectNameFromText "hostbootstrap-demo"
                    , buildSpecDigest = buildSpecDigestFromText "spec-1"
                    , buildConfigDigest = buildConfigDigestFromText "config-1"
                    , buildIdentifier = buildIdentifierFromText "build-7"
                    , buildSourceDigest = buildSourceDigestFromText sourceDigest
                    , buildCoordinatorDigest = coordinatorDigestFromText coordinatorDigest
                    , buildBuilderDigest = builderDigestFromText builderDigest
                    , buildFrameName = buildFrameNameFromText "image-build-container-0"
                    }
        withBuildCoordinator signingKey (coordinatorDigestFromText coordinatorDigest) $ \coordinator -> do
            let sign b = do
                    grant <- expectIO =<< signBuildGrant coordinator b
                    pure BuildChannel{channelBinding = b, channelGrant = grant}
            channel <- sign binding
            use
                Fixture
                    { fixtureRoot = root
                    , fixtureSource = source
                    , fixtureBuilder = builder
                    , fixtureProject = "hostbootstrap-demo"
                    , fixtureSpecDigest = "spec-1"
                    , fixtureConfigDigest = "config-1"
                    , fixtureCoordinatorDigest = coordinatorDigest
                    , fixtureBuilderDigest = builderDigest
                    , fixtureKey = verificationKey
                    , fixtureChannel = channel
                    , fixtureResign = sign
                    }

{- | Re-sign a modified binding, so the tampered case is a *genuine* signature
over a false description rather than a broken signature.
-}
rebind :: Fixture -> (BuildBinding -> BuildBinding) -> IO BuildChannel
rebind fixture edit = fixtureResign fixture (edit (channelBinding (fixtureChannel fixture)))

{- | Build a channel using the fixture's provisioned seed but an independently
spelled protocol domain. This pins the public v1 signature domain rather than
merely checking that this module's signer and verifier agree with each other.
-}
externallySignedChannel :: Fixture -> ByteString -> IO BuildChannel
externallySignedChannel fixture domain = do
    secret <- case Ed25519.secretKey fixtureSigningSeed of
        CryptoFailed err -> assertFailure ("fixture signing seed was invalid: " <> show err)
        CryptoPassed value -> pure value
    let binding = channelBinding (fixtureChannel fixture)
        material = frameWire domain <> frameWire (renderBuildBinding binding)
        signature :: ByteString
        signature = convert (Ed25519.sign secret (Ed25519.toPublic secret) material)
        path = fixtureRoot fixture </> "external-channel.bin"
    ByteString.writeFile
        path
        (renderBuildBinding binding <> frameWire signature)
    expectIO =<< readBuildChannel path

data EscapedBuildCoordinator where
    EscapedBuildCoordinator :: BuildCoordinator coordinatorId -> EscapedBuildCoordinator

expiryBinding :: BuildBinding
expiryBinding =
    BuildBinding
        { buildProjectName = buildProjectNameFromText "hostbootstrap-demo"
        , buildSpecDigest = buildSpecDigestFromText "spec-1"
        , buildConfigDigest = buildConfigDigestFromText "config-1"
        , buildIdentifier = buildIdentifierFromText "build-expired"
        , buildSourceDigest = buildSourceDigestFromText "source"
        , buildCoordinatorDigest = coordinatorDigestFromText "coordinator-digest"
        , buildBuilderDigest = builderDigestFromText "builder"
        , buildFrameName = buildFrameNameFromText "image-build-container-0"
        }

fixtureSigningSeed :: ByteString
fixtureSigningSeed = ByteString.pack [0 .. 31]

otherSigningSeed :: ByteString
otherSigningSeed = ByteString.pack [32 .. 63]

verifyFixture ::
    Fixture ->
    BuildChannel ->
    ( forall projectId specDigest configId frame buildId sourceDigest builderBinaryDigest.
      ImageBuildFrame projectId specDigest configId frame ->
      BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest ->
      IO result
    ) ->
    IO (Either BuildError result)
verifyFixture fixture channel use =
    verifyBuildInvocation
        (fixtureKey fixture)
        (buildProjectNameFromText (fixtureProject fixture))
        (buildSpecDigestFromText (fixtureSpecDigest fixture))
        (buildConfigDigestFromText (fixtureConfigDigest fixture))
        (coordinatorDigestFromText (fixtureCoordinatorDigest fixture))
        (buildSourceRootFromFilePath (fixtureSource fixture))
        (builderPathFromFilePath (fixtureBuilder fixture))
        channel
        use

ignoreVerified ::
    ImageBuildFrame projectId specDigest configId frame ->
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest ->
    IO ()
ignoreVerified _ _ = pure ()

withSourceTree :: (FilePath -> IO ()) -> IO ()
withSourceTree use =
    withSystemTempDirectory "hostbootstrap-source" $ \root -> do
        writeSourceTree root
        use root

writeSourceTree :: FilePath -> IO ()
writeSourceTree root = do
    createDirectoryIfMissing True (root </> "src")
    ByteString.writeFile (root </> "project.cabal") "name: demo\n"
    ByteString.writeFile (root </> "src" </> "Main.hs") "main = pure ()\n"

expectIO :: (Show err) => Either err value -> IO value
expectIO (Right value) = pure value
expectIO (Left failure) = assertFailure ("expected success, got " <> show failure)
