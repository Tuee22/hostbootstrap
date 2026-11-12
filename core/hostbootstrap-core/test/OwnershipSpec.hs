{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The ownership seam's capabilities, source boundary and operational lifetime.

The classifier is exercised by applying the real total function to every one of
the eight capability combinations. Divergent primitives and callbacks prove
refusal ordering, separately from any claim about kernel success.

Reported producers and their shared steps are checked as a bounded source
property. Compiler fixtures hold both nominal indices and stored-read provenance.
Real host-row cases exercise exclusive staging/publication, identity and fault
preservation, and an actual owned file proves expired/foreign-thread release
preserves its namespace and protected envelope before a live retry settles it.
-}
module OwnershipSpec (tests) where

import qualified Expect as OwnershipFixture
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar, throwTo, tryPutMVar)
import Control.Exception (AssertionFailed (..), AsyncException (ThreadKilled), IOException, MaskingState (Unmasked), SomeException, fromException, getMaskingState, throwIO, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Foldable (for_, traverse_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Ownership.Clause (Bound, Recorded, boundEvidence, recordedEvidence)
import HostBootstrap.Ownership.Object (
    ConflictReport (ConflictReport, conflictExpected, conflictObserved, conflictSubject),
    ObjectIdentity,
    Payload,
    ObjectKind (OwnedDirectory, OwnedFile, ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OriginRecord,
    OwnershipFault (OwnershipConflict, OwnershipMalformed, OwnershipOccupied, OwnershipProbeFailed, OwnershipUnsupported),
    bindOriginRecord,
    mkObjectIdentity,
    mkOwnerClaim,
    mkPayload,
    originRecord,
    originRecordBinding,
    originRecordKind,
    originRecordOrigin,
    ownershipFaultMessage,
    payloadDigest,
    parseOriginRecord,
    renderOriginRecord,
    storeFault,
 )
import HostBootstrap.Ownership.Primitive
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Ownership.Tape (
    OwnershipCarrier (..),
    RecordTape,
    readStoredRecordUnder,
    storedOriginRecord,
    storedRecordVersion,
    RecordSubject (RecordSubject, subjectBinding, subjectRecord),
    forgetRecord,
    forgetRecordAtVersion,
    publishBoundRecord,
    publishFreshRecord,
    recordTape,
    readRecordUnder,
    readVersionedRecordUnder,
    readRawRecordUnder,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError (..),
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    compareAndSwapProtectedRecord,
    readProtectedRecord,
    recordKeyText,
    recordVersionWord,
    sessionStoreRoot,
    protectedErrorMessage,
    ProtectedSession,
    RecordKey,
    RecordVersion,
    mkRecordKey,
    openProtectedStore,
    withProtectedEntry,
    verifyProtectedSession,
 )
import qualified SourceGuard
import System.Directory (createDirectory, doesDirectoryExist, doesPathExist, getCurrentDirectory)
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (ioeGetErrorString)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "OwnershipSpec"
        [ testGroup "scoped read caller adoption" scopedReadAdoptionTests
        , testGroup "the scoped whole-object read" wholeObjectReadTests
        , testGroup "the live ownership entry" entryLifetimeTests
        , testGroup "the capability classifier" classifierTests
        , testGroup "a row that cannot hold a clause" refusalTests
        , testGroup "mutating capability gates" capabilityGateTests
        , testGroup "re-entering an owned object" reentryTests
        , testGroup "stored origin re-entry" storedReentryTests
        , testGroup "stored caller adoptions" storedCallerAdoptionTests
        , testGroup "creating only from recorded absence" creatingOriginTests
        , testGroup "identity-conditional act" identityActTests
        , testGroup "the reported observation" reportedTests
        , testGroup "the seam's shape" seamTests
        , testGroup "the shared record tape" tapeTests
        , testGroup "each shared ownership computation has one definition site" computationSiteTests
        ]

-- ---------------------------------------------------------------------------
-- The classifier

classifierTests :: [TestTree]
classifierTests =
    [ testCase "a row that holds everything owes no refusal" $
        traverse_
            (\clause -> clauseRefusal fullCapabilities clause @?= Nothing)
            [minBound .. maxBound]
    , testCase "each clause refuses exactly when a capability it needs is absent" $ do
        length everyCapability @?= 8
        for_ everyCapability $ \capabilities -> do
            let refuses clause = isJust (clauseRefusal capabilities clause)
                identity = holdsStableIdentity capabilities
                parent = holdsDurableParentSync capabilities
                publication = holdsNoReplacePublication capabilities
            refuses ClauseEnter @?= not identity
            refuses ClauseRecord @?= not (identity && parent)
            refuses ClauseBind @?= not (identity && publication)
            refuses ClauseRelease @?= not identity
    , testCase "a refusal names the clause and every capability it is missing" $ do
        let message clause = fmap ownershipFaultMessage (clauseRefusal noCapabilities clause)
        message ClauseEnter
            @?= Just
                ( "this host cannot hold ownership clause 1 (exclusive entry):"
                    <> " it supplies no stable object identity"
                )
        message ClauseRecord
            @?= Just
                ( "this host cannot hold ownership clause 2 (durable origin record):"
                    <> " it supplies no stable object identity, no durable parent directory"
                )
        message ClauseBind
            @?= Just
                ( "this host cannot hold ownership clause 3 (identity binding):"
                    <> " it supplies no stable object identity, no atomic no-replace publication"
                )
        message ClauseRelease
            @?= Just
                ( "this host cannot hold ownership clause 4 (conditional release):"
                    <> " it supplies no stable object identity"
                )
    , testCase "the four clauses are the whole set" $
        [minBound .. maxBound] @?= [ClauseEnter, ClauseRecord, ClauseBind, ClauseRelease]
    ]

-- ---------------------------------------------------------------------------
-- Refusal before any kernel call

refusalTests :: [TestTree]
refusalTests =
    [ testCase "entering refuses before the row's primitives are reached" $
        withEntry $ \session -> do
            entered <-
                try
                    ( enterOwnedObject
                        (unreachableRow noCapabilities)
                        session
                        "/owned/target"
                        (\_ -> pure (Right ()))
                    )
            expectUnsupported entered
    , testCase "a row that holds the clause does reach the kernel it declared" $
        -- The mirror of the case above: with the capability declared, the same
        -- call reaches the primitive and the unreachable row's divergence is
        -- observed. Without this, "refuses before the kernel" would also pass
        -- for a producer that never calls a kernel at all.
        withEntry $ \session -> do
            entered <-
                try
                    ( enterOwnedObject
                        (unreachableRow fullCapabilities)
                        session
                        "/owned/target"
                        (\_ -> pure (Right ()))
                    )
            case entered of
                Left (thrown :: SomeException) ->
                    assertBool
                        "the producer reached the identity read it declared"
                        ("observe an identity" `isInfixOf` show thrown)
                Right outcome ->
                    assertFailure
                        ("expected the declared kernel read, got " <> show outcome)
    ]

capabilityGateTests :: [TestTree]
capabilityGateTests =
    [ testCase "recording without parent sync refuses before publishing the origin" $
        withEntry $ \session -> do
            let capabilities = fullCapabilities{holdsDurableParentSync = False}
                row = pureObserveRow capabilities
            outcome <- enterOwnedObject row session "/owned/target" $ \entered -> do
                recorded <- recordOwnedOrigin row entered OwnedDirectory
                    (\_ -> error "a refused origin reached its publication continuation")
                pure (Right (() <$ recorded))
            outcome @?= Right (Left (requiredRefusal capabilities ClauseRecord))
    , testCase "file publication and binding require no-replace before any primitive" $
        withEntry $ \session -> do
            let payload = mkPayload "intended bytes"
                capabilities = fullCapabilities{holdsNoReplacePublication = False}
                row = pureObserveRow capabilities
            identity <- expectIdentity (OwnershipFixture.kernelIdentityWords 7 21)
            withRecorded session (OwnedFile (payloadDigest payload)) $ \recorded -> do
                published <- publishOwnedFile row recorded payload "/owned/target.staging"
                (() <$ published) @?= Left (requiredRefusal capabilities ClauseBind)
                bound <- bindOwnedIdentity row recorded identity
                    (\_ -> error "a refused binding reached its publication continuation")
                (() <$ bound) @?= Left (requiredRefusal capabilities ClauseBind)
    , testCase "opposite kernel object kinds refuse before any primitive" $
        withEntry $ \session -> do
            let payload = mkPayload "intended bytes"
                row = pureObserveRow fullCapabilities
            withRecorded session (OwnedFile (payloadDigest payload)) $ \recorded -> do
                outcome <- createOwnedDirectory row recorded
                (() <$ outcome) @?= Left (OwnershipUnsupported "this record describes a file, not a directory")
            withRecorded session OwnedDirectory $ \recorded -> do
                outcome <- publishOwnedFile row recorded payload "/owned/target.staging"
                (() <$ outcome) @?= Left (OwnershipUnsupported "this record describes a directory, not a file")
    , testCase "a different file payload is refused before any primitive" $
        withEntry $ \session ->
            withRecorded session (OwnedFile (payloadDigest (mkPayload "recorded bytes"))) $ \recorded -> do
                outcome <- publishOwnedFile (pureObserveRow fullCapabilities) recorded
                    (mkPayload "different bytes") "/owned/target.staging"
                (() <$ outcome) @?= Left (OwnershipUnsupported
                    "the payload offered is not the payload the origin record names")
    , testCase "re-observation without identity refuses before any primitive" $
        withEntry $ \session -> do
            identity <- expectIdentity (OwnershipFixture.kernelIdentityWords 7 22)
            withBound session identity $ \bound -> do
                outcome <- reobserveOwnedIdentity (unreachableRow noCapabilities) bound
                (() <$ outcome) @?= Left (requiredRefusal noCapabilities ClauseRelease)
    , testCase "directory creation without parent sync refuses before any primitive" $
        withEntry $ \session ->
            withRecorded session OwnedDirectory $ \recorded -> do
                let capabilities = fullCapabilities{holdsDurableParentSync = False}
                outcome <- createOwnedDirectory (pureObserveRow capabilities) recorded
                (() <$ outcome) @?= Left (requiredRefusal capabilities ClauseRecord)
    , testCase "object removal without parent sync refuses before removing or forgetting" $
        withEntry $ \session -> do
            identity <- expectIdentity (OwnershipFixture.kernelIdentityWords 7 23)
            withBound session identity $ \bound -> do
                releasable <- either (assertFailure . show) pure
                    (reobserveReportedIdentity bound (OriginPresent identity))
                let capabilities = fullCapabilities{holdsDurableParentSync = False}
                outcome <- releaseOwnedObject (pureObserveRow capabilities) releasable
                    (\_ -> error "a refused release reached its forget continuation")
                outcome @?= Left (requiredRefusal capabilities ClauseRecord)
    ]

-- Only the declaration's identity observation is a value; every other
-- primitive retains the existing divergent definition.
pureObserveRow :: OwnershipCapabilities -> OwnershipRow
pureObserveRow capabilities = observingRow capabilities (Right Nothing)

observingRow :: OwnershipCapabilities -> Either OwnershipFault (Maybe ObjectIdentity) -> OwnershipRow
observingRow capabilities observed =
    withOwnershipRow (unreachableRow capabilities) $ \primitives ->
        ownershipRow (primitives{rowObserveIdentity = \_ -> pure observed})

requiredRefusal :: OwnershipCapabilities -> OwnershipClause -> OwnershipFault
requiredRefusal capabilities clause =
    maybe (error "the capability fixture must refuse this clause") id (clauseRefusal capabilities clause)

withRecorded ::
    ProtectedSession session ->
    ObjectKind ->
    (forall object. Recorded session object -> IO ()) ->
    IO ()
withRecorded session kind use = do
    outcome <- enterOwnedObject (pureObserveRow fullCapabilities) session "/owned/target" $ \entered -> do
        recorded <- recordOwnedOrigin (pureObserveRow fullCapabilities) entered kind (\_ -> pure (Right ()))
        case recorded of
            Left fault -> pure (Left fault)
            Right token -> Right () <$ use token
    either (assertFailure . ("could not record the pure-observe fixture: " <>) . show) pure outcome

-- ---------------------------------------------------------------------------
-- Re-entry

{- | The producer that makes clause 4 reachable from the durable record.

Every case here runs against the row whose primitives diverge, which is the
point: re-entry reads a record the caller already holds and reaches no kernel at
all, so a case that finished proves it, and one that touched a primitive would
not finish.
-}
reentryTests :: [TestTree]
reentryTests =
    [ testCase "a record with no identity binding mints no token" $
        withEntry $ \session ->
            withStoredOrigin session (originRecord OwnedDirectory OriginAbsent) $ \stored -> do
                outcome <-
                    try
                        ( reenterStoredOwnedObject
                            (unreachableRow fullCapabilities)
                            session
                            "/owned/target"
                            stored
                            (\_ -> pure (Right ()))
                        )
                case (outcome :: Either SomeException (Either OwnershipFault ())) of
                    Right (Left (OwnershipMalformed reason)) ->
                        assertBool
                            ("the refusal says why: " <> show reason)
                            ("authorizes no release" `isInfixOf` Text.unpack reason)
                    other -> assertFailure ("expected a malformed-record refusal, got " <> show other)
    , testCase "a row that cannot hold the clause refuses before the record is read" $
        -- The capability check comes first, so an unbound record — which would
        -- otherwise be refused for its own reason — is still answered with the
        -- row's declared refusal rather than with a diagnostic about the record.
        withEntry $ \session ->
            withStoredOrigin session (originRecord OwnedDirectory OriginAbsent) $ \stored -> do
                outcome <-
                    try
                        ( reenterStoredOwnedObject
                            (unreachableRow noCapabilities)
                            session
                            "/owned/target"
                            stored
                            (\_ -> pure (Right ()))
                        )
                expectUnsupported outcome
    , testCase "a bound record discloses exactly the target and identity it names" $
        withEntry $ \session -> do
            identity <- expectIdentity (OwnershipFixture.kernelIdentityWords 7 11)
            bound <- expectBound (bindOriginRecord identity (originRecord OwnedDirectory OriginAbsent))
            withStoredOrigin session bound $ \stored -> do
                outcome <-
                    reenterStoredOwnedObject
                        (unreachableRow fullCapabilities)
                        session
                        "/owned/target"
                        stored
                        ( boundEvidence
                            ( \target record disclosed ->
                                pure (Right (target, record, disclosed))
                            )
                        )
                outcome @?= Right ("/owned/target", bound, identity)
    , testCase "reported re-entry projects the exact bound target record and identity with no row" $
        withEntry $ \session -> do
            let identity = forceIdentity "reported-instance"
            bound <- expectBound (bindOriginRecord identity sampleRecord)
            withStoredOrigin session bound $ \stored -> do
                outcome <-
                    reenterStoredReportedObject session "/reported/target" stored
                        (boundEvidence (\target record disclosed -> pure (Right (target, record, disclosed))))
                outcome @?= Right ("/reported/target", bound, identity)
    , testCase "reported re-entry refuses an unbound record before its continuation" $
        withEntry $ \session ->
            withStoredOrigin session sampleRecord $ \stored -> do
                outcome <- reenterStoredReportedObject session "/reported/target" stored
                    (\_ -> error "unbound reported re-entry reached its continuation")
                outcome @?= (Left (OwnershipMalformed
                    "this record names no identity binding, so it authorizes no release") :: Either OwnershipFault ())
    , testCase "reported re-entry refuses a bound kernel record before its continuation" $
        withEntry $ \session -> do
            identity <- expectIdentity (OwnershipFixture.kernelIdentityWords 7 11)
            bound <- expectBound (bindOriginRecord identity (originRecord OwnedDirectory OriginAbsent))
            withStoredOrigin session bound $ \stored -> do
                outcome <- reenterStoredReportedObject session "/reported/target" stored
                    (\_ -> error "kernel record reached reported re-entry continuation")
                outcome @?= (Left (OwnershipUnsupported
                    "this record describes a kernel object, not a reported object") :: Either OwnershipFault ())

    ]

-- ---------------------------------------------------------------------------
-- One conditional identity act

identityActTests :: [TestTree]
identityActTests =
    [ testCase "conditional act refuses absence before its continuation" $ do
        expected <- expectIdentity (OwnershipFixture.kernelIdentityWords 11 17)
        outcome <- withReobservedIdentity (observingRow fullCapabilities (Right Nothing))
            "/owned/target" expected (\_ -> error "absent conditional act reached its continuation")
        case (outcome :: Either OwnershipFault ()) of
            Left (OwnershipConflict report) -> do
                conflictSubject report @?= "/owned/target"
                conflictExpected report @?= OriginPresent expected
                conflictObserved report @?= OriginAbsent
            other -> assertFailure ("expected the absent identity conflict: " <> show other)
    , testCase "conditional act refuses a replacement before its continuation" $ do
        expected <- expectIdentity (OwnershipFixture.kernelIdentityWords 11 17)
        actual <- expectIdentity (OwnershipFixture.kernelIdentityWords 11 19)
        outcome <- withReobservedIdentity (observingRow fullCapabilities (Right (Just actual)))
            "/owned/target" expected (\_ -> error "replaced conditional act reached its continuation")
        case (outcome :: Either OwnershipFault ()) of
            Left (OwnershipConflict report) -> do
                conflictSubject report @?= "/owned/target"
                conflictExpected report @?= OriginPresent expected
                conflictObserved report @?= OriginPresent actual
            other -> assertFailure ("expected the replacement identity conflict: " <> show other)
    , testCase "conditional act uses the matching row and preserves its answer" $ do
        expected <- expectIdentity (OwnershipFixture.kernelIdentityWords 11 17)
        let row = observingRow fullCapabilities (Right (Just expected))
        outcome <- withReobservedIdentity row "/owned/target" expected
            (\primitives -> rowObserveIdentity primitives "/owned/target")
        outcome @?= Right (Just expected)
        let refusal = OwnershipProbeFailed "the conditional act" "refused"
        failed <- withReobservedIdentity row "/owned/target" expected (\_ -> pure (Left refusal))
        failed @?= (Left refusal :: Either OwnershipFault ())
    , testCase "conditional act checks capabilities before any row primitive" $ do
        expected <- expectIdentity (OwnershipFixture.kernelIdentityWords 11 17)
        outcome <- withReobservedIdentity (unreachableRow noCapabilities) "/owned/target" expected
            (\_ -> error "unsupported conditional act reached its continuation")
        outcome @?= (Left (requiredRefusal noCapabilities ClauseRelease) :: Either OwnershipFault ())
    , testCase "conditional act preserves an observation failure before its continuation" $ do
        expected <- expectIdentity (OwnershipFixture.kernelIdentityWords 11 17)
        let refusal = OwnershipProbeFailed "observe conditional target" "denied"
        outcome <- withReobservedIdentity (observingRow fullCapabilities (Left refusal))
            "/owned/target" expected (\_ -> error "failed observation reached its conditional act")
        outcome @?= (Left refusal :: Either OwnershipFault ())
    , testCase "the host wall delegates both conditional namespace acts to the seam" $
        withMainSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Wsl2" </> "GlobalWall" </> "Host.hs")
            SourceGuard.countHaskellIdentifier "withConfirmedIdentity" source @?= 0
            for_ ["deleteWallFile", "renameOpenFile"] $ \name -> do
                tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens name source)
                assertBool (name <> " must use the seam's conditional act")
                    (elem "withReobservedIdentity" tokens)
    ]

-- ---------------------------------------------------------------------------
-- The reported observation

{- | The face of the seam whose observation is an answer rather than a probe.

The reported producers take no row. The source guard covers their definitions,
the strict stored re-entry and its shared bound projection, and all primitive
fields. This is a property of source text; IO callbacks remain the caller's.
Fixtures that obtain a bound token through kernel re-entry use a diverging row,
so any unintended primitive call fails the case rather than recording a count.
-}
reportedTests :: [TestTree]
reportedTests =
    [ testCase "claim-only reported recording publishes the reported kind" $
        withEntry $ \session -> do
            published <- newIORef Nothing
            outcome <- enterReportedObject session "/reported/claim" OriginAbsent $ \entered ->
                fmap (fmap (const ())) $ recordReportedOrigin entered (mkOwnerClaim "reported")
                    (\record -> Right () <$ writeIORef published (Just record))
            outcome @?= Right ()
            recorded <- readIORef published
            fmap originRecordKind recorded @?= Just (ReportedObject (mkOwnerClaim "reported"))
    , testCase "the origin a record describes is the observation the caller was handed" $
        withEntry $ \session -> do
            identity <- expectIdentity (OwnershipFixture.kernelIdentityWords 3 5)
            for_ [OriginAbsent, OriginPresent identity] $ \observed -> do
                published <- newIORef Nothing
                outcome <-
                    enterReportedObject session "/reported/target" observed $ \entered ->
                        fmap
                            (fmap (const ()))
                            ( recordReportedOrigin
                                entered
                                (mkOwnerClaim "reported")
                                (\record -> Right () <$ writeIORef published (Just record))
                            )
                outcome @?= Right ()
                recorded <- readIORef published
                fmap originRecordKind recorded @?= Just (ReportedObject (mkOwnerClaim "reported"))
                fmap originRecordOrigin recorded @?= Just observed
                fmap originRecordBinding recorded @?= Just Nothing
    , testCase "clause 2 mints no token when the caller's durable write refuses" $
        withEntry $ \session -> do
            outcome <-
                enterReportedObject session "/reported/target" OriginAbsent $ \entered ->
                    fmap
                        (fmap (const ()))
                        ( recordReportedOrigin
                            entered
                            (mkOwnerClaim "reported")
                            (\_ -> pure (Left (OwnershipMalformed "the store refused")))
                        )
            case outcome of
                Left (OwnershipMalformed reason) -> reason @?= "the store refused"
                other -> assertFailure ("expected the store's own refusal, got " <> show other)
    , testCase "clause 3 binds the identity the owning authority reported" $
        withEntry $ \session -> do
            identity <- expectIdentity (OwnershipFixture.kernelIdentityWords 11 13)
            published <- newIORef Nothing
            outcome <-
                enterReportedObject session "/reported/target" OriginAbsent $ \entered -> do
                    recorded <-
                        recordReportedOrigin entered (mkOwnerClaim "reported") (\_ -> pure (Right ()))
                    case recorded of
                        Left fault -> pure (Left fault)
                        Right token ->
                            fmap
                                (fmap (const ()))
                                ( bindReportedIdentity
                                    token
                                    identity
                                    (\record -> Right () <$ writeIORef published (Just record))
                                )
            outcome @?= Right ()
            bound <- readIORef published
            fmap originRecordBinding bound @?= Just (Just identity)
    , testCase "clause 4 admits exactly the bound identity" $
        withEntry $ \session -> do
            identity <- expectIdentity (OwnershipFixture.kernelIdentityWords 17 19)
            other <- expectIdentity (OwnershipFixture.kernelIdentityWords 17 23)
            withBound session identity $ \bound -> do
                assertBool
                    "the exact identity is releasable"
                    (isRight (reobserveReportedIdentity bound (OriginPresent identity)))
                for_
                    [OriginAbsent, OriginPresent other]
                    ( \observed -> case reobserveReportedIdentity bound observed of
                        Left (OwnershipConflict report) -> do
                            conflictExpected report @?= OriginPresent identity
                            conflictObserved report @?= observed
                            conflictSubject report @?= "/reported/target"
                        Left fault ->
                            assertFailure ("expected a release conflict, got " <> show fault)
                        Right _ ->
                            assertFailure "a replaced or absent object was admitted for release"
                    )
    , testCase "a record is forgotten only over a reported absence" $
        withEntry $ \session -> do
            identity <- expectIdentity (OwnershipFixture.kernelIdentityWords 29 31)
            withBound session identity $ \bound ->
                case reobserveReportedIdentity bound (OriginPresent identity) of
                    Left fault -> assertFailure ("expected a releasable token: " <> show fault)
                    Right releasable -> do
                        forgotten <- newIORef (0 :: Int)
                        gone <-
                            releaseReportedObject
                                releasable
                                OriginAbsent
                                (\_ -> Right () <$ modifyIORef' forgotten (+ 1))
                        gone @?= Right ()
                        readIORef forgotten >>= (@?= 1)
                        -- A forget reached here would end the case rather than
                        -- record a wrong answer.
                        surviving <-
                            releaseReportedObject
                                releasable
                                (OriginPresent identity)
                                (\_ -> error "clause 4 forgot a record over a surviving object")
                        case surviving of
                            Left (OwnershipConflict report) -> do
                                conflictExpected report @?= OriginAbsent
                                conflictObserved report @?= OriginPresent identity
                            other ->
                                assertFailure
                                    ("expected a surviving-object conflict, got " <> show other)
                        readIORef forgotten >>= (@?= 1)
    , testCase "kernel removal recovery refuses reported and found-state records" $
        withSystemTempDirectory "hostbootstrap-kernel-recovery-policy" $ \directory -> withEntry $ \session -> do
            let identity = forceIdentity "kernel-recovery-policy"
                tape = recordTape session tapeSubject
                refused kind _origin = case kind of
                    ReportedObject _ -> OwnershipUnsupported "a reported object cannot use kernel removal recovery"
                    _ -> OwnershipOccupied "the kernel removal record does not name a created object"
                declared fallback = withOwnershipRow ownershipRowForHost $ \row ->
                    case clauseRefusal (rowCapabilities row) ClauseRelease of
                        Just fault -> fault
                        Nothing -> case clauseRefusal (rowCapabilities row) ClauseRecord of
                            Just fault -> fault
                            Nothing -> fallback
            for_ [("kernel-recovery-reported", ReportedObject (mkOwnerClaim "reported"), OriginAbsent),
                  ("kernel-recovery-found", OwnedDirectory, OriginPresent identity)] $ \(name, kind, origin) -> do
                key <- expectKey name
                record <- expectBound (bindOriginRecord identity (originRecord kind origin))
                before <- publishRawTapeRecord session key (renderOriginRecord record)
                stored <- readStoredOrigin tape key >>= OwnershipFixture.expectRight
                    >>= maybe (assertFailure "the actual stored policy record vanished") pure
                outcome <- reenterStoredOwnedObject ownershipRowForHost session (directory </> "missing") stored $ \bound ->
                    resumeOwnedRemoval ownershipRowForHost bound
                        (\_ -> assertFailure "a reported or found-state record reached kernel recovery's forget")
                outcome @?= Left (declared (refused kind origin))
                readProtectedRecord session key >>= (@?= Right (Just before))
    , testCase "an interrupted reported removal cleans its record only over fresh absence" $
        withEntry $ \session -> do
            let identity = forceIdentity "removed-instance"
                other = forceIdentity "replacement-instance"
                tape = recordTape session tapeSubject
            key <- expectKey "interrupted-reported-removal"
            record <- expectBound (bindOriginRecord identity sampleRecord)
            before <- publishRawTapeRecord session key (renderOriginRecord record)
            stored <- readStoredOrigin tape key
                >>= OwnershipFixture.expectRight
                >>= maybe (assertFailure "the actual retained binding disappeared") pure
            result <- reenterStoredReportedObject session "/reported/removed" stored $ \bound -> do
                for_ [OriginPresent identity, OriginPresent other] $ \present -> do
                    refused <- resumeReportedRemoval bound present
                        (\_ -> error "a present instance reached resumed record cleanup")
                    refused @?= Left (OwnershipConflict
                        (ConflictReport "/reported/removed" OriginAbsent present))
                    readProtectedRecord session key >>= (@?= Right (Just before))
                resumed <- resumeReportedRemoval bound OriginAbsent $ \actual -> do
                    actual @?= record
                    forgetRecord tape key
                resumed @?= Right ()
                readProtectedRecord session key >>= (@?= Right Nothing)
                pure (Right ())
            result @?= Right ()
    , testCase "kernel release refuses a reported object before removal or forget" $
        withEntry $ \session -> do
            let identity = forceIdentity "reported-release"
            record <- expectBound (bindOriginRecord identity (originRecord (ReportedObject (mkOwnerClaim "reported")) OriginAbsent))
            forgotten <- newIORef False
            withStoredOrigin session record $ \stored -> do
                outcome <- reenterStoredOwnedObject (unreachableRow fullCapabilities) session "/reported/target" stored $ \bound -> do
                    observed <- reobserveOwnedIdentity (observingRow fullCapabilities (Right (Just identity))) bound
                    case observed of
                        Left fault -> pure (Left fault)
                        Right releasable -> releaseOwnedObject (unreachableRow fullCapabilities) releasable
                            (\_ -> Right () <$ writeIORef forgotten True)
                outcome @?= Left (OwnershipMalformed "a reported object cannot use kernel removal")
            readIORef forgotten >>= (@?= False)
    , testCase "a kernel producer refuses a record about an object it does not answer for" $
        withEntry $ \session -> do
            -- Reached without a kernel: both producers read the record's kind
            -- before they touch a primitive, so the diverging row proves the
            -- refusal comes first rather than after a mutation.
            outcome <-
                enterReportedObject session "/reported/instance" OriginAbsent $ \entered -> do
                    recorded <-
                        recordReportedOrigin
                            entered
                            (mkOwnerClaim "one attempt")
                            (\_ -> pure (Right ()))
                    case recorded of
                        Left fault -> pure (Left fault)
                        Right token -> do
                            directory <- createOwnedDirectory (unreachableRow fullCapabilities) token
                            file <-
                                publishOwnedFile
                                    (unreachableRow fullCapabilities)
                                    token
                                    (mkPayload "bytes")
                                    "/reported/instance.staging"
                            pure (Right (fmap (const ()) directory, fmap (const ()) file))
            case outcome of
                Right (Left (OwnershipUnsupported directory), Left (OwnershipUnsupported file)) -> do
                    assertBool
                        ("the directory refusal says why: " <> Text.unpack directory)
                        ("another authority owns" `isInfixOf` Text.unpack directory)
                    assertBool
                        ("the file refusal says why: " <> Text.unpack file)
                        ("another authority owns" `isInfixOf` Text.unpack file)
                other -> assertFailure ("expected two unsupported refusals, got " <> show other)
    , testCase "the reported face names no row and reaches no primitive" $
        withCoreSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Primitive.hs")
            fields <- OwnershipFixture.expectRight (SourceGuard.recordFieldNames "OwnershipPrimitive" source)
            assertBool "the actual primitive fields are present" (not (null fields))
            [name | name <- fields, not (elem name reportedPrimitiveVocabulary)] @?= []
            reportedPrimitiveReferences source @?= Right []
    , testCase "the reported-face guard rejects every primitive vocabulary name" $
        withCoreSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Primitive.hs")
            let (before, after) = break (isInfixOf "-- Shared steps") (lines source)
            assertBool "the reported/shared boundary exists" (not (null after))
            for_ reportedPrimitiveVocabulary $ \name -> do
                let violating = unlines (before <> ["forbiddenProbe = " <> name] <> after)
                reportedPrimitiveReferences violating @?= Right [name]
    , testCase "both faces settle each shared clause through one computation" $
        withCoreSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Primitive.hs")
            traverse_
                ( \shared ->
                    assertBool
                        (shared <> " is the one computation both faces use")
                        (shared `isInfixOf` normalize source)
                )
                [ "Nothing -> recordOrigin entered kind publish"
                , "recordReportedOrigin entered claim publish = recordOrigin entered (ReportedObject claim) publish"
                , "Nothing -> bindReportedIdentity recorded identity publish"
                , "Right current -> reobserveReportedIdentity bound (originOf current)"
                ]
    ]

{- | Mint a 'Bound' token from a durable record, which is the only way to reach
clause 4 without a kernel. The row is the diverging one, so a case that reached a
primitive would not finish.
-}
withBound ::
    ProtectedSession session ->
    ObjectIdentity ->
    (forall object. Bound session object -> IO ()) ->
    IO ()
withBound session identity use = do
    record <- expectBound (bindOriginRecord identity (originRecord OwnedDirectory OriginAbsent))
    withStoredOrigin session record $ \stored -> do
        outcome <-
            reenterStoredOwnedObject
                (unreachableRow fullCapabilities)
                session
                "/reported/target"
                stored
                (\bound -> Right () <$ use bound)
        either (\fault -> assertFailure ("could not re-enter: " <> show fault)) pure outcome

-- | Reported definitions include strict re-entry and its shared bound projection.
reportedFace :: String -> Either String String
reportedFace source = do
    let body = unlines
            (takeWhile (not . isInfixOf "-- Shared steps")
                (drop 1 (dropWhile (not . isInfixOf opening) (lines source))))
    if null body then Left "the reported producer region is absent" else do
        shared <- traverse (flip SourceGuard.haskellDefinitionTokens source)
            [ "reenterStoredReportedObject", "reenterBoundRecord"
            , "enteredEvidenceOf", "recordedEvidenceOf", "releasableEvidenceOf"
            , "withLiveOwnershipEntry"
            ]
        pure (unlines (body : map unwords shared))
  where
    opening = "-- The five clause producers, over an object an authority reports on"

reportedPrimitiveReferences :: String -> Either String [String]
reportedPrimitiveReferences source = do
    face <- reportedFace source
    pure [name | name <- reportedPrimitiveVocabulary, SourceGuard.countHaskellIdentifier name face > 0]

reportedPrimitiveVocabulary :: [String]
reportedPrimitiveVocabulary =
    [ "OwnershipRow", "OwnershipPrimitive", "OwnershipCapabilities"
    , "ownershipRow", "withOwnershipRow", "readWholeObject", "ownershipRowForHost", "rowCapabilities", "clauseRefusal"
    , "rowObserveIdentity", "rowOpenExclusive", "rowCreateDirectory", "rowCreateFile"
    , "rowLinkNoReplace", "rowReadObject", "rowRemoveObject", "rowCloseHandle", "rowSyncParent"
    , "identityOfCreated", "enterOwnedObject", "reenterStoredOwnedObject", "recordOwnedOrigin"
    , "createOwnedDirectory", "publishOwnedFile", "bindOwnedIdentity", "reobserveOwnedIdentity"
    , "withReobservedIdentity", "releaseOwnedObject"
    ]

isRight :: Either fault value -> Bool
isRight = either (const False) (const True)

expectIdentity :: Either OwnershipFault ObjectIdentity -> IO ObjectIdentity
expectIdentity = either (\fault -> assertFailure ("expected an identity: " <> show fault)) pure

expectBound :: Either OwnershipFault OriginRecord -> IO OriginRecord
expectBound = either (\fault -> assertFailure ("expected a bound record: " <> show fault)) pure

-- ---------------------------------------------------------------------------
-- The seam's shape

{- | The store adapter every owner shares, and the refusal the copies disagreed on.

Two hand-copied adapters produced different refusals for the same condition —
one named "this instance's key" and carried a 'RecordKey' it never printed, the
other named "this key" and carried none. The tape keeps the shorter key wording
and names the /subject/ instead, which is the distinction the longer one was
reaching for; the unread parameter is gone. The chosen refusal is asserted here
so the decision is a case rather than a diff.
-}
tapeTests :: [TestTree]
tapeTests =
    [ testCase "a fresh publish is idempotent within its own transaction" $
        withEntry $ \session -> do
            let tape = recordTape session tapeSubject
            key <- expectKey "tape-idempotent"
            first <- publishFreshRecord tape key sampleRecord
            first @?= Right ()
            again <- publishFreshRecord tape key sampleRecord
            again @?= Right ()
    , testCase "a record another transaction published is refused, named by subject" $
        withEntry $ \session -> do
            let tape = recordTape session tapeSubject
            key <- expectKey "tape-foreign"
            published <- publishFreshRecord tape key sampleRecord
            published @?= Right ()
            intruding <- publishFreshRecord tape key otherRecord
            intruding
                @?= Left
                    ( OwnershipOccupied
                        "the durable record under this key is not the sample origin record this transaction publishes"
                    )
    , testCase "a fresh publish refuses an existing binding with the same kind and origin" $
        withEntry $ \session -> do
            key <- expectKey "tape-fresh-bound"
            bound <- expectBound (bindOriginRecord (forceIdentity "first-bound") sampleRecord)
            before <- publishRawTapeRecord session key (renderOriginRecord bound)
            publishFreshRecord (recordTape session tapeSubject) key sampleRecord
                >>= (@?= Left occupiedTapeRecord)
            readProtectedRecord session key >>= (@?= Right (Just before))
    , testCase "binding refuses a different stored binding without changing its bytes or version" $
        withEntry $ \session -> do
            key <- expectKey "tape-rebinding"
            first <- expectBound (bindOriginRecord (forceIdentity "first-bound") sampleRecord)
            second <- expectBound (bindOriginRecord (forceIdentity "second-bound") sampleRecord)
            before <- publishRawTapeRecord session key (renderOriginRecord first)
            publishBoundRecord (recordTape session tapeSubject) key second
                >>= (@?= Left occupiedTapeRecord)
            readProtectedRecord session key >>= (@?= Right (Just before))
    , testCase "binding swaps only the exact unbound record and identical bytes keep their version" $
        withEntry $ \session -> do
            key <- expectKey "tape-binding"
            let tape = recordTape session tapeSubject
            before <- publishRawTapeRecord session key (renderOriginRecord sampleRecord)
            bound <- expectBound (bindOriginRecord (forceIdentity "first-bound") sampleRecord)
            publishBoundRecord tape key bound >>= (@?= Right ())
            after <- expectTapeRecord session key
            protectedRecordBytes after @?= renderOriginRecord bound
            recordVersionWord (protectedRecordVersion after)
                @?= recordVersionWord (protectedRecordVersion before) + 1
            publishBoundRecord tape key bound >>= (@?= Right ())
            readProtectedRecord session key >>= (@?= Right (Just after))
    , testCase "fresh and bound publication refuse another unbound origin without changing it" $
        withEntry $ \session -> do
            key <- expectKey "tape-other-origin"
            before <- publishRawTapeRecord session key (renderOriginRecord otherRecord)
            bound <- expectBound (bindOriginRecord (forceIdentity "first-bound") sampleRecord)
            let tape = recordTape session tapeSubject
            publishFreshRecord tape key sampleRecord >>= (@?= Left occupiedTapeRecord)
            publishBoundRecord tape key bound >>= (@?= Left occupiedTapeRecord)
            readProtectedRecord session key >>= (@?= Right (Just before))
    , testCase "a torn store envelope is malformed in every tape operation and remains exact" $
        withEntry $ \session -> do
            key <- expectKey "tape-torn"
            let path = tapeRecordPath session key
                raw = "not-a-protected-envelope"
                tape = recordTape session tapeSubject
                expected = storeFault "ignored operation"
                    (ProtectedMalformedRecord (recordKeyText key) "the record has no header terminator")
            before <- publishRawTapeRecord session key (renderOriginRecord sampleRecord)
            ByteString.writeFile path raw
            readRecordUnder tape key >>= (@?= Left expected)
            readRawRecordUnder tape key >>= (@?= Left expected)
            readVersionedRecordUnder tape key >>= (@?= Left expected)
            readStoredOrigin tape key >>= (@?= Left expected)
            publishFreshRecord tape key sampleRecord >>= (@?= Left expected)
            bound <- expectBound (bindOriginRecord (forceIdentity "first-bound") sampleRecord)
            publishBoundRecord tape key bound >>= (@?= Left expected)
            forgetRecord tape key >>= (@?= Left expected)
            forgetRecordAtVersion tape key (protectedRecordVersion before) >>= (@?= Left expected)
            ByteString.readFile path >>= (@?= raw)
    , testCase "a valid envelope with an invalid origin body is malformed in every decoded tape operation" $
        withEntry $ \session -> do
            key <- expectKey "tape-invalid-body"
            let raw = "this is not an origin record\n"
                tape = recordTape session tapeSubject
            expected <- case parseOriginRecord raw of
                Left fault@(OwnershipMalformed _) -> pure fault
                other -> assertFailure ("the fixture must be malformed: " <> show other)
            before <- publishRawTapeRecord session key raw
            readRecordUnder tape key >>= (@?= Left expected)
            readVersionedRecordUnder tape key >>= (@?= Left expected)
            readStoredOrigin tape key >>= (@?= Left expected)
            publishFreshRecord tape key sampleRecord >>= (@?= Left expected)
            bound <- expectBound (bindOriginRecord (forceIdentity "first-bound") sampleRecord)
            publishBoundRecord tape key bound >>= (@?= Left expected)
            forgetRecord tape key >>= (@?= Left expected)
            forgetRecordAtVersion tape key (protectedRecordVersion before) >>= (@?= Left expected)
            readProtectedRecord session key >>= (@?= Right (Just before))
    , testCase "a real unreadable record path remains a probe failure in every tape operation" $
        withEntry $ \session -> do
            key <- expectKey "tape-unreadable"
            let path = tapeRecordPath session key
                tape = recordTape session tapeSubject
            createDirectory path
            stored <- readProtectedRecord session key
            failure <- case stored of
                Left fault@(ProtectedIOFailure _ _) -> pure fault
                other -> assertFailure ("expected the directory read to fail: " <> show other)
            readRecordUnder tape key
                >>= (@?= Left (storeFault "read the durable ownership record" failure))
            readStoredOrigin tape key
                >>= (@?= Left (storeFault "read the durable ownership record" failure))
            publishFreshRecord tape key sampleRecord
                >>= (@?= Left (storeFault "read the sample origin record" failure))
            bound <- expectBound (bindOriginRecord (forceIdentity "first-bound") sampleRecord)
            publishBoundRecord tape key bound
                >>= (@?= Left (storeFault "read the sample origin record" failure))
            forgetRecord tape key
                >>= (@?= Left (storeFault "read the sample origin record" failure))
            doesDirectoryExist path >>= (@?= True)
    , testCase "only malformed protected envelopes lose the probe classification" $
        for_ [ ProtectedInvalid "rejected"
             , ProtectedVersionMismatch "sample" Nothing Nothing
             , ProtectedIOFailure "read" "denied"
             ] $ \failure ->
                storeFault "operation" failure
                    @?= OwnershipProbeFailed "operation" (protectedErrorMessage failure)
    , testCase "forgetting an absent record is the settled state, not a refusal" $
        withEntry $ \session -> do
            let tape = recordTape session tapeSubject
            key <- expectKey "tape-absent"
            forgotten <- forgetRecord tape key
            forgotten @?= Right ()
    , testCase "binding without a published record refuses in the subject's own words" $
        withEntry $ \session -> do
            let tape = recordTape session tapeSubject
            key <- expectKey "tape-unpublished"
            bound <- publishBoundRecord tape key sampleRecord
            bound
                @?= Left
                    ( OwnershipProbeFailed
                        "bind the sample identity"
                        "the origin record vanished inside the exclusive entry"
                    )
    , testCase "the raw tape read preserves authoritative absence in the domain carrier" $
        withEntry $ \session -> do
            key <- expectKey "tape-raw-absent"
            readRawRecordUnder (recordTape session tapeSubject) key
                >>= (@?= (Right Nothing :: Either TapeReadFault (Maybe ProtectedRecord)))
    , testCase "raw read preserves an invalid origin body while decoded read carries its parse fault" $
        withEntry $ \session -> do
            key <- expectKey "tape-raw-body"
            let raw = "not an origin body\n"
                tape = recordTape session tapeSubject
            before <- publishRawTapeRecord session key raw
            readRawRecordUnder tape key >>= (@?= (Right (Just before) :: Either TapeReadFault (Maybe ProtectedRecord)))
            fault <- case parseOriginRecord raw of
                Left malformed@(OwnershipMalformed _) -> pure malformed
                other -> assertFailure ("expected the invalid body fixture: " <> show other)
            readStoredRecordUnder tape key >>= (@?= Left (TapeClauseFault fault))
            readRecordUnder tape key >>= (@?= Left (TapeClauseFault fault))
            readProtectedRecord session key >>= (@?= Right (Just before))
    , testCase "raw and decoded reads keep a malformed envelope in the domain store variant" $
        withEntry $ \session -> do
            key <- expectKey "tape-raw-envelope"
            let tape = recordTape session tapeSubject
                raw = "not-a-protected-envelope"
                expected = TapeStoreFault
                    (ProtectedMalformedRecord (recordKeyText key) "the record has no header terminator")
            ByteString.writeFile (tapeRecordPath session key) raw
            readRawRecordUnder tape key >>= (@?= Left expected)
            readRecordUnder tape key >>= (@?= Left expected)
            ByteString.readFile (tapeRecordPath session key) >>= (@?= raw)
    , testCase "a real raw-read IO failure retains the exact domain store fault" $
        withEntry $ \session -> do
            key <- expectKey "tape-raw-io"
            let tape = recordTape session tapeSubject
                path = tapeRecordPath session key
            createDirectory path
            observed <- readProtectedRecord session key
            fault <- case observed of
                Left failure@(ProtectedIOFailure _ _) -> pure failure
                other -> assertFailure ("expected a real directory read failure: " <> show other)
            readRawRecordUnder tape key >>= (@?= Left (TapeStoreFault fault))
            readStoredRecordUnder tape key >>= (@?= Left (TapeStoreFault fault))
            readRecordUnder tape key >>= (@?= Left (TapeStoreFault fault))
            doesDirectoryExist path >>= (@?= True)
    , testCase "versioned origin read returns the exact envelope version and decoded body" $
        withEntry $ \session -> do
            key <- expectKey "tape-versioned-read"
            missing <- expectKey "tape-versioned-missing"
            before <- publishRawTapeRecord session key (renderOriginRecord sampleRecord)
            let tape = recordTape session tapeSubject
            readVersionedRecordUnder tape key
                >>= (@?= (Right (Just (protectedRecordVersion before, sampleRecord)) :: Either TapeReadFault (Maybe (RecordVersion, OriginRecord))))
            readVersionedRecordUnder tape missing
                >>= (@?= (Right Nothing :: Either TapeReadFault (Maybe (RecordVersion, OriginRecord))))
            readProtectedRecord session key >>= (@?= Right (Just before))
    , testCase "version-qualified forget deletes exactly the retained version" $
        withEntry $ \session -> do
            key <- expectKey "tape-versioned-forget"
            before <- publishRawTapeRecord session key (renderOriginRecord sampleRecord)
            let tape = recordTape session tapeSubject
            forgetRecordAtVersion tape key (protectedRecordVersion before) >>= (@?= Right ())
            readProtectedRecord session key >>= (@?= Right Nothing)
            forgetRecord tape key >>= (@?= Right ())
    , testCase "version-qualified forget refuses a real intervening write without changing it" $
        withEntry $ \session -> do
            key <- expectKey "tape-versioned-stale"
            before <- publishRawTapeRecord session key (renderOriginRecord sampleRecord)
            let version = protectedRecordVersion before
            _ <- OwnershipFixture.expectRight =<<
                compareAndSwapProtectedRecord session key (ExpectVersion version) (renderOriginRecord otherRecord)
            after <- expectTapeRecord session key
            let failure = ProtectedVersionMismatch (recordKeyText key) (Just version) (Just (protectedRecordVersion after))
            forgetRecordAtVersion (recordTape session tapeSubject) key version
                >>= (@?= Left (storeFault "forget the sample origin record" failure))
            readProtectedRecord session key >>= (@?= Right (Just after))
    , testCase "version-qualified forget refuses absence while ordinary forget accepts settlement" $
        withEntry $ \session -> do
            key <- expectKey "tape-versioned-absent"
            before <- publishRawTapeRecord session key (renderOriginRecord sampleRecord)
            let tape = recordTape session tapeSubject
                version = protectedRecordVersion before
            forgetRecord tape key >>= (@?= Right ())
            forgetRecordAtVersion tape key version
                >>= (@?= Left (storeFault "forget the sample origin record"
                    (ProtectedVersionMismatch (recordKeyText key) (Just version) Nothing)))
            readProtectedRecord session key >>= (@?= Right Nothing)
    , testCase "Colima reads and forgets its origin records through the tape" $
        SourceGuard.withPackageSourceIn [] $ \driverPackageRoot _ -> do
            raw <- ByteString.readFile (driverPackageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            source <- either (assertFailure . show) (pure . Text.unpack) (TextEncoding.decodeUtf8' raw)
            assertBool "Colima imports the origin record tape"
                (SourceGuard.importsModule "HostBootstrap.Ownership.Tape" source)
            SourceGuard.countHaskellIdentifier "parseOriginRecord" source @?= 0
            SourceGuard.countHaskellIdentifier "compareAndDeleteProtectedRecord" source @?= 2
            assertBool "the sole direct delete is the separate retained manifest protocol"
                (isInfixOf "compareAndDeleteProtectedRecord session (colimaManifestKey keys)" source)
            for_
                [ ("acquireColimaDirectory", ["readRawRecordUnder"])
                , ("ensureColimaDirectory", ["readStoredRecordUnder"])
                , ("releaseColimaDirectory", ["readStoredRecordUnder", "storedRecordVersion", "forgetRecordAtVersion"])
                ] $ \(name, expected) -> do
                    tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens name source)
                    for_ expected $ \identifier ->
                        assertBool (name <> " must use " <> identifier) (elem identifier tokens)
                    for_ ["readProtectedRecord", "compareAndDeleteProtectedRecord"] $ \identifier ->
                        assertBool (name <> " bypasses the origin tape via " <> identifier) (not (elem identifier tokens))
    , testCase "every owner behind the seam reaches the store through the tape" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ ->
            for_ storeAdapterOwners $ \owner -> do
                let directory = if owner == ["HostBootstrap", "Cluster", "Ownership.hs"] then "internal" </> "cluster-ownership" else "src"
                source <- readFile (packageRoot </> directory </> foldr1 (</>) owner)
                assertBool
                    (show owner <> " no longer imports the record tape")
                    (SourceGuard.importsModule "HostBootstrap.Ownership.Tape" source)
                traverse_
                    ( \reachedDirectly ->
                        assertBool
                            (show owner <> " reaches the store past the tape via " <> reachedDirectly)
                            (SourceGuard.countHaskellIdentifier reachedDirectly source == 0)
                    )
                    ["compareAndSwapProtectedRecord", "compareAndDeleteProtectedRecord"]
                for_ (if elem owner harnessTapeOwners then ["readProtectedRecord", "forgetFailure"] else []) $
                    \identifier -> SourceGuard.countHaskellIdentifier identifier source @?= 0
    , testCase "both readers of the little-endian wire share one word reader" $
        withMainSourceRoot $ \sourceRoot ->
            for_ littleEndianReaders $ \reader -> do
                source <- readFile (sourceRoot </> foldr1 (</>) reader)
                assertBool
                    (show reader <> " no longer imports the shared word reader")
                    (SourceGuard.importsModule "HostBootstrap.Wire.LittleEndian" source)
                assertBool
                    (show reader <> " still assembles words from bytes itself")
                    (not (SourceGuard.importsModule "Data.Bits" source))
    ]

{- | The five owners that each held a copy of the store adapter.

Naming them is the point: a guard that walked every module would pass the day a
sixth owner was written with a sixth copy, because it would have nothing to say
about a module it had never been told to expect.
-}
storeAdapterOwners :: [[FilePath]]
storeAdapterOwners =
    [ ["HostBootstrap", "Substrate", "Provider", "Ownership.hs"]
    , ["HostBootstrap", "Cluster", "Ownership.hs"]
    ]
        <> harnessTapeOwners
        <> [["HostBootstrap", "Ownership", "Shipped.hs"]]

-- | The raw presence read and forget adapter also belong to the tape for these owners.
harnessTapeOwners :: [[FilePath]]
harnessTapeOwners =
    [ ["HostBootstrap", "Harness", "DataRoot.hs"]
    , ["HostBootstrap", "Harness", "GeneratedConfig.hs"]
    ]

-- | The two modules that decode a little-endian length-prefixed wire.
littleEndianReaders :: [[FilePath]]
littleEndianReaders =
    [ ["HostBootstrap", "Ownership", "Shipped.hs"]
    , ["HostBootstrap", "Wsl2", "GlobalWall", "Host.hs"]
    ]


-- | Actual protected-store writes keep envelope versions independent of tape assertions.
publishRawTapeRecord :: ProtectedSession session -> RecordKey -> ByteString -> IO ProtectedRecord
publishRawTapeRecord session key bytes = do
    written <- compareAndSwapProtectedRecord session key ExpectAbsent bytes
    _ <- OwnershipFixture.expectRight written
    expectTapeRecord session key

expectTapeRecord :: ProtectedSession session -> RecordKey -> IO ProtectedRecord
expectTapeRecord session key = do
    stored <- OwnershipFixture.expectRight =<< readProtectedRecord session key
    maybe (assertFailure "expected the durable tape record") pure stored

tapeRecordPath :: ProtectedSession session -> RecordKey -> FilePath
tapeRecordPath session key =
    sessionStoreRoot session </> "records" </> (Text.unpack (recordKeyText key) <> ".rec")

occupiedTapeRecord :: OwnershipFault
occupiedTapeRecord =
    OwnershipOccupied "the durable record under this key is not the sample origin record this transaction publishes"



-- | A distinct domain sum proves the raw read keeps its store-error constructor.
data TapeReadFault
    = TapeClauseFault OwnershipFault
    | TapeStoreFault ProtectedError
    deriving (Eq, Show)

instance OwnershipCarrier TapeReadFault where
    fromClauseFault = TapeClauseFault
    fromStoreFault = TapeStoreFault


tapeSubject :: RecordSubject
tapeSubject =
    RecordSubject
        { subjectRecord = "the sample origin record"
        , subjectBinding = "bind the sample identity"
        }

expectKey :: Text -> IO RecordKey
expectKey name =
    either (\fault -> assertFailure ("could not mint a record key: " <> show fault)) pure (mkRecordKey name)

sampleRecord :: OriginRecord
sampleRecord = originRecord (ReportedObject (mkOwnerClaim "sample-owner")) OriginAbsent

otherRecord :: OriginRecord
otherRecord =
    originRecord
        (ReportedObject (mkOwnerClaim "sample-owner"))
        (OriginPresent (forceIdentity "another-object"))

forceIdentity :: ByteString -> ObjectIdentity
forceIdentity raw =
    either (\fault -> error ("the fixture identity is not one: " <> show fault)) id (mkObjectIdentity raw)

seamTests :: [TestTree]
seamTests =
    [ testCase "a sealed row discloses its declaration and never its handle type" $ do
        withOwnershipRow (unreachableRow fullCapabilities) rowCapabilities @?= fullCapabilities
        withOwnershipRow (unreachableRow noCapabilities) rowCapabilities @?= noCapabilities
    , testCase "the classifier identifier count and gate spellings stay declared" $
        withCoreSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Primitive.hs")
            -- Export, signature, definition and twelve gated call sites.
            -- Behavioural cases separately hold refusal ordering.
            SourceGuard.countHaskellIdentifier "clauseRefusal" source @?= 15
            traverse_
                ( \gated ->
                    assertBool
                        (gated <> " is gated on its clause")
                        (gated `isInfixOf` normalize source)
                )
                [ "case clauseRefusal (rowCapabilities primitives) ClauseEnter of Just refusal -> pure (Left refusal)"
                , "case clauseRefusal (rowCapabilities primitives) ClauseRecord of Just refusal -> pure (Left refusal)"
                , "case clauseRefusal (rowCapabilities primitives) ClauseBind of Just refusal -> pure (Left refusal)"
                , "case clauseRefusal (rowCapabilities primitives) ClauseRelease of Just refusal -> pure (Left refusal)"
                , "createOwnedDirectory row recorded = withOwnershipRow row $ \\primitives -> case clauseRefusal (rowCapabilities primitives) ClauseRecord of Just refusal -> pure (Left refusal)"
                , "publishOwnedFile row recorded payload staging = withOwnershipRow row $ \\primitives -> case clauseRefusal (rowCapabilities primitives) ClauseRecord of Just refusal -> pure (Left refusal) Nothing -> case clauseRefusal (rowCapabilities primitives) ClauseBind of Just refusal -> pure (Left refusal)"
                , "releaseOwnedObject row releasable forget = withOwnershipRow row $ \\primitives -> case clauseRefusal (rowCapabilities primitives) ClauseRecord of Just refusal -> pure (Left refusal)"
                , "withReobservedIdentity row target identity act = withOwnershipRow row $ \\primitives -> case clauseRefusal (rowCapabilities primitives) ClauseRelease of Just refusal -> pure (Left refusal)"
                ]
    , testCase "the seam carries no runner, no pathname policy, and no durable record" $
        withCoreSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Primitive.hs")
            traverse_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier source @?= 0)
                [ "HostCommand"
                , "interpretHostCommand"
                , "createProcess"
                , "readProcessWithExitCode"
                , "ProtectedStore"
                , "RecordKey"
                , "compareAndSwapProtectedRecord"
                , "readProtectedRecord"
                , "takeDirectory"
                , "takeFileName"
                , "</>"
                , "unsafeCoerce"
                ]
    ]

normalize :: String -> String
normalize = unwords . words

-- ---------------------------------------------------------------------------
-- Helpers

-- | Every capability combination, so the classifier is applied to all eight.
everyCapability :: [OwnershipCapabilities]
everyCapability =
    [ OwnershipCapabilities identity publication parent
    | identity <- [False, True]
    , publication <- [False, True]
    , parent <- [False, True]
    ]

fullCapabilities :: OwnershipCapabilities
fullCapabilities = OwnershipCapabilities True True True

noCapabilities :: OwnershipCapabilities
noCapabilities = OwnershipCapabilities False False False

{- | A row whose every primitive diverges.

Reaching one is not a wrong answer a case would have to compare against; it is a
case that does not finish. That is what makes "the refusal happens before the
kernel" a property of the program rather than of a fake's bookkeeping, and it is
also what lets the mirror case observe that a declared capability really is
reached.
-}
unreachableRow :: OwnershipCapabilities -> OwnershipRow
unreachableRow capabilities =
    ownershipRow
        OwnershipPrimitive
            { rowCapabilities = capabilities
            , rowObserveIdentity = unreachable "observe an identity"
            , rowOpenExclusive = unreachable "open one object exclusively"
            , rowCreateDirectory = unreachable "create a directory"
            , rowCreateFile = \_ -> unreachable "create a file"
            , rowLinkNoReplace = \_ -> unreachable "link without replacing"
            , rowReadObject = unreachable "read an object"
            , rowRemoveObject = unreachable "remove an object"
            , rowCloseHandle = unreachable "close a handle"
            , rowSyncParent = unreachable "sync a parent directory"
            }
  where
    unreachable :: String -> argument -> IO result
    unreachable operation _ =
        error ("a clause reached the kernel to " <> operation)

withEntry :: (forall session. ProtectedSession session -> IO ()) -> IO ()
withEntry use =
    withSystemTempDirectory "hostbootstrap-ownership" $ \root -> do
        opened <- openProtectedStore root
        case opened of
            Left fault -> assertFailure ("could not open the protected store: " <> show fault)
            Right store -> do
                held <- withProtectedEntry store (\session -> Right <$> use session)
                either
                    (\fault -> assertFailure ("the protected entry failed: " <> show fault))
                    pure
                    held

expectUnsupported :: Either SomeException (Either OwnershipFault ()) -> IO ()
expectUnsupported outcome = case outcome of
    Left thrown -> assertFailure ("a refused clause reached the kernel: " <> show thrown)
    Right (Left (OwnershipUnsupported _)) -> pure ()
    Right other -> assertFailure ("expected an unsupported refusal, got " <> show other)

withMainSourceRoot :: (FilePath -> IO result) -> IO result
withMainSourceRoot use = SourceGuard.withPackageSourceIn ["src"] (const use)

withCoreSourceRoot :: (FilePath -> IO result) -> IO result
withCoreSourceRoot use = do
    cwd <- getCurrentDirectory
    repoRoot <-
        findRepoRoot cwd
            >>= maybe (assertFailure ("could not locate repo root from " <> cwd)) pure
    use (repoRoot </> "core" </> "hostbootstrap-core" </> "internal" </> "ownership")

readStoredOrigin ::
    RecordTape session ->
    RecordKey ->
    IO (Either OwnershipFault (Maybe (StoredOriginRecord session)))
readStoredOrigin = readStoredRecordUnder

withStoredOrigin ::
    ProtectedSession session ->
    OriginRecord ->
    (StoredOriginRecord session -> IO ()) ->
    IO ()
withStoredOrigin session record use = do
    key <- expectKey "stored-reentry-origin"
    _ <- publishRawTapeRecord session key (renderOriginRecord record)
    found <- readStoredOrigin (recordTape session tapeSubject) key >>= OwnershipFixture.expectRight
    case found of
        Just stored -> use stored
        Nothing -> assertFailure "the actual tape read lost its published origin"

storedReentryTests :: [TestTree]
storedReentryTests =
    [ testCase "stored read discloses the exact protected version and origin" $
        withEntry $ \session -> do
            key <- expectKey "stored-read-version"
            absent <- expectKey "stored-read-absent"
            let tape = recordTape session tapeSubject
            before <- publishRawTapeRecord session key (renderOriginRecord sampleRecord)
            result <- readStoredOrigin tape key >>= OwnershipFixture.expectRight
            case result of
                Nothing -> assertFailure "the stored origin disappeared"
                Just stored -> do
                    storedOriginRecord stored @?= sampleRecord
                    storedRecordVersion stored @?= protectedRecordVersion before
            readStoredOrigin tape absent >>= (@?= Right Nothing)
            readProtectedRecord session key >>= (@?= Right (Just before))
    , testCase "stored kernel re-entry discloses the actual target body and identity without a primitive" $
        withEntry $ \session -> do
            identity <- expectIdentity (OwnershipFixture.kernelIdentityWords 13 19)
            bound <- expectBound (bindOriginRecord identity (originRecord OwnedDirectory OriginAbsent))
            withStoredOrigin session bound $ \stored -> do
                result <- reenterStoredOwnedObject (unreachableRow fullCapabilities) session "/stored/kernel" stored
                    (boundEvidence (\target body observed -> pure (Right (target, body, observed))))
                result @?= Right ("/stored/kernel", bound, identity)
    , testCase "stored unbound records mint no token on either face" $
        withEntry $ \session ->
            withStoredOrigin session sampleRecord $ \stored -> do
                let refusal = Left (OwnershipMalformed "this record names no identity binding, so it authorizes no release") :: Either OwnershipFault ()
                    unreachable _ = error "unbound stored evidence reached its continuation"
                reenterStoredOwnedObject (unreachableRow fullCapabilities) session "/stored/unbound" stored unreachable
                    >>= (@?= refusal)
                reenterStoredReportedObject session "/stored/unbound" stored unreachable
                    >>= (@?= refusal)
    , testCase "stored kernel re-entry checks capability before forcing its stored record" $
        withEntry $ \session -> do
            result <- try (reenterStoredOwnedObject (unreachableRow noCapabilities) session "/stored/unsupported"
                (error "the stored record was forced before capability refusal")
                (\_ -> error "unsupported stored re-entry reached its continuation"))
            expectUnsupported result
    , testCase "stored reported re-entry discloses the actual reported record without a row" $
        withEntry $ \session -> do
            let identity = forceIdentity "stored-reported-identity"
            bound <- expectBound (bindOriginRecord identity sampleRecord)
            withStoredOrigin session bound $ \stored -> do
                result <- reenterStoredReportedObject session "/stored/reported" stored
                    (boundEvidence (\target body observed -> pure (Right (target, body, observed))))
                result @?= Right ("/stored/reported", bound, identity)
    , testCase "stored reported re-entry refuses a bound kernel record before its continuation" $
        withEntry $ \session -> do
            identity <- expectIdentity (OwnershipFixture.kernelIdentityWords 13 19)
            bound <- expectBound (bindOriginRecord identity (originRecord OwnedDirectory OriginAbsent))
            withStoredOrigin session bound $ \stored -> do
                result <- reenterStoredReportedObject session "/stored/kernel" stored
                    (\_ -> error "a kernel record reached reported re-entry")
                result @?= (Left (OwnershipUnsupported "this record describes a kernel object, not a reported object") :: Either OwnershipFault ())
    , testCase "stored evidence is nominal and its sole mint uses the existing decoder" $
        withCoreSourceRoot $ \sourceRoot -> do
            tape <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Tape.hs")
            primitive <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Primitive.hs")
            let tokens = SourceGuard.haskellTokens tape
            assertBool "the stored entry index is nominal"
                (isInfixOf ["type", "role", "StoredOriginRecord", "nominal"] tokens)
            mint <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "readStoredRecordUnder" tape)
            assertBool "the mint delegates to the existing versioned decoder" (elem "readVersionedRecordUnder" mint)
            assertBool "the mint seals the actual decoded record" (elem "StoredOriginRecord" mint)
            reported <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "reenterStoredReportedObject" primitive)
            mapM_ (\name -> assertBool ("reported stored re-entry reaches " <> name) (not (elem name reported)))
                ["OwnershipRow", "OwnershipPrimitive", "withOwnershipRow", "rowObserveIdentity", "rowOpenExclusive",
                 "rowCreateDirectory", "rowCreateFile", "rowLinkNoReplace", "rowReadObject", "rowRemoveObject",
                 "rowCloseHandle", "rowSyncParent", "identityOfCreated"]

    , testCase "all production re-entry requires the exact stored-evidence boundary" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            let repoRoot = takeDirectory (takeDirectory packageRoot)
                roots = map (packageRoot </>) ["src", "internal", "app", "provider-live"]
                    <> [repoRoot </> "demo" </> "src"]
            sources <- concat <$> traverse SourceGuard.readHaskellSources roots
            [(path, names) | (path, source) <- sources,
                let names = unconstrainedReentryIdentifiers source, not (null names)] @?= []
            primitive <- readFile (packageRoot </> "internal" </> "ownership" </> "HostBootstrap" </> "Ownership" </> "Primitive.hs")
            exports <- maybe (assertFailure "the ownership export list is absent") pure
                (SourceGuard.moduleExportTokens "HostBootstrap.Ownership.Primitive" primitive)
            for_ ["reenterStoredOwnedObject", "reenterStoredReportedObject"] $ \name ->
                assertBool ("the strict producer is exported: " <> name) (elem name exports)
            for_ ["reenterOwnedObject", "reenterReportedObject"] $ \name -> do
                assertBool ("the unconstrained producer is not exported: " <> name) (not (elem name exports))
                unconstrainedReentryIdentifiers
                    ("module Violation where\n" <> name <> " session target record use = use record\n")
                    @?= [name]
                unconstrainedReentryIdentifiers
                    ("module Violation where\nforged = " <> name
                        <> " row session target (originRecord OwnedDirectory OriginAbsent) use\n")
                    @?= [name]
            unconstrainedReentryIdentifiers
                "-- reenterOwnedObject\nexample = \"reenterReportedObject\"\n" @?= []
    , testCase "unsupported protected-store clauses remain unsupported ownership" $
        storeFault "outer operation" (ProtectedUnsupported "write the origin" "permission denied")
            @?= OwnershipUnsupported "cannot write the origin: permission denied"

    ]

storedCallerAdoptionTests :: [TestTree]
storedCallerAdoptionTests =
    [ testCase "data-root release and recovery retain stored origin evidence" $
        withMainSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Harness" </> "DataRoot.hs")
            for_ ["releaseDataRoot", "recoverDataRoot"] $ \name -> do
                tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens name source)
                assertBool (name <> " must read its stored origin") (elem "readStoredRecordUnder" tokens)
                assertBool (name <> " must consume stored evidence") (elem "reenterStoredOwnedObject" tokens)
            SourceGuard.countHaskellIdentifier "reenterOwnedObject" source @?= 0
            SourceGuard.countHaskellIdentifier "readRecordUnder" source @?= 0
    , testCase "generated-config release and recovery retain stored origin evidence" $
        withMainSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Harness" </> "GeneratedConfig.hs")
            for_ ["releaseGeneratedConfig", "recoverGeneratedConfig"] $ \name -> do
                tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens name source)
                assertBool (name <> " must read its stored origin") (elem "readStoredRecordUnder" tokens)
                assertBool (name <> " must consume stored evidence") (elem "reenterStoredOwnedObject" tokens)
                assertBool (name <> " must retain policy data") (elem "storedOriginRecord" tokens)
            SourceGuard.countHaskellIdentifier "reenterOwnedObject" source @?= 0
            SourceGuard.countHaskellIdentifier "readRecordUnder" source @?= 0
    , testCase "shipped give-back retains stored origin evidence" $
        withMainSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Shipped.hs")
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "inEntry" source)
            assertBool "the shipped entry reads stored evidence" (elem "readStoredRecordUnder" tokens)
            assertBool "the shipped entry consumes stored evidence" (elem "reenterStoredOwnedObject" tokens)
            SourceGuard.countHaskellIdentifier "reenterOwnedObject" source @?= 0
            length (filter (== "readStoredRecordUnder") tokens) @?= 2
            leaseTokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "withShippedDirectoryLease" source)
            length (filter (== "readStoredRecordUnder") leaseTokens) @?= 1
            for_ ["reenterStoredOwnedObject", "storedOriginRecord", "originRecordKind",
                  "originRecordOrigin", "originRecordBinding"] $ \name ->
                assertBool ("the directory lease must retain stored evidence and policy: " <> name) (elem name leaseTokens)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "giveBack = do stored <- readStoredRecordUnder (shippedTape session) key")
                source @?= 1
    , testCase "provider claim re-entry retains stored origin evidence" $
        withMainSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Substrate" </> "Provider" </> "Ownership.hs")
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "withBoundInstanceClaim" source)
            for_ ["readStoredRecordUnder", "storedOriginRecord", "reenterStoredReportedObject",
                  "originRecordKind", "originRecordOrigin", "originRecordBinding"] $ \name ->
                assertBool ("the provider claim helper must use " <> name) (elem name tokens)
            SourceGuard.countHaskellIdentifier "reenterReportedObject" source @?= 0
    , testCase "cluster node-claim re-entry retains stored origin evidence" $
        SourceGuard.withPackageSourceIn ["internal", "cluster-ownership"] $ \_ sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Cluster" </> "Ownership.hs")
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "withBoundNodeClaim" source)
            for_ ["readStoredRecordUnder", "storedOriginRecord", "reenterStoredReportedObject",
                  "originRecordKind", "originRecordOrigin", "originRecordBinding"] $ \name ->
                assertBool ("the cluster node-claim helper must use " <> name) (elem name tokens)
            SourceGuard.countHaskellIdentifier "reenterReportedObject" source @?= 0
    , testCase "Colima re-entry and namespace clearing retain stored parent evidence" $
        SourceGuard.withPackageSourceIn [] $ \driverPackageRoot _ -> do
            raw <- ByteString.readFile (driverPackageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            source <- either (assertFailure . show) (pure . Text.unpack) (TextEncoding.decodeUtf8' raw)
            cleanup <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "cleanupManagedColimaProfileWith" source)
            namespace <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "releaseNamespaceRemainders" source)
            assertBool "Colima cleanup delegates its retained namespace to the shared walker" ("releaseNamespaceRemainders" `elem` cleanup)
            let tokens = cleanup <> namespace
            for_ ["readStoredRecordUnder", "storedOriginRecord", "storedRecordVersion",
                  "reenterStoredReportedObject", "reenterStoredOwnedObject", "reobserveOwnedIdentity",
                  "projectOwnershipManifest", "admitOwnershipManifestRemainders", "releaseManifestRemainder"] $ \name ->
                assertBool ("Colima cleanup must retain " <> name) (elem name tokens)
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                native <- readFile (packageRoot </> "internal" </> "ownership" </> "HostBootstrap" </> "Ownership" </> "Posix.hs")
                clauses <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionClauseTokens "posixReleaseManifestEntry" native)
                let nativeTokens = concat clauses
                for_ ["expectedRoot", "identityOfStatus", "manifestEntryIdentity", "manifestEntryKind",
                      "openFdAt", "nofollow", "c_manifestUnlinkAt", "fileSynchronise",
                      "manifestEntryStatusAt", "isDoesNotExistError"] $ \name ->
                    assertBool ("raw namespace clearing must retain " <> name) (elem name nativeTokens)
            SourceGuard.countHaskellIdentifier "reenterOwnedObject" source @?= 0
            SourceGuard.countHaskellIdentifier "bindOriginRecord" source @?= 0
            SourceGuard.countHaskellIdentifier "readVersionedRecordUnder" source @?= 0
    , testCase "POSIX namespace operations retain descriptor-relative parent lookup" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            native <- readFile (packageRoot </> "internal" </> "ownership" </> "HostBootstrap" </> "Ownership" </> "Posix.hs")
            for_ ["getSymbolicLinkStatus", "createDirectory", "createLink", "removeDirectory", "removeLink"] $ \name -> do
                SourceGuard.countHaskellIdentifier name native @?= 0
                SourceGuard.countHaskellIdentifier name (name <> " target") @?= 1
            for_ ["posixObserveIdentity", "posixOpenExclusive", "posixCreateDirectory", "posixCreateFile",
                  "posixLinkNoReplace", "posixRemoveObject", "posixSyncParent",
                  "posixObserveOwnershipManifest", "posixReleaseManifestEntry"] $ \name -> do
                clauses <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionClauseTokens name native)
                let tokens = concat clauses
                assertBool ("the actual " <> name <> " must retain its parent")
                    (any (\candidate -> elem candidate tokens) ["withPathParent", "withPathParentResult"])
            parent <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "withPathParent" native)
            for_ ["openFdAt", "nofollow", "directory", "cloexec", "bracket", "closeFd"] $ \name ->
                assertBool ("the shared parent traversal must retain " <> name) (elem name parent)
    ]

