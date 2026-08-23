{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}

module RecoverySpec (tests) where

import HostBootstrap.Lifecycle.Mode
    ( RecoveredProjectFrame
    , foldRecoveredFrameResources
    , productionRootAuthority
    , recoveredFrameAdapter
    , recoveredFrameName
    , recoveredFrameParent
    , withRecoveredProjectFrames
    , withRecoveredChildProjectionBinding
    , driveRecoveredForest
    , recoveredForestFrameOrder
    , recoveredForestOwnedCount
    , recoveredForestReleasedCount
    , recordRecoveredResourceReleased
    , planSnapshotPlanDigest
    )
import ResourceRecordSpec (withRecoveryFixture, withRecoveryFixtureFor, withReleasedRecoveryFixture, withReleasedRecoveryFixtureFor, withRecoveryRootFixtureFor, wrongRecoveryMembership)
import qualified Data.ByteString as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified Data.Text
import HostBootstrap.Handoff
    ( projectSigningKeyFromBytes
    , productionHandoffScope
    , renderRecoveryProjectionBinding
    , withRootBroker
    )
import HostBootstrap.Step
    ( StepFrame (StepFrame)
    , StepObservation (StepChanged)
    , StepPlan
    , deployKindStep
    , deployVMStep
    , descendsVia
    , mkStepPlan
    , mkStepReverseAdapterRevision
    , reverseAdapterAt
    )
