{-# LANGUAGE GADTs #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE RankNTypes #-}

{- | Package-private bridge from the provider's clause-holding backend to
dependent exact consumers.  Public callers can retain the abstract package,
but only code in this package can recover the generic Running handle and the
backend-owned fresh reprobe used by dependency preconditions.
-}
module HostBootstrap.Substrate.Provider.Dependency.Internal (
    RunningProviderDependency (..),
    runningProviderDependencyHandle,
    runningProviderDependencyReprobe,
    runningProviderDependencyProbe,
    ProviderShareDependency (..),
    providerShareDependencyHandle,
    withLocalProviderShareDependency,
    providerShareDependencyReprobe,
    providerShareDependencyProbe,
)
where

import Data.Word (Word64)
import qualified HostBootstrap.Lifecycle.Dependency.Internal as Dependency
import qualified HostBootstrap.Readiness.Kernel as ProbeKernel
import HostBootstrap.Reconcile (
    DependencyProbe,
    DurableShareResource,
    Managed,
    ProviderResource,
    Provisioned,
    ReconcileError,
    ResourceHandle,
    Running,
 )
import HostBootstrap.Substrate.Provider.Observation.Internal (
    ManagedProviderHandle (..),
    ManagedProviderShareHandle (..),
 )

{- | A Running provider authority paired with the real backend reprobe that
minted it.  Its constructor is package-private and every index is nominal.
-}
data RunningProviderDependency scope planId providerId where
    RunningProviderDependency ::
        ManagedProviderHandle scope planId backendId providerId Running ->
        IO (Either ReconcileError Word64) ->
        RunningProviderDependency scope planId providerId
    RecoveredRunningProviderDependency ::
        ResourceHandle scope planId providerId ProviderResource Managed Running ->
        IO (Either ReconcileError Word64) ->
        RunningProviderDependency scope planId providerId

type role RunningProviderDependency nominal nominal nominal

runningProviderDependencyHandle ::
    RunningProviderDependency scope planId providerId ->
    ResourceHandle scope planId providerId ProviderResource Managed Running
runningProviderDependencyHandle (RunningProviderDependency (ManagedProviderHandle _ handle _) _) = handle
runningProviderDependencyHandle (RecoveredRunningProviderDependency handle _) = handle

runningProviderDependencyReprobe ::
    RunningProviderDependency scope planId providerId ->
    IO (Either ReconcileError Word64)
runningProviderDependencyReprobe (RunningProviderDependency _ reprobe) = reprobe
runningProviderDependencyReprobe (RecoveredRunningProviderDependency _ reprobe) = reprobe

-- | Reobserve the exact backend-owned running provider during preparation.
runningProviderDependencyProbe ::
    RunningProviderDependency scope planId providerId ->
    DependencyProbe scope planId providerId ProviderResource ProbeKernel.ProviderResponding
runningProviderDependencyProbe = Dependency.dependencyProbeWithKind ProbeKernel.ProviderRespondingKind . runningProviderDependencyReprobe

{- | A carried provider-derived share paired with the owner-serviced fresh
reprobe that admitted its exact generation. The constructor remains
package-private so cluster callers cannot substitute a generic share handle or
caller-authored observation.
-}
data ProviderShareDependency scope planId shareId where
    LocalProviderShareDependency ::
        ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned ->
        IO (Either ReconcileError Word64) ->
        ProviderShareDependency scope planId shareId
    RecoveredProviderShareDependency ::
        ResourceHandle scope planId shareId DurableShareResource Managed Provisioned ->
        IO (Either ReconcileError Word64) ->
        ProviderShareDependency scope planId shareId

type role ProviderShareDependency nominal nominal nominal

providerShareDependencyHandle ::
    ProviderShareDependency scope planId shareId ->
    ResourceHandle scope planId shareId DurableShareResource Managed Provisioned
providerShareDependencyHandle (LocalProviderShareDependency (ManagedProviderShareHandle _ handle _ _) _) = handle
providerShareDependencyHandle (RecoveredProviderShareDependency handle _) = handle

-- | Inspect a local dependency without exposing its constructor to callers.
withLocalProviderShareDependency ::
    ProviderShareDependency scope planId shareId ->
    (forall backendId providerId. ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned -> result) ->
    Maybe result
withLocalProviderShareDependency (LocalProviderShareDependency managed _) consume = Just (consume managed)
withLocalProviderShareDependency (RecoveredProviderShareDependency _ _) _ = Nothing

providerShareDependencyReprobe ::
    ProviderShareDependency scope planId shareId ->
    IO (Either ReconcileError Word64)
providerShareDependencyReprobe (LocalProviderShareDependency _ reprobe) = reprobe
providerShareDependencyReprobe (RecoveredProviderShareDependency _ reprobe) = reprobe


-- | Reobserve the exact backend-owned durable share during preparation.
providerShareDependencyProbe ::
    ProviderShareDependency scope planId shareId ->
    DependencyProbe scope planId shareId DurableShareResource ProbeKernel.DurableShareReady
providerShareDependencyProbe = Dependency.dependencyProbeWithKind ProbeKernel.DurableShareKind . providerShareDependencyReprobe
