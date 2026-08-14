module OpenCommandReservation where

-- Reservation construction and replay policy remain entirely behind the
-- public opaque CommandAuthority surface.
import HostBootstrap.Authority
    ( CommandReservation
    , childCommandReservationKernel
    , commandReservationKernel
    , reserveCommandInvocationKernel
    )

hidden :: ()
hidden = ()
