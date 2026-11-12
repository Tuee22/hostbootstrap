{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module ProviderAliasSpec (tests, localGuestAliasSupported) where

#ifndef mingw32_HOST_OS
import qualified Expect as OwnershipFixture
#endif
import ConditionalCase (conditionalCase)
import Control.Monad (forM_, when)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import FakeProvider (localGuestAliasSupported)
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    OriginRecord,
    ObjectKind (ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    ConflictReport (ConflictReport, conflictSubject, conflictExpected, conflictObserved),
    OwnershipFault (OwnershipOccupied, OwnershipUnsupported, OwnershipProbeFailed, OwnershipMalformed, OwnershipConflict),
    mkObjectIdentity,
    mkOwnerClaim,
    originRecord,
    originRecordBinding,
    parseOriginRecord,
    renderOriginRecord,
 )
import HostBootstrap.Ownership.Primitive (rowObserveIdentity, withOwnershipRow)
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Ownership.Shipped
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    RecordKey,
    ProtectedRecord (protectedRecordBytes),
    compareAndSwapProtectedRecord,
    mkRecordKey,
    openProtectedStore,
    readProtectedRecord,
    recordKeyText,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile (FailureDetail (FailureDetail), ReconcileError (Failure), RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry))
import HostBootstrap.Substrate.Provider.Alias
import System.Directory (
    createDirectory,
    createFileLink,
    doesDirectoryExist,
    doesPathExist,
    getSymbolicLinkTarget,
    pathIsSymbolicLink,
    removeFile,
    renameFile,
 )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
#ifndef mingw32_HOST_OS
import HostBootstrap.Ownership.Object (bindOriginRecord)
import HostBootstrap.Protected (Expectation (ExpectVersion), protectedRecordVersion)
import System.Posix.Files (createSymbolicLink, deviceID, fileID, getSymbolicLinkStatus)
#ifndef darwin_HOST_OS
import System.Posix.Files (createLink)
#endif
#endif

tests :: TestTree
tests =
    testGroup
        "ProviderAliasSpec"
        [ testGroup "the closed guest alias descriptor" descriptorCases
        , testGroup "the shipped failure recovery" failureRecoveryCases
        , testGroup "the shipped guest alias ownership row" (ownershipCases <> crashWindowCases)
        ]

descriptorCases :: [TestTree]
descriptorCases =
    [ rejected "a relative alias" "alias path must be an absolute POSIX guest path" "tmp/alias" "/srv/data"
    , rejected "a relative target" "alias target must be an absolute POSIX guest path" "/tmp/alias" "srv/data"
    , rejected "a Windows alias" "alias path must be an absolute POSIX guest path" "C:\\alias" "/srv/data"
    , rejected "the guest root" "alias path must name a non-root guest entry" "/" "/srv/data"
    , rejected "a trailing slash" "alias path must not have a trailing slash" "/srv/alias/" "/srv/data"
    , rejected "a dot segment" ambiguous "/srv/./alias" "/srv/data"
    , rejected "a dot-dot segment" ambiguous "/srv/x/../alias" "/srv/data"
    , rejected "an empty segment" ambiguous "/srv//alias" "/srv/data"
    , rejected "the target itself" "alias path and target must differ" "/srv/data" "/srv/data"
    , rejected "a NUL in the alias" nul "/srv/a\0b" "/srv/data"
    , rejected "a NUL in the target" nul "/srv/alias" "/srv/a\0b"
    , rejected "an alias above its target" "alias path must not be an ancestor of its target" "/srv/data" "/srv/data/child"
    , rejected "an alias at the authority directory" authority "/srv/data/.hostbootstrap-alias-authority-v1" "/srv/data"
    , rejected "an alias below the authority directory" authority "/srv/data/.hostbootstrap-alias-authority-v1/child" "/srv/data"
    , rejected "the root target authority directory" authority "/.hostbootstrap-alias-authority-v1" "/"
    , testCase "distinct canonical absolute POSIX paths are admitted" $
        assertRight (mkGuestAliasSpec "/srv/alias" "/mnt/data")
    , testCase "a shared character prefix is not a path ancestor" $
        assertRight (mkGuestAliasSpec "/srv/data" "/srv/database")
    , testCase "the shipped authority stays in the guest's POSIX grammar" $ do
        spec <- either (assertFailure . show) pure (mkGuestAliasSpec "/srv/hostbootstrap" "/mnt/c/demo/data")
        shippedAuthorityPath (shippedAuthority (guestAliasOwnershipTransaction spec (ShipTakeSymbolicLink (fixtureLinkTarget "/mnt/c/demo/data"))))
            @?= "/mnt/c/demo/data/.hostbootstrap-alias-authority-v1"
    , testCase "the alias adapter contains no guest interpreter or tool-discovery fallback" $ do
        source <- readFile "src/HostBootstrap/Substrate/Provider/Alias.hs"
        providerSource <- readFile "src/HostBootstrap/Substrate/Provider.hs"
        assertBool "the alias adapter does not use the shipped ownership transaction" ("ShipTakeSymbolicLink" `contains` source)
        mapM_
            (\legacy -> assertBool ("legacy alias driver remains: " <> legacy) (not (legacy `contains` source)))
            ["aliasOwnershipProgram", "exclusiveWrapped", "GuestOwnershipTools", "runProviderGuestExecutor"]
        mapM_
            (\legacy -> assertBool ("legacy guest tool probe remains: " <> legacy) (not (legacy `contains` providerSource)))
            ["GuestLockPrimitive", "GuestStatDialect", "GuestPythonCapability", "guest Python 3", "guest flock"]
    ]
  where
    ambiguous = "alias path and target must not contain empty, dot, or dot-dot segments"
    nul = "alias path and target must not contain NUL"
    authority = "alias path must not overlap the target alias authority directory"

