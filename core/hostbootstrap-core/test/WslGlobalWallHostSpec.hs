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

import ConditionalCase (conditionalCase)
import Control.Concurrent (forkFinally, forkIO, threadDelay, throwTo)
import Control.Exception (AsyncException (ThreadKilled), fromException)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Monad (void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Foldable (for_)
import Data.List (isInfixOf, isPrefixOf, sort)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Expect (expectRightLabelled)
import HostBootstrap.Ownership.Object (ObjectIdentity, OwnershipFault (OwnershipProbeFailed), mkObjectIdentity, objectIdentityBytes)
import HostBootstrap.Ownership.Posix (posixOwnershipRow)
import HostBootstrap.Ownership.Primitive (OwnershipPrimitive (..), OwnershipRow, ownershipRow, withOwnershipRow)
import HostBootstrap.Ownership.Row (hostOwnershipSupported, ownershipRowForHost)
import HostBootstrap.Ownership.Windows (windowsOwnershipRow, windowsOwnershipSupported)
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    compareAndSwapProtectedRecord,
    readProtectedRecord,
    withProtectedEntry,
 )
import HostBootstrap.Wsl2.GlobalWall
import HostBootstrap.Wsl2.GlobalWall.ConfigBytes (ConfigBytesError (InvalidManagedSpec), mergeManagedWslConfig, mkManagedWslConfigSpec)
import HostBootstrap.Wsl2.GlobalWall.Host
import HostBootstrap.Wsl2.GlobalWall.Location (
    hostWallActiveRecordKey,
    hostWallProtectedStore,
    openHostWallLocation,
 )
import qualified SourceGuard
import System.Directory (
    createDirectoryIfMissing,
    createFileLink,
    doesFileExist,
    listDirectory,
    removeFile,
    renameFile,
 )
