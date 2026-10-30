module EmptyProspectiveMigrationDrafts where

import HostBootstrap.Authority (InstalledProjectIdentity)
import HostBootstrap.Config.Class (ProjectCodec)
import HostBootstrap.Config.Schema (ValidatedConfig, VerifiedConfigWire)
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Lifecycle.Mode (
    BoundRunLease,
    ModeError,
    ProjectUpMigrationProfile,
    withProspectiveMigrationPlan,
 )
import HostBootstrap.Protected (ProtectedSession)

data Session
data Project
data OldSpecDigest
data OldPlanDigest
data BrokerGeneration
data NewSpecDigest
data ConfigDigest
data ConfigId
data Config scope

emptyCandidate ::
    ProtectedSession Session ->
    InstalledProjectIdentity Project ->
    ProjectUpMigrationProfile Project OldSpecDigest OldPlanDigest BrokerGeneration ->
    BoundRunLease (Production Project) OldSpecDigest OldPlanDigest BrokerGeneration ->
    ProjectCodec (Production Project) NewSpecDigest Config ->
    VerifiedConfigWire (Production Project) ConfigDigest ConfigId ->
    ValidatedConfig (Production Project) NewSpecDigest ConfigId (Config (Production Project)) ->
    IO (Either ModeError ())
emptyCandidate session project profile bound codec wire config =
    withProspectiveMigrationPlan session project profile bound codec wire config [] (\_ _ _ -> pure (Right ()))
