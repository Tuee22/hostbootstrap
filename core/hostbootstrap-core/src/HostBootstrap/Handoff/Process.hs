{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Who owns a child process for exactly as long as its edge lasts.

Spawning is the easy half. The hard half is that a child is a resource with
three ways of outliving the thing that wanted it: it can keep running after the
exchange fails, it can leave descendants behind after it exits, and it can hold
descriptors open after nobody is reading them. A lifecycle that treats
@createProcess@ as the end of its responsibility acquires all three.

So the child lives inside one bracket and nothing else may hold it. The bracket
spawns exactly one sanitized 'LifecycleProcessRoute' — never an argv, image, or
executable a caller chose — into a new process group with its standard input
and output on private pipes and its standard error inherited, so diagnostics
reach the operator while the protocol keeps the pipes to itself. It hands those
pipes to the relay for the exchange's lifetime, runs one fixed completion
operation, waits for the child, and closes every descriptor it opened. On the
way out — normal return, refusal, protocol failure, exception, or asynchronous
cancellation alike — it signals the whole group, waits a fixed grace, escalates
to an unignorable kill if the group is still there, and reaps unconditionally.
Signalling the group rather than the process is what makes a shell or provider
the child launched go away with it.

What the bracket deliberately does not own is a deadline over the work itself.
Its constants bound the launch and the termination grace; the relay bounds the
frames a peer owes immediately. Between admission and the completed report sits
whatever the admitted backend effect takes, and that effect has its own closed
policy — one wall-clock deadline across it would turn every slow provisioning
step into a protocol failure. A child that is working is not a child that has
stopped talking, and this module does not confuse the two.

Nor does exiting mean succeeding. EOF on the pipe, a zero exit status,
reassuring text on standard error, and a closed channel are all things a child
that never completed its edge can produce. The only evidence that an edge
finished is the rooted completion the relay obtained and the root recorded, so
that is the only thing this bracket reports as success.

Every obligation above is a POSIX primitive: the child is launched into a new
process group, the group is signalled rather than the process, and the
escalation is a signal the child cannot ignore. A host without those primitives
cannot hold the contract, so this is a platform row. It is compiled on every
gate host and refuses totally where it cannot apply, rather than being dropped
from the package there (§ JJ): a caller sees the same two entry points
everywhere, an absent row is a refusal it can read rather than a module that is
not there, and the case that covers it asserts that refusal instead of
disappearing.
-}
module HostBootstrap.Handoff.Process (
    withForwardLifecycleChildProcess,
    withProviderDependencyForwardLifecycleChildProcess,
    withCarriedProviderDependencyForwardLifecycleChildProcess,
    seedProviderDependencyCarrierKernel,
    withCarriedProviderDependencyFromCarrierKernel,
    withPreparedReverseLifecycleChildProcess,
    withReverseLifecycleChildProcess,
)
where

import Data.ByteString (ByteString)
import Data.Proxy (Proxy (Proxy))
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Handoff (HandoffBindingInput, providerDependencyPackageFields, providerDependencyProbeRequestFromFields, withProviderDependencyReprobeKernel)
import HostBootstrap.Handoff.Process.Route (
    LifecycleProcessRoute,
    withRecoveryLifecycleProcessRouteForKernel,
 )
import HostBootstrap.Handoff.Relay (BrokerLink, withProviderDependencyReprobeEndpointKernel)
import HostBootstrap.HostConfig (HostConfig)
import qualified HostBootstrap.Lifecycle.Dependency.Internal as Dependency
import HostBootstrap.Lifecycle.Execution.Internal (
    ResourceCarrier,
    invokeStepRuntimeDependencyService,
    mintTransferredCarriedResource,
    newStepRuntime,
    pushCarriedResource,
    registerStepRuntimeDependencyPackage,
    replaceStepRuntimeDependencyService,
    stepRuntimeDependencyPackages,
 )
import HostBootstrap.Teardown.Internal (
    ReverseDescent,
    withReverseDescentProcessInputsKernel,
 )
#if !defined(mingw32_HOST_OS)
import Control.Concurrent (threadDelay)
import qualified Control.Exception as Exception
import qualified Data.Text as Text
import HostBootstrap.Handoff.Completion
    ( withAcknowledgedBoundReverseLifecycleCompletionKernel
    , withAcknowledgedForwardLifecycleCompletionKernel
    )
import HostBootstrap.Handoff.Process.Route (withLifecycleProcessRouteLaunchKernel)
import HostBootstrap.Handoff.Protocol (HandoffChannel, handoffChannel)
import HostBootstrap.Handoff.Relay
    ( RelayError
    , offerHandoffEdge
    , offerReverseDescentKernel
    , relayErrorMessage
    )
