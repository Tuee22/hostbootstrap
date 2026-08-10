{-# LANGUAGE OverloadedStrings #-}

module EscapeRecoveryProjectionInput where

import HostBootstrap.Handoff

data CallerChosenRecoveryPlan
data CallerChosenRecoveryParent
data CallerChosenRecoveryChild

selectPlan :: RecoveryProjectionBindingInput CallerChosenRecoveryPlan parent child -> ()
selectPlan _ = ()

selectParent :: RecoveryProjectionBindingInput plan CallerChosenRecoveryParent child -> ()
selectParent _ = ()

selectChild :: RecoveryProjectionBindingInput plan parent CallerChosenRecoveryChild -> ()
selectChild _ = ()

escapePlan :: Either HandoffError ()
escapePlan =
    withRecoveryProjectionBindingInput "plan" "parent" "child" selectPlan

escapeParent :: Either HandoffError ()
escapeParent =
    withRecoveryProjectionBindingInput "plan" "parent" "child" selectParent

escapeChild :: Either HandoffError ()
escapeChild =
    withRecoveryProjectionBindingInput "plan" "parent" "child" selectChild
