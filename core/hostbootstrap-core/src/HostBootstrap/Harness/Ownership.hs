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
   effect; a lease that *did* bind one is reopened through
   'HostBootstrap.Lifecycle.Mode.withAbandonedHarnessRun', which yields the old
   snapshot, the retained lease and mode, a @destroy@-only root, and a recovered
   close authority on a fresh broker generation. Only the branch whose records
   prove it acquired nothing is resolved; every other branch names the exact run
   that needs operator recovery, and no new run starts;
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
   through the same seam and against the same row, so the durable record one
   owner writes is the record the other reads;
5. on exit settles both owned objects and only then closes the lease and
   releases the mode. The directory and the config are removed only after
   re-observing their exact kernel identities; a @.test_data@ (or @.data@) the
   run merely found is preserved, and an object that was /replaced/ under the
   run is reported as a conflict and left intact (§ Z). Settling the config
   record here is what keeps it from outliving the lease that indexes it: the
   sweep enumerates incomplete __leases__, so a record still standing when this
   run's lease closes is unreachable forever after.

Both owned objects are also what the __sweep__ resolves. An abandoned unbound
run's data root and generated config are reclaimed from their durable origin
records before its lease closes; an abandoned __bound__ run is reopened,
classified, and — when its records prove it acquired nothing — closed under the
reopening's own close authority, where it previously could only be named in a
refusal an operator had to resolve by deleting protected records by hand.
-}
module HostBootstrap.Harness.Ownership (
    OwnedHarnessRoot,
    OwnedHarnessCloseControl,
    withOwnedHarnessRoot,
    ownedHarnessConfigPath,
    acquireOwnedRunConfig,
    releaseOwnedRunConfig,
    protectedProjectRunOwnership,
    protectedProjectRunOwnershipWithRecovery,
    RecoveredResourceExecutor (..),
    protectedRunOwnership,
    harnessAuthorityStoreDirectory,
) where

import Control.Exception.Safe (generalBracket, throwIO)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Authority (
    InstalledProjectIdentity,
    ProjectVerb (ProjectUp),
    VerbUp,
    installedProjectName,
 )
import HostBootstrap.Harness (
    HarnessRunCleanupFailure (..),
    HarnessRunOwnership (..),
    SafetyRefusal (SafetyRefusal),
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
import HostBootstrap.Harness.Ownership.Internal (
    OwnedHarnessCloseControl,
    consumeOwnedHarnessClose,
    newOwnedHarnessCloseControl,
 )
import HostBootstrap.Lifecycle.Mode (
    AbandonedHarnessRun,
    BoundRunLease,
    HarnessBoundRecovery (HarnessOpenRevisionRecovery, HarnessPersistedClosing),
    HarnessCloseRoot,
    HarnessMode,
    HarnessRoot,
    IncompleteLeaseKind (IncompleteBound, IncompleteUnbound),
    ModeError (ModeOwnershipUnresolved, ModeSessionFailure, ModeStoreFailure),
    OpenRevisionKind (CompletedMigration, IncompleteMigration, NormalRevision),
    ProjectClosureEvidence,
    ProjectModeLease,
    RecoveredForestSettled,
    RunId,
    VerifiedIncompleteRunLease,
    abandonedHarnessAdmission,
    abandonedHarnessBoundLease,
    abandonedHarnessBroker,
    abandonedHarnessCloseRoot,
    abandonedHarnessModeLease,
    abandonedHarnessRecovery,
    abandonedHarnessSnapshot,
    activateMigratedPlanConfigless,
    authorizeHarnessClose,
    closeHarnessRun,
    currentHarnessCloseRoot,
    driveRecoveredForest,
    finalizeHarnessClose,
    harnessPreconditions,
    harnessRootModeLease,
    harnessRootRunId,
    harnessRootUnboundLease,
    incompleteRunLeaseKind,
    incompleteRunLeaseRunText,
    modeErrorMessage,
    openRevisionKind,
    planSnapshotPlanDigest,
    recordRecoveredResourceReleased,
    recoverAbandonedHarnessRuns,
    recoveredDestroySettledClosure,
    resumeHarnessClose,
    runIdText,
    verifyBoundRunHasNoProjectResourcesAcquired,
    verifyNoProjectResourcesAcquired,
    withAbandonedHarnessRun,
    withCompletedMigrationRecovery,
    withHarnessRoot,
    withMigratedRecoveredProjectFrames,
    withRehydratedSnapshotResourceSet,
 )
import HostBootstrap.Lifecycle.Session (
    RehydratedOwnershipReceipt,
    RehydratedResourceHandle,
    verifyAllSessionsClosed,
 )
import HostBootstrap.Ownership.Primitive (OwnershipRow)
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    canonicalProjectRootPath,
 )