import System.FilePath (dropExtension, takeDirectory, takeExtension, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

managedBody :: [ByteString]
managedBody =
    [ "[general]"
    , "instanceIdleTimeout=21600000"
    , "[wsl2]"
    , "processors=4"
    , "memory=8GB"
    , "swap=8GB"
    , "vmIdleTimeout=21600000"
    ]

otherManagedBody :: [ByteString]
otherManagedBody =
    [ "[general]"
    , "instanceIdleTimeout=21600000"
    , "[wsl2]"
    , "processors=8"
    , "memory=16GB"
    , "swap=16GB"
    , "vmIdleTimeout=21600000"
    ]

request :: ByteString -> [ByteString] -> IO CurrentUserWallRequest
request owner body =
    case mkCurrentUserWallRequest owner "spec" "reservation" "receipt" body of
        Left err -> assertFailure ("unexpected request error: " ++ show err)
        Right value -> pure value

{- | A temporary target plus its own protected store, so no case can observe
another case's durable records.
-}
withWall ::
    (FilePath -> HostWallLocation -> IO result) ->
    IO result
withWall consume =
    withSystemTempDirectory "hostbootstrap-host-wall" $ \directory -> do
        let target = directory </> ".wslconfig"
            state = directory </> "state"
        createDirectoryIfMissing True state
        opened <- openHostWallLocation HostWallJournalFailure target state
        location <- expectRightLabelled "open the wall location" opened
        consume target location

{- | One case that drives the host's ownership row against the kernel.

On a gate host that can hold the row's clauses the body runs and the case is
evidence about the real syscalls (§ NN).  On one that cannot, the case is still
here and still runs; what it asserts is the total refusal the row declares, so
the family's size is a property of the suite rather than of the host.
-}
rowCase :: TestName -> TestName -> (FilePath -> HostWallLocation -> IO ()) -> TestTree
rowCase family name body =
    conditionalCase
        ["WslGlobalWallHostSpec", family]
        hostOwnershipSupported
        name
        (withWall body)
        (withWall (\_ location -> expectRowRefusal ownershipRowForHost location))

{- | The disposition a row that cannot hold its clauses owes every caller.

Both production entry points are asked, because a row that refused only one of
them would be a row that half exists.
-}
expectRowRefusal :: OwnershipRow -> HostWallLocation -> IO ()
expectRowRefusal row location = do
    wall <- request "owner" managedBody
    applied <- applyGlobalWall row location wall
    case applied of
        Left (HostWallUnsupported _) -> pure ()
        other ->
            assertFailure
                ("expected this host's row to refuse this apply, got " ++ show other)
    restored <- restoreGlobalWall row location wall
    case restored of
        Left (HostWallUnsupported _) -> pure ()
        other ->
            assertFailure
                ("expected this host's row to refuse this restore, got " ++ show other)

tests :: TestTree
tests =
    testGroup
        "WslGlobalWallHostSpec"
        [ testGroup "apply over an absent origin" absentOriginCases
        , testGroup "apply over a present origin" presentOriginCases
        , testGroup "ownership refusals" refusalCases
        , testGroup "crash resume" resumeCases
        , testGroup "the durable record codec" codecCases
        , testGroup "request construction" windowsEntryCases
        , testGroup "private wall location" privateLocationCases
        , testGroup "read-only ownership observation" ownershipObservationCases
        ]

absentOriginCases :: [TestTree]
absentOriginCases =
    [ rowCase "apply over an absent origin" "publishes the managed body and restores absence" $ \target location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        persistedWallPhase (appliedWslConfigRecord applied) @?= WallApplied
        published <- ByteString.readFile target
        assertBool
            "the published file contains the managed processors line"
            ("processors=4" `ByteString.isInfixOf` published)
        assertBool
            "the published file contains the managed idle timeout"
            ("vmIdleTimeout=21600000" `ByteString.isInfixOf` published)

        restored <- restoreGlobalWall ownershipRowForHost location wall
        _ <- expectRightLabelled "restore" restored
        exists <- doesFileExist target
        exists @?= False
    , rowCase "apply over an absent origin" "leaves no recovery names or journal behind" $ \target location -> do
        wall <- request "owner" managedBody
        _ <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
        residue <- targetSiblings target
        residue @?= []

        second <- restoreGlobalWall ownershipRowForHost location wall
        case second of
            Left HostWallNoActiveRecord -> pure ()
            other ->
                assertFailure
                    ("expected a cleared journal, got " ++ show other)
    , rowCase "apply over an absent origin" "a second apply is an idempotent no-op" $ \target location -> do
        wall <- request "owner" managedBody
        first <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        afterFirst <- ByteString.readFile target
        second <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "re-apply"
        afterSecond <- ByteString.readFile target
        afterSecond @?= afterFirst
        persistedFenceValue (appliedWslConfigRecord second)
            @?= persistedFenceValue (appliedWslConfigRecord first)
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
        pure ()
    , rowCase "apply over an absent origin" "each acquisition consumes a strictly newer fence" $ \_ location -> do
        wall <- request "owner" managedBody
        first <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
        second <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "re-apply"
        assertBool
            "the second acquisition allocated a strictly newer fence"
            ( persistedFenceValue (appliedWslConfigRecord second)
                > persistedFenceValue (appliedWslConfigRecord first)
            )
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "final restore"
        pure ()
    , rowCase "apply over an absent origin" "clause 1 serialises two concurrent entries" $ \_ location -> do
        started <- newEmptyMVar
        finished <- newEmptyMVar
        outerReturned <- newIORef False
        let store = hostWallProtectedStore location
        void . forkIO $ do
            outcome <-
                withProtectedEntry store $ \_ -> do
                    putMVar started ()
                    threadDelay 200000
                    writeIORef outerReturned True
                    pure (Right (1 :: Int))
            putMVar finished outcome
        takeMVar started
        inner <- withProtectedEntry store $ \_ -> do
            sawOuter <- readIORef outerReturned
            pure (Right (sawOuter, 2 :: Int))
        outer <- takeMVar finished
        outer @?= Right 1
        inner @?= Right (True, 2)
    ]

presentOriginCases :: [TestTree]
presentOriginCases =
    [ rowCase "apply over a present origin" "retains and republishes the exact original bytes" $ \target location -> do
        let original = "# operator settings\n[wsl2]\nkernel=C:\\\\custom\n"
        ByteString.writeFile target original
        wall <- request "owner" managedBody
        _ <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        managed <- ByteString.readFile target
        assertBool
            "the managed file still carries the operator's unrelated key"
            ("kernel=C:\\\\custom" `ByteString.isInfixOf` managed)
        assertBool
            "the managed file carries the cordon"
            ("memory=8GB" `ByteString.isInfixOf` managed)

        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
        recovered <- ByteString.readFile target
        recovered @?= original
        residue <- targetSiblings target
        residue @?= []
    , rowCase "apply over a present origin" "an empty original file is restored as an empty file" $ \target location -> do
        ByteString.writeFile target ByteString.empty
        wall <- request "owner" managedBody
        _ <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
        exists <- doesFileExist target
        exists @?= True
        recovered <- ByteString.readFile target
        recovered @?= ByteString.empty
    , rowCase "apply over a present origin" "a symbolic-link target is refused rather than followed" $ \target location -> do
        ByteString.writeFile (target ++ ".real") "operator bytes\n"
        createFileLink (target ++ ".real") target
        wall <- request "owner" managedBody
        result <- applyGlobalWall ownershipRowForHost location wall
        case result of
            Left (HostWallUnsupported reason) ->
                assertBool
                    "the refusal names the link"
                    (isInfixOf (if windowsOwnershipSupported then "reparse point" else "symbolic link") reason)
            other ->
                assertFailure
                    ("expected an Unsupported symlink refusal, got " ++ show other)
        followed <- ByteString.readFile (target ++ ".real")
        followed @?= "operator bytes\n"
    ]
        ++ journalPreflightCases

refusalCases :: [TestTree]
refusalCases =
    [ rowCase "ownership refusals" "a foreign owner cannot take over an active wall" $ \_ location -> do
        mine <- request "owner" managedBody
        theirs <- request "other-owner" managedBody
        _ <- applyGlobalWall ownershipRowForHost location mine >>= expectRightLabelled "apply"
        result <- applyGlobalWall ownershipRowForHost location theirs
        case result of
            Left (HostWallConflict (ForeignWallOwner _ _)) -> pure ()
            other ->
                assertFailure
                    ("expected a foreign-owner conflict, got " ++ show other)
        _ <- restoreGlobalWall ownershipRowForHost location mine >>= expectRightLabelled "restore"
        pure ()
    , rowCase "ownership refusals" "an incompatible declaration refuses rather than overwrites" $ \target location -> do
        small <- request "owner" managedBody
        large <- request "owner" otherManagedBody
        _ <- applyGlobalWall ownershipRowForHost location small >>= expectRightLabelled "apply"
        before <- ByteString.readFile target
        result <- applyGlobalWall ownershipRowForHost location large
        case result of
            Left (HostWallConflict (IncompatibleWallSpec _ _)) -> pure ()
            other ->
                assertFailure
                    ("expected an incompatible-spec conflict, got " ++ show other)
        after <- ByteString.readFile target
        after @?= before
        _ <- restoreGlobalWall ownershipRowForHost location small >>= expectRightLabelled "restore"
        pure ()
    , rowCase "ownership refusals" "restore without an active record is a structured refusal" $ \_ location -> do
        wall <- request "owner" managedBody
        result <- restoreGlobalWall ownershipRowForHost location wall
        case result of
            Left HostWallNoActiveRecord -> pure ()
            other ->
                assertFailure
                    ("expected HostWallNoActiveRecord, got " ++ show other)
    , rowCase "ownership refusals" "the model refuses a same-bytes replacement before restore begins" $ \target location -> do
        wall <- request "owner" managedBody
        _ <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        -- Same privilege, different object: the pathname is identical but the
        -- kernel identity is not the one the receipt binds.
        replacement <- ByteString.readFile target
        _ <- withOwnershipRow ownershipRowForHost (\row -> rowLinkNoReplace row target (target <> ".original-live")) >>= expectRightLabelled "retain original identity"
        removeFile target
        ByteString.writeFile target replacement
        result <- restoreGlobalWall ownershipRowForHost location wall
        case result of
            Left (HostWallConflict (TargetReplaced _ _)) -> pure ()
            other ->
                assertFailure
                    ("expected an identity conflict, got " ++ show other)
        survived <- ByteString.readFile target
        survived @?= replacement
    ]
        ++ finalGuardCases
        ++ extraRefusalCases
        ++ scopedReadCases

resumeCases :: [TestTree]
resumeCases =
    [ rowCase "crash resume" "an interrupted publication converges on the next apply" $ \target location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        let record = appliedWslConfigRecord applied
        -- The publication call completed, but WallApplied was not stored.
        -- Rewind to that post-publication crash window.
        rewindJournal location record{persistedWallPhase = WallApplyOutcomeUnknown}
        resumed <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "resume"
        persistedWallPhase (appliedWslConfigRecord resumed) @?= WallApplied
        published <- ByteString.readFile target
        assertBool
            "the resumed wall still carries the managed body"
            ("processors=4" `ByteString.isInfixOf` published)
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
        pure ()
    , rowCase "crash resume" "an interrupted restore converges on the next restore" $ \target location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        let record = appliedWslConfigRecord applied
        rewindJournal
            location
            record{persistedWallPhase = WallRestoreOutcomeUnknown}
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "resume restore"
        exists <- doesFileExist target
        exists @?= False
        residue <- targetSiblings target
        residue @?= []
    , rowCase "crash resume" "a durable armed leftover is reclaimed, never published" $ \target location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        let record = appliedWslConfigRecord applied
            fence = show (persistedFenceValue record)
            armed = target ++ ".hostbootstrap." ++ fence ++ ".stage.armed"
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"

        -- Re-enter the stage phase with a stale armed object present. The
        -- host row's armed object is durable, so this is our own interrupted attempt;
        -- its unknown bytes must be discarded rather than published.
        ByteString.writeFile armed "stale attempt bytes\n"
        rewindJournal
            location
            record
                { persistedWallPhase = WallStageCreateOutcomeUnknown
                , persistedTargetIdentity = Nothing
                }
        resumed <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "resume stage"
        persistedWallPhase (appliedWslConfigRecord resumed) @?= WallApplied
        published <- ByteString.readFile target
        assertBool
            "the stale armed bytes were never published"
            (not ("stale attempt bytes" `ByteString.isInfixOf` published))
        doesFileExist armed >>= (@?= False)
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "final restore"
        targetSiblings target >>= (@?= [])
    ]
        ++ extraResumeCases
        ++ halfMoveCases
        ++ namespaceDurabilityCases
        ++ namespaceFailureCases

codecCases :: [TestTree]
codecCases =
    [ rowCase "the durable record codec" "the durable record round-trips" $ \_ location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        let record = appliedWslConfigRecord applied
        decoded <-
            expectRightLabelled "decode" (decodeWallRecord (encodeWallRecord record))
        decoded @?= record
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
        pure ()
    , testCase "an unknown format is refused" $ do
        record <- codecGoldenRecord
        decodeWallRecord ("HBWSLH02" <> ByteString.drop 8 (encodeWallRecord record))
            @?= Left (HostWallJournalFailure "active wall record has an unknown format")
    , rowCase "the durable record codec" "trailing bytes are refused" $ \_ location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        let encoded =
                encodeWallRecord (appliedWslConfigRecord applied)
                    <> "trailing"
        case decodeWallRecord encoded of
            Left (HostWallJournalFailure _) -> pure ()
            other ->
                assertFailure ("expected a journal failure, got " ++ show other)
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
        pure ()
    ]
        ++ codecBoundaryCases

ownershipObservationCases :: [TestTree]
ownershipObservationCases =
    [ testCase "an absent active record reports no ownership without writing" $
        withWall $ \_ location -> do
            result <- withProtectedEntry (hostWallProtectedStore location) $ \session -> do
                observed <- hostWallOwnershipPresent session
                observed @?= Right False
                retained <- readProtectedRecord session (hostWallActiveRecordKey location)
                retained @?= Right Nothing
                pure (Right ())
            _ <- expectRightLabelled "presence entry" result
            pure ()
    , testCase "retained active bytes report ownership and keep their exact version and bytes" $
        withWall $ \_ location -> do
            result <- withProtectedEntry (hostWallProtectedStore location) $ \session -> do
                let key = hostWallActiveRecordKey location
                _ <- expectRightLabelled "retain active bytes" =<< compareAndSwapProtectedRecord session key ExpectAbsent "retained-wall-receipt"
                before <- readProtectedRecord session key
                observed <- hostWallOwnershipPresent session
                observed @?= Right True
                after <- readProtectedRecord session key
                after @?= before
                pure (Right ())
            _ <- expectRightLabelled "presence entry" result
            pure ()
    , testCase "the projection is read-only and demo imports no raw location helper" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            description <- SourceGuard.readPackageDescription
            sources <- SourceGuard.readLibrarySources packageRoot description
            case [body | (name, _, body) <- sources, name == "HostBootstrap.Wsl2.GlobalWall.Location"] of
                [body] -> do
                    tokens <- expectRightLabelled "presence definition" (SourceGuard.haskellDefinitionTokens "hostWallOwnershipPresent" body)
                    mapM_
                        (\name -> assertBool ("presence can mutate through " <> name) (notElem name tokens))
                        ["compareAndSwapProtectedRecord", "compareAndDeleteProtectedRecord", "openProtectedStore"]
                _ -> assertFailure "the wall projection does not have one source home"
            let demoSource = takeDirectory (takeDirectory packageRoot) </> "demo" </> "src"
            demo <- SourceGuard.readHaskellSources demoSource
            case [body | (path, body) <- demo, SourceGuard.repoRelativePath demoSource path == "HostBootstrapDemo/Commands.hs"] of
                [body] ->
                    mapM_
                        (\name -> SourceGuard.countHaskellIdentifier name body @?= 0)
                        ["openHostWallLocation", "hostWallProtectedStore", "hostWallActiveRecordKey"]
                _ -> assertFailure "the demo command module does not have one source home"
    ]

privateLocationCases :: [TestTree]
privateLocationCases =
    [ testCase "a regular-file state path is a journal failure and remains intact" $
        withSystemTempDirectory "hostbootstrap-wall-state-file" $ \directory -> do
            let target = directory </> ".wslconfig"
                state = directory </> "state-file"
            ByteString.writeFile state "not a protected-store directory"
            opened <- openHostWallLocation HostWallJournalFailure target state
            case opened of
                Left (HostWallJournalFailure _) -> pure ()
                Left other -> assertFailure ("expected a journal failure, got " <> show other)
                Right _ -> assertFailure "a regular file was admitted as the wall store"
            ByteString.readFile state >>= (@?= "not a protected-store directory")
            doesFileExist target >>= (@?= False)
    , testCase "raw location opening and store access stay outside the public wall facade" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            description <- SourceGuard.readPackageDescription
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules description)
            assertBool "the location module is private" (notElem "HostBootstrap.Wsl2.GlobalWall.Location" exposed)
            sources <- SourceGuard.readLibrarySources packageRoot description
            case [body | (name, _, body) <- sources, name == "HostBootstrap.Wsl2.GlobalWall.Host"] of
                [body] -> case SourceGuard.moduleExportTokens "HostBootstrap.Wsl2.GlobalWall.Host" body of
                    Nothing -> assertFailure "the public wall export list is missing"
                    Just tokens ->
                        mapM_
                            (\name -> assertBool ("raw wall export returned: " <> name) (notElem name tokens))
                            ["openHostWallLocation", "hostWallProtectedStore", "hostWallActiveRecordKey"]
                _ -> assertFailure "the public wall facade does not have one source home"
    ]

