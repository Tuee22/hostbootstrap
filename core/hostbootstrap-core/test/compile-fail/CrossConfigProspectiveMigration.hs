module CrossConfigProspectiveMigration where

import Data.List.NonEmpty (NonEmpty)
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
import HostBootstrap.ProjectPlan (PlanDraft)
import HostBootstrap.Protected (ProtectedSession)

crossConfig session project profile bound codec wire config drafts =
    withProspectiveMigrationPlan session project profile bound codec wire config drafts (\_ _ _ -> pure (Right ()))

wireIdentity :: VerifiedConfigWire (Production projectId) wireDigest firstConfigId -> VerifiedConfigWire (Production projectId) wireDigest firstConfigId
wireIdentity = id

-- The explicit signature fixes distinct config identities at the join.
badJoin ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    ProjectUpMigrationProfile projectId oldSpec oldPlan broker ->
    BoundRunLease (Production projectId) oldSpec oldPlan broker ->
    ProjectCodec (Production projectId) newSpec cfg ->
    VerifiedConfigWire (Production projectId) wireDigest firstConfigId ->
    ValidatedConfig (Production projectId) newSpec secondConfigId (cfg (Production projectId)) ->
    NonEmpty (PlanDraft (Production projectId) newSpec (cfg (Production projectId))) ->
    IO (Either ModeError ())
badJoin session project profile bound codec wire config drafts =
    crossConfig session project profile bound codec wire config drafts
