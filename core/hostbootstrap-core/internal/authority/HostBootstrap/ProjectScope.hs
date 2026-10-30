{- | Lifecycle scopes shared by project authority and configuration.

The parameters are phantom identities minted by the owning rank-2 brackets.
-}
module HostBootstrap.ProjectScope (
    Production,
    Harness,
) where

-- | Production scope for one installed project identity.
data Production projectId

-- | Harness scope for one installed project and one generative run.
data Harness projectId runId