failureRecoveryCases :: [TestTree]
failureRecoveryCases =
    [ testCase "only the frame's decoded malformed-input refusal is permanent" $ do
        identity <- either (assertFailure . show) pure (mkObjectIdentity "observed-identity")
        let report =
                ConflictReport
                    { conflictSubject = "/alias"
                    , conflictExpected = OriginAbsent
                    , conflictObserved = OriginPresent identity
                    }
            uncertain =
                [ Left (ShippedCrossingFailed "the frame is unavailable")
                , Left (ShippedOutcomeUndecodable "the answer cannot be decoded")
                , Left (ShippedFrameRefused (OwnershipOccupied "an operator's object"))
                , Left (ShippedFrameRefused (OwnershipProbeFailed "observe" "unavailable"))
                , Left (ShippedFrameRefused (OwnershipUnsupported "no row"))
                , Left (ShippedFrameRefused (OwnershipConflict report))
                , Right ShippedObjectAbsent
                , Right (ShippedSymbolicLinkCreated identity)
                ]
        map shippedAliasFailureRecovery uncertain
            @?= replicate (length uncertain) ReprobeBeforeRetry
        shippedAliasFailureRecovery (Left (ShippedFrameRefused (OwnershipMalformed "bad input")))
            @?= DoNotRetry
    ]

