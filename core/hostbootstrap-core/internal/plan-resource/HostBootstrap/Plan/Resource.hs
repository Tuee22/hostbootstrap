{-# LANGUAGE RoleAnnotations #-}

{- | The private representation of an exact planned resource.

Validated graph projection remains in "HostBootstrap.Lifecycle.Plan". This
lower type home lets private backend kernels share the same resource identity
without depending on the main library or duplicating its representation.
-}
module HostBootstrap.Plan.Resource (
    PlannedResource (..),
    ProviderResource,
    DurableShareResource,
    DurableAliasResource,
    DockerResource,
    MinioResource,
    RegistryResource,
    ClusterResource,
)
where

import Data.Text (Text)

{- | One resource identity projected from an exact admitted plan.

The stable operation key and frame are read from the validated graph, while
the digest is retained so later reconciliation gates can reject a value from
another interpretation. The constructor is available only to private consumers.
-}
data PlannedResource scope planId resourceId resource frame
    = PlannedResource Text Text Text

type role PlannedResource nominal nominal nominal nominal nominal

data ProviderResource
data DurableShareResource
data DurableAliasResource
data DockerResource
data MinioResource
data RegistryResource
data ClusterResource
