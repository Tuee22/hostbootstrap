{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Exclusive ownership of one harness run.

This is the production implementation of the engine's
'HostBootstrap.Harness.HarnessRunOwnership' seam, and the replacement for the
bare @createDirectory@ lock whose crash left both @.test_data@ and a
@.test_data.hostbootstrap-run-owner@ directory behind with nothing to
distinguish a dead predecessor from a live one — an operator had to remove both
by hand.

In order, a run now:

0. takes the project-wide **run-liveness lock** and holds it for the whole run.
   This is the § EE clause-1 primitive applied to the run itself, and it is what
   makes the sweep in step 1 sound: without it, a *live* run's lease is
   indistinguishable from an abandoned one, so a concurrent starter would sweep
   the live owner's lease, release its mode, and take ownership — two runs then
   both believe they own the project. The kernel releases this lock when the
   process dies, so a genuinely dead predecessor never blocks the next run;
1. sweeps every abandoned run recorded in the protected store. A lease that
   never bound a plan is closed after the protected proof that it recorded no
   effect; a lease that *did* bind one names the exact run that needs operator
   recovery, and no new run starts;
2. takes the project-wide Harness mode and this run's lease in one protected
   compare-and-swap, so a Production opener cannot interleave between the
   safety recheck and ownership;
3. takes ownership of its own generation @.test_data\/\<runId\>@ through
   "HostBootstrap.Harness.DataRoot", which holds all four § EE clauses for that
   directory inside one protected entry: the durable origin record naming the
   exact prior identity-or-absence is published /before/ the directory is
   created, and the created directory's own kernel identity is then bound to
   the receipt. The shared @.test_data@ parent is scaffolding — created if
   missing, never owned and never removed — so a run releases exactly the
   generation its generative @runId@ names and can never remove another run's
   (§ Z);
4. takes ownership of its generated sibling @\<project\>.dhall@ through
   "HostBootstrap.Harness.GeneratedConfig" — the same four clauses over a file,
   replacing the @\<config\>.hostbootstrap-test-owner@ lock directory that held
   none of them;
5. on exit closes the lease and releases the mode, and removes the directory and
   the config only after re-observing their exact kernel identities. A
   @.test_data@ (or @.data@) the run merely found is preserved, and an object
   that was /replaced/ under the run is reported as a conflict and left intact
   (§ Z).

Both owned objects are also what the __sweep__ resolves. An abandoned unbound
run's data root and generated config are reclaimed from their durable origin
records before its lease closes; an abandoned __bound__ run is now classified
and, when its records prove it acquired nothing, closed — where it previously
could only be named in a refusal an operator had to resolve by deleting
protected records by hand.
-}
module HostBootstrap.Harness.Ownership (
    OwnedHarnessRoot,
    withOwnedHarnessRoot,
    ownedHarnessConfigPath,
    acquireOwnedRunConfig,
    releaseOwnedRunConfig,
    protectedProjectRunOwnership,
    protectedRunOwnership,
    harnessAuthorityStoreDirectory,
) where

import Control.Exception.Safe (generalBracket)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Authority (
    InstalledProject,
    ProjectVerb (ProjectUp),
    VerbUp,
    authorityErrorMessage,
    installedProjectName,
    withInstalledProject,
 )
import HostBootstrap.Harness (
    HarnessRunCleanupFailure (..),
    HarnessRunOwnership (..),
    testDataGeneration,
 )
import HostBootstrap.Harness.DataRoot (
    DataRootError (DataRootStoreFailure),
    DataRootOwnership,
    acquireDataRoot,
    dataRootErrorMessage,
    recoverDataRoot,
    releaseDataRoot,
 )
import HostBootstrap.Harness.GeneratedConfig (
    GeneratedConfigError (GeneratedConfigStoreFailure),
    GeneratedConfigOwnership,
    acquireGeneratedConfig,
    generatedConfigErrorMessage,
    recoverGeneratedConfig,
    releaseGeneratedConfig,
 )