windowsEntryCases :: [TestTree]
windowsEntryCases =
    [ testCase "an invalid managed body is a structured configuration error" $
        case mkCurrentUserWallRequest
            "owner"
            "spec"
            "reservation"
            "receipt"
            (managedBody ++ ["processors=8"]) of
            Left (HostWallConfigurationFailure _) -> pure ()
            other ->
                assertFailure
                    ("expected a structured configuration failure, got " ++ show other)
    , testCase "an empty identity is refused before any effect" $
        case mkCurrentUserWallRequest "" "spec" "reservation" "receipt" managedBody of
            Left (HostWallModelFailure (InvalidWallIdentity _)) -> pure ()
            other ->
                assertFailure
                    ("expected an invalid-identity refusal, got " ++ show other)
    ]
        ++ requestAdmissionCases

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
    void (expectRightLabelled "rewind journal" stored)

-- | Every recovery name the adapter can leave beside the target.
targetSiblings :: FilePath -> IO [FilePath]
targetSiblings target = do
    entries <- listDirectory (takeDirectory target)
    pure (sort (filter (".wslconfig.hostbootstrap." `isPrefixOf`) entries))

codecGoldenRecord :: IO PersistedWallRecord
codecGoldenRecord = do
    identity <- expectRightLabelled "codec identity" (mkObjectIdentity (ByteString.pack [1 .. 8]))
    pure
        PersistedWallRecord
            { persistedOwnerIdentity = "a"
            , persistedSpecIdentity = "b"
            , persistedReservationIdentity = "c"
            , persistedReceiptIdentity = "d"
            , persistedFenceValue = 1
            , persistedDesiredBytes = "x"
            , persistedWallPhase = WallStageBound
            , persistedWallOrigin = Just OriginalAbsent
            , persistedStageCandidate = Just "stage"
            , persistedTargetIdentity = Just identity
            }

