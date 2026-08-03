{-# LANGUAGE OverloadedStrings #-}

{- | Native Windows coverage for the public WSL global-wall entry points.

The portable driver and its crash-resume matrix run through
"WslGlobalWallHostSpec" on POSIX. These cases exercise the production Win32
backend against a temporary @USERPROFILE@ so the native identity, hard-link,
rename, journal, and conditional-release operations run without touching the
operator's real @.wslconfig@.
-}
module WslGlobalWallWindowsSpec (tests) where

import Control.Exception (bracket)
import qualified Data.ByteString as ByteString
import HostBootstrap.Wsl2.GlobalWall
import HostBootstrap.Wsl2.GlobalWall.Host
import HostBootstrap.Wsl2.GlobalWall.Windows
import System.Directory (doesFileExist, removeFile)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

managedBody :: [ByteString.ByteString]
managedBody =
  [ "[general]",
    "instanceIdleTimeout=21600000",
    "[wsl2]",
    "processors=4",
    "memory=8GB",
    "swap=8GB",
    "vmIdleTimeout=21600000"
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

expectRight :: (Show err) => String -> Either err value -> IO value
expectRight label = either (assertFailure . ((label ++ ": ") ++) . show) pure

tests :: TestTree
tests =
  testGroup
    "WslGlobalWallWindowsSpec"
    [ testCase "the native backend is selected" $
        windowsGlobalWallSupported @?= True,
      testCase "an absent origin is published and restored to absence" $
        withTemporaryProfile $ \profile -> do
          wall <- request
          applied <- applyCurrentUserGlobalWall wall >>= expectRight "apply"
          persistedWallPhase (appliedWslConfigRecord applied) @?= WallApplied
          let target = profile </> ".wslconfig"
          published <- ByteString.readFile target
          assertBool
            "the native publication contains the managed memory wall"
            ("memory=8GB" `ByteString.isInfixOf` published)
          _ <- restoreCurrentUserGlobalWall wall >>= expectRight "restore"
          doesFileExist target >>= (@?= False)
          doesFileExist (profile </> ".hostbootstrap" </> "global-wall.record")
            >>= (@?= False),
      testCase "a present origin is restored byte-for-byte" $
        withTemporaryProfile $ \profile -> do
          let target = profile </> ".wslconfig"
              original = "# operator bytes\r\n[wsl2]\r\nkernel=C:\\\\custom\r\n"
          ByteString.writeFile target original
          wall <- request
          _ <- applyCurrentUserGlobalWall wall >>= expectRight "apply"
          _ <- restoreCurrentUserGlobalWall wall >>= expectRight "restore"
          ByteString.readFile target >>= (@?= original),
      testCase "a replacement is refused and preserved" $
        withTemporaryProfile $ \profile -> do
          let target = profile </> ".wslconfig"
              replacement = "foreign replacement\r\n"
          wall <- request
          _ <- applyCurrentUserGlobalWall wall >>= expectRight "apply"
          removeFile target
          ByteString.writeFile target replacement
          restored <- restoreCurrentUserGlobalWall wall
          case restored of
            Left (HostWallConflict _) -> pure ()
            other ->
              assertFailure
                ("expected an identity conflict, got " ++ show other)
          ByteString.readFile target >>= (@?= replacement)
    ]