import HostBootstrap.HostConfig (resolveMaybe)
import HostBootstrap.HostTool (absExePath)
import System.Exit (ExitCode)
import System.IO (Handle, hClose)
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcessGroup)
import System.Process
    ( CreateProcess (close_fds, create_group, std_err, std_in, std_out)
    , ProcessHandle
    , StdStream (CreatePipe, Inherit)
    , getPid
    , getProcessExitCode
    , proc
    , waitForProcess
    , withCreateProcess
    )
import System.Timeout (timeout)
#endif

{- | Launch one forward child and complete its edge, or leave nothing running.

The offered payload and binding input are the catalog's own, and the completion
operation is fixed rather than supplied: a forward edge is acknowledged through
the forward completion kernel and no other. The continuation a caller might
otherwise have passed does not exist, so there is no way to run arbitrary work
inside a live child's exchange.
-}
withForwardLifecycleChildProcess ::
    HostConfig ->
    BrokerLink scope brokerGeneration ->
    LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb ->
    Word64 ->
    HandoffBindingInput ->
    ByteString ->
    IO (Either Text ())
#if defined(mingw32_HOST_OS)
withForwardLifecycleChildProcess _config _link _route _request _input _payload =
    pure (Left unsupportedOnThisHost)
#else
withForwardLifecycleChildProcess config link route request input payload =
    withLifecycleChild config route $ \channel ->
        offerHandoffEdge link channel request input payload $ \offer report persist ->
            withAcknowledgedForwardLifecycleCompletionKernel offer report persist $
                \_ -> pure (Right ())
#endif

{- | Install one lexical provider reprobe service inside the same Process
exchange that owns the child. Closing the exchange closes both endpoint and
kernel; the child receives no probe, handle, or reusable authority.
-}
withProviderDependencyForwardLifecycleChildProcess ::
    HostConfig ->
    BrokerLink scope brokerGeneration ->
    LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb ->
    Word64 ->
    HandoffBindingInput ->
    ByteString ->
    ByteString ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    IO (Either Text Word64) ->
    IO (Either Text ())
withProviderDependencyForwardLifecycleChildProcess config link route request input payload packageWire plan scope resource frame origin generation journal receipt providerRoute now probe =
    withProviderDependencyReprobeKernel
        packageWire
        plan
        scope
        resource
        frame
        origin
        generation
        journal
        receipt
        providerRoute
        now
        probe
        $ \endpoint ->
            withProviderDependencyReprobeEndpointKernel link packageWire endpoint $ \installed ->
                withForwardLifecycleChildProcess config installed route request input payload

{- | Carry an already registered invocation-local provider package and its
fixed live service into one authenticated child exchange. The endpoint checks
the canonical package/request join before invoking the retained service.
-}
withCarriedProviderDependencyForwardLifecycleChildProcess ::
    HostConfig ->
    BrokerLink scope brokerGeneration ->
    LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb ->
    Word64 ->
    HandoffBindingInput ->
    ByteString ->
    ByteString ->
    (ByteString -> IO (Either Text ByteString)) ->
    IO (Either Text ())
withCarriedProviderDependencyForwardLifecycleChildProcess config link route request input payload packageWire service =
    case providerDependencyPackageFields packageWire of
        Left failure -> pure (Left failure)
        Right _ ->
            withProviderDependencyReprobeEndpointKernel link packageWire endpoint $ \installed ->
                withForwardLifecycleChildProcess config installed route request input payload
  where
    endpoint fields = case providerDependencyProbeRequestFromFields packageWire fields of
        Left failure -> pure (Left failure)
        Right _nonce -> case fields of
            [requestWire] -> fmap (fmap pure) (service requestWire)
            _ -> pure (Left "provider dependency request fields changed after validation")

seedProviderDependencyCarrierKernel ::
    ResourceCarrier scope planId ->
    ByteString ->
    (Text -> IO (Either Text (Either Text Word64))) ->
    IO (Either Text ())
