module ForgeTeardownForest where

import HostBootstrap.Teardown

-- A `down` projection is not a `destroy` projection. `down` stops a provider
-- frame and keeps its disk; `destroy` deletes both. Substituting one for the
-- other is the difference between a restartable stack and a deleted one.
downAsDestroy :: TeardownPlan s p f DownVerb -> TeardownPlan s p f DestroyVerb
downAsDestroy projection = projection

-- Likewise for the live forest and for the completed proof, so a completed
-- `down` cannot be presented to the settled-destroy verifier.
downForestAsDestroy :: TeardownForest s p DownVerb -> TeardownForest s p DestroyVerb
downForestAsDestroy forest = forest

completedDownAsDestroy ::
    CompletedTeardownForest s p DownVerb -> CompletedTeardownForest s p DestroyVerb
completedDownAsDestroy completed = completed

-- `openTeardownForest` is the sole initial forest producer; there is no way to
-- name a forest, so a caller cannot start one at an arbitrary position.
forgedForest :: TeardownForest s p DestroyVerb
forgedForest = TeardownForest destroyVerb "plan-1" []

-- An authorization point is authority to attempt one step of one forest.
forgedPoint :: TeardownAuthorizationPoint s p DestroyVerb
forgedPoint = TeardownAuthorizationPoint

-- The completed-forest proof is minted only when every node settled.
forgedCompleted :: CompletedTeardownForest s p DestroyVerb
forgedCompleted = CompletedTeardownForest destroyVerb "plan-1" [] []

-- The settled-child proof cannot be asserted: it is what stops a parent frame
-- being torn down while a child still needs it.
forgedSettledChildren :: SettledChildren s p
forgedSettledChildren = SettledChildren []

-- Nor can the destroy-only pre-descent step, or an ordinary cursor.
forgedPreDescent :: PreDescentStep s p DestroyVerb
forgedPreDescent = PreDescentStep

forgedCursor :: TeardownCursor s p DestroyVerb
forgedCursor = TeardownCursor

-- `DestroySettled` is the settled half of Production closure. Asserting one
-- would let a project release its mode with resources still acquired.
forgedSettled :: DestroySettled s p
forgedSettled = DestroySettled "plan-1" []

-- Progress has no public constructors, so neither branch can be wrapped or
-- skipped; `eliminateTeardownProgress` is the only reader.
forgedProgress :: TeardownProgress s p DestroyVerb
forgedProgress = ProgressCompleted forgedCompleted
