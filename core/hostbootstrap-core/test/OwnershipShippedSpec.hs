{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The frame table's third ownership row, exercised as a transport.

Three kinds of evidence and no others (§ NN):

1. the transaction's encoding, the outcome's encoding, and the frame table's
   ownership column are total functions, so every case and every refusal is
   reached by applying them to values;
2. the far-side interpreter is applied to a transaction in this process, against
   the production row and a real protected store in a temporary directory, so
   the clauses it holds are held against a real kernel;
3. the empty-context crossing is driven through a __real child process__ — the
   production classifier, the shared production frame-transaction dispatcher,
   and the argument vector the lift fold places at the leaf — so "the transaction reached another process and
   an answer came back" is a property of a program that would not finish if it
   were false.

A crossing into a provider frame is the worked-demo phase's to confirm live and
is not simulated here.
-}
module OwnershipShippedSpec (tests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (ArithException (DivideByZero), throwIO, try)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Expect (expectRight)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word8)
import HostBootstrap.Effect.Vocabulary (
    EffectFrame (CrossedInto, OuterHost),
    FrameCrossing (CrossContainer, CrossIncusVM, CrossLimaVM, CrossWsl2VM),
 )
import HostBootstrap.HostConfig (HostConfig (HostConfig, hcSubstrate, hcToolPaths))
import HostBootstrap.Incus (IncusVM (IncusVM, vmImage, vmName))
import HostBootstrap.Lift (InVMSelfPath (InVMSelfPath), LocalSelfPath (LocalSelfPath), emptyVMStack, inVM, localContext, mkSelfRef, vmContext)
import HostBootstrap.Ownership.Object (
    ConflictReport (ConflictReport, conflictExpected, conflictObserved, conflictSubject),
    ObjectIdentity,
    ObjectKind (OwnedDirectory),
    Origin (OriginAbsent, OriginPresent),
    OwnershipFault (
        OwnershipConflict,
        OwnershipMalformed,
        OwnershipOccupied,
        OwnershipProbeFailed,
        OwnershipUnsupported
    ),
    bindOriginRecord,
    mkPayload,
    originRecord,
    originRecordBinding,
    originRecordKind,
    originRecordOrigin,
    parseOriginRecord,
    renderOriginRecord,
 )
import HostBootstrap.Ownership.Primitive (rowObserveIdentity, withOwnershipRow)
import HostBootstrap.Ownership.Row (hostOwnershipSupported, ownershipRowForHost)
import HostBootstrap.Ownership.Shipped
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    ProtectedRecord (protectedRecordBytes),
    RecordKey,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    openProtectedStore,
    readProtectedRecord,
    recordKeyText,
    withProtectedEntry,
 )
import HostBootstrap.Substrate (
    Arch (Amd64),
    Substrate (Substrate, substrateArch, substrateName),
    SubstrateName (LinuxCpu),
 )
import HostBootstrap.Substrate.Frame (
    FrameOwnershipRow (HostOwnershipRow, PosixOwnershipRow),
    frameOwnershipRow,
 )
import qualified SourceGuard
import System.Directory (
    createDirectory,
    createFileLink,
    doesDirectoryExist,
    doesFileExist,
    doesPathExist,
    getSymbolicLinkTarget,
    pathIsSymbolicLink,
    removeDirectory,
    removeFile,
    renameDirectory,
    renameFile,
 )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.Process (readProcessWithExitCode)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "OwnershipShippedSpec"
        [ testGroup "the frame table's ownership column" columnTests
        , testGroup "the admitted authority path" authorityPathTests
        , testGroup "the admitted object target path" targetPathTests
        , testGroup "the admitted symbolic-link target path" linkTargetPathTests
        , testGroup "the transaction's own encoding" transactionCodecTests
        , testGroup "the outcome's own encoding" outcomeCodecTests
        , testGroup "the transaction, run where the object is" interpreterTests
        , testGroup "the scoped directory lease" directoryLeaseTests
        , testGroup "the crossing failure classification" crossingFailureTests
        , testGroup "the crossing, across a real process boundary" crossingTests
        ]

-- ---------------------------------------------------------------------------
-- The column

columnTests :: [TestTree]
columnTests =
    [ testCase "the outer host's clauses are held by this binary's own row" $
        frameOwnershipRow OuterHost @?= HostOwnershipRow
    , testCase "the ownership column offers no second routing decision" $
        -- DEVELOPMENT_PLAN/rationale.md: VM crossings share one placement renderer.
        SourceGuard.withPackageSourceIn ["src"] $ \_ sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Substrate" </> "Frame.hs")
            SourceGuard.countHaskellIdentifier "frameOwnsLocally" source @?= 0
    , testCase "the symbolic-link interpreter observes identity through the selected row" $
        SourceGuard.withPackageSourceIn ["src"] $ \_ sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Shipped.hs")
            mapM_ (\name -> SourceGuard.countHaskellIdentifier name source @?= 0)
                ["mkKernelObjectIdentity", "deviceID", "fileID"]
            SourceGuard.countHaskellIdentifier "rowObserveIdentity" source @?= 2
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "withOwnershipRow ownershipRowForHost (\\primitives -> rowObserveIdentity primitives path)")
                source @?= 1
    , testCase "symbolic-link unlink admission consumes the fresh identity observation" $
        SourceGuard.withPackageSourceIn ["src"] $ \_ sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Shipped.hs")
            mapM_
                (\spelling -> SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens spelling) source @?= 1)
                [ "removeExactSymbolicLink row target linkTarget identity (reobserveReportedIdentity bound . OriginPresent)"
                , "observed <- observeSymbolicLink path linkTarget"
                , "case admit current of"
                , "removed <- try (removeLink path)"
                , "Right SymbolicLinkAbsent -> syncSymbolicLinkParent row stage"
                ]
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "Right bound -> case reobserveReportedIdentity bound (OriginPresent current)")
                source @?= 0
    , testCase "every crossing's clauses are held by the POSIX row" $
        -- Every frame this project reaches through a host-provider command is
        -- Linux, so one answer covers all four crossings rather than four
        -- per-provider entries that could fall out of step.
        mapM_
            (\crossing -> frameOwnershipRow (CrossedInto crossing []) @?= PosixOwnershipRow)
            everyCrossing
    , testCase "a nested crossing is still a crossing" $
        frameOwnershipRow (CrossedInto (CrossIncusVM "vm") [CrossContainer "image"])
            @?= PosixOwnershipRow
    ]

everyCrossing :: [FrameCrossing]
everyCrossing =
    [ CrossIncusVM "vm"
    , CrossLimaVM "vm"
    , CrossWsl2VM "distro"
    , CrossContainer "image"
    ]

-- ---------------------------------------------------------------------------
-- The wire

authorityPathTests :: [TestTree]
authorityPathTests =
    [ testCase "absolute scalar authority paths keep their exact codec text" $
        sequence_
            [ case mkShippedAuthorityPath path of
                Left fault -> assertFailure (show fault)
                Right authority -> do
                    shippedAuthorityPath authority @?= path
                    let transaction = mkShippedOwnership authority specRecordKey (fixtureTarget "/owned") ShipObserveObject
                    decodeShippedOwnership (encodeShippedOwnership transaction) @?= Right transaction
            | path <- ["/var/tmp/authority", "C:\\hostbootstrap\\authority", "/var/tmp/\x03BB"]
            ]
    , testCase "empty, relative, NUL and surrogate authorities are refused" $
        sequence_
            [ expectMalformed "invalid authority producer input" (mkShippedAuthorityPath path)
            | path <- ["", "relative/authority", "C:relative", "/authority\0tail", "/tmp/\xDC80"]
            ]
    , testCase "unchecked authority wire fields are refused as malformed" $
        sequence_
            [ expectMalformed
                "invalid authority wire"
                (decodeShippedOwnership (rawTransaction 0 path "shipped.spec.object" "/owned"))
            | path <- ["", "relative/authority", "C:relative", "/authority\0tail"]
            ]
    , testCase "the receiving frame refuses the other path grammar before store open" $
        withFrame $ \frame -> do
            let authority = fixtureAuthority wrongFrameAuthority
                transaction = mkShippedOwnership authority specRecordKey (fixtureTarget (frameTarget frame)) ShipObserveObject
            present <- doesPathExist wrongFrameAuthority
            assertBool "the wrong-frame fixture starts absent" (not present)
            result <- runShippedOwnership ownershipRowForHost transaction
            case result of
                ShippedRefused (OwnershipMalformed _) -> pure ()
                other -> assertFailure ("expected a receiving-frame path refusal, got " <> show other)
            after <- doesPathExist wrongFrameAuthority
            assertBool "wrong-frame admission created no store" (not after)
    ]

