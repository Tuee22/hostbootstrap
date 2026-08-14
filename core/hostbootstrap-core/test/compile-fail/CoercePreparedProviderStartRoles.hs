{- | Every plan, resource, and journal axis on a prepared provider start is
nominal. -}
module CoercePreparedProviderStartRoles where

import Data.Coerce (coerce)
import HostBootstrap.Reconcile (PreparedProviderStart)

data Scope
data PlanA
data PlanB
data ProviderResource
data Operation
data CallDigestA
data CallDigestB
data Attempt
data JournalVersion

wrongPlan ::
  PreparedProviderStart Scope PlanA ProviderResource Operation CallDigestA Attempt JournalVersion ->
  PreparedProviderStart Scope PlanB ProviderResource Operation CallDigestA Attempt JournalVersion
wrongPlan = coerce

wrongCall ::
  PreparedProviderStart Scope PlanA ProviderResource Operation CallDigestA Attempt JournalVersion ->
  PreparedProviderStart Scope PlanA ProviderResource Operation CallDigestB Attempt JournalVersion
wrongCall = coerce
