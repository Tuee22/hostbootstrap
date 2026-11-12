{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module WslDiskSpec (tests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as Bytes
import HostBootstrap.Cluster.Cordon.Foundation (ResourceBudget)
import HostBootstrap.Ownership.Object (OwnerClaim, OwnershipFault (OwnershipMalformed), mkOwnerClaim)
import HostBootstrap.Protected (
    Expectation (ExpectAbsent), ProtectedError (ProtectedInvalid), ProtectedRecord (..),
    ProtectedSession, ProtectedStore, compareAndSwapProtectedRecord, listProtectedRecords,
    mkRecordKey, openProtectedStore, readProtectedRecord, recordVersionWord, withProtectedEntry,
 )
import HostBootstrap.Substrate.Provider.Command (ProviderSizing (ProviderSizing))
import HostBootstrap.Substrate.Provider.Ownership (ProviderOwnershipFault (..))
import HostBootstrap.Substrate.Provider.Report (ProviderSizingObservation (RecordedWslStorage), providerSizingBudget)
import HostBootstrap.Substrate.Provider.WslDisk
import Expect (expectRight)
import qualified SourceGuard
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "WslDiskSpec" (codecCases <> storeCases <> [metadataBoundaryCase])

owner, otherOwner :: OwnerClaim
owner = mkOwnerClaim ""
otherOwner = mkOwnerClaim "another owner"

goldenPrefix :: ByteString
goldenPrefix = "hostbootstrap/wsl-disk-cap/v1\0"
    <> "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

diskBudget :: Integer -> IO ResourceBudget
diskBudget bytes = expectRight (providerSizingBudget (ProviderSizing 2 "4GiB" (show bytes)))

codecCases :: [TestTree]
codecCases =
    [ testCase ("the " <> label <> " cap matches an independent binary vector") $ do
        budget <- diskBudget cap
        let wire = goldenPrefix <> Bytes.pack suffix
        encodeWslDiskCap owner budget @?= wire
        classifyWslDiskCap owner wire @?= Right cap
    | (label, cap, suffix) <-
        [ ("minimum", 1, [1,0,0,0,0,0,0,0])
        , ("8-GiB", 8589934592, [0,0,0,0,2,0,0,0])
        , ("signed maximum", 9223372036854775807, [255,255,255,255,255,255,255,127])
        ]
    ] <>
    [ testCase "another owner cannot read a cap as its own" $ do
        budget <- diskBudget 8589934592
        classifyWslDiskCap otherOwner (encodeWslDiskCap owner budget)
            @?= Left (OwnershipMalformed "the WSL disk-cap record belongs to another owner")
    , testCase "CPU and memory changes do not rewrite the original disk metadata" $ do
        original <- diskBudget 8589934592
        changed <- expectRight (providerSizingBudget (ProviderSizing 3 "8GiB" "8GiB"))
        encodeWslDiskCap owner changed @?= encodeWslDiskCap owner original
    ] <>
    [ testCase ("the binary cap refuses " <> label) $
        classifyWslDiskCap owner wire @?= Left (OwnershipMalformed reason)
    | (label, wire, reason) <-
        [ ("empty input", "", "the WSL disk-cap record has an invalid length")
        , ("a truncated body", goldenPrefix <> Bytes.replicate 7 1, "the WSL disk-cap record has an invalid length")
        , ("trailing bytes", goldenPrefix <> Bytes.replicate 9 1, "the WSL disk-cap record has an invalid length")
        , ("a different version", "x" <> Bytes.drop 1 goldenPrefix <> Bytes.replicate 8 1,
            "the WSL disk-cap record has an unknown version")
        , ("invalid owner bytes", Bytes.take (Bytes.length goldenPrefix - 64) goldenPrefix
            <> Bytes.replicate 64 255 <> Bytes.pack [1,0,0,0,0,0,0,0],
            "the WSL disk-cap record belongs to another owner")
        , ("zero", goldenPrefix <> Bytes.replicate 8 0,
            "the recorded WSL disk cap is not positive signed-range bytes")
        , ("unsigned overflow", goldenPrefix <> Bytes.pack [0,0,0,0,0,0,0,128],
            "the recorded WSL disk cap is not positive signed-range bytes")
        ]
    ]

storeCases :: [TestTree]
storeCases =
    [ testCase "a fresh installation publishes one durable version-one cap" $ withDiskStore $ \records -> do
        budget <- diskBudget 8589934592
        withDiskEntry records $ \session -> do
            reconcileWslDiskCap session BeginWslInstallation owner budget >>= (@?= Right (RecordedWslStorage 8589934592))
            held <- onlyDiskRecord session
            protectedRecordBytes held @?= goldenPrefix <> Bytes.pack [0,0,0,0,2,0,0,0]
            recordVersionWord (protectedRecordVersion held) @?= 1
    , testCase "equal retained admission leaves the exact record unchanged" $ withDiskStore $ \records -> do
        budget <- diskBudget 8589934592
        withDiskEntry records $ \session -> do
            _ <- reconcileWslDiskCap session BeginWslInstallation owner budget >>= expectRight
            before <- onlyDiskRecord session
            reconcileWslDiskCap session RequireRecordedWslInstallation owner budget >>= (@?= Right (RecordedWslStorage 8589934592))
            onlyDiskRecord session >>= (@?= before)
    , testCase "an intent survives entry closure before origin publication" $ withDiskStore $ \records -> do
        budget <- diskBudget 8589934592
        before <- withDiskEntry records $ \session -> do
            _ <- reconcileWslDiskCap session BeginWslInstallation owner budget >>= expectRight
            onlyDiskRecord session
        withDiskEntry records $ \session -> do
            reconcileWslDiskCap session BeginWslInstallation owner budget >>= (@?= Right (RecordedWslStorage 8589934592))
            onlyDiskRecord session >>= (@?= before)
    , testCase "CPU and memory remain the separate shared-wall contract" $ withDiskStore $ \records -> do
        original <- diskBudget 8589934592
        changed <- expectRight (providerSizingBudget (ProviderSizing 3 "8GiB" "8GiB"))
        withDiskEntry records $ \session -> do
            _ <- reconcileWslDiskCap session BeginWslInstallation owner original >>= expectRight
            before <- onlyDiskRecord session
            reconcileWslDiskCap session RequireRecordedWslInstallation owner changed >>= (@?= Right (RecordedWslStorage 8589934592))
            onlyDiskRecord session >>= (@?= before)
    , testCase "a retained installation cannot invent a missing original cap" $ withDiskStore $ \records -> do
        budget <- diskBudget 8589934592
        withDiskEntry records $ \session -> do
            reconcileWslDiskCap session RequireRecordedWslInstallation owner budget >>= (@?= Left
                (ProviderOwnershipClause (OwnershipMalformed "the owned WSL installation has no recorded disk cap")))
            listProtectedRecords session >>= (@?= Right [])
    , testCase "foreign metadata is refused and preserved" $ withDiskStore $ \records -> do
        budget <- diskBudget 8589934592
        withDiskEntry records $ \session -> do
            _ <- reconcileWslDiskCap session BeginWslInstallation otherOwner budget >>= expectRight
            before <- onlyDiskRecord session
            reconcileWslDiskCap session RequireRecordedWslInstallation owner budget >>= (@?= Left
                (ProviderOwnershipClause (OwnershipMalformed "the WSL disk-cap record belongs to another owner")))
            onlyDiskRecord session >>= (@?= before)
    , testCase "malformed durable bytes are refused and never replaced" $ withDiskStore $ \records -> do
        budget <- diskBudget 8589934592
        withDiskEntry records $ \session -> do
            key <- expectRight (mkRecordKey "wsl-installed-storage")
            _ <- compareAndSwapProtectedRecord session key ExpectAbsent "corrupt" >>= expectRight
            before <- onlyDiskRecord session
            reconcileWslDiskCap session BeginWslInstallation owner budget >>= (@?= Left
                (ProviderOwnershipClause (OwnershipMalformed "the WSL disk-cap record has an invalid length")))
            onlyDiskRecord session >>= (@?= before)
    , testCase "a captured metadata write refuses after its entry closes" $ withDiskStore $ \records -> do
        budget <- diskBudget 8589934592
        escaped <- withDiskEntry records $ \session ->
            pure (reconcileWslDiskCap session BeginWslInstallation owner budget)
        escaped >>= (@?= Left (ProviderOwnershipStore (ProtectedInvalid "the protected session is no longer live")))
        withDiskEntry records $ \session -> listProtectedRecords session >>= (@?= Right [])
    , testCase "a foreign thread cannot publish in the holder's entry" $ withDiskStore $ \records -> do
        budget <- diskBudget 8589934592
        withDiskEntry records $ \session -> do
            reply <- newEmptyMVar
            void (forkIO (reconcileWslDiskCap session BeginWslInstallation owner budget >>= putMVar reply))
            takeMVar reply >>= (@?= Left
                (ProviderOwnershipStore (ProtectedInvalid "the protected session belongs to another thread")))
            listProtectedRecords session >>= (@?= Right [])
    ] <>
    [ testCase ("changed storage cannot overwrite " <> label) $ withDiskStore $ \records -> do
        original <- diskBudget 8589934592
        changed <- diskBudget 17179869184
        withDiskEntry records $ \session -> do
            _ <- reconcileWslDiskCap session BeginWslInstallation owner original >>= expectRight
            before <- onlyDiskRecord session
            reconcileWslDiskCap session admission owner changed >>= (@?= Left
                (ProviderOwnershipSizing changed (RecordedWslStorage 8589934592)))
            onlyDiskRecord session >>= (@?= before)
    | (label, admission) <- [("an interrupted intent", BeginWslInstallation), ("a retained install", RequireRecordedWslInstallation)]
    ]

metadataBoundaryCase :: TestTree
metadataBoundaryCase = testCase "disk metadata exposes no native-identity query or execution seam" $
    SourceGuard.withPackageSourceIn ["src", "HostBootstrap", "Substrate", "Provider"] $ \_ directory -> do
        source <- readFile (directory </> "WslDisk.hs")
        mapM_ (\name -> assertBool ("metadata imported " <> name)
            (name `notElem` SourceGuard.haskellImports source))
            ["System.Process", "System.Environment", "HostBootstrap.HostConfig",
             "HostBootstrap.Effect.Interpreter", "HostBootstrap.Wsl2.Registration"]
        assertBool "disk metadata uses the shared binary decoder"
            (SourceGuard.importsModule "HostBootstrap.Wire.LittleEndian" source)
        assertBool "disk publication applies the shared tape"
            (SourceGuard.importsModule "HostBootstrap.Ownership.Tape" source)
        SourceGuard.countHaskellIdentifier "publishAbsentRawRecord" source @?= 2
        SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" source @?= 0
        guest <- readFile (directory </> "GuestVm.hs")
        SourceGuard.countHaskellIdentifier "observeWslRegistration" guest @?= 2
        SourceGuard.countHaskellIdentifier "readWslRegistrationKey" guest @?= 0

withDiskStore :: (ProtectedStore -> IO result) -> IO result
withDiskStore consume = withSystemTempDirectory "hostbootstrap-wsl-disk" $ \temporary ->
    openProtectedStore (temporary </> "records") >>= expectRight >>= consume

withDiskEntry :: ProtectedStore -> (forall session. ProtectedSession session -> IO result) -> IO result
withDiskEntry records consume =
    withProtectedEntry records (\session -> Right <$> consume session) >>= expectRight

onlyDiskRecord :: ProtectedSession session -> IO ProtectedRecord
onlyDiskRecord session = do
    keys <- listProtectedRecords session >>= expectRight
    case keys of
        [key] -> do
            found <- readProtectedRecord session key >>= expectRight
            maybe (assertFailure "the published cap vanished") pure found
        _ -> assertFailure ("expected one cap record, got " <> show keys)