wrongFrameAuthority :: FilePath
#ifdef mingw32_HOST_OS
wrongFrameAuthority = "/hostbootstrap-wrong-frame-authority"
#else
wrongFrameAuthority = "C:\\hostbootstrap-wrong-frame\\authority"
#endif

targetPathTests :: [TestTree]
targetPathTests =
    [ testCase "absolute scalar object targets keep their exact codec text" $
        sequence_
            [ case mkShippedTargetPath path of
                Left fault -> assertFailure (show fault)
                Right target -> do
                    shippedTargetPath target @?= path
                    let transaction = mkShippedOwnership (fixtureAuthority "/authority") specRecordKey target ShipObserveObject
                    decodeShippedOwnership (encodeShippedOwnership transaction) @?= Right transaction
            | path <- ["/var/tmp/owned", "C:\\hostbootstrap\\owned", "/var/tmp/\x03BB"]
            ]
    , testCase "empty, relative, NUL and surrogate object targets are refused" $
        sequence_
            [ expectMalformed "invalid target producer input" (mkShippedTargetPath path)
            | path <- ["", "relative/owned", "C:relative", "/owned\0tail", "/tmp/\xDC80"]
            ]
    , testCase "unchecked object target wire fields are refused as malformed" $
        sequence_
            [ expectMalformed
                "invalid target wire"
                (decodeShippedOwnership (rawTransaction 0 "/authority" "shipped.spec.object" path))
            | path <- ["", "relative/owned", "C:relative", "/owned\0tail"]
            ]
    , testCase "a wrong-frame object target refuses before creating the authority store" $
        withFrame $ \frame -> do
            let transaction =
                    mkShippedOwnership
                        (fixtureAuthority (frameAuthority frame))
                        specRecordKey
                        (fixtureTarget wrongFrameAuthority)
                        ShipObserveObject
            before <- doesPathExist (frameAuthority frame)
            assertBool "the authority store starts absent" (not before)
            result <- runShippedOwnership ownershipRowForHost transaction
            case result of
                ShippedRefused (OwnershipMalformed _) -> pure ()
                other -> assertFailure ("expected an object-target frame refusal, got " <> show other)
            after <- doesPathExist (frameAuthority frame)
            assertBool "wrong-frame object target created no authority store" (not after)
    ]

linkTargetPathTests :: [TestTree]
linkTargetPathTests =
    [ testCase "absolute scalar symbolic-link targets keep their exact codec text" $
        sequence_
            [ case mkShippedLinkTargetPath path of
                Left fault -> assertFailure (show fault)
                Right target -> do
                    shippedLinkTargetPath target @?= path
                    let transaction = sample (act target)
                        field = LazyByteString.toStrict (Builder.toLazyByteString (sizedField (TextEncoding.encodeUtf8 (Text.pack path))))
                        wire = rawTransaction tag "/var/tmp/authority" (asciiOf (recordKeyText specRecordKey)) "/var/tmp/owned" <> field
                    encodeShippedOwnership transaction @?= wire
                    decodeShippedOwnership wire @?= Right transaction
            | path <- ["/var/tmp/destination", "C:\\hostbootstrap\\destination", "/var/tmp/\x03BB"]
            , (tag, act) <- [(4, ShipTakeSymbolicLink), (5, ShipGiveBackSymbolicLink)]
            ]
    , testCase "empty, relative, NUL and surrogate symbolic-link targets are refused" $
        sequence_
            [ expectMalformed "invalid link-target producer input" (mkShippedLinkTargetPath path)
            | path <- ["", "relative/destination", "C:relative", "/destination\0tail", "/tmp/\xDC80"]
            ]
    , testCase "both symbolic-link acts refuse unchecked target wire fields" $
        sequence_
            [ let field = LazyByteString.toStrict (Builder.toLazyByteString (sizedField path))
               in expectMalformed
                    "invalid link-target wire"
                    (decodeShippedOwnership (rawTransaction tag "/authority" "shipped.spec.object" "/owned" <> field))
            | tag <- [4, 5]
            , path <- ["", "relative/destination", "C:relative", "/destination\0tail", "\255"]
            ]
    , testCase "both symbolic-link acts refuse a wrong-frame payload before store creation" $
        sequence_
            [ withFrame $ \frame -> do
                let transaction =
                        mkShippedOwnership
                            (fixtureAuthority (frameAuthority frame))
                            specRecordKey
                            (fixtureTarget (frameTarget frame))
                            (act (fixtureLinkTarget wrongFrameAuthority))
                before <- doesPathExist (frameAuthority frame)
                assertBool "the authority store starts absent" (not before)
                result <- runShippedOwnership ownershipRowForHost transaction
                case result of
                    ShippedRefused (OwnershipMalformed _) -> pure ()
                    other -> assertFailure ("expected a symbolic-link target frame refusal, got " <> show other)
                after <- doesPathExist (frameAuthority frame)
                assertBool "wrong-frame link target created no authority store" (not after)
            | act <- [ShipTakeSymbolicLink, ShipGiveBackSymbolicLink]
            ]
    ]