-- | The same lexical guard is applied to physical production files and violating controls.
unconstrainedReentryIdentifiers :: String -> [String]
unconstrainedReentryIdentifiers source =
    [name | name <- ["reenterOwnedObject", "reenterReportedObject"],
        SourceGuard.countHaskellIdentifier name source > 0]


computationSiteTests :: [TestTree]
computationSiteTests =
    [ testCase "physical production sources retain the declared shared computation homes" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            sources <- concat <$> traverse SourceGuard.readHaskellSources
                [packageRoot </> "src", packageRoot </> "internal"]
            let physical = [(SourceGuard.repoRelativePath packageRoot path, source) | (path, source) <- sources]
            SourceGuard.ownershipComputationViolations physical @?= Right []
    , testCase "each shared computation guard rejects its violating module text" $
        for_ controls $ \(label, source, expected) -> do
            violations <- OwnershipFixture.expectRight
                (SourceGuard.ownershipComputationViolations [("src/HostBootstrap/Copy.hs", source)])
            assertBool ("the " <> label <> " guard must bite: " <> show violations)
                (any (isInfixOf expected) violations)
    , testCase "ordinary metadata and comment or string mentions are not ownership computations" $ do
        let source = unlines
                [ "module HostBootstrap.Metadata where"
                , "probe path = getFileStatus path"
                , "-- parseOriginRecord createLink mkKernelObjectIdentity"
                , "description = \"windows.h CreateHardLinkW\""
                , "codecName = \"parseOriginRecord\""
                ]
        SourceGuard.ownershipComputationViolations [("src/HostBootstrap/Metadata.hs", source)] @?= Right []
    , testCase "row declarations are neutral but same-named conditional copies are refused" $ do
        let path = "internal/ownership/HostBootstrap/Ownership/Posix.hs"
            declaration = unlines
                [ "module Example where"
                , "refusingPrimitives = OwnershipPrimitive"
                , "    { rowObserveIdentity = refuse, rowRemoveObject = refuse, rowLinkNoReplace = refuse }"
                ]
            effect = unlines
                [ "module Example where"
                , "refusingPrimitives row target = do"
                , "    seen <- rowObserveIdentity row target"
                , "    rowRemoveObject row target"
                ]
        SourceGuard.ownershipComputationViolations [(path, declaration)] @?= Right []
        violations <- OwnershipFixture.expectRight
            (SourceGuard.ownershipComputationViolations [(path, effect)])
        assertBool "a refusal-like binding name cannot exempt actual copied effects"
            (any (isInfixOf "identity-conditional act") violations)

    ]
  where
    controls =
        [ ("kernel identity", "module Copy where\ncopy path = mkKernelObjectIdentity 1 (getFileStatus path)\n",
            "kernel identity")
        , ("no-replace link", "module Copy where\ncopy = createLink\n", "no-replace link")
        , ("foreign no-replace link", "module Copy where\nforeign import capi unsafe \"windows.h CreateHardLinkW\" copy :: IO ()\n",
            "no-replace link")
        , ("identity act", "module Copy where\ncopy row target = do\n    seen <- rowObserveIdentity row target\n    rowRemoveObject row target\n",
            "identity-conditional act")
        , ("act definition", "module Copy where\nreobserveOwnedIdentity token = pure token\n",
            "shared definition")
        , ("origin codec", "module Copy where\nparseOriginRecord bytes = Right bytes\n", "origin record codec")
        , ("scoped read definition", "module Copy where\nreadWholeObject row target = pure target\n", "shared definition")
        ]


