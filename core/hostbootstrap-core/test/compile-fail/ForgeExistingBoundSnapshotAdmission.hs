module ForgeExistingBoundSnapshotAdmission where

-- Public reverse-root kernels cannot expose their hidden admission constructor.
import HostBootstrap.Lifecycle.Mode (ExistingBoundSnapshotAdmission)

forgedAdmission = ExistingBoundSnapshotAdmission