transactionCodecTests :: [TestTree]
transactionCodecTests =
    [ testCase "every act round-trips exactly" $
        mapM_
            (\act -> decodeShippedOwnership (encodeShippedOwnership (sample act)) @?= Right (sample act))
            [ ShipObserveObject
            , ShipTakeDirectory
            , ShipTakeFile (mkPayload "let cfg = 1 in cfg\n")
            , ShipTakeFile (mkPayload "")
            , ShipGiveBackObject
            , ShipTakeSymbolicLink (fixtureLinkTarget "/srv/project-data")
            , ShipGiveBackSymbolicLink (fixtureLinkTarget "/srv/project-data")
            ]
    , testCase "an unknown format is refused, never guessed" $
        expectMalformed "an unknown format" (decodeShippedOwnership "not a transaction at all")
    , testCase "a truncated transaction is refused" $
        expectMalformed
            "a truncated transaction"
            ( decodeShippedOwnership
                (ByteString.init (encodeShippedOwnership (sample ShipTakeDirectory)))
            )
    , testCase "a trailing byte is refused rather than ignored" $
        expectMalformed
            "a trailing byte"
            ( decodeShippedOwnership
                (encodeShippedOwnership (sample ShipTakeDirectory) <> "\0")
            )
    , testCase "an unknown act is refused" $
        expectMalformed
            "an unknown act"
            (decodeShippedOwnership (rawTransaction 9 "/authority" "shipped.spec.object" "/owned"))
    , testCase "a record key the store would not admit is refused here" $
        expectMalformed
            "an illegal record key"
            (decodeShippedOwnership (rawTransaction 1 "/authority" ".leading-dot" "/owned"))
    , testCase "every transaction field enforces the same 4 MiB ceiling" $
        sequence_
            [ expectMalformedReason
                ("ownership transaction: " <> subject <> " exceeds this wire's field ceiling")
                (decodeShippedOwnership (wireFields transactionPrefix tag (prior <> [Builder.word32LE 0x00400001])))
            | (tag, prior, subject) <-
                [ (1, [], "the ownership transaction's authority")
                , (1, take 1 baseTransactionFields, "the ownership transaction's record key")
                , (1, take 2 baseTransactionFields, "the ownership transaction's target")
                , (2, baseTransactionFields, "the ownership transaction's payload")
                , (4, baseTransactionFields, "the symbolic link's target")
                , (5, baseTransactionFields, "the symbolic link's target")
                ]
            ]
    , testCase "transaction text rejects invalid UTF-8 while file payloads remain bytes" $ do
        let invalid = ByteString.pack [0xff]
        sequence_
            [ expectMalformedReason
                ("ownership transaction: " <> subject <> " is not text")
                (decodeShippedOwnership (wireFields transactionPrefix tag (prior <> [sizedField invalid])))
            | (tag, prior, subject) <-
                [ (1, [], "the ownership transaction's authority")
                , (1, take 1 baseTransactionFields, "the ownership transaction's record key")
                , (1, take 2 baseTransactionFields, "the ownership transaction's target")
                , (4, baseTransactionFields, "the symbolic link's target")
                , (5, baseTransactionFields, "the symbolic link's target")
                ]
            ]
        let bytes = ByteString.pack [0, 0xff, 0xc0, 0x80]
        decodeShippedOwnership (wireFields transactionPrefix 2 (baseTransactionFields <> [sizedField bytes]))
            @?= Right (sample (ShipTakeFile (mkPayload bytes)))
    , testCase "the decoder admits 4 MiB payloads and the encoder preserves wider payloads" $ do
        let payload = ByteString.replicate (4 * 1024 * 1024) 0x61
            transaction = sample (ShipTakeFile (mkPayload payload))
        case decodeShippedOwnership (encodeShippedOwnership transaction) of
            Right decoded -> assertBool "the inclusive ceiling preserves the payload" (decoded == transaction)
            Left fault -> assertFailure ("the exact field ceiling was refused: " <> show fault)
        let wider = ByteString.snoc payload 0x62
            encoded = encodeShippedOwnership (sample (ShipTakeFile (mkPayload wider)))
        assertBool
            "the encoder writes the complete wider field"
            (encoded == wireFields transactionPrefix 2 (baseTransactionFields <> [sizedField wider]))
        expectMalformedReason
            "ownership transaction: the ownership transaction's payload exceeds this wire's field ceiling"
            (decodeShippedOwnership encoded)
    , testCase "a well-formed hand-built transaction is admitted, so the fixture is honest" $
        decodeShippedOwnership (rawTransaction 1 "/var/tmp/authority" (asciiOf (recordKeyText specRecordKey)) "/var/tmp/owned")
            @?= Right (sample ShipTakeDirectory)
    ]

outcomeCodecTests :: [TestTree]
outcomeCodecTests =
    [ testCase "every answer round-trips exactly" $ do
        identity <- someIdentity
        mapM_
            (\outcome -> decodeShippedOutcome (encodeShippedOutcome outcome) @?= Right outcome)
            [ ShippedObjectAbsent
            , ShippedObjectPresent identity
            , ShippedObjectTaken identity
            , ShippedObjectGivenBack
            , ShippedSymbolicLinkCreated identity
            , ShippedSymbolicLinkRetained identity
            ]
    , testCase "every refusal in the closed fault sum round-trips exactly" $ do
        identity <- someIdentity
        mapM_
            ( \fault ->
                decodeShippedOutcome (encodeShippedOutcome (ShippedRefused fault))
                    @?= Right (ShippedRefused fault)
            )
            [ OwnershipUnsupported "this host holds no clause"
            , OwnershipProbeFailed "observe" "the probe could not answer"
            , OwnershipMalformed "the record is not a record"
            , OwnershipOccupied "something is already there"
            , OwnershipConflict
                ConflictReport
                    { conflictSubject = "/owned/target"
                    , conflictExpected = OriginPresent identity
                    , conflictObserved = OriginAbsent
                    }
            , OwnershipConflict
                ConflictReport
                    { conflictSubject = "/owned/target"
                    , conflictExpected = OriginAbsent
                    , conflictObserved = OriginPresent identity
                    }
            ]
    , testCase "every outcome field enforces the same 4 MiB ceiling" $
        sequence_
            [ expectMalformedReason
                ("ownership outcome: " <> subject <> " exceeds this wire's field ceiling")
                (decodeShippedOutcome (wireFields outcomePrefix tag (prior <> [Builder.word32LE 0x00400001])))
            | (tag, prior, subject) <-
                [(tag, [], "an object identity") | tag <- [1, 2, 5, 6]]
                    <> [(4, prior, subject) | (prior, subject) <- faultTextFields]
                    <> [ (4, [Builder.word8 4, sizedField "/owned", Builder.word8 1], "an object identity")
                       , (4, [Builder.word8 4, sizedField "/owned", Builder.word8 0, Builder.word8 1], "an object identity")
                       ]
            ]
    , testCase "every refusal text field rejects invalid UTF-8" $
        sequence_
            [ expectMalformedReason
                ("ownership outcome: " <> subject <> " is not text")
                (decodeShippedOutcome (wireFields outcomePrefix 4 (prior <> [sizedField (ByteString.pack [0xff])])))
            | (prior, subject) <- faultTextFields
            ]
    , testCase "both conflict origins reject an unknown origin tag" $
        sequence_
            [ expectMalformedReason
                "ownership outcome: the ownership outcome names an unknown prior state"
                (decodeShippedOutcome (wireFields outcomePrefix 4 body))
            | body <-
                [ [Builder.word8 4, sizedField "/owned", Builder.word8 2, Builder.word8 0]
                , [Builder.word8 4, sizedField "/owned", Builder.word8 0, Builder.word8 2]
                ]
            ]
    , testCase "every identity position refuses zero and 65 bytes" $
        sequence_
            [ expectMalformedReason
                "ownership outcome: the ownership outcome carries no usable identity"
                (decodeShippedOutcome raw)
            | width <- [0, 65]
            , let identity = sizedField (ByteString.replicate width 0x41)
            , raw <-
                [wireFields outcomePrefix tag [identity] | tag <- [1, 2, 5, 6]]
                    <> [ wireFields outcomePrefix 4 [Builder.word8 4, sizedField "/owned", Builder.word8 1, identity, Builder.word8 0]
                       , wireFields outcomePrefix 4 [Builder.word8 4, sizedField "/owned", Builder.word8 0, Builder.word8 1, identity]
                       ]
            ]
    , testCase "an unknown answer is refused, never guessed" $
        expectMalformed
            "an unknown answer"
            (decodeShippedOutcome (withOutcomeTag 9 ShippedObjectGivenBack))
    , testCase "an unknown refusal is refused" $ do
        let refused = encodeShippedOutcome (ShippedRefused (OwnershipMalformed "x"))
        expectMalformed
            "an unknown refusal"
            (decodeShippedOutcome (replaceByteAt (ByteString.length outcomePrefix + 1) 9 refused))
    ]

-- ---------------------------------------------------------------------------
-- The transaction, run where the object is

