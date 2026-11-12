module TransposeShippedObjectLinkTarget (forge) where
import HostBootstrap.Ownership.Shipped (ShippedLinkTargetPath, ShippedTargetPath, ShippedAct (ShipTakeSymbolicLink))
forge :: ShippedLinkTargetPath -> ShippedTargetPath -> ShippedAct
forge _link target = ShipTakeSymbolicLink target