creatingOriginTests :: [TestTree]
creatingOriginTests =
    [ testCase "occupied recorded origins refuse both creators before any primitive" $ do
        identity <- expectIdentity (OwnershipFixture.kernelIdentityWords 17 23)
        let payload = mkPayload "managed bytes"
        for_ [OwnedDirectory, OwnedFile (payloadDigest payload)] $ \kind ->
            withEntry $ \session -> do
                let row = observingRow fullCapabilities (Right (Just identity))
                result <- enterOwnedObject row session "/occupied/target" $ \entered -> do
                    saved <- recordOwnedOrigin row entered kind (const (pure (Right ())))
                    case saved of
                        Left fault -> pure (Left fault)
                        Right recorded -> do
                            recordedEvidence (\_ record -> originRecordOrigin record) recorded @?= OriginPresent identity
                            created <- case kind of
                                OwnedDirectory -> createOwnedDirectory row recorded
                                OwnedFile _ -> publishOwnedFile row recorded payload "/occupied/staging"
                                ReportedObject _ -> assertFailure "the fixture names only kernel-created objects"
                            case created of
                                Left (OwnershipOccupied _) -> pure (Right ())
                                Left fault -> assertFailure ("expected occupied origin refusal, got " <> show fault)
                                Right _ -> assertFailure "a present origin reached a creator"
                OwnershipFixture.expectRight result
    , testCase "a failed real link retains its fault and target while attempting staging withdrawal" $
        for_ [False, True] $ \refuseCleanup ->
            withHostRecordedFile $ \session recorded payload target staging key -> do
                ByteString.writeFile target "operator bytes"
                targetIdentity <- OwnershipFixture.expectRight =<< withOwnershipRow ownershipRowForHost (\row -> rowObserveIdentity row target)
                assertBool "the actual target has an identity" (isJust targetIdentity)
                before <- expectTapeRecord session key
                linkFault <- newIORef Nothing
                let cleanupFault = OwnershipProbeFailed "withdraw fixture staging" "injected refusal"
                    row = withOwnershipRow ownershipRowForHost $ \primitives ->
                        ownershipRow (primitives
                            { rowLinkNoReplace = \source destination -> do
                                outcome <- rowLinkNoReplace primitives source destination
                                case outcome of
                                    Left fault -> writeIORef linkFault (Just fault)
                                    Right () -> pure ()
                                pure outcome
                            , rowRemoveObject = \path ->
                                if refuseCleanup then pure (Left cleanupFault) else rowRemoveObject primitives path
                            })
                result <- publishOwnedFile row recorded payload staging
                observed <- readIORef linkFault >>= maybe (assertFailure "the actual link did not refuse") pure
                case observed of
                    OwnershipOccupied _ -> pure ()
                    other -> assertFailure ("expected the real no-replace collision, got " <> show other)
                result @?= Left observed
                doesPathExist staging >>= (@?= refuseCleanup)
                ByteString.readFile target >>= (@?= "operator bytes")
                withOwnershipRow ownershipRowForHost (\primitives -> rowObserveIdentity primitives target)
                    >>= (@?= Right targetIdentity)
                expectTapeRecord session key >>= (@?= before)
    , testCase "a failed staging create preserves the existing foreign stage" $
        withHostRecordedFile $ \session recorded payload target staging key -> do
            ByteString.writeFile staging "foreign staging bytes"
            stagingIdentity <- OwnershipFixture.expectRight =<< withOwnershipRow ownershipRowForHost (\row -> rowObserveIdentity row staging)
            assertBool "the actual foreign stage has an identity" (isJust stagingIdentity)
            before <- expectTapeRecord session key
            result <- publishOwnedFile ownershipRowForHost recorded payload staging
            case result of
                Left (OwnershipOccupied _) -> pure ()
                Left fault -> assertFailure ("expected the real exclusive-create collision, got " <> show fault)
                Right _ -> assertFailure "the foreign staging object was replaced"
            ByteString.readFile staging >>= (@?= "foreign staging bytes")
            withOwnershipRow ownershipRowForHost (\row -> rowObserveIdentity row staging)
                >>= (@?= Right stagingIdentity)
            doesPathExist target >>= (@?= False)
            expectTapeRecord session key >>= (@?= before)
    ]

