{-# LANGUAGE OverloadedStrings #-}

module UpdateHandoffBindingField where

import HostBootstrap.Handoff

-- DEVELOPMENT_PLAN/rationale.md#handoff-bindings-retain-their-admitted-fields
retained ::
    HostBootstrap.Handoff.HandoffBinding scope generation ->
    HostBootstrap.Handoff.HandoffBinding scope generation
retained binding = binding{handoffChildFrame = "elsewhere"}
