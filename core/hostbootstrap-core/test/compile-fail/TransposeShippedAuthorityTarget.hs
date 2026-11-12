module TransposeShippedAuthorityTarget (forge) where
import HostBootstrap.Ownership.Shipped (ShippedAuthorityPath, ShippedTargetPath, ShippedAct, ShippedOwnership, mkShippedOwnership)
import HostBootstrap.Protected (RecordKey)
forge :: ShippedAuthorityPath -> ShippedTargetPath -> RecordKey -> ShippedAct -> ShippedOwnership
forge _authority target key act = mkShippedOwnership target key target act
