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
4. on exit closes the lease and releases the mode, and removes the directory
   only after re-observing that exact kernel identity. A @.test_data@ (or
   @.data@) the run merely found is preserved, and a directory that was
   /replaced/ under the run is reported as a conflict and left intact (§ Z).
-}
module HostBootstrap.Harness.Ownership (
    protectedRunOwnership,
    harnessAuthorityStoreDirectory,
) where

import Control.Exception.Safe (finally)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Authority (
    InstalledProject,
    ProjectVerb (ProjectUp),
    authorityErrorMessage,
    installedProjectName,
    withInstalledProject,
 )
import HostBootstrap.Harness (HarnessRunOwnership (..), testDataGeneration)
import HostBootstrap.Harness.DataRoot (
    DataRootError (DataRootStoreFailure),
    DataRootIdentityBackend,
    DataRootOwnership,
    acquireDataRoot,
    dataRootErrorMessage,
    recoverDataRoot,
    releaseDataRoot,
 )
import HostBootstrap.Harness.DataRoot.Native (nativeDataRootIdentityBackend)
import HostBootstrap.Lifecycle.Mode (
    IncompleteLeaseKind (IncompleteBound, IncompleteUnbound),
    ModeError (ModeOwnershipUnresolved),
    RunId,
    VerifiedIncompleteRunLease,
    closeHarnessRun,
    harnessPreconditions,
    harnessRootRunId,
    incompleteRunLeaseKind,
    incompleteRunLeaseRun,
    modeErrorMessage,
    recoverAbandonedHarnessRuns,
    runIdText,
    verifyNoProjectResourcesAcquired,
    withHarnessRoot,
 )
import HostBootstrap.Protected (
    ProtectedError,
    withRunLiveness,
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
    withProtectedEntry,
 )
import System.FilePath ((</>))

-- | Where the protected authority store lives, relative to the state root.
harnessAuthorityStoreDirectory :: FilePath
harnessAuthorityStoreDirectory = ".hostbootstrap" </> "authority"

{- | Build the run-ownership bracket for one project.

The project name and both directories are derived by the command layer from the
project the binary *is*; nothing here is an operator argument.
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
    HarnessRunOwnership
protectedRunOwnership projectName stateRoot siblingDirectory dataParent =
    HarnessRunOwnership (ownRun projectName stateRoot siblingDirectory dataParent)

ownRun ::
    forall result.
    Text ->
    FilePath ->
    FilePath ->
    FilePath ->
    IO result ->
    IO (Either String result)
ownRun projectName stateRoot siblingDirectory dataParent body =
    case withInstalledProject projectName owned of
        Left failure -> pure (Left (refused (authorityErrorMessage failure)))
        Right action -> action
  where
    owned :: InstalledProject projectId -> IO (Either String result)
    owned project = do
        opened <- openProtectedStore (stateRoot </> harnessAuthorityStoreDirectory)
        case opened of
            Left failure -> pure (Left (storeRefused failure))
            Right store -> do
                -- Held across the sweep AND the whole run: the sweep may only
                -- reclaim leases whose owners are dead, and this lock is the
                -- only thing that can tell it so.
                held <-
                    withRunLiveness store (installedProjectName project) (owning store project)
                pure $ case held of
                    Left failure -> Left (storeRefused failure)
                    Right Nothing -> Left (refused liveRunHoldsProject)
                    Right (Just inner) -> inner

    owning :: ProtectedStore -> InstalledProject projectId -> IO (Either String result)
    owning store project = do
        swept <-
            recoverAbandonedHarnessRuns
                store
                project
                (reclaimUnboundRun store project dataParent)
                reportBoundRun
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
                        (runOwned store project)
                pure (either (Left . modeRefused) Right outcome)
    runOwned store project root = do
        let run = harnessRootRunId root
            -- § Z: the run owns @.test_data/<runId>@, not the shared parent.
            generation = testDataGeneration dataParent (runIdText run)
        started <- takeDataRoot store project run generation
        case started of
            Left failure ->
                pure
                    ( Left
                        ( ModeOwnershipUnresolved
                            (runIdText run)
                            (dataRootErrorMessage failure)
                        )
                    )
            Right receipt ->
                (Right <$> body)
                    `finally` releaseRun store project run receipt
    releaseRun store project run receipt = do
        _ <- giveUpDataRoot store project run receipt
        _ <-
            withProtectedEntry store $ \session -> do
                evidence <- verifyNoProjectResourcesAcquired session project run
                case evidence of
                    Left _ -> pure (Right ())
                    Right proof -> do
                        _ <- closeHarnessRun session project run proof
                        pure (Right ())
        pure ()

{- | Reclaim an abandoned unbound run's data root before the sweep closes its
lease. The recorded origin is the authority: a generation that run created is
removed and the recorded absence restored, while a directory it merely found is
left alone. A conflict — the path now holds a different object — is reported and
blocks the new run rather than deleting a stranger's directory.
-}
reclaimUnboundRun ::
    ProtectedStore ->
    InstalledProject projectId ->
    -- | the shared @.test_data@ parent
    FilePath ->
    VerifiedIncompleteRunLease projectId ->
    IO (Either ModeError ())
reclaimUnboundRun store project dataParent lease = do
    let run = incompleteRunLeaseRun lease
    reclaimed <-
        reclaimAbandonedDataRoot
            store
            project
            run
            (testDataGeneration dataParent (runIdText run))
    pure $ case reclaimed of
        Left failure ->
            Left
                ( ModeOwnershipUnresolved
                    (runIdText run)
                    (dataRootErrorMessage failure)
                )
        Right () -> Right ()

{- | The bound-lease fold callback. A bound lease reached a plan and may own real
lifecycle resources, so it is deliberately left alone — the sweep's recheck then
refuses the new run and names the exact run an operator must recover.
-}
reportBoundRun :: VerifiedIncompleteRunLease projectId -> IO (Either ModeError ())
reportBoundRun lease = case incompleteRunLeaseKind lease of
    IncompleteUnbound -> pure (Right ())
    IncompleteBound _ _ -> pure (Right ())

-- | The host identity backend the production bracket binds ownership to.
identityBackend :: DataRootIdentityBackend
identityBackend = nativeDataRootIdentityBackend

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
