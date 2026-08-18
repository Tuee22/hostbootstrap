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
import HostBootstrap.Ownership.Object
    ( OwnershipFault (OwnershipUnsupported)
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
-- The seam's shape

seamTests :: [TestTree]
seamTests =
    [ testCase "a sealed row discloses its declaration and never its handle type" $ do
        withOwnershipRow (unreachableRow fullCapabilities) rowCapabilities @?= fullCapabilities
        withOwnershipRow (unreachableRow noCapabilities) rowCapabilities @?= noCapabilities
    , testCase "every producer consults the classifier before it reaches a primitive" $
        withCoreSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Primitive.hs")
            -- Four producers gate on a clause directly. The three that mutate —
            -- creating a directory, publishing a file, and releasing — are
            -- reachable only from a token the gated producers minted, so gating
            -- them again would ask the same question twice.
            -- Its export, its signature, its definition, and one use in each
            -- of the four gated producers.
            SourceGuard.countHaskellIdentifier "clauseRefusal" source @?= 7
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
            , rowPublishNoReplace = \_ -> unreachable "publish without replacing"
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
    use (repoRoot </> "core" </> "hostbootstrap-core" </> "src")
