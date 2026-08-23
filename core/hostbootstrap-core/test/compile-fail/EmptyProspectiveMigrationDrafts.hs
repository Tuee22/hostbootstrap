module EmptyProspectiveMigrationDrafts where

import HostBootstrap.Authority (InstalledProjectIdentity)
import HostBootstrap.Config.Class (ProjectCodec)
import HostBootstrap.Config.Schema (ValidatedConfig, VerifiedConfigWire)
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Lifecycle.Mode
    ( BoundRunLease
    , ModeError
    , ProjectUpMigrationProfile
    , withProspectiveMigrationPlan
    )
import HostBootstrap.Protected (ProtectedSession)

emptyCandidate session project profile bound codec wire config =
    withProspectiveMigrationPlan session project profile bound codec wire config [] (\_ _ _ -> pure (Right ()))