codecGoldenBytes :: ByteString
codecGoldenBytes =
    ByteString.pack
    [ 72, 66, 87, 83, 76, 72, 48, 51, 3, 1, 0, 0
    , 0, 0, 0, 0, 0, 1, 0, 0, 0, 97, 1, 0
    , 0, 0, 98, 1, 0, 0, 0, 99, 1, 0, 0, 0
    , 100, 1, 0, 0, 0, 120, 1, 1, 5, 0, 0, 0
    , 115, 116, 97, 103, 101, 1, 8, 0, 0, 0, 1, 2
    , 3, 4, 5, 6, 7, 8
    ]

patchBytes :: Int -> ByteString -> ByteString -> ByteString
patchBytes offset replacement bytes =
    ByteString.take offset bytes <> replacement <> ByteString.drop (offset + ByteString.length replacement) bytes

codecBoundaryCases :: [TestTree]
codecBoundaryCases =
    [ testCase "one independent byte vector pins the complete wall codec" $ do
        record <- codecGoldenRecord
        encodeWallRecord record @?= codecGoldenBytes
        decodeWallRecord codecGoldenBytes @?= Right record
    ]
        ++ [ testCase ("the codec refuses " <> label) $
                decodeWallRecord bytes @?= Left (HostWallJournalFailure message)
           | (label, bytes, message) <-
                [ ("phase byte 9", patchBytes 8 (ByteString.singleton 9) codecGoldenBytes, "active wall record has an unknown phase")
                , ("origin tag 3", patchBytes 42 (ByteString.singleton 3) codecGoldenBytes, "active wall record has an unknown origin tag")
                , ("optional bytes tag 2", patchBytes 43 (ByteString.singleton 2) codecGoldenBytes, "active wall record has an unknown optional-bytes tag")
                , ("optional identity tag 2", patchBytes 53 (ByteString.singleton 2) codecGoldenBytes, "active wall record has an unknown optional-identity tag")
                , ("a four-byte identity without trailing bytes", ByteString.take 62 (patchBytes 54 (ByteString.pack [4, 0, 0, 0]) codecGoldenBytes), "kernel identity evidence must be between 8 and 64 bytes")
                , ("a 0xFFFFFFFF field length", patchBytes 17 (ByteString.replicate 4 255) codecGoldenBytes, "active wall record field exceeds the 16 MiB limit")
                ]
           ]
        ++ [ testCase "truncation at every wire-field boundary is refused" $
                mapM_
                    (\offset -> decodeWallRecord (ByteString.take offset codecGoldenBytes) @?= Left (HostWallJournalFailure "active wall record is truncated"))
                    [0, 7, 8, 9, 16, 17, 20, 41, 42, 43, 47, 53, 57, 65]
           ]

requestAdmissionCases :: [TestTree]
requestAdmissionCases =
    [ testCase "request admission refuses every remaining empty identity and oversize field" $ do
        let big = ByteString.replicate (maximumWallBytes + 1) 120
            invalids =
                [ mkCurrentUserWallRequest "owner" "" "reservation" "receipt" managedBody
                , mkCurrentUserWallRequest "owner" "spec" "" "receipt" managedBody
                , mkCurrentUserWallRequest "owner" "spec" "reservation" "" managedBody
                ]
            oversize =
                [ mkCurrentUserWallRequest big "spec" "reservation" "receipt" managedBody
                , mkCurrentUserWallRequest "owner" big "reservation" "receipt" managedBody
                , mkCurrentUserWallRequest "owner" "spec" big "receipt" managedBody
                , mkCurrentUserWallRequest "owner" "spec" "reservation" big managedBody
                , mkCurrentUserWallRequest "owner" "spec" "reservation" "receipt" [big]
                ]
        mapM_
            (\result -> case result of
                Left (HostWallModelFailure (InvalidWallIdentity _)) -> pure ()
                other -> assertFailure ("expected InvalidWallIdentity, got " <> show other))
            invalids
        mapM_
            (\result -> case result of
                Left (HostWallUnsupported _) -> pure ()
                other -> assertFailure ("expected HostWallUnsupported, got " <> show other))
            oversize
    , testCase "managed-spec admission refuses each malformed section, line and missing key" $ do
        let malformed =
                [ drop 2 managedBody
                , take 2 managedBody
                , managedBody <> ["[general]"]
                , managedBody <> ["[wsl2]"]
                , managedBody <> ["[network]"]
                , "memory=8GB" : managedBody
                , ByteString.empty : managedBody
                , ByteString.singleton 0 : managedBody
                ]
            missing =
                [ filter (\line -> not (ByteString.isPrefixOf key line)) managedBody
                | key <- ["instanceIdleTimeout=", "processors=", "memory=", "swap=", "vmIdleTimeout="]
                ]
        mapM_
            (\body -> case mkManagedWslConfigSpec body of
                Left (InvalidManagedSpec _) -> pure ()
                other -> assertFailure ("expected InvalidManagedSpec, got " <> show other))
            (malformed <> missing)
    ]

readActiveRecord :: HostWallLocation -> IO (Maybe ProtectedRecord)
readActiveRecord location = do
    result <- withProtectedEntry (hostWallProtectedStore location) $ \session ->
        readProtectedRecord session (hostWallActiveRecordKey location)
    expectRightLabelled "read active wall record" result

observeRowIdentity :: FilePath -> IO ObjectIdentity
observeRowIdentity target = do
    observed <- withOwnershipRow ownershipRowForHost (\row -> rowObserveIdentity row target)
    case observed of
        Right (Just identity) -> pure identity
        other -> assertFailure ("expected a real row identity, got " <> show other)

finalGuardCases :: [TestTree]
finalGuardCases =
    [ rowCase "ownership refusals" label $ \target location -> do
        if present then ByteString.writeFile target "# operator\n" else pure ()
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        let record = appliedWslConfigRecord applied
            parked = target <> ".pre-guard-original"
        published <- ByteString.readFile target
        rewindJournal location record{persistedWallPhase = WallRestoreOutcomeUnknown}
        readFinished <- newIORef False
        withOwnershipRow ownershipRowForHost $ \primitives -> do
            let raced =
                    ownershipRow
                        primitives
                            { rowReadObject = \handle -> do
                                contents <- rowReadObject primitives handle
                                _ <- expectRightLabelled "actual payload read" contents
                                writeIORef readFinished True
                                pure contents
                            , rowObserveIdentity = \path -> do
                                observed <- rowObserveIdentity primitives path
                                ready <- readIORef readFinished
                                alreadyMoved <- doesFileExist parked
                                if path == target && ready && not alreadyMoved
                                    then do
                                        -- The post-read syscall has observed the original.
                                        -- Replace after it, before the final-act guard probes.
                                        renameFile target parked
                                        if vanished then pure () else ByteString.writeFile target published
                                    else pure ()
                                pure observed
                            }
            result <- restoreGlobalWall raced location wall
            case (vanished, result) of
                (True, Left (HostWallConflict (UnexpectedTargetAbsent expected))) ->
                    Just expected @?= persistedTargetIdentity record
                (False, Left (HostWallConflict (TargetReplaced expected observed))) -> do
                    Just expected @?= persistedTargetIdentity record
                    current <- observeRowIdentity target
                    observed @?= current
                    assertBool "two live identities differ" (expected /= observed)
                other -> assertFailure ("expected the final identity guard, got " <> show other)
        ByteString.readFile parked >>= (@?= published)
        if vanished
            then doesFileExist target >>= (@?= False)
            else ByteString.readFile target >>= (@?= published)
    | (label, present, vanished) <-
        [ ("the final guard refuses same-bytes replacement before unlink", False, False)
        , ("the final guard refuses same-bytes replacement before hard-link retirement", True, False)
        , ("the final guard refuses disappearance before unlink", False, True)
        ]
    ]