import HostBootstrap.Harness.Identity (ObjectIdentityBackend)
import HostBootstrap.Harness.Identity.Native (nativeObjectIdentityBackend)
import HostBootstrap.Lifecycle.Mode (
    HarnessBoundRecovery (HarnessOpenRevisionRecovery, HarnessPersistedClosing),
    HarnessRoot,
    IncompleteLeaseKind (IncompleteBound, IncompleteUnbound),
    ModeError (ModeOwnershipUnresolved, ModeRecoveryRequired, ModeStoreFailure),
    OpenRevisionKind (CompletedMigration, IncompleteMigration, NormalRevision),
    RunId,
    VerifiedIncompleteRunLease,
    classifyAbandonedBoundRun,
    closeHarnessRun,
    harnessPreconditions,
    harnessRootRunId,
    incompleteRunLeaseKind,
    incompleteRunLeaseRun,
    modeErrorMessage,
    openRevisionKind,
    recoverAbandonedHarnessRuns,
    runIdText,
    verifyNoProjectResourcesAcquired,
    withHarnessRoot,
 )
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    canonicalProjectRootPath,
 )
import HostBootstrap.Protected (
    ProtectedError,
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
    withProtectedEntry,
    withRunLiveness,
 )
import System.FilePath ((<.>), (</>))

-- | Where the protected authority store lives, relative to the state root.
harnessAuthorityStoreDirectory :: FilePath
harnessAuthorityStoreDirectory = ".hostbootstrap" </> "authority"

{- | Build the run-ownership bracket for one project.

The typed constructor is the production boundary: its project identity is the
one installed by the project config family, and the value supplied to the body
contains the exact generative root acquired by 'withHarnessRoot'.
-}
data OwnedHarnessRoot projectId where
    OwnedHarnessRoot ::
        ProtectedStore ->
        InstalledProject projectId ->
        -- | the sibling config path, derived from installed project identity
        FilePath ->
        HarnessRoot projectId runId brokerGeneration VerbUp ->
        OwnedHarnessRoot projectId

withOwnedHarnessRoot ::
    OwnedHarnessRoot projectId ->
    ( forall runId brokerGeneration.
      ProtectedStore ->
      InstalledProject projectId ->
      HarnessRoot projectId runId brokerGeneration VerbUp ->
      result
    ) ->
    result
withOwnedHarnessRoot (OwnedHarnessRoot store project _ root) use =
    use store project root

{- | The sibling @\<project\>.dhall@ this run generates. It is derived from the
installed project identity and the directory the binary sits in — the same
derivation the harness precondition uses — so a caller cannot name a different
file as "the generated config".
-}
ownedHarnessConfigPath :: OwnedHarnessRoot projectId -> FilePath
ownedHarnessConfigPath (OwnedHarnessRoot _ _ path _) = path

{- | Install this run's generated config under all four § EE clauses. An object
already at the path is refused before any mutation — that refusal is the
authoritative "a production config already exists" one, and it runs here, inside
the ownership bracket and therefore /after/ the abandoned-run sweep.
-}
acquireOwnedRunConfig ::
    OwnedHarnessRoot projectId ->
    -- | the exact bytes to install
    ByteString ->
    IO (Either String GeneratedConfigOwnership)
acquireOwnedRunConfig (OwnedHarnessRoot store project path root) payload = do
    outcome <-
        inConfigEntry store $ \session ->
            case generatedConfigKey project (harnessRootRunId root) of
                Left failure -> pure (Left failure)
                Right key -> acquireGeneratedConfig identityBackend session key path payload
    pure (either (Left . Text.unpack . generatedConfigErrorMessage) Right outcome)

{- | Give the generated config back. It is unlinked only after its exact kernel
identity and payload are re-observed; an edited or replaced file is a reported
conflict and is left intact.
-}
releaseOwnedRunConfig ::
    OwnedHarnessRoot projectId ->
    GeneratedConfigOwnership ->
    IO (Either String ())