-- | Real observation and durable publication precede each host creating-producer case.
withHostRecordedFile ::
    (forall session object. ProtectedSession session -> Recorded session object ->
        Payload -> FilePath -> FilePath -> RecordKey -> IO ()) ->
    IO ()
withHostRecordedFile use =
    withEntry $ \session -> do
        let target = sessionStoreRoot session </> "created-target"
            staging = sessionStoreRoot session </> "created-staging"
            payload = mkPayload "managed bytes"
        key <- expectKey "creating-origin"
        result <- enterOwnedObject ownershipRowForHost session target $ \entered -> do
            saved <- recordOwnedOrigin ownershipRowForHost entered (OwnedFile (payloadDigest payload))
                (\record -> Right () <$ publishRawTapeRecord session key (renderOriginRecord record))
            case saved of
                Left fault -> pure (Left fault)
                Right recorded -> Right () <$ use session recorded payload target staging key
        OwnershipFixture.expectRight result

-- ---------------------------------------------------------------------------
-- The operational lifetime of typed ownership effects

entryLifetimeTests :: [TestTree]
entryLifetimeTests =
    [ testCase "delayed entry and successor effects refuse after normal or exceptional exit" $
        for_ [False, True] $ \exceptional -> do
            saved <- newIORef []
            outcome <- try $ withEntry $ \session -> do
                actions <- entryLifetimeActions session
                writeIORef saved actions
                if exceptional
                    then throwIO (AssertionFailed "entry exits exceptionally")
                    else pure ()
            case (outcome :: Either SomeException ()) of
                Right () -> assertBool "normal exit was requested" (not exceptional)
                Left failure -> case fromException failure of
                    Just (AssertionFailed message) -> do
                        assertBool "exceptional exit was requested" exceptional
                        message @?= "entry exits exceptionally"
                    Nothing -> assertFailure ("unexpected entry exception: " <> show failure)
            actions <- readIORef saved
            length actions @?= 15
            for_ actions $ \(name, action) ->
                assertEntryRefused name "the protected session is no longer live" action
    , testCase "foreign-thread entry and successor effects refuse while the entry remains live" $
        withEntry $ \session -> do
            actions <- entryLifetimeActions session
            onForeignThread $ do
                verifyProtectedSession session
                    >>= (@?= Left (ProtectedInvalid "the protected session belongs to another thread"))
                for_ actions $ \(name, action) ->
                    assertEntryRefused name "the protected session belongs to another thread" action
            verifyProtectedSession session >>= (@?= Right ())
            enterReportedObject session "/live/control" OriginAbsent (\_ -> pure (Right ()))
                >>= (@?= Right ())
    , testCase "refused real releases preserve the file and envelope and a live retry settles both" $
        withSystemTempDirectory "hostbootstrap-ownership-entry-lifetime" $ \root -> do
            store <- openProtectedStore root >>= OwnershipFixture.expectRight
            key <- expectKey "entry-lifetime-file"
            let target = root </> "owned-file"
                staging = root </> "owned-stage"
                payload = mkPayload "live entry payload"
                row = ownershipRowForHost
            deferred <- newIORef Nothing
            beforeRef <- newIORef Nothing
            identityRef <- newIORef Nothing
            held <- withProtectedEntry store $ \session -> do
                let tape = recordTape session tapeSubject
                result <- enterOwnedObject row session target $ \entered -> do
                    recorded <- recordOwnedOrigin row entered (OwnedFile (payloadDigest payload))
                        (publishFreshRecord tape key) >>= OwnershipFixture.expectRight
                    identity <- publishOwnedFile row recorded payload staging >>= OwnershipFixture.expectRight
                    bound <- bindOwnedIdentity row recorded identity (publishBoundRecord tape key)
                        >>= OwnershipFixture.expectRight
                    releasable <- reobserveOwnedIdentity row bound >>= OwnershipFixture.expectRight
                    before <- expectTapeRecord session key
                    let release = releaseOwnedObject row releasable
                            (\_ -> forgetRecordAtVersion tape key (protectedRecordVersion before))
                    writeIORef deferred (Just release)
                    writeIORef beforeRef (Just before)
                    writeIORef identityRef (Just identity)
                    onForeignThread $
                        assertEntryRefused "actual foreign-thread release"
                            "the protected session belongs to another thread" release
                    ByteString.readFile target >>= (@?= "live entry payload")
                    expectTapeRecord session key >>= (@?= before)
                    withOwnershipRow row (\primitives -> rowObserveIdentity primitives target)
                        >>= (@?= Right (Just identity))
                    pure (Right ())
                OwnershipFixture.expectRight result
                pure (Right ())
            OwnershipFixture.expectRight held
            release <- readIORef deferred >>= maybe (assertFailure "no real release was retained") pure
            assertEntryRefused "actual expired release" "the protected session is no longer live" release
            ByteString.readFile target >>= (@?= "live entry payload")
            before <- readIORef beforeRef >>= maybe (assertFailure "no envelope was captured") pure
            identity <- readIORef identityRef >>= maybe (assertFailure "no real identity was captured") pure
            withOwnershipRow row (\primitives -> rowObserveIdentity primitives target)
                >>= (@?= Right (Just identity))
            retried <- withProtectedEntry store $ \session -> do
                readProtectedRecord session key >>= (@?= Right (Just before))
                let tape = recordTape session tapeSubject
                stored <- readStoredOrigin tape key >>= OwnershipFixture.expectRight
                    >>= maybe (assertFailure "the preserved origin disappeared") pure
                result <- reenterStoredOwnedObject row session target stored $ \bound -> do
                    releasable <- reobserveOwnedIdentity row bound >>= OwnershipFixture.expectRight
                    releaseOwnedObject row releasable
                        (\_ -> forgetRecordAtVersion tape key (storedRecordVersion stored))
                OwnershipFixture.expectRight result
                readProtectedRecord session key >>= (@?= Right Nothing)
                pure (Right ())
            OwnershipFixture.expectRight retried
            doesPathExist target >>= (@?= False)
    , testCase "every typed effect follows the shared live-entry check and tokens retain the session" $
        withCoreSourceRoot $ \sourceRoot -> do
            primitive <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Primitive.hs")
            internal <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Internal.hs")
            protected <- readFile (sourceRoot </> "HostBootstrap" </> "Protected.hs")
            let edges =
                    [ ("enterOwnedObject", "withLiveOwnershipEntry")
                    , ("enterReportedObject", "withLiveOwnershipEntry")
                    , ("reenterStoredOwnedObject", "withLiveOwnershipEntry")
                    , ("reenterStoredReportedObject", "withLiveOwnershipEntry")
                    , ("recordOwnedOrigin", "recordOrigin")
                    , ("recordReportedOrigin", "recordOrigin")
                    , ("recordOrigin", "enteredEvidenceOf")
                    , ("enteredEvidenceOf", "withLiveOwnershipEntry")
                    , ("createOwnedDirectory", "recordedEvidenceOf")
                    , ("publishOwnedFile", "recordedEvidenceOf")
                    , ("bindOwnedIdentity", "bindReportedIdentity")
                    , ("bindReportedIdentity", "recordedEvidenceOf")
                    , ("recordedEvidenceOf", "withLiveOwnershipEntry")
                    , ("reobserveOwnedIdentity", "withLiveOwnershipEntry")
                    , ("releaseOwnedObject", "releasableEvidenceOf")
                    , ("resumeOwnedRemoval", "withLiveOwnershipEntry")
                    , ("releaseReportedObject", "releasableEvidenceOf")
                    , ("resumeReportedRemoval", "withLiveOwnershipEntry")
                    , ("releasableEvidenceOf", "withLiveOwnershipEntry")
                    , ("withLiveOwnershipEntry", "verifyProtectedSession")
                    ]
            for_ edges $ \(name, next) -> do
                tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens name primitive)
                assertBool (name <> " must consume " <> next) (elem next tokens)
            floorTokens <- OwnershipFixture.expectRight
                (SourceGuard.haskellDefinitionTokens "verifyProtectedSession" protected)
            assertBool "the public check consumes the existing runtime floor"
                (elem "withActiveProtectedSession" floorTokens)
            for_ ["Entered", "Recorded", "Bound", "Releasable"] $ \name ->
                assertBool (name <> " retains the actual nominal session")
                    (isInfixOf [name, "(", "ProtectedSession", "session", ")"] (SourceGuard.haskellTokens internal))
    ]