extraRefusalCases :: [TestTree]
extraRefusalCases =
    foreignRequestCases <> otherRefusalCases <> observationRaceCases

foreignRequestCases :: [TestTree]
foreignRequestCases =
    [ rowCase "ownership refusals" label $ \target location -> do
        mine <- request "owner" managedBody
        theirs <-
            expectRightLabelled "foreign request"
                (mkCurrentUserWallRequest "owner" "spec"
                    (if reservation then "foreign-reservation" else "reservation")
                    (if reservation then "receipt" else "foreign-receipt")
                    managedBody)
        _ <- applyGlobalWall ownershipRowForHost location mine >>= expectRightLabelled "apply"
        before <- ByteString.readFile target
        recordBefore <- readActiveRecord location
        applied <- applyGlobalWall ownershipRowForHost location theirs
        expectForeignRequest reservation applied
        restored <- restoreGlobalWall ownershipRowForHost location theirs
        expectForeignRequest reservation restored
        ByteString.readFile target >>= (@?= before)
        readActiveRecord location >>= (@?= recordBefore)
        _ <- restoreGlobalWall ownershipRowForHost location mine >>= expectRightLabelled "owner restore"
        pure ()
    | (label, reservation) <-
        [ ("foreign reservations refuse both apply and restore", True)
        , ("foreign receipts refuse both apply and restore", False)
        ]
    ]
        <> [ rowCase "ownership refusals" "a reused spec identity with different desired bytes is an invalid journal" $ \target location -> do
                wall <- request "owner" managedBody
                applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
                let record = appliedWslConfigRecord applied
                before <- ByteString.readFile target
                rewindJournal location record{persistedDesiredBytes = "different desired bytes"}
                result <- applyGlobalWall ownershipRowForHost location wall
                case result of
                    Left (HostWallModelFailure (InvalidWallJournal _)) -> pure ()
                    other -> assertFailure ("expected InvalidWallJournal, got " <> show other)
                ByteString.readFile target >>= (@?= before)
                rewindJournal location record
                _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
                pure ()
           ]

expectForeignRequest :: (Show value) => Bool -> Either HostWallError value -> IO ()
expectForeignRequest reservation result = case (reservation, result) of
    (True, Left (HostWallConflict (ForeignWallReservation _ _))) -> pure ()
    (False, Left (HostWallConflict (ForeignWallReceipt _ _))) -> pure ()
    other -> assertFailure ("expected the exact foreign-request conflict, got " <> show other)

otherRefusalCases :: [TestTree]
otherRefusalCases =
    [ testCase "the row-case fallback exercises the unavailable real platform row" $
        withWall $ \_ location -> do
            let unavailable = if windowsOwnershipSupported then posixOwnershipRow else windowsOwnershipRow
            expectRowRefusal unavailable location
            readActiveRecord location >>= (@?= Nothing)
    , rowCase "ownership refusals" "a partial armed write preserves the reported probe fault" $ \target location -> do
        wall <- request "owner" managedBody
        withOwnershipRow ownershipRowForHost $ \primitives -> do
            let partial =
                    ownershipRow
                        primitives
                            { rowCreateFile = \path bytes -> do
                                created <- rowCreateFile primitives path (ByteString.take 1 bytes)
                                case created of
                                    Left failure -> pure (Left failure)
                                    Right () -> do
                                        ByteString.readFile path >>= (@?= ByteString.take 1 bytes)
                                        pure (Left (OwnershipProbeFailed "write armed stage" "declared partial-write failure"))
                            }
            result <- applyGlobalWall partial location wall
            result @?= Left (HostWallFailure "write armed stage" "declared partial-write failure")
        residue <- targetSiblings target
        assertBool "the actual partial object remains" (not (null residue))
    ]
        <> presentReplacementCases
        <> retainedCollisionCases

presentReplacementCases :: [TestTree]
presentReplacementCases =
    [ rowCase "ownership refusals" "the model refuses a same-bytes replacement over a present origin" $ \target location -> do
        ByteString.writeFile target "# operator\n"
        wall <- request "owner" managedBody
        _ <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        replacement <- ByteString.readFile target
        _ <- withOwnershipRow ownershipRowForHost (\row -> rowLinkNoReplace row target (target <> ".original-live")) >>= expectRightLabelled "retain original identity"
        removeFile target
        ByteString.writeFile target replacement
        result <- restoreGlobalWall ownershipRowForHost location wall
        case result of
            Left (HostWallConflict (TargetReplaced _ _)) -> pure ()
            other -> assertFailure ("expected TargetReplaced, got " <> show other)
        ByteString.readFile target >>= (@?= replacement)
    ]

retainedCollisionCases :: [TestTree]
retainedCollisionCases =
    [ rowCase "ownership refusals" "a pre-created retained name refuses present-origin publication" $ \target location -> do
        let original = "# operator\n"
        ByteString.writeFile target original
        wall <- request "owner" managedBody
        withOwnershipRow ownershipRowForHost $ \primitives -> do
            let colliding =
                    ownershipRow
                        primitives
                            { rowCreateFile = \armed bytes -> do
                                let retained = dropExtension (dropExtension armed) <> ".origin"
                                ByteString.writeFile retained "foreign retained bytes"
                                rowCreateFile primitives armed bytes
                            }
            result <- applyGlobalWall colliding location wall
            case result of
                Left (HostWallConflict (UnexpectedTargetPresent _)) -> pure ()
                other -> assertFailure ("expected UnexpectedTargetPresent, got " <> show other)
        ByteString.readFile target >>= (@?= original)
        active <- readActiveRecord location
        record <- case active of
            Just stored -> expectRightLabelled "active collision record" (decodeWallRecord (protectedRecordBytes stored))
            Nothing -> assertFailure "the interrupted publication lost its active record"
        let retained = target <> ".hostbootstrap." <> show (persistedFenceValue record) <> ".origin"
        ByteString.readFile retained >>= (@?= "foreign retained bytes")
    ]

extraResumeCases :: [TestTree]
extraResumeCases =
    refusedPhaseCases <> armedResumeCases <> publicationResumeCases

refusedPhaseCases :: [TestTree]
refusedPhaseCases =
    [ rowCase "crash resume" label $ \target location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        let record = appliedWslConfigRecord applied
        before <- ByteString.readFile target
        rewindJournal location record{persistedWallPhase = phase}
        active <- readActiveRecord location
        result <- if applying
            then fmap (fmap (const ())) (applyGlobalWall ownershipRowForHost location wall)
            else restoreGlobalWall ownershipRowForHost location wall
        case result of
            Left (HostWallModelFailure (IllegalWallTransition observed _)) -> observed @?= phase
            other -> assertFailure ("expected the exact illegal phase, got " <> show other)
        ByteString.readFile target >>= (@?= before)
        readActiveRecord location >>= (@?= active)
        rewindJournal location record
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
        pure ()
    | (label, phase, applying) <-
        [ ("apply refuses a restored journal phase", WallRestored, True)
        , ("restore refuses a stage-bound journal phase", WallStageBound, False)
        ]
    ]
        <> [ rowCase "crash resume" "a released record with restored origin clears its active pointer" $ \target location -> do
                wall <- request "owner" managedBody
                applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
                _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "first restore"
                rewindJournal location (appliedWslConfigRecord applied){persistedWallPhase = WallReleased}
                restoreGlobalWall ownershipRowForHost location wall >>= (@?= Right ())
                readActiveRecord location >>= (@?= Nothing)
                doesFileExist target >>= (@?= False)
           ]