releaseOwnedRunConfig (OwnedHarnessRoot store project _ root) owned = do
    outcome <-
        inConfigEntry store $ \session ->
            case generatedConfigKey project (harnessRootRunId root) of
                Left failure -> pure (Left failure)
                Right key ->
                    fmap
                        (fmap (const ()))
                        (releaseGeneratedConfig identityBackend session key owned)
    pure (either (Left . Text.unpack . generatedConfigErrorMessage) Right outcome)

protectedProjectRunOwnership ::
    InstalledProject projectId ->
    CanonicalProjectRoot rootScope rootId ->
    -- | the directory a sibling production config would occupy
    FilePath ->
    -- | the shared @.test_data@ parent the run's generation sits under
    FilePath ->
    HarnessRunOwnership (OwnedHarnessRoot projectId)
protectedProjectRunOwnership project stateRoot siblingDirectory dataParent =
    HarnessRunOwnership
        ( ownProjectRun
            project
            ( canonicalProjectRootPath stateRoot
                </> harnessAuthorityStoreDirectory
                </> Text.unpack (installedProjectName project)
            )
            siblingDirectory
            dataParent
        )

{- | Text-only compatibility wrapper for low-level ownership tests. It still
acquires a real typed root and exposes only that root's descriptive run name;
it cannot mint config authority and is not used by the command path.
-}
protectedRunOwnership ::
    -- | the installed project name
    Text ->
    -- | the state root the protected store and data root sit under
    FilePath ->
    -- | the directory a sibling production config would occupy
    FilePath ->
    -- | the shared @.test_data@ parent the run's generation sits under
    FilePath ->
    HarnessRunOwnership Text
protectedRunOwnership projectName stateRoot siblingDirectory dataParent =
    HarnessRunOwnership (ownRun projectName stateRoot siblingDirectory dataParent)

ownRun ::
    forall result.
    Text ->
    FilePath ->
    FilePath ->
    FilePath ->
    (Text -> IO result) ->
    IO (Either String (result, Maybe HarnessRunCleanupFailure))
ownRun projectName stateRoot siblingDirectory dataParent body =
    case withInstalledProject projectName $ \project ->
        ownProjectRun
            project
            (stateRoot </> harnessAuthorityStoreDirectory)
            siblingDirectory
            dataParent
            ( \owned ->
                withOwnedHarnessRoot owned $ \_store _project root ->
                    body (runIdText (harnessRootRunId root))
            ) of
        Left failure -> pure (Left (refused (authorityErrorMessage failure)))
        Right action -> action

ownProjectRun ::
    forall projectId result.
    InstalledProject projectId ->
    FilePath ->
    FilePath ->
    FilePath ->
    (OwnedHarnessRoot projectId -> IO result) ->
    IO (Either String (result, Maybe HarnessRunCleanupFailure))
