module ImportAcquisitionJournalAdmission where

-- The lower Session opener is callable only with this package-private witness.
-- Public clients cannot import the hidden admission module that owns it.
import HostBootstrap.Lifecycle.Plan