armedResumeCases :: [TestTree]
armedResumeCases =
    [ rowCase "crash resume" label $ \target location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        let record = appliedWslConfigRecord applied
            stage = target <> ".hostbootstrap." <> show (persistedFenceValue record) <> ".stage"
            armed = stage <> ".armed"
        if foreignArmed
            then do
                renameFile target (target <> ".bound-original-live")
                ByteString.writeFile armed (persistedDesiredBytes record)
            else renameFile target armed
        rewindJournal location record{persistedWallPhase = WallStageBound}
        resumed <- applyGlobalWall ownershipRowForHost location wall
        result <- expectRightLabelled "bound armed resume" resumed
        persistedWallPhase (appliedWslConfigRecord result) @?= WallApplied
        ByteString.readFile target >>= (@?= persistedDesiredBytes record)
        doesFileExist armed >>= (@?= False)
        doesFileExist stage >>= (@?= False)
        if foreignArmed
            then do
                current <- observeRowIdentity target
                assertBool "the previous bound identity was not reused" (Just current /= persistedTargetIdentity record)
                ByteString.readFile (target <> ".bound-original-live") >>= (@?= persistedDesiredBytes record)
            else pure ()
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
        pure ()
    | (label, foreignArmed) <-
        [ ("a journalled armed identity with no durable stage resumes publication", False)
        , ("a different armed identity at this fence is reclaimed in the bound stage", True)
        ]
    ]

publicationResumeCases :: [TestTree]
publicationResumeCases =
    [ rowCase "crash resume" "resume before the publication call publishes the bound durable stage" $ \target location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        let record = appliedWslConfigRecord applied
            stage = target <> ".hostbootstrap." <> show (persistedFenceValue record) <> ".stage"
        renameFile target stage
        rewindJournal location record{persistedWallPhase = WallApplyOutcomeUnknown}
        resumed <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "pre-publication resume"
        persistedWallPhase (appliedWslConfigRecord resumed) @?= WallApplied
        ByteString.readFile target >>= (@?= persistedDesiredBytes record)
        doesFileExist stage >>= (@?= False)
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
        targetSiblings target >>= (@?= [])
    , rowCase "crash resume" "foreign bytes at the durable stage refuse create-outcome recovery" $ \target location -> do
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "apply"
        let record = appliedWslConfigRecord applied
            stage = target <> ".hostbootstrap." <> show (persistedFenceValue record) <> ".stage"
        ByteString.writeFile stage "foreign stage"
        rewindJournal location record{persistedWallPhase = WallStageCreateOutcomeUnknown, persistedTargetIdentity = Nothing}
        result <- applyGlobalWall ownershipRowForHost location wall
        case result of
            Left (HostWallConflict (UnboundStagePresent _)) -> pure ()
            other -> assertFailure ("expected UnboundStagePresent, got " <> show other)
        ByteString.readFile stage >>= (@?= "foreign stage")
        ByteString.readFile target >>= (@?= persistedDesiredBytes record)
    ]

journalPreflightCases :: [TestTree]
journalPreflightCases =
    [ rowCase "apply over a present origin" "a record that would outgrow the journal is refused before the first active store" $ \target location -> do
        ByteString.writeFile target ByteString.empty
        identity <- observeRowIdentity target
        wall <- request "owner" managedBody
        spec <- expectRightLabelled "managed spec" (mkManagedWslConfigSpec managedBody)
        emptyDesired <- expectRightLabelled "empty merge" (mergeManagedWslConfig ByteString.empty spec)
        smallDesired <- expectRightLabelled "small merge" (mergeManagedWslConfig "#\n" spec)
        let base =
                PersistedWallRecord
                    { persistedOwnerIdentity = "owner"
                    , persistedSpecIdentity = requestManagedSpecIdentity wall
                    , persistedReservationIdentity = "reservation"
                    , persistedReceiptIdentity = "receipt"
                    , persistedFenceValue = 1
                    , persistedDesiredBytes = emptyDesired
                    , persistedWallPhase = WallOriginRecorded
                    , persistedWallOrigin = Just (OriginalPresent identity ByteString.empty)
                    , persistedStageCandidate = Nothing
                    , persistedTargetIdentity = Nothing
                    }
            overhead = ByteString.length (encodeWallRecord base) - ByteString.length emptyDesired
            mergeGrowth = ByteString.length smallDesired - 2
            candidate = ".hostbootstrap.1.stage"
            candidateGrowth = 4 + ByteString.length candidate
            originalLength = div (maximumWallBytes - overhead - mergeGrowth - candidateGrowth - 2) 2
            original = "#" <> ByteString.replicate (originalLength - 2) 120 <> "\n"
        assertBool "the real file fixture has positive padding" (originalLength > 2)
        ByteString.writeFile target original
        current <- observeRowIdentity target
        desired <- expectRightLabelled "large merge" (mergeManagedWslConfig original spec)
        let recorded = base{persistedDesiredBytes = desired, persistedWallOrigin = Just (OriginalPresent current original)}
            withCandidate = recorded{persistedStageCandidate = Just candidate, persistedWallPhase = WallStageCreateOutcomeUnknown}
            candidateSize = ByteString.length (encodeWallRecord withCandidate)
        assertBool "the first active encoding fits" (ByteString.length (encodeWallRecord recorded) <= maximumWallBytes)
        assertBool "the candidate-only encoding fits" (candidateSize <= maximumWallBytes)
        assertBool "a native bound identity would exceed the journal" (candidateSize + 4 + ByteString.length (objectIdentityBytes current) > maximumWallBytes)
        result <- applyGlobalWall ownershipRowForHost location wall
        case result of
            Left (HostWallUnsupported _) -> pure ()
            other -> assertFailure ("expected journal preflight Unsupported, got " <> show other)
        readActiveRecord location >>= (@?= Nothing)
        ByteString.readFile target >>= (@?= original)
        targetSiblings target >>= (@?= [])
    ]

-- A link leaves both names present; these fixtures perform the real row syscall.
linkWallNames :: FilePath -> FilePath -> IO ()
linkWallNames source destination = do
    linked <- withOwnershipRow ownershipRowForHost (\row -> rowLinkNoReplace row source destination)
    _ <- expectRightLabelled "real no-replace hard link" linked
    pure ()

