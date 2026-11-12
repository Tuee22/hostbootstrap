module TransposeShippedAuthorityLinkTarget (forge) where
import HostBootstrap.Ownership.Shipped (ShippedAuthorityPath, ShippedLinkTargetPath, ShippedTargetPath, ShippedAct (ShipObserveObject), ShippedOwnership, mkShippedOwnership)
import HostBootstrap.Protected (RecordKey)
forge :: ShippedAuthorityPath -> ShippedLinkTargetPath -> ShippedTargetPath -> RecordKey -> ShippedOwnership
forge _authority link target key = mkShippedOwnership link key target ShipObserveObject