ownProjectRun project storeRoot siblingDirectory dataParent body = do
    opened <- openProtectedStore storeRoot
    case opened of
        Left failure -> pure (Left (storeRefused failure))
        Right store -> do
            -- Held across the sweep AND the whole run: the sweep may only
            -- reclaim leases whose owners are dead, and this lock is the
            -- only thing that can tell it so.
            held <-
                withRunLiveness store (installedProjectName project) (owning store)
            pure $ case held of
                Left failure -> Left (storeRefused failure)
                Right Nothing -> Left (refused liveRunHoldsProject)
                Right (Just inner) -> inner
  where
    configPath :: FilePath
    configPath =
        siblingDirectory </> Text.unpack (installedProjectName project) <.> "dhall"
    owning ::
        ProtectedStore ->
        IO (Either String (result, Maybe HarnessRunCleanupFailure))
    owning store = do
        swept <-
            recoverAbandonedHarnessRuns
                store
                project
                (reclaimAbandonedRun store project dataParent configPath)
                (resolveBoundRun store project dataParent configPath)
        case swept of
            Left failure -> pure (Left (modeRefused failure))
            Right proof -> do
                outcome <-
                    withHarnessRoot
                        store
                        project
                        ProjectUp
                        -- The suite's own probe has already refused a live
                        -- production cluster; this half rechecks the sibling
                        -- config inside the same entry that takes the mode.
                        (harnessPreconditions project siblingDirectory (pure False))
                        proof
                        (runOwned store)
                pure (either (Left . modeRefused) Right outcome)
    runOwned ::
        forall runId brokerGeneration.
        ProtectedStore ->
        HarnessRoot projectId runId brokerGeneration VerbUp ->
        IO (Either ModeError (result, Maybe HarnessRunCleanupFailure))
    runOwned store root = do
        let run = harnessRootRunId root
            -- § Z: the run owns @.test_data/<runId>@, not the shared parent.
            generation = testDataGeneration dataParent (runIdText run)
        (outcome, cleanupFailure) <-
            generalBracket
                (takeDataRoot store project run generation)
                ( \started _ -> case started of
                    Left _ -> pure Nothing
                    Right receipt -> releaseRun store run receipt
                )
                ( \started -> case started of
                    Left failure ->
                        pure
                            ( Left
                                ( ModeOwnershipUnresolved
                                    (runIdText run)
                                    (dataRootErrorMessage failure)
                                )
                            )
                    Right _ ->
                        Right <$> body (OwnedHarnessRoot store project configPath root)
                )
        pure (fmap (\result -> (result, cleanupFailure)) outcome)
    releaseRun store run receipt = do
        released <- giveUpDataRoot store project run receipt
        case released of
            Left failure ->
                pure
                    ( Just
                        (HarnessDataRootCleanupFailed (Text.unpack (dataRootErrorMessage failure)))
                    )
            Right () -> do
                closed <- closeRun store run
                pure $ case closed of
                    Left reason -> Just (HarnessModeCloseFailed reason)
                    Right () -> Nothing
    closeRun store run = do
        closed <-
            withProtectedEntry store $ \session -> do
                evidence <- verifyNoProjectResourcesAcquired session project run
                case evidence of
                    Left failure -> pure (Right (Left failure))
                    Right proof -> do
                        outcome <- closeHarnessRun session project run proof
                        pure (Right outcome)
        pure $ case closed of
            Left failure -> Left (Text.unpack (protectedErrorMessage failure))
            Right (Left failure) -> Left (Text.unpack (modeErrorMessage failure))
            Right (Right ()) -> Right ()

{- | Reclaim an abandoned run's two owned filesystem objects from their durable
origin records. For an unbound lease the sweep runs this /before/ closing the
lease, so whatever the dead run acquired outside the lease is reclaimed while it
is still identifiable.

The recorded origin is the authority in both cases: a data-root generation that
run created is removed and the recorded absence restored, while a directory it
merely found is left alone; a generated config is unlinked only when both its
bound kernel identity and its recorded payload still match. A conflict — the
path now holds a different object, or bytes the record does not name — is
reported and blocks the new run rather than deleting a stranger's file.
-}
reclaimAbandonedRun ::
    ProtectedStore ->
    InstalledProject projectId ->
    -- | the shared @.test_data@ parent
    FilePath ->
    -- | the sibling config path the run would have generated
    FilePath ->
    VerifiedIncompleteRunLease projectId ->
    IO (Either ModeError ())
reclaimAbandonedRun store project dataParent configPath lease = do
    reclaimedData <-
        reclaimAbandonedDataRoot
            store
            project
            run
            (testDataGeneration dataParent (runIdText run))
    case reclaimedData of
        Left failure -> pure (Left (unresolved (dataRootErrorMessage failure)))
        Right () -> do
            reclaimedConfig <- reclaimAbandonedConfig store project run configPath
            pure $ case reclaimedConfig of
                Left failure -> Left (unresolved (generatedConfigErrorMessage failure))
                Right () -> Right ()
  where
    run = incompleteRunLeaseRun lease
    unresolved = ModeOwnershipUnresolved (runIdText run)

