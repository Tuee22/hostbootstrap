{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Locked-Origin Identity Ownership for the harness data root
(@development_plan_standards.md § EE@, the test-harness-and-run-ownership phase).

These cases are deliberately __not__ platform-gated: they drive the production
driver and the production native identity backend against a real filesystem and
a real kernel, so every substrate the suite runs on proves the same four
clauses. Each clause has a case that fails when the clause is dropped:

* clause 1 is structural — every entry point demands a 'ProtectedSession', so
  there is no way to observe, create, or remove outside the exclusive entry;
* clause 2 — the origin record exists, and names the exact prior state, before
  the directory does;
* clause 3 — ownership names the created directory's @device:inode@, so a
  same-named replacement is a different object;
* clause 4 — release re-observes that identity and refuses a replacement
  instead of deleting it.
-}
module DataRootSpec (tests) where

import Data.ByteString (ByteString)
import HostBootstrap.Harness.DataRoot
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    ObjectKind (OwnedDirectory),
    originRecord,
    originRecordBinding,
    originRecordOrigin,
    parseOriginRecord,
    renderOriginRecord,
 )
import HostBootstrap.Ownership.Primitive (
    OwnershipCapabilities (OwnershipCapabilities),
    OwnershipPrimitive (..),
    OwnershipRow,
    ownershipRow,
    rowObserveIdentity,
    withOwnershipRow,
 )
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Protected
import System.Directory (
    createDirectory,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    removeDirectoryRecursive,
 )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "DataRootSpec"
        [ testGroup
            "clause 2 — the durable origin record precedes the first write"
            [ testCase "an absent origin is recorded, then the directory is created" $
                withOwnership $ \_ session key path -> do
                    acquired <- expectRight =<< acquireDataRoot row session key path
                    dataRootOwnershipOrigin acquired @?= OriginAbsent
                    present <- doesDirectoryExist path
                    assertBool "the data root exists after acquisition" present
                    stored <- readRecordBytes session key
                    record <- expectRight (parseOriginRecord stored)
                    originRecordOrigin record @?= OriginAbsent
                    assertBool
                        "the created identity is journalled"
                        (originRecordBinding record == dataRootOwnershipManaged acquired)
                    assertBool "an identity was bound" (originRecordBinding record /= Nothing)
            , testCase "a pre-existing directory is recorded by its identity and never adopted" $
                withOwnership $ \_ session key path -> do
                    createDirectoryIfMissing True path
                    found <- observeIdentity path
                    acquired <- expectRight =<< acquireDataRoot row session key path
                    dataRootOwnershipOrigin acquired @?= OriginPresent found
                    dataRootOwnershipManaged acquired @?= Nothing
            , testCase "an unsettled record under the same key is a conflict, not an overwrite" $
                withOwnership $ \_ session key path -> do
                    _ <- expectRight =<< acquireDataRoot row session key path
                    again <- acquireDataRoot row session key path
                    expectConflict "a second acquisition" again
            , testCase "the record round-trips through the one canonical codec" $ do
                let encoded = renderOriginRecord (originRecord OwnedDirectory OriginAbsent)
                fmap originRecordOrigin (parseOriginRecord encoded) @?= Right OriginAbsent
            , testCase "a malformed record is refused, never guessed" $
                assertBool
                    "unknown magic is rejected"
                    ( case parseOriginRecord "nope 1 directory absent - -\n" of
                        Left _ -> True
                        _ -> False
                    )
            ]
        , testGroup
            "clause 3 — ownership binds the kernel identity, not the name"
            [ testCase "the bound identity is the created directory's own" $
                withOwnership $ \_ session key path -> do
                    acquired <- expectRight =<< acquireDataRoot row session key path
                    observed <- observeIdentity path
                    dataRootOwnershipManaged acquired @?= Just observed
            , testCase "a same-named replacement has a different identity" $
                withOwnership $ \_ session key path -> do
                    acquired <- expectRight =<< acquireDataRoot row session key path
                    removeDirectoryRecursive path
                    createDirectory path
                    replaced <- observeIdentity path
                    assertBool
                        "the replacement is not the owned object"
                        (dataRootOwnershipManaged acquired /= Just replaced)
            , testCase "a row without a stable identity mints no ownership" $
                withOwnership $ \_ session key path -> do
                    refused <- acquireDataRoot unsupportedRow session key path
                    case refused of
                        Left (DataRootUnsupported _) -> pure ()
                        other -> assertFailure ("expected Unsupported, got " <> show other)
                    created <- doesDirectoryExist path
                    assertBool "no directory was created" (not created)
            ]
        , testGroup
            "clause 4 — release is conditional on re-observing that identity"
            [ testCase "a directory this run created is removed" $
                withOwnership $ \_ session key path -> do
                    acquired <- expectRight =<< acquireDataRoot row session key path
                    released <- expectRight =<< releaseDataRoot row session key acquired
                    released @?= DataRootRemoved
                    present <- doesDirectoryExist path
                    assertBool "the data root is gone" (not present)
                    settled <- readProtectedRecord session key
                    settled @?= Right Nothing
            , testCase "a directory this run found is preserved" $
                withOwnership $ \_ session key path -> do
                    createDirectoryIfMissing True path
                    writeFile (path </> "operator.txt") "keep me"
                    acquired <- expectRight =<< acquireDataRoot row session key path
                    released <- expectRight =<< releaseDataRoot row session key acquired
                    released @?= DataRootPreserved
                    kept <- doesFileExist (path </> "operator.txt")
                    assertBool "the operator's content survives" kept
            , testCase "a replaced directory is refused and left intact" $
                withOwnership $ \_ session key path -> do
                    acquired <- expectRight =<< acquireDataRoot row session key path
                    removeDirectoryRecursive path
                    createDirectory path
                    writeFile (path </> "stranger.txt") "not yours"
                    refused <- releaseDataRoot row session key acquired
                    expectConflict "releasing a replacement" refused
                    survived <- doesFileExist (path </> "stranger.txt")
                    assertBool "the replacement is untouched" survived
            , testCase "a vanished directory is refused rather than reported removed" $
                withOwnership $ \_ session key path -> do
                    acquired <- expectRight =<< acquireDataRoot row session key path
                    removeDirectoryRecursive path
                    refused <- releaseDataRoot row session key acquired
                    expectConflict "releasing an absent root" refused
            , testCase "a receipt cannot release another run's record" $
                withOwnership $ \store session key path -> do
                    acquired <- expectRight =<< acquireDataRoot row session key path
                    other <- expectRight (mkRecordKey "dataroot.spec.other")
                    refused <- releaseDataRoot row session other acquired
                    expectConflict "a cross-record release" refused
                    _ <- pure store
                    present <- doesDirectoryExist path
                    assertBool "the data root is untouched" present
            ]
        , testGroup
            "recovery — the recorded origin is the authority"
            [ testCase "a kill after the origin record but before the identity binding restores absence" $
                withOwnership $ \_ session key path -> do
                    -- Exactly the crash window: the origin says absent, the
                    -- directory exists, and no managed identity was ever bound.
                    _ <-
                        expectRight
                            =<< compareAndSwapProtectedRecord
                                session
                                key
                                ExpectAbsent
                                (renderOriginRecord (originRecord OwnedDirectory OriginAbsent))
                    createDirectory path
                    writeFile (path </> "generated.txt") "from the dead run"
                    recovered <- expectRight =<< recoverDataRoot row session key path
                    recovered @?= DataRootAbsenceRestored
                    present <- doesDirectoryExist path
                    assertBool "generated content is not adopted" (not present)
                    settled <- readProtectedRecord session key
                    settled @?= Right Nothing
            , testCase "a kill after the identity binding restores absence too" $
                withOwnership $ \_ session key path -> do
                    _ <- expectRight =<< acquireDataRoot row session key path
                    recovered <- expectRight =<< recoverDataRoot row session key path
                    recovered @?= DataRootAbsenceRestored
                    present <- doesDirectoryExist path
                    assertBool "the abandoned generation is gone" (not present)
            , testCase "a foreign replacement is refused, not restored" $
                withOwnership $ \_ session key path -> do
                    _ <- expectRight =<< acquireDataRoot row session key path
                    removeDirectoryRecursive path
                    createDirectory path
                    writeFile (path </> "stranger.txt") "not yours"
                    refused <- recoverDataRoot row session key path
                    expectConflict "recovering over a replacement" refused
                    survived <- doesFileExist (path </> "stranger.txt")
                    assertBool "the replacement is untouched" survived
            , testCase "an absent-original run whose directory is already gone settles cleanly" $
                withOwnership $ \_ session key path -> do
                    acquired <- expectRight =<< acquireDataRoot row session key path
                    _ <- expectRight =<< releaseDataRoot row session key acquired
                    recovered <- expectRight =<< recoverDataRoot row session key path
                    recovered @?= DataRootAlreadyAbsent
            , testCase "a recorded pre-existing directory is preserved by recovery" $
                withOwnership $ \_ session key path -> do
                    createDirectoryIfMissing True path
                    writeFile (path </> "operator.txt") "keep me"
                    _ <- expectRight =<< acquireDataRoot row session key path
                    recovered <- expectRight =<< recoverDataRoot row session key path
                    recovered @?= DataRootFoundStatePreserved
                    kept <- doesFileExist (path </> "operator.txt")
                    assertBool "the operator's content survives recovery" kept
            ]
        ]

