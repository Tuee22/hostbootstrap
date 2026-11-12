{-# LANGUAGE RoleAnnotations #-}

{- | Package-private transport primitives for the provider boundary.

Public callers may interpret a request handed to the bound discovery executor,
but cannot construct one. The package-private bound route executes only closed
provider requests for the exact managed resource. A discovery capability carries
descriptive facts and no independent guest runner.
-}
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

-- | The Direct permission observation; egress uses a separate ProviderProvisioningEgressProbe request.
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

{- | Raw discovery execution already bound by the clause-holding provider
backend to one exact managed provider resource and phase.
-}
data ProviderBoundRoute
    = ProviderBoundIncusRoute String String
    | ProviderBoundLimaRoute String
    | ProviderBoundWsl2Route String
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