directoryLeaseTests :: [TestTree]
directoryLeaseTests =
    [ leaseCase "fresh acquisition binds the real directory and admits nested use" $ \frame -> do
        outcome <- withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory) $ \lease -> do
            doesDirectoryExist (frameTarget frame) >>= (@?= True)
            nested <- useShippedDirectoryLease lease (pure (41 :: Int))
            nested @?= Right 41
            observeIdentity (frameTarget frame)
        identity <- expectRight outcome
        stored <- maybe (assertFailure "the directory record is absent") pure =<< recordForFrame frame
        record <- expectRight (parseOriginRecord (protectedRecordBytes stored))
        originRecordKind record @?= OwnedDirectory
        originRecordOrigin record @?= OriginAbsent
        originRecordBinding record @?= Just identity
    , leaseCase "retained acquisition preserves identity and the complete record" $ \frame -> do
        first <- expectTaken =<< runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        before <- recordForFrame frame
        outcome <- withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory) $ \_ ->
            observeIdentity (frameTarget frame)
        outcome @?= Right first
        recordForFrame frame >>= (@?= before)
    , leaseCase "an unrecorded occupied directory receives no callback" $ \frame -> do
        createDirectory (frameTarget frame)
        identity <- observeIdentity (frameTarget frame)
        calls <- newIORef (0 :: Int)
        outcome <- withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory) $ \_ ->
            modifyIORef' calls (+ 1)
        outcome @?= Left (OwnershipOccupied (Text.pack (frameTarget frame) <> " is already there, and this transaction adopts nothing it finds"))
        readIORef calls >>= (@?= 0)
        observeIdentity (frameTarget frame) >>= (@?= identity)
        recordForFrame frame >>= (@?= Nothing)
    , leaseCase "an absent unbound directory resumes through shared acquisition" $ \frame -> do
        publishUnboundDirectoryForFrame frame
        outcome <- withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory) $ \_ ->
            observeIdentity (frameTarget frame)
        identity <- expectRight outcome
        stored <- maybe (assertFailure "the resumed directory record is absent") pure =<< recordForFrame frame
        record <- expectRight (parseOriginRecord (protectedRecordBytes stored))
        originRecordBinding record @?= Just identity
        originRecordOrigin record @?= OriginAbsent
    , leaseCase "an occupied unbound directory preserves the record and refuses" $ \frame -> do
        publishUnboundDirectoryForFrame frame
        createDirectory (frameTarget frame)
        identity <- observeIdentity (frameTarget frame)
        before <- recordForFrame frame
        calls <- newIORef (0 :: Int)
        outcome <- withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory) $ \_ ->
            modifyIORef' calls (+ 1)
        case outcome of
            Left (OwnershipConflict report) -> do
                conflictExpected report @?= OriginAbsent
                conflictObserved report @?= OriginPresent identity
            other -> assertFailure ("expected the unbound directory conflict, got " <> show other)
        readIORef calls >>= (@?= 0)
        recordForFrame frame >>= (@?= before)
        observeIdentity (frameTarget frame) >>= (@?= identity)
    , leaseCase "a same-path replacement refuses before entering the callback" $ \frame -> do
        original <- expectTaken =<< runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        before <- recordForFrame frame
        replacement <- replaceLeaseDirectory frame
        calls <- newIORef (0 :: Int)
        outcome <- withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory) $ \_ ->
            modifyIORef' calls (+ 1)
        assertLeaseIdentityConflict frame original replacement outcome
        readIORef calls >>= (@?= 0)
        recordForFrame frame >>= (@?= before)
        observeIdentity (frameTarget frame) >>= (@?= replacement)
    , leaseCase "replacement before use refuses before the action" $ \frame -> do
        calls <- newIORef (0 :: Int)
        identities <- newIORef Nothing
        outcome <- withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory) $ \lease -> do
            original <- observeIdentity (frameTarget frame)
            replacement <- replaceLeaseDirectory frame
            modifyIORef' identities (const (Just (original, replacement)))
            refused <- useShippedDirectoryLease lease (modifyIORef' calls (+ 1))
            assertLeaseIdentityConflict frame original replacement refused
        pair <- maybe (assertFailure "callback did not run") pure =<< readIORef identities
        uncurry (\original replacement -> assertLeaseIdentityConflict frame original replacement outcome) pair
        readIORef calls >>= (@?= 0)
    , leaseCase "replacement during the action is refused by the final observation" $ \frame -> do
        identities <- newIORef Nothing
        calls <- newIORef (0 :: Int)
        outcome <- withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory) $ \lease -> do
            original <- observeIdentity (frameTarget frame)
            refused <- useShippedDirectoryLease lease $ do
                modifyIORef' calls (+ 1)
                replacement <- replaceLeaseDirectory frame
                modifyIORef' identities (const (Just (original, replacement)))
                pure replacement
            pair <- maybe (assertFailure "the action did not run") pure =<< readIORef identities
            uncurry (\expected observed -> assertLeaseIdentityConflict frame expected observed refused) pair
        pair <- maybe (assertFailure "callback did not run") pure =<< readIORef identities
        uncurry (\expected observed -> assertLeaseIdentityConflict frame expected observed outcome) pair
        readIORef calls >>= (@?= 1)
    , leaseCase "an escaped effect refuses after its entry closes" $ \frame -> do
        calls <- newIORef (0 :: Int)
        escaped <- expectRight =<<
            withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory)
                (\lease -> pure (useShippedDirectoryLease lease (modifyIORef' calls (+ 1))))
        escaped >>= (@?= Left (OwnershipProbeFailed "use the ownership entry" "the protected session is no longer live"))
        readIORef calls >>= (@?= 0)
    , leaseCase "a different thread refuses before its effect" $ \frame -> do
        calls <- newIORef (0 :: Int)
        outcome <- withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory) $ \lease -> do
            answer <- newEmptyMVar
            _ <- forkIO (useShippedDirectoryLease lease (modifyIORef' calls (+ 1)) >>= putMVar answer)
            takeMVar answer >>= (@?= Left (OwnershipProbeFailed "use the ownership entry" "the protected session belongs to another thread"))
        outcome @?= Right ()
        readIORef calls >>= (@?= 0)
    , leaseCase "another process is excluded for the entire callback" $ \frame -> do
        outcome <- withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory) $ \lease -> do
            probeDirectoryEntry frame >>= (@?= (ExitFailure 3, "", ""))
            used <- useShippedDirectoryLease lease (probeDirectoryEntry frame)
            used @?= Right (ExitFailure 3, "", "")
            probeDirectoryEntry frame >>= (@?= (ExitFailure 3, "", ""))
        outcome @?= Right ()
        probeDirectoryEntry frame >>= (@?= (ExitSuccess, "", ""))
    , leaseCase "a callback exception releases the entry and preserves ownership" $ \frame -> do
        outcome <- try (withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory)
            (\_ -> throwIO DivideByZero)) :: IO (Either ArithException (Either OwnershipFault ()))
        outcome @?= Left DivideByZero
        probeDirectoryEntry frame >>= (@?= (ExitSuccess, "", ""))
        taken <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        _ <- expectTaken taken
        pure ()
    , testCase "a non-directory transaction refuses before opening an authority" $
        withFrame $ \frame -> do
            outcome <- withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipObserveObject) (\_ -> pure ())
            outcome @?= Left (OwnershipMalformed "a directory lease requires a directory-take transaction")
            doesPathExist (frameAuthority frame) >>= (@?= False)
            doesPathExist (frameTarget frame) >>= (@?= False)
    ]

leaseCase :: TestName -> (Frame -> IO ()) -> TestTree
leaseCase name body = testCase name $
    withFrame $ \frame ->
        if hostOwnershipSupported then body frame else do
            calls <- newIORef (0 :: Int)
            outcome <- withShippedDirectoryLease ownershipRowForHost (transactionFor frame ShipTakeDirectory) $ \_ ->
                modifyIORef' calls (+ 1)
            case outcome of
                Left (OwnershipUnsupported _) -> pure ()
                other -> assertFailure ("expected the directory lease's platform refusal, got " <> show other)
            readIORef calls >>= (@?= 0)
            doesPathExist (frameTarget frame) >>= (@?= False)

replaceLeaseDirectory :: Frame -> IO ObjectIdentity
replaceLeaseDirectory frame = do
    renameDirectory (frameTarget frame) (frameTarget frame <> "-original")
    createDirectory (frameTarget frame)
    observeIdentity (frameTarget frame)

assertLeaseIdentityConflict :: Frame -> ObjectIdentity -> ObjectIdentity -> Either OwnershipFault result -> IO ()
assertLeaseIdentityConflict frame expected observed outcome = case outcome of
    Left (OwnershipConflict report) ->
        report @?= ConflictReport (Text.pack (frameTarget frame)) (OriginPresent expected) (OriginPresent observed)
    _ -> assertFailure "expected the exact directory identity conflict"