seedProviderDependencyCarrierKernel carrier packageWire client =
    case Dependency.runtimeDependencyPackageFromWire packageWire of
        Left failure -> pure (Left failure)
        Right package
            | Dependency.runtimeDependencyPackageDomain package /= "provider" ->
                pure (Left "forward child: the admitted dependency package is not a provider package")
            | otherwise -> do
                -- The authenticated package transfers ownership evidence, but
                -- not the parent frame's settlement.  Version 1 is only the
                -- descriptive child-side handle version; the package binds the
                -- exact resource, generation, receipt, and live reprobe.
                pushCarriedResource
                    carrier
                    ( mintTransferredCarriedResource
                        (Dependency.runtimeDependencyPackageResource package)
                        (Dependency.runtimeDependencyPackageGeneration package)
                        1
                        (Dependency.runtimeDependencyPackageResource package)
                    )
                runtime <- newStepRuntime carrier
                registered <- registerStepRuntimeDependencyPackage runtime package
                case registered of
                    Left failure -> pure (Left failure)
                    Right () -> replaceStepRuntimeDependencyService runtime package $ \requestWire ->
                        case Dependency.withRuntimeDependencyProbeRequest package requestWire id of
                            Left failure -> pure (Left failure)
                            Right nonce -> fmap (encodeOutcome package nonce) (client nonce)
  where
    encodeOutcome package nonce outcome = case outcome of
        Left failure -> Left failure
        Right (Left reason) -> Dependency.renderRuntimeDependencyProbeRefusal package nonce reason
        Right (Right observed) -> Right (Dependency.renderRuntimeDependencyProbeResponse package nonce observed)

withCarriedProviderDependencyFromCarrierKernel ::
    HostConfig ->
    BrokerLink scope brokerGeneration ->
    LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb ->
    Word64 ->
    HandoffBindingInput ->
    ByteString ->
    ResourceCarrier scope planId ->
    IO (Either Text ())
withCarriedProviderDependencyFromCarrierKernel config link route request input payload carrier = do
    runtime <- newStepRuntime carrier
    packages <- stepRuntimeDependencyPackages runtime
    case filter ((== "provider") . Dependency.runtimeDependencyPackageDomain) packages of
        [] -> withForwardLifecycleChildProcess config link route request input payload
        [package] ->
            withCarriedProviderDependencyForwardLifecycleChildProcess
                config
                link
                route
                request
                input
                payload
                (Dependency.runtimeDependencyPackageWire package)
                (invokeStepRuntimeDependencyService runtime package)
        _ -> pure (Left "forward child: multiple provider dependency packages are carried")

{- | Launch one reverse child and complete its edge on the same terms.

The prepared descent carries its own catalog-admitted package, so this entry
takes no payload at all, and the reverse completion kernel is the fixed one
here for the same reason the forward kernel is fixed there.
-}
withReverseLifecycleChildProcess ::
    HostConfig ->
    BrokerLink scope brokerGeneration ->
    LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb ->
    Word64 ->
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    IO (Either Text ())
#if defined(mingw32_HOST_OS)
withReverseLifecycleChildProcess _config _link _route _request _descent =
    pure (Left unsupportedOnThisHost)

{- | The refusal this row returns on a host without POSIX process groups.

It is a total answer rather than an absence: the caller receives the same
'Either' it receives everywhere, and the reason names the primitive the
contract needs rather than the module that is missing.
-}
unsupportedOnThisHost :: Text
unsupportedOnThisHost =
    processFailure
        "owning a child's process group is a POSIX row, and this host has no group signal"
#else
withReverseLifecycleChildProcess config link route request descent =
    withLifecycleChild config route $ \channel ->
        offerReverseDescentKernel link channel request descent $ \bound report persist ->
            withAcknowledgedBoundReverseLifecycleCompletionKernel bound report persist $
                \_ -> pure (Right ())

{- | Derive and own one reverse child directly from its prepared descent.

The target binary is the only platform-dependent description supplied by the
root coordinator. Package, lift route, binding input, and verb all come from
the opaque prepared value and remain lexical to route construction.
-}
withPreparedReverseLifecycleChildProcess ::
    forall scope brokerGeneration planId parentFrame childFrame verb descentId.
    HostConfig ->
    BrokerLink scope brokerGeneration ->
    Word64 ->
    Text ->
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    IO (Either Text ())
withPreparedReverseLifecycleChildProcess config link request targetBinary descent = do
    withReverseDescentProcessInputsKernel descent $ \package route input verb ->
        withRecoveryLifecycleProcessRouteForKernel
            (Proxy :: Proxy scope)
            (Proxy :: Proxy brokerGeneration)
            package route input verb targetBinary $ \processRoute ->
                withReverseLifecycleChildProcess config link processRoute request descent

{- | Hold one child, its pipes, and its group for exactly one exchange.

The route decides what runs: its host tool is resolved to an absolute path
through the installed configuration, so a bare command name cannot be executed
even if one reached the argument vector, and an already opened route refuses
before a process exists. Standard error is inherited deliberately — it is where
the isolated child sends everything that is not a protocol frame.
-}
withLifecycleChild ::
    HostConfig ->
    LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb ->
    (HandoffChannel -> IO (Either RelayError ())) ->
    IO (Either Text ())