-- These actual entry/store reads set up closures, while the divergent row and
-- callbacks prove refusal ordering only; they do not claim kernel success.
entryLifetimeActions :: ProtectedSession session -> IO [(String, IO (Either OwnershipFault ()))]
entryLifetimeActions session = do
    verifyProtectedSession session >>= (@?= Right ())
    let identity = forceIdentity "entry-lifetime-identity"
        kind = ReportedObject (mkOwnerClaim "entry-lifetime-owner")
        row = unreachableRow fullCapabilities
        never :: argument -> IO (Either OwnershipFault result)
        never _ = error "a revoked ownership entry reached a callback"
    key <- expectKey "entry-lifetime-stored"
    record <- expectBound (bindOriginRecord identity (originRecord kind OriginAbsent))
    _ <- publishRawTapeRecord session key (renderOriginRecord record)
    stored <- readStoredOrigin (recordTape session tapeSubject) key
        >>= OwnershipFixture.expectRight >>= maybe (assertFailure "the actual stored origin disappeared") pure
    result <- enterReportedObject session "/lifetime/target" OriginAbsent $ \entered -> do
        recorded <- recordReportedOrigin entered (mkOwnerClaim "entry-lifetime-owner") (\_ -> pure (Right ())) >>= OwnershipFixture.expectRight
        bound <- bindReportedIdentity recorded identity (\_ -> pure (Right ())) >>= OwnershipFixture.expectRight
        releasable <- OwnershipFixture.expectRight (reobserveReportedIdentity bound (OriginPresent identity))
        pure (Right
            [ ("kernel entry", enterOwnedObject row session "/lifetime/kernel" never)
            , ("reported entry", enterReportedObject session "/lifetime/reported" OriginAbsent never)
            , ("stored kernel entry", reenterStoredOwnedObject row session "/lifetime/stored-kernel" stored never)
            , ("stored reported entry", reenterStoredReportedObject session "/lifetime/stored-reported" stored never)
            , ("kernel record", unitOwnership (recordOwnedOrigin row entered kind never))
            , ("reported record", unitOwnership (recordReportedOrigin entered (mkOwnerClaim "entry-lifetime-owner") never))
            , ("directory creation", unitOwnership (createOwnedDirectory row recorded))
            , ("file publication", unitOwnership (publishOwnedFile row recorded (mkPayload "lifetime bytes") "/lifetime/stage"))
            , ("kernel binding", unitOwnership (bindOwnedIdentity row recorded identity never))
            , ("reported binding", unitOwnership (bindReportedIdentity recorded identity never))
            , ("kernel re-observation", unitOwnership (reobserveOwnedIdentity row bound))
            , ("kernel release", releaseOwnedObject row releasable never)
            , ("kernel removal recovery", resumeOwnedRemoval row bound never)
            , ("reported release", releaseReportedObject releasable OriginAbsent never)
            , ("resumed reported removal", resumeReportedRemoval bound OriginAbsent never)
            ])
    OwnershipFixture.expectRight result