ownershipCases :: [TestTree]
ownershipCases =
    [ kernelCase "create, exact retry, and release use one durable identity" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        first <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        identity <- expectCreated first
        observedIdentity <- withOwnershipRow ownershipRowForHost (\row -> rowObserveIdentity row (frameAlias frame))
        observedIdentity @?= Right (Just identity)
        pathIsSymbolicLink (frameAlias frame) >>= assertBool "the alias is a symbolic link"
        getSymbolicLinkTarget (frameAlias frame) >>= (@?= frameLinkTarget frame)
        second <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        second @?= ShippedSymbolicLinkRetained identity
        released <- runShippedOwnership ownershipRowForHost (releaseTransaction frame)
        released @?= ShippedObjectGivenBack
        doesPathExist (frameAlias frame) >>= assertBool "the alias was removed" . not
        doesDirectoryExist (frameLinkTarget frame) >>= assertBool "the durable target remains"
        assertRecordPresent frame False
        fresh <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        _ <- expectCreated fresh
        assertRecordPresent frame True
        getSymbolicLinkTarget (frameAlias frame) >>= (@?= frameLinkTarget frame)
    , kernelCase "an exact-looking unrecorded alias remains foreign" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        createFileLink (frameLinkTarget frame) (frameAlias frame)
        result <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        case result of
            ShippedRefused (OwnershipOccupied _) -> pure ()
            other -> assertFailure ("expected an occupied refusal, got " <> show other)
        getSymbolicLinkTarget (frameAlias frame) >>= (@?= frameLinkTarget frame)
    , kernelCase "an interruption after origin publication resumes the same transaction" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        publishUnboundRecord frame
        resumed <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        identity <- case resumed of
            ShippedSymbolicLinkRetained value -> pure value
            other -> assertFailure ("expected a retained recovery, got " <> show other)
        pathIsSymbolicLink (frameAlias frame) >>= (@?= True)
        getSymbolicLinkTarget (frameAlias frame) >>= (@?= frameLinkTarget frame)
        observeAliasIdentity (frameAlias frame) >>= (@?= identity)
        assertAliasBinding frame identity
        doesPathExist (stagingPath frame) >>= (@?= False)
        runShippedOwnership ownershipRowForHost (releaseTransaction frame) >>= (@?= ShippedObjectGivenBack)
        assertRecordPresent frame False
    , kernelCase "an interruption after pre-publication identity binding resumes that exact inode" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        publishUnboundRecord frame
        staged <- publishBoundStaging frame
        resumed <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        resumed @?= ShippedSymbolicLinkRetained staged
        pathIsSymbolicLink (frameAlias frame) >>= (@?= True)
        getSymbolicLinkTarget (frameAlias frame) >>= (@?= frameLinkTarget frame)
        observeAliasIdentity (frameAlias frame) >>= (@?= staged)
        assertAliasBinding frame staged
        retried <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        retried @?= ShippedSymbolicLinkRetained staged
        doesPathExist (stagingPath frame) >>= assertBool "the recovery removed its staging link" . not
    , kernelCase "an interruption after unlink converges by forgetting only the bound record" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        _ <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        removeFile (frameAlias frame)
        released <- runShippedOwnership ownershipRowForHost (releaseTransaction frame)
        released @?= ShippedObjectGivenBack
        assertRecordPresent frame False
        again <- runShippedOwnership ownershipRowForHost (releaseTransaction frame)
        again @?= ShippedObjectGivenBack
    ]

