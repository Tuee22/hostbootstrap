module RecordUpdateBudget where

import HostBootstrap.Cluster.Cordon.Foundation (ResourceBudget, budgetCpu)

relabel :: ResourceBudget -> ResourceBudget
relabel budget = budget{budgetCpu = 0}
