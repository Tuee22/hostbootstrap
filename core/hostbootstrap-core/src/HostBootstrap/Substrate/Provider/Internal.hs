{-# LANGUAGE RoleAnnotations #-}

-- | Package-private transport primitives for the provider boundary.
--
-- Public callers may /interpret/ a request handed to their injected executor,
-- but cannot construct one.  Alias/backend modules in this package use the
-- bound guest executor below; no public function projects an arbitrary argv
-- runner out of a discovery capability.
module HostBootstrap.Substrate.Provider.Internal (
    ProviderProbeRequest,
    ProviderProbeRequestView (..),
    DirectProbe (..),
    RawProviderOutcome (..),
    providerProbeRequestView,
    hostToolRequest,
    directProbeRequest,
    provisioningEgressRequest,
    guestProbeRequest,
    ProviderGuestExecutor,
    bindProviderGuestExecutor,
    runProviderGuestExecutor,
    ProviderBoundExec,
    ProviderBoundRoute (..),
    bindProviderBoundExec,
    providerBoundRoute,
    runProviderBoundExec,
    waitProviderBoundExec,
) where

import HostBootstrap.HostTool (HostTool)
import HostBootstrap.Readiness (Micros)
import System.Exit (ExitCode)

-- | The two observations applicable to the already-local provider.
data DirectProbe
    = DirectPermissionProbe
    deriving (Eq, Show)

-- | Read-only shape of one provider-owned request.
data ProviderProbeRequestView
    = ProviderHostToolRequest HostTool [String]
    | ProviderDirectProbeRequest DirectProbe
    | ProviderProvisioningEgressProbe
    | ProviderGuestProbeRequest [String]
    deriving (Eq, Show)

-- Constructor intentionally package-private.
newtype ProviderProbeRequest = ProviderProbeRequest ProviderProbeRequestView

providerProbeRequestView :: ProviderProbeRequest -> ProviderProbeRequestView
providerProbeRequestView (ProviderProbeRequest request) = request

hostToolRequest :: HostTool -> [String] -> ProviderProbeRequest
hostToolRequest tool argv = ProviderProbeRequest (ProviderHostToolRequest tool argv)

directProbeRequest :: DirectProbe -> ProviderProbeRequest
directProbeRequest probe = ProviderProbeRequest (ProviderDirectProbeRequest probe)

provisioningEgressRequest :: ProviderProbeRequest
provisioningEgressRequest = ProviderProbeRequest ProviderProvisioningEgressProbe

guestProbeRequest :: [String] -> ProviderProbeRequest
guestProbeRequest argv = ProviderProbeRequest (ProviderGuestProbeRequest argv)

-- | Raw process/transport output.  It carries no semantic readiness claim.
data RawProviderOutcome
    = RawProviderExit ExitCode String String
    | RawProviderFailure String
    deriving (Eq, Show)

-- | Guest execution bound to one discovered managed provider resource.
--
-- Its constructor and runner live only in this hidden module.  Public code can
-- possess the opaque value but cannot turn it into an argv execution oracle.
newtype ProviderGuestExecutor scope planId providerId phase backendId capabilityId
    = ProviderGuestExecutor ([String] -> IO RawProviderOutcome)

type role ProviderGuestExecutor nominal nominal nominal nominal nominal nominal

bindProviderGuestExecutor ::
    ([String] -> IO RawProviderOutcome) ->
    ProviderGuestExecutor scope planId providerId phase backendId capabilityId
bindProviderGuestExecutor = ProviderGuestExecutor

runProviderGuestExecutor ::
    ProviderGuestExecutor scope planId providerId phase backendId capabilityId ->
    [String] ->
    IO RawProviderOutcome
runProviderGuestExecutor (ProviderGuestExecutor execute) = execute

-- | Raw discovery execution already bound by the clause-holding provider
-- backend to one exact managed provider resource and phase.
data ProviderBoundRoute
    = ProviderBoundIncusRoute String String
    | ProviderBoundLimaRoute String
    | ProviderBoundDirectRoute FilePath String
    deriving (Eq, Show)

data ProviderBoundExec scope planId providerId phase backendId
    = ProviderBoundExec
        ProviderBoundRoute
        (ProviderProbeRequest -> IO RawProviderOutcome)
        (Micros -> IO ())

type role ProviderBoundExec nominal nominal nominal nominal nominal

bindProviderBoundExec ::
    ProviderBoundRoute ->
    (ProviderProbeRequest -> IO RawProviderOutcome) ->
    (Micros -> IO ()) ->
    ProviderBoundExec scope planId providerId phase backendId
bindProviderBoundExec = ProviderBoundExec

providerBoundRoute ::
    ProviderBoundExec scope planId providerId phase backendId ->
    ProviderBoundRoute
providerBoundRoute (ProviderBoundExec route _ _) = route

runProviderBoundExec ::
    ProviderBoundExec scope planId providerId phase backendId ->
    ProviderProbeRequest ->
    IO RawProviderOutcome
runProviderBoundExec (ProviderBoundExec _ execute _) = execute

waitProviderBoundExec ::
    ProviderBoundExec scope planId providerId phase backendId ->
    Micros ->
    IO ()
waitProviderBoundExec (ProviderBoundExec _ _ wait) = wait
