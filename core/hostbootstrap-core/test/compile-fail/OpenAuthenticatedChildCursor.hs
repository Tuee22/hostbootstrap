module OpenAuthenticatedChildCursor where

-- The authenticated package and its producer stay behind the child-plan
-- implementation boundary; the public constructor facade exposes neither.
import HostBootstrap.ProjectPlan.Construct
    ( AuthenticatedChildCursor
    , withAuthenticatedChildCursor
    )
