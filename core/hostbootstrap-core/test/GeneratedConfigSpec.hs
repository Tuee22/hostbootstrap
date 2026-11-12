{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Locked-Origin Identity Ownership for the harness's generated sibling
@\<project\>.dhall@ (@development_plan_standards.md § EE@, the
four-ownership-clauses phase).

These cases are the peer of "DataRootSpec" and are deliberately __not__
platform-gated: they drive the production driver against the production row
'ownershipRowForHost' selects, a real filesystem, and a real kernel, so every
substrate the suite runs on proves the same four clauses over a file. Each
clause has a case that fails when the clause is dropped:

* clause 1 carries the protected entry's nominal provenance and uses its live
  owner-thread floor before protected access and typed ownership effects;
* clause 2 — the canonical origin record exists, and names the intended payload,
  before the file does;
* clause 3 — ownership names the created file's own kernel identity, so a
  same-named replacement is a different object;
* clause 4 — release re-observes that identity /and/ the payload, and refuses a
  replacement or an edit instead of deleting it.
-}
module GeneratedConfigSpec (tests) where

import Control.Concurrent (forkFinally, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (AsyncException (ThreadKilled), fromException)
import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import Expect (expectRight)
import HostBootstrap.Harness.GeneratedConfig
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    OwnershipFault (OwnershipProbeFailed),
    ObjectKind (OwnedFile),
    Origin (OriginAbsent),
    bindOriginRecord,
    mkPayload,
    originRecord,
    originRecordBinding,
    originRecordKind,
    parseOriginRecord,
    payloadDigest,
    payloadDigestText,
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
import System.Directory (doesFileExist, listDirectory, removeFile, renameFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

payload :: ByteString
payload = "let cfg = { project = \"demo\" } in cfg\n"

tests :: TestTree
tests =
    testGroup
        "GeneratedConfigSpec"
        [ testGroup "scoped payload read" scopedPayloadReadTests
        , testGroup
            "clause 2 — the durable origin record precedes the first write"
            [ testCase "the intended payload is recorded, then the file is created" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    generatedConfigOwnershipDigest acquired
                        @?= payloadDigest (mkPayload payload)
                    present <- doesFileExist path
                    assertBool "the generated config exists after acquisition" present
                    installed <- ByteString.readFile path
                    installed @?= payload
                    stored <- readRecordBytes session key
                    record <- expectRight (parseOriginRecord stored)
                    originRecordKind record @?= OwnedFile (payloadDigest (mkPayload payload))
                    originRecordBinding record
                        @?= Just (generatedConfigOwnershipManaged acquired)
            , testCase "the record retains the digest, never the config bytes" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    stored <- readRecordBytes session key
                    expected <-
                        expectRight
                            ( bindOriginRecord
                                (generatedConfigOwnershipManaged acquired)
                                (originRecord (OwnedFile (payloadDigest (mkPayload payload))) OriginAbsent)
                            )
                    stored @?= renderOriginRecord expected
            , testCase "an unsettled record under the same key is a conflict, not an overwrite" $
                withOwnership $ \session key path -> do
                    _ <- expectRight =<< acquireGeneratedConfig row session key path payload
                    again <- acquireGeneratedConfig row session key path payload
                    expectConflict "a second acquisition" again
            , testCase "the record round-trips through the one canonical codec" $ do
                let encoded =
                        renderOriginRecord
                            ( originRecord
                                (OwnedFile (payloadDigest (mkPayload payload)))
                                OriginAbsent
                            )
                fmap originRecordKind (parseOriginRecord encoded)
                    @?= Right (OwnedFile (payloadDigest (mkPayload payload)))
            , testCase "a malformed record is refused, never guessed" $
                withOwnership $ \session key path -> do
                    _ <-
                        expectRight
                            =<< compareAndSwapProtectedRecord
                                session
                                key
                                ExpectAbsent
                                "nope 1 file absent ab -\n"
                    refused <- recoverGeneratedConfig row session key path
                    case refused of
                        Left (GeneratedConfigMalformedRecord _) -> pure ()
                        other -> assertFailure ("expected a malformed record, got " <> show other)
            , testCase "the staging object is withdrawn once the file is published" $
                withOwnership $ \session key path -> do
                    _ <- expectRight =<< acquireGeneratedConfig row session key path payload
                    siblings <- listDirectory (takeDirectory path)
                    assertBool
                        ("no staging object survives publication: " <> show siblings)
                        (not (any (\name -> "hostbootstrap-staging" `isInfix` name) siblings))
            ]
        , testGroup
            "clause 3 — ownership binds the kernel identity, not the name"
            [ testCase "the bound identity is the created file's own" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    observed <- observeIdentity path
                    generatedConfigOwnershipManaged acquired @?= observed
            , testCase "a same-named replacement has a different identity" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    -- Keep the owned inode alive so the replacement cannot reuse it.
                    renameFile path (path <> "-original")
                    ByteString.writeFile path payload
                    replaced <- observeIdentity path
                    assertBool
                        "the replacement is not the owned object"
                        (generatedConfigOwnershipManaged acquired /= replaced)
            , testCase "a row that cannot hold the clauses mints no ownership" $
                withOwnership $ \session key path -> do
                    refused <- acquireGeneratedConfig unsupportedRow session key path payload
                    case refused of
                        Left (GeneratedConfigUnsupported _) -> pure ()
                        other -> assertFailure ("expected Unsupported, got " <> show other)
                    created <- doesFileExist path
                    assertBool "no file was created" (not created)
                    stored <- readProtectedRecord session key
                    stored @?= Right Nothing
            ]
        , testGroup
            "a found object is never adopted and never replaced"
            [ testCase "an existing config refuses before anything is recorded" $
                withOwnership $ \session key path -> do
                    ByteString.writeFile path "-- an operator's production config\n"
                    refused <- acquireGeneratedConfig row session key path payload
                    case refused of
                        Left (GeneratedConfigOccupied occupied) -> occupied @?= path
                        other -> assertFailure ("expected Occupied, got " <> show other)
                    kept <- ByteString.readFile path
                    kept @?= "-- an operator's production config\n"
                    stored <- readProtectedRecord session key
                    stored @?= Right Nothing
            ]
        , testGroup
            "clause 4 — release is conditional on identity and payload together"
            [ testCase "a config this run installed is removed" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    released <- expectRight =<< releaseGeneratedConfig row session key acquired
                    released @?= GeneratedConfigRemoved
                    present <- doesFileExist path
                    assertBool "the generated config is gone" (not present)
                    settled <- readProtectedRecord session key
                    settled @?= Right Nothing
            , testCase "an edited config is refused and left intact" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    ByteString.writeFile path "-- edited under the run\n"
                    before <- readRecordBytes session key
                    refused <- releaseGeneratedConfig row session key acquired
                    expectConflict "releasing an edited config" refused
                    survived <- ByteString.readFile path
                    survived @?= "-- edited under the run\n"
                    after <- readRecordBytes session key
                    after @?= before
            , testCase "the refusal names the payload it expected and the one it found" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    let edited = "-- edited under the run\n"
                    ByteString.writeFile path edited
                    before <- readRecordBytes session key
                    refused <- releaseGeneratedConfig row session key acquired
                    case refused of
                        Left failure@(GeneratedConfigConflict{}) -> do
                            let message = generatedConfigErrorMessage failure
                            assertBool
                                "the expected payload is named"
                                ( ("payload " <> payloadDigestText (payloadDigest (mkPayload payload)))
                                    `Text.isInfixOf` message
                                )
                            assertBool
                                "the observed payload is named"
                                ( ("payload " <> payloadDigestText (payloadDigest (mkPayload edited)))
                                    `Text.isInfixOf` message
                                )
                        other -> assertFailure ("expected a conflict, got " <> show other)
                    after <- readRecordBytes session key
                    after @?= before
            , testCase "line-ending-only changes are still a different payload" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    let crlf =
                            ByteString.concatMap
                                (\byte -> if byte == 10 then "\r\n" else ByteString.singleton byte)
                                payload
                    ByteString.writeFile path crlf
                    before <- readRecordBytes session key
                    refused <- releaseGeneratedConfig row session key acquired
                    expectConflict "releasing a re-line-ended config" refused
                    survived <- ByteString.readFile path
                    survived @?= crlf
                    after <- readRecordBytes session key
                    after @?= before
            , testCase "a replaced config is refused and left intact" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    renameFile path (path <> "-original")
                    ByteString.writeFile path payload
                    before <- readRecordBytes session key
                    refused <- releaseGeneratedConfig row session key acquired
                    expectConflict "releasing a replacement" refused
                    survived <- doesFileExist path
                    assertBool "the replacement is untouched" survived
                    after <- readRecordBytes session key
                    after @?= before
            , testCase "a vanished config is refused rather than reported removed" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    removeFile path
                    before <- readRecordBytes session key
                    refused <- releaseGeneratedConfig row session key acquired
                    expectConflict "releasing an absent config" refused
                    after <- readRecordBytes session key
                    after @?= before
            , testCase "a receipt cannot release another run's record" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    other <- expectRight (mkRecordKey "config.spec.other")
                    bytes <- readRecordBytes session key
                    _ <- expectRight =<< compareAndSwapProtectedRecord session other ExpectAbsent bytes
                    before <- readRecordBytes session key
                    refused <- releaseGeneratedConfig row session other acquired
                    expectConflict "a cross-record release" refused
                    case refused of
                        Left (GeneratedConfigConflict _ _ observed) ->
                            assertBool "the key guard refused" ("release attempted under" `Text.isPrefixOf` observed)
                        otherResult -> assertFailure ("expected key conflict, got " <> show otherResult)
                    otherAfter <- readRecordBytes session other
                    otherAfter @?= bytes
                    present <- doesFileExist path
                    assertBool "the generated config is untouched" present
                    after <- readRecordBytes session key
                    after @?= before
            ]
        , testGroup
            "recovery — the recorded origin is the authority"
            [ testCase "a kill after the origin record but before the identity binding restores absence" $
                withOwnership $ \session key path -> do
                    -- Exactly the crash window: the payload digest is recorded,
                    -- the file exists, and no identity was ever bound.
                    _ <-
                        expectRight
                            =<< compareAndSwapProtectedRecord
                                session
                                key
                                ExpectAbsent
                                ( renderOriginRecord
                                    ( originRecord
                                        (OwnedFile (payloadDigest (mkPayload payload)))
                                        OriginAbsent
                                    )
                                )
                    let staging = recordedStagingPath key path
                    ByteString.writeFile staging payload
                    ByteString.writeFile path payload
                    recovered <- expectRight =<< recoverGeneratedConfig row session key path
                    recovered @?= GeneratedConfigAbsenceRestored
                    present <- doesFileExist path
                    assertBool "generated content is not adopted" (not present)
                    settled <- readProtectedRecord session key
                    settled @?= Right Nothing
                    staged <- doesFileExist staging
                    assertBool "the staging object is withdrawn" (not staged)
            , testCase "a kill in that window over foreign bytes is refused, not adopted" $
                withOwnership $ \session key path -> do
                    _ <-
                        expectRight
                            =<< compareAndSwapProtectedRecord
                                session
                                key
                                ExpectAbsent
                                ( renderOriginRecord
                                    ( originRecord
                                        (OwnedFile (payloadDigest (mkPayload payload)))
                                        OriginAbsent
                                    )
                                )
                    ByteString.writeFile path "-- a stranger's config\n"
                    before <- readRecordBytes session key
                    refused <- recoverGeneratedConfig row session key path
                    expectConflict "recovering over foreign bytes" refused
                    survived <- ByteString.readFile path
                    survived @?= "-- a stranger's config\n"
                    after <- readRecordBytes session key
                    after @?= before
            , testCase "a kill after the identity binding restores absence too" $
                withOwnership $ \session key path -> do
                    _ <- expectRight =<< acquireGeneratedConfig row session key path payload
                    recovered <- expectRight =<< recoverGeneratedConfig row session key path
                    recovered @?= GeneratedConfigAbsenceRestored
                    present <- doesFileExist path
                    assertBool "the abandoned config is gone" (not present)
                    settled <- readProtectedRecord session key
                    settled @?= Right Nothing
            , testCase "a foreign replacement is refused, not restored" $
                withOwnership $ \session key path -> do
                    _ <- expectRight =<< acquireGeneratedConfig row session key path payload
                    renameFile path (path <> "-original")
                    ByteString.writeFile path "-- a stranger's config\n"
                    before <- readRecordBytes session key
                    refused <- recoverGeneratedConfig row session key path
                    expectConflict "recovering over a replacement" refused
                    survived <- ByteString.readFile path
                    survived @?= "-- a stranger's config\n"
                    after <- readRecordBytes session key
                    after @?= before
            , testCase "an already-removed config settles cleanly" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    _ <- expectRight =<< releaseGeneratedConfig row session key acquired
                    recovered <- expectRight =<< recoverGeneratedConfig row session key path
                    recovered @?= GeneratedConfigAlreadyAbsent
            , testCase "a bound record whose file is gone settles and withdraws remaining staging" $
                withOwnership $ \session key path -> do
                    _ <- expectRight =<< acquireGeneratedConfig row session key path payload
                    removeFile path
                    let staging = recordedStagingPath key path
                    ByteString.writeFile staging payload
                    recovered <- expectRight =<< recoverGeneratedConfig row session key path
                    recovered @?= GeneratedConfigAlreadyAbsent
                    settled <- readProtectedRecord session key
                    settled @?= Right Nothing
                    staged <- doesFileExist staging
                    assertBool "staging is withdrawn before settlement" (not staged)
            , testCase "a same-bytes replacement after the crash-window payload read is refused" $
                withOwnership $ \session key path -> do
                    recordUnboundAbsence session key
                    ByteString.writeFile path payload
                    original <- observeIdentity path
                    before <- readRecordBytes session key
                    withOwnershipRow row $ \primitives -> do
                        let raced =
                                ownershipRow
                                    primitives
                                        { rowReadObject = \handle -> do
                                            contents <- rowReadObject primitives handle
                                            renameFile path (path <> "-read-original")
                                            ByteString.writeFile path payload
                                            pure contents
                                        }
                        refused <- recoverGeneratedConfig raced session key path
                        expectConflict "recovering over a same-bytes atomic replacement" refused
                    replacement <- observeIdentity path
                    assertBool "the two live identities differ" (original /= replacement)
                    survived <- ByteString.readFile path
                    survived @?= payload
                    after <- readRecordBytes session key
                    after @?= before
            , testCase "an unpublished staging file is withdrawn before settling absent target" $
                withOwnership $ \session key path -> do
                    recordUnboundAbsence session key
                    let staging = recordedStagingPath key path
                    ByteString.writeFile staging payload
                    recovered <- expectRight =<< recoverGeneratedConfig row session key path
                    recovered @?= GeneratedConfigAlreadyAbsent
                    settled <- readProtectedRecord session key
                    settled @?= Right Nothing
                    staged <- doesFileExist staging
                    assertBool "unpublished staging is gone" (not staged)
            , testCase "a run that died before creating the file settles cleanly" $
                withOwnership $ \session key path -> do
                    _ <-
                        expectRight
                            =<< compareAndSwapProtectedRecord
                                session
                                key
                                ExpectAbsent
                                ( renderOriginRecord
                                    ( originRecord
                                        (OwnedFile (payloadDigest (mkPayload payload)))
                                        OriginAbsent
                                    )
                                )
                    recovered <- expectRight =<< recoverGeneratedConfig row session key path
                    recovered @?= GeneratedConfigAlreadyAbsent
                    settled <- readProtectedRecord session key
                    settled @?= Right Nothing
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
            { rowCapabilities = OwnershipCapabilities False False False
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

{- | Run one case inside a fresh store's exclusive entry, with a generated-config
path under the same temporary directory. The fixture keeps the actual entry
live on its owning thread for the complete operation.
-}
withOwnership ::
    ( forall session.
      ProtectedSession session ->
      RecordKey ->
      FilePath ->
      IO ()
    ) ->
    IO ()
withOwnership action =
    withSystemTempDirectory "hb-genconfig" $ \root -> do
        store <- expectRight =<< openProtectedStore (root </> "authority")
        key <- expectRight (mkRecordKey "config.hostbootstrap-spec.run-1")
        outcome <-
            withProtectedEntry store $ \session ->
                Right <$> action session key (root </> "demo.dhall")
        either (assertFailure . show) pure outcome

observeIdentity :: FilePath -> IO ObjectIdentity
observeIdentity path = do
    observed <- withOwnershipRow row (\primitives -> rowObserveIdentity primitives path)
    case observed of
        Right (Just identity) -> pure identity
        other -> assertFailure ("expected an identity, got " <> show other)

-- | Whether one sequence occurs inside another, for the staging-name assertion.
isInfix :: (Eq element) => [element] -> [element] -> Bool
isInfix needle haystack =
    any (\suffix -> take (length needle) suffix == needle) (suffixes haystack)
  where
    suffixes [] = [[]]
    suffixes value@(_ : rest) = value : suffixes rest

readRecordBytes :: ProtectedSession session -> RecordKey -> IO ByteString
readRecordBytes session key = do
    stored <- readProtectedRecord session key
    case stored of
        Right (Just record) -> pure (protectedRecordBytes record)
        other -> assertFailure ("expected a stored record, got " <> show other)

recordUnboundAbsence :: ProtectedSession session -> RecordKey -> IO ()
recordUnboundAbsence session key = do
    _ <-
        expectRight
            =<< compareAndSwapProtectedRecord
                session
                key
                ExpectAbsent
                (renderOriginRecord (originRecord (OwnedFile (payloadDigest (mkPayload payload))) OriginAbsent))
    pure ()

recordedStagingPath :: RecordKey -> FilePath -> FilePath
recordedStagingPath key path =
    takeDirectory path </> ("." <> Text.unpack (recordKeyText key) <> ".hostbootstrap-staging")

expectConflict :: (Show value) => String -> Either GeneratedConfigError value -> IO ()
expectConflict label outcome = case outcome of
    Left (GeneratedConfigConflict{}) -> pure ()
    other -> assertFailure (label <> ": expected a conflict, got " <> show other)

-- Both operations own their protected entry on the interrupted worker.
scopedPayloadReadTests :: [TestTree]
scopedPayloadReadTests =
    [ testCase "interrupted release and recovery close their handle and preserve retryable evidence" $
        for_ [False, True] $ \recovering ->
            withSystemTempDirectory "hb-genconfig-scoped-read" $ \root -> do
                store <- openProtectedStore (root </> "authority") >>= expectRight
                key <- expectRight (mkRecordKey "config.scoped-read.run-1")
                let path = root </> "demo.dhall"
                acquiredResult <- withProtectedEntry store $ \session ->
                    Right <$> acquireGeneratedConfig row session key path payload
                acquired <- expectRight acquiredResult >>= expectRight
                beforeIdentity <- observeIdentity path
                before <- withProtectedEntry store (\session -> readProtectedRecord session key) >>= expectRight
                assertBool "an actual protected envelope exists" (case before of Just _ -> True; Nothing -> False)
                withOwnershipRow row $ \primitives -> do
                    probe <- newIORef Nothing
                    targetRead <- newIORef False
                    ready <- newEmptyMVar
                    gate <- newEmptyMVar
                    completed <- newEmptyMVar
                    let interrupted = ownershipRow (primitives
                            { rowOpenExclusive = \target -> do
                                opened <- rowOpenExclusive primitives target
                                case opened of
                                    Left fault -> pure (Left fault)
                                    Right handle -> do
                                        writeIORef targetRead (target == path)
                                        if target == path
                                            then writeIORef probe (Just (rowReadObject primitives handle))
                                            else pure ()
                                        pure (Right handle)
                            , rowReadObject = \handle -> do
                                contents <- rowReadObject primitives handle
                                isTarget <- readIORef targetRead
                                if isTarget
                                    then do
                                        contents @?= Right payload
                                        putMVar ready ()
                                        takeMVar gate >>= \() -> pure contents
                                    else pure contents
                            })
                        operation session =
                            if recovering
                                then fmap (fmap (const ())) (recoverGeneratedConfig interrupted session key path)
                                else fmap (fmap (const ())) (releaseGeneratedConfig interrupted session key acquired)
                    worker <- forkFinally
                        (withProtectedEntry store (\session -> Right <$> operation session))
                        (\outcome -> do
                            _ <- tryPutMVar ready ()
                            putMVar completed outcome)
                    takeMVar ready
                    throwTo worker ThreadKilled
                    outcome <- takeMVar completed
                    case outcome of
                        Left failure -> (fromException failure :: Maybe AsyncException) @?= Just ThreadKilled
                        Right other -> assertFailure ("the interrupted config read returned: " <> show other)
                    actualRead <- readIORef probe >>= maybe (assertFailure "the actual config handle was not retained") pure
                    closed <- actualRead
                    case closed of
                        Left (OwnershipProbeFailed _ _) -> pure ()
                        other -> assertFailure ("the config retained its actual handle: " <> show other)
                ByteString.readFile path >>= (@?= payload)
                observeIdentity path >>= (@?= beforeIdentity)
                after <- withProtectedEntry store (\session -> readProtectedRecord session key) >>= expectRight
                after @?= before
                retried <- withProtectedEntry store $ \session -> do
                    if recovering
                        then recoverGeneratedConfig row session key path >>= (@?= Right GeneratedConfigAbsenceRestored)
                        else releaseGeneratedConfig row session key acquired >>= (@?= Right GeneratedConfigRemoved)
                    readProtectedRecord session key >>= (@?= Right Nothing)
                    pure (Right ())
                expectRight retried
                doesFileExist path >>= (@?= False)
                doesFileExist (recordedStagingPath key path) >>= (@?= False)
    ]
