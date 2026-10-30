module ForgeAcquisitionJournalAdmission where

-- A raw-admission refusal also requires the public kernel's witness to remain
-- unconstructible. Its real constructor belongs to the hidden plan module.
import HostBootstrap.Lifecycle.Session (AcquisitionJournalAdmission)

forgedAdmission = AcquisitionJournalAdmission
