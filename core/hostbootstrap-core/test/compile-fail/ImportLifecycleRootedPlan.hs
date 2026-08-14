module ImportLifecycleRootedPlan where

-- A downstream consumer cannot import the recursive rooted plan catalog, its
-- two hidden constructors, its producer, or any of its rank-2 folds.
import HostBootstrap.Lifecycle.RootedPlan
