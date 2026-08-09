module CompileFailSpec (tests) where

import Data.List (isInfixOf)
import HostBootstrap.DocValidator (findRepoRoot)
import System.Directory (getCurrentDirectory, withCurrentDirectory)
import System.Exit (ExitCode (ExitFailure))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

tests :: TestTree
tests =
    testGroup
        "public compile-fail boundaries"
        [ rejects "RawStep.hs"
        , rejects "RawProjectSpec.hs"
        , rejects "ForgeProjectStepIdentity.hs"
        , rejects "ReplaceProjectContribution.hs"
        , rejects "DispatchUnfinishedBuilder.hs"
        , rejects "CrossFinalizationCodec.hs"
        , rejects "ForgeRoleParams.hs"
        , rejects "RawReadiness.hs"
        , rejects "RawBudget.hs"
        , rejects "RawReconcile.hs"
        , rejects "ForgeStrongAliasBackend.hs"
        , rejects "ForgePreparedGuestAliasCall.hs"
        , rejects "ObservedReadyGuestAlias.hs"
        , rejects "ForeignGuestAliasRelease.hs"
        , rejects "CrossAliasReceipt.hs"
        , rejects "ForeignClusterCleanup.hs"
        , rejects "CrossClusterReceipt.hs"
        , rejects "HostLocalClusterRedirect.hs"
        , rejects "EndpointScopeSubstitution.hs"
        , rejects "RawRegistryPlan.hs"
        , rejects "ForgeReadyBlobRoute.hs"
        , rejects "ForgeCommandAuthority.hs"
        , rejects "WrongVerbCloseRoot.hs"
        , rejectsWith
            "ForgeHarnessAuthority.hs"
            ["does not export any children"]
        , rejectsWith
            "OpenHarnessAuthorityFromText.hs"
            ["does not export", "withHarnessAuthority"]
        , rejectsWith
            "HarnessConfigAsProduction.hs"
            ["Expected: SecretRef (Production Project)"]
        , rejectsWith
            "CrossRunPlaintext.hs"
            [ "Expected: HarnessConfigAuthority Project runB"
            , "Actual: HarnessConfigAuthority Project runA"
            ]
        , rejectsWith
            "ProductionPlaintext.hs"
            ["Expected: SecretRef (Production Project)"]
        , rejects "HarnessLeaseAsProduction.hs"
        , rejects "ForgeRunLease.hs"
        , rejects "ForgeProtectedSession.hs"
        , rejects "ForgeVerifiedHandoff.hs"
        , rejects "CrossScopeHandoff.hs"
        , rejectsWith
            "SignHandoffWithoutRootStore.hs"
            ["Variable not in scope: signHandoffGrant"]
        , rejectsWith
            "RelaySignsWithoutBroker.hs"
            ["Couldn't match expected type: RootBroker"]
        , rejects "ForgeSessionPermit.hs"
        , rejectsWith
            "ClosingPermitAsOpen.hs"
            [ "Couldn't match expected type: ProjectPermit"
            , "with actual type: ClosingProjectPermit"
            ]
        , rejectsWith
            "ConstructTransactionInterrupted.hs"
            ["Illegal term-level use of the type constructor"]
        , rejects "ForgeBuildAuthority.hs"
        , rejects "ForgeRuntimeActivation.hs"
        , rejects "ForgeRoleCursor.hs"
        , rejects "ForgeTeardownForest.hs"
        , rejects "ForgePreconditionSet.hs"
        , rejects "ForgePreparedGate.hs"
        , -- A role performs only the effects its declared row names. 'HasEffect'
          -- has no empty-row equation, so the diagnostic names the effect the
          -- row lacks rather than reporting a generic mismatch.
          rejectsWith
            "UndeclaredServiceEffect.hs"
            ["Could not solve: \8216HasEffect DurableStore '[]\8217"]
        , rejectsWith
            "ForgeStepExecution.hs"
            [ "Illegal term-level use of the type constructor 'StepExecution'"
            , "Data constructor not in scope: ExecutionNode"
            ]
        , rejectsWith
            "ForgeDetachedLaunch.hs"
            [ "Illegal term-level use of the type constructor 'DetachedLaunch'"
            , "Illegal term-level use of the type constructor 'DetachedChild'"
            , "Illegal term-level use of the type constructor 'DetachedWorkingDirectory'"
            , "Illegal term-level use of the type constructor 'DetachedOutputSink'"
            , "Variable not in scope: detachedProcess :: DetachedLaunch -> CreateProcess"
            ]
        , rejectsWith
            "RelabelDetachedLaunch.hs"
            ["Not in scope: record field 'dlArguments'"]
        ]

rejects :: FilePath -> TestTree
rejects fixture = rejectsWith fixture []

rejectsWith :: FilePath -> [String] -> TestTree
rejectsWith fixture expectedDiagnostics =
    testCase fixture $ do
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        let coreRoot = root </> "core"
            fixturePath = "hostbootstrap-core" </> "test" </> "compile-fail" </> fixture
        (code, _, err) <-
            withCurrentDirectory coreRoot $
                readProcessWithExitCode
                    "cabal"
                    ["exec", "--", "ghc", "-fno-code", "-package", "hostbootstrap-core", fixturePath]
                    ""
        case code of
            ExitFailure _ -> do
                assertBool
                    ("compile-fail fixture produced no diagnostic: " ++ fixture)
                    (not (null err))
                mapM_
                    ( \expected ->
                        assertBool
                            ( "compile-fail fixture produced the wrong diagnostic: "
                                ++ fixture
                                ++ "; expected to find "
                                ++ show expected
                                ++ " in:\n"
                                ++ err
                            )
                            (normalizeDiagnostic expected `isInfixOf` normalizeDiagnostic err)
                    )
                    expectedDiagnostics
            _ -> assertFailure ("compile-fail fixture unexpectedly compiled: " ++ fixture)

{- | Normalise a diagnostic to the axes an expectation is allowed to depend on:
its words, in order, and the identifiers it quotes.

Two renderings vary without the rejection changing. GHC breaks a diagnostic
across continuation lines when the rendered type is wide, so the same rejection
reads @"Variable not in scope: f"@ for a short signature and
@"Variable not in scope:\\n    f\\n      :: ..."@ for a long one; and it quotes
an identifier with typographic quotes when the handle encoding admits them and
ASCII quotes when it does not, so the same rejection names @DetachedLaunch@
differently under a UTF-8 and a C locale.

Neither axis says whether the fixture was rejected for the intended reason, so
both are normalised away. That is what lets an expectation stay **one
contiguous phrase** including the identifier it names — the shape
@documents/architecture/unrepresentable_state.md@ requires, because a phrase
split into separately-matched tokens can be satisfied by an unrelated in-scope
error on the same line. Normalisation cannot admit an unrelated compiler
failure: the fixture must still fail to compile, and the whole phrase must
still appear.
-}
normalizeDiagnostic :: String -> String
normalizeDiagnostic = unwords . words . map normalizeQuote
  where
    normalizeQuote c
        | c `elem` typographicQuotes = '\''
        | otherwise = c
    -- U+2018/U+2019 single and U+201C/U+201D double typographic quotes, plus
    -- the backtick GHC's ASCII rendering pairs with a closing apostrophe.
    typographicQuotes :: String
    typographicQuotes = ['\8216', '\8217', '\8220', '\8221', '`']
