module CoerceManagedProviderHandleRoles where

import Data.Coerce (coerce)
import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Reconcile

data ScopeA
data ScopeB
data PlanA
data PlanB
data BackendA
data BackendB
data ProviderA
data ProviderB
data PhaseA
data PhaseB

coerceScope ::
  ManagedProviderHandle ScopeA PlanA BackendA ProviderA PhaseA ->
  ManagedProviderHandle ScopeB PlanA BackendA ProviderA PhaseA
coerceScope = coerce

coercePlan ::
  ManagedProviderHandle ScopeA PlanA BackendA ProviderA PhaseA ->
  ManagedProviderHandle ScopeA PlanB BackendA ProviderA PhaseA
coercePlan = coerce

coerceBackend ::
  ManagedProviderHandle ScopeA PlanA BackendA ProviderA PhaseA ->
  ManagedProviderHandle ScopeA PlanA BackendB ProviderA PhaseA
coerceBackend = coerce

coerceProvider ::
  ManagedProviderHandle ScopeA PlanA BackendA ProviderA PhaseA ->
  ManagedProviderHandle ScopeA PlanA BackendA ProviderB PhaseA
coerceProvider = coerce

coercePhase ::
  ManagedProviderHandle ScopeA PlanA BackendA ProviderA PhaseA ->
  ManagedProviderHandle ScopeA PlanA BackendA ProviderA PhaseB
coercePhase = coerce
