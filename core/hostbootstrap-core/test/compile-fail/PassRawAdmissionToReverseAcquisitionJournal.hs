module PassRawAdmissionToReverseAcquisitionJournal where

-- The existing-only reverse acquisition opener is visible for package wiring,
-- but a downstream caller cannot replace its hidden admission witness.
import HostBootstrap.Lifecycle.Session (reopenExistingReverseAcquisitionJournalKernel)

reverseAcquisitionWithRawToken = reopenExistingReverseAcquisitionJournalKernel ()