unitOwnership :: IO (Either OwnershipFault result) -> IO (Either OwnershipFault ())
unitOwnership = fmap (fmap (const ()))

assertEntryRefused :: String -> Text -> IO (Either OwnershipFault ()) -> IO ()
assertEntryRefused name message action = do
    outcome <- try action
    case outcome of
        Left (failure :: SomeException) -> assertFailure (name <> " reached an effect: " <> show failure)
        Right result ->
            result @?= Left (storeFault "use the ownership entry" (ProtectedInvalid message))

onForeignThread :: IO () -> IO ()
onForeignThread action = do
    completed <- newEmptyMVar
    _ <- forkFinally action (putMVar completed)
    outcome <- takeMVar completed
    either (assertFailure . show) pure outcome

-- ---------------------------------------------------------------------------
-- Actual kernel handle lifetime, separately from typed origin authority

wholeObjectReadTests :: [TestTree]
wholeObjectReadTests =
    [ testCase "a successful whole-object read returns bytes and closes the actual handle" $
        withWholeObjectRead $ \hostRow target bytes ->
            withOwnershipRow hostRow $ \primitives -> do
                probe <- newIORef Nothing
                callerMask <- getMaskingState
                let row = ownershipRow (primitives
                        { rowOpenExclusive = \path -> do
                            state <- getMaskingState
                            assertBool "acquisition is masked" (state /= Unmasked)
                            captureActualRead probe primitives path
                        , rowReadObject = \handle -> do
                            getMaskingState >>= (@?= callerMask)
                            rowReadObject primitives handle
                        , rowCloseHandle = \handle -> do
                            state <- getMaskingState
                            assertBool "cleanup is masked" (state /= Unmasked)
                            rowCloseHandle primitives handle
                        })
                readWholeObject row target >>= (@?= Right bytes)
                assertActualHandleClosed probe
                ByteString.readFile target >>= (@?= bytes)
    , testCase "typed read and close faults retain read-first priority and close the actual handle" $
        for_ [(True, False), (False, True), (True, True)] $ \(failRead, failClose) ->
            withWholeObjectRead $ \hostRow target bytes ->
                withOwnershipRow hostRow $ \primitives -> do
                    probe <- newIORef Nothing
                    let readFault = OwnershipProbeFailed "read the fixture" "typed read refusal"
                        closeFault = OwnershipProbeFailed "close the fixture" "typed close refusal"
                        row = ownershipRow (primitives
                            { rowOpenExclusive = captureActualRead probe primitives
                            , rowReadObject = \handle -> do
                                actual <- rowReadObject primitives handle
                                actual @?= Right bytes
                                pure (if failRead then Left readFault else actual)
                            , rowCloseHandle = \handle -> do
                                actual <- rowCloseHandle primitives handle
                                pure (if failClose then Left closeFault else actual)
                            })
                    readWholeObject row target >>= (@?= Left (if failRead then readFault else closeFault))
                    assertActualHandleClosed probe
    , testCase "a synchronous read exception retains its primary error even when cleanup throws" $
        for_ [False, True] $ \throwCleanup ->
            withWholeObjectRead $ \hostRow target bytes ->
                withOwnershipRow hostRow $ \primitives -> do
                    probe <- newIORef Nothing
                    let row = ownershipRow (primitives
                            { rowOpenExclusive = captureActualRead probe primitives
                            , rowReadObject = \handle -> do
                                rowReadObject primitives handle >>= (@?= Right bytes)
                                throwIO (userError "primary read exception")
                            , rowCloseHandle = \handle -> do
                                actual <- rowCloseHandle primitives handle
                                if throwCleanup
                                    then throwIO (AssertionFailed "cleanup must not replace the read exception")
                                    else pure actual
                            })
                    outcome <- try (readWholeObject row target)
                    case (outcome :: Either IOException (Either OwnershipFault ByteString)) of
                        Left failure -> ioeGetErrorString failure @?= "primary read exception"
                        Right other -> assertFailure ("the read exception disappeared: " <> show other)
                    assertActualHandleClosed probe
    , testCase "asynchronous interruption restores the read mask and closes the actual handle" $
        withWholeObjectRead $ \hostRow target bytes ->
            withOwnershipRow hostRow $ \primitives -> do
                probe <- newIORef Nothing
                ready <- newEmptyMVar
                gate <- newEmptyMVar
                completed <- newEmptyMVar
                let row = ownershipRow (primitives
                        { rowOpenExclusive = captureActualRead probe primitives
                        , rowReadObject = \handle -> do
                            getMaskingState >>= (@?= Unmasked)
                            actual <- rowReadObject primitives handle
                            actual @?= Right bytes
                            putMVar ready ()
                            takeMVar gate >>= \() -> pure actual
                        })
                reader <- forkFinally (readWholeObject row target) $ \outcome -> do
                    _ <- tryPutMVar ready ()
                    putMVar completed outcome
                takeMVar ready
                throwTo reader ThreadKilled
                outcome <- takeMVar completed
                case outcome of
                    Left failure -> (fromException failure :: Maybe AsyncException) @?= Just ThreadKilled
                    Right other -> assertFailure ("the interrupted read returned: " <> show other)
                assertActualHandleClosed probe
    , testCase "an actual open refusal reaches no read or close" $
        withWholeObjectRead $ \hostRow target _ ->
            withOwnershipRow hostRow $ \primitives -> do
                let missing = target <> ".missing"
                actual <- rowOpenExclusive primitives missing
                case actual of
                    Right handle -> do
                        _ <- rowCloseHandle primitives handle
                        assertFailure "the absent path unexpectedly opened"
                    Left fault -> do
                        let row = ownershipRow (primitives
                                { rowReadObject = \_ -> error "an open refusal reached read"
                                , rowCloseHandle = \_ -> error "an open refusal reached close"
                                })
                        readWholeObject row missing >>= (@?= Left fault)
    , testCase "a cleanup exception propagates after a successful actual read" $
        withWholeObjectRead $ \hostRow target bytes ->
            withOwnershipRow hostRow $ \primitives -> do
                probe <- newIORef Nothing
                let row = ownershipRow (primitives
                        { rowOpenExclusive = captureActualRead probe primitives
                        , rowReadObject = \handle -> do
                            actual <- rowReadObject primitives handle
                            actual @?= Right bytes
                            pure actual
                        , rowCloseHandle = \handle -> do
                            _ <- rowCloseHandle primitives handle
                            throwIO (userError "close exception after a successful read")
                        })
                outcome <- try (readWholeObject row target)
                case (outcome :: Either IOException (Either OwnershipFault ByteString)) of
                    Left failure -> ioeGetErrorString failure @?= "close exception after a successful read"
                    Right other -> assertFailure ("the close exception disappeared: " <> show other)
                assertActualHandleClosed probe
    ]

