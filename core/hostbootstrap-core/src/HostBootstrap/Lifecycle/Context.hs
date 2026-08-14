{-# LANGUAGE RankNTypes #-}

{- | Exact admission of one descriptive binary context into one already-open
lifecycle plan/store/frame boundary.

The resulting value is intentionally inert: it grants no command, journal,
cursor, handoff, or backend operation.  Later package-private entry leaves may
borrow its retained evidence, but downstream callers can neither construct it
nor project the protected store or frame authorities it contains.
-}
module HostBootstrap.Lifecycle.Context
    ( ValidatedLifecycleContext
    , LifecycleContextError (..)
    , withValidatedLifecycleContext
    , lifecycleContextErrorMessage
    )
where

import qualified Data.Text as Text
import HostBootstrap.Config.Class (ProjectCfg)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Lifecycle.Context.Internal
    ( LifecycleContextError (..)
    , ValidatedLifecycleContext
    , lifecycleContextErrorMessage
    , mintValidatedLifecycleContext
    )
import HostBootstrap.Lifecycle.Plan (projectPlanProfileStoreIdentityKernel)
import HostBootstrap.ProjectPlan
    ( ProjectPlan
    , projectPlanProjectName
    , renderSnapshot
    , stablePlanSnapshotRoot
    )
import HostBootstrap.ProjectPlan.Frame (withCurrentFrame)
import HostBootstrap.ProjectRoot
    ( CanonicalProjectRoot
    , canonicalProjectRootPath
    )
import HostBootstrap.Protected
    ( ProtectedStore
    , protectedStoreIdentity
    , protectedStoreIdentityText
    , protectedStoreRoot
    )
import System.FilePath ((</>))

{- | Join one canonical root, one already-open protected store, one admitted
plan, and the exact descriptive context retained by that plan.

The installed-project identity retained by the lifecycle profile is the
canonical identity of both @project@ and @binary@ for a project executable.
The join rechecks that identity, the canonical source root, the plan snapshot
root, the fixed authority-store path and durable store identity, total
topology/placement, exact required-witness declaration, fresh runtime witness
observations, and the plan-local current frame.  It never reopens the protected
store and never consults command classes or capabilities.

All checks finish before the continuation runs, so a refusal cannot create a
journal, cursor, handoff, or backend effect through this boundary.
-}
withValidatedLifecycleContext ::
    (ProjectCfg cfg) =>
    CanonicalProjectRoot scope rootId ->
    ProtectedStore ->
    ProjectPlan scope specDigest planId configId cfg ->
    Context.BinaryContext ->
    ( forall frame.
      ValidatedLifecycleContext scope specDigest planId configId frame ->
      IO result
    ) ->
    IO (Either LifecycleContextError result)
withValidatedLifecycleContext root store plan supplied use =
    case preflight of
        Left failure -> pure (Left failure)
        Right () ->
            case withCurrentFrame plan supplied admitFrame of
                Left failure -> pure (Left (LifecycleContextFrameError failure))
                Right admitted -> admitted
  where
    canonicalRoot = canonicalProjectRootPath root
    installedProject = projectPlanProjectName plan
    expectedStoreRoot =
        canonicalRoot
            </> ".hostbootstrap"
            </> "authority"
            </> Text.unpack installedProject
    observedStoreRoot = protectedStoreRoot store
    expectedStoreIdentity = projectPlanProfileStoreIdentityKernel plan
    observedStoreIdentity =
        protectedStoreIdentityText (protectedStoreIdentity store)

    preflight
        | stablePlanSnapshotRoot (renderSnapshot plan) /= canonicalRoot =
            Left
                ( LifecycleContextPlanRootMismatch
                    canonicalRoot
                    (stablePlanSnapshotRoot (renderSnapshot plan))
                )
        | Text.unpack (Context.sourceRoot supplied) /= canonicalRoot =
            Left
                ( LifecycleContextSourceRootMismatch
                    canonicalRoot
                    (Text.unpack (Context.sourceRoot supplied))
                )
        | observedStoreRoot /= expectedStoreRoot =
            Left
                ( LifecycleContextStoreRootMismatch
                    expectedStoreRoot
                    observedStoreRoot
                )
        | observedStoreIdentity /= expectedStoreIdentity =
            Left
                ( LifecycleContextStoreIdentityMismatch
                    expectedStoreIdentity
                    observedStoreIdentity
                )
        | otherwise = Right ()

    admitFrame current projectFrame validated = do
        contextResult <-
            Context.validateLifecycleContext
                installedProject
                installedProject
                supplied
        case contextResult of
            Left failure ->
                pure (Left (LifecycleContextBinaryContextError failure))
            Right _ ->
                case
                    mintValidatedLifecycleContext
                        plan
                        root
                        store
                        current
                        projectFrame
                        validated
                of
                    Left failure -> pure (Left failure)
                    Right admitted -> Right <$> use admitted