halfMoveCases :: [TestTree]
halfMoveCases =
    [ rowCase "crash resume" label $ \target location -> do
        if move == ("publishStage" :: String) then pure () else ByteString.writeFile target "# original operator bytes\n"
        wall <- request "owner" managedBody
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "initial apply"
        let record = appliedWslConfigRecord applied
            prefix = target <> ".hostbootstrap." <> show (persistedFenceValue record)
            stage = prefix <> ".stage"
            retained = prefix <> ".origin"
            retired = prefix <> ".managed"
        case move of
            "publishStage" -> linkWallNames target stage
            "retainOrigin" -> do
                linkWallNames target stage
                removeFile target
                linkWallNames retained target
            "retireManagedTarget" -> linkWallNames target retired
            "publishOrigin" -> do
                linkWallNames target retired
                removeFile target
                linkWallNames retained target
            _ -> assertFailure "unknown half-move fixture"
        rewindJournal location record{persistedWallPhase = if applying then WallApplyOutcomeUnknown else WallRestoreOutcomeUnknown}
        if applying
            then do
                resumed <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "half-move apply"
                persistedWallPhase (appliedWslConfigRecord resumed) @?= WallApplied
                current <- observeRowIdentity target
                Just current @?= persistedTargetIdentity record
                ByteString.readFile target >>= (@?= persistedDesiredBytes record)
                doesFileExist stage >>= (@?= False)
                active <- readActiveRecord location
                decoded <- case active of
                    Just stored -> expectRightLabelled "settled active record" (decodeWallRecord (protectedRecordBytes stored))
                    Nothing -> assertFailure "apply lost its active record"
                persistedWallPhase decoded @?= WallApplied
                _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "final restore"
                pure ()
            else do
                _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "half-move restore"
                readActiveRecord location >>= (@?= Nothing)
                doesFileExist retained >>= (@?= False)
                doesFileExist retired >>= (@?= False)
        if move == "publishStage"
            then doesFileExist target >>= (@?= False)
            else do
                ByteString.readFile target >>= (@?= "# original operator bytes\n")
                case persistedWallOrigin record of
                    Just (OriginalPresent original _) -> observeRowIdentity target >>= (@?= original)
                    other -> assertFailure ("expected the recorded original, got " <> show other)
        targetSiblings target >>= (@?= [])
    | (label, move, applying) <-
        [ ("publishStage resumes with both hard-link names present", "publishStage", True)
        , ("retainOrigin resumes with both hard-link names present", "retainOrigin", True)
        , ("retireManagedTarget resumes with both hard-link names present", "retireManagedTarget", False)
        , ("publishOrigin resumes with both hard-link names present", "publishOrigin", False)
        ]
    ]
        <> [ rowCase "crash resume" "duplicate names with changed bytes are preserved and refused" $ \target location -> do
                wall <- request "owner" managedBody
                applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "initial apply"
                let record = appliedWslConfigRecord applied
                    stage = target <> ".hostbootstrap." <> show (persistedFenceValue record) <> ".stage"
                linkWallNames target stage
                ByteString.writeFile target "changed bytes through the same inode"
                rewindJournal location record{persistedWallPhase = WallApplyOutcomeUnknown}
                before <- readActiveRecord location
                resumed <- applyGlobalWall ownershipRowForHost location wall
                case resumed of
                    Left (HostWallConflict _) -> pure ()
                    other -> assertFailure ("expected changed-byte refusal, got " <> show other)
                readActiveRecord location >>= (@?= before)
                ByteString.readFile stage >>= (@?= "changed bytes through the same inode")
                observeRowIdentity stage >>= (\identity -> Just identity @?= persistedTargetIdentity record)
           ]

observationRaceCases :: [TestTree]
observationRaceCases =
    [ rowCase "ownership refusals" label $ \target location -> do
        ByteString.writeFile target "# original bytes\n"
        wall <- request "owner" managedBody
        let parked = target <> ".read-original"
        withOwnershipRow ownershipRowForHost $ \primitives -> do
            let raced = ownershipRow primitives
                    { rowReadObject = \handle -> do
                        contents <- rowReadObject primitives handle
                        _ <- expectRightLabelled "read original" contents
                        renameFile target parked
                        if vanished then pure () else ByteString.writeFile target "# replacement bytes\n"
                        pure contents
                    }
            result <- applyGlobalWall raced location wall
            case result of
                Left (HostWallBusy _) -> pure ()
                other -> assertFailure ("expected unstable observation refusal, got " <> show other)
        readActiveRecord location >>= (@?= Nothing)
        ByteString.readFile parked >>= (@?= "# original bytes\n")
        if vanished
            then doesFileExist target >>= (@?= False)
            else ByteString.readFile target >>= (@?= "# replacement bytes\n")
    | (label, vanished) <-
        [ ("replacement during the origin read is busy before any active record", False)
        , ("disappearance during the origin read is busy before any active record", True)
        ]
    ]

-- Inspect actual record envelopes without acquiring another protected entry.
-- The row callbacks run inside the driver's existing entry.
recordEnvelopeSnapshot :: FilePath -> IO [(FilePath, ByteString)]
recordEnvelopeSnapshot target = do
    let directory = takeDirectory target </> "state" </> "records"
    entries <- sort <$> listDirectory directory
    mapM (\name -> do bytes <- ByteString.readFile (directory </> name); pure (name, bytes))
        (filter (\name -> takeExtension name == ".rec") entries)

namespaceDurabilityCases :: [TestTree]
namespaceDurabilityCases =
    [ rowCase "crash resume" "namespace changes sync before any protected record advances" $ \target location -> do
        ByteString.writeFile target "# operator origin\n"
        wall <- request "owner" managedBody
        events <- newIORef []
        withOwnershipRow ownershipRowForHost $ \primitives -> do
            let remember operation path outcome = case outcome of
                    Left _ -> pure outcome
                    Right () -> do
                        snapshot <- recordEnvelopeSnapshot target
                        modifyIORef' events ((operation, path, snapshot) :)
                        pure outcome
                recording = ownershipRow primitives
                    { rowLinkNoReplace = \source destination ->
                        rowLinkNoReplace primitives source destination >>= remember "link" destination
                    , rowRemoveObject = \path -> rowRemoveObject primitives path >>= remember "remove" path
                    , rowSyncParent = \path -> rowSyncParent primitives path >>= remember "sync" path
                    }
            _ <- applyGlobalWall recording location wall >>= expectRightLabelled "recorded apply"
            _ <- restoreGlobalWall recording location wall >>= expectRightLabelled "recorded restore"
            pure ()
        observed <- reverse <$> readIORef events
        length [() | ("link", _, _) <- observed] @?= 5
        length [() | ("remove", _, _) <- observed] @?= 6
        assertBool "record snapshots cover real version advances"
            (length (uniqueSnapshots [snapshot | (_, _, snapshot) <- observed]) > 2)
        verifySyncs observed
        readActiveRecord location >>= (@?= Nothing)
        ByteString.readFile target >>= (@?= "# operator origin\n")
    ]
  where
    uniqueSnapshots [] = []
    uniqueSnapshots (x : xs) = x : uniqueSnapshots (filter (/= x) xs)
    verifySyncs [] = pure ()
    verifySyncs ((operation, path, snapshot) : rest) = do
        if operation == "link" || operation == "remove"
            then case break (\(kind, syncedPath, _) -> kind == "sync" && takeDirectory syncedPath == takeDirectory path) rest of
                (_, []) -> assertFailure ("missing parent sync after " <> operation <> " at " <> path)
                (between, (_, _, syncedSnapshot) : _) -> do
                    syncedSnapshot @?= snapshot
                    mapM_ (\(_, _, current) -> current @?= snapshot) between
            else pure ()
        verifySyncs rest

