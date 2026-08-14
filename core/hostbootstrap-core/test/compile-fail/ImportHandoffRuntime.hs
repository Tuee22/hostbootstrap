module ImportHandoffRuntime where

import HostBootstrap.Handoff.Runtime
    ( RecursiveHandoffRuntime
    , nestedRecursiveHandoffRuntimeKernel
    , rootRecursiveHandoffRuntimeKernel
    , withRecursiveHandoffRuntimeKernel
    )

hidden :: RecursiveHandoffRuntime scope broker verb -> ()
hidden _ = ()
