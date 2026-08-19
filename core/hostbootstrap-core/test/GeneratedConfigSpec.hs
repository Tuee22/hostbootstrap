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

* clause 1 is structural — every entry point demands a 'ProtectedSession', so
  there is no way to observe, create, or remove outside the exclusive entry;
* clause 2 — the canonical origin record exists, and names the intended payload,
  before the file does;
* clause 3 — ownership names the created file's own kernel identity, so a
  same-named replacement is a different object;
* clause 4 — release re-observes that identity /and/ the payload, and refuses a
  replacement or an edit instead of deleting it.
-}
module GeneratedConfigSpec (tests) where

import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.ByteString as ByteString
import HostBootstrap.Harness.GeneratedConfig
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    ObjectKind (OwnedFile),
    Origin (OriginAbsent),
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
import System.Directory (doesFileExist, listDirectory, removeFile)
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
        [ testGroup
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
                    _ <- expectRight =<< acquireGeneratedConfig row session key path payload
                    stored <- readRecordBytes session key
                    assertBool
                        "no config content reaches the protected store"
                        (not ("project" `ByteString.isInfixOf` stored))
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
                    removeFile path
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
                    refused <- releaseGeneratedConfig row session key acquired
                    expectConflict "releasing an edited config" refused
                    survived <- ByteString.readFile path
                    survived @?= "-- edited under the run\n"
            , testCase "the refusal names the payload it expected and the one it found" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    let edited = "-- edited under the run\n"
                    ByteString.writeFile path edited
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
            , testCase "line-ending-only changes are still a different payload" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    let crlf =
                            ByteString.concatMap
                                (\byte -> if byte == 10 then "\r\n" else ByteString.singleton byte)
                                payload
                    ByteString.writeFile path crlf
                    refused <- releaseGeneratedConfig row session key acquired
                    expectConflict "releasing a re-line-ended config" refused
                    survived <- ByteString.readFile path
                    survived @?= crlf
            , testCase "a replaced config is refused and left intact" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    removeFile path
                    ByteString.writeFile path payload
                    refused <- releaseGeneratedConfig row session key acquired
                    expectConflict "releasing a replacement" refused
                    survived <- doesFileExist path
                    assertBool "the replacement is untouched" survived
            , testCase "a vanished config is refused rather than reported removed" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    removeFile path
                    refused <- releaseGeneratedConfig row session key acquired
                    expectConflict "releasing an absent config" refused
            , testCase "a receipt cannot release another run's record" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    other <- expectRight (mkRecordKey "config.spec.other")
                    refused <- releaseGeneratedConfig row session other acquired
                    expectConflict "a cross-record release" refused
                    present <- doesFileExist path
                    assertBool "the generated config is untouched" present
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
                    ByteString.writeFile path payload
                    recovered <- expectRight =<< recoverGeneratedConfig row session key path
                    recovered @?= GeneratedConfigAbsenceRestored
                    present <- doesFileExist path
                    assertBool "generated content is not adopted" (not present)
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
                    refused <- recoverGeneratedConfig row session key path
                    expectConflict "recovering over foreign bytes" refused
                    survived <- ByteString.readFile path
                    survived @?= "-- a stranger's config\n"
            , testCase "a kill after the identity binding restores absence too" $
                withOwnership $ \session key path -> do
                    _ <- expectRight =<< acquireGeneratedConfig row session key path payload
                    recovered <- expectRight =<< recoverGeneratedConfig row session key path
                    recovered @?= GeneratedConfigAbsenceRestored
                    present <- doesFileExist path
                    assertBool "the abandoned config is gone" (not present)
            , testCase "a foreign replacement is refused, not restored" $
                withOwnership $ \session key path -> do
                    _ <- expectRight =<< acquireGeneratedConfig row session key path payload
                    removeFile path
                    ByteString.writeFile path "-- a stranger's config\n"
                    refused <- recoverGeneratedConfig row session key path
                    expectConflict "recovering over a replacement" refused
                    survived <- ByteString.readFile path
                    survived @?= "-- a stranger's config\n"
            , testCase "an already-removed config settles cleanly" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig row session key path payload
                    _ <- expectRight =<< releaseGeneratedConfig row session key acquired
                    recovered <- expectRight =<< recoverGeneratedConfig row session key path
                    recovered @?= GeneratedConfigAlreadyAbsent
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

{- | Run one case inside a fresh store's exclusive entry, with a generated-config
path under the same temporary directory. Taking the entry here is what makes
clause 1 structural for every case below: none of the driver's operations is
reachable without it.
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

-- | Whether one sequence occurs inside another, for the two textual assertions.
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

expectRight :: (Show failure) => Either failure value -> IO value
expectRight = either (assertFailure . show) pure

expectConflict :: (Show value) => String -> Either GeneratedConfigError value -> IO ()
expectConflict label outcome = case outcome of
    Left (GeneratedConfigConflict{}) -> pure ()
    other -> assertFailure (label <> ": expected a conflict, got " <> show other)