probeDirectoryEntry :: Frame -> IO (ExitCode, String, String)
probeDirectoryEntry frame = do
    self <- getExecutablePath
    readProcessWithExitCode self ["--hostbootstrap-protected-entry-probe", frameAuthority frame] ""

interpreterTests :: [TestTree]
interpreterTests =
    [ testCase "an authority beneath a regular file refuses at store open" $
        withFrame $ \frame -> do
            ByteString.writeFile (frameAuthority frame) "authority obstruction\n"
            let authority = frameAuthority frame </> "blocked"
                transaction =
                    mkShippedOwnership (fixtureAuthority authority) specRecordKey
                        (fixtureTarget (frameTarget frame)) ShipTakeDirectory
            refused <- runShippedOwnership ownershipRowForHost transaction
            case refused of
                ShippedRefused (OwnershipProbeFailed operation reason) -> do
                    operation @?= "open this frame's ownership authority"
                    assertBool "the store diagnostic is retained" (not (Text.null reason))
                other -> assertFailure ("expected a store-open probe refusal, got " <> show other)
            ByteString.readFile (frameAuthority frame) >>= (@?= "authority obstruction\n")
            doesPathExist authority >>= (@?= False)
            doesPathExist (frameTarget frame) >>= (@?= False)
            doesPathExist (stagingForFrame frame) >>= (@?= False)
    , rowCase "an absent object is reported absent, and nothing is created" $ \frame -> do
        outcome <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipObserveObject)
        outcome @?= ShippedObjectAbsent
        doesPathExist (frameTarget frame) >>= (@?= False)
        doesPathExist (stagingForFrame frame) >>= (@?= False)
        recordForFrame frame >>= (@?= Nothing)
    , rowCase "a directory is taken, bound to its identity, and given back" $ \frame -> do
        taken <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        identity <- expectTaken taken
        present <- doesDirectoryExist (frameTarget frame)
        assertBool "the directory exists after the transaction" present
        observed <- observeIdentity (frameTarget frame)
        observed @?= identity
        stored <- maybe (assertFailure "expected the bound directory record") pure =<< recordForFrame frame
        record <- either (assertFailure . show) pure (parseOriginRecord (protectedRecordBytes stored))
        originRecordKind record @?= OwnedDirectory
        originRecordOrigin record @?= OriginAbsent
        originRecordBinding record @?= Just identity

        reported <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipObserveObject)
        reported @?= ShippedObjectPresent identity

        given <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipGiveBackObject)
        given @?= ShippedObjectGivenBack
        gone <- doesDirectoryExist (frameTarget frame)
        assertBool "the directory is gone" (not gone)
        recordForFrame frame >>= (@?= Nothing)
    , rowCase "a file is published with its payload, and given back" $ \frame -> do
        let payload = "let cfg = { project = \"demo\" } in cfg\n"
        taken <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeFile (mkPayload payload)))
        _ <- expectTaken taken
        installed <- ByteString.readFile (frameTarget frame)
        installed @?= payload
        doesPathExist (stagingForFrame frame) >>= (@?= False)

        given <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipGiveBackObject)
        given @?= ShippedObjectGivenBack
        gone <- doesFileExist (frameTarget frame)
        assertBool "the file is gone" (not gone)
        doesPathExist (stagingForFrame frame) >>= (@?= False)
        recordForFrame frame >>= (@?= Nothing)
    , rowCase "an exact retry converges on the record this frame already holds" $ \frame -> do
        first <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        identity <- expectTaken first
        again <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        again @?= ShippedObjectTaken identity
    , rowCase "an exact file retry preserves its payload, identity and record" $ \frame -> do
        let payload = "owned file A\n"
            transaction = transactionFor frame (ShipTakeFile (mkPayload payload))
        owned <- expectTaken =<< runShippedOwnership ownershipRowForHost transaction
        before <- recordForFrame frame
        retried <- runShippedOwnership ownershipRowForHost transaction
        retried @?= ShippedObjectTaken owned
        ByteString.readFile (frameTarget frame) >>= (@?= payload)
        observeIdentity (frameTarget frame) >>= (@?= owned)
        recordForFrame frame >>= (@?= before)
    , rowCase "a changed file payload refuses without changing the owned file or record" $ \frame -> do
        owned <-
            expectTaken
                =<< runShippedOwnership ownershipRowForHost
                    (transactionFor frame (ShipTakeFile (mkPayload "owned file A\n")))
        before <- recordForFrame frame
        retried <-
            runShippedOwnership ownershipRowForHost
                (transactionFor frame (ShipTakeFile (mkPayload "different file B\n")))
        expectMalformedOutcome retried
        ByteString.readFile (frameTarget frame) >>= (@?= "owned file A\n")
        observeIdentity (frameTarget frame) >>= (@?= owned)
        recordForFrame frame >>= (@?= before)
    , rowCase "a directory take refuses a file record without changing the file" $ \frame -> do
        owned <-
            expectTaken
                =<< runShippedOwnership ownershipRowForHost
                    (transactionFor frame (ShipTakeFile (mkPayload "owned file A\n")))
        before <- recordForFrame frame
        retried <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        expectMalformedOutcome retried
        ByteString.readFile (frameTarget frame) >>= (@?= "owned file A\n")
        observeIdentity (frameTarget frame) >>= (@?= owned)
        recordForFrame frame >>= (@?= before)
    , rowCase "a vanished bound directory refuses retry and preserves its record" $ \frame -> do
        owned <- expectTaken =<< runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        before <- recordForFrame frame
        removeDirectory (frameTarget frame)
        retried <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        case retried of
            ShippedRefused (OwnershipConflict report) -> do
                conflictSubject report @?= Text.pack (frameTarget frame)
                conflictExpected report @?= OriginPresent owned
                conflictObserved report @?= OriginAbsent
            other -> assertFailure ("expected the missing bound object's conflict, got " <> show other)
        doesPathExist (frameTarget frame) >>= (@?= False)
        recordForFrame frame >>= (@?= before)
    , rowCase "a replaced bound directory refuses retry and leaves the replacement intact" $ \frame -> do
        owned <- expectTaken =<< runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        before <- recordForFrame frame
        removeAndReplace (frameTarget frame)
        replacement <- observeIdentity (frameTarget frame)
        ByteString.writeFile (frameTarget frame </> "operator") "keep this replacement\n"
        retried <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        case retried of
            ShippedRefused (OwnershipConflict report) -> do
                conflictSubject report @?= Text.pack (frameTarget frame)
                conflictExpected report @?= OriginPresent owned
                conflictObserved report @?= OriginPresent replacement
            other -> assertFailure ("expected the replacement's identity conflict, got " <> show other)
        observeIdentity (frameTarget frame) >>= (@?= replacement)
        ByteString.readFile (frameTarget frame </> "operator") >>= (@?= "keep this replacement\n")
        recordForFrame frame >>= (@?= before)
    , rowCase "a bound record with a present origin cannot adopt the existing directory" $ \frame -> do
        createDirectory (frameTarget frame)
        ByteString.writeFile (frameTarget frame </> "operator") "already here\n"
        identity <- observeIdentity (frameTarget frame)
        record <-
            either (assertFailure . show) pure
                (bindOriginRecord identity (originRecord OwnedDirectory (OriginPresent identity)))
        publishRecordForFrame frame (renderOriginRecord record)
        before <- recordForFrame frame
        result <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        expectMalformedOutcome result
        observeIdentity (frameTarget frame) >>= (@?= identity)
        ByteString.readFile (frameTarget frame </> "operator") >>= (@?= "already here\n")
        recordForFrame frame >>= (@?= before)
    , rowCase "an unbound absent directory record resumes the take" $ \frame -> do
        publishUnboundDirectoryForFrame frame
        before <- recordForFrame frame
        owned <- expectTaken =<< runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        doesDirectoryExist (frameTarget frame) >>= (@?= True)
        after <- recordForFrame frame
        assertBool "the interrupted record gains its identity binding" (after /= Nothing && after /= before)
        retried <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        retried @?= ShippedObjectTaken owned
        recordForFrame frame >>= (@?= after)
        given <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipGiveBackObject)
        given @?= ShippedObjectGivenBack
        doesPathExist (frameTarget frame) >>= (@?= False)
        recordForFrame frame >>= (@?= Nothing)
    , rowCase "an unbound present directory record refuses the take" $ \frame ->
        assertUnboundDirectoryConflict frame ShipTakeDirectory
    , rowCase "an unbound absent directory record settles give-back" $ \frame -> do
        publishUnboundDirectoryForFrame frame
        given <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipGiveBackObject)
        given @?= ShippedObjectGivenBack
        doesPathExist (frameTarget frame) >>= (@?= False)
        recordForFrame frame >>= (@?= Nothing)
        again <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipGiveBackObject)
        again @?= ShippedObjectGivenBack
        _ <- expectTaken =<< runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        doesDirectoryExist (frameTarget frame) >>= (@?= True)
    , rowCase "an unbound present directory record refuses give-back" $ \frame ->
        assertUnboundDirectoryConflict frame ShipGiveBackObject
    , symbolicLinkCase "a symbolic link is published, retained on retry, and conditionally given back" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        created <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeSymbolicLink (fixtureLinkTarget (frameLinkTarget frame))))
        identity <- case created of
            ShippedSymbolicLinkCreated value -> pure value
            other -> assertFailure ("expected a created symbolic link, got " <> show other)
        linked <- pathIsSymbolicLink (frameTarget frame)
        assertBool "the published object is a symbolic link" linked
        getSymbolicLinkTarget (frameTarget frame) >>= (@?= frameLinkTarget frame)

        retried <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeSymbolicLink (fixtureLinkTarget (frameLinkTarget frame))))
        retried @?= ShippedSymbolicLinkRetained identity

        released <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipGiveBackSymbolicLink (fixtureLinkTarget (frameLinkTarget frame))))
        released @?= ShippedObjectGivenBack
        remaining <- doesPathExist (frameTarget frame)
        assertBool "the managed symbolic link was removed" (not remaining)
        targetRemaining <- doesDirectoryExist (frameLinkTarget frame)
        assertBool "the symbolic link target was not removed" targetRemaining
    , symbolicLinkCase "kernel give-back refuses a reported symbolic link" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        created <- runShippedOwnership ownershipRowForHost
            (transactionFor frame (ShipTakeSymbolicLink (fixtureLinkTarget (frameLinkTarget frame))))
        case created of
            ShippedSymbolicLinkCreated _ -> pure ()
            other -> assertFailure ("expected a created symbolic link, got " <> show other)
        refused <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipGiveBackObject)
        case refused of
            ShippedRefused (OwnershipMalformed _) -> pure ()
            other -> assertFailure ("expected reported-object refusal, got " <> show other)
        pathIsSymbolicLink (frameTarget frame) >>= (@?= True)
        released <- runShippedOwnership ownershipRowForHost
            (transactionFor frame (ShipGiveBackSymbolicLink (fixtureLinkTarget (frameLinkTarget frame))))
        released @?= ShippedObjectGivenBack
    , symbolicLinkCase "an exact-looking symbolic link without this transaction's record remains foreign" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        createFileLink (frameLinkTarget frame) (frameTarget frame)
        refused <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeSymbolicLink (fixtureLinkTarget (frameLinkTarget frame))))
        case refused of
            ShippedRefused (OwnershipOccupied _) -> pure ()
            other -> assertFailure ("expected an occupied refusal, got " <> show other)
        linked <- pathIsSymbolicLink (frameTarget frame)
        assertBool "the foreign exact-looking link survived" linked
    , symbolicLinkCase "symbolic-link give-back preserves an unrecorded exact-looking link" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        createFileLink (frameLinkTarget frame) (frameTarget frame)
        before <- observeIdentity (frameTarget frame)
        refused <-
            runShippedOwnership ownershipRowForHost
                (transactionFor frame (ShipGiveBackSymbolicLink (fixtureLinkTarget (frameLinkTarget frame))))
        case refused of
            ShippedRefused (OwnershipOccupied _) -> pure ()
            other -> assertFailure ("expected an occupied give-back refusal, got " <> show other)
        pathIsSymbolicLink (frameTarget frame) >>= (@?= True)
        getSymbolicLinkTarget (frameTarget frame) >>= (@?= frameLinkTarget frame)
        observeIdentity (frameTarget frame) >>= (@?= before)
        recordForFrame frame >>= (@?= Nothing)
    , symbolicLinkCase "symbolic-link give-back preserves an unrecorded regular file" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        ByteString.writeFile (frameTarget frame) "an operator's file"
        before <- observeIdentity (frameTarget frame)
        refused <-
            runShippedOwnership ownershipRowForHost
                (transactionFor frame (ShipGiveBackSymbolicLink (fixtureLinkTarget (frameLinkTarget frame))))
        case refused of
            ShippedRefused (OwnershipOccupied _) -> pure ()
            other -> assertFailure ("expected an occupied give-back refusal, got " <> show other)
        ByteString.readFile (frameTarget frame) >>= (@?= "an operator's file")
        observeIdentity (frameTarget frame) >>= (@?= before)
        recordForFrame frame >>= (@?= Nothing)
    , symbolicLinkCase "a replacement symbolic link is refused on release and left intact" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        created <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeSymbolicLink (fixtureLinkTarget (frameLinkTarget frame))))
        owned <- case created of
            ShippedSymbolicLinkCreated identity -> pure identity
            other -> assertFailure ("expected the created symbolic link, got " <> show other)
        before <- recordForFrame frame
        renameFile (frameTarget frame) (frameTarget frame <> "-original")
        createFileLink "/operator/replacement" (frameTarget frame)
        replacement <- observeIdentity (frameTarget frame)
        assertBool "the original inode remains distinct" (replacement /= owned)
        refused <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipGiveBackSymbolicLink (fixtureLinkTarget (frameLinkTarget frame))))
        case refused of
            ShippedRefused (OwnershipConflict report) -> do
                conflictSubject report @?= Text.pack (frameTarget frame)
                conflictExpected report @?= OriginPresent owned
                conflictObserved report @?= OriginPresent replacement
            other -> assertFailure ("expected the replacement symbolic link's conflict, got " <> show other)
        getSymbolicLinkTarget (frameTarget frame) >>= (@?= "/operator/replacement")
        observeIdentity (frameTarget frame) >>= (@?= replacement)
        recordForFrame frame >>= (@?= before)
    , rowCase "an object already there is refused, and nothing is recorded" $ \frame -> do
        ByteString.writeFile (frameTarget frame) "an operator's file\n"
        refused <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeFile (mkPayload "ours\n")))
        case refused of
            ShippedRefused (OwnershipOccupied reason) ->
                reason @?= Text.pack (frameTarget frame) <> " is already there, and this transaction adopts nothing it finds"
            other -> assertFailure ("expected the occupied target's refusal, got " <> show other)
        kept <- ByteString.readFile (frameTarget frame)
        kept @?= "an operator's file\n"
        recordForFrame frame >>= (@?= Nothing)
        removeFile (frameTarget frame)
        _ <-
            expectTaken
                =<< runShippedOwnership ownershipRowForHost
                    (transactionFor frame (ShipTakeFile (mkPayload "ours\n")))
        ByteString.readFile (frameTarget frame) >>= (@?= "ours\n")
        doesPathExist (stagingForFrame frame) >>= (@?= False)
    , rowCase "giving back what was never taken is a settled answer, not a refusal" $ \frame -> do
        given <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipGiveBackObject)
        given @?= ShippedObjectGivenBack
    , rowCase "a replaced object is refused, and left intact" $ \frame -> do
        owned <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory) >>= expectTaken
        removeAndReplace (frameTarget frame)
        replacement <- observeIdentity (frameTarget frame)
        assertBool "the fixture replaced the owned identity" (replacement /= owned)
        ByteString.writeFile (frameTarget frame </> "operator") "preserve the replacement\n"
        before <- recordForFrame frame
        refused <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipGiveBackObject)
        case refused of
            ShippedRefused (OwnershipConflict report) -> do
                conflictSubject report @?= Text.pack (frameTarget frame)
                conflictExpected report @?= OriginPresent owned
                conflictObserved report @?= OriginPresent replacement
            other -> assertFailure ("expected the replacement directory's conflict, got " <> show other)
        observeIdentity (frameTarget frame) >>= (@?= replacement)
        ByteString.readFile (frameTarget frame </> "operator") >>= (@?= "preserve the replacement\n")
        recordForFrame frame >>= (@?= before)
    ]