crashWindowCases :: [TestTree]
crashWindowCases =
    [ kernelCase "give-back refuses an unrecorded exact-looking alias" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        createFileLink (frameLinkTarget frame) (frameAlias frame)
        before <- observeAliasIdentity (frameAlias frame)
        outcome <- runShippedOwnership ownershipRowForHost (releaseTransaction frame)
        expectOccupiedAlias outcome
        getSymbolicLinkTarget (frameAlias frame) >>= (@?= frameLinkTarget frame)
        observeAliasIdentity (frameAlias frame) >>= (@?= before)
        recordForAlias frame >>= (@?= Nothing)
    , kernelCase "give-back refuses an unrecorded regular file" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        ByteString.writeFile (frameAlias frame) "an operator's file"
        before <- observeAliasIdentity (frameAlias frame)
        outcome <- runShippedOwnership ownershipRowForHost (releaseTransaction frame)
        expectOccupiedAlias outcome
        ByteString.readFile (frameAlias frame) >>= (@?= "an operator's file")
        observeAliasIdentity (frameAlias frame) >>= (@?= before)
        recordForAlias frame >>= (@?= Nothing)
    , kernelCase "an unbound absent alias gives back its intent without a stage" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        publishUnboundRecord frame
        runShippedOwnership ownershipRowForHost (releaseTransaction frame) >>= (@?= ShippedObjectGivenBack)
        assertRecordPresent frame False
        doesPathExist (frameAlias frame) >>= (@?= False)
        doesPathExist (stagingPath frame) >>= (@?= False)
    , kernelCase "an unbound absent alias gives back its exact staging link" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        publishUnboundRecord frame
        createFileLink (frameLinkTarget frame) (stagingPath frame)
        runShippedOwnership ownershipRowForHost (releaseTransaction frame) >>= (@?= ShippedObjectGivenBack)
        assertRecordPresent frame False
        doesPathExist (frameAlias frame) >>= (@?= False)
        doesPathExist (stagingPath frame) >>= (@?= False)
        doesDirectoryExist (frameLinkTarget frame) >>= (@?= True)
    , kernelCase "an unbound record refuses an alias occupant" (unboundAliasOccupantCase True)
    , kernelCase "an unbound record refuses a regular-file occupant" (unboundAliasOccupantCase False)
    , kernelCase "give-back removes the bound stage while the alias is absent" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        publishUnboundRecord frame
        staged <- publishBoundStaging frame
        observeAliasIdentity (stagingPath frame) >>= (@?= staged)
        runShippedOwnership ownershipRowForHost (releaseTransaction frame) >>= (@?= ShippedObjectGivenBack)
        doesPathExist (stagingPath frame) >>= (@?= False)
        doesPathExist (frameAlias frame) >>= (@?= False)
        assertRecordPresent frame False
    , kernelCase "give-back removes the published inode and its platform staging name" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        publishUnboundRecord frame
        (staged, stagePresent) <- publishBoundAlias frame
        observeAliasIdentity (frameAlias frame) >>= (@?= staged)
        doesPathExist (stagingPath frame) >>= (@?= stagePresent)
        when stagePresent (observeAliasIdentity (stagingPath frame) >>= (@?= staged))
        runShippedOwnership ownershipRowForHost (releaseTransaction frame) >>= (@?= ShippedObjectGivenBack)
        doesPathExist (frameAlias frame) >>= (@?= False)
        doesPathExist (stagingPath frame) >>= (@?= False)
        assertRecordPresent frame False
    , kernelCase "a same-target replacement refuses a take retry" (sameTargetReplacementCase takeTransaction)
    , kernelCase "a same-target replacement refuses give-back" (sameTargetReplacementCase releaseTransaction)
    , kernelCase "both acts refuse another target under the same authority and key" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        bound <- expectCreated =<< runShippedOwnership ownershipRowForHost (takeTransaction frame)
        before <- recordForAlias frame
        let other = frame{frameLinkTarget = frameLinkTarget frame <> "-other"}
        forM_ [takeTransaction other, releaseTransaction other] $ \request -> do
            runShippedOwnership ownershipRowForHost request
                >>= (@?= ShippedRefused (OwnershipMalformed "the symbolic-link record belongs to a different target claim"))
            getSymbolicLinkTarget (frameAlias frame) >>= (@?= frameLinkTarget frame)
            observeAliasIdentity (frameAlias frame) >>= (@?= bound)
            recordForAlias frame >>= (@?= before)
    , kernelCase "both acts refuse a reported record with a present origin" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        createFileLink (frameLinkTarget frame) (frameAlias frame)
        current <- observeAliasIdentity (frameAlias frame)
        let claim = mkOwnerClaim (TextEncoding.encodeUtf8 (Text.pack (frameLinkTarget frame)))
        publishAliasRecord frame (originRecord (ReportedObject claim) (OriginPresent current))
        before <- recordForAlias frame
        forM_ [takeTransaction frame, releaseTransaction frame] $ \request -> do
            runShippedOwnership ownershipRowForHost request
                >>= (@?= ShippedRefused (OwnershipMalformed "the symbolic-link record did not record an absent origin"))
            observeAliasIdentity (frameAlias frame) >>= (@?= current)
            getSymbolicLinkTarget (frameAlias frame) >>= (@?= frameLinkTarget frame)
            recordForAlias frame >>= (@?= before)
    , kernelCase "an unbound take resumes the exact staging inode" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        publishUnboundRecord frame
        createFileLink (frameLinkTarget frame) (stagingPath frame)
        staged <- observeAliasIdentity (stagingPath frame)
        runShippedOwnership ownershipRowForHost (takeTransaction frame)
            >>= (@?= ShippedSymbolicLinkRetained staged)
        observeAliasIdentity (frameAlias frame) >>= (@?= staged)
        getSymbolicLinkTarget (frameAlias frame) >>= (@?= frameLinkTarget frame)
        assertAliasBinding frame staged
        doesPathExist (stagingPath frame) >>= (@?= False)
        runShippedOwnership ownershipRowForHost (releaseTransaction frame) >>= (@?= ShippedObjectGivenBack)
        assertRecordPresent frame False
    , kernelCase "an unbound take preserves a regular file at its staging path" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        publishUnboundRecord frame
        ByteString.writeFile (stagingPath frame) "foreign stage"
        before <- recordForAlias frame
        stageIdentity <- observeAliasIdentity (stagingPath frame)
        outcome <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        expectOccupiedAlias outcome
        ByteString.readFile (stagingPath frame) >>= (@?= "foreign stage")
        observeAliasIdentity (stagingPath frame) >>= (@?= stageIdentity)
        recordForAlias frame >>= (@?= before)
        doesPathExist (frameAlias frame) >>= (@?= False)
    , kernelCase "both acts preserve a replaced bound stage while the alias is absent" (replacedAliasStageCase False)
    , kernelCase "both acts preserve a replaced bound stage beside the exact alias" (replacedAliasStageCase True)
    ]

