{-# LANGUAGE OverloadedStrings #-}

{- | The owned-object vocabulary, proved by application.

Every case here is a pure function applied to a value. That is the point of the
module under test: the nouns the four ownership clauses are written in carry no
effects, so nothing here needs a filesystem, a stand-in, or a process, and a
property that holds by application holds on every gate host (§ NN).

What is covered is the whole of what a durable record can do to an owner. The
codec round-trips, and every way a record can be malformed — a wrong magic, a
wrong version, a wrong field count, a kind that carries the wrong payload
shape, a non-hex identity, a missing terminator, and a byte after it — is a
refusal rather than a partially understood record, because a record an owner
half-reads is the one input that could make it delete something it does not own.
-}
module OwnershipObjectSpec (tests) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.List (sort)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Ownership.Object
import qualified SourceGuard
import System.Directory (doesDirectoryExist, getCurrentDirectory, listDirectory)
import System.FilePath (takeExtension, (</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "OwnershipObjectSpec"
        [ testGroup "the kernel's answer" identityTests
        , testGroup "the intended payload" payloadTests
        , testGroup "the durable origin record" recordTests
        , testGroup "the closed fault sum" faultTests
        , testGroup "the clause tokens" clauseTests
        ]

-- ---------------------------------------------------------------------------
-- Identity

identityTests :: [TestTree]
identityTests =
    [ testCase "an identity is the kernel's non-empty answer and nothing else" $ do
        expectUnsupported (mkObjectIdentity "")
        expectUnsupported (mkObjectIdentity (ByteString.replicate 65 0x41))
        identity <- expectRight (mkObjectIdentity (ByteString.replicate 64 0x41))
        objectIdentityBytes identity @?= ByteString.replicate 64 0x41
    , testCase "an identity round-trips through its hex journal codec" $ do
        traverse_
            ( \raw -> do
                identity <- expectRight (mkObjectIdentity raw)
                readBack <- expectRight (parseObjectIdentityHex (objectIdentityText identity))
                readBack @?= identity
                objectIdentityBytes readBack @?= raw
            )
            [ ByteString.pack [0x00]
            , ByteString.pack [0xff]
            , ByteString.pack [0x01, 0x0a, 0xb2, 0xcd]
            , ByteString.replicate 64 0x7f
            ]
    , testCase "a journalled identity that is not lowercase hex is malformed" $ do
        traverse_
            (expectMalformed . parseObjectIdentityHex)
            [ ""
            , "0"
            , "abc"
            , "AB"
            , "0G"
            , "00 11"
            , "0x00"
            ]
        -- Well-formed hex the kernel could not have answered is refused by the
        -- constructor's own bound rather than by the codec, so the two refusals
        -- stay distinguishable in a report.
        expectUnsupported (parseObjectIdentityHex (Text.replicate 65 "ab"))
    , testCase "two identities compare by the bytes the kernel answered" $ do
        left <- expectRight (mkObjectIdentity "\x01\x02")
        right <- expectRight (mkObjectIdentity "\x01\x02")
        other <- expectRight (mkObjectIdentity "\x01\x03")
        left @?= right
        assertBool "different kernel answers are different identities" (left /= other)
        objectIdentityText other @?= "0103"
    ]

-- ---------------------------------------------------------------------------
-- Payload

payloadTests :: [TestTree]
payloadTests =
    [ testCase "a payload digest is the SHA-256 of exactly the intended bytes" $ do
        payloadDigestText (payloadDigest (mkPayload ""))
            @?= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        payloadDigestText (payloadDigest (mkPayload "abc"))
            @?= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        assertBool
            "different payloads digest differently"
            (payloadDigest (mkPayload "abc") /= payloadDigest (mkPayload "abd"))
        payloadBytes (mkPayload "abc") @?= "abc"
    , testCase "a payload digest round-trips through its journal codec" $ do
        let digest = payloadDigest (mkPayload "the run's intended bytes")
        readBack <- expectRight (parsePayloadDigestHex (payloadDigestText digest))
        readBack @?= digest
    , testCase "a journalled digest that is not 64 lowercase hex characters is malformed" $
        traverse_
            (expectMalformed . parsePayloadDigestHex)
            [ ""
            , "-"
            , Text.replicate 63 "a"
            , Text.replicate 65 "a"
            , Text.replicate 64 "A"
            , Text.replicate 63 "a" <> "g"
            ]
    ]

-- ---------------------------------------------------------------------------
-- The record

recordTests :: [TestTree]
recordTests =
    [ testCase "a record carries what was observed and claims no binding it never made" $ do
        prior <- expectRight (mkObjectIdentity "\x0a\x0b")
        let record = originRecord OwnedDirectory (OriginPresent prior)
        originRecordKind record @?= OwnedDirectory
        originRecordOrigin record @?= OriginPresent prior
        originRecordBinding record @?= Nothing
        objectKindIsDirectory (originRecordKind record) @?= True
        originIdentity (originRecordOrigin record) @?= Just prior
        originIdentity OriginAbsent @?= Nothing
    , testCase "a binding is attached once and a second identity is a conflict" $ do
        created <- expectRight (mkObjectIdentity "\x01")
        other <- expectRight (mkObjectIdentity "\x02")
        bound <- expectRight (bindOriginRecord created (originRecord OwnedDirectory OriginAbsent))
        originRecordBinding bound @?= Just created
        rebound <- expectRight (bindOriginRecord created bound)
        originRecordBinding rebound @?= Just created
        case bindOriginRecord other bound of
            Left (OwnershipConflict report) -> do
                conflictExpected report @?= OriginPresent created
                conflictObserved report @?= OriginPresent other
            other' -> assertFailure ("expected a conflict, got " <> show other')
    , testCase "every record shape round-trips through the one canonical codec" $
        traverse_
            roundTrips
            [ originRecord OwnedDirectory OriginAbsent
            , originRecord (OwnedFile (payloadDigest (mkPayload "installed bytes"))) OriginAbsent
            , originRecord OwnedDirectory (OriginPresent (forceIdentity "\x0a\xff"))
            , originRecord
                (OwnedFile (payloadDigest (mkPayload "")))
                (OriginPresent (forceIdentity "\x01\x02\x03\x04"))
            , forceBound (forceIdentity "\x10\x20") (originRecord OwnedDirectory OriginAbsent)
            , forceBound
                (forceIdentity "\x10\x20")
                ( originRecord
                    (OwnedFile (payloadDigest (mkPayload "installed bytes")))
                    (OriginPresent (forceIdentity "\xaa"))
                )
            , originRecord (ReportedObject (mkOwnerClaim "one attempt")) OriginAbsent
            , forceBound
                (forceIdentity "\x10\x20")
                ( originRecord
                    (ReportedObject (mkOwnerClaim "another attempt"))
                    (OriginPresent (forceIdentity "\xaa"))
                )
            ]
    , testCase "the rendered record is one terminated line of six tokens" $ do
        let rendered = renderOriginRecord (originRecord OwnedDirectory OriginAbsent)
        rendered @?= "ownership 1 directory absent - -\n"
        renderOriginRecord
            ( forceBound
                (forceIdentity "\x0a")
                (originRecord (OwnedFile (payloadDigest (mkPayload "abc"))) (OriginPresent (forceIdentity "\xff")))
            )
            @?= ( "ownership 1 file ff "
                    <> "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 0a\n"
                )
        ownershipRecordVersion @?= "1"
    , testCase "a reported-object record renders its owner claim in the payload column" $ do
        let claim = mkOwnerClaim "one attempt"
        renderOriginRecord (originRecord (ReportedObject claim) OriginAbsent)
            @?= ByteString.concat
                [ "ownership 1 reported absent "
                , TextEncoding.encodeUtf8 (ownerClaimText claim)
                , " -\n"
                ]
        -- The column carries whichever value the kind's own case has, and no
        -- record has two of them.
        Text.length (ownerClaimText claim) @?= 64
    , testCase "an owner claim is the SHA-256 of exactly the bytes it was minted from" $ do
        ownerClaimText (mkOwnerClaim "abc")
            @?= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        assertBool
            "two derivations that differ mint different claims"
            (mkOwnerClaim "one attempt" /= mkOwnerClaim "another attempt")
    , testCase "a journalled owner claim that is not 64 lowercase hex characters is malformed" $ do
        claim <- expectRight (parseOwnerClaimHex (ownerClaimText (mkOwnerClaim "abc")))
        claim @?= mkOwnerClaim "abc"
        traverse_
            (expectMalformed . parseOwnerClaimHex)
            [ ""
            , "deadbeef"
            , Text.toUpper (ownerClaimText (mkOwnerClaim "abc"))
            , ownerClaimText (mkOwnerClaim "abc") <> "0"
            ]
    , testCase "a record this vocabulary did not write is refused rather than guessed at" $
        traverse_
            (expectMalformed . parseOriginRecord)
            [ ""
            , "\n"
            , "ownership 1 directory absent - -"
            , "ownership 1 directory absent - -\n\n"
            , "ownership 1 directory absent - -\nownership 1 directory absent - -\n"
            , "ownership 1 directory absent - -\n "
            , "ownership 2 directory absent - -\n"
            , "reservation 1 directory absent - -\n"
            , "ownership 1 directory absent -\n"
            , "ownership 1 directory absent - - -\n"
            , "ownership 1 socket absent - -\n"
            , "ownership 1 directory absent deadbeef -\n"
            , "ownership 1 file absent - -\n"
            , "ownership 1 file absent nothex -\n"
            , "ownership 1 reported absent - -\n"
            , "ownership 1 reported absent nothex -\n"
            , "ownership 1 directory NOTHEX - -\n"
            , "ownership 1 directory absent - NOTHEX\n"
            , "ownership 1 directory absent - absent\n"
            , ByteString.pack [0x6f, 0x77, 0xff, 0x0a]
            ]
    , testCase "a record is compared by its own bytes rather than by its rendering's shape" $ do
        let record = originRecord (OwnedFile (payloadDigest (mkPayload "abc"))) OriginAbsent
        readBack <- expectRight (parseOriginRecord (renderOriginRecord record))
        readBack @?= record
        assertBool
            "the payload digest survives the round trip"
            (originRecordKind readBack == OwnedFile (payloadDigest (mkPayload "abc")))
    ]

roundTrips :: OriginRecord -> IO ()
roundTrips record = do
    readBack <- expectRight (parseOriginRecord (renderOriginRecord record))
    readBack @?= record
    renderOriginRecord readBack @?= renderOriginRecord record

-- ---------------------------------------------------------------------------
-- Faults

faultTests :: [TestTree]
faultTests =
    [ testCase "the eliminator reaches every case and nothing else" $ do
        let label =
                ownershipFault
                    (const ("unsupported" :: Text.Text))
                    (\_ _ -> "probe-failed")
                    (const "malformed")
                    (const "occupied")
                    (const "conflict")
        label (OwnershipUnsupported "no stable identity") @?= "unsupported"
        label (OwnershipProbeFailed "read the identity" "denied") @?= "probe-failed"
        label (OwnershipMalformed "not a record") @?= "malformed"
        label (OwnershipOccupied "already there") @?= "occupied"
        label (OwnershipConflict sampleConflict) @?= "conflict"
    , testCase "a fault's message names the fault and both sides of a conflict" $ do
        ownershipFaultMessage (OwnershipUnsupported "no stable identity") @?= "no stable identity"
        ownershipFaultMessage (OwnershipProbeFailed "read the identity" "denied")
            @?= "could not read the identity: denied"
        ownershipFaultMessage (OwnershipMalformed "not a record") @?= "not a record"
        ownershipFaultMessage (OwnershipOccupied "already there") @?= "already there"
        ownershipFaultMessage (OwnershipConflict sampleConflict)
            @?= "the generated config: expected 0a, observed nothing"
    ]

sampleConflict :: ConflictReport
sampleConflict =
    ConflictReport
        { conflictSubject = "the generated config"
        , conflictExpected = OriginPresent (forceIdentity "\x0a")
        , conflictObserved = OriginAbsent
        }

-- ---------------------------------------------------------------------------
-- The clause tokens

{- | Where the tokens live, and what a caller can reach.

The ordering theorem itself is proved by the compile-fail fixtures — a token a
caller could construct would make every one of them pass vacuously — so what is
left for a running case is the shape those fixtures depend on: that the
constructors are in one Cabal-private module, that only this phase's own modules
import it, that both indices are declared nominal rather than left phantom, and
that the facade publishes the abstract types and their eliminators and nothing
else.
-}
clauseTests :: [TestTree]
clauseTests =
    [ testCase "the constructors are private and only this phase's own modules reach them" $
        withCoreSourceRoot $ \packageRoot sourceRoot -> do
            internalSource <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Internal.hs")
            clauseSource <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Clause.hs")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            let rows = map (unwords . words) (lines cabalSource)
                importsInternal name =
                    SourceGuard.importsModule "HostBootstrap.Ownership.Internal" name
            assertBool
                "the constructor owner is registered privately"
                ("HostBootstrap.Ownership.Internal" `elem` rows)
            assertBool
                "the facade and the vocabulary are the public surface"
                ( "HostBootstrap.Ownership.Clause" `elem` rows
                    && "HostBootstrap.Ownership.Object" `elem` rows
                )
            assertBool "the facade imports the constructor owner" (importsInternal clauseSource)
            importers <- ownershipInternalImporters sourceRoot
            importers
                @?= [ "HostBootstrap/Ownership/Clause.hs"
                    , "HostBootstrap/Ownership/Primitive.hs"
                    ]
            traverse_
                (\pragma -> assertBool (pragma <> " is declared") (pragma `elem` roleLines internalSource))
                [ "type role Entered nominal nominal"
                , "type role Recorded nominal nominal"
                , "type role Bound nominal nominal"
                , "type role Releasable nominal nominal"
                ]
            traverse_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier internalSource @?= 0)
                [ "IO"
                , "unsafeCoerce"
                , "ProtectedStore"
                , "HostCommand"
                , "createProcess"
                , -- The target rides on a token, so the module names a path
                  -- type; deriving one would be the pathname policy the seam
                  -- deliberately does not have.
                  "takeDirectory"
                , "takeFileName"
                , "makeAbsolute"
                , "</>"
                ]
    , testCase "the facade publishes the abstract tokens and their eliminators and nothing else" $
        withCoreSourceRoot $ \_packageRoot sourceRoot -> do
            clauseSource <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Clause.hs")
            exports <-
                maybe
                    (assertFailure "HostBootstrap.Ownership.Clause has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Ownership.Clause" clauseSource)
            map concat (chunkExports exports)
                @?= [ "OwnedTargetPath"
                    , "Entered"
                    , "Recorded"
                    , "Bound"
                    , "Releasable"
                    , "enteredEvidence"
                    , "recordedEvidence"
                    , "boundEvidence"
                    , "releasableEvidence"
                    ]
    , testCase "each eliminator discloses exactly what the next clause consumes" $
        withCoreSourceRoot $ \_packageRoot sourceRoot -> do
            internalSource <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Internal.hs")
            -- The tokens have no producer outside the seam, so what is checkable
            -- here is the disclosure each eliminator makes. A continuation rather
            -- than a field selector is the whole mechanism: a token that gains a
            -- fact becomes a compile error at every reader instead of a reader
            -- that silently keeps looking at the old ones.
            let normalized = unwords (words internalSource)
            traverse_
                ( \signature ->
                    assertBool
                        ("the eliminator is declared as " <> signature)
                        (signature `substringOf` normalized)
                )
                [ "enteredEvidence :: (OwnedTargetPath -> Origin -> result) -> Entered session object -> result"
                , "recordedEvidence :: (OwnedTargetPath -> OriginRecord -> result) -> Recorded session object -> result"
                , "boundEvidence :: (OwnedTargetPath -> OriginRecord -> ObjectIdentity -> result) -> Bound session object -> result"
                , "releasableEvidence :: (OwnedTargetPath -> OriginRecord -> ObjectIdentity -> result) -> Releasable session object -> result"
                ]
    ]

substringOf :: String -> String -> Bool
substringOf needle haystack = any (needle `isPrefixOfList`) (suffixes haystack)
  where
    suffixes [] = [[]]
    suffixes value@(_ : rest) = value : suffixes rest
    isPrefixOfList [] _ = True
    isPrefixOfList _ [] = False
    isPrefixOfList (x : xs) (y : ys) = x == y && isPrefixOfList xs ys

{- | Every Haskell source under the library's own source root. -}
coreHaskellSources :: FilePath -> IO [(FilePath, String)]
coreHaskellSources directory = do
    entries <- listDirectory directory
    fmap concat (traverse visit (sort entries))
  where
    visit entry = do
        let path = directory </> entry
        nested <- doesDirectoryExist path
        if nested
            then coreHaskellSources path
            else
                if takeExtension path == ".hs"
                    then do
                        source <- readFile path
                        pure [(path, source)]
                    else pure []

ownershipInternalImporters :: FilePath -> IO [FilePath]
ownershipInternalImporters sourceRoot = do
    sources <- coreHaskellSources sourceRoot
    pure
        ( sort
            [ SourceGuard.repoRelativePath sourceRoot path
            | (path, source) <- sources
            , SourceGuard.importsModule "HostBootstrap.Ownership.Internal" source
            ]
        )

roleLines :: String -> [String]
roleLines = map (unwords . words) . lines

chunkExports :: [String] -> [[String]]
chunkExports = foldr step []
  where
    step token accumulated
        | token == "," = [] : accumulated
        | otherwise = case accumulated of
            (current : rest) -> (token : current) : rest
            [] -> [[token]]

-- ---------------------------------------------------------------------------
-- Helpers

{- | An identity for a case that is not about the constructor's bounds.

It calls 'error' on a value the case already knows is admissible, so a bound
that changed shows up as a failing case rather than as a silently different
fixture.
-}
forceIdentity :: ByteString -> ObjectIdentity
forceIdentity raw = either (error . show) id (mkObjectIdentity raw)

forceBound :: ObjectIdentity -> OriginRecord -> OriginRecord
forceBound identity record = either (error . show) id (bindOriginRecord identity record)

expectRight :: (Show fault) => Either fault value -> IO value
expectRight (Right value) = pure value
expectRight (Left fault) = assertFailure ("expected a value, got " <> show fault)

expectUnsupported :: (Show value) => Either OwnershipFault value -> IO ()
expectUnsupported outcome = case outcome of
    Left (OwnershipUnsupported _) -> pure ()
    other -> assertFailure ("expected an unsupported refusal, got " <> show other)

expectMalformed :: (Show value) => Either OwnershipFault value -> IO ()
expectMalformed outcome = case outcome of
    Left (OwnershipMalformed _) -> pure ()
    other -> assertFailure ("expected a malformed refusal, got " <> show other)

withCoreSourceRoot :: (FilePath -> FilePath -> IO result) -> IO result
withCoreSourceRoot use = do
    cwd <- getCurrentDirectory
    repoRoot <-
        findRepoRoot cwd
            >>= maybe (assertFailure ("could not locate repo root from " <> cwd)) pure
    let packageRoot = repoRoot </> "core" </> "hostbootstrap-core"
    use packageRoot (packageRoot </> "src")
