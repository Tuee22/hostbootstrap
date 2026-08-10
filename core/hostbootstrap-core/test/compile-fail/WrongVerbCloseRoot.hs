module WrongVerbCloseRoot where

import HostBootstrap.Authority
import HostBootstrap.Lifecycle.Closure

-- An `up` grant cannot take the settled-destroy closure branch: the verb index
-- is part of the type, so this is a type error rather than a runtime check.
upAuthority :: RootInvocationAuthority scope brokerGeneration VerbUp
upAuthority = undefined

settledFromUp :: ProductionCloseRoot scope brokerGeneration
settledFromUp = destroyCloseRoot upAuthority