withWholeObjectRead :: (OwnershipRow -> FilePath -> ByteString -> IO ()) -> IO ()
withWholeObjectRead use =
    withSystemTempDirectory "hostbootstrap-whole-object-read" $ \root -> do
        let target = root </> "read-target"
            bytes = "actual whole-object bytes"
        ByteString.writeFile target bytes
        use ownershipRowForHost target bytes

-- The retained closure performs an actual read on the same opened kernel handle.
captureActualRead ::
    IORef (Maybe (IO (Either OwnershipFault ByteString))) ->
    OwnershipPrimitive handle ->
    FilePath ->
    IO (Either OwnershipFault handle)
captureActualRead probe primitives path = do
    opened <- rowOpenExclusive primitives path
    case opened of
        Left fault -> pure (Left fault)
        Right handle -> do
            writeIORef probe (Just (rowReadObject primitives handle))
            pure (Right handle)

assertActualHandleClosed :: IORef (Maybe (IO (Either OwnershipFault ByteString))) -> IO ()
assertActualHandleClosed probe = do
    actualRead <- readIORef probe >>= maybe (assertFailure "no actual opened handle was retained") pure
    result <- actualRead
    case result of
        Left (OwnershipProbeFailed _ _) -> pure ()
        other -> assertFailure ("the actual handle did not report closed: " <> show other)