expectOccupiedAlias :: ShippedOutcome -> IO ()
expectOccupiedAlias (ShippedRefused (OwnershipOccupied _)) = pure ()
expectOccupiedAlias other = assertFailure ("expected an occupied refusal, got " <> show other)

expectAliasConflict :: FilePath -> Origin -> Origin -> ShippedOutcome -> IO ()
expectAliasConflict path expected observed outcome =
    outcome @?= ShippedRefused (OwnershipConflict
        ConflictReport
            { conflictSubject = Text.pack path
            , conflictExpected = expected
            , conflictObserved = observed
            })

unboundAliasOccupantCase :: Bool -> AliasFrame -> IO ()
unboundAliasOccupantCase isLink frame = do
    createDirectory (frameLinkTarget frame)
    publishUnboundRecord frame
    if isLink
        then createFileLink (frameLinkTarget frame) (frameAlias frame)
        else ByteString.writeFile (frameAlias frame) "foreign alias"
    before <- recordForAlias frame
    current <- observeAliasIdentity (frameAlias frame)
    runShippedOwnership ownershipRowForHost (releaseTransaction frame)
        >>= expectAliasConflict (frameAlias frame) OriginAbsent (OriginPresent current)
    observeAliasIdentity (frameAlias frame) >>= (@?= current)
    recordForAlias frame >>= (@?= before)
    if isLink
        then getSymbolicLinkTarget (frameAlias frame) >>= (@?= frameLinkTarget frame)
        else ByteString.readFile (frameAlias frame) >>= (@?= "foreign alias")

sameTargetReplacementCase :: (AliasFrame -> ShippedOwnership) -> AliasFrame -> IO ()
sameTargetReplacementCase request frame = do
    createDirectory (frameLinkTarget frame)
    bound <- expectCreated =<< runShippedOwnership ownershipRowForHost (takeTransaction frame)
    before <- recordForAlias frame
    -- Retain the old inode under another name so the filesystem cannot reuse it.
    renameFile (frameAlias frame) (frameAlias frame <> "-original")
    createFileLink (frameLinkTarget frame) (frameAlias frame)
    current <- observeAliasIdentity (frameAlias frame)
    assertBool "the replacement has a different inode" (current /= bound)
    runShippedOwnership ownershipRowForHost (request frame)
        >>= expectAliasConflict (frameAlias frame) (OriginPresent bound) (OriginPresent current)
    observeAliasIdentity (frameAlias frame) >>= (@?= current)
    getSymbolicLinkTarget (frameAlias frame) >>= (@?= frameLinkTarget frame)
    recordForAlias frame >>= (@?= before)

replacedAliasStageCase :: Bool -> AliasFrame -> IO ()
replacedAliasStageCase aliasPresent frame = do
    createDirectory (frameLinkTarget frame)
    publishUnboundRecord frame
    (bound, stagePresent) <-
        if aliasPresent
            then publishBoundAlias frame
            else do
                identity <- publishBoundStaging frame
                pure (identity, True)
    when stagePresent (renameFile (stagingPath frame) (stagingPath frame <> "-original"))
    createFileLink (frameLinkTarget frame) (stagingPath frame)
    current <- observeAliasIdentity (stagingPath frame)
    assertBool "the replacement stage has a different inode" (current /= bound)
    before <- recordForAlias frame
    forM_ [takeTransaction frame, releaseTransaction frame] $ \request -> do
        runShippedOwnership ownershipRowForHost request
            >>= expectAliasConflict (stagingPath frame) (OriginPresent bound) (OriginPresent current)
        observeAliasIdentity (stagingPath frame) >>= (@?= current)
        getSymbolicLinkTarget (stagingPath frame) >>= (@?= frameLinkTarget frame)
        recordForAlias frame >>= (@?= before)
        doesPathExist (frameAlias frame) >>= (@?= aliasPresent)
        when aliasPresent (observeAliasIdentity (frameAlias frame) >>= (@?= bound))

