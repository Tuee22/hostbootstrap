module ForgeWallReceiptAndAuthority where

import HostBootstrap.Wsl2.GlobalWall (WallAuthority, WallReceipt)

receipt :: WallReceipt owner spec reservation acknowledged fence
receipt = WallReceipt undefined

authority :: WallAuthority owner spec reservation acknowledged fence
authority = WallAuthority undefined
