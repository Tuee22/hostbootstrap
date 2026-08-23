{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

-- | The bare binary's owned live-gate configuration, plan, and assertions.
module HostBootstrap.CLI.Bare
    ( BareConfig
    , BareTestConfig
    , bareTestCodec
    , bareTestInit
    , bareAssemble
    , bareInit
    , bareStepPlan
    , bareClusterLiveSuite
    )
where

import Control.Monad (foldM)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall)
import qualified Dhall
import GHC.Generics (Generic)
import HostBootstrap.Cluster.Lifecycle
    ( ClusterPlan (clusterName, dataPath)
    , ClusterProfile (TestCase)
    , clusterCreate
    , clusterDelete
    , resolvePlan
    )
import HostBootstrap.Config.Class
    ( AssemblyRequest (..)
    , ConfigAssembly
    , InitArgs (..)
    , ProjectCfg (..)
    , TestCfg (..)
    , failConfigAssembly
    , pureConfigAssembly
    , withProjectCodec
    )
import HostBootstrap.Config.Schema (siblingProjectConfigPath)
import HostBootstrap.Config.Vocab (harnessRunName)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (CodecWitness, autoCodecWitness, requireCodecWitness)
import HostBootstrap.Ensure (runTool)
import HostBootstrap.Harness
    ( Case (..)
    , CaseId
    , CaseResult (..)
    , TestMatrixError (..)
    , TestSuite (..)
    , VariantId
    , mkCaseId
    , mkTestMatrix
    , mkVariantId
    , variantDraft
    , variantDraftId
    )
import HostBootstrap.HostConfig (HostConfig, buildHostConfig)
import HostBootstrap.HostTool (HostTool (Docker, Kind, Kubectl))
import HostBootstrap.Lifecycle.Execution (stepExecutionHostConfig)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.Step
    ( Step
    , StepAction
    , StepFrame (..)
    , StepObservation (..)
    , StepPlan
    , StepPlanError (..)
    , TeardownOutcome (..)
    , deployKindStep
    , mkStepPlan
    , reversedBy
    )
import HostBootstrap.Substrate (detect)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>))

