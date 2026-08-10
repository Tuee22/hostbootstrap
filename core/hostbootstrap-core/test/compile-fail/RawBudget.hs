module RawBudget where

import HostBootstrap.Cluster.Budget
import HostBootstrap.Cluster.Cordon.Foundation

badBudget :: ResourceBudget
badBudget = ResourceBudget 0 0 0

badCapability :: ProviderBudgetCapability scope planId provider capabilityId
badCapability = ProviderBudgetCapability LimaBackend
