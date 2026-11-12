module CoerceResolvedExposureRoles where

import Data.Coerce (coerce)
import HostBootstrap.Cluster.Backend (PreparedClusterExposure, ResolvedExposure)

data ResolvedScopeA
data ResolvedScopeB
data ResolvedPlanA
data ResolvedPlanB
data ResolvedClusterA
data ResolvedClusterB
data ResolvedServiceA
data ResolvedServiceB

crossResolvedScope :: ResolvedExposure ResolvedScopeA ResolvedPlanA ResolvedClusterA ResolvedServiceA -> ResolvedExposure ResolvedScopeB ResolvedPlanA ResolvedClusterA ResolvedServiceA
crossResolvedScope = coerce

crossResolvedPlan :: ResolvedExposure ResolvedScopeA ResolvedPlanA ResolvedClusterA ResolvedServiceA -> ResolvedExposure ResolvedScopeA ResolvedPlanB ResolvedClusterA ResolvedServiceA
crossResolvedPlan = coerce

crossResolvedCluster :: ResolvedExposure ResolvedScopeA ResolvedPlanA ResolvedClusterA ResolvedServiceA -> ResolvedExposure ResolvedScopeA ResolvedPlanA ResolvedClusterB ResolvedServiceA
crossResolvedCluster = coerce

crossResolvedService :: ResolvedExposure ResolvedScopeA ResolvedPlanA ResolvedClusterA ResolvedServiceA -> ResolvedExposure ResolvedScopeA ResolvedPlanA ResolvedClusterA ResolvedServiceB
crossResolvedService = coerce

data PreparedScopeA
data PreparedScopeB
data PreparedPlanA
data PreparedPlanB
data PreparedClusterA
data PreparedClusterB
data PreparedFrameA
data PreparedFrameB

crossPreparedScope :: PreparedClusterExposure PreparedScopeA PreparedPlanA PreparedClusterA PreparedFrameA -> PreparedClusterExposure PreparedScopeB PreparedPlanA PreparedClusterA PreparedFrameA
crossPreparedScope = coerce

crossPreparedPlan :: PreparedClusterExposure PreparedScopeA PreparedPlanA PreparedClusterA PreparedFrameA -> PreparedClusterExposure PreparedScopeA PreparedPlanB PreparedClusterA PreparedFrameA
crossPreparedPlan = coerce

crossPreparedCluster :: PreparedClusterExposure PreparedScopeA PreparedPlanA PreparedClusterA PreparedFrameA -> PreparedClusterExposure PreparedScopeA PreparedPlanA PreparedClusterB PreparedFrameA
crossPreparedCluster = coerce

crossPreparedFrame :: PreparedClusterExposure PreparedScopeA PreparedPlanA PreparedClusterA PreparedFrameA -> PreparedClusterExposure PreparedScopeA PreparedPlanA PreparedClusterA PreparedFrameB
crossPreparedFrame = coerce
