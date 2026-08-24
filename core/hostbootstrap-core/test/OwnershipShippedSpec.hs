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
   production classifier, the production child body, and the argument vector the
   lift fold places at the leaf — so "the transaction reached another process and
   an answer came back" is a property of a program that would not finish if it
   were false.

A crossing into a provider frame is the worked-demo phase's to confirm live and
is not simulated here.
-}
module OwnershipShippedSpec (tests) where

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
import HostBootstrap.Lift (localContext, mkSelfRef)
import HostBootstrap.Ownership.Object (
    ConflictReport (ConflictReport, conflictExpected, conflictObserved, conflictSubject),
    ObjectIdentity,
    Origin (OriginAbsent, OriginPresent),
    OwnershipFault (
        OwnershipConflict,
        OwnershipMalformed,
        OwnershipOccupied,
        OwnershipProbeFailed,
        OwnershipUnsupported
    ),
    mkPayload,
 )
import HostBootstrap.Ownership.Primitive (rowObserveIdentity, withOwnershipRow)
import HostBootstrap.Ownership.Row (hostOwnershipSupported, ownershipRowForHost)
import HostBootstrap.Ownership.Shipped
import HostBootstrap.Protected (RecordKey, mkRecordKey, recordKeyText)
import HostBootstrap.Substrate (
    Arch (Amd64),
    Substrate (Substrate, substrateArch, substrateName),
    SubstrateName (LinuxCpu),
 )
import HostBootstrap.Substrate.Frame (
    FrameOwnershipRow (HostOwnershipRow, PosixOwnershipRow),
    frameOwnershipRow,
    frameOwnsLocally,
 )
import System.Directory (
    createDirectory,
    createFileLink,
    doesDirectoryExist,
    doesFileExist,
    doesPathExist,
    getSymbolicLinkTarget,
    pathIsSymbolicLink,
    removeDirectoryRecursive,
    removeFile,
 )
import System.Environment (getExecutablePath)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "OwnershipShippedSpec"
        [ testGroup "the frame table's ownership column" columnTests
        , testGroup "the transaction's own encoding" transactionCodecTests
        , testGroup "the outcome's own encoding" outcomeCodecTests
        , testGroup "the transaction, run where the object is" interpreterTests
        , testGroup "the crossing, across a real process boundary" crossingTests
        ]

-- ---------------------------------------------------------------------------
-- The column