withLifecycleChild config route serve =
    withLifecycleProcessRouteLaunchKernel route $ \tool argv _interactive ->
        case resolveMaybe config tool of
            Nothing ->
                pure (Left (processFailure "the route's host tool resolves to no absolute path"))
            Just exe -> spawned (absExePath exe) (map Text.unpack argv)
  where
    spawned executable arguments =
        withCreateProcess (childProcess executable arguments) $
            \inbound outbound _ child ->
                case (inbound, outbound) of
                    (Just childStdin, Just childStdout) ->
                        Exception.bracket_
                            (pure ())
                            (terminateChildGroup child childStdin childStdout)
                            (exchange childStdin childStdout serve)
                    _ ->
                        pure (Left (processFailure "the child was launched without its own pipes"))

{- | The only process shape this owner ever launches. -}
childProcess :: FilePath -> [String] -> CreateProcess
childProcess executable arguments =
    (proc executable arguments)
        { std_in = CreatePipe
        , std_out = CreatePipe
        , std_err = Inherit
        , create_group = True
        , close_fds = True
        }

{- | Run the exchange on the child's own pipes and report only rooted completion.

The launch is bounded, because a child that never reaches its first frame is
indistinguishable from one that never started. Everything after that is the
relay's to bound: it limits the frames the child owes immediately and leaves
the admitted work alone.
-}
exchange ::
    Handle ->
    Handle ->
    (HandoffChannel -> IO (Either RelayError ())) ->
    IO (Either Text ())
exchange childStdin childStdout serve = do
    opened <- timeout launchMicros (handoffChannel childStdout childStdin)
    case opened of
        Nothing -> pure (Left (processFailure "the child never opened its protocol channel"))
        Just channel -> do
            served <- serve channel
            pure (either (Left . processFailure . Text.pack . relayErrorMessage) Right served)

{- | End the child's whole group, then reap it, whatever happened above.

The group is signalled rather than the process, so a shell, provider, or nested
tool the child launched goes away with it. Termination is attempted first and
escalated only if the group is still present after the grace, because a child
that is finishing an effect deserves the chance to finish it; the escalation
exists because a child that is not finishing anything must not become the
operator's problem. The wait is unconditional — a reaped child is the only kind
that is not a zombie — and the pipes are closed last, quietly, because a
descriptor left open outlives the process that justified it.
-}
terminateChildGroup :: ProcessHandle -> Handle -> Handle -> IO ()
terminateChildGroup child childStdin childStdout = do
    signalChildGroup child sigTERM
    lingering <- waitFor terminationGraceMicros child
    case lingering of
        Just _ -> pure ()
        Nothing -> signalChildGroup child sigKILL
    _ <- Exception.try (waitForProcess child) :: IO (Either Exception.SomeException ExitCode)
    closeQuietly childStdin
    closeQuietly childStdout

{- | Signal the child's own group, or accept that there is no longer one. -}
signalChildGroup :: ProcessHandle -> Signal -> IO ()
signalChildGroup child signal = do
    identity <- getPid child
    case identity of
        Nothing -> pure ()
        Just pid -> do
            signalled <-
                Exception.try (signalProcessGroup signal (fromIntegral pid))
            either (\(_ :: Exception.IOException) -> pure ()) pure signalled

{- | Poll for the child's exit until the grace runs out. -}
waitFor :: Int -> ProcessHandle -> IO (Maybe ExitCode)
waitFor remaining child
    | remaining <= 0 = getProcessExitCode child
    | otherwise = do
        exited <- getProcessExitCode child
        case exited of
            Just status -> pure (Just status)
            Nothing -> do
                threadDelay pollMicros
                waitFor (remaining - pollMicros) child

closeQuietly :: Handle -> IO ()
closeQuietly handle = do
    closed <- Exception.try (hClose handle)
    either (\(_ :: Exception.IOException) -> pure ()) pure closed

{- | How long a child has to exist at all. -}
launchMicros :: Int
launchMicros = 30 * 1000000

{- | How long a signalled group has to finish before it is killed. -}
terminationGraceMicros :: Int
terminationGraceMicros = 10 * 1000000

{- | How often the grace is checked. -}
pollMicros :: Int
pollMicros = 50 * 1000
#endif

processFailure :: Text -> Text
processFailure detail = "lifecycle child process: " <> detail
