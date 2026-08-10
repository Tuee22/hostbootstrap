module CoerceProviderPhaseAdvanceRoles where

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
data PhaseA
data PhaseB

coerceScope ::
  ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA PhaseA ->
  ProviderPhaseAdvance ScopeB PlanA BackendA ProviderA PhaseA
coerceScope = coerce

coercePlan ::
  ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA PhaseA ->
  ProviderPhaseAdvance ScopeA PlanB BackendA ProviderA PhaseA
coercePlan = coerce

coerceBackend ::
  ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA PhaseA ->
  ProviderPhaseAdvance ScopeA PlanA BackendB ProviderA PhaseA
coerceBackend = coerce

coerceProvider ::
  ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA PhaseA ->
  ProviderPhaseAdvance ScopeA PlanA BackendA ProviderB PhaseA
coerceProvider = coerce

coercePhase ::
  ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA PhaseA ->
  ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA PhaseB
coercePhase = coerce
