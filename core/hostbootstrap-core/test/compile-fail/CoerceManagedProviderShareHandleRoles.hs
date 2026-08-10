module CoerceManagedProviderShareHandleRoles where

import Data.Coerce (coerce)
import HostBootstrap.Substrate.Provider.Reconcile

data ScopeA
data ScopeB
data PlanA
data PlanB
data BackendA
data BackendB
data ProviderA
data ProviderB
data ShareA
data ShareB
data PhaseA
data PhaseB

coerceScope ::
  ManagedProviderShareHandle ScopeA PlanA BackendA ProviderA ShareA PhaseA ->
  ManagedProviderShareHandle ScopeB PlanA BackendA ProviderA ShareA PhaseA
coerceScope = coerce

coercePlan ::
  ManagedProviderShareHandle ScopeA PlanA BackendA ProviderA ShareA PhaseA ->
  ManagedProviderShareHandle ScopeA PlanB BackendA ProviderA ShareA PhaseA
coercePlan = coerce

coerceBackend ::
  ManagedProviderShareHandle ScopeA PlanA BackendA ProviderA ShareA PhaseA ->
  ManagedProviderShareHandle ScopeA PlanA BackendB ProviderA ShareA PhaseA
coerceBackend = coerce

coerceProvider ::
  ManagedProviderShareHandle ScopeA PlanA BackendA ProviderA ShareA PhaseA ->
  ManagedProviderShareHandle ScopeA PlanA BackendA ProviderB ShareA PhaseA
coerceProvider = coerce

coerceShare ::
  ManagedProviderShareHandle ScopeA PlanA BackendA ProviderA ShareA PhaseA ->
  ManagedProviderShareHandle ScopeA PlanA BackendA ProviderA ShareB PhaseA
coerceShare = coerce

coercePhase ::
  ManagedProviderShareHandle ScopeA PlanA BackendA ProviderA ShareA PhaseA ->
  ManagedProviderShareHandle ScopeA PlanA BackendA ProviderA ShareA PhaseB
coercePhase = coerce