scopedReadAdoptionTests :: [TestTree]
scopedReadAdoptionTests =
    [ testCase "the host wall delegates its bytes to the shared scope" $
        withMainSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Wsl2" </> "GlobalWall" </> "Host.hs")
            names <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionNames source)
            assertBool "the wall has no local readWholeObject transaction" (not (elem "readWholeObject" names))
            observed <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "observeWallFile" source)
            for_ ["readWholeObject", "entryRow", "fromOwnershipFault"] $ \name ->
                assertBool ("the wall observation must use " <> name) (elem name observed)
            for_ ["rowOpenExclusive", "rowReadObject", "rowCloseHandle"] $ \name ->
                SourceGuard.countHaskellIdentifier name source @?= 0
    , testCase "the generated config delegates payload bytes to the shared scope" $
        withMainSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Harness" </> "GeneratedConfig.hs")
            names <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionNames source)
            assertBool "the config has no local readThroughRow transaction" (not (elem "readThroughRow" names))
            checked <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "payloadStillMatches" source)
            assertBool "payload verification uses the shared read" (elem "readWholeObject" checked)
            for_ ["rowOpenExclusive", "rowReadObject", "rowCloseHandle"] $ \name ->
                SourceGuard.countHaskellIdentifier name source @?= 0

    ]
