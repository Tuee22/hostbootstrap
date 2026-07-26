module RawStep where

import HostBootstrap.Step

rawStep :: Step
rawStep =
    Step
        "label"
        (StepFrame "host-orchestrator-0" "host")
        (ProjectKind (error "hidden"))
        ProjectManagedReverse
        (const (pure ()))
