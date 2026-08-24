{-# LANGUAGE DataKinds #-}

module CoerceExposureAuthorityRoles where

import Data.Coerce (coerce)
import HostBootstrap.Network (Exposure, NetworkScope (HostLocal))

data ScopeA
data ScopeB
data PlanA
data PlanB
data ClusterA
data ClusterB
data ServiceA
data ServiceB

crossScope :: Exposure 'HostLocal ScopeA PlanA ClusterA ServiceA -> Exposure 'HostLocal ScopeB PlanA ClusterA ServiceA
crossScope = coerce

crossPlan :: Exposure 'HostLocal ScopeA PlanA ClusterA ServiceA -> Exposure 'HostLocal ScopeA PlanB ClusterA ServiceA
crossPlan = coerce

crossCluster :: Exposure 'HostLocal ScopeA PlanA ClusterA ServiceA -> Exposure 'HostLocal ScopeA PlanA ClusterB ServiceA
crossCluster = coerce

crossService :: Exposure 'HostLocal ScopeA PlanA ClusterA ServiceA -> Exposure 'HostLocal ScopeA PlanA ClusterA ServiceB
crossService = coerce