rejected :: TestName -> Text.Text -> FilePath -> FilePath -> TestTree
rejected label reason aliasPath target =
    testCase label $
        case mkGuestAliasSpec aliasPath target of
            Left failure -> failure @?= Failure (FailureDetail "validate provider guest alias" reason DoNotRetry)
            Right _ -> assertFailure "expected the descriptor to be rejected"

assertRight :: Either ReconcileError value -> IO ()
assertRight (Right _) = pure ()
assertRight (Left failure) = assertFailure ("expected the descriptor to be admitted: " <> show failure)

contains :: String -> String -> Bool
contains needle haystack = any (needle `prefixOf`) (tails haystack)
  where
    tails [] = [[]]
    tails value@(_ : rest) = value : tails rest
    prefixOf [] _ = True
    prefixOf _ [] = False
    prefixOf (left : lefts) (right : rights) = left == right && prefixOf lefts rights

data AliasFrame = AliasFrame
    { frameAlias :: FilePath
    , frameLinkTarget :: FilePath
    , frameAuthority :: FilePath
    }

kernelCase :: TestName -> (AliasFrame -> IO ()) -> TestTree
kernelCase name body =
    conditionalCase
        ["ProviderAliasSpec", "the shipped guest alias ownership row"]
        localGuestAliasSupported
        name
        (withFrame body)
        (withFrame refusal)
  where
    withFrame action =
        withSystemTempDirectory "hb-provider-alias" $ \root -> do
            let frame =
                    AliasFrame
                        { frameAlias = root </> "stable-alias"
                        , frameLinkTarget = root </> "durable-target"
                        , frameAuthority = root </> "durable-target" </> ".hostbootstrap-alias-authority-v1"
                        }
            action frame
    refusal frame = do
        outcome <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        case outcome of
            ShippedRefused (OwnershipUnsupported _) -> pure ()
            other -> assertFailure ("expected this host's row to refuse, got " <> show other)

takeTransaction :: AliasFrame -> ShippedOwnership
takeTransaction frame = transaction frame (ShipTakeSymbolicLink (fixtureLinkTarget (frameLinkTarget frame)))

releaseTransaction :: AliasFrame -> ShippedOwnership
releaseTransaction frame = transaction frame (ShipGiveBackSymbolicLink (fixtureLinkTarget (frameLinkTarget frame)))

transaction :: AliasFrame -> ShippedAct -> ShippedOwnership
transaction frame act =
    mkShippedOwnership
        (either (error . show) id (mkShippedAuthorityPath (frameAuthority frame)))
        aliasRecordKey
        (either (error . show) id (mkShippedTargetPath (frameAlias frame)))
        act

fixtureLinkTarget :: FilePath -> ShippedLinkTargetPath
fixtureLinkTarget = either (error . show) id . mkShippedLinkTargetPath

aliasRecordKey :: RecordKey
aliasRecordKey = either (error . show) id (mkRecordKey "guest-alias.spec.record")

publishUnboundRecord :: AliasFrame -> IO ()
publishUnboundRecord frame =
    publishAliasRecord frame
        (originRecord (ReportedObject (mkOwnerClaim (TextEncoding.encodeUtf8 (Text.pack (frameLinkTarget frame))))) OriginAbsent)

publishAliasRecord :: AliasFrame -> OriginRecord -> IO ()
publishAliasRecord frame record = do
    store <- either (assertFailure . show) pure =<< openProtectedStore (frameAuthority frame)
    written <-
        withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord session aliasRecordKey ExpectAbsent (renderOriginRecord record)
    either (assertFailure . show) (const (pure ())) written

