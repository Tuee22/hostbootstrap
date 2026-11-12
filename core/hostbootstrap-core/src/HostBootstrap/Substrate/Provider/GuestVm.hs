{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Recorded ownership over the guest-VM row.

A real owned directory encloses a distinct protected VM-record entry. Every
provider effect checks that parent lease, and dependent work additionally
re-enters the stored reported-object binding and checks the current native VM
on both sides of the effect. The descriptor is ordinary data, never authority.
-}
module HostBootstrap.Substrate.Provider.GuestVm (
    OwnedGuestVm (..),
    ownedGuestVmClaim,
    ownedGuestVmNamespace,
    ownedGuestVmRecordDirectory,
    ownedGuestVmInstallLocation,
    provisionOwnedGuestVm,
    observeOwnedGuestVm,
    readyOwnedGuestVm,
    execInOwnedGuestVm,
) where

import Control.Exception (IOException, displayException, try)
import Control.Monad (unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import Data.Char (isControl)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Cordon (budgetFromResources, budgetStorageBytes)
import HostBootstrap.Cluster.Cordon.Foundation (ResourceBudget)
import HostBootstrap.Context (ResourceEnvelope (ResourceEnvelope))
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.Effect.Vocabulary (HostCommand)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lift (LiftLeaf (RawCmd), foldLeafCommand)
import HostBootstrap.Ownership.Clause (Bound, Recorded, recordedEvidence)
import HostBootstrap.Ownership.Object
import HostBootstrap.Ownership.Primitive (
    bindReportedIdentity, enterReportedObject, recordReportedOrigin,
    reenterStoredReportedObject, reobserveReportedIdentity,
    rowObserveIdentity, withOwnershipRow,
 )
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Ownership.Shipped (
    ShippedDirectoryLease,
 )
import qualified HostBootstrap.Ownership.Shipped as Shipped
import HostBootstrap.Ownership.Tape (
    RecordSubject (RecordSubject), RecordTape, publishBoundRecord, publishFreshRecord,
    readRecordUnder, readStoredRecordUnder, recordTape, storedOriginRecord,
 )
import HostBootstrap.Protected (ProtectedError, ProtectedSession, RecordKey, mkRecordKey, openProtectedStore, withProtectedEntry)
import HostBootstrap.Substrate.Provider (
    HostPathShare (..), ProviderKind (..), SubstrateProvider, providerKind,
    providerLiftContext, providerVmId,
 )
import HostBootstrap.Substrate.Provider.Command
import HostBootstrap.Substrate.Provider.Ownership (
    ProviderOwnershipFault (..), ProviderProvisionOutcome (..), ProviderReadyOutcome (..),
 )
import HostBootstrap.Substrate.Provider.Report
import HostBootstrap.Substrate.Provider.Resume
import HostBootstrap.Substrate.Provider.WslDisk (WslDiskAdmission (..), reconcileWslDiskCap)
import HostBootstrap.Wsl2.Registration (observeWslRegistration, wslRegistrationIdentity)
import System.Directory (doesDirectoryExist, pathIsSymbolicLink)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (isAbsolute, (</>))
import qualified System.FilePath.Posix as PosixPath

data OwnedGuestVm = OwnedGuestVm
    { ownedGuestVmProvider :: SubstrateProvider
    , ownedGuestVmSizing :: ProviderSizing
    , ownedGuestVmShare :: HostPathShare
    , ownedGuestVmOwner :: Text
    }

ownedGuestVmClaim :: OwnedGuestVm -> OwnerClaim
ownedGuestVmClaim = mkOwnerClaim . TextEncoding.encodeUtf8 . ownedGuestVmOwner

namespaceTag :: OwnedGuestVm -> Text
namespaceTag owned = ownerClaimText (mkOwnerClaim (TextEncoding.encodeUtf8
    (Text.pack (show (providerKind provider) <> ":" <> providerVmId provider))))
  where
    provider = ownedGuestVmProvider owned

ownedGuestVmNamespace :: OwnedGuestVm -> FilePath
ownedGuestVmNamespace owned =
    hpsHostPath (ownedGuestVmShare owned) </> (".guest-vm-" <> Text.unpack (namespaceTag owned))

ownedGuestVmRecordDirectory :: OwnedGuestVm -> FilePath
ownedGuestVmRecordDirectory owned = ownedGuestVmNamespace owned </> ".ownership"

ownedGuestVmInstallLocation :: OwnedGuestVm -> FilePath
ownedGuestVmInstallLocation owned =
    ownedGuestVmNamespace owned </> ("installation-" <> Text.unpack (ownerClaimText (ownedGuestVmClaim owned)))

type GuestAction value = ExceptT ProviderOwnershipFault IO value

clause :: IO (Either OwnershipFault value) -> GuestAction value
clause action = ExceptT (fmap (either (Left . ProviderOwnershipClause) Right) action)

store :: IO (Either ProtectedError value) -> GuestAction value
store action = ExceptT (fmap (either (Left . ProviderOwnershipStore) Right) action)

report :: Either ProviderReportFault value -> GuestAction value
report = either (throwE . ProviderOwnershipReport) pure

bad :: Text -> GuestAction value
bad = throwE . ProviderOwnershipClause . OwnershipMalformed

validateGuestVm :: OwnedGuestVm -> GuestAction ()
validateGuestVm owned = do
    unless supported (throwE (ProviderOwnershipClause (OwnershipUnsupported requirement)))
    let share = ownedGuestVmShare owned
        sizing = ownedGuestVmSizing owned
        name = providerVmId (ownedGuestVmProvider owned)
    when (null name || length name > 128 || any isControl name) (bad "the guest-VM name is not bounded non-empty text")
    unless (isAbsolute (hpsHostPath share) && PosixPath.isAbsolute (hpsGuestPath share))
        (bad "the guest-VM share requires absolute host and guest paths")
    when (any isControl (hpsHostPath share <> hpsGuestPath share)) (bad "the guest-VM share contains a control character")
    when (sizingCpu sizing == 0) (bad "the guest-VM CPU quantity is zero")
    void (guestBudget owned)
  where
#if defined(mingw32_HOST_OS)
    supported = providerKind (ownedGuestVmProvider owned) == ProviderWsl2
    requirement = "this host's native guest-VM identity row requires WSL2"
#else
    supported = providerKind (ownedGuestVmProvider owned) == ProviderLima
    requirement = "this host's native guest-VM identity row requires Lima"
#endif

guestBudget :: OwnedGuestVm -> GuestAction ResourceBudget
guestBudget owned = case budgetFromResources
    (ResourceEnvelope (fromIntegral (sizingCpu sizing)) (Text.pack (sizingMemory sizing)) (Text.pack (sizingStorage sizing))) of
        Left failure -> bad ("the guest-VM budget is invalid: " <> Text.pack (show failure))
        Right budget -> do
            when (providerKind (ownedGuestVmProvider owned) == ProviderWsl2
                && budgetStorageBytes budget `mod` (1024 * 1024 * 1024) /= 0)
                (bad "WSL2 installation requires a whole GiB disk budget")
            pure budget
  where sizing = ownedGuestVmSizing owned

withGuestVmEntry ::
    OwnedGuestVm ->
    (forall lease session. ShippedDirectoryLease lease -> ProtectedSession session -> RecordKey -> GuestAction value) ->
    IO (Either ProviderOwnershipFault value)
withGuestVmEntry owned action = runExceptT $ do
    validateGuestVm owned
    namespaceKey <- store (pure (mkRecordKey ("guest-namespace." <> namespaceTag owned)))
    vmKey <- store (pure (mkRecordKey "guest-instance"))
    authority <- clause (pure (Shipped.mkShippedAuthorityPath (hpsHostPath (ownedGuestVmShare owned) </> ".provider-state")))
    target <- clause (pure (Shipped.mkShippedTargetPath (ownedGuestVmNamespace owned)))
    let transaction = Shipped.mkShippedOwnership authority namespaceKey target Shipped.ShipTakeDirectory
    nested <- clause $ Shipped.withShippedDirectoryLease ownershipRowForHost transaction $ \lease ->
        runExceptT $ do
            records <- store (openProtectedStore (ownedGuestVmRecordDirectory owned))
            entered <- store (withProtectedEntry records (\session -> Right <$> runExceptT (action lease session vmKey)))
            either throwE pure entered
    either throwE pure nested

guestTape :: ProtectedSession session -> RecordTape session
guestTape session = recordTape session (RecordSubject "the guest-VM origin record" "bind the guest-VM native identity")

data GuestObservation = GuestObservation (Maybe ProviderRunState) Origin ProviderConfigValue (Maybe ResourceBudget)

interpret :: ShippedDirectoryLease lease -> HostConfig -> HostCommand -> GuestAction (Either String CapturedRun)
interpret lease cfg command = clause (Shipped.useShippedDirectoryLease lease (interpretHostCommand cfg command))

observe :: ShippedDirectoryLease lease -> HostConfig -> OwnedGuestVm -> GuestAction GuestObservation
observe lease cfg owned = case providerKind provider of
    ProviderLima -> do
        listed <- report =<< (classifyLimaInstanceReport name <$> interpret lease cfg (listLimaInstanceCommand name))
        case listed of
            Nothing -> pure (GuestObservation Nothing OriginAbsent ProviderConfigUnset Nothing)
            Just native -> do
                let directory = limaInstanceDirectory native
                facts <- liftIO (try ((,) <$> doesDirectoryExist directory <*> pathIsSymbolicLink directory)
                    :: IO (Either IOException (Bool, Bool)))
                case facts of
                    Right (True, False) -> pure ()
                    Right _ -> bad "the native Lima instance directory is absent or is a symbolic link"
                    Left failure -> throwE (ProviderOwnershipClause
                        (OwnershipProbeFailed "observe the native Lima instance directory"
                            (Text.take 512 (Text.pack (displayException failure)))))
                identity <- clause (withOwnershipRow ownershipRowForHost (\row -> rowObserveIdentity row directory))
                origin <- report (providerObservedOrigin (Just (limaInstanceListing native)) identity)
                pure (GuestObservation (Just (listedState (limaInstanceListing native))) origin (limaInstanceClaim native) (Just (limaInstanceSizing native)))
    ProviderWsl2 -> do
        registration <- clause (Shipped.useShippedDirectoryLease lease (observeWslRegistration name)) >>= either (throwE . ProviderOwnershipClause) pure
        pure $ case registration of
            Nothing -> GuestObservation Nothing OriginAbsent ProviderConfigUnset Nothing
            Just native -> GuestObservation Nothing (OriginPresent (wslRegistrationIdentity native))
                (wslLocationClaim (ownedGuestVmInstallLocation owned) (ownedGuestVmClaim owned) native) Nothing
    _ -> bad "the guest-VM transaction received a non-VM provider"
  where
    provider = ownedGuestVmProvider owned
    name = providerVmId provider

standing :: ShippedDirectoryLease lease -> HostConfig -> ProtectedSession session -> RecordKey -> OwnedGuestVm ->
    GuestAction (ProviderStanding, GuestObservation)
standing lease cfg session key owned = do
    observation@(GuestObservation _ origin carried _) <- observe lease cfg owned
    record <- clause (readRecordUnder (guestTape session) key)
    case record of
        Just held | ReportedObject claim <- originRecordKind held, claim /= ownedGuestVmClaim owned ->
            throwE (ProviderOwnershipStanding (InstanceUnderAnotherClaim
                (ownerClaimText (ownedGuestVmClaim owned)) (ownerClaimText claim)))
        _ -> pure ()
    value <- either (throwE . ProviderOwnershipStanding) pure (providerStanding record origin carried)
    pure (value, observation)

provisionOwnedGuestVm :: HostConfig -> OwnedGuestVm -> IO (Either ProviderOwnershipFault ProviderProvisionOutcome)
provisionOwnedGuestVm cfg owned = withGuestVmEntry owned $ \lease session key -> do
    (current, _) <- standing lease cfg session key owned
    when (providerKind (ownedGuestVmProvider owned) == ProviderWsl2) $ do
        declared <- guestBudget owned
        let admission = case current of NothingDone -> BeginWslInstallation; _ -> RequireRecordedWslInstallation
        void (ExceptT (reconcileWslDiskCap session admission (ownedGuestVmClaim owned) declared))
    case current of
        InstanceOwned _ identity -> withBound lease cfg session key owned $ \_ (GuestObservation _ _ _ sizing) -> do
            case sizing of
                Just actual -> do
                    declared <- guestBudget owned
                    unless (providerSizingMatches declared (NativeProviderSizing actual))
                        (throwE (ProviderOwnershipSizing declared (NativeProviderSizing actual)))
                Nothing -> unless (providerKind (ownedGuestVmProvider owned) == ProviderWsl2)
                    (bad "the owned Lima instance has no native sizing observation")
            pure (ProvisionAlreadyOwned identity)
        _ -> withOrigin session key owned $ \recorded -> do
            case current of
                InstanceCreated _ _ -> pure ()
                _ -> do
                    command <- creationCommand owned
                    void (report . classifyProviderReport 65536 =<< interpret lease cfg command)
            recordedEvidence (\_ record -> do
                GuestObservation _ origin carried _ <- observe lease cfg owned
                state <- either (throwE . ProviderOwnershipStanding) pure (providerStanding (Just record) origin carried)
                identity <- maybe (bad "the guest-VM create command produced no claimed native instance") pure (standingIdentity state)
                void (clause (bindReportedIdentity recorded identity (publishBoundRecord (guestTape session) key)))
                pure (case current of InstanceCreated _ _ -> ProvisionRecovered identity; _ -> ProvisionCreated identity)) recorded

withOrigin :: ProtectedSession session -> RecordKey -> OwnedGuestVm ->
    (forall object. Recorded session object -> GuestAction value) -> GuestAction value
withOrigin session key owned action = do
    nested <- clause $ enterReportedObject session (providerVmId (ownedGuestVmProvider owned)) OriginAbsent $ \entered -> do
        recorded <- recordReportedOrigin entered (ownedGuestVmClaim owned) (publishFreshRecord (guestTape session) key)
        traverse (runExceptT . action) recorded
    either throwE pure nested

creationCommand :: OwnedGuestVm -> GuestAction HostCommand
creationCommand owned
    | providerKind provider == ProviderLima =
        pure (createLimaInstanceCommand name sizing (hpsHostPath share) (hpsGuestPath share) (ownedGuestVmClaim owned))
    | otherwise = do
        budget <- guestBudget owned
        let bytes = budgetStorageBytes budget
            unit = 1024 * 1024 * 1024
        pure (installWslInstanceCommand name (ownedGuestVmInstallLocation owned) (show (bytes `div` unit) <> "GB"))
  where
    provider = ownedGuestVmProvider owned
    name = providerVmId provider
    sizing = ownedGuestVmSizing owned
    share = ownedGuestVmShare owned

withBound :: ShippedDirectoryLease lease -> HostConfig -> ProtectedSession session -> RecordKey -> OwnedGuestVm ->
    (forall object. Bound session object -> GuestObservation -> GuestAction value) -> GuestAction value
withBound lease cfg session key owned action = do
    (current, before) <- standing lease cfg session key owned
    identity <- case current of
        InstanceOwned _ actual -> pure actual
        _ -> bad "the guest-VM record does not yet bind an owned native instance"
    stored <- clause (readStoredRecordUnder (guestTape session) key)
    held <- maybe (bad "the guest-VM record vanished inside its exclusive entry") pure stored
    unless (originRecordBinding (storedOriginRecord held) == Just identity) (bad "the guest-VM stored binding changed inside its entry")
    nested <- clause $ reenterStoredReportedObject session (providerVmId (ownedGuestVmProvider owned)) held $ \bound ->
        Right <$> runExceptT (action bound before)
    either throwE pure nested

-- A daemon probe observes the same recorded native object as dependent work.
-- It exposes no session, token, callback or unrestricted command executor.
observeOwnedGuestVm :: HostConfig -> OwnedGuestVm -> IO (Either ProviderOwnershipFault ())
observeOwnedGuestVm cfg owned = withGuestVmEntry owned $ \lease session key ->
    withBound lease cfg session key owned (\_ _ -> pure ())

boundCommand :: ShippedDirectoryLease lease -> HostConfig -> ProtectedSession session -> RecordKey -> OwnedGuestVm ->
    HostCommand -> GuestAction (Either String CapturedRun)
boundCommand lease cfg session key owned command = withBound lease cfg session key owned $ \bound _ -> do
    (_, GuestObservation _ beforeOrigin _ _) <- standing lease cfg session key owned
    void (clause (pure (reobserveReportedIdentity bound beforeOrigin)))
    captured <- interpret lease cfg command
    (_, GuestObservation _ afterOrigin _ _) <- standing lease cfg session key owned
    void (clause (pure (reobserveReportedIdentity bound afterOrigin)))
    pure captured

execUnderEntry :: ShippedDirectoryLease lease -> HostConfig -> ProtectedSession session -> RecordKey -> OwnedGuestVm ->
    [String] -> GuestAction CapturedRun
execUnderEntry lease cfg session key owned argv = do
    when (null argv || any (elem '\0') argv) (bad "guest probe argv must be non-empty and contain no NUL")
    command <- case argv of
        exe : arguments -> either (throwE . ProviderOwnershipReport . ProviderCommandUnrun . Text.pack) pure
            (foldLeafCommand (providerLiftContext (ownedGuestVmProvider owned)) (RawCmd exe arguments))
        [] -> bad "guest probe argv must be non-empty and contain no NUL"
    captured <- boundCommand lease cfg session key owned command
    case classifyProviderReport providerReportLineBound captured of
        Right _ -> either (throwE . ProviderOwnershipReport . ProviderCommandUnrun . Text.pack) pure captured
        Left (ProviderCommandExited code diagnostic) -> pure (CapturedRun (ExitFailure code) "" (Text.unpack diagnostic))
        Left failure -> throwE (ProviderOwnershipReport failure)

execInOwnedGuestVm :: HostConfig -> OwnedGuestVm -> [String] -> IO (Either ProviderOwnershipFault CapturedRun)
execInOwnedGuestVm cfg owned argv = withGuestVmEntry owned $ \lease session key -> execUnderEntry lease cfg session key owned argv

readyOwnedGuestVm :: HostConfig -> OwnedGuestVm -> IO (Either ProviderOwnershipFault ProviderReadyOutcome)
readyOwnedGuestVm cfg owned = withGuestVmEntry owned $ \lease session key -> do
    (current, GuestObservation state _ _ _) <- standing lease cfg session key owned
    identity <- case current of
        InstanceOwned _ actual -> pure actual
        _ -> bad "the guest-VM record does not yet bind an owned native instance"
    started <- if state == Just ProviderStopped then do
        void (report . classifyProviderReport 65536 =<< boundCommand lease cfg session key owned
            (startLimaInstanceCommand (providerVmId (ownedGuestVmProvider owned))))
        (_, GuestObservation after _ _ _) <- standing lease cfg session key owned
        unless (after == Just ProviderRunning) (bad "the Lima instance is not Running after its start command")
        pure True
      else pure False
    captured <- execUnderEntry lease cfg session key owned ["true"]
    pure $ case capturedExit captured of
        ExitSuccess -> if started then ReadyStarted identity else ReadyAlready identity
        ExitFailure _ -> ReadyNotAnswering (Text.pack (capturedStderr captured))
