module EscapeChildProjectPlanIdentity where

import Data.List.NonEmpty (NonEmpty)
import HostBootstrap.Authority (AuthorityError, ProjectVerb)
import HostBootstrap.Config.Schema
    ( ValidatedConfig
    , VerifiedConfigHandoff
    , VerifiedConfigWire
    )
import HostBootstrap.ProjectPlan (PlanDraft)
import HostBootstrap.ProjectPlan.Construct
    ( ChildPlanAuthority
    , withChildProjectPlan
    )

data ChosenPlan

-- Child plan admission chooses a fresh local plan identity.  The callback
-- cannot retain its authority under an identity selected by the caller.
escapeChildPlanIdentity ::
    ProjectVerb verb ->
    VerifiedConfigHandoff
        scope planDigest brokerGeneration parentFrame childFrame configId verb phase ->
    VerifiedConfigWire scope configDigest configId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    NonEmpty (PlanDraft scope specDigest (cfg scope)) ->
    Either
        AuthorityError
        ( ChildPlanAuthority
            scope specDigest planDigest brokerGeneration parentFrame childFrame
            ChosenPlan configId verb phase
        )
escapeChildPlanIdentity verb handoff wire config drafts =
    withChildProjectPlan verb handoff wire config drafts
        (\authority _plan _binding -> authority)
