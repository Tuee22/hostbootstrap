module CompileFailSpec (tests) where

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
        , rejects "HarnessLeaseAsProduction.hs"
        , rejects "ForgeRunLease.hs"
        , rejects "ForgeProtectedSession.hs"
        , rejects "ForgeVerifiedHandoff.hs"
        , rejects "ForgeSessionPermit.hs"
        , rejects "ForgeBuildAuthority.hs"
        , rejects "ForgeRuntimeActivation.hs"
        , rejects "ForgeRoleCursor.hs"
        , rejects "ForgeTeardownForest.hs"
        , rejects "ForgePreconditionSet.hs"
        , rejects "ForgePreparedGate.hs"
        ]

rejects :: FilePath -> TestTree
rejects fixture =
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
            ExitFailure _ ->
                assertBool
                    ("compile-fail fixture produced no diagnostic: " ++ fixture)
                    (not (null err))
            _ -> assertFailure ("compile-fail fixture unexpectedly compiled: " ++ fixture)
