{-# LANGUAGE GADTs #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Package-private bridge from the provider's clause-holding backend to
dependent exact consumers.  Public callers can retain the abstract package,
but only code in this package can recover the generic Running handle and the
backend-owned fresh reprobe used by dependency preconditions.
-}
module HostBootstrap.Substrate.Provider.Dependency.Internal
  ( RunningProviderDependency (..),
    runningProviderDependencyHandle,
    runningProviderDependencyReprobe,
  )
where

import Data.Word (Word64)
import HostBootstrap.Reconcile
  ( Managed,
    ProviderResource,
    ReconcileError,
    ResourceHandle,
    Running,
  )
import HostBootstrap.Substrate.Provider.Observation.Internal
  ( ManagedProviderHandle (..),
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
