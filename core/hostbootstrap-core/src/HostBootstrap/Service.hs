{- | The service-handler registry — one of the parallel extension streams a
project contributes through 'HostBootstrap.CLI.ProjectSpec'
(development_plan_standards § P, § T, § AA).

@hostbootstrap-core@ ships a /fixed/ @service init|schema|run@ command surface
(see "HostBootstrap.Command"); a project plugs its long-running roles in as a
registry of 'ServiceHandler's keyed by the service variant name (the Dhall
project-registered runtime name, e.g. @web@ / @workload-orchestrator@).
The project's config selector maps its Dhall @ServiceType@ to one of those
internal keys; @service run@ takes no positional variant. The registry may be
/empty/, in which case the fixed surface is unchanged and @service run@ simply
fails fast (not every project ships a service).

The registry is the only service-specific extension point: there is no
per-project @service@ verb (the surface is closed, § P).
-}
module HostBootstrap.Service (
    ServiceHandler (..),
    ServiceRegistry,
    emptyServiceRegistry,
    serviceVariantNames,
    lookupServiceHandler,
    duplicateServiceVariants,
)
where

import Data.List (find, group, sort)

{- | One long-running role a project's binary can run through @service run@. The
variant is the project-registered internal key selected from config; the
action is the role body (a leaf-frame runtime, never an orchestrator,
§ AA). The context gate ('HostBootstrap.Context.ServiceCommand') has already
validated the service-role config before the action runs, so the handler is
just the role.
-}
data ServiceHandler = ServiceHandler
    { serviceVariant :: String
    , serviceRun :: IO ()
    }

{- | A project's service-handler registry: the variants its @service run@ can
dispatch to. Concatenated across library layers like the other extension
streams (§ T); may be empty.
-}
type ServiceRegistry = [ServiceHandler]

{- | The empty registry the bare @hostbootstrap@ binary (and any project that
ships no service) supplies: @service@ stays on the tree and @service run@ fails
fast.
-}
emptyServiceRegistry :: ServiceRegistry
emptyServiceRegistry = []

-- | The variant names a registry can dispatch, in registration order.
serviceVariantNames :: ServiceRegistry -> [String]
serviceVariantNames = map serviceVariant

-- | Resolve a variant to its handler.
lookupServiceHandler :: String -> ServiceRegistry -> Maybe ServiceHandler
lookupServiceHandler variant = find ((== variant) . serviceVariant)

{- | The duplicated variant names in a registry (so the CLI entrypoint can reject
a registry that registers the same variant twice, § P).
-}
duplicateServiceVariants :: ServiceRegistry -> [String]
duplicateServiceVariants registry =
    [name | name : _ : _ <- group (sort (serviceVariantNames registry))]
