{-# LANGUAGE OverloadedStrings #-}

{- | Native Windows coverage for the public WSL global-wall entry points.

The portable driver and its crash-resume matrix run through
"WslGlobalWallHostSpec" over the host's ownership row. These cases exercise the production
Win32 backend against a temporary @USERPROFILE@ so the native identity,
hard-link, rename, journal, and conditional-release operations run without
touching the operator's real @.wslconfig@.

The Windows row is a platform row, so this module compiles on every gate host
(§ JJ). On a host that cannot hold the row, each case stays and asserts the
total refusal the row declares, and the first case asserts that the row's own
declaration agrees with the gate host it is running on. The family is therefore
the same size everywhere, which is what "CoverageManifest" checks.
-}
module WslGlobalWallWindowsSpec (tests) where

import ConditionalCase (conditionalCase)
import Control.Exception (bracket)
import qualified Data.ByteString as ByteString
import Expect (expectRightLabelled)
import HostBootstrap.Ownership.Object (ObjectIdentity)
import HostBootstrap.Ownership.Primitive (rowLinkNoReplace, rowObserveIdentity, withOwnershipRow)
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Wsl2.GlobalWall
import HostBootstrap.Wsl2.GlobalWall.ConfigBytes (mergeManagedWslConfig, mkManagedWslConfigSpec)
import HostBootstrap.Wsl2.GlobalWall.Host
import HostBootstrap.Wsl2.GlobalWall.Windows
import System.Directory (doesFileExist, removeFile)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Info (os)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

managedBody :: [ByteString.ByteString]
managedBody =
    [ "[general]"
    , "instanceIdleTimeout=21600000"
    , "[wsl2]"
    , "processors=4"
    , "memory=8GB"
    , "swap=8GB"
    , "vmIdleTimeout=21600000"
    ]

request :: IO CurrentUserWallRequest
request =
    case mkCurrentUserWallRequest "owner" "spec" "reservation" "receipt" managedBody of
        Left err -> assertFailure ("unexpected request error: " ++ show err)
        Right value -> pure value

withTemporaryProfile :: (FilePath -> IO result) -> IO result
withTemporaryProfile consume =
    withSystemTempDirectory "hostbootstrap-windows-wall" $ \profile ->
        bracket
            (lookupEnv "USERPROFILE")
            (restoreEnvironment "USERPROFILE")
            (\_ -> setEnv "USERPROFILE" profile >> consume profile)

restoreEnvironment :: String -> Maybe String -> IO ()
restoreEnvironment name Nothing = unsetEnv name
restoreEnvironment name (Just value) = setEnv name value

{- | One case that drives the Win32 row against the kernel.

On a native Windows gate host the body runs, so the case is evidence about the
real by-handle identity, hard link, rename, and conditional release. Elsewhere
the case stays and asserts the refusal the row declares.
-}
rowCase :: TestName -> (FilePath -> IO ()) -> TestTree
rowCase name body =
    conditionalCase
        ["WslGlobalWallWindowsSpec"]
        windowsGlobalWallSupported
        name
        (withTemporaryProfile body)
        (withTemporaryProfile (const expectRowRefusal))

{- | The disposition the Win32 row owes a caller on a host that is not Windows.

Both production entry points are asked, because a row that refused only one of
them would be a row that half exists.
-}
expectRowRefusal :: IO ()
expectRowRefusal = do
    wall <- request
    applied <- applyCurrentUserGlobalWall wall
    case applied of
        Left (HostWallUnsupported _) -> pure ()
        other ->
            assertFailure
                ("expected the Windows row to refuse this apply, got " ++ show other)
    restored <- restoreCurrentUserGlobalWall wall
    case restored of
        Left (HostWallUnsupported _) -> pure ()
        other ->
            assertFailure
                ("expected the Windows row to refuse this restore, got " ++ show other)

tests :: TestTree
tests =
    testGroup
        "WslGlobalWallWindowsSpec"
        [ testCase "the row's own declaration agrees with the gate host" $
            windowsGlobalWallSupported @?= (os == "mingw32")
        , rowCase "an absent origin is published and restored to absence" $
            \profile -> do
                wall <- request
                applied <- applyCurrentUserGlobalWall wall >>= expectRightLabelled "apply"
                persistedWallPhase (appliedWslConfigRecord applied) @?= WallApplied
                let target = profile </> ".wslconfig"
                published <- ByteString.readFile target
                spec <- expectRightLabelled "managed spec" (mkManagedWslConfigSpec managedBody)
                expected <- expectRightLabelled "exact merge" (mergeManagedWslConfig ByteString.empty spec)
                published @?= expected
                _ <- restoreCurrentUserGlobalWall wall >>= expectRightLabelled "restore"
                doesFileExist target >>= (@?= False)
                restoredAgain <- restoreCurrentUserGlobalWall wall
                restoredAgain @?= Left HostWallNoActiveRecord
        , rowCase "a present origin is restored byte-for-byte" $ \profile -> do
            let target = profile </> ".wslconfig"
                original = "# operator bytes\r\n[wsl2]\r\nkernel=C:\\\\custom\r\n"
            ByteString.writeFile target original
            originalIdentity <- observeIdentity target
            wall <- request
            _ <- applyCurrentUserGlobalWall wall >>= expectRightLabelled "apply"
            published <- ByteString.readFile target
            assertBool "apply changed the target bytes" (published /= original)
            _ <- restoreCurrentUserGlobalWall wall >>= expectRightLabelled "restore"
            ByteString.readFile target >>= (@?= original)
            restoredIdentity <- observeIdentity target
            restoredIdentity @?= originalIdentity
        , rowCase "a replacement is refused and preserved" $ \profile -> do
            let target = profile </> ".wslconfig"
                retained = profile </> "published-original"
            wall <- request
            _ <- applyCurrentUserGlobalWall wall >>= expectRightLabelled "apply"
            replacement <- ByteString.readFile target
            linked <- withOwnershipRow ownershipRowForHost (\primitives -> rowLinkNoReplace primitives target retained)
            _ <- expectRightLabelled "retain the original live identity" linked
            removeFile target
            ByteString.writeFile target replacement
            restored <- restoreCurrentUserGlobalWall wall
            case restored of
                Left (HostWallConflict (TargetReplaced _ _)) -> pure ()
                other ->
                    assertFailure
                        ("expected an identity conflict, got " ++ show other)
            ByteString.readFile target >>= (@?= replacement)
        , profileRefusalCase "an unset USERPROFILE refuses both entry points" Nothing
        , profileRefusalCase "an empty USERPROFILE refuses both entry points" (Just "")
        , profileRefusalCase "a relative USERPROFILE refuses both entry points" (Just "relative-profile")
        ]

profileRefusalCase :: TestName -> Maybe String -> TestTree
profileRefusalCase name profile =
    rowCase name $ \_ ->
        bracket
            (lookupEnv "USERPROFILE")
            (restoreEnvironment "USERPROFILE")
            (\_ -> restoreEnvironment "USERPROFILE" profile >> expectRowRefusal)

observeIdentity :: FilePath -> IO ObjectIdentity
observeIdentity target = do
    observed <- withOwnershipRow ownershipRowForHost (\primitives -> rowObserveIdentity primitives target)
    case observed of
        Right (Just identity) -> pure identity
        other -> assertFailure ("expected a native file identity, got " <> show other)
