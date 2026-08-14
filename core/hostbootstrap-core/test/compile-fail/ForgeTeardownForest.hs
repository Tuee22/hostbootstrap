module ForgeTeardownForest where

import HostBootstrap.Authority (ProjectVerb (ProjectDestroy), VerbDestroy, VerbDown)
import HostBootstrap.Teardown

-- A `down` projection is not a `destroy` projection. `down` stops a provider
-- frame and keeps its disk; `destroy` deletes both. Substituting one for the
-- other is the difference between a restartable stack and a deleted one.
downAsDestroy :: TeardownPlan s p f VerbDown -> TeardownPlan s p f VerbDestroy
downAsDestroy projection = projection

-- Likewise for the live forest and for the completed proof, so a completed
-- `down` cannot be presented to the settled-destroy verifier.
downForestAsDestroy :: TeardownForest s p f VerbDown -> TeardownForest s p f VerbDestroy
downForestAsDestroy forest = forest

completedDownAsDestroy ::
    CompletedTeardownForest s p f VerbDown ->
    CompletedTeardownForest s p f VerbDestroy
completedDownAsDestroy completed = completed

-- `openTeardownForest` is the sole initial forest producer; there is no way to
-- name a forest, so a caller cannot start one at an arbitrary position.
forgedForest :: TeardownForest s p f VerbDestroy
forgedForest = TeardownForest undefined []

-- An authorization point is authority to attempt one step of one forest.
forgedPoint :: TeardownAuthorizationPoint s p f VerbDestroy
forgedPoint = TeardownAuthorizationPoint

-- The completed-forest proof is minted only when every node settled.
forgedCompleted :: CompletedTeardownForest s p f VerbDestroy
forgedCompleted = CompletedTeardownForest ProjectDestroy "plan-1" "frame" []

-- The settled-child proof cannot be asserted: it is what stops a parent frame
-- being torn down while a child still needs it.
forgedSettledChildren :: SettledChildren s p f
forgedSettledChildren = SettledChildren []

-- Nor can the destroy-only pre-descent step.
forgedPreDescent :: PreDescentStep s p f VerbDestroy
forgedPreDescent = PreDescentStep

-- `DestroySettled` is the settled half of Production closure. Asserting one
-- would let a project release its mode with resources still acquired.
forgedSettled :: DestroySettled s p
forgedSettled = DestroySettled "plan-1" []

-- Progress has no public constructors, so neither branch can be wrapped or
-- skipped; `eliminateTeardownProgress` is the only reader.
forgedProgress :: TeardownProgress s p f VerbDestroy
forgedProgress = ProgressCompleted forgedCompleted
