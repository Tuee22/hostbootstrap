module CrossFrameTeardownPipeline where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan

data OpenFrameA
data OpenFrameB

-- The forest retains the exact frame carried by the projection that opened it.
openAcrossFrames ::
    TeardownPlan Scope Plan OpenFrameA VerbDestroy ->
    Either TeardownError (TeardownForest Scope Plan OpenFrameB VerbDestroy)
openAcrossFrames = openTeardownForest

data SuccessorFrameA
data SuccessorFrameB

-- The next-work progress cannot be relabelled away from its opening frame.
progressAcrossFrames ::
    TeardownForest Scope Plan SuccessorFrameA VerbDestroy ->
    TeardownProgress Scope Plan SuccessorFrameB VerbDestroy
progressAcrossFrames = nextTeardownWork

data WorkFrameA
data WorkFrameB

consumeWorkB :: TeardownWork Scope Plan WorkFrameB VerbDestroy -> ()
consumeWorkB _ = ()

-- An ordinary-work sum opened under one frame cannot enter another's consumer.
consumeWorkAcrossFrames ::
    TeardownWork Scope Plan WorkFrameA VerbDestroy ->
    ()
consumeWorkAcrossFrames = consumeWorkB

data SettlementFrameA
data SettlementFrameB

-- Completion from another frame cannot settle this projection.
settleAcrossFrames ::
    TeardownPlan Scope Plan SettlementFrameA VerbDestroy ->
    CompletedTeardownForest Scope Plan SettlementFrameB VerbDestroy ->
    Either TeardownError (SubtreeSettled Scope Plan SettlementFrameA VerbDestroy)
settleAcrossFrames projection completed = verifySubtreeSettled projection completed
