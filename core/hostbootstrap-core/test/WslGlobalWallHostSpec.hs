{-# LANGUAGE OverloadedStrings #-}

{- | The portable host-wall driver exercised against a real kernel.

Every case here runs the production recovery driver
('HostBootstrap.Wsl2.GlobalWall.Host') against the production ownership row
'ownershipRowForHost' selects and a real protected store, so the phase machine,
the four ownership clauses, and the crash-resume branches are proved on the
filesystem rather than in a model — and on whichever kernel the gate host runs,
rather than on a POSIX-only lane.

The row is a platform row, and the module compiles on every gate host (§ JJ).
On a host that cannot hold the row's clauses, a case does not disappear: it
stays, and what it asserts becomes the refusal the row declares.  That keeps
each family the same size everywhere, which is what "CoverageManifest" checks —
a family that quietly shrank on one host would still report a green total, and
the number would read the same.
-}
module WslGlobalWallHostSpec (tests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import HostBootstrap.Ownership.Row (hostOwnershipSupported, ownershipRowForHost)
import HostBootstrap.Protected
  ( Expectation (ExpectAbsent, ExpectVersion),
    ProtectedRecord (protectedRecordVersion),
    compareAndSwapProtectedRecord,
    readProtectedRecord,
    withProtectedEntry,
  )
import HostBootstrap.Wsl2.GlobalWall
import HostBootstrap.Wsl2.GlobalWall.Host
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
import Test.Tasty (TestName, TestTree, testGroup)
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

-- | A temporary target plus its own protected store, so no case can observe
-- another case's durable records.
withWall ::
  (FilePath -> HostWallLocation -> IO result) ->
  IO result
withWall consume =
  withSystemTempDirectory "hostbootstrap-host-wall" $ \directory -> do
    let target = directory </> ".wslconfig"
        state = directory </> "state"
    createDirectoryIfMissing True state
    opened <- openHostWallLocation target state
    location <- expectRight "open the wall location" opened
    consume target location

expectRight :: (Show err) => String -> Either err value -> IO value
expectRight label = either (assertFailure . ((label ++ ": ") ++) . show) pure

{- | One case that drives the POSIX row against the kernel.

On a gate host that can hold the row's clauses the body runs and the case is
evidence about the real syscalls (§ NN).  On one that cannot, the case is still
here and still runs; what it asserts is the total refusal the row declares, so
the family's size is a property of the suite rather than of the host.
-}
rowCase :: TestName -> (FilePath -> HostWallLocation -> IO ()) -> TestTree
rowCase name body =
  testCase name $
    withWall $ \target location ->
      if hostOwnershipSupported
        then body target location
        else expectRowRefusal location

{- | The disposition a row that cannot hold its clauses owes every caller.

Both production entry points are asked, because a row that refused only one of
them would be a row that half exists.
-}
expectRowRefusal :: HostWallLocation -> IO ()
expectRowRefusal location = do
  wall <- request "owner" managedBody
  applied <- applyGlobalWall ownershipRowForHost location wall
  case applied of
    Left (HostWallUnsupported _) -> pure ()
    other ->
      assertFailure
        ("expected this host's row to refuse this apply, got " ++ show other)
  restored <- restoreGlobalWall ownershipRowForHost location wall
  case restored of
    Left (HostWallUnsupported _) -> pure ()
    other ->
      assertFailure
        ("expected this host's row to refuse this restore, got " ++ show other)

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
  [ rowCase "publishes the managed body and restores absence" $ \target location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "apply"
        persistedWallPhase (appliedWslConfigRecord applied) @?= WallApplied
        published <- ByteString.readFile target
        assertBool
          "the published file contains the managed processors line"
          ("processors=4" `ByteString.isInfixOf` published)
        assertBool
          "the published file contains the managed idle timeout"
          ("vmIdleTimeout=21600000" `ByteString.isInfixOf` published)

        restored <- restoreGlobalWall ownershipRowForHost location wall
        _ <- expectRight "restore" restored
        exists <- doesFileExist target
        exists @?= False,
    rowCase "leaves no recovery names or journal behind" $ \target location -> do
        wall <- request "owner" managedBody
        _ <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "apply"
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRight "restore"
        residue <- targetSiblings target
        residue @?= []

        second <- restoreGlobalWall ownershipRowForHost location wall
        case second of
          Left HostWallNoActiveRecord -> pure ()
          other ->
            assertFailure
              ("expected a cleared journal, got " ++ show other),
    rowCase "a second apply is an idempotent no-op" $ \target location -> do
        wall <- request "owner" managedBody
        first <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "apply"
        afterFirst <- ByteString.readFile target
        second <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "re-apply"
        afterSecond <- ByteString.readFile target
        afterSecond @?= afterFirst
        persistedFenceValue (appliedWslConfigRecord second)
          @?= persistedFenceValue (appliedWslConfigRecord first)
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRight "restore"
        pure (),
    rowCase "each acquisition consumes a strictly newer fence" $ \_ location -> do
        wall <- request "owner" managedBody
        first <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "apply"
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRight "restore"
        second <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "re-apply"
        assertBool
          "the second acquisition allocated a strictly newer fence"
          ( persistedFenceValue (appliedWslConfigRecord second)
              > persistedFenceValue (appliedWslConfigRecord first)
          )
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRight "final restore"
        pure (),
    rowCase "clause 1 serialises two concurrent entries" $ \_ location -> do
        started <- newEmptyMVar
        finished <- newEmptyMVar
        let store = hostWallProtectedStore location
        void . forkIO $ do
          outcome <-
            withProtectedEntry store $ \_ -> do
              putMVar started ()
              threadDelay 200000
              pure (Right (1 :: Int))
          putMVar finished outcome
        takeMVar started
        inner <- withProtectedEntry store (\_ -> pure (Right (2 :: Int)))
        outer <- takeMVar finished
        outer @?= Right 1
        inner @?= Right 2
  ]

presentOriginCases :: [TestTree]
presentOriginCases =
  [ rowCase "retains and republishes the exact original bytes" $ \target location -> do
        let original = "# operator settings\n[wsl2]\nkernel=C:\\\\custom\n"
        ByteString.writeFile target original
        wall <- request "owner" managedBody
        _ <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "apply"
        managed <- ByteString.readFile target
        assertBool
          "the managed file still carries the operator's unrelated key"
          ("kernel=C:\\\\custom" `ByteString.isInfixOf` managed)
        assertBool
          "the managed file carries the cordon"
          ("memory=8GB" `ByteString.isInfixOf` managed)

        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRight "restore"
        recovered <- ByteString.readFile target
        recovered @?= original
        residue <- targetSiblings target
        residue @?= [],
    rowCase "an empty original file is restored as an empty file" $ \target location -> do
        ByteString.writeFile target ByteString.empty
        wall <- request "owner" managedBody
        _ <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "apply"
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRight "restore"
        exists <- doesFileExist target
        exists @?= True
        recovered <- ByteString.readFile target
        recovered @?= ByteString.empty,
    rowCase "a symbolic-link target is refused rather than followed" $ \target location -> do
        ByteString.writeFile (target ++ ".real") "operator bytes\n"
        createFileLink (target ++ ".real") target
        wall <- request "owner" managedBody
        result <- applyGlobalWall ownershipRowForHost location wall
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
  [ rowCase "a foreign owner cannot take over an active wall" $ \_ location -> do
        mine <- request "owner" managedBody
        theirs <- request "other-owner" managedBody
        _ <- applyGlobalWall ownershipRowForHost location mine >>= expectRight "apply"
        result <- applyGlobalWall ownershipRowForHost location theirs
        case result of
          Left (HostWallConflict (ForeignWallOwner _ _)) -> pure ()
          other ->
            assertFailure
              ("expected a foreign-owner conflict, got " ++ show other)
        _ <- restoreGlobalWall ownershipRowForHost location mine >>= expectRight "restore"
        pure (),
    rowCase "an incompatible declaration refuses rather than overwrites" $ \target location -> do
        small <- request "owner" managedBody
        large <- request "owner" otherManagedBody
        _ <- applyGlobalWall ownershipRowForHost location small >>= expectRight "apply"
        before <- ByteString.readFile target
        result <- applyGlobalWall ownershipRowForHost location large
        case result of
          Left (HostWallConflict (IncompatibleWallSpec _ _)) -> pure ()
          other ->
            assertFailure
              ("expected an incompatible-spec conflict, got " ++ show other)
        after <- ByteString.readFile target
        after @?= before
        _ <- restoreGlobalWall ownershipRowForHost location small >>= expectRight "restore"
        pure (),
    rowCase "restore without an active record is a structured refusal" $ \_ location -> do
        wall <- request "owner" managedBody
        result <- restoreGlobalWall ownershipRowForHost location wall
        case result of
          Left HostWallNoActiveRecord -> pure ()
          other ->
            assertFailure
              ("expected HostWallNoActiveRecord, got " ++ show other),
    rowCase "clause 4 refuses to delete a replaced managed target" $ \target location -> do
        wall <- request "owner" managedBody
        _ <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "apply"
        -- Same privilege, different object: the pathname is identical but the
        -- kernel identity is not the one the receipt binds.
        removeFile target
        ByteString.writeFile target "foreign replacement\n"
        result <- restoreGlobalWall ownershipRowForHost location wall
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
  [ rowCase "an interrupted publication converges on the next apply" $ \target location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "apply"
        let record = appliedWslConfigRecord applied
        -- Rewind the journal to the phase written immediately before the
        -- publication call, exactly as a crash there would leave it.
        rewindJournal location record {persistedWallPhase = WallApplyOutcomeUnknown}
        resumed <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "resume"
        persistedWallPhase (appliedWslConfigRecord resumed) @?= WallApplied
        published <- ByteString.readFile target
        assertBool
          "the resumed wall still carries the managed body"
          ("processors=4" `ByteString.isInfixOf` published)
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRight "restore"
        pure (),
    rowCase "an interrupted restore converges on the next restore" $ \target location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "apply"
        let record = appliedWslConfigRecord applied
        rewindJournal
          location
          record {persistedWallPhase = WallRestoreOutcomeUnknown}
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRight "resume restore"
        exists <- doesFileExist target
        exists @?= False
        residue <- targetSiblings target
        residue @?= [],
    rowCase "a durable armed leftover is reclaimed, never published" $ \target location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "apply"
        let record = appliedWslConfigRecord applied
            fence = show (persistedFenceValue record)
            armed = target ++ ".hostbootstrap." ++ fence ++ ".stage.armed"
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRight "restore"

        -- Re-enter the stage phase with a stale armed object present. The
        -- POSIX armed link is durable, so this is our own interrupted attempt;
        -- its unknown bytes must be discarded rather than published.
        ByteString.writeFile armed "stale attempt bytes\n"
        rewindJournal
          location
          record
            { persistedWallPhase = WallStageCreateOutcomeUnknown,
              persistedTargetIdentity = Nothing
            }
        resumed <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "resume stage"
        persistedWallPhase (appliedWslConfigRecord resumed) @?= WallApplied
        published <- ByteString.readFile target
        assertBool
          "the stale armed bytes were never published"
          (not ("stale attempt bytes" `ByteString.isInfixOf` published))
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRight "final restore"
        pure ()
  ]

codecCases :: [TestTree]
codecCases =
  [ rowCase "the durable record round-trips" $ \_ location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "apply"
        let record = appliedWslConfigRecord applied
        decoded <-
          expectRight "decode" (decodeWallRecord (encodeWallRecord record))
        decoded @?= record
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRight "restore"
        pure (),
    testCase "an unknown format is refused" $
      case decodeWallRecord "HBWSLXXX" of
        Left (HostWallJournalFailure _) -> pure ()
        other ->
          assertFailure ("expected a journal failure, got " ++ show other),
    rowCase "trailing bytes are refused" $ \_ location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRight "apply"
        let encoded =
              encodeWallRecord (appliedWslConfigRecord applied)
                <> "trailing"
        case decodeWallRecord encoded of
          Left (HostWallJournalFailure _) -> pure ()
          other ->
            assertFailure ("expected a journal failure, got " ++ show other)
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRight "restore"
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

{- | Publish a hand-built active record so a crash-resume branch is entered
deterministically.

The durable state an interruption leaves is a value, so the fixture writes that
value through the wall's own protected store and re-enters the ordinary entry
point.  Nothing in the driver cooperates: there is no crash point, no injected
seam, and no branch that exists for a test (§ NN).
-}
rewindJournal :: HostWallLocation -> PersistedWallRecord -> IO ()
rewindJournal location record = do
  let store = hostWallProtectedStore location
      key = hostWallActiveRecordKey location
  stored <-
    withProtectedEntry store $ \session -> do
      current <- readProtectedRecord session key
      case current of
        Left failure -> pure (Left failure)
        Right observed ->
          fmap
            (fmap (const ()))
            ( compareAndSwapProtectedRecord
                session
                key
                (maybe ExpectAbsent (ExpectVersion . protectedRecordVersion) observed)
                (encodeWallRecord record)
            )
  void (expectRight "rewind journal" stored)

-- | Every recovery name the adapter can leave beside the target.
targetSiblings :: FilePath -> IO [FilePath]
targetSiblings target = do
  entries <- listDirectory (takeDirectory target)
  pure (sort (filter (".wslconfig.hostbootstrap." `isPrefixOf`) entries))
