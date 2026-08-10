module EscapeVerifiedConfigHandoffIndices where

import HostBootstrap.Authority (ProjectVerb)
import HostBootstrap.Config.Schema
    ( ValidatedConfig
    , VerifiedConfigHandoff
    , VerifiedConfigWire
    , withVerifiedConfigHandoff
    )
import HostBootstrap.Handoff (HandoffError, VerifiedHandoff)

data ChosenHandoffPlan
data ChosenHandoffParent
data ChosenHandoffChild
data ChosenHandoffPhase

selectPlan ::
    VerifiedConfigHandoff
        scope ChosenHandoffPlan brokerGeneration parentFrame childFrame
        configId verb phase ->
    ()
selectPlan _ = ()

selectParent ::
    VerifiedConfigHandoff
        scope planDigest brokerGeneration ChosenHandoffParent childFrame
        configId verb phase ->
    ()
selectParent _ = ()

selectChild ::
    VerifiedConfigHandoff
        scope planDigest brokerGeneration parentFrame ChosenHandoffChild
        configId verb phase ->
    ()
selectChild _ = ()

selectPhase ::
    VerifiedConfigHandoff
        scope planDigest brokerGeneration parentFrame childFrame
        configId verb ChosenHandoffPhase ->
    ()
selectPhase _ = ()

escapePlan ::
    ProjectVerb verb ->
    VerifiedHandoff scope brokerGeneration ->
    VerifiedConfigWire scope configDigest configId ->
    ValidatedConfig scope specDigest configId config ->
    Either HandoffError ()
escapePlan verb handoff wire config =
    withVerifiedConfigHandoff verb handoff wire config selectPlan

escapeParent ::
    ProjectVerb verb ->
    VerifiedHandoff scope brokerGeneration ->
    VerifiedConfigWire scope configDigest configId ->
    ValidatedConfig scope specDigest configId config ->
    Either HandoffError ()
escapeParent verb handoff wire config =
    withVerifiedConfigHandoff verb handoff wire config selectParent

escapeChild ::
    ProjectVerb verb ->
    VerifiedHandoff scope brokerGeneration ->
    VerifiedConfigWire scope configDigest configId ->
    ValidatedConfig scope specDigest configId config ->
    Either HandoffError ()
escapeChild verb handoff wire config =
    withVerifiedConfigHandoff verb handoff wire config selectChild

escapePhase ::
    ProjectVerb verb ->
    VerifiedHandoff scope brokerGeneration ->
    VerifiedConfigWire scope configDigest configId ->
    ValidatedConfig scope specDigest configId config ->
    Either HandoffError ()
escapePhase verb handoff wire config =
    withVerifiedConfigHandoff verb handoff wire config selectPhase