import HostBootstrap.ProjectScope (Harness)
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
        InstalledProjectIdentity projectId ->
        -- | the sibling config path, derived from installed project identity
        FilePath ->
        HarnessRoot projectId runId brokerGeneration VerbUp ->
        OwnedHarnessCloseControl projectId runId brokerGeneration ->
        OwnedHarnessRoot projectId

withOwnedHarnessRoot ::
    OwnedHarnessRoot projectId ->
    ( forall runId brokerGeneration.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      HarnessRoot projectId runId brokerGeneration VerbUp ->
      OwnedHarnessCloseControl projectId runId brokerGeneration ->
      result
    ) ->
    result
withOwnedHarnessRoot (OwnedHarnessRoot store project _ root closeControl) use =
    use store project root closeControl

{- | The sibling @\<project\>.dhall@ this run generates. It is derived from the
installed project identity and the directory the binary sits in — the same
derivation the harness precondition uses — so a caller cannot name a different
file as "the generated config".
-}
ownedHarnessConfigPath :: OwnedHarnessRoot projectId -> FilePath
ownedHarnessConfigPath (OwnedHarnessRoot _ _ path _ _) = path

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
acquireOwnedRunConfig (OwnedHarnessRoot store project path root _) payload = do
    outcome <-
        inConfigEntry store $ \session ->
            case generatedConfigKey project (runIdText (harnessRootRunId root)) of
                Left failure -> pure (Left failure)
                Right key -> acquireGeneratedConfig ownershipRow session key path payload
    pure (either (Left . Text.unpack . generatedConfigErrorMessage) Right outcome)

{- | Give the generated config back. It is unlinked only after its exact kernel
identity and payload are re-observed; an edited or replaced file is a reported
conflict and is left intact.
-}
releaseOwnedRunConfig ::
    OwnedHarnessRoot projectId ->
    GeneratedConfigOwnership ->
    IO (Either String ())
releaseOwnedRunConfig (OwnedHarnessRoot store project _ root _) owned = do
    outcome <-
        inConfigEntry store $ \session ->
            case generatedConfigKey project (runIdText (harnessRootRunId root)) of
                Left failure -> pure (Left failure)
                Right key ->
                    fmap
                        (fmap (const ()))
                        (releaseGeneratedConfig ownershipRow session key owned)
    pure (either (Left . Text.unpack . generatedConfigErrorMessage) Right outcome)

newtype RecoveredResourceExecutor = RecoveredResourceExecutor
    { executeRecoveredResource ::
        forall scope planId id brokerGeneration.
        Text ->
        Text ->
        Word64 ->
        RehydratedResourceHandle scope planId id brokerGeneration ->
        RehydratedOwnershipReceipt scope planId id brokerGeneration ->
        IO (Either Text ())
    }

refusingRecoveredResourceExecutor :: RecoveredResourceExecutor
refusingRecoveredResourceExecutor =
    RecoveredResourceExecutor $ \frame adapter revision _ _ ->
        pure
            ( Left
                ( "no recovered backend is installed for owned resource at "
                    <> frame
                    <> " ("
                    <> adapter
                    <> " v"
                    <> Text.pack (show revision)
                    <> ")"
                )
            )

protectedProjectRunOwnership ::
    InstalledProjectIdentity projectId ->
    CanonicalProjectRoot rootScope rootId ->
    -- | the directory a sibling production config would occupy
    FilePath ->
    -- | the shared @.test_data@ parent the run's generation sits under
    FilePath ->
    HarnessRunOwnership (OwnedHarnessRoot projectId)
protectedProjectRunOwnership project stateRoot siblingDirectory dataParent =
    protectedProjectRunOwnershipWithRecovery
        refusingRecoveredResourceExecutor
        project
        stateRoot
        siblingDirectory
        dataParent

protectedProjectRunOwnershipWithRecovery ::
    RecoveredResourceExecutor ->
    InstalledProjectIdentity projectId ->
    CanonicalProjectRoot rootScope rootId ->
    FilePath ->
    FilePath ->
    HarnessRunOwnership (OwnedHarnessRoot projectId)
