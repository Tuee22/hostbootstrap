{-# LANGUAGE OverloadedStrings #-}

{- | The portable host-wall driver exercised against a real kernel.

Every case here runs the production recovery driver
('HostBootstrap.Wsl2.GlobalWall.Host') over the POSIX backend, so the phase
machine, the four ownership clauses, and the crash-resume branches are proved
on the filesystem rather than in a model.  The Windows backend supplies the
same primitives through @Win32@; its remaining obligation is the native gate,
not a second copy of this logic.
-}
module WslGlobalWallHostSpec (tests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import HostBootstrap.Wsl2.GlobalWall
import HostBootstrap.Wsl2.GlobalWall.Host
import HostBootstrap.Wsl2.GlobalWall.Posix
import Data.List (isPrefixOf, sort)
import System.Directory
  ( createDirectoryIfMissing,
    createFileLink,
    doesFileExist,
    listDirectory,
    removeFile,
  )
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

managedBody :: [ByteString]
managedBody =
  [ "[general]",
    "instanceIdleTimeout=21600000",
    "[wsl2]",
    "processors=4",
    "memory=8GB",
    "swap=8GB",
    "vmIdleTimeout=21600000"
  ]

otherManagedBody :: [ByteString]
otherManagedBody =
  [ "[general]",
    "instanceIdleTimeout=21600000",
    "[wsl2]",
    "processors=8",
    "memory=16GB",
    "swap=16GB",
    "vmIdleTimeout=21600000"
  ]

request :: ByteString -> [ByteString] -> IO CurrentUserWallRequest
request owner body =
  case mkCurrentUserWallRequest owner "spec" "reservation" "receipt" body of
    Left err -> assertFailure ("unexpected request error: " ++ show err)
    Right value -> pure value

-- | A temporary target plus its own state directory, so no case can observe
-- another case's journal.
withWall ::
  (FilePath -> HostWallBackend PosixWallHandle -> IO result) ->
  IO result
withWall consume =
  withSystemTempDirectory "hostbootstrap-host-wall" $ \directory -> do
    let target = directory </> ".wslconfig"
        state = directory </> "state"
    createDirectoryIfMissing True state
    backend <-
      newPosixHostWallBackend
        PosixWallLocation
          { posixWallTargetPath = target,
            posixWallStateDirectory = state
          }
    consume target backend

expectRight :: (Show err) => String -> Either err value -> IO value
expectRight label = either (assertFailure . ((label ++ ": ") ++) . show) pure

tests :: TestTree
tests =
  testGroup
    "WslGlobalWallHostSpec"
    [ testGroup "apply over an absent origin" absentOriginCases,
      testGroup "apply over a present origin" presentOriginCases,
      testGroup "ownership refusals" refusalCases,
      testGroup "crash resume" resumeCases,
      testGroup "the durable record codec" codecCases,
      testGroup "the Windows production entry points" windowsEntryCases
    ]

absentOriginCases :: [TestTree]
absentOriginCases =
  [ testCase "publishes the managed body and restores absence" $
      withWall $ \target backend -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall backend wall >>= expectRight "apply"
        persistedWallPhase (appliedWslConfigRecord applied) @?= WallApplied
        published <- ByteString.readFile target
        assertBool
          "the published file contains the managed processors line"
          ("processors=4" `ByteString.isInfixOf` published)
        assertBool
          "the published file contains the managed idle timeout"
          ("vmIdleTimeout=21600000" `ByteString.isInfixOf` published)

        restored <- restoreGlobalWall backend wall
        _ <- expectRight "restore" restored
        exists <- doesFileExist target
        exists @?= False,
    testCase "leaves no recovery names or journal behind" $
      withWall $ \target backend -> do
        wall <- request "owner" managedBody
        _ <- applyGlobalWall backend wall >>= expectRight "apply"
        _ <- restoreGlobalWall backend wall >>= expectRight "restore"
        residue <- targetSiblings target
        residue @?= []

        second <- restoreGlobalWall backend wall
        case second of
          Left HostWallNoActiveRecord -> pure ()
          other ->
            assertFailure
              ("expected a cleared journal, got " ++ show other),
    testCase "a second apply is an idempotent no-op" $
      withWall $ \target backend -> do
        wall <- request "owner" managedBody
        first <- applyGlobalWall backend wall >>= expectRight "apply"
        afterFirst <- ByteString.readFile target
        second <- applyGlobalWall backend wall >>= expectRight "re-apply"
        afterSecond <- ByteString.readFile target
        afterSecond @?= afterFirst
        persistedFenceValue (appliedWslConfigRecord second)
          @?= persistedFenceValue (appliedWslConfigRecord first)
        _ <- restoreGlobalWall backend wall >>= expectRight "restore"
        pure (),
    testCase "each acquisition consumes a strictly newer fence" $
      withWall $ \_ backend -> do
        wall <- request "owner" managedBody
        first <- applyGlobalWall backend wall >>= expectRight "apply"
        _ <- restoreGlobalWall backend wall >>= expectRight "restore"
        second <- applyGlobalWall backend wall >>= expectRight "re-apply"
        assertBool
          "the second acquisition allocated a strictly newer fence"
          ( persistedFenceValue (appliedWslConfigRecord second)
              > persistedFenceValue (appliedWslConfigRecord first)
          )
        _ <- restoreGlobalWall backend wall >>= expectRight "final restore"
        pure (),
    testCase "clause 1 serialises two concurrent entries" $
      withWall $ \_ backend -> do
        started <- newEmptyMVar
        finished <- newEmptyMVar
        void . forkIO $ do
          outcome <-
            wallWithExclusiveEntry backend $ do
              putMVar started ()
              threadDelay 200000
              pure (Right (1 :: Int))
          putMVar finished outcome
        takeMVar started
        inner <-
          wallWithExclusiveEntry backend (pure (Right (2 :: Int)))
        outer <- takeMVar finished
        outer @?= Right 1
        inner @?= Right 2
  ]

presentOriginCases :: [TestTree]
presentOriginCases =
  [ testCase "retains and republishes the exact original bytes" $
      withWall $ \target backend -> do
        let original = "# operator settings\n[wsl2]\nkernel=C:\\\\custom\n"
        ByteString.writeFile target original
        wall <- request "owner" managedBody
        _ <- applyGlobalWall backend wall >>= expectRight "apply"
        managed <- ByteString.readFile target
        assertBool
          "the managed file still carries the operator's unrelated key"
          ("kernel=C:\\\\custom" `ByteString.isInfixOf` managed)
        assertBool
          "the managed file carries the cordon"
          ("memory=8GB" `ByteString.isInfixOf` managed)

        _ <- restoreGlobalWall backend wall >>= expectRight "restore"
        recovered <- ByteString.readFile target
        recovered @?= original
        residue <- targetSiblings target
        residue @?= [],
    testCase "an empty original file is restored as an empty file" $
      withWall $ \target backend -> do
        ByteString.writeFile target ByteString.empty
        wall <- request "owner" managedBody
        _ <- applyGlobalWall backend wall >>= expectRight "apply"
        _ <- restoreGlobalWall backend wall >>= expectRight "restore"
        exists <- doesFileExist target
        exists @?= True
        recovered <- ByteString.readFile target
        recovered @?= ByteString.empty,
    testCase "a symbolic-link target is refused rather than followed" $
      withWall $ \target backend -> do
        ByteString.writeFile (target ++ ".real") "operator bytes\n"
        createFileLink (target ++ ".real") target
        wall <- request "owner" managedBody
        result <- applyGlobalWall backend wall
        case result of
          Left (HostWallUnsupported _) -> pure ()
          other ->
            assertFailure
              ("expected an Unsupported symlink refusal, got " ++ show other)
        followed <- ByteString.readFile (target ++ ".real")
        followed @?= "operator bytes\n"
  ]

refusalCases :: [TestTree]
refusalCases =
  [ testCase "a foreign owner cannot take over an active wall" $
      withWall $ \_ backend -> do
        mine <- request "owner" managedBody
        theirs <- request "other-owner" managedBody
        _ <- applyGlobalWall backend mine >>= expectRight "apply"
        result <- applyGlobalWall backend theirs
        case result of
          Left (HostWallConflict (ForeignWallOwner _ _)) -> pure ()
          other ->
            assertFailure
              ("expected a foreign-owner conflict, got " ++ show other)
        _ <- restoreGlobalWall backend mine >>= expectRight "restore"
        pure (),
    testCase "an incompatible declaration refuses rather than overwrites" $
      withWall $ \target backend -> do
        small <- request "owner" managedBody
        large <- request "owner" otherManagedBody
        _ <- applyGlobalWall backend small >>= expectRight "apply"
        before <- ByteString.readFile target
        result <- applyGlobalWall backend large
        case result of
          Left (HostWallConflict (IncompatibleWallSpec _ _)) -> pure ()
          other ->
            assertFailure
              ("expected an incompatible-spec conflict, got " ++ show other)
        after <- ByteString.readFile target
        after @?= before
        _ <- restoreGlobalWall backend small >>= expectRight "restore"
        pure (),
    testCase "restore without an active record is a structured refusal" $
      withWall $ \_ backend -> do
        wall <- request "owner" managedBody
        result <- restoreGlobalWall backend wall
        case result of
          Left HostWallNoActiveRecord -> pure ()
          other ->
            assertFailure
              ("expected HostWallNoActiveRecord, got " ++ show other),
    testCase "clause 4 refuses to delete a replaced managed target" $
      withWall $ \target backend -> do
        wall <- request "owner" managedBody
        _ <- applyGlobalWall backend wall >>= expectRight "apply"
        -- Same privilege, different object: the pathname is identical but the
        -- kernel identity is not the one the receipt binds.
        removeFile target
        ByteString.writeFile target "foreign replacement\n"
        result <- restoreGlobalWall backend wall
        case result of
          Left (HostWallConflict _) -> pure ()
          other ->
            assertFailure
              ("expected an identity conflict, got " ++ show other)
        survived <- ByteString.readFile target
        survived @?= "foreign replacement\n"
  ]

resumeCases :: [TestTree]
resumeCases =
  [ testCase "an interrupted publication converges on the next apply" $
      withWall $ \target backend -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall backend wall >>= expectRight "apply"
        let record = appliedWslConfigRecord applied
        -- Rewind the journal to the phase written immediately before the
        -- publication call, exactly as a crash there would leave it.
        rewindJournal backend record {persistedWallPhase = WallApplyOutcomeUnknown}
        resumed <- applyGlobalWall backend wall >>= expectRight "resume"
        persistedWallPhase (appliedWslConfigRecord resumed) @?= WallApplied
        published <- ByteString.readFile target
        assertBool
          "the resumed wall still carries the managed body"
          ("processors=4" `ByteString.isInfixOf` published)
        _ <- restoreGlobalWall backend wall >>= expectRight "restore"
        pure (),
    testCase "an interrupted restore converges on the next restore" $
      withWall $ \target backend -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall backend wall >>= expectRight "apply"
        let record = appliedWslConfigRecord applied
        rewindJournal
          backend
          record {persistedWallPhase = WallRestoreOutcomeUnknown}
        _ <- restoreGlobalWall backend wall >>= expectRight "resume restore"
        exists <- doesFileExist target
        exists @?= False
        residue <- targetSiblings target
        residue @?= [],
    testCase "a durable armed leftover is reclaimed, never published" $
      withWall $ \target backend -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall backend wall >>= expectRight "apply"
        let record = appliedWslConfigRecord applied
            fence = show (persistedFenceValue record)
            armed = target ++ ".hostbootstrap." ++ fence ++ ".stage.armed"
        _ <- restoreGlobalWall backend wall >>= expectRight "restore"

        -- Re-enter the stage phase with a stale armed object present. The
        -- POSIX armed link is durable, so this is our own interrupted attempt;
        -- its unknown bytes must be discarded rather than published.
        ByteString.writeFile armed "stale attempt bytes\n"
        rewindJournal
          backend
          record
            { persistedWallPhase = WallStageCreateOutcomeUnknown,
              persistedTargetIdentity = Nothing
            }
        resumed <- applyGlobalWall backend wall >>= expectRight "resume stage"
        persistedWallPhase (appliedWslConfigRecord resumed) @?= WallApplied
        published <- ByteString.readFile target
        assertBool
          "the stale armed bytes were never published"
          (not ("stale attempt bytes" `ByteString.isInfixOf` published))
        _ <- restoreGlobalWall backend wall >>= expectRight "final restore"
        pure ()
  ]

codecCases :: [TestTree]
codecCases =
  [ testCase "the durable record round-trips" $
      withWall $ \_ backend -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall backend wall >>= expectRight "apply"
        let record = appliedWslConfigRecord applied
        decoded <-
          expectRight "decode" (decodeWallRecord (encodeWallRecord record))
        decoded @?= record
        _ <- restoreGlobalWall backend wall >>= expectRight "restore"
        pure (),
    testCase "an unknown format is refused" $
      case decodeWallRecord "HBWSLXXX" of
        Left (HostWallJournalFailure _) -> pure ()
        other ->
          assertFailure ("expected a journal failure, got " ++ show other),
    testCase "trailing bytes are refused" $
      withWall $ \_ backend -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall backend wall >>= expectRight "apply"
        let encoded =
              encodeWallRecord (appliedWslConfigRecord applied)
                <> "trailing"
        case decodeWallRecord encoded of
          Left (HostWallJournalFailure _) -> pure ()
          other ->
            assertFailure ("expected a journal failure, got " ++ show other)
        _ <- restoreGlobalWall backend wall >>= expectRight "restore"
        pure ()
  ]

windowsEntryCases :: [TestTree]
windowsEntryCases =
  [ testCase "an invalid managed body is a structured configuration error" $
      case
        mkCurrentUserWallRequest
          "owner"
          "spec"
          "reservation"
          "receipt"
          (managedBody ++ ["processors=8"])
        of
        Left (HostWallConfigurationFailure _) -> pure ()
        other ->
          assertFailure
            ("expected a structured configuration failure, got " ++ show other),
    testCase "an empty identity is refused before any effect" $
      case mkCurrentUserWallRequest "" "spec" "reservation" "receipt" managedBody of
        Left (HostWallModelFailure (InvalidWallIdentity _)) -> pure ()
        other ->
          assertFailure
            ("expected an invalid-identity refusal, got " ++ show other)
  ]

-- | Overwrite the journal with a hand-built record so a crash-resume branch can
-- be entered deterministically. This is a test seam over the same durable
-- encoding the backend writes; the driver reads it exactly as it would after a
-- real interruption.
rewindJournal ::
  HostWallBackend handle ->
  PersistedWallRecord ->
  IO ()
rewindJournal backend record = do
  stored <-
    wallWithExclusiveEntry backend $
      wallJournalStore backend (encodeWallRecord record)
  void (expectRight "rewind journal" stored)

-- | Every recovery name the adapter can leave beside the target.
targetSiblings :: FilePath -> IO [FilePath]
targetSiblings target = do
  entries <- listDirectory (takeDirectory target)
  pure (sort (filter (".wslconfig.hostbootstrap." `isPrefixOf`) entries))
