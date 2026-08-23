module ResourceRecordTombstoneAsReceipt where

import HostBootstrap.Reconcile

bad bundle =
    withVerifiedResourceRecordBundle bundle id
        (\_resource _generation _operation _version _phase _adapter _bytes -> ())
