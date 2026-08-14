module LegacyRootDestroyVerifier where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan
data Frame

-- The former projection+completion shortcut lacked the exact ProjectPlan and
-- CurrentFrame packages needed to prove unique-root membership.
legacyRootVerifier ::
    TeardownPlan Scope Plan Frame VerbDestroy ->
    CompletedTeardownForest Scope Plan Frame VerbDestroy ->
    Either TeardownError (DestroySettled Scope Plan)
legacyRootVerifier = verifyDestroySettled