columnTests :: [TestTree]
columnTests =
    [ testCase "the outer host's clauses are held by this binary's own row" $ do
        frameOwnershipRow OuterHost @?= HostOwnershipRow
        assertBool "the outer host owns locally" (frameOwnsLocally OuterHost)
    , testCase "every crossing's clauses are held by the POSIX row" $ do
        -- Every frame this project reaches through a host-provider command is
        -- Linux, so one answer covers all four crossings rather than four
        -- per-provider entries that could fall out of step.
        mapM_
            (\crossing -> frameOwnershipRow (CrossedInto crossing []) @?= PosixOwnershipRow)
            everyCrossing
        mapM_
            ( \crossing ->
                assertBool
                    "a crossed frame does not own locally"
                    (not (frameOwnsLocally (CrossedInto crossing [])))
            )
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
            , ShipTakeSymbolicLink "/srv/project-data"
            , ShipGiveBackSymbolicLink "/srv/project-data"
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

interpreterTests :: [TestTree]
interpreterTests =
    [ rowCase "an absent object is reported absent, and nothing is created" $ \frame -> do
        outcome <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipObserveObject)
        outcome @?= ShippedObjectAbsent
        present <- doesDirectoryExist (frameTarget frame)
        assertBool "observing creates nothing" (not present)
    , rowCase "a directory is taken under all four clauses, and given back" $ \frame -> do
        taken <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        identity <- expectTaken taken
        present <- doesDirectoryExist (frameTarget frame)
        assertBool "the directory exists after the transaction" present
        observed <- observeIdentity (frameTarget frame)
        observed @?= identity

        reported <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipObserveObject)
        reported @?= ShippedObjectPresent identity

        given <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipGiveBackObject)
        given @?= ShippedObjectGivenBack
        gone <- doesDirectoryExist (frameTarget frame)
        assertBool "the directory is gone" (not gone)
    , rowCase "a file is published with its payload, and given back" $ \frame -> do
        let payload = "let cfg = { project = \"demo\" } in cfg\n"
        taken <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeFile (mkPayload payload)))
        _ <- expectTaken taken
        installed <- ByteString.readFile (frameTarget frame)
        installed @?= payload

        given <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipGiveBackObject)
        given @?= ShippedObjectGivenBack
        gone <- doesFileExist (frameTarget frame)
        assertBool "the file is gone" (not gone)
    , rowCase "an exact retry converges on the record this frame already holds" $ \frame -> do
        first <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        identity <- expectTaken first
        again <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        again @?= ShippedObjectTaken identity
    , rowCase "a symbolic link is published, retained on retry, and conditionally given back" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        created <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeSymbolicLink (frameLinkTarget frame)))
        identity <- case created of
            ShippedSymbolicLinkCreated value -> pure value
            other -> assertFailure ("expected a created symbolic link, got " <> show other)
        linked <- pathIsSymbolicLink (frameTarget frame)
        assertBool "the published object is a symbolic link" linked
        getSymbolicLinkTarget (frameTarget frame) >>= (@?= frameLinkTarget frame)

        retried <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeSymbolicLink (frameLinkTarget frame)))
        retried @?= ShippedSymbolicLinkRetained identity

        released <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipGiveBackSymbolicLink (frameLinkTarget frame)))
        released @?= ShippedObjectGivenBack
        remaining <- doesPathExist (frameTarget frame)
        assertBool "the managed symbolic link was removed" (not remaining)
        targetRemaining <- doesDirectoryExist (frameLinkTarget frame)
        assertBool "the symbolic link target was not removed" targetRemaining
    , rowCase "an exact-looking symbolic link without this transaction's record remains foreign" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        createFileLink (frameLinkTarget frame) (frameTarget frame)
        refused <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeSymbolicLink (frameLinkTarget frame)))
        case refused of
            ShippedRefused (OwnershipOccupied _) -> pure ()
            other -> assertFailure ("expected an occupied refusal, got " <> show other)
        linked <- pathIsSymbolicLink (frameTarget frame)
        assertBool "the foreign exact-looking link survived" linked
    , rowCase "a replacement symbolic link is refused on release and left intact" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        _ <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeSymbolicLink (frameLinkTarget frame)))
        removeFile (frameTarget frame)
        createFileLink "/operator/replacement" (frameTarget frame)
        refused <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipGiveBackSymbolicLink (frameLinkTarget frame)))
        expectRefusal "giving back a replacement symbolic link" refused
        getSymbolicLinkTarget (frameTarget frame) >>= (@?= "/operator/replacement")
    , rowCase "an object already there is refused, and nothing is recorded" $ \frame -> do
        ByteString.writeFile (frameTarget frame) "an operator's file\n"
        refused <-
            runShippedOwnership
                ownershipRowForHost
                (transactionFor frame (ShipTakeFile (mkPayload "ours\n")))
        expectRefusal "taking an occupied target" refused
        kept <- ByteString.readFile (frameTarget frame)
        kept @?= "an operator's file\n"
    , rowCase "giving back what was never taken is a settled answer, not a refusal" $ \frame -> do
        given <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipGiveBackObject)
        given @?= ShippedObjectGivenBack
    , rowCase "a replaced object is refused, and left intact" $ \frame -> do
        _ <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipTakeDirectory)
        removeAndReplace (frameTarget frame)
        refused <- runShippedOwnership ownershipRowForHost (transactionFor frame ShipGiveBackObject)
        expectRefusal "giving back a replacement" refused
        survived <- doesDirectoryExist (frameTarget frame)
        assertBool "the replacement is untouched" survived
    ]

-- ---------------------------------------------------------------------------
-- The crossing

crossingTests :: [TestTree]
crossingTests =
    [ testCase "an empty context runs the transaction in a real child process" $
        withFrame $ \frame -> do
            executable <- getExecutablePath
            let self = mkSelfRef executable executable
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
            let self = mkSelfRef executable executable
            ByteString.writeFile (frameTarget frame) "an operator's file\n"
            refused <-
                shipOwnedTransaction
                    unresolvedHostConfig
                    self
                    localContext
                    (transactionFor frame (ShipTakeFile (mkPayload "ours\n")))
            case refused of
                Left (OwnershipOccupied _) -> pure ()
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

transactionFor :: Frame -> ShippedAct -> ShippedOwnership
transactionFor frame act =
    ShippedOwnership
        { shippedAuthority = frameAuthority frame
        , shippedRecord = specRecordKey
        , shippedTarget = frameTarget frame
        , shippedAct = act
        }

specRecordKey :: RecordKey
specRecordKey =
    either (error "the spec's own record key must be admitted") id (mkRecordKey "shipped.spec.object")

sample :: ShippedAct -> ShippedOwnership
sample act =
    ShippedOwnership
        { shippedAuthority = "/var/tmp/authority"
        , shippedRecord = specRecordKey
        , shippedTarget = "/var/tmp/owned"
        , shippedAct = act
        }

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

expectRefusal :: String -> ShippedOutcome -> IO ()
expectRefusal label outcome = case outcome of
    ShippedRefused _ -> pure ()
    other -> assertFailure (label <> ": expected a refusal, got " <> show other)

expectMalformed :: (Show value) => String -> Either OwnershipFault value -> IO ()
expectMalformed label outcome = case outcome of
    Left (OwnershipMalformed _) -> pure ()
    other -> assertFailure (label <> ": expected a malformed refusal, got " <> show other)

removeAndReplace :: FilePath -> IO ()
removeAndReplace path = do
    removeDirectoryRecursive path
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