protectedProjectRunOwnershipWithRecovery executor project stateRoot siblingDirectory dataParent =
    HarnessRunOwnership
        ( ownProjectRun
            executor
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
    -- | the executable-verified installed project
    InstalledProjectIdentity projectId ->
    -- | the state root the protected store and data root sit under
    FilePath ->
    -- | the directory a sibling production config would occupy
    FilePath ->
    -- | the shared @.test_data@ parent the run's generation sits under
    FilePath ->
    HarnessRunOwnership Text
protectedRunOwnership project stateRoot siblingDirectory dataParent =
    HarnessRunOwnership (ownRun project stateRoot siblingDirectory dataParent)

ownRun ::
    forall projectId result.
    InstalledProjectIdentity projectId ->
    FilePath ->
    FilePath ->
    FilePath ->
    IO (Either String ()) ->
    (Text -> IO result) ->
    IO (Either String (result, Maybe HarnessRunCleanupFailure))
ownRun project stateRoot siblingDirectory dataParent safety body =
    ownProjectRun
        refusingRecoveredResourceExecutor
        project
        (stateRoot </> harnessAuthorityStoreDirectory)
        siblingDirectory
        dataParent
        safety
        ( \owned ->
            withOwnedHarnessRoot owned $ \_store _project root _closeControl ->
                body (runIdText (harnessRootRunId root))
        )

ownProjectRun ::
    forall projectId result.
    RecoveredResourceExecutor ->
    InstalledProjectIdentity projectId ->
    FilePath ->
    FilePath ->
    FilePath ->
    IO (Either String ()) ->
    (OwnedHarnessRoot projectId -> IO result) ->
    IO (Either String (result, Maybe HarnessRunCleanupFailure))
ownProjectRun recoveryExecutor project storeRoot siblingDirectory dataParent safety body = do
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
                (resolveBoundRun recoveryExecutor store project dataParent configPath)
        case swept of
            Left failure -> pure (Left (modeRefused failure))
            Right proof -> do
                safe <- safety
                either (throwIO . SafetyRefusal) pure safe
                outcome <-
                    withHarnessRoot
                        store
                        project
                        ProjectUp
                        -- The suite's own probe has just refused any live
                        -- production cluster after recovery; this half rechecks
                        -- the sibling config inside the same entry that takes
                        -- the mode.
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
        -- § Z: the run owns @.test_data/<runId>@, not the shared parent.
        let generation = testDataGeneration dataParent (runIdText run)
        terminalClose <- newOwnedHarnessCloseControl
        (outcome, cleanupFailure) <-
            generalBracket
                (takeDataRoot store project run generation)
                ( \started _ -> case started of
                    Left _ -> pure Nothing
                    Right receipt -> releaseRun terminalClose receipt
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
                        Right
                            <$> body
                                ( OwnedHarnessRoot
                                    store
                                    project
                                    configPath
                                    root
                                    terminalClose
                                )
                )
        pure (fmap (\result -> (result, cleanupFailure)) outcome)
      where
        -- These two close over the exact live root, so the terminal close is
        -- authorized by *this* run's own authority rather than by its run
        -- identity: 'currentHarnessCloseRoot' is one of the two producers of
        -- 'HarnessCloseRoot', and recovery's opener is the other.
        run = harnessRootRunId root
        releaseRun terminalClose receipt = do
            released <- giveUpDataRoot store project run receipt
            case released of
                Left failure ->
                    pure
                        ( Just
                            (HarnessDataRootCleanupFailed (Text.unpack (dataRootErrorMessage failure)))
                        )
                Right () -> do
                    -- A run settles its own generated-config record here, exactly
                    -- as it settles its data root above, and for the same reason:
                    -- once the lease closes on the next line the sweep can no
                    -- longer reach this run, because the sweep enumerates
                    -- incomplete *leases*. Two states reach this point with a
                    -- record still standing — an acquire that published the origin
                    -- record and then failed to install, and a body that acquired
                    -- the config and never released it — and both are the dead
                    -- run's own state. On the ordinary path the release already
                    -- removed the file and deleted the record, so this is a no-op.
                    settled <- reclaimAbandonedConfig store project (runIdText run) configPath
                    case settled of
                        Left failure ->
                            pure
                                ( Just
                                    ( HarnessGeneratedConfigCleanupFailed
                                        (Text.unpack (generatedConfigErrorMessage failure))
                                    )
                                )
                        Right () -> do
                            closed <- runTerminalClose terminalClose
                            pure $ case closed of
                                Left reason -> Just (HarnessModeCloseFailed reason)
                                Right () -> Nothing
        runTerminalClose terminalClose =
            consumeOwnedHarnessClose
                terminalClose
                closeUnbound
                closeBound
                finalizeSettled
        closeUnbound = do
            evidence <- verifyNoProjectResourcesAcquired (harnessRootUnboundLease root)
            case evidence of
                Left failure -> pure (Left (Text.unpack (modeErrorMessage failure)))
                Right proof ->
                    closeShort
                        (currentHarnessCloseRoot root)
                        (harnessRootModeLease root)
                        proof
        closeBound ::
            forall fallbackBrokerGeneration specDigest planDigest.
            HarnessCloseRoot projectId runId fallbackBrokerGeneration ->
            ProjectModeLease projectId (HarnessMode runId) fallbackBrokerGeneration ->
            BoundRunLease
                (Harness projectId runId)
                specDigest
                planDigest
                fallbackBrokerGeneration ->
            IO (Either String ())
        closeBound closeRoot modeLease bound = do
            evidence <- verifyBoundRunHasNoProjectResourcesAcquired bound
            case evidence of
                Left failure -> pure (Left (Text.unpack (modeErrorMessage failure)))
                Right proof -> closeShort closeRoot modeLease proof
        closeShort ::
            forall fallbackBrokerGeneration.
            HarnessCloseRoot projectId runId fallbackBrokerGeneration ->
            ProjectModeLease projectId (HarnessMode runId) fallbackBrokerGeneration ->
            ProjectClosureEvidence (Harness projectId runId) ->
            IO (Either String ())
        closeShort closeRoot modeLease proof = do
            closed <-
                withProtectedEntry store $ \session -> do
                    outcome <-
                        closeHarnessRun
                            session
                            project
                            closeRoot
                            modeLease
                            proof
                    pure (Right outcome)
            pure $ case closed of
                Left failure -> Left (Text.unpack (protectedErrorMessage failure))
                Right (Left failure) -> Left (Text.unpack (modeErrorMessage failure))
                Right (Right ()) -> Right ()
        finalizeSettled authorization = do
            finalized <-
                withProtectedEntry store $ \session -> do
                    outcome <- finalizeHarnessClose session project authorization
                    pure (Right outcome)
            pure $ case finalized of
                Left failure -> Left (Text.unpack (protectedErrorMessage failure))
                Right (Left failure) -> Left (Text.unpack (modeErrorMessage failure))
                Right (Right _) -> Right ()

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
    InstalledProjectIdentity projectId ->
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
            (testDataGeneration dataParent run)
    case reclaimedData of
        Left failure -> pure (Left (unresolved (dataRootErrorMessage failure)))
        Right () -> do
            reclaimedConfig <- reclaimAbandonedConfig store project run configPath
            pure $ case reclaimedConfig of
                Left failure -> Left (unresolved (generatedConfigErrorMessage failure))
                Right () -> Right ()
  where
    run = incompleteRunLeaseRunText lease
    unresolved = ModeOwnershipUnresolved run

{- | The bound-lease fold callback.

A bound lease reached a plan, so it /may/ own real lifecycle resources — and
until this landed it was simply reported: the sweep's recheck refused the new run
and named the run, with nothing able to act on that name. An operator's only
route forward was deleting the run's protected records by hand.

The whole callback now runs inside 'withAbandonedHarnessRun', so the abandoned
run is /reopened/ before any branch is taken: the lease is rechecked as still
bound to the digests the sweep observed, the old snapshot is read back, the
durable invocation record is classified, and the run's mode and lease are retained
onto a fresh broker generation together with a @destroy@-only root and a
'RecoveredHarnessClose' close root. Previously each of those was either skipped or
done piecemeal by this function, and the close it did perform was authorized by a
bare 'RunId'.

It then resolves the one branch it can prove is safe: an ordinary Open revision
whose records show that the run acquired __nothing__.
'verifyNoProjectResourcesAcquired' is that proof and it is the sprint's own
producer for the true-pre-effect branch — a single effect-shaped record refuses, so
partial @up@ work can never be relabelled as a refusal that preceded acquisition.
That branch reclaims the run's two owned objects and closes its lease and mode
under the reopening's own close authority, which is exactly the interrupted-run
case the reservation exists for.

    A persisted @Closing@ epoch is the second branch it resolves. That run already
proved ordinary destroy settled and proved its sessions closed; only then could
'authorizeHarnessClose' consume that closure evidence and persist the epoch. The
remaining gap is terminal finalization, so recovery finishes the close it started
rather than reopening the run: it reclaims the two owned objects (already settled
on the ordinary path, and reclaiming from a durable origin record is idempotent),
resumes the authorization for that exact persisted epoch through
'resumeHarnessClose', and runs the same 'finalizeHarnessClose' the live run would
have.

An __incomplete__ migration is resolved the same way, and for the same reason.
Its recorded kind is a durable observation that the activation barrier was never
crossed, so there is no new revision to follow through: the staging is discarded
rather than resumed. What makes that safe is
'verifyNoProjectResourcesAcquired', not the classification — a staging that
acquired anything wrote an effect record and the proof refuses.

A __completed__ migration stays fail-closed and names why. Its activation
compare-and-swap committed, so the project's live revision is the new one and the
only correct continuation is to follow that activation through — a resumption
that needs the recovery boundary's own teardown, which this phase still owes. A
run that /did/ record effects likewise needs the recursive teardown forest, not a
lease close.
-}
resolveBoundRun ::
    forall projectId.
    RecoveredResourceExecutor ->
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    FilePath ->
    FilePath ->
    VerifiedIncompleteRunLease projectId ->
    IO (Either ModeError ())
resolveBoundRun recoveryExecutor store project dataParent configPath lease =
    case incompleteRunLeaseKind lease of
        IncompleteUnbound -> pure (Right ())
        IncompleteBound _ _ ->
            withAbandonedHarnessRun store project lease $ \reopened ->
                case abandonedHarnessRecovery reopened of
                    HarnessPersistedClosing epoch -> finishPersistedClose reopened epoch
                    HarnessOpenRevisionRecovery revision ->
                        case openRevisionKind revision of
                            -- The barrier was not crossed: no activation
                            -- committed, so there is no new revision to follow
                            -- through and the staging is discarded rather than
                            -- resumed. What makes discarding it safe is the same
                            -- proof the normal branch takes, not the
                            -- classification: a staging that acquired anything
                            -- wrote an effect record, and the proof refuses.
                            IncompleteMigration _ -> closeOrRecoverResources reopened
                            -- The barrier *was* crossed. The activation
                            -- compare-and-swap committed, so the project's live
                            -- revision is the new one and following it through
                            -- is a resumption, not a close: the activation is
                            -- driven to completion first, and only then is the
                            -- run settled the ordinary way.
                            CompletedMigration _ -> resumeCompletedMigration reopened
                            NormalRevision -> closeOrRecoverResources reopened
  where
    {- Finish a close the abandoned run had already authorized. Ordinary project
    destroy and its closure proof precede that authorization; the terminal
    projection over the generated config and data-root generation follows it.
    Recovery therefore reclaims those objects first from their durable origin
    records, then resumes the exact persisted authorization. -}
    finishPersistedClose ::
        forall oldRunId specDigest planDigest planId brokerGeneration.
        AbandonedHarnessRun projectId oldRunId specDigest planDigest planId brokerGeneration ->
        Word64 ->
        IO (Either ModeError ())
    finishPersistedClose reopened epoch = do
        reclaimed <- reclaimAbandonedRun store project dataParent configPath lease
        case reclaimed of
            Left failure -> pure (Left failure)
            Right () -> do
                resumed <-
                    runInEntry store $ \session ->
                        resumeHarnessClose
                            session
                            project
                            (abandonedHarnessCloseRoot reopened)
                            (abandonedHarnessModeLease reopened)
                            (abandonedHarnessBoundLease reopened)
                            epoch
                case resumed of
                    Left failure -> pure (Left failure)
                    Right authorization ->
                        runInEntry store $ \session ->
                            fmap (fmap (const ())) (finalizeHarnessClose session project authorization)

    {- Follow a committed activation through, then settle the run.

    The activation compare-and-swap already switched the lineage, so what is
    owed is the half that had not run when the invocation died: settle the
    superseded revision's sessions and admit the new revision's broker. That is
    'activateMigratedPlan', reached through the only opener that can name the
    candidate without a config — 'withCompletedMigrationRecovery' loads it back
    under the durable stable migration key, so an operator who edited or deleted
    the config in between cannot change which revision is activated.

    Only after the activation completes is the ordinary settlement attempted. A
    run that acquired resources still refuses there, by name: releasing them
    needs the recursive teardown forest at a recovery boundary, which is a
    different capability from closing a lease. -}
    resumeCompletedMigration ::
        forall oldRunId specDigest planDigest planId brokerGeneration.
        AbandonedHarnessRun projectId oldRunId specDigest planDigest planId brokerGeneration ->
        IO (Either ModeError ())
    resumeCompletedMigration reopened = do
        activated <-
            runInEntry store $ \session ->
                withCompletedMigrationRecovery
                    session
                    project
                    (abandonedHarnessBoundLease reopened)
                    $ \_profile barrier candidateSnapshot oldSnapshot rehydrated ->
                        case withMigratedRecoveredProjectFrames candidateSnapshot oldSnapshot rehydrated (\_ count -> count + (1 :: Int)) 0 of
                            Left failure -> pure (Left failure)
                            Right 0 -> pure (Left (ModeOwnershipUnresolved "completed-migration" "recovered no frames"))
                            Right _ ->
                                fmap
                                    (fmap (const ()))
                                    ( activateMigratedPlanConfigless
                                        session
                                        barrier
                                        (abandonedHarnessBoundLease reopened)
                                        (abandonedHarnessBroker reopened)
                                        rehydrated
                                    )
        case activated of
            Left failure -> pure (Left failure)
            Right () -> closeOrRecoverResources reopened

    closeOrRecoverResources ::
        forall oldRunId specDigest planDigest planId brokerGeneration.
        AbandonedHarnessRun projectId oldRunId specDigest planDigest planId brokerGeneration ->
        IO (Either ModeError ())
    closeOrRecoverResources reopened = do
        proved <- verifyBoundRunHasNoProjectResourcesAcquired (abandonedHarnessBoundLease reopened)
        case proved of
            Right evidence -> closeWithNoResources reopened evidence
            Left ownershipFailure -> do
                recovered <- withRehydratedSnapshotResourceSet
                    store
                    (abandonedHarnessSnapshot reopened)
                    (abandonedHarnessBroker reopened)
                    (abandonedHarnessAdmission reopened)
                    $ \resources -> do
                        settled <-
                            driveRecoveredForest
                                (abandonedHarnessSnapshot reopened)
                                resources
                                ( \frame adapter revision handle receipt -> do
                                    executed <- executeRecoveredResource recoveryExecutor frame adapter revision handle receipt
                                    case executed of
                                        Left failure -> pure (Left failure)
                                        Right () -> do
                                            recorded <-
                                                recordRecoveredResourceReleased
                                                    store
                                                    (planSnapshotPlanDigest (abandonedHarnessSnapshot reopened))
                                                    handle
                                                    receipt
                                            pure (either (Left . modeErrorMessage) Right recorded)
                                )
                        case settled of
                            Left failure -> pure (Left failure)
                            Right forest -> finishRecoveredClose reopened forest
                pure $ case recovered of
                    Left failure@(ModeOwnershipUnresolved _ _) -> Left failure
                    Left _ -> Left ownershipFailure
                    Right () -> Right ()

    finishRecoveredClose ::
        forall oldRunId specDigest planDigest planId brokerGeneration.
        AbandonedHarnessRun projectId oldRunId specDigest planDigest planId brokerGeneration ->
        RecoveredForestSettled (Harness projectId oldRunId) planId brokerGeneration ->
        IO (Either ModeError ())
    finishRecoveredClose reopened forest = do
        closed <-
            runInEntry store $ \session ->
                fmap (either (Left . ModeSessionFailure) Right) $
                    verifyAllSessionsClosed
                        session
                        (planSnapshotPlanDigest (abandonedHarnessSnapshot reopened))
        case closed of
            Left failure -> pure (Left failure)
            Right sessions ->
                case recoveredDestroySettledClosure (abandonedHarnessBoundLease reopened) sessions forest of
                    Left failure -> pure (Left failure)
                    Right closure -> do
                        authorized <-
                            runInEntry store $ \session ->
                                authorizeHarnessClose
                                    session
                                    project
                                    (abandonedHarnessCloseRoot reopened)
                                    (abandonedHarnessModeLease reopened)
                                    (abandonedHarnessBoundLease reopened)
                                    sessions
                                    closure
                                    1
                        case authorized of
                            Left failure -> pure (Left failure)
                            Right authorization -> do
                                reclaimed <- reclaimAbandonedRun store project dataParent configPath lease
                                case reclaimed of
                                    Left failure -> pure (Left failure)
                                    Right () ->
                                        runInEntry store $ \session ->
                                            fmap (fmap (const ())) (finalizeHarnessClose session project authorization)

    closeWithNoResources ::
        forall oldRunId specDigest planDigest planId brokerGeneration.
        AbandonedHarnessRun projectId oldRunId specDigest planDigest planId brokerGeneration ->
        ProjectClosureEvidence (Harness projectId oldRunId) ->
        IO (Either ModeError ())
    closeWithNoResources reopened evidence = do
        reclaimed <- reclaimAbandonedRun store project dataParent configPath lease
        case reclaimed of
            Left failure -> pure (Left failure)
            Right () ->
                runInEntry store $ \session ->
                    closeHarnessRun
                        session
                        project
                        (abandonedHarnessCloseRoot reopened)
                        (abandonedHarnessModeLease reopened)
                        evidence

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

{- | The ownership row this host's kernel supplies.

One selector, so the data root's clauses are held by the same primitives the
generated config's are, and there is one place that decides which kernel holds a
clause.
-}
ownershipRow :: OwnershipRow
ownershipRow = ownershipRowForHost

{- | Take the data root under all four § EE clauses.  The whole
observe → record-origin → create → bind-identity sequence runs inside one
protected entry, so it cannot straddle another opener's transaction and the
kernel releases the entry if this process dies part-way through.
-}
takeDataRoot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    RunId runId ->
    FilePath ->
    IO (Either DataRootError DataRootOwnership)
takeDataRoot store project run path =
    inEntry store $ \session ->
        case dataRootOriginKey project (runIdText run) of
            Left failure -> pure (Left failure)
            Right key -> acquireDataRoot ownershipRow session key path

{- | Give the data root back.  A directory this run created is removed only
after its exact kernel identity is re-observed; one the run merely found is
preserved; a replaced directory is a conflict and is left intact.  A conflict
here is reported, not raised: the run's report card already reflects the body's
outcome, and refusing to remove a stranger's directory is the correct end state.
-}
giveUpDataRoot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    RunId runId ->
    DataRootOwnership ->
    IO (Either DataRootError ())
giveUpDataRoot store project run owned =
    inEntry store $ \session ->
        case dataRootOriginKey project (runIdText run) of
            Left failure -> pure (Left failure)
            Right key ->
                fmap (fmap (const ())) (releaseDataRoot ownershipRow session key owned)

{- | Resolve an abandoned run's data-root record: restore the recorded absence,
or leave a recorded pre-existing directory alone.  Exposed to the sweep's fold
so a crashed predecessor's generation does not survive the next run.
-}
reclaimAbandonedDataRoot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    Text ->
    FilePath ->
    IO (Either DataRootError ())
reclaimAbandonedDataRoot store project run path =
    inEntry store $ \session ->
        case dataRootOriginKey project run of
            Left failure -> pure (Left failure)
            Right key ->
                fmap (fmap (const ())) (recoverDataRoot ownershipRow session key path)

{- | Resolve an abandoned run's generated-config record: unlink exactly the file
that run installed, or refuse an edited or replaced one and leave it intact.
This is what makes the interrupted-run config self-healing, and it is reachable
only because the existence refusal now runs after the sweep.
-}
reclaimAbandonedConfig ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    Text ->
    FilePath ->
    IO (Either GeneratedConfigError ())
reclaimAbandonedConfig store project run path =
    inConfigEntry store $ \session ->
        case generatedConfigKey project run of
            Left failure -> pure (Left failure)
            Right key ->
                fmap
                    (fmap (const ()))
                    (recoverGeneratedConfig ownershipRow session key path)

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
    InstalledProjectIdentity projectId -> Text -> Either DataRootError RecordKey
dataRootOriginKey project run =
    case mkRecordKey ("dataroot." <> installedProjectName project <> "." <> run) of
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
    InstalledProjectIdentity projectId -> Text -> Either GeneratedConfigError RecordKey
generatedConfigKey project run =
    case mkRecordKey ("config." <> installedProjectName project <> "." <> run) of
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