publishBoundStaging :: AliasFrame -> IO ObjectIdentity
#ifdef mingw32_HOST_OS
publishBoundStaging _frame = assertFailure "the Windows row cannot publish a POSIX symbolic link"
#else
publishBoundStaging frame = do
    createSymbolicLink (frameLinkTarget frame) (stagingPath frame)
    status <- getSymbolicLinkStatus (stagingPath frame)
    identity <-
        either (assertFailure . show) pure $
            OwnershipFixture.kernelIdentityWords (fromIntegral (deviceID status)) (fromIntegral (fileID status))
    opened <- openProtectedStore (frameAuthority frame)
    store <- either (assertFailure . show) pure opened
    bound <-
        withProtectedEntry store $ \session -> do
            stored <- readProtectedRecord session aliasRecordKey
            case stored of
                Left failure -> pure (Left failure)
                Right Nothing -> assertFailure "the pre-publication origin record vanished"
                Right (Just stamped) -> do
                    record <- either (assertFailure . show) pure (parseOriginRecord (protectedRecordBytes stamped))
                    next <- either (assertFailure . show) pure (bindOriginRecord identity record)
                    compareAndSwapProtectedRecord
                        session
                        aliasRecordKey
                        (ExpectVersion (protectedRecordVersion stamped))
                        (renderOriginRecord next)
    either (assertFailure . show) (const (pure identity)) bound
#endif

-- | Construct the platform publisher's state with its already-bound inode.
-- Linux retains the staging hard link; Darwin moves it into the alias name.
publishBoundAlias :: AliasFrame -> IO (ObjectIdentity, Bool)
#ifdef mingw32_HOST_OS
publishBoundAlias _frame = assertFailure "the Windows row cannot publish a POSIX symbolic link"
#else
publishBoundAlias frame = do
    identity <- publishBoundStaging frame
#ifdef darwin_HOST_OS
    renameFile (stagingPath frame) (frameAlias frame)
    pure (identity, False)
#else
    createLink (stagingPath frame) (frameAlias frame)
    pure (identity, True)
#endif
#endif

observeAliasIdentity :: FilePath -> IO ObjectIdentity
observeAliasIdentity path = do
    observed <- withOwnershipRow ownershipRowForHost (\row -> rowObserveIdentity row path)
    case observed of
        Right (Just identity) -> pure identity
        other -> assertFailure ("expected a present kernel identity, got " <> show other)

recordForAlias :: AliasFrame -> IO (Maybe ProtectedRecord)
recordForAlias frame = do
    store <- either (assertFailure . show) pure =<< openProtectedStore (frameAuthority frame)
    either (assertFailure . show) pure
        =<< withProtectedEntry store (\session -> readProtectedRecord session aliasRecordKey)

assertAliasBinding :: AliasFrame -> ObjectIdentity -> IO ()
assertAliasBinding frame identity = do
    stored <- recordForAlias frame
    case stored of
        Nothing -> assertFailure "the symbolic-link ownership record is absent"
        Just stamped -> do
            record <- either (assertFailure . show) pure (parseOriginRecord (protectedRecordBytes stamped))
            originRecordBinding record @?= Just identity

stagingPath :: AliasFrame -> FilePath
stagingPath frame =
    frameAlias frame <> ".hostbootstrap-shipped-" <> showRecordKey aliasRecordKey

showRecordKey :: RecordKey -> String
showRecordKey = Text.unpack . recordKeyText

assertRecordPresent :: AliasFrame -> Bool -> IO ()
assertRecordPresent frame expected = do
    opened <- openProtectedStore (frameAuthority frame)
    store <- either (assertFailure . show) pure opened
    observed <- withProtectedEntry store (\session -> readProtectedRecord session aliasRecordKey)
    case observed of
        Left failure -> assertFailure (show failure)
        Right record -> assertBool "unexpected durable record presence" (isPresent record == expected)
  where
    isPresent Nothing = False
    isPresent (Just _) = True

expectCreated :: ShippedOutcome -> IO ObjectIdentity
expectCreated (ShippedSymbolicLinkCreated identity) = pure identity
expectCreated other = assertFailure ("expected a created symbolic link, got " <> show other)