namespaceFailureCases :: [TestTree]
namespaceFailureCases =
    [ rowCase "crash resume" "failed source unlink leaves a recoverable retained-origin half-move" $ \target location -> do
        ByteString.writeFile target "# operator\n"
        wall <- request "owner" managedBody
        original <- observeRowIdentity target
        withOwnershipRow ownershipRowForHost $ \primitives -> do
            let refused = ownershipRow primitives
                    { rowRemoveObject = \path ->
                        if path == target
                            then pure (Left (OwnershipProbeFailed "remove source" "declared sharing violation"))
                            else rowRemoveObject primitives path
                    }
            result <- applyGlobalWall refused location wall
            result @?= Left (HostWallFailure "remove source" "declared sharing violation")
        stored <- readActiveRecord location
        record <- case stored of
            Just value -> expectRightLabelled "interrupted active record" (decodeWallRecord (protectedRecordBytes value))
            Nothing -> assertFailure "the failed move lost its journal"
        persistedWallPhase record @?= WallApplyOutcomeUnknown
        let retained = target <> ".hostbootstrap." <> show (persistedFenceValue record) <> ".origin"
        observeRowIdentity target >>= (@?= original)
        observeRowIdentity retained >>= (@?= original)
        applied <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "retry failed unlink"
        persistedWallPhase (appliedWslConfigRecord applied) @?= WallApplied
        _ <- restoreGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "restore"
        observeRowIdentity target >>= (@?= original)
    ]
        <> [ rowCase "crash resume" label $ \target location -> do
                wall <- request "owner" managedBody
                if restoring
                    then do
                        _ <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "initial apply"
                        pure ()
                    else pure ()
                removed <- newIORef False
                withOwnershipRow ownershipRowForHost $ \primitives -> do
                    let refused = ownershipRow primitives
                            { rowRemoveObject = \path -> do
                                result <- rowRemoveObject primitives path
                                case result of
                                    Right () | (restoring && path == target) || (not restoring && takeExtension path == ".stage") ->
                                        writeIORef removed True
                                    _ -> pure ()
                                pure result
                            , rowSyncParent = \path -> do
                                changed <- readIORef removed
                                if changed
                                    then pure (Left (OwnershipProbeFailed "sync changed namespace" "declared flush failure"))
                                    else rowSyncParent primitives path
                            }
                    result <- if restoring
                        then restoreGlobalWall refused location wall
                        else fmap (fmap (const ())) (applyGlobalWall refused location wall)
                    result @?= Left (HostWallFailure "sync changed namespace" "declared flush failure")
                active <- readActiveRecord location
                record <- case active of
                    Just value -> expectRightLabelled "unsynced active record" (decodeWallRecord (protectedRecordBytes value))
                    Nothing -> assertFailure "a refused flush advanced past its journal"
                persistedWallPhase record @?= if restoring then WallRestoreOutcomeUnknown else WallApplyOutcomeUnknown
                syncs <- newIORef []
                withOwnershipRow ownershipRowForHost $ \primitives -> do
                    let recording = ownershipRow primitives
                            { rowSyncParent = \path -> do
                                result <- rowSyncParent primitives path
                                case result of
                                    Right () -> modifyIORef' syncs (path :)
                                    Left _ -> pure ()
                                pure result
                            }
                    if restoring
                        then restoreGlobalWall recording location wall >>= (@?= Right ())
                        else do
                            applied <- applyGlobalWall recording location wall >>= expectRightLabelled "retry refused flush"
                            persistedWallPhase (appliedWslConfigRecord applied) @?= WallApplied
                paths <- readIORef syncs
                assertBool "the observed namespace is synced before retry settles" (not (null paths))
                if restoring
                    then readActiveRecord location >>= (@?= Nothing)
                    else restoreGlobalWall ownershipRowForHost location wall >>= (@?= Right ())
           | (label, restoring) <-
                [ ("a failed move flush retains intent and retry syncs before settlement", False)
                , ("a failed delete flush retains intent and retry syncs before settlement", True)
                ]
           ]

-- The whole production operation owns the protected entry on its worker thread.
scopedReadCases :: [TestTree]
scopedReadCases =
    [ rowCase "ownership refusals" "interrupted active-wall reads close their handle and remain retryable" $ \target location ->
        for_ [False, True] $ \restoring -> do
            let original = "# operator origin for interrupted reads\n"
            ByteString.writeFile target original
            originalIdentity <- observeRowIdentity target
            wall <- request "owner" managedBody
            _ <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "initial apply"
            beforeBytes <- ByteString.readFile target
            beforeIdentity <- observeRowIdentity target
            beforeActive <- readActiveRecord location
            assertBool "an actual active envelope exists" (case beforeActive of Just _ -> True; Nothing -> False)
            beforeRecords <- recordEnvelopeSnapshot target
            withOwnershipRow ownershipRowForHost $ \primitives -> do
                probe <- newIORef Nothing
                targetRead <- newIORef False
                ready <- newEmptyMVar
                gate <- newEmptyMVar
                completed <- newEmptyMVar
                let interrupted = ownershipRow (primitives
                        { rowOpenExclusive = \path -> do
                            opened <- rowOpenExclusive primitives path
                            case opened of
                                Left fault -> pure (Left fault)
                                Right handle -> do
                                    writeIORef targetRead (path == target)
                                    if path == target
                                        then writeIORef probe (Just (rowReadObject primitives handle))
                                        else pure ()
                                    pure (Right handle)
                        , rowReadObject = \handle -> do
                            contents <- rowReadObject primitives handle
                            isTarget <- readIORef targetRead
                            if isTarget
                                then do
                                    contents @?= Right beforeBytes
                                    putMVar ready ()
                                    takeMVar gate >>= \() -> pure contents
                                else pure contents
                        })
                    operation = if restoring
                        then restoreGlobalWall interrupted location wall
                        else fmap (fmap (const ())) (applyGlobalWall interrupted location wall)
                worker <- forkFinally operation $ \outcome -> do
                    _ <- tryPutMVar ready ()
                    putMVar completed outcome
                takeMVar ready
                throwTo worker ThreadKilled
                outcome <- takeMVar completed
                case outcome of
                    Left failure -> (fromException failure :: Maybe AsyncException) @?= Just ThreadKilled
                    Right other -> assertFailure ("the interrupted wall read returned: " <> show other)
                actualRead <- readIORef probe >>= maybe (assertFailure "the target handle was not captured") pure
                closed <- actualRead
                case closed of
                    Left (OwnershipProbeFailed _ _) -> pure ()
                    other -> assertFailure ("the interrupted wall retained its actual handle: " <> show other)
            ByteString.readFile target >>= (@?= beforeBytes)
            observeRowIdentity target >>= (@?= beforeIdentity)
            readActiveRecord location >>= (@?= beforeActive)
            recordEnvelopeSnapshot target >>= (@?= beforeRecords)
            if restoring
                then restoreGlobalWall ownershipRowForHost location wall >>= (@?= Right ())
                else do
                    retried <- applyGlobalWall ownershipRowForHost location wall >>= expectRightLabelled "retry interrupted apply"
                    persistedWallPhase (appliedWslConfigRecord retried) @?= WallApplied
                    restoreGlobalWall ownershipRowForHost location wall >>= (@?= Right ())
            ByteString.readFile target >>= (@?= original)
            observeRowIdentity target >>= (@?= originalIdentity)
            readActiveRecord location >>= (@?= Nothing)
            targetSiblings target >>= (@?= [])
    ]