{- | The bound-lease fold callback.

A bound lease reached a plan, so it /may/ own real lifecycle resources — and
until this landed it was simply reported: the sweep's recheck refused the new run
and named the run, with nothing able to act on that name. An operator's only
route forward was deleting the run's protected records by hand.

It now classifies the lease's durable invocation record and resolves the one
branch it can prove is safe: an ordinary Open revision whose records show that
the run acquired __nothing__. 'verifyNoProjectResourcesAcquired' is that proof
and it is the sprint's own producer for the true-pre-effect branch — a single
effect-shaped record refuses, so partial @up@ work can never be relabelled as a
refusal that preceded acquisition. That branch reclaims the run's two owned
objects and closes its lease and mode, which is exactly the interrupted-run case
the reservation exists for.

Every other branch stays fail-closed and names why: a persisted @Closing@ epoch
and either migration revision need the close-journal and migration resumption
Sprint 16.6 owns, and a run that /did/ record effects needs the recursive
teardown forest, not a lease close.
-}
resolveBoundRun ::
    ProtectedStore ->
    InstalledProject projectId ->
    FilePath ->
    FilePath ->
    VerifiedIncompleteRunLease projectId ->
    IO (Either ModeError ())
resolveBoundRun store project dataParent configPath lease =
    case incompleteRunLeaseKind lease of
        IncompleteUnbound -> pure (Right ())
        IncompleteBound _ _ -> do
            classified <-
                runInEntry store (\session -> classifyAbandonedBoundRun session project lease)
            case classified of
                Left failure -> pure (Left failure)
                Right (HarnessPersistedClosing epoch) ->
                    pure (Left (needsOperator ("a persisted closing epoch " <> showEpoch epoch)))
                Right (HarnessOpenRevisionRecovery revision) ->
                    case openRevisionKind revision of
                        IncompleteMigration key ->
                            pure (Left (needsOperator ("an incomplete migration " <> key)))
                        CompletedMigration key ->
                            pure (Left (needsOperator ("a completed migration " <> key)))
                        NormalRevision -> closeIfNothingAcquired
  where
    run = incompleteRunLeaseRun lease
    needsOperator detail =
        ModeRecoveryRequired (runIdText run <> " carries " <> detail)
    showEpoch = Text.pack . show
    closeIfNothingAcquired = do
        -- The proof is taken first: nothing is reclaimed and no lease is closed
        -- until the run's own records show it acquired nothing.
        proved <-
            runInEntry store (\session -> verifyNoProjectResourcesAcquired session project run)
        case proved of
            Left failure -> pure (Left failure)
            Right evidence -> do
                reclaimed <- reclaimAbandonedRun store project dataParent configPath lease
                case reclaimed of
                    Left failure -> pure (Left failure)
                    Right () ->
                        runInEntry store $ \session ->
                            closeHarnessRun session project run evidence

-- | Run one recovery decision inside the store's exclusive entry.
runInEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either ModeError result)) ->
    IO (Either ModeError result)
runInEntry store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    pure $ case outcome of
        Left failure -> Left (ModeStoreFailure failure)
        Right inner -> inner

-- | The host identity backend the production bracket binds ownership to.
identityBackend :: ObjectIdentityBackend
identityBackend = nativeObjectIdentityBackend

{- | Take the data root under all four § EE clauses.  The whole
observe → record-origin → create → bind-identity sequence runs inside one
protected entry, so it cannot straddle another opener's transaction and the
kernel releases the entry if this process dies part-way through.
-}
takeDataRoot ::
    ProtectedStore ->
    InstalledProject projectId ->
    RunId ->
    FilePath ->
    IO (Either DataRootError DataRootOwnership)
takeDataRoot store project run path =
    inEntry store $ \session ->
        case dataRootOriginKey project run of
            Left failure -> pure (Left failure)
            Right key -> acquireDataRoot identityBackend session key path

