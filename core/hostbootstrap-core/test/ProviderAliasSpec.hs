{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module ProviderAliasSpec (tests, aliasGuest, localGuestAliasSupported) where

import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified FakeProvider
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    ObjectKind (ReportedObject),
    Origin (OriginAbsent),
    OwnershipFault (OwnershipOccupied, OwnershipUnsupported),
    mkOwnerClaim,
    originRecord,
    renderOriginRecord,
 )
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Ownership.Shipped
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    RecordKey,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    openProtectedStore,
    readProtectedRecord,
    recordKeyText,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile (ReconcileError)
import HostBootstrap.Substrate.Provider (RawProviderOutcome (RawProviderFailure))
import HostBootstrap.Substrate.Provider.Alias
import System.Directory (
    createDirectory,
    createFileLink,
    doesDirectoryExist,
    doesPathExist,
    getSymbolicLinkTarget,
    pathIsSymbolicLink,
    removeFile,
 )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
#ifndef mingw32_HOST_OS
import HostBootstrap.Ownership.Object (bindOriginRecord, mkKernelObjectIdentity, parseOriginRecord)
import HostBootstrap.Ownership.Row (hostOwnershipSupported)
import HostBootstrap.Protected (Expectation (ExpectVersion), ProtectedRecord (protectedRecordBytes, protectedRecordVersion))
import System.Posix.Files (createSymbolicLink, deviceID, fileID, getSymbolicLinkStatus)
#endif

tests :: TestTree
tests =
    testGroup
        "ProviderAliasSpec"
        [ testGroup "the closed guest alias descriptor" descriptorCases
        , testGroup "the shipped guest alias ownership row" ownershipCases
        ]

descriptorCases :: [TestTree]
descriptorCases =
    [ rejected "a relative alias" "tmp/alias" "/srv/data"
    , rejected "a relative target" "/tmp/alias" "srv/data"
    , rejected "a Windows alias" "C:\\alias" "/srv/data"
    , rejected "the guest root" "/" "/srv/data"
    , rejected "a trailing slash" "/srv/alias/" "/srv/data"
    , rejected "a dot segment" "/srv/./alias" "/srv/data"
    , rejected "a dot-dot segment" "/srv/x/../alias" "/srv/data"
    , rejected "an empty segment" "/srv//alias" "/srv/data"
    , rejected "the target itself" "/srv/data" "/srv/data"
    , testCase "distinct canonical absolute POSIX paths are admitted" $
        assertRight (mkGuestAliasSpec "/srv/hostbootstrap" "/srv/hostbootstrap/data")
    , testCase "the shipped authority stays in the guest's POSIX grammar" $ do
        spec <- either (assertFailure . show) pure (mkGuestAliasSpec "/srv/hostbootstrap" "/mnt/c/demo/data")
        shippedAuthority (guestAliasOwnershipTransaction spec (ShipTakeSymbolicLink "/mnt/c/demo/data"))
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

ownershipCases :: [TestTree]
ownershipCases =
    [ kernelCase "create, exact retry, and release use one durable identity" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        first <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        identity <- expectCreated first
        pathIsSymbolicLink (frameAlias frame) >>= assertBool "the alias is a symbolic link"
        getSymbolicLinkTarget (frameAlias frame) >>= (@?= frameLinkTarget frame)
        second <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        second @?= ShippedSymbolicLinkRetained identity
        released <- runShippedOwnership ownershipRowForHost (releaseTransaction frame)
        released @?= ShippedObjectGivenBack
        doesPathExist (frameAlias frame) >>= assertBool "the alias was removed" . not
        doesDirectoryExist (frameLinkTarget frame) >>= assertBool "the durable target remains"
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
        case resumed of
            ShippedSymbolicLinkRetained _ -> pure ()
            other -> assertFailure ("expected a retained recovery, got " <> show other)
        assertRecordPresent frame True
    , kernelCase "an interruption after pre-publication identity binding resumes that exact inode" $ \frame -> do
        createDirectory (frameLinkTarget frame)
        publishUnboundRecord frame
        publishBoundStaging frame
        resumed <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        identity <- case resumed of
            ShippedSymbolicLinkRetained value -> pure value
            other -> assertFailure ("expected a retained published link, got " <> show other)
        retried <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
        retried @?= ShippedSymbolicLinkRetained identity
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

rejected :: TestName -> FilePath -> FilePath -> TestTree
rejected label aliasPath target =
    testCase label $ assertLeft (mkGuestAliasSpec aliasPath target)

assertLeft :: Either ReconcileError value -> IO ()
assertLeft (Left _) = pure ()
assertLeft (Right _) = assertFailure "expected the descriptor to be rejected"

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
    testCase name $
        withSystemTempDirectory "hb-provider-alias" $ \root -> do
            let frame =
                    AliasFrame
                        { frameAlias = root </> "stable-alias"
                        , frameLinkTarget = root </> "durable-target"
                        , frameAuthority = root </> "durable-target" </> ".hostbootstrap-alias-authority-v1"
                        }
            if localGuestAliasSupported
                then body frame
                else do
                    outcome <- runShippedOwnership ownershipRowForHost (takeTransaction frame)
                    case outcome of
                        ShippedRefused (OwnershipUnsupported _) -> pure ()
                        other -> assertFailure ("expected this host's row to refuse, got " <> show other)

takeTransaction :: AliasFrame -> ShippedOwnership
takeTransaction frame = transaction frame (ShipTakeSymbolicLink (frameLinkTarget frame))

releaseTransaction :: AliasFrame -> ShippedOwnership
releaseTransaction frame = transaction frame (ShipGiveBackSymbolicLink (frameLinkTarget frame))

transaction :: AliasFrame -> ShippedAct -> ShippedOwnership
transaction frame act =
    ShippedOwnership
        { shippedAuthority = frameAuthority frame
        , shippedRecord = aliasRecordKey
        , shippedTarget = frameAlias frame
        , shippedAct = act
        }

aliasRecordKey :: RecordKey
aliasRecordKey = either (error . show) id (mkRecordKey "guest-alias.spec.record")

publishUnboundRecord :: AliasFrame -> IO ()
publishUnboundRecord frame = do
    opened <- openProtectedStore (frameAuthority frame)
    store <- either (assertFailure . show) pure opened
    written <-
        withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord
                session
                aliasRecordKey
                ExpectAbsent
                ( renderOriginRecord
                    ( originRecord
                        (ReportedObject (mkOwnerClaim (ByteString.pack (map (fromIntegral . fromEnum) (frameLinkTarget frame)))))
                        OriginAbsent
                    )
                )
    case written of
        Left failure -> assertFailure (show failure)
        Right _version -> pure ()

publishBoundStaging :: AliasFrame -> IO ()
#ifdef mingw32_HOST_OS
publishBoundStaging _frame = assertFailure "the Windows row cannot publish a POSIX symbolic link"
#else
publishBoundStaging frame = do
    createSymbolicLink (frameLinkTarget frame) (stagingPath frame)
    status <- getSymbolicLinkStatus (stagingPath frame)
    identity <-
        either (assertFailure . show) pure $
            mkKernelObjectIdentity (fromIntegral (deviceID status)) (fromIntegral (fileID status))
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
    either (assertFailure . show) (const (pure ())) bound
#endif

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

aliasGuest :: FakeProvider.GuestHandler
aliasGuest _root _name _role argv =
    pure (RawProviderFailure ("the legacy alias guest driver is unavailable: " <> show argv))

localGuestAliasSupported :: Bool
#ifdef mingw32_HOST_OS
localGuestAliasSupported = False
#else
localGuestAliasSupported = hostOwnershipSupported
#endif
