module CoerceFailedUpAuthorityRoles where

import Data.Coerce (coerce)
import HostBootstrap.Authority.FailedUp.Internal (FailedUpUnwindAuthority)

newtype FailedScopeA = FailedScopeA Int
newtype FailedScopeB = FailedScopeB Int
newtype FailedPlanA = FailedPlanA Int
newtype FailedPlanB = FailedPlanB Int
newtype FailedBrokerA = FailedBrokerA Int
newtype FailedBrokerB = FailedBrokerB Int
newtype FailedCatalogA = FailedCatalogA Int
newtype FailedCatalogB = FailedCatalogB Int

scope :: FailedUpUnwindAuthority FailedScopeA FailedPlanA FailedBrokerA FailedCatalogA -> FailedUpUnwindAuthority FailedScopeB FailedPlanA FailedBrokerA FailedCatalogA
scope = coerce

plan :: FailedUpUnwindAuthority FailedScopeA FailedPlanA FailedBrokerA FailedCatalogA -> FailedUpUnwindAuthority FailedScopeA FailedPlanB FailedBrokerA FailedCatalogA
plan = coerce

broker :: FailedUpUnwindAuthority FailedScopeA FailedPlanA FailedBrokerA FailedCatalogA -> FailedUpUnwindAuthority FailedScopeA FailedPlanA FailedBrokerB FailedCatalogA
broker = coerce

catalog :: FailedUpUnwindAuthority FailedScopeA FailedPlanA FailedBrokerA FailedCatalogA -> FailedUpUnwindAuthority FailedScopeA FailedPlanA FailedBrokerA FailedCatalogB
catalog = coerce
