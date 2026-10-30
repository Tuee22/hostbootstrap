module OpenCommandReservation where

-- Reservation construction and consumption stay behind the opaque command authority.

import HostBootstrap.Authority (
    CommandReservation,
    commandReservationKernel,
    reserveCommandInvocationKernel,
 )
