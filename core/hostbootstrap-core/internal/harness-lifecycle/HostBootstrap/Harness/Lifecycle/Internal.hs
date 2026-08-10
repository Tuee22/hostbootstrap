{- | Private-component construction boundary for Harness lifecycle actions.

The public "HostBootstrap.Harness" facade exposes the type and its two
eliminators, but no constructor.  Only the core command boundary can close over
one exact Harness-scoped project plan and package its common forward and reverse
interpreters.  The package's private test component imports the same constructor
for engine unit tests; downstream packages cannot depend on this component.
-}
module HostBootstrap.Harness.Lifecycle.Internal (
    HarnessLifecycle,
    harnessLifecycle,
    testingHarnessLifecycle,
    runHarnessForward,
    runHarnessReverse,
)
where

{- | The common forward and reverse interpreters retained from one exact
Harness-scoped project plan.

There is deliberately no selector, raw plan, or caller-supplied frame in this
value.  Its creator has already fixed the plan, current frame, snapshot, lease,
journal, cursor, and authority for one generated-config bracket.
-}
data HarnessLifecycle = HarnessLifecycle (IO ()) (IO ())

harnessLifecycle :: IO () -> IO () -> HarnessLifecycle
harnessLifecycle = HarnessLifecycle

-- | Private-component alias used only by the core test suite.
testingHarnessLifecycle :: IO () -> IO () -> HarnessLifecycle
testingHarnessLifecycle = HarnessLifecycle

runHarnessForward :: HarnessLifecycle -> IO ()
runHarnessForward (HarnessLifecycle forwardAction _) = forwardAction

runHarnessReverse :: HarnessLifecycle -> IO ()
runHarnessReverse (HarnessLifecycle _ reverseAction) = reverseAction