-- Harness -----------------------------------------------------------------------

-- | The production row for this host, which is what the bracket itself selects.
row :: OwnershipRow
row = ownershipRowForHost

{- | A host that cannot hold the clauses. § EE requires such a row to mint no
ownership at all rather than fall back to a pathname, and the refusal follows
from the declaration alone — every primitive below diverges, so a driver that
reached one would not finish.
-}
unsupportedRow :: OwnershipRow
unsupportedRow =
    ownershipRow
        OwnershipPrimitive
            { rowCapabilities = OwnershipCapabilities False False False False
            , rowObserveIdentity = unreachable
            , rowOpenExclusive = unreachable
            , rowCreateDirectory = unreachable
            , rowCreateFile = \_ -> unreachable
            , rowLinkNoReplace = \_ -> unreachable
            , rowReadObject = unreachable
            , rowRemoveObject = unreachable
            , rowCloseHandle = unreachable
            , rowSyncParent = unreachable
            }
  where
    unreachable :: argument -> IO result
    unreachable _ = error "a refused clause reached the kernel"

{- | Run one case inside a fresh store's exclusive entry, with a data-root path
under the same temporary directory. Taking the entry here is what makes clause 1
structural for every case below: none of the driver's operations is reachable
without it.
-}
withOwnership ::
    ( forall session.
      ProtectedStore ->
      ProtectedSession session ->
      RecordKey ->
      FilePath ->
      IO ()
    ) ->
    IO ()
