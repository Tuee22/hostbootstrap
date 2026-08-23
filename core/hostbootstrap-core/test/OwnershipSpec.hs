{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The seam's declared capabilities, and the refusal a row owes for a clause it
cannot hold.

Three things are proved here, and they are deliberately the three that do not
need a kernel.

The first is the classifier. Which clauses a row can hold is a /declaration/, and
the refusal that follows from it is a total function of that declaration, so it
is exercised over every one of the sixteen capability combinations by
application. Nothing runs, nothing is stubbed, and a case that changed shows up
as a different value rather than as a stand-in nobody called (§ NN).

The second is that the refusal happens /before/ the kernel. The row the entry
case runs against supplies primitives that cannot be called at all: every field
diverges. A producer that reached one would fail the case by throwing, so
"reaches no mutation" is a property of the program rather than of a counter a
fake incremented.

The third is that every other producer consults the same classifier before it
reaches a primitive. That is a source guard rather than a run, and honestly so:
reaching the later producers needs a token, a token needs a successful entry, and
a successful entry needs a kernel read — which is a platform row and belongs to
the sprint that supplies it. The chain's behaviour is proved there, against the
real kernel, rather than here against something written to stand in for one.
-}
module OwnershipSpec (tests) where

import Control.Exception (SomeException, try)
import Data.Foldable (for_, traverse_)
import Data.List (isInfixOf)
import Data.Maybe (isJust)
import HostBootstrap.DocValidator (findRepoRoot)
import qualified Data.Text as Text
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import HostBootstrap.Ownership.Clause (Bound, boundEvidence)
import HostBootstrap.Ownership.Object
    ( ConflictReport (conflictExpected, conflictObserved, conflictSubject)
    , ObjectIdentity
    , ObjectKind (OwnedDirectory, ReportedObject)
    , Origin (OriginAbsent, OriginPresent)
    , OriginRecord
    , OwnershipFault (OwnershipConflict, OwnershipMalformed, OwnershipUnsupported)
    , bindOriginRecord
    , mkKernelObjectIdentity
    , mkOwnerClaim
    , mkPayload
    , originRecord
    , originRecordBinding
    , originRecordOrigin
    , ownershipFaultMessage
    )
import HostBootstrap.Ownership.Primitive
import HostBootstrap.Protected (ProtectedSession, openProtectedStore, withProtectedEntry)
import qualified SourceGuard
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "OwnershipSpec"
        [ testGroup "the capability classifier" classifierTests
        , testGroup "a row that cannot hold a clause" refusalTests
        , testGroup "re-entering an owned object" reentryTests
        , testGroup "the reported observation" reportedTests
        , testGroup "the seam's shape" seamTests
        ]

-- ---------------------------------------------------------------------------
-- The classifier