-- ---------------------------------------------------------------------------
-- The crossing

crossingFailureTests :: [TestTree]
crossingFailureTests =
    [ testCase "a transport diagnostic retains its crossing stage" $
        classifyShippedOutcome (Left "the configured frame is unavailable")
            @?= Left (ShippedCrossingFailed "the configured frame is unavailable")
    , testCase "an unreadable outcome stays distinct from a decoded malformed-input refusal" $ do
        case classifyShippedOutcome (Right "not an ownership outcome") of
            Left (ShippedOutcomeUndecodable reason) ->
                assertBool "the decoding diagnostic is retained" (not (Text.null reason))
            other -> assertFailure ("expected an undecodable outcome, got " <> show other)
        let fault = OwnershipMalformed "the frame rejected its input"
        classifyShippedOutcome (Right (encodeShippedOutcome (ShippedRefused fault)))
            @?= Left (ShippedFrameRefused fault)
    , testCase "every decoded successful outcome retains its exact value" $ do
        identity <- someIdentity
        sequence_
            [ classifyShippedOutcome (Right (encodeShippedOutcome outcome)) @?= Right outcome
            | outcome <-
                [ ShippedObjectAbsent
                , ShippedObjectPresent identity
                , ShippedObjectTaken identity
                , ShippedObjectGivenBack
                , ShippedSymbolicLinkCreated identity
                , ShippedSymbolicLinkRetained identity
                ]
            ]
    , testCase "every frame refusal retains its exact ownership fault" $ do
        identity <- someIdentity
        let report = ConflictReport "/owned" OriginAbsent (OriginPresent identity)
        sequence_
            [ classifyShippedOutcome (Right (encodeShippedOutcome (ShippedRefused fault)))
                @?= Left (ShippedFrameRefused fault)
            | fault <-
                [ OwnershipOccupied "an operator's object"
                , OwnershipProbeFailed "observe" "unavailable"
                , OwnershipUnsupported "the row cannot perform this act"
                , OwnershipMalformed "the request is malformed"
                , OwnershipConflict report
                ]
            ]
    ]

