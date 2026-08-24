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
    restartingHarnessLifecycle,
    testingHarnessLifecycle,
    testingRestartingHarnessLifecycle,
    runHarnessForward,
    runHarnessRestart,
    runHarnessReverse,
)
where

{- | The common forward and reverse interpreters retained from one exact
Harness-scoped project plan.

There is deliberately no selector, raw plan, or caller-supplied frame in this
value.  Its creator has already fixed the plan, current frame, snapshot, lease,
journal, cursor, and authority for one generated-config bracket.
-}
data HarnessLifecycle = HarnessLifecycle (IO ()) (Maybe (IO ())) (IO ())

harnessLifecycle :: IO () -> IO () -> HarnessLifecycle
harnessLifecycle forwardAction reverseAction =
    HarnessLifecycle forwardAction Nothing reverseAction

{- | Command-private constructor for a Harness lifecycle that can move from a
settled intermediate destroy into a fresh same-run invocation.
-}
restartingHarnessLifecycle :: IO () -> IO () -> IO () -> HarnessLifecycle
restartingHarnessLifecycle forwardAction restartAction reverseAction =
    HarnessLifecycle forwardAction (Just restartAction) reverseAction

-- | Private-component alias used only by the core test suite.
testingHarnessLifecycle :: IO () -> IO () -> HarnessLifecycle
testingHarnessLifecycle = harnessLifecycle

-- | Private-component alias used only by engine tests of the restart route.
testingRestartingHarnessLifecycle :: IO () -> IO () -> IO () -> HarnessLifecycle
testingRestartingHarnessLifecycle = restartingHarnessLifecycle

runHarnessForward :: HarnessLifecycle -> IO ()
runHarnessForward (HarnessLifecycle forwardAction _ _) = forwardAction

runHarnessRestart :: HarnessLifecycle -> IO ()
runHarnessRestart (HarnessLifecycle _ restartAction _) =
    maybe
        (ioError (userError "this Harness lifecycle has no fresh same-run invocation"))
        id
        restartAction

runHarnessReverse :: HarnessLifecycle -> IO ()
runHarnessReverse (HarnessLifecycle _ _ reverseAction) = reverseAction
