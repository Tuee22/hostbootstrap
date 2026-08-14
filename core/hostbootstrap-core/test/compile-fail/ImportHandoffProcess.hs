module ImportHandoffProcess where

-- The lifecycle child-process owner is Cabal-private, so no consumer can
-- launch a child, hold its group, or reach the bracket that terminates and
-- reaps it.
import HostBootstrap.Handoff.Process
    ( withForwardLifecycleChildProcess
    , withReverseLifecycleChildProcess
    )
