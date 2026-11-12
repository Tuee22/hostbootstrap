{-# LANGUAGE OverloadedStrings #-}

module EscapeWallReservation where

import HostBootstrap.Wsl2.GlobalWall

data Outside

escape ::
    WallOwner owner -> WallSpec spec -> WallFence fence ->
    Either WallModelError (WallReservation owner spec Outside Outside fence)
escape owner spec fence =
    withWallReservation owner spec "reservation" "receipt" fence id
