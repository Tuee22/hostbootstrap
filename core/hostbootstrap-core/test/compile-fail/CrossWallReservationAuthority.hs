{-# LANGUAGE OverloadedStrings #-}

module CrossWallReservationAuthority where

import HostBootstrap.Wsl2.GlobalWall

cross :: WallOwner owner -> WallSpec spec -> WallFence fence -> Either WallModelError ()
cross owner spec fence =
    () <$ withWallReservation owner spec "first" "first-receipt" fence (\first ->
        withWallReservation owner spec "second" "second-receipt" fence (\second ->
            let firstReceipt = admitted (claimOrResumeWall first Nothing)
                secondReceipt = admitted (claimOrResumeWall second Nothing)
             in withWallAuthority (wallReceiptRecord firstReceipt) firstReceipt (\authority ->
                    () <$ beginWallRestore (wallReceiptRecord secondReceipt) authority secondReceipt
                        (RestoreObservation ObservedAbsent ObservedAbsent ObservedAbsent))))

admitted :: Either WallModelError value -> value
admitted = either (error . show) id