crossingTests :: [TestTree]
crossingTests =
    [ testCase "the crossing child uses the production frame transaction dispatcher" $
        -- DEVELOPMENT_PLAN/rationale.md: Frame transactions share their production dispatcher.
        SourceGuard.withPackageSourceIn ["test"] $ \_ testRoot -> do
            source <- readFile (testRoot </> "Spec.hs")
            mapM_ (\name -> SourceGuard.countHaskellIdentifier name source @?= 0)
                ["interpretShippedOwnership", "interpretShippedClusterExposure"]
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "import HostBootstrap.CLI (interpretFrameTransaction)")
                source @?= 1
            SourceGuard.countHaskellIdentifier "interpretFrameTransaction" source @?= 2
    , testCase "a frame with no configured host tool returns a crossing failure" $ do
        executable <- getExecutablePath
        let self = mkSelfRef (LocalSelfPath executable) (InVMSelfPath "/usr/local/bin/hostbootstrap-core-test")
            context = vmContext (inVM IncusVM{vmName = "hostbootstrap-test-no-configured-incus", vmImage = "unused"} emptyVMStack)
        result <- shipOwnedTransaction unresolvedHostConfig self context (sample ShipTakeDirectory)
        result @?= Left (ShippedCrossingFailed "frame child: the crossing's host tool resolves to no absolute path")
    , testCase "an empty context runs the transaction in a real child process" $
        withFrame $ \frame -> do
            executable <- getExecutablePath
            let self = mkSelfRef (LocalSelfPath executable) (InVMSelfPath executable)
            taken <-
                shipOwnedTransaction
                    unresolvedHostConfig
                    self
                    localContext
                    (transactionFor frame ShipTakeDirectory)
            case taken of
                Right (ShippedObjectTaken _) -> pure ()
                other -> assertFailure ("expected an owned directory, got " <> show other)
            -- The object is on this filesystem, so the child really did the
            -- transaction: nothing in this process touched the path.
            present <- doesDirectoryExist (frameTarget frame)
            assertBool "the child created the directory" present

            given <-
                shipOwnedTransaction
                    unresolvedHostConfig
                    self
                    localContext
                    (transactionFor frame ShipGiveBackObject)
            given @?= Right ShippedObjectGivenBack
            gone <- doesDirectoryExist (frameTarget frame)
            assertBool "the child removed the directory" (not gone)
    , testCase "a frame's refusal crosses back as a refusal, not as a broken exchange" $
        withFrame $ \frame -> do
            executable <- getExecutablePath
            let self = mkSelfRef (LocalSelfPath executable) (InVMSelfPath executable)
            ByteString.writeFile (frameTarget frame) "an operator's file\n"
            refused <-
                shipOwnedTransaction
                    unresolvedHostConfig
                    self
                    localContext
                    (transactionFor frame (ShipTakeFile (mkPayload "ours\n")))
            case refused of
                Left (ShippedFrameRefused (OwnershipOccupied _)) -> pure ()
                other -> assertFailure ("expected an occupied refusal, got " <> show other)
    ]

-- ---------------------------------------------------------------------------
-- Harness

-- | Where one case's frame keeps its object and its ownership authority.
data Frame = Frame
    { frameTarget :: FilePath
    , frameAuthority :: FilePath
    , frameLinkTarget :: FilePath
    }

withFrame :: (Frame -> IO ()) -> IO ()
withFrame use =
    withSystemTempDirectory "hb-shipped-ownership" $ \root ->
        use
            Frame
                { frameTarget = root </> "owned"
                , frameAuthority = root </> "authority"
                , frameLinkTarget = root </> "durable-target"
                }

{- | One case that drives the production row against the kernel.

On a gate host that cannot hold the row's clauses the case still runs and what
it asserts is the refusal the row declares, so the family is the same size
everywhere.
-}
rowCase :: TestName -> (Frame -> IO ()) -> TestTree
rowCase name body =
    testCase name $
        withFrame $ \frame ->
            if hostOwnershipSupported
                then body frame
                else do
                    refused <-
                        runShippedOwnership
                            ownershipRowForHost
                            (transactionFor frame ShipTakeDirectory)
                    case refused of
                        ShippedRefused (OwnershipUnsupported _) -> pure ()
                        other ->
                            assertFailure
                                ("expected this host's row to refuse, got " <> show other)

symbolicLinkCase :: TestName -> (Frame -> IO ()) -> TestTree
symbolicLinkCase name body =
    testCase name $
        withFrame $ \frame ->
            if symbolicLinkSupported then body frame else assertSymbolicLinkRefusal frame
  where
    assertSymbolicLinkRefusal frame = do
        refused <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeSymbolicLink (fixtureLinkTarget (frameLinkTarget frame))))
        case refused of
            ShippedRefused (OwnershipUnsupported _) -> pure ()
            other -> assertFailure ("expected symbolic-link refusal, got " <> show other)

symbolicLinkSupported :: Bool
#ifdef mingw32_HOST_OS
symbolicLinkSupported = False
#else
symbolicLinkSupported = hostOwnershipSupported
#endif

