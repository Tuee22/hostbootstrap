module UpdateShippedDirectoryLease where

import HostBootstrap.Ownership.Shipped (ShippedDirectoryLease)

alter :: ShippedDirectoryLease lease -> ShippedDirectoryLease lease
alter lease = lease { directoryLeaseRow = undefined }