{- | Give the data root back.  A directory this run created is removed only
after its exact kernel identity is re-observed; one the run merely found is
preserved; a replaced directory is a conflict and is left intact.  A conflict
here is reported, not raised: the run's report card already reflects the body's
outcome, and refusing to remove a stranger's directory is the correct end state.
-}
giveUpDataRoot ::
    ProtectedStore ->
    InstalledProject projectId ->
    RunId ->
    DataRootOwnership ->
    IO (Either DataRootError ())
giveUpDataRoot store project run owned =
    inEntry store $ \session ->
        case dataRootOriginKey project run of
            Left failure -> pure (Left failure)
            Right key ->
                fmap (fmap (const ())) (releaseDataRoot identityBackend session key owned)

{- | Resolve an abandoned run's data-root record: restore the recorded absence,
or leave a recorded pre-existing directory alone.  Exposed to the sweep's fold
so a crashed predecessor's generation does not survive the next run.
-}
reclaimAbandonedDataRoot ::
    ProtectedStore ->
    InstalledProject projectId ->
    RunId ->
    FilePath ->
    IO (Either DataRootError ())
reclaimAbandonedDataRoot store project run path =
    inEntry store $ \session ->
        case dataRootOriginKey project run of
            Left failure -> pure (Left failure)
            Right key ->
                fmap (fmap (const ())) (recoverDataRoot identityBackend session key path)

{- | Resolve an abandoned run's generated-config record: unlink exactly the file
that run installed, or refuse an edited or replaced one and leave it intact.
This is what makes the interrupted-run config self-healing, and it is reachable
only because the existence refusal now runs after the sweep.
-}
reclaimAbandonedConfig ::
    ProtectedStore ->
    InstalledProject projectId ->
    RunId ->
    FilePath ->
    IO (Either GeneratedConfigError ())
reclaimAbandonedConfig store project run path =
    inConfigEntry store $ \session ->
        case generatedConfigKey project run of
            Left failure -> pure (Left failure)
            Right key ->
                fmap
                    (fmap (const ()))
                    (recoverGeneratedConfig identityBackend session key path)

{- | Run a data-root decision inside the store's exclusive entry, flattening the
store's own refusal into the data-root failure vocabulary.
-}
inEntry ::
    ProtectedStore ->
    ( forall session.
      ProtectedSession session ->
      IO (Either DataRootError result)
    ) ->
    IO (Either DataRootError result)
inEntry store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    pure $ case outcome of
        Left failure -> Left (DataRootStoreFailure failure)
        Right inner -> inner

dataRootOriginKey ::
    InstalledProject projectId -> RunId -> Either DataRootError RecordKey
dataRootOriginKey project run =
    case mkRecordKey ("dataroot." <> installedProjectName project <> "." <> runIdText run) of
        Left failure -> Left (DataRootStoreFailure failure)
        Right key -> Right key

{- | Run a generated-config decision inside the store's exclusive entry,
flattening the store's own refusal into that protocol's failure vocabulary.
-}
inConfigEntry ::
    ProtectedStore ->
    ( forall session.
      ProtectedSession session ->
      IO (Either GeneratedConfigError result)
    ) ->
    IO (Either GeneratedConfigError result)
inConfigEntry store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    pure $ case outcome of
        Left failure -> Left (GeneratedConfigStoreFailure failure)
        Right inner -> inner

generatedConfigKey ::
    InstalledProject projectId -> RunId -> Either GeneratedConfigError RecordKey
generatedConfigKey project run =
    case mkRecordKey ("config." <> installedProjectName project <> "." <> runIdText run) of
        Left failure -> Left (GeneratedConfigStoreFailure failure)
        Right key -> Right key

{- | The refusal a competing run gets while another process still holds the
project. It is a *stated* exclusion, not a sweep that quietly takes ownership.
-}
liveRunHoldsProject :: Text
liveRunHoldsProject =
    "another test run is already in progress for this project (its liveness lock is held); \
    \refusing to start a second one"

refused :: Text -> String
refused reason = "test run refused: " <> Text.unpack reason

modeRefused :: ModeError -> String
modeRefused = refused . modeErrorMessage

storeRefused :: ProtectedError -> String
storeRefused = refused . protectedErrorMessage
