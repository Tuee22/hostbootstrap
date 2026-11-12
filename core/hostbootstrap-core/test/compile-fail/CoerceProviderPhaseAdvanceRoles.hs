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
data SourcePhaseA
data SourcePhaseB
data PhaseA
data PhaseB

coerceScope ::
    ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA SourcePhaseA PhaseA ->
    ProviderPhaseAdvance ScopeB PlanA BackendA ProviderA SourcePhaseA PhaseA
coerceScope = coerce

coercePlan ::
    ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA SourcePhaseA PhaseA ->
    ProviderPhaseAdvance ScopeA PlanB BackendA ProviderA SourcePhaseA PhaseA
coercePlan = coerce

coerceBackend ::
    ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA SourcePhaseA PhaseA ->
    ProviderPhaseAdvance ScopeA PlanA BackendB ProviderA SourcePhaseA PhaseA
coerceBackend = coerce

coerceProvider ::
    ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA SourcePhaseA PhaseA ->
    ProviderPhaseAdvance ScopeA PlanA BackendA ProviderB SourcePhaseA PhaseA
coerceProvider = coerce

coercePhase ::
    ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA SourcePhaseA PhaseA ->
    ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA SourcePhaseA PhaseB
coercePhase = coerce
coerceSource ::
    ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA SourcePhaseA PhaseA ->
    ProviderPhaseAdvance ScopeA PlanA BackendA ProviderA SourcePhaseB PhaseA
coerceSource = coerce
