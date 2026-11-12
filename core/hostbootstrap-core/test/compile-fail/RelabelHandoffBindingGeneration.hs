module RelabelHandoffBindingGeneration where

import HostBootstrap.Handoff

-- DEVELOPMENT_PLAN/rationale.md#handoff-bindings-retain-their-admitted-fields
retained ::
    HostBootstrap.Handoff.HandoffBinding scope generation ->
    HostBootstrap.Handoff.HandoffBinding scope otherGeneration
retained binding = binding{handoffPhase = HostBootstrap.Handoff.handoffPhase binding}
