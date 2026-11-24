{-# LANGUAGE GADTs #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Private representation shared only with the catalog's test fixture.
module HostBootstrap.Lifecycle.RootedPlan.Internal (
    RootedPlanCatalog (..),
    ParentFrameId (..),
    ChildFrameId (..),
    RawLiftRoute (..),
    StrippedLiftRoute (..),
    ConfigDigest (..),
    PayloadDigest (..),
) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import HostBootstrap.Authority.Kernel (RootInvocationAuthority)
import HostBootstrap.Config.Class (ProjectCfg)
import HostBootstrap.Lifecycle.Context.Internal (ValidatedLifecycleContext)
import HostBootstrap.Lifecycle.FrameRole (ChildFrameId (..), ParentFrameId (..))
import HostBootstrap.Lifecycle.Plan (PlanDigestBinding, ProjectPlan)
import HostBootstrap.Lift.Context (LiftContext)
import HostBootstrap.ProjectPlan.Construct.Internal (FinalizedProjectSpec)
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)
import HostBootstrap.Step (OperationKey)

{- | The route and digest roles one admitted descent edge carries beside its
parent and child frame roles ('ParentFrameId', 'ChildFrameId'). Each is its own
type, so a transposed raw and stripped route, or configuration and payload
digest, is a type error rather than a value an edge recheck might miss.
-}

-- | The plan-owned lift of one edge, including any staged config delivery.
newtype RawLiftRoute = RawLiftRoute LiftContext

-- | The same one-layer lift with its staged config delivery removed.
newtype StrippedLiftRoute = StrippedLiftRoute LiftContext

newtype ConfigDigest = ConfigDigest Text
    deriving (Eq, Show)

newtype PayloadDigest = PayloadDigest Text
    deriving (Eq, Show)

{- | The exact recursive catalog for one root plan and one invocation broker
generation.

The base carries the root's retained evidence; every extension carries one
admitted descent edge together with the complete target evidence a later
package or storeless executor needs.  The four indices are nominal, so a
catalog admitted for one scope, root plan, broker generation, or construction
cannot be relabelled as another with 'coerce'.
-}
data RootedPlanCatalog scope rootPlanId brokerGeneration catalogId where
    RootedPlanCatalogRoot ::
        (ProjectCfg cfg) =>
        FinalizedProjectSpec scope specDigest cfg ->
        RootInvocationAuthority scope brokerGeneration verb ->
        ProjectPlan scope specDigest rootPlanId rootConfigId cfg ->
        CurrentFrame scope rootPlanId rootFrame ->
        ValidatedLifecycleContext scope specDigest rootPlanId rootConfigId rootFrame ->
        RootedPlanCatalog scope rootPlanId brokerGeneration catalogId
    RootedPlanCatalogDescent ::
        (ProjectCfg cfg) =>
        RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
        ProjectPlan scope specDigest childPlanId childConfigId cfg ->
        PlanDigestBinding scope specDigest childPlanDigest childPlanId ->
        CurrentFrame scope childPlanId childFrame ->
        ParentFrameId ->
        ChildFrameId ->
        RawLiftRoute ->
        StrippedLiftRoute ->
        ByteString ->
        ConfigDigest ->
        PayloadDigest ->
        [OperationKey] ->
        RootedPlanCatalog scope rootPlanId brokerGeneration catalogId

type role RootedPlanCatalog nominal nominal nominal nominal

