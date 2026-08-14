module ImportHandoffProcessRoute where

-- The protocol-safe process route is Cabal-private, so no consumer can name
-- the type, derive one from a package it assembled, read the argument vector
-- it renders, or raise a frame's own opening.
import HostBootstrap.Handoff.Process.Route
    ( LifecycleProcessRoute
    , withForwardLifecycleProcessRouteKernel
    , withLifecycleChildOpeningKernel
    , withLifecycleProcessRouteLaunchKernel
    , withRecoveryLifecycleProcessRouteKernel
    )