import HostBootstrap.Lift (localContext)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import System.Directory (removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

tests :: TestTree
tests =
    testGroup
        "RecoverySpec"
        [ testCase "the canonical snapshot and complete set recover the root frame" $
            withRecoveryFixture $ \snapshot resources ->
                case withRecoveredProjectFrames snapshot resources collect [] of
                    Left failure -> assertFailure (show failure)
                    Right frames -> frames @?= [("host", Nothing, ("core-managed", 1), 1, 0)]
        , testCase "nested frames and their exact resources are recovered without config" $
            withRecoveryFixtureFor nestedPlan $ \snapshot resources ->
                case withRecoveredProjectFrames snapshot resources collect [] of
                    Left failure -> assertFailure (show failure)
                    Right frames -> reverse frames @?=
                        [ ("host", Nothing, ("project-managed", 1), 1, 0)
                        , ("vm", Just "host", ("core-managed", 1), 1, 0)
                        ]
        , testCase "recovery is independent of config presence and contents" $
            withRecoveryFixture $ \snapshot resources ->
                withSystemTempDirectory "hostbootstrap-recovery-config" $ \directory -> do
                    let config = directory </> "project.dhall"
                        recover = case withRecoveredProjectFrames snapshot resources collect [] of
                            Left failure -> assertFailure (show failure)
                            Right frames -> frames @?= [("host", Nothing, ("core-managed", 1), 1, 0)]
                    writeFile config "{ project = 1 }"
                    recover
                    writeFile config "this is deliberately no longer valid config"
                    recover
                    removeFile config
                    recover
        , testCase "a resource set with wrong membership refuses" $
            wrongRecoveryMembership >>= \result -> case result of
                Left _ -> pure ()
                Right _ -> assertFailure "foreign recovery membership was admitted"
        , testCase "released resources expose only tombstones" $
            withReleasedRecoveryFixture $ \snapshot resources ->
                case withRecoveredProjectFrames snapshot resources collect [] of
                    Left failure -> assertFailure (show failure)
                    Right frames -> frames @?= [("host", Nothing, ("core-managed", 1), 0, 1)]
        , testCase "an adapter revision outside the closed table refuses" $
            withRecoveryFixtureFor unknownAdapterPlan $ \snapshot resources ->
                case withRecoveredProjectFrames snapshot resources collect [] of
                    Left _ -> pure ()
                    Right _ -> assertFailure "an unknown recovery adapter was admitted"
        , testCase "the root derives the exact nested recovery projection and set-bound adapter wire" $
            withRecoveryRootFixtureFor nestedPlan $ \store project root snapshot resources -> do
                signing <- either (assertFailure . show) pure (projectSigningKeyFromBytes (ByteString.replicate 32 73))
                brokered <- withRootBroker (productionHandoffScope project) store signing (productionRootAuthority root) $ \broker ->
                    case withRecoveredProjectFrames snapshot resources (\frame frames -> SomeRecoveredFrame frame : frames) [] of
                        Left failure -> assertFailure (show failure)
                        Right [SomeRecoveredFrame child, SomeRecoveredFrame parent] -> do
                            case withRecoveredChildProjectionBinding broker parent child (\wire binding -> (wire, renderRecoveryProjectionBinding binding)) of
                                Left failure -> assertFailure (show failure)
                                Right (wire, bindingBytes) -> do
                                    ByteString.null wire @?= False
                                    ByteString.null bindingBytes @?= False
                            case withRecoveredChildProjectionBinding broker child parent (\_ _ -> ()) of
                                Left _ -> pure ()
                                Right _ -> assertFailure "the reversed recovered edge was admitted"
                        Right _ -> assertFailure "the nested recovery fixture did not yield exactly two frames"
                either (assertFailure . show) pure brokered
        , testCase "the recovered forest drives owned resources child-first" $
            withRecoveryFixtureFor nestedPlan $ \snapshot resources -> do
                observed <- newIORef []
                outcome <- driveRecoveredForest snapshot resources $ \frame _adapter _revision _handle _receipt -> do
                    modifyIORef' observed (<> [frame])
                    pure (Right ())
                case outcome of
                    Left failure -> assertFailure (show failure)
                    Right settled -> do
                        recoveredForestFrameOrder settled @?= ["vm", "host"]
                        recoveredForestOwnedCount settled @?= 2
                        recoveredForestReleasedCount settled @?= 0
                readIORef observed >>= (@?= ["vm", "host"])
        , testCase "released recovered resources settle without a backend call" $
            withReleasedRecoveryFixtureFor nestedPlan $ \snapshot resources -> do
                calls <- newIORef (0 :: Int)
                outcome <- driveRecoveredForest snapshot resources $ \_ _ _ _ _ -> do
                    modifyIORef' calls (+ 1)
                    pure (Right ())
                case outcome of
                    Left failure -> assertFailure (show failure)
                    Right settled -> do
                        recoveredForestOwnedCount settled @?= 0
                        recoveredForestReleasedCount settled @?= 2
                readIORef calls >>= (@?= 0)
        , testCase "a recovered backend refusal stops before its parent" $
            withRecoveryFixtureFor nestedPlan $ \snapshot resources -> do
                observed <- newIORef []
                outcome <- driveRecoveredForest snapshot resources $ \frame _ _ _ _ -> do
                    modifyIORef' observed (<> [frame])
                    pure (Left "seeded child refusal")
                case outcome of
                    Left _ -> pure ()
                    Right _ -> assertFailure "a failed recovered child settled the forest"
                readIORef observed >>= (@?= ["vm"])
        , testCase "successful recovered release records converge before parent settlement" $
            withRecoveryRootFixtureFor nestedPlan $ \store _project _root snapshot resources -> do
                outcome <- driveRecoveredForest snapshot resources $ \_ _ _ handle receipt -> do
                    first <- recordRecoveredResourceReleased store (planSnapshotPlanDigest snapshot) handle receipt
                    second <- recordRecoveredResourceReleased store (planSnapshotPlanDigest snapshot) handle receipt
                    pure $ case (first, second) of
                        (Right (), Right ()) -> Right ()
                        (Left failure, _) -> Left (showText failure)
                        (_, Left failure) -> Left (showText failure)
                case outcome of
                    Left failure -> assertFailure (show failure)
                    Right settled -> recoveredForestOwnedCount settled @?= 2
        ]
  where
    collect frame frames =
        let (owned, released) =
                foldRecoveredFrameResources frame (0 :: Int, 0 :: Int)
                    (\(o, r) _ _ -> (o + 1, r))
                    (\(o, r) _ -> (o, r + 1))
         in (recoveredFrameName frame, recoveredFrameParent frame, recoveredFrameAdapter frame, owned, released) : frames

data SomeRecoveredFrame scope planId brokerGeneration where
    SomeRecoveredFrame :: RecoveredProjectFrame scope planId brokerGeneration frame -> SomeRecoveredFrame scope planId brokerGeneration

showText :: Show value => value -> Data.Text.Text
showText = Data.Text.pack . show

nestedPlan :: StepPlan
nestedPlan = either (error . show) id $
    mkStepPlan
        [ descendsVia localContext (deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged)))
        , deployKindStep "cluster" (StepFrame "vm" "VM") (const (pure StepChanged))
        ]

unknownAdapterPlan :: StepPlan
unknownAdapterPlan = either (error . show) id $
    mkStepPlan
        [ reverseAdapterAt
            (either error id (mkStepReverseAdapterRevision 2))
            (deployKindStep "cluster" (StepFrame "host" "Host") (const (pure StepChanged)))
        ]
