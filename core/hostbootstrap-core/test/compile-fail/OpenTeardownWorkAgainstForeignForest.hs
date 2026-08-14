module OpenTeardownWorkAgainstForeignForest where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan
data Frame

-- A branch-specific transition consumes only its retained origin package. It
-- has no argument through which a caller can select another live forest.
advanceForeign ::
    TeardownForest Scope Plan Frame VerbDestroy ->
    LocalWork Scope Plan Frame VerbDestroy ->
    TeardownOutcome ->
    TeardownForest Scope Plan Frame VerbDestroy
advanceForeign otherForest local outcome = attemptLocalWork otherForest local outcome