withOwnership action =
    withSystemTempDirectory "hb-dataroot" $ \root -> do
        store <- expectRight =<< openProtectedStore (root </> "authority")
        key <- expectRight (mkRecordKey "dataroot.hostbootstrap-spec.run-1")
        outcome <-
            withProtectedEntry store $ \session ->
                Right <$> action store session key (root </> ".test_data")
        either (assertFailure . show) pure outcome

observeIdentity :: FilePath -> IO ObjectIdentity
observeIdentity path = do
    observed <- withOwnershipRow row (\primitives -> rowObserveIdentity primitives path)
    case observed of
        Right (Just identity) -> pure identity
        other -> assertFailure ("expected an identity, got " <> show other)

readRecordBytes :: ProtectedSession session -> RecordKey -> IO ByteString
readRecordBytes session key = do
    stored <- readProtectedRecord session key
    case stored of
        Right (Just record) -> pure (protectedRecordBytes record)
        other -> assertFailure ("expected a stored record, got " <> show other)

expectRight :: (Show failure) => Either failure value -> IO value
expectRight = either (assertFailure . show) pure

expectConflict :: (Show value) => String -> Either DataRootError value -> IO ()
expectConflict label outcome = case outcome of
    Left (DataRootConflict{}) -> pure ()
    other -> assertFailure (label <> ": expected a conflict, got " <> show other)
