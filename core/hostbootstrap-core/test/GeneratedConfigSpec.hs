{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Locked-Origin Identity Ownership for the harness's generated sibling
@\<project\>.dhall@ (@development_plan_standards.md § EE@, Sprint 10.9).

These cases are the peer of "DataRootSpec" and are deliberately __not__
platform-gated: they drive the production driver and the production native
identity backend against a real filesystem and a real kernel, so every substrate
the suite runs on proves the same four clauses over a file. Each clause has a
case that fails when the clause is dropped:

* clause 1 is structural — every entry point demands a 'ProtectedSession', so
  there is no way to observe, create, or remove outside the exclusive entry;
* clause 2 — the origin record exists, and names the intended payload, before
  the file does;
* clause 3 — ownership names the created file's @device:inode@, so a
  same-named replacement is a different object;
* clause 4 — release re-observes that identity /and/ the payload, and refuses a
  replacement or an edit instead of deleting it.

The predecessor design — a @\<config\>.hostbootstrap-test-owner@ directory
holding the payload for a byte comparison — held none of these, and is recorded
in @DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md@.
-}
module GeneratedConfigSpec (tests) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import HostBootstrap.Harness.GeneratedConfig
import HostBootstrap.Harness.Identity (
    IdentityFault (IdentityUnsupported),
    ObjectIdentity,
    ObjectIdentityBackend (ObjectIdentityBackend),
    observeObjectIdentity,
 )
