-- Neither a plan index nor a fence index can be relabelled by coerce.
module CoerceProviderWallReservationRoles where

import Data.Coerce (coerce)
import HostBootstrap.Cluster.Budget (ProviderWallReservation)

data Scope
data PlanA
data PlanB
data Budget
data Provider
data Capability
data Wall
data Workloads
data Partition
data ReservationId
data Fence
data FenceA
data FenceB

type Reservation planId fence = ProviderWallReservation Scope planId Budget Provider Capability Wall Workloads Partition ReservationId fence

crossPlan :: Reservation PlanA Fence -> Reservation PlanB Fence
crossPlan = coerce

crossFence :: Reservation PlanA FenceA -> Reservation PlanA FenceB
crossFence = coerce
