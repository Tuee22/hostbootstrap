{-# LANGUAGE OverloadedStrings #-}

-- A public client cannot construct the journal-bound reservation.
module ForgeProviderWallReservation where

import HostBootstrap.Cluster.Budget (ProviderWallReservation)

forge :: ProviderWallReservation scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence
forge = ProviderWallReservation "plan" "operation" "session" 7 3 1
