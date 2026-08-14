{- | Every member of the direct-Colima provider package must come from the
same exact admitted project plan.
-}
module CrossPlanColimaConsumer where

import HostBootstrap.Cluster.Budget
  ( BudgetPartition,
    ColimaProvider,
    ProviderBudgetCapability,
    ProviderWallReservation,
    ProviderWallSpec,
    ValidatedBudget,
    VerifiedWorkloadFit,
  )
import HostBootstrap.Ensure.Colima (prepareColimaWallCall)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.ProjectPlan
  ( DerivedTopology,
    PlannedResource,
    ProjectPlan,
    ProviderResource,
  )
import HostBootstrap.Reconcile
  ( Observed,
    ReconcileError,
    ResourceHandle,
    Unclassified,
  )

data Scope
data SpecificationDigest
data ConfigurationIdentity
data Configuration scope
data ColimaPlan
data ForeignProviderPlan
data ForeignTopologyPlan
data ForeignPartitionPlan
data ForeignReservationPlan
data ProviderResourceIdentity
data ProviderFrame
data BudgetIdentity
data CapabilityIdentity
data WallSpecificationIdentity
data WorkloadSetIdentity
data PartitionIdentity
data ReservationIdentity
data Fence

type ExactPlan plan =
  ProjectPlan Scope SpecificationDigest plan ConfigurationIdentity Configuration

type Provider plan =
  PlannedResource Scope plan ProviderResourceIdentity ProviderResource ProviderFrame

type ObservedProvider plan =
  ResourceHandle
    Scope
    plan
    ProviderResourceIdentity
    ProviderResource
    Unclassified
    Observed

type Budget plan = ValidatedBudget Scope plan BudgetIdentity

type Capability plan =
  ProviderBudgetCapability Scope plan ColimaProvider CapabilityIdentity

type Wall plan =
  ProviderWallSpec
    Scope
    plan
    BudgetIdentity
    ColimaProvider
    CapabilityIdentity
    WallSpecificationIdentity

type Fit plan =
  VerifiedWorkloadFit
    Scope
    plan
    BudgetIdentity
    ColimaProvider
    CapabilityIdentity
    WallSpecificationIdentity
    WorkloadSetIdentity

type Partition plan =
  BudgetPartition
    Scope
    plan
    BudgetIdentity
    ColimaProvider
    CapabilityIdentity
    WallSpecificationIdentity
    WorkloadSetIdentity
    PartitionIdentity

type Reservation plan =
  ProviderWallReservation
    Scope
    plan
    BudgetIdentity
    ColimaProvider
    CapabilityIdentity
    WallSpecificationIdentity
    WorkloadSetIdentity
    PartitionIdentity
    ReservationIdentity
    Fence

discardPrepared :: Functor functor => functor value -> functor ()
discardPrepared = fmap (const ())

crossPlanProviderResource ::
  ExactPlan ColimaPlan ->
  Provider ForeignProviderPlan ->
  ObservedProvider ForeignProviderPlan ->
  DerivedTopology Scope ColimaPlan ->
  Budget ColimaPlan ->
  Capability ColimaPlan ->
  Wall ColimaPlan ->
  Fit ColimaPlan ->
  Partition ColimaPlan ->
  Reservation ColimaPlan ->
  PreparedGate ->
  IO (Either ReconcileError ())
crossPlanProviderResource plan provider handle topology budget capability wall fit partition reservation gate =
  discardPrepared
    <$> prepareColimaWallCall plan provider handle topology budget capability wall fit partition reservation gate

crossPlanTopology ::
  ExactPlan ColimaPlan ->
  Provider ColimaPlan ->
  ObservedProvider ColimaPlan ->
  DerivedTopology Scope ForeignTopologyPlan ->
  Budget ColimaPlan ->
  Capability ColimaPlan ->
  Wall ColimaPlan ->
  Fit ColimaPlan ->
  Partition ColimaPlan ->
  Reservation ColimaPlan ->
  PreparedGate ->
  IO (Either ReconcileError ())
crossPlanTopology plan provider handle topology budget capability wall fit partition reservation gate =
  discardPrepared
    <$> prepareColimaWallCall plan provider handle topology budget capability wall fit partition reservation gate

crossPlanPartition ::
  ExactPlan ColimaPlan ->
  Provider ColimaPlan ->
  ObservedProvider ColimaPlan ->
  DerivedTopology Scope ColimaPlan ->
  Budget ColimaPlan ->
  Capability ColimaPlan ->
  Wall ColimaPlan ->
  Fit ColimaPlan ->
  Partition ForeignPartitionPlan ->
  Reservation ColimaPlan ->
  PreparedGate ->
  IO (Either ReconcileError ())
crossPlanPartition plan provider handle topology budget capability wall fit partition reservation gate =
  discardPrepared
    <$> prepareColimaWallCall plan provider handle topology budget capability wall fit partition reservation gate

crossPlanReservation ::
  ExactPlan ColimaPlan ->
  Provider ColimaPlan ->
  ObservedProvider ColimaPlan ->
  DerivedTopology Scope ColimaPlan ->
  Budget ColimaPlan ->
  Capability ColimaPlan ->
  Wall ColimaPlan ->
  Fit ColimaPlan ->
  Partition ColimaPlan ->
  Reservation ForeignReservationPlan ->
  PreparedGate ->
  IO (Either ReconcileError ())
crossPlanReservation plan provider handle topology budget capability wall fit partition reservation gate =
  discardPrepared
    <$> prepareColimaWallCall plan provider handle topology budget capability wall fit partition reservation gate