stagingForFrame :: Frame -> FilePath
stagingForFrame frame =
    frameTarget frame <> ".hostbootstrap-shipped-" <> Text.unpack (recordKeyText specRecordKey)

recordForFrame :: Frame -> IO (Maybe ProtectedRecord)
recordForFrame frame = do
    store <- either (assertFailure . show) pure =<< openProtectedStore (frameAuthority frame)
    either (assertFailure . show) pure
        =<< withProtectedEntry store (\session -> readProtectedRecord session specRecordKey)

publishRecordForFrame :: Frame -> ByteString.ByteString -> IO ()
publishRecordForFrame frame bytes = do
    store <- either (assertFailure . show) pure =<< openProtectedStore (frameAuthority frame)
    _ <-
        either (assertFailure . show) pure
            =<< withProtectedEntry store
                (\session -> compareAndSwapProtectedRecord session specRecordKey ExpectAbsent bytes)
    pure ()

publishUnboundDirectoryForFrame :: Frame -> IO ()
publishUnboundDirectoryForFrame frame =
    publishRecordForFrame frame (renderOriginRecord (originRecord OwnedDirectory OriginAbsent))

assertUnboundDirectoryConflict :: Frame -> ShippedAct -> IO ()
assertUnboundDirectoryConflict frame act = do
    createDirectory (frameTarget frame)
    ByteString.writeFile (frameTarget frame </> "operator") "keep this directory\\n"
    identity <- observeIdentity (frameTarget frame)
    publishUnboundDirectoryForFrame frame
    before <- recordForFrame frame
    result <- runShippedOwnership ownershipRowForHost (transactionFor frame act)
    case result of
        ShippedRefused (OwnershipConflict report) -> do
            conflictSubject report
                @?= Text.pack (frameTarget frame)
                    <> " exists without a recorded identity; inspect it and restore the recorded absence before retrying"
            conflictExpected report @?= OriginAbsent
            conflictObserved report @?= OriginPresent identity
        other -> assertFailure ("expected an unbound directory conflict with recovery guidance, got " <> show other)
    observeIdentity (frameTarget frame) >>= (@?= identity)
    ByteString.readFile (frameTarget frame </> "operator") >>= (@?= "keep this directory\\n")
    recordForFrame frame >>= (@?= before)

expectMalformedOutcome :: ShippedOutcome -> IO ()
expectMalformedOutcome (ShippedRefused (OwnershipMalformed _)) = pure ()
expectMalformedOutcome other = assertFailure ("expected an exact malformed-record refusal, got " <> show other)

transactionFor :: Frame -> ShippedAct -> ShippedOwnership
transactionFor frame act =
    mkShippedOwnership
        (fixtureAuthority (frameAuthority frame))
        specRecordKey
        (fixtureTarget (frameTarget frame))
        act

specRecordKey :: RecordKey
specRecordKey =
    either (error "the spec's own record key must be admitted") id (mkRecordKey "shipped.spec.object")

sample :: ShippedAct -> ShippedOwnership
sample act =
    mkShippedOwnership (fixtureAuthority "/var/tmp/authority") specRecordKey (fixtureTarget "/var/tmp/owned") act

fixtureAuthority :: FilePath -> ShippedAuthorityPath
fixtureAuthority = either (error . show) id . mkShippedAuthorityPath

fixtureTarget :: FilePath -> ShippedTargetPath
fixtureTarget = either (error . show) id . mkShippedTargetPath

fixtureLinkTarget :: FilePath -> ShippedLinkTargetPath
fixtureLinkTarget = either (error . show) id . mkShippedLinkTargetPath

{- | A host that resolves no tool, so a crossing that needed one would refuse
before it launched. Every case here uses the empty context, which needs none.
-}
unresolvedHostConfig :: HostConfig
unresolvedHostConfig =
    HostConfig
        { hcSubstrate = Substrate{substrateName = LinuxCpu, substrateArch = Amd64}
        , hcToolPaths = Map.empty
        }

someIdentity :: IO ObjectIdentity
someIdentity = withSystemTempDirectory "hb-shipped-identity" observeIdentity

observeIdentity :: FilePath -> IO ObjectIdentity
observeIdentity path = do
    observed <- withOwnershipRow ownershipRowForHost (\row -> rowObserveIdentity row path)
    case observed of
        Right (Just identity) -> pure identity
        other -> assertFailure ("expected an identity, got " <> show other)

expectTaken :: ShippedOutcome -> IO ObjectIdentity
expectTaken (ShippedObjectTaken identity) = pure identity
expectTaken other = assertFailure ("expected an owned object, got " <> show other)

expectMalformedReason :: (Show value) => Text.Text -> Either OwnershipFault value -> IO ()
expectMalformedReason expected outcome = case outcome of
    Left (OwnershipMalformed reason) -> reason @?= expected
    other -> assertFailure ("expected the exact malformed-wire diagnostic, got " <> show other)

expectMalformed :: (Show value) => String -> Either OwnershipFault value -> IO ()
expectMalformed label outcome = case outcome of
    Left (OwnershipMalformed _) -> pure ()
    other -> assertFailure (label <> ": expected a malformed refusal, got " <> show other)

removeAndReplace :: FilePath -> IO ()
removeAndReplace path = do
    -- Retain the original inode so the replacement cannot reuse its identity.
    renameDirectory path (path <> "-original")
    createDirectory path

-- ---------------------------------------------------------------------------
-- Wire fixtures

{- | Build one transaction's wire by hand.

Hand-built rather than produced by the encoder, because the decoder's own
admissions — an unknown act, a record key the store would refuse — describe
values the encoder cannot construct. A fixture that could only be produced by
the encoder could never reach them.
-}
rawTransaction :: Word8 -> ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString
rawTransaction tag authority key target =
    LazyByteString.toStrict
        ( Builder.toLazyByteString
            ( Builder.byteString transactionPrefix
                <> Builder.word8 tag
                <> sizedField authority
                <> sizedField key
                <> sizedField target
            )
        )

wireFields :: ByteString.ByteString -> Word8 -> [Builder.Builder] -> ByteString.ByteString
wireFields prefix tag fields =
    LazyByteString.toStrict
        (Builder.toLazyByteString (Builder.byteString prefix <> Builder.word8 tag <> mconcat fields))

baseTransactionFields :: [Builder.Builder]
baseTransactionFields =
    map sizedField ["/var/tmp/authority", asciiOf (recordKeyText specRecordKey), "/var/tmp/owned"]

faultTextFields :: [([Builder.Builder], Text.Text)]
faultTextFields =
    [ ([Builder.word8 0], "an unsupported refusal's reason")
    , ([Builder.word8 1], "a probe failure's operation")
    , ([Builder.word8 1, sizedField "observe"], "a probe failure's reason")
    , ([Builder.word8 2], "a malformed refusal's reason")
    , ([Builder.word8 3], "an occupied refusal's reason")
    , ([Builder.word8 4], "a conflict's subject")
    ]

sizedField :: ByteString.ByteString -> Builder.Builder
sizedField bytes =
    Builder.word32LE (fromIntegral (ByteString.length bytes)) <> Builder.byteString bytes

transactionPrefix :: ByteString.ByteString
transactionPrefix = "hb-owned-transaction-1"

outcomePrefix :: ByteString.ByteString
outcomePrefix = "hb-owned-outcome-1"

withOutcomeTag :: Word8 -> ShippedOutcome -> ByteString.ByteString
withOutcomeTag tag outcome =
    replaceByteAt (ByteString.length outcomePrefix) tag (encodeShippedOutcome outcome)

replaceByteAt :: Int -> Word8 -> ByteString.ByteString -> ByteString.ByteString
replaceByteAt index value raw =
    ByteString.take index raw <> ByteString.singleton value <> ByteString.drop (index + 1) raw

asciiOf :: Text.Text -> ByteString.ByteString
asciiOf = TextEncoding.encodeUtf8