classifierTests :: [TestTree]
classifierTests =
    [ testCase "a row that holds everything owes no refusal" $
        traverse_
            (\clause -> clauseRefusal fullCapabilities clause @?= Nothing)
            [minBound .. maxBound]
    , testCase "each clause refuses exactly when a capability it needs is absent" $
        for_ everyCapability $ \capabilities -> do
            let refuses clause = isJust (clauseRefusal capabilities clause)
                identity = holdsStableIdentity capabilities
                parent = holdsDurableParentSync capabilities
                publication = holdsNoReplacePublication capabilities
            refuses ClauseEnter @?= not identity
            refuses ClauseRecord @?= not (identity && parent)
            refuses ClauseBind @?= not (identity && publication)
            refuses ClauseRelease @?= not identity
    , testCase "the exclusive open is a primitive rather than a clause requirement" $ do
        -- Clause 1 is the protected store's own entry, so a row that cannot
        -- open one named object exclusively still holds every clause. The
        -- capability is declared because owners that must hold an existing
        -- object open consult it, not because a clause does.
        let withoutOpen = fullCapabilities{holdsExclusiveOpen = False}
        traverse_
            (\clause -> clauseRefusal withoutOpen clause @?= Nothing)
            [minBound .. maxBound]
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
        withEntry $ \session -> do
            outcome <-
                try
                    ( reenterOwnedObject
                        (unreachableRow fullCapabilities)
                        session
                        "/owned/target"
                        (originRecord OwnedDirectory OriginAbsent)
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
        withEntry $ \session -> do
            outcome <-
                try
                    ( reenterOwnedObject
                        (unreachableRow noCapabilities)
                        session
                        "/owned/target"
                        (originRecord OwnedDirectory OriginAbsent)
                        (\_ -> pure (Right ()))
                    )
            expectUnsupported outcome
    , testCase "a bound record discloses exactly the target and identity it names" $
        withEntry $ \session -> do
            identity <- expectIdentity (mkKernelObjectIdentity 7 11)
            bound <- expectBound (bindOriginRecord identity (originRecord OwnedDirectory OriginAbsent))
            outcome <-
                reenterOwnedObject
                    (unreachableRow fullCapabilities)
                    session
                    "/owned/target"
                    bound
                    ( boundEvidence
                        ( \target record disclosed ->
                            pure (Right (target, record, disclosed))
                        )
                    )
            outcome @?= Right ("/owned/target", bound, identity)
    ]

-- ---------------------------------------------------------------------------
-- The reported observation

{- | The face of the seam whose observation is an answer rather than a probe.

Every case here runs the clause order to completion with no row in scope at all,
which is the point: the reported producers take none, so "this face reaches no
kernel primitive" is a property of their types rather than of a stand-in that
has to be trusted not to have been called. The one row that does appear belongs
to re-entry, which is how a 'Bound' token is minted from a durable record, and it
is the diverging row — so a case that reached it would not finish.
-}
reportedTests :: [TestTree]
reportedTests =
    [ testCase "the origin a record describes is the observation the caller was handed" $
        withEntry $ \session -> do
            identity <- expectIdentity (mkKernelObjectIdentity 3 5)
            for_ [OriginAbsent, OriginPresent identity] $ \observed -> do
                published <- newIORef Nothing
                outcome <-
                    enterReportedObject session "/reported/target" observed $ \entered ->
                        fmap
                            (fmap (const ()))
                            ( recordReportedOrigin
                                entered
                                OwnedDirectory
                                (\record -> Right () <$ writeIORef published (Just record))
                            )
                outcome @?= Right ()
                recorded <- readIORef published
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
                            OwnedDirectory
                            (\_ -> pure (Left (OwnershipMalformed "the store refused")))
                        )
            case outcome of
                Left (OwnershipMalformed reason) -> reason @?= "the store refused"
                other -> assertFailure ("expected the store's own refusal, got " <> show other)
    , testCase "clause 3 binds the identity the owning authority reported" $
        withEntry $ \session -> do
            identity <- expectIdentity (mkKernelObjectIdentity 11 13)
            published <- newIORef Nothing
            outcome <-
                enterReportedObject session "/reported/target" OriginAbsent $ \entered -> do
                    recorded <-
                        recordReportedOrigin entered OwnedDirectory (\_ -> pure (Right ()))
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
            identity <- expectIdentity (mkKernelObjectIdentity 17 19)
            other <- expectIdentity (mkKernelObjectIdentity 17 23)
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
            identity <- expectIdentity (mkKernelObjectIdentity 29 31)
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
                            (ReportedObject (mkOwnerClaim "one attempt"))
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
            let face = reportedFace source
            assertBool "the reported face is in the module" (not (null face))
            traverse_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier face @?= 0)
                [ "OwnershipRow"
                , "withOwnershipRow"
                , "rowCapabilities"
                , "clauseRefusal"
                , "rowObserveIdentity"
                , "rowRemoveObject"
                , "rowSyncParent"
                ]
    , testCase "both faces settle each shared clause through one computation" $
        withCoreSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Primitive.hs")
            traverse_
                ( \shared ->
                    assertBool
                        (shared <> " is the one computation both faces use")
                        (shared `isInfixOf` normalize source)
                )
                [ "Nothing -> recordReportedOrigin entered kind publish"
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
    outcome <-
        reenterOwnedObject
            (unreachableRow fullCapabilities)
            session
            "/reported/target"
            record
            (\bound -> Right () <$ use bound)
    either (\fault -> assertFailure ("could not re-enter: " <> show fault)) pure outcome

-- | The module region the reported producers occupy, and nothing else.
reportedFace :: String -> String
reportedFace source =
    unlines
        ( takeWhile (not . ("-- Shared steps" `isInfixOf`))
            (drop 1 (dropWhile (not . (opening `isInfixOf`)) (lines source)))
        )
  where
    opening = "-- The five clause producers, over an object an authority reports on"

isRight :: Either fault value -> Bool
isRight = either (const False) (const True)

expectIdentity :: Either OwnershipFault ObjectIdentity -> IO ObjectIdentity
expectIdentity = either (\fault -> assertFailure ("expected an identity: " <> show fault)) pure

expectBound :: Either OwnershipFault OriginRecord -> IO OriginRecord
expectBound = either (\fault -> assertFailure ("expected a bound record: " <> show fault)) pure

-- ---------------------------------------------------------------------------
-- The seam's shape

seamTests :: [TestTree]
seamTests =
    [ testCase "a sealed row discloses its declaration and never its handle type" $ do
        withOwnershipRow (unreachableRow fullCapabilities) rowCapabilities @?= fullCapabilities
        withOwnershipRow (unreachableRow noCapabilities) rowCapabilities @?= noCapabilities
    , testCase "every producer consults the classifier before it reaches a primitive" $
        withCoreSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Primitive.hs")
            -- Five producers gate on a clause directly. The three that mutate —
            -- creating a directory, publishing a file, and releasing — are
            -- reachable only from a token the gated producers minted, so gating
            -- them again would ask the same question twice.
            -- Its export, its signature, its definition, and one use in each
            -- of the five gated producers.
            SourceGuard.countHaskellIdentifier "clauseRefusal" source @?= 8
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

{- | Every capability combination, so the classifier is applied to all sixteen. -}
everyCapability :: [OwnershipCapabilities]
everyCapability =
    [ OwnershipCapabilities identity open publication parent
    | identity <- [False, True]
    , open <- [False, True]
    , publication <- [False, True]
    , parent <- [False, True]
    ]

fullCapabilities :: OwnershipCapabilities
fullCapabilities = OwnershipCapabilities True True True True

noCapabilities :: OwnershipCapabilities
noCapabilities = OwnershipCapabilities False False False False

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

withCoreSourceRoot :: (FilePath -> IO result) -> IO result
withCoreSourceRoot use = do
    cwd <- getCurrentDirectory
    repoRoot <-
        findRepoRoot cwd
            >>= maybe (assertFailure ("could not locate repo root from " <> cwd)) pure
    use (repoRoot </> "core" </> "hostbootstrap-core" </> "internal" </> "ownership")