data BareConfig scope = BareConfig
    { bareContext :: Context.BinaryContext
    , bareHarnessRun :: Maybe Text
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

newtype BareTestConfig = BareTestConfig {runClusterLive :: Bool}
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

instance TestCfg BareTestConfig where
    type TestVariant BareTestConfig = ()
    projectTestMatrix caseIds config
        | runClusterLive config =
            mkTestMatrix caseIds [draft] [(cid, [variantDraftId draft]) | cid <- caseIds]
        | otherwise = Left EmptyVariantRegistry
      where
        draft = variantDraft bareVariantId ()

instance ProjectCfg BareConfig where
    withProductionProjectCodec =
        withProjectCodec
            (T.pack "BareConfig/Production")
            (requireCodecWitness "BareConfig" autoCodecWitness)
    withHarnessProjectCodec _ =
        withProjectCodec
            (T.pack "BareConfig/Harness")
            (requireCodecWitness "BareConfig" autoCodecWitness)
    cfgContext = bareContext

bareTestCodec :: CodecWitness BareTestConfig
bareTestCodec = requireCodecWitness "bare test config" autoCodecWitness

bareTestInit :: InitArgs -> BareTestConfig
bareTestInit _ = BareTestConfig True

bareAssemble ::
    forall projectId scope.
    String ->
    FilePath ->
    AssemblyRequest projectId BareTestConfig () scope ->
    ConfigAssembly scope (BareConfig scope)
bareAssemble progName root request = case request of
    ProductionAssembly args ->
        either failConfigAssembly pureConfigAssembly (bareInit progName root args)
    HarnessAssembly authority _ _ _ ->
        either
            failConfigAssembly
            (pureConfigAssembly . (\cfg -> cfg{bareHarnessRun = Just (harnessRunName authority)}))
            (bareInit progName root (defaultBareArgs root))

bareInit :: String -> FilePath -> InitArgs -> Either String (BareConfig scope)
bareInit progName root args =
    let baseContext =
            Context.contextForKind
                (T.pack progName)
                (T.pack progName)
                (T.pack (fromMaybe root (sourceRoot args)))
                (role args)
     in case foldM (flip Context.addRole) baseContext (alsoRoles args) of
            Left err -> Left (Context.contextErrorMessage err)
            Right context -> Right (BareConfig context Nothing)

defaultBareArgs :: FilePath -> InitArgs
defaultBareArgs root =
    InitArgs
        { role = Context.HostOrchestrator
        , alsoRoles = []
        , output = Nothing
        , sourceRoot = Just root
        , mCpu = Nothing
        , memory = Nothing
        , storage = Nothing
        , dockerfile = Nothing
        , haReplicas = Nothing
        , force = False
        , ifMissing = False
        }

bareCaseId :: CaseId
bareCaseId = either (error . show) id (mkCaseId (T.pack "cluster-live"))

bareVariantId :: VariantId
bareVariantId = either (error . show) id (mkVariantId (T.pack "linux-cpu"))

bareStepPlan ::
    String ->
    CanonicalProjectRoot scope rootId ->
    BareConfig scope ->
    Either StepPlanError StepPlan
bareStepPlan progName _ cfg = case bareHarnessRun cfg of
    Nothing -> Left EmptyStepPlan
    Just runName -> mkStepPlan [bareClusterStep progName cfg runName]

bareClusterStep :: String -> BareConfig scope -> Text -> Step
bareClusterStep progName cfg runName =
    reversedBy
        (\host _ -> clusterDelete host plan >> pure TeardownReleased)
        ( deployKindStep
            "create the harness-owned live Kind cluster"
            (StepFrame (T.unpack (Context.currentFrame (bareContext cfg))) "metal")
            (bareClusterAction plan runName)
        )
  where
    root = T.unpack (Context.sourceRoot (bareContext cfg))
    plan = resolvePlan progName root (TestCase (T.unpack runName))

bareClusterAction :: ClusterPlan -> Text -> StepAction
bareClusterAction plan runName execution = do
    let host = stepExecutionHostConfig execution
    listing <- runTool host Kind ["get", "clusters"]
    case listing of
        Right (ExitSuccess, out, _)
            | clusterName plan `elem` lines out ->
                pure (StepRefused (T.pack ("cluster-live: run-scoped cluster already exists: " ++ clusterName plan)))
        Right (ExitSuccess, _, _) -> do
            createDirectoryIfMissing True (dataPath plan)
            writeFile (bareSentinelPath plan) (bareSentinelBytes runName)
            clusterCreate host plan (Context.ResourceEnvelope 2 (T.pack "2GiB") (T.pack "8GiB"))
            pure StepChanged
        Right (ExitFailure code, _, err) ->
            pure (StepRefused (T.pack ("cluster-live: kind listing failed (exit " ++ show code ++ "): " ++ err)))
        Left err -> pure (StepRefused (T.pack ("cluster-live: kind listing failed: " ++ err)))

bareClusterLiveSuite :: String -> TestSuite
bareClusterLiveSuite progName =
    TestSuite
        (pure (Right ()))
        (const (readBarePlan progName))
        [Case bareCaseId 1 True]
        assertLive
        assertReversed
  where
    assertLive _ _ = do
        host <- resolveBareHostConfig
        version <- runTool host Kubectl ["version", "-o", "json"]
        case version of
            Right (ExitSuccess, out, _) -> putStrLn ("cluster-live: kubectl version " ++ out)
            Right (ExitFailure code, _, err) -> die ("cluster-live: kubectl version observation failed (exit " ++ show code ++ "): " ++ err)
            Left err -> die ("cluster-live: kubectl version observation failed: " ++ err)
        observed <- runTool host Kubectl ["get", "nodes", "-o", "name"]
        pure $ case observed of
            Right (ExitSuccess, out, _)
                | not (null (lines out)) -> Pass
                | otherwise -> Fail "cluster-live: kubectl returned no nodes"
            Right (ExitFailure code, _, err) -> Fail ("cluster-live: kubectl node observation failed (exit " ++ show code ++ "): " ++ err)
            Left err -> Fail ("cluster-live: kubectl node observation failed: " ++ err)
    assertReversed = do
        plan <- readBarePlan progName
        host <- resolveBareHostConfig
        remaining <-
            runTool host Docker
                [ "ps", "-a", "--filter"
                , "label=io.x-k8s.kind.cluster=" ++ clusterName plan
                , "--format", "{{.ID}}"
                ]
        case remaining of
            Right (ExitSuccess, out, _) | null (lines out) -> pure ()
            Right (ExitSuccess, _, _) -> die "cluster-live: labelled node container remains after reverse"
            Right (ExitFailure code, _, err) -> die ("cluster-live: Docker absence observation failed (exit " ++ show code ++ "): " ++ err)
            Left err -> die ("cluster-live: Docker absence observation failed: " ++ err)
        sentinel <- readFile (bareSentinelPath plan)
        cfg <- readBareConfig progName
        case bareHarnessRun cfg of
            Just runName | sentinel == bareSentinelBytes runName -> pure ()
            _ -> die "cluster-live: durable-root sentinel changed across cluster deletion"

readBareConfig :: String -> IO (BareConfig ())
readBareConfig progName = do
    path <- siblingProjectConfigPath (T.pack progName)
    Dhall.inputFile Dhall.auto path

readBarePlan :: String -> IO ClusterPlan
readBarePlan progName = do
    cfg <- readBareConfig progName
    case bareHarnessRun cfg of
        Nothing -> die "cluster-live: generated Harness config has no run identity"
        Just runName ->
            pure (resolvePlan progName (T.unpack (Context.sourceRoot (bareContext cfg))) (TestCase (T.unpack runName)))

bareSentinelPath :: ClusterPlan -> FilePath
bareSentinelPath plan = dataPath plan </> "cluster-live.sentinel"

bareSentinelBytes :: Text -> String
bareSentinelBytes runName = "hostbootstrap-cluster-live:" ++ T.unpack runName ++ "\n"

resolveBareHostConfig :: IO HostConfig
resolveBareHostConfig = detect >>= either die buildHostConfig