import HostBootstrap.Harness.Identity.Native (nativeObjectIdentityBackend)
import HostBootstrap.Protected
import System.Directory (doesFileExist, removeFile)
import System.FilePath ((</>))
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
                    acquired <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    generatedConfigOwnershipDigest acquired
                        @?= generatedConfigPayloadDigest payload
                    present <- doesFileExist path
                    assertBool "the generated config exists after acquisition" present
                    installed <- ByteString.readFile path
                    installed @?= payload
                    stored <- readRecordBytes session key
                    record <- expectRight (decodeGeneratedConfigRecord stored)
                    generatedConfigPayload record @?= generatedConfigPayloadDigest payload
                    generatedConfigManaged record
                        @?= Just (generatedConfigOwnershipManaged acquired)
            , testCase "the record retains the digest, never the config bytes" $
                withOwnership $ \session key path -> do
                    _ <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    stored <- readRecordBytes session key
                    assertBool
                        "no config content reaches the protected store"
                        (not ("project" `ByteString.isInfixOf` stored))
            , testCase "an unsettled record under the same key is a conflict, not an overwrite" $
                withOwnership $ \session key path -> do
                    _ <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    again <- acquireGeneratedConfig backend session key path payload
                    expectConflict "a second acquisition" again
            , testCase "the record round-trips through its codec" $ do
                let encoded =
                        encodeGeneratedConfigRecord
                            (GeneratedConfigRecord (generatedConfigPayloadDigest payload) Nothing)
                decodeGeneratedConfigRecord encoded
                    @?= Right
                        (GeneratedConfigRecord (generatedConfigPayloadDigest payload) Nothing)
            , testCase "a malformed record is refused, never guessed" $
                assertBool
                    "unknown magic is rejected"
                    ( case decodeGeneratedConfigRecord "nope\norigin absent\npayload ab\n" of
                        Left (GeneratedConfigMalformedRecord _) -> True
                        _ -> False
                    )
            ]
        , testGroup
            "clause 3 — ownership binds the kernel identity, not the name"
            [ testCase "the bound identity is the created file's own" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    observed <- observeIdentity path
                    generatedConfigOwnershipManaged acquired @?= observed
            , testCase "a same-named replacement has a different identity" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    removeFile path
                    ByteString.writeFile path payload
                    replaced <- observeIdentity path
                    assertBool
                        "the replacement is not the owned object"
                        (generatedConfigOwnershipManaged acquired /= replaced)
            , testCase "a backend without a stable identity mints no ownership" $
                withOwnership $ \session key path -> do
                    refused <- acquireGeneratedConfig unsupportedBackend session key path payload
                    case refused of
                        Left (GeneratedConfigUnsupported _) -> pure ()
                        other -> assertFailure ("expected Unsupported, got " <> show other)
                    created <- doesFileExist path
                    assertBool "no file was created" (not created)
            ]
        , testGroup
            "a found object is never adopted and never replaced"
            [ testCase "an existing config refuses before anything is recorded" $
                withOwnership $ \session key path -> do
                    ByteString.writeFile path "-- an operator's production config\n"
                    refused <- acquireGeneratedConfig backend session key path payload
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
                    acquired <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    released <- expectRight =<< releaseGeneratedConfig backend session key acquired
                    released @?= GeneratedConfigRemoved
                    present <- doesFileExist path
                    assertBool "the generated config is gone" (not present)
                    settled <- readProtectedRecord session key
                    settled @?= Right Nothing
            , testCase "an edited config is refused and left intact" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    ByteString.writeFile path "-- edited under the run\n"
                    refused <- releaseGeneratedConfig backend session key acquired
                    expectConflict "releasing an edited config" refused
                    survived <- ByteString.readFile path
                    survived @?= "-- edited under the run\n"
            , testCase "line-ending-only changes are still a different payload" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    let crlf =
                            ByteString.concatMap
                                (\byte -> if byte == 10 then "\r\n" else ByteString.singleton byte)
                                payload
                    ByteString.writeFile path crlf
                    refused <- releaseGeneratedConfig backend session key acquired
                    expectConflict "releasing a re-line-ended config" refused
                    survived <- ByteString.readFile path
                    survived @?= crlf
            , testCase "a replaced config is refused and left intact" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    removeFile path
                    ByteString.writeFile path payload
                    refused <- releaseGeneratedConfig backend session key acquired
                    expectConflict "releasing a replacement" refused
                    survived <- doesFileExist path
                    assertBool "the replacement is untouched" survived
            , testCase "a vanished config is refused rather than reported removed" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    removeFile path
                    refused <- releaseGeneratedConfig backend session key acquired
                    expectConflict "releasing an absent config" refused
            , testCase "a receipt cannot release another run's record" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    other <- expectRight (mkRecordKey "config.spec.other")
                    refused <- releaseGeneratedConfig backend session other acquired
                    expectConflict "a cross-record release" refused
                    present <- doesFileExist path
                    assertBool "the generated config is untouched" present
            ]
        , testGroup
            "recovery — an interrupted run's config resolves itself"
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
                                ( encodeGeneratedConfigRecord
                                    ( GeneratedConfigRecord
                                        (generatedConfigPayloadDigest payload)
                                        Nothing
                                    )
                                )
                    ByteString.writeFile path payload
                    recovered <- expectRight =<< recoverGeneratedConfig backend session key path
                    recovered @?= GeneratedConfigAbsenceRestored
                    present <- doesFileExist path
                    assertBool "generated content is not adopted" (not present)
                    settled <- readProtectedRecord session key
                    settled @?= Right Nothing
            , testCase "a kill after the identity binding restores absence too" $
                withOwnership $ \session key path -> do
                    _ <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    recovered <- expectRight =<< recoverGeneratedConfig backend session key path
                    recovered @?= GeneratedConfigAbsenceRestored
                    present <- doesFileExist path
                    assertBool "the abandoned config is gone" (not present)
            , testCase "a foreign replacement is refused, not restored" $
                withOwnership $ \session key path -> do
                    _ <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    removeFile path
                    ByteString.writeFile path "-- a stranger's config\n"
                    refused <- recoverGeneratedConfig backend session key path
                    expectConflict "recovering over a replacement" refused
                    survived <- ByteString.readFile path
                    survived @?= "-- a stranger's config\n"
            , testCase "an already-removed config settles cleanly" $
                withOwnership $ \session key path -> do
                    acquired <- expectRight =<< acquireGeneratedConfig backend session key path payload
                    _ <- expectRight =<< releaseGeneratedConfig backend session key acquired
                    recovered <- expectRight =<< recoverGeneratedConfig backend session key path
                    recovered @?= GeneratedConfigAlreadyAbsent
            , testCase "a run that died before creating the file settles cleanly" $
                withOwnership $ \session key path -> do
                    _ <-
                        expectRight
                            =<< compareAndSwapProtectedRecord
                                session
                                key
                                ExpectAbsent
                                ( encodeGeneratedConfigRecord
                                    ( GeneratedConfigRecord
                                        (generatedConfigPayloadDigest payload)
                                        Nothing
                                    )
                                )
                    recovered <- expectRight =<< recoverGeneratedConfig backend session key path
                    recovered @?= GeneratedConfigAlreadyAbsent
                    settled <- readProtectedRecord session key
                    settled @?= Right Nothing
            ]
        ]

-- Harness -----------------------------------------------------------------------

backend :: ObjectIdentityBackend
backend = nativeObjectIdentityBackend

{- | A host that cannot report a stable identity. § EE requires such a backend
to mint no ownership at all rather than fall back to a pathname.
-}
unsupportedBackend :: ObjectIdentityBackend
unsupportedBackend =
    ObjectIdentityBackend
        (\_ -> pure (Left (IdentityUnsupported "no stable object identity on this host")))

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
    observed <- observeObjectIdentity backend path
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

expectConflict :: (Show value) => String -> Either GeneratedConfigError value -> IO ()
expectConflict label outcome = case outcome of
    Left (GeneratedConfigConflict{}) -> pure ()
    other -> assertFailure (label <> ": expected a conflict, got " <> show other)
