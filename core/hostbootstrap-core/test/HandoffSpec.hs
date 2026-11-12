{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The authenticated cross-frame handoff value and cryptography layer.

These cases use real Ed25519 signatures and real protected stores. Ordinary
grant issuance consumes tokens in the root store. Recovery verification uses a
test-local deterministic Ed25519 oracle over the dynamic canonical binding;
authenticated-root-scope verification uses the same public-only oracle shape.
Public consumer packages cannot obtain signing admission; the selected private
test route separately exercises fixed-domain production signers.
-}
module HandoffSpec (tests, runFrameInterpreterFailureProbe, runPrivateProtocolStdioProbe, runChildGroupProbe, frameChildFixtureInterpreter, windowsChildGroupObservationSupported, siblingConfigSymlinksSupported) where

import qualified CompileFailSpec
import ConditionalCase (conditionalCase)
import Control.Concurrent (MVar, ThreadId, forkFinally, forkIO, killThread, newEmptyMVar, putMVar, readMVar, takeMVar, threadDelay)
import Control.Exception (AsyncException (ThreadKilled, UserInterrupt), IOException, SomeException, bracket, evaluate, finally, fromException, mask, throwIO, throwTo, try)
import Control.Monad (forM, forM_, unless, when)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import qualified Crypto.PubKey.Ed25519 as Ed25519
import qualified Data.Aeson as Aeson
import Data.ByteArray (convert)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (isSpace, toUpper)
import Data.Either (isLeft)
import Data.Foldable (traverse_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Kind (Type)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, nub, sort, stripPrefix)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word32, Word64, Word8)
import Expect (expectRight)
import qualified Fixture
import GHC.Conc (BlockReason (BlockedOnMVar), ThreadStatus (ThreadBlocked), threadStatus)
import GHC.IO.Exception (IOErrorType (UnsupportedOperation))
import qualified HostBootstrap.Activation as Activation
import HostBootstrap.Authority (
    InstalledProjectIdentity,
    ProjectVerb (ProjectDestroy, ProjectDown, ProjectUp),
    VerbDown,
    VerbUp,
    installedProjectName,
    verifyOsPrincipal,
 )
import qualified HostBootstrap.Authority.Testing as AuthorityFixture
import HostBootstrap.Config.Class (
    ProjectCfg (withProductionProjectCodec),
    ProjectCodec,
    projectCodecSpecDigest,
    renderProjectCodecHoisted,
 )
import HostBootstrap.Config.Schema (
    ConfigWireAdmissionError (..),
    SiblingConfigInstallError (..),
    SiblingConfigInstallResult (..),
    installAuthenticatedHarnessSiblingConfig,
    installAuthenticatedProductionSiblingConfig,
    siblingProjectConfigPath,
    validatedConfigDigest,
    validatedConfigSpecDigest,
    validatedConfigValue,
    verifiedConfigDigest,
    withAuthenticatedConfigWire,
    withValidatedConfig,
    withVerifiedConfigHandoff,
 )
import HostBootstrap.Config.Vocab (
    Harness,
    HarnessAuthority,
    Production,
    harnessRunName,
 )
import qualified HostBootstrap.Context as Context
import qualified HostBootstrap.Effect.ChildGroup as ChildGroup
import HostBootstrap.Handoff
import qualified HostBootstrap.Handoff.Internal as HandoffInternal
import qualified HostBootstrap.Handoff.Protocol as Protocol
import qualified HostBootstrap.Handoff.Receiver as Receiver
import qualified HostBootstrap.Handoff.Relay as Relay
import qualified HostBootstrap.Handoff.Rooted as Rooted
import HostBootstrap.Handoff.Transaction (
    FrameAnswer (FrameOutcome, FrameRefusal, FrameUnexpected),
    classifyFrameChild,
    frameChildArguments,
    frameInterpreter,
    readFrameAnswer,
    runFrameChildEntry,
    withFrameChildTransaction,
 )
import qualified HostBootstrap.Ownership.Object as Ownership
import qualified HostBootstrap.Ownership.Shipped as Shipped
import HostBootstrap.HostConfig (HostConfig (..))
import qualified HostBootstrap.Lifecycle.Dependency.Internal as Dependency
import HostBootstrap.Lifecycle.Mode (
    ModeError,
    VerifiedIncompleteRunLease,
    harnessPreconditions,
    harnessRootAuthority,
    harnessRootHarnessAuthority,
    productionRootAuthority,
    recoverAbandonedHarnessRuns,
    withHarnessRoot,
    withProductionRoot,
 )
import HostBootstrap.Lift (InVMSelfPath (InVMSelfPath), LocalSelfPath (LocalSelfPath), localContext, mkSelfRef)
import HostBootstrap.Lift.Context (
    ConfigDelivery (..),
    ContainerLift (..),
    ContainerPlacement (ProviderGuestContainer),
    IncusVM (..),
    emptyVMStack,
    inContainer,
    inVM,
    vmContext,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError (ProtectedIOFailure),
    ProtectedStore,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    openProtectedStore,
    protectedStoreIdentity,
    protectedStoreIdentityText,
    protectedStoreRoot,
    protectedRecordBytes,
    protectedRecordVersion,
    readProtectedRecord,
    recordKeyText,
    recordVersionWord,
    withProtectedEntry,
 )
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import Numeric (showHex)
import SourceGuard (
    fieldModules,
    indentation,
    mainLibraryStanza,
    normalizeWhitespace,
    readHaskellSources,
    significantHaskellLineCount,
    trim,
 )
import qualified SourceGuard
import System.Directory (createDirectory, createFileLink, doesPathExist, listDirectory, pathIsSymbolicLink, removePathForcibly)
import System.Environment (getExecutablePath, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (takeDirectory, (<.>), (</>))
import System.IO (Handle, hClose, hFlush, hIsClosed, hSetBinaryMode, stderr, stdout)
import System.IO.Error (ioeGetErrorString, ioeGetErrorType, isDoesNotExistError, isPermissionError)
import System.IO.Temp (withSystemTempDirectory, withTempDirectory)
import System.IO.Unsafe (unsafePerformIO)
import System.Process (
    CreateProcess (close_fds, create_group, std_err, std_in, std_out),
    ProcessHandle,
    StdStream (CreatePipe, Inherit, NoStream),
    createPipe,
    getProcessExitCode,
    proc,
    terminateProcess,
    waitForProcess,
    withCreateProcess,
 )
import System.Timeout (timeout)
import Text.Read (readMaybe)
#if defined(mingw32_HOST_OS)
import Control.Exception (onException)
import Data.Bits ((.|.))
import GHC.Windows (BOOL, DWORD, HANDLE, failIfFalse_, failIfNull, throwGetLastError)
import System.Process (createProcess)
#endif
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "HandoffSpec"
        [ testGroup "source guard contracts" sourceGuardTests
        , testGroup "length framing" framingTests
        , testGroup "protocol decoder and child-state DATA" protocolDataTests
        , testGroup "binding rendering" bindingTests
        , testGroup "the signed handoff protocol" protocolTests
        , testGroup "sibling config symlinks" siblingConfigSymlinkTests
        , testGroup "the keyless duplex relay" duplexRelayTests
        , testGroup "the scripted scope-first receiver" receiverScriptTests
        , testGroup "the bounded rooted recovery carrier" receiverCarrierTests
        , testGroup "the actual rooted requester transport" rootedRequesterTransportTests
        , testGroup "the recovery wire" recoveryTests
        , testGroup "the lifecycle completion wire" lifecycleCompletionWireTests
        , testGroup "the durable lifecycle acknowledgement substrate" lifecycleAcknowledgementSubstrateTests
        , testGroup "the sealed facade" sealedFacadeTests
        , testGroup "the frame-child entry" frameCrossingTests
        , testGroup "native Windows child groups" windowsChildGroupTests
        ]

data SiblingSymlinkCapability
    = SiblingSymlinkAvailable
    | SiblingSymlinkRefused IOException
    | SiblingSymlinkProbeFailed String

{-# NOINLINE siblingSymlinkCapability #-}
siblingSymlinkCapability :: SiblingSymlinkCapability
siblingSymlinkCapability = unsafePerformIO $ do
    observed <- try @IOException $ do
        executable <- getExecutablePath
        withTempDirectory (takeDirectory executable) ".hostbootstrap-symlink-capability" $ \directory -> do
            let target = directory </> "target"
                link = directory </> "link"
            ByteString.writeFile target "symlink control"
            ByteString.readFile target >>= \bytes ->
                unless (bytes == "symlink control") (ioError (userError "symlink control changed bytes"))
            created <- try @IOException (createFileLink target link)
            case created of
                Left failure
                    | unavailableSiblingSymlink failure -> pure (SiblingSymlinkRefused failure)
                    | otherwise -> pure (SiblingSymlinkProbeFailed (show failure))
                Right () -> do
                    linked <- pathIsSymbolicLink link
                    bytes <- ByteString.readFile link
                    unless (linked && bytes == "symlink control")
                        (ioError (userError "actual symlink inspection changed identity or bytes"))
                    pure SiblingSymlinkAvailable
    pure (either (SiblingSymlinkProbeFailed . show) id observed)

unavailableSiblingSymlink :: IOException -> Bool
unavailableSiblingSymlink failure =
    isPermissionError failure || ioeGetErrorType failure == UnsupportedOperation

siblingConfigSymlinksSupported :: Bool
siblingConfigSymlinksSupported = case siblingSymlinkCapability of
    SiblingSymlinkAvailable -> True
    _ -> False

siblingConfigSymlinkTests :: [TestTree]
siblingConfigSymlinkTests =
    [ row "authenticated sibling install refuses a symlinked destination" $
        withProductionSibling $ \project authenticated path _ ->
            withSystemTempDirectory "hostbootstrap-sibling-symlink-target" $ \directory -> do
                let target = directory </> "target"
                ByteString.writeFile target "destination target"
                createFileLink target path
                installAuthenticatedProductionSiblingConfig project authenticated
                    >>= (@?= Left (SiblingConfigUnsafeDestination path))
                pathIsSymbolicLink path >>= (@?= True)
                ByteString.readFile target >>= (@?= "destination target")
    , row "authenticated sibling install refuses a symlinked lock" $
        withProductionSibling $ \project authenticated path _ ->
            withSystemTempDirectory "hostbootstrap-sibling-lock-target" $ \directory -> do
                let target = directory </> "target"
                    lockPath = path <> ".hostbootstrap-handoff.lock"
                ByteString.writeFile target "lock target"
                createFileLink target lockPath
                installAuthenticatedProductionSiblingConfig project authenticated
                    >>= (@?= Left (SiblingConfigInstallFailed path))
                pathIsSymbolicLink lockPath >>= (@?= True)
                ByteString.readFile target >>= (@?= "lock target")
                doesPathExist path >>= (@?= False)
    ]
  where
    row name action =
        conditionalCase ["HandoffSpec", "sibling config symlinks"] siblingConfigSymlinksSupported
            name action $ case siblingSymlinkCapability of
                SiblingSymlinkRefused failure -> do
                    assertBool (show failure) (unavailableSiblingSymlink failure)
                    putStrLn ("Unsupported: actual sibling-filesystem symlink creation refused: " <> show failure)
                SiblingSymlinkProbeFailed reason ->
                    assertFailure ("actual sibling-filesystem symlink probe failed: " <> reason)
                SiblingSymlinkAvailable ->
                    assertFailure "the actual sibling filesystem supports symlinks but selected a refusal"

withProductionSibling ::
    ( forall projectId brokerGeneration.
      InstalledProjectIdentity projectId ->
      AuthenticatedConfigPayload (Production projectId) brokerGeneration ->
      FilePath ->
      ByteString.ByteString ->
      IO ()
    ) ->
    IO ()
withProductionSibling use =
    withNamedHandoff 15 ProjectUp $ \(project :: InstalledProjectIdentity projectId) broker ->
        withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \codec -> do
            let projectName = installedProjectName project
                cfg = Fixture.defaultProjectConfig projectName "/workspace/demo" Context.HostOrchestrator
                payload = canonicalConfigBytes codec cfg
            authenticated <- authenticatedPayload broker payload
            path <- siblingProjectConfigPath projectName
            withCleanSiblingDestination path (use project authenticated path payload)

withCleanSiblingDestination :: FilePath -> IO () -> IO ()
withCleanSiblingDestination path action = do
    let cleanup = removeIfPresent path >> removeIfPresent (path <> ".hostbootstrap-handoff.lock")
    cleanup
    (action `finally` assertNoSiblingTemporaries path) `finally` cleanup

assertNoSiblingTemporaries :: FilePath -> IO ()
assertNoSiblingTemporaries path = do
    entries <- listDirectory (takeDirectory path)
    filter (".hostbootstrap-config.tmp" `isPrefixOf`) entries @?= []

awaitSiblingStartBarrier :: [ThreadId] -> IO ()
awaitSiblingStartBarrier workers = do
    states <- traverse threadStatus workers
    let waiting state = case state of
            ThreadBlocked BlockedOnMVar -> True
            _ -> False
    unless (all waiting states) (threadDelay 1000 >> awaitSiblingStartBarrier workers)

-- ---------------------------------------------------------------------------
-- The frame-child entry

{- | The far side of a frame crossing, and the near side that reaches it.

The classifier is covered over its whole argument space rather than over the
one vector that works, because everything it must /not/ recognize is the part
an operator can reach: the marker is in the binary on every host, and the only
thing standing between an ordinary invocation and the child body is this
comparison.

The crossing itself is run as a real process. The parent folds a local lift
context, launches this suite's own executable at the leaf argv, sends one
transaction, and reads what comes back — through the production classifier and
the production child body, so what the case proves is a process boundary rather
than a description of one.
-}
frameCrossingTests :: [TestTree]
frameCrossingTests =
    [ testCase "a frame child is exactly the folded leaf argument vector" $ do
        length frameChildArguments @?= 1
        assertBool
            "the marker is not a verb an operator would reach for"
            (all ("--hostbootstrap-" `isPrefixOf`) frameChildArguments)
        assertBool
            "the folded leaf argv is a frame child"
            (isJust (classifyFrameChild frameChildArguments))
        traverse_
            ( \argv ->
                assertBool
                    (show argv <> " is not a frame child")
                    (isNothing (classifyFrameChild argv))
            )
            [ []
            , [""]
            , ["project", "up"]
            , ["--help"]
            , ["--version"]
            , frameChildArguments <> ["up"]
            , "project" : frameChildArguments
            , frameChildArguments <> frameChildArguments
            , map (<> "x") frameChildArguments
            , map (drop 1) frameChildArguments
            , map (" " <>) frameChildArguments
            , map (<> "=") frameChildArguments
            , map (map toUpper) frameChildArguments
            ]
    , testCase "the marker names nothing the parser or the command tree offers" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- concat <$> traverse readHaskellSources
                [packageRoot </> "src", packageRoot </> "internal", packageRoot </> "app"]
            forM_ frameChildArguments $ \marker -> do
                let users spelling = sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellTokenSequence [show spelling] source > 0
                        ]
                users marker @?= ["src/HostBootstrap/Handoff/Transaction.hs"]
                sum [SourceGuard.countHaskellTokenSequence [show marker] source | (_, source) <- sources] @?= 1
                users (dropWhile (== '-') marker) @?= []
    , testCase "one answer is read against the one request it must answer" $ do
        readFrameAnswer 1 1 (FrameOutcome "settled") @?= Right "settled"
        readFrameAnswer 1 1 (FrameOutcome "") @?= Right ""
        readFrameAnswer 1 1 (FrameRefusal "unavailable" "no interpreter")
            @?= Left "frame child: the frame refused the transaction: unavailable: no interpreter"
        readFrameAnswer 1 1 (FrameUnexpected "OfferTag" 4)
            @?= Left "frame child: the child answered OfferTag with 4 fields"
        readFrameAnswer 1 2 (FrameOutcome "settled")
            @?= Left "frame child: the child answered request 2 rather than 1"
        readFrameAnswer 1 2 (FrameRefusal "unavailable" "no interpreter")
            @?= Left "frame child: the child answered request 2 rather than 1"
        readFrameAnswer 7 7 (FrameOutcome "settled") @?= Right "settled"
    , testCase "a crossing whose host tool resolves nowhere never launches" $ do
        executable <- getExecutablePath
        crossed <-
            withFrameChildTransaction
                unresolvedHostConfig
                (mkSelfRef (LocalSelfPath executable) (InVMSelfPath executable))
                (vmContext (inVM IncusVM{vmName = "absent", vmImage = "absent"} emptyVMStack))
                "one transaction"
        crossed @?= Left "frame child: the crossing's host tool resolves to no absolute path"
    , testCase "a frame transaction refuses staged config delivery before resolving a crossing" $ do
        executable <- getExecutablePath
        let self = mkSelfRef (LocalSelfPath executable) (InVMSelfPath executable)
            container =
                ContainerLift
                    { clImage = "frame-transaction:unused"
                    , clPlacement = ProviderGuestContainer
                    , clMounts = []
                    , clExtraArgs = []
                    , clRemoveAfter = False
                    , clConfigDelivery = Just (ConfigDelivery "/app/project.dhall" "inert projection")
                    }
            contexts =
                [ inContainer container emptyVMStack
                , inContainer container (inVM IncusVM{vmName = "absent", vmImage = "absent"} emptyVMStack)
                ]
        forM_ contexts $ \context -> do
            crossed <- withFrameChildTransaction unresolvedHostConfig self context "one transaction"
            crossed @?= Left "frame child: the frame transaction cannot launch staged container config delivery"
    , testCase "a local crossing answers one transaction across a real process boundary" $ do
        executable <- getExecutablePath
        crossed <-
            boundedHandoff "the local frame crossing" $ withFrameChildTransaction
                unresolvedHostConfig
                (mkSelfRef (LocalSelfPath executable) (InVMSelfPath executable))
                localContext
                "hostbootstrap/cluster-exposure/request/v1\0"
        crossed @?= Left "frame child: the frame refused the transaction: unavailable: the cluster exposure request does not contain exactly three fields"
    , testCase "a local ownership crossing returns a decoded malformed-input refusal" $ do
        executable <- getExecutablePath
        crossed <-
            boundedHandoff "the ownership decode-refusal crossing" $
                withFrameChildTransaction
                    unresolvedHostConfig
                    (mkSelfRef (LocalSelfPath executable) (InVMSelfPath executable))
                    localContext
                    "not an ownership transaction"
        case crossed of
            Left failure -> assertFailure ("expected an encoded ownership refusal, got " <> Text.unpack failure)
            Right raw -> case Shipped.decodeShippedOutcome raw of
                Right (Shipped.ShippedRefused (Ownership.OwnershipMalformed _)) -> pure ()
                other -> assertFailure ("expected the frame's malformed-input refusal, got " <> show other)
    , testCase "the argument vector is read once, by the classifier, before the parser" $
        withHandoffPackageRoot $ \packageRoot -> do
            cliSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.CLI")
            SourceGuard.countHaskellIdentifier "getArgs" cliSource @?= 2
            SourceGuard.countHaskellIdentifier "classifyFrameChild" cliSource @?= 2
            SourceGuard.countHaskellIdentifier "runFrameChildEntry" cliSource @?= 2
            cliDefinition <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "runCLI" cliSource)
            takeWhile (/= "where") cliDefinition @?= SourceGuard.haskellTokens
                (unlines
                    [ "runCLI project finalizedSpec testCodec progName projectArtifacts testSuite checkCode assemblyInputs assemble initBuilder testInit = do"
                    , "argv <- getArgs"
                    , "if argv == installedIdentityEntryArguments"
                    , "then installIdentityForInvokedExecutable"
                    , "else case runExposureRelayEntry argv of"
                    , "Just relay -> relay"
                    , "Nothing -> if take 1 argv == workingDirectoryEntryArguments"
                    , "then runWorkingDirectoryEntry (drop 1 argv)"
                    , "else if argv == shippedCommandEntryArguments"
                    , "then runShippedCommandEntry"
                    , "else if argv == lifecycleChildArguments"
                    , "then runForwardLifecycleChild project finalizedSpec"
                    , "else case classifyFrameChild argv of"
                    , "Just entry -> runFrameChildEntry (frameInterpreter interpretFrameTransaction) entry"
                    , "Nothing -> join (customExecParser (prefs showHelpOnEmpty) opts)"
                    ])
            traverse_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier cliSource @?= 0)
                ["getProgName", "lookupEnv", "getEnvironment", "withArgs"]
            transactionSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Transaction")
            forM_ ["timeout", "launchMicros", "CPP"] $ \identifier ->
                SourceGuard.countHaskellIdentifier identifier transactionSource @?= 0
            traverse_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier transactionSource @?= 0)
                [ "ProtectedStore"
                , "BrokerLink"
                , "RootBroker"
                , "InstalledProjectIdentity"
                , "ProjectSigningKey"
                , "ProjectVerificationKey"
                , "ProjectSpec"
                , "CommandAuthority"
                , "lookupEnv"
                , "getEnvironment"
                , "getArgs"
                , "unsafeCoerce"
                ]
            -- One fold selects the crossing; the process callback delegates
            -- cleanup to its group owner rather than repeating its reaper.
            crossing <-
                either
                    (\failure -> assertFailure ("could not read the frame transaction binding: " <> failure) >> pure [])
                    pure
                    (SourceGuard.haskellDefinitionTokens "withFrameChildTransaction" transactionSource)
            forM_ ["foldLift", "frameChildArguments", "withChildGroupProcess", "endChildGroup"] $ \identifier ->
                length (filter (== identifier) crossing) @?= 1
            assertBool
                "the exchange is bracketed by the shared child-group cleanup"
                ( SourceGuard.haskellTokens
                    "Exception.bracket_ (pure ()) (endChildGroup group child childStdin childStdout) (exchange childStdin childStdout)"
                    `isInfixOf` crossing
                )
            forM_ ["askChildGroupToStop", "awaitChildGroupExit", "killChildGroup", "waitForProcess"] $ \identifier ->
                length (filter (== identifier) crossing) @?= 0
            assertBool
                "shared CLI lost the frame-child classifier"
                (significantHaskellLineCount cliSource >= 424)
    , testCase "the actual frame child refuses malformed streams and a decoded wrong tag" $ do
        wrongTag <- expectRight (Protocol.protocolMessage Protocol.ChallengeTag 29 [ByteString.replicate 32 7])
        wrongTagRefusal <- expectRight (Protocol.protocolMessage Protocol.RefusedTag 29
            ["unavailable", "expected a frame transaction, saw ChallengeTag"])
        transaction <- expectRight (Protocol.protocolMessage Protocol.FrameTransactionTag 29 ["transaction"])
        let extraField = frameWire (ByteString.drop 8 (Protocol.encodeProtocolMessage transaction) <> frameWire "")
            protocolDiagnostic failure = "frame child: frame child: " <> Text.pack (Protocol.protocolErrorMessage failure)
            cases =
                [ ("empty input", ByteString.empty, ByteString.empty, protocolDiagnostic (Protocol.ProtocolTruncated 8 0))
                , ("bad magic", frameWire (ByteString.replicate 15 0), ByteString.empty, protocolDiagnostic Protocol.ProtocolBadMagic)
                , ("decoded wrong tag", Protocol.encodeProtocolMessage wrongTag, Protocol.encodeProtocolMessage wrongTagRefusal,
                    "frame child: expected a frame transaction, saw ChallengeTag")
                , ("two transaction fields", extraField, ByteString.empty,
                    protocolDiagnostic (Protocol.ProtocolExcessFields Protocol.FrameTransactionTag 1 8))
                ]
        forM_ cases $ \(label, input, expectedOutput, expectedDiagnostic) -> do
            (status, output, diagnostic) <- runFrameBinary frameChildArguments input
            assertBool (label <> " fails rather than starting the parser") (status /= ExitSuccess)
            output @?= expectedOutput
            Text.strip (TextEncoding.decodeUtf8 diagnostic) @?= expectedDiagnostic
    , testCase "an interpreter IOException sends one refusal and rethrows the original exception" $ do
        transaction <- expectRight (Protocol.protocolMessage Protocol.FrameTransactionTag 37 ["the failing transaction"])
        refusal <- expectRight (Protocol.protocolMessage Protocol.RefusedTag 37 ["unavailable", "the frame interpreter failed"])
        (status, output, diagnostic) <- runFrameBinary
            ["--hostbootstrap-frame-io-failure-probe"] (Protocol.encodeProtocolMessage transaction)
        assertBool "the interpreter exception exits unsuccessfully" (status /= ExitSuccess)
        output @?= Protocol.encodeProtocolMessage refusal
        diagnostic @?= frameInterpreterFailureConfirmation
    , testCase "private protocol stdio isolates ordinary output and restores stdout" $ do
        (status, output, diagnostic) <- runFrameBinary ["--hostbootstrap-private-protocol-stdio-probe"] ByteString.empty
        status @?= ExitSuccess
        diagnostic @?= privateProtocolInsideMarker
        (body, afterProtocol) <- expectRight (takeHandoffFrame output)
        message <- expectRight (Protocol.decodeProtocolMessage (frameWire body))
        Protocol.protocolMessageTag message @?= Protocol.FrameOutcomeTag
        Protocol.protocolMessageRequestId message @?= 41
        Protocol.protocolMessageFields message @?= ["the private protocol output"]
        afterProtocol @?= privateProtocolAfterMarker
    , testCase "private stdio acquisition and both global redirects retain cleanup" $
        withHandoffPackageRoot $ \packageRoot -> do
            (protocolSource, _) <- readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Protocol"
            let definition name = either assertFailure pure (SourceGuard.haskellDefinitionTokens name protocolSource)
            definition "openProtocolStdio" >>= (@?= SourceGuard.haskellTokens (unlines
                [ "openProtocolStdio = do"
                , "hFlush stdout"
                , "inbound <- hDuplicate stdin"
                , "outbound <- hDuplicate stdout `onException` closeQuietly inbound"
                , "savedIn <- hDuplicate stdin `onException` mapM_ closeQuietly [outbound, inbound]"
                , "savedOut <- hDuplicate stdout `onException` mapM_ closeQuietly [savedIn, outbound, inbound]"
                , "sink <- openFile nullDevicePath ReadMode `onException` mapM_ closeQuietly [savedOut, savedIn, outbound, inbound]"
                , "pure (inbound, outbound, savedIn, savedOut, sink)"
                ]))
            definition "isolateGlobalStdio" >>= (@?= SourceGuard.haskellTokens (unlines
                [ "isolateGlobalStdio savedIn savedOut sink = do"
                , "hFlush stdout"
                , "hDuplicateTo sink stdin `onException` restoreGlobalStdio savedIn savedOut"
                , "hDuplicateTo stderr stdout `onException` restoreGlobalStdio savedIn savedOut"
                ]))
            definition "withPrivateProtocolStdio" >>= (@?= SourceGuard.haskellTokens (unlines
                [ "withPrivateProtocolStdio use ="
                , "bracket openProtocolStdio closeProtocolStdio $"
                , "\\(inbound, outbound, savedIn, savedOut, sink) ->"
                , "bracket_ (isolateGlobalStdio savedIn savedOut sink)"
                , "(restoreGlobalStdio savedIn savedOut)"
                , "(handoffChannel inbound outbound >>= use)"
                ]))
            (transactionSource, _) <- readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Transaction"
            serving <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "serveOneFrameTransaction" transactionSource)
            assertBool "only the interpreter's IOException receives the fixed refusal before rethrow"
                (SourceGuard.haskellTokens (unlines
                    [ "interpret transaction `Exception.catch` \\(failure :: Exception.IOException) -> do"
                    , "_ <- sendRefusal channel (protocolMessageRequestId message) \"the frame interpreter failed\""
                    , "Exception.throwIO failure"
                    ]) `isInfixOf` serving)
            forM_ ["SomeException", "mask", "uninterruptibleMask", "finally"] $ \identifier ->
                length (filter (== identifier) serving) @?= 0
    ]

-- Re-enter the actual child entry with an ordinary interpreter, without
-- exposing its private server or changing the executable's production route.
runFrameInterpreterFailureProbe :: IO ()
runFrameInterpreterFailureProbe = do
    hSetBinaryMode stderr True
    entry <- maybe (assertFailure "the fixed frame child argv was not classified") pure
        (classifyFrameChild frameChildArguments)
    outcome <- try @IOException (runFrameChildEntry
        (frameInterpreter (\_ -> throwIO (userError frameInterpreterFailureMarker))) entry)
    case outcome of
        Left failure -> do
            ioeGetErrorString failure @?= frameInterpreterFailureMarker
            ByteString.hPut stderr frameInterpreterFailureConfirmation
            hFlush stderr
            exitFailure
        Right () -> assertFailure "the original interpreter IOException was not rethrown"

frameInterpreterFailureMarker :: String
frameInterpreterFailureMarker = "the test interpreter IOException"

frameInterpreterFailureConfirmation :: ByteString.ByteString
frameInterpreterFailureConfirmation = "the original interpreter IOException was rethrown\n"

runPrivateProtocolStdioProbe :: IO ()
runPrivateProtocolStdioProbe = do
    hSetBinaryMode stdout True
    hSetBinaryMode stderr True
    Protocol.withPrivateProtocolStdio $ \channel -> do
        ByteString.hPut stdout privateProtocolInsideMarker
        hFlush stdout
        message <- expectRight (Protocol.protocolMessage Protocol.FrameOutcomeTag 41 ["the private protocol output"])
        Protocol.channelSend channel message >>= expectRight
    ByteString.hPut stdout privateProtocolAfterMarker
    hFlush stdout

privateProtocolInsideMarker :: ByteString.ByteString
privateProtocolInsideMarker = "ordinary output inside private protocol stdio\n"

privateProtocolAfterMarker :: ByteString.ByteString
privateProtocolAfterMarker = "ordinary output after private protocol stdio\n"

-- All three streams remain bytes. Drain both outputs concurrently, and stop
-- and reap a still-running child before unwinding its reader workers.
runFrameBinary :: [String] -> ByteString.ByteString -> IO (ExitCode, ByteString.ByteString, ByteString.ByteString)
runFrameBinary arguments input = boundedHandoff "the frame binary probe" $ do
    executable <- getExecutablePath
    withCreateProcess
        (proc executable arguments)
            { std_in = CreatePipe
            , std_out = CreatePipe
            , std_err = CreatePipe
            , create_group = True
            , close_fds = True
            } $ \inbound outbound diagnostic child -> case (inbound, outbound, diagnostic) of
                (Just childInput, Just childOutput, Just childDiagnostic) -> do
                    forM_ [childInput, childOutput, childDiagnostic] $ \handle -> hSetBinaryMode handle True
                    let cleanup = closeHandoffHandle childInput `finally` do
                            status <- getProcessExitCode child
                            when (isNothing status) (terminateProcess child)
                            _ <- boundedHandoff "the frame binary cleanup" (waitForProcess child)
                            pure ()
                    withHandoffWorker (ByteString.hGetContents childOutput) $ \awaitOutput ->
                        withHandoffWorker (ByteString.hGetContents childDiagnostic) $ \awaitDiagnostic ->
                            (do
                                ByteString.hPut childInput input
                                closeHandoffHandle childInput
                                status <- waitForProcess child
                                output <- awaitOutput
                                errors <- awaitDiagnostic
                                pure (status, output, errors)) `finally` cleanup
                _ -> assertFailure "the frame probe was launched without three private pipes"

{- | A configuration that resolves no host tool at all.

A local crossing consults none of it, which is the point: the case that does
cross a frame is refused by the resolver rather than by a missing binary, and
the case that does not cross one is unaffected by either.
-}
unresolvedHostConfig :: HostConfig
unresolvedHostConfig =
    HostConfig
        { hcSubstrate = Substrate{substrateName = LinuxCpu, substrateArch = Amd64}
        , hcToolPaths = Map.empty
        }

-- ---------------------------------------------------------------------------
-- Framing

framingTests :: [TestTree]
framingTests =
    [ testCase "a framed payload round-trips" $
        unframeWire (frameWire "narrowed child config") @?= Right "narrowed child config"
    , testCase "an empty payload is a valid frame" $
        unframeWire (frameWire "") @?= Right ""
    , testCase "a short header is truncation, not an empty payload" $
        unframeWire (ByteString.take 4 (frameWire "abc"))
            @?= Left (HandoffWireTruncated 8 4)
    , testCase "a body shorter than its declared length is truncation" $ do
        let full = frameWire "abcdefghij"
        unframeWire (ByteString.take (ByteString.length full - 3) full)
            @?= Left (HandoffWireTruncated 10 7)
    , testCase "bytes after the declared length are refused, not ignored" $
        unframeWire (frameWire "abc" <> "extra")
            @?= Left (HandoffWireTrailingBytes 5)
    , testCase "a declared length beyond the receiver limit is refused before allocation" $ do
        let hostile = ByteString.pack [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff] <> "x"
        case unframeWire hostile of
            Left (HandoffWireTooLarge declared limit) -> do
                assertBool "the declared length exceeds the limit" (declared > limit)
                limit @?= maxWireBytes
            other -> assertFailure ("expected an oversize refusal, got " <> show other)
    , testCase "the grant protocol version is explicit" $
        handoffProtocolVersion @?= 1
    , testCase "provider dependency fields are canonical data-only handoff payloads" $ do
        let package = ByteStringChar8.pack "35:hostbootstrap/runtime-dependency/v18:provider4:plan5:scope8:resource5:frame6:origin1:77:journal7:receipt26:runtime://provider/reprobe3:100"
        providerDependencyPackageFields package @?= Right [package]
        providerDependencyPackageFromFields [package] @?= Right package
        request <- expectRight (providerDependencyProbeRequestFields package "nonce-1")
        providerDependencyProbeRequestFromFields package request @?= Right "nonce-1"
        response <- expectRight (providerDependencyProbeResponseFields package "nonce-1" 7)
        providerDependencyProbeResponseFromFields package "nonce-1" response @?= Right (Right 7)
        refusal <- expectRight (providerDependencyProbeRefusalFields package "nonce-1" "unavailable")
        providerDependencyProbeResponseFromFields package "nonce-1" refusal @?= Right (Left "unavailable")
        assertBool "a duplicate package field was accepted" (isLeft (providerDependencyPackageFromFields [package, package]))
        assertBool "a changed nonce accepted a response" (isLeft (providerDependencyProbeResponseFromFields package "nonce-2" response))
        provider <- expectRight (Dependency.runtimeDependencyPackageFromWire package :: Either Text.Text (Dependency.RuntimeDependencyPackage () ()))
        share <- expectRight (Dependency.mkProviderShareRuntimeDependencyPackage "plan" "scope" "share" "frame" "origin" 9 "journal" "receipt" "runtime://provider-share/reprobe" 100)
        bundle <- expectRight (Dependency.runtimeDependencyPackageBundleWire [provider, share])
        providerDependencyPackagesFields bundle @?= Right [bundle]
        providerDependencyPackagesFromFields [bundle]
            @?= Right [package, Dependency.runtimeDependencyPackageWire share]
    , testCase "the provider reprobe kernel authenticates, consumes, probes, and refuses" $ do
        let package = ByteStringChar8.pack "35:hostbootstrap/runtime-dependency/v18:provider4:plan5:scope8:resource5:frame6:origin1:77:journal7:receipt26:runtime://provider/reprobe3:100"
            kernel probe =
                withProviderDependencyReprobeKernel
                    package
                    "plan"
                    "scope"
                    "resource"
                    "frame"
                    "origin"
                    7
                    "journal"
                    "receipt"
                    "runtime://provider/reprobe"
                    99
                    probe
            outcome nonce fields = providerDependencyProbeResponseFromFields package nonce fields
        calls <- newIORef (0 :: Int)
        first <- expectRight (providerDependencyProbeRequestFields package "nonce-1")
        kernel (modifyIORef' calls (+ 1) >> pure (Right 7)) $ \answer -> do
            expected <- expectRight (providerDependencyProbeResponseFields package "nonce-1" 7)
            answer first >>= (@?= Right expected)
            replay <- answer first >>= expectRight
            outcome "nonce-1" replay @?= Right (Left "provider dependency probe nonce was replayed")
            changed <- expectRight (providerDependencyProbeRequestFields package "nonce-2")
            wrong <-
                withProviderDependencyReprobeKernel
                    package
                    "plan"
                    "scope"
                    "resource"
                    "frame"
                    "origin"
                    7
                    "journal"
                    "receipt"
                    "runtime://provider/other"
                    99
                    (modifyIORef' calls (+ 1) >> pure (Right 7))
                    (\wrong -> wrong changed)
            assertBool "a changed route reached the backend" (isLeft wrong)
        readIORef calls >>= (@?= 1)
        refused <- expectRight (providerDependencyProbeRequestFields package "nonce-3")
        kernel (pure (Left "provider is closed")) $ \answer -> do
            response <- answer refused >>= expectRight
            outcome "nonce-3" response @?= Right (Left "provider is closed")
        changedGeneration <- expectRight (providerDependencyProbeRequestFields package "nonce-4")
        kernel (pure (Right 8)) $ \answer -> do
            response <- answer changedGeneration >>= expectRight
            outcome "nonce-4" response @?= Right (Left "provider dependency generation changed")
        timed <- expectRight (providerDependencyProbeRequestFields package "nonce-5")
        kernel (threadDelay 2000000 >> pure (Right 7)) $ \answer -> do
            response <- answer timed >>= expectRight
            outcome "nonce-5" response @?= Right (Left "provider dependency probe timed out")
    , testCase "provider reprobe uses the admitted duplex, keyless relay, and Process bracket only" $
        withHandoffPackageRoot $ \packageRoot -> do
            relay <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            receiver <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver")
            process <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Process")
            let routed = normalizeWhitespace relay
                client = normalizeWhitespace receiver
                installed = normalizeWhitespace process
            mapM_
                (\term -> assertBool (term <> " is absent from the keyless provider route") (term `isInfixOf` routed))
                [ "linkProviderDependencyRaw"
                , "relayProviderDependency edge"
                , "ProviderDependencyProbeRequestTag"
                , "ProviderDependencyProbeResponseTag"
                , "providerRelayMicros = 1000000"
                ]
            mapM_
                (\term -> assertBool (term <> " is absent from the hidden child client") (term `isInfixOf` client))
                [ "receivedEdgeChannel edge"
                , "receivedEdgeRequestId edge"
                , "providerClientRequestLimit = 64"
                , "the provider dependency nonce was replayed"
                ]
            assertBool
                "Process does not own the provider service installation"
                ( "withProviderDependencyReprobeKernel" `isInfixOf` installed
                    && "withProviderDependencyReprobeEndpointKernel" `isInfixOf` installed
                    && "withForwardLifecycleChildProcess config installed" `isInfixOf` installed
                )
            mapM_
                (\term -> assertBool ("provider route names alternate authority " <> term) (not (term `isInfixOf` routed || term `isInfixOf` client || term `isInfixOf` installed)))
                [ "getEnv"
                , "lookupEnv"
                , "Network.Socket"
                ]
    ]

-- ---------------------------------------------------------------------------
-- Protocol decoder and child-state DATA

protocolDataTests :: [TestTree]
protocolDataTests =
    [ testCase "the actual decoder distinguishes nine malformed-wire categories" $ do
        message <- expectRight (Protocol.protocolMessage Protocol.OfferRequestTag 17 ["field"])
        let wire = Protocol.encodeProtocolMessage message
            body = ByteString.drop 8 wire
            header = ByteString.take 15 body
            oversized = ByteString.pack [0, 0, 0, 0, 0, 128, 0, 1]
            mutate offset replacement =
                ByteString.take offset body <> replacement
                    <> ByteString.drop (offset + ByteString.length replacement) body
            cases =
                [ ("outer header truncation", ByteString.take 3 wire,
                    Protocol.ProtocolTruncated 8 3)
                , ("outer body bound", oversized,
                    Protocol.ProtocolBodyTooLarge 8388609 8388608)
                , ("nested field bound", frameWire (header <> oversized),
                    Protocol.ProtocolFieldTooLarge 8388608)
                , ("trailing outer bytes", wire <> "xyz",
                    Protocol.ProtocolTrailingBytes 3)
                , ("bad body magic", frameWire (mutate 0 "X"),
                    Protocol.ProtocolBadMagic)
                , ("unsupported version", frameWire (mutate 4 (ByteString.pack [0, 2])),
                    Protocol.ProtocolUnsupportedVersion 2)
                , ("unknown tag", frameWire (mutate 6 (ByteString.singleton 255)),
                    Protocol.ProtocolUnknownTag 255)
                , ("zero request", frameWire (mutate 7 (ByteString.replicate 8 0)),
                    Protocol.ProtocolZeroRequestId)
                , ("missing required field", frameWire header,
                    Protocol.ProtocolWrongFieldCount Protocol.OfferRequestTag 1 0)
                ]
        Protocol.protocolMaximumBytes @?= 8388608
        ByteString.length body @?= 28
        ByteString.length header @?= 15
        ByteString.length (header <> oversized) @?= 23
        Protocol.decodeProtocolMessage wire @?= Right message
        forM_ cases $ \(label, candidate, expected) ->
            assertBool (label <> ": " <> show (Protocol.decodeProtocolMessage candidate))
                (Protocol.decodeProtocolMessage candidate == Left expected)
        -- Retain independent truncation coordinates at the other two layers.
        Protocol.decodeProtocolMessage (ByteString.init wire)
            @?= Left (Protocol.ProtocolTruncated 28 27)
        Protocol.decodeProtocolMessage (frameWire (ByteString.take 14 body))
            @?= Left (Protocol.ProtocolTruncated 15 14)
        Protocol.decodeProtocolMessage
            (frameWire (header <> lifecycleWordBytesFor 2 <> "x"))
            @?= Left (Protocol.ProtocolTruncated 2 1)
    , testCase "excess fields report remaining bytes without counting invented fields" $ do
        message <- expectRight (Protocol.protocolMessage Protocol.OfferRequestTag 17 ["field"])
        let wire = Protocol.encodeProtocolMessage message
            body = ByteString.drop 8 wire
            cases =
                [ ("three stray bytes", "xyz", 3, 31)
                , ("five complete empty frames", ByteString.concat (replicate 5 (frameWire "")), 40, 68)
                ]
        Protocol.decodeProtocolMessage wire @?= Right message
        forM_ cases $ \(label, extra, byteCount, bodyCount) -> do
            let candidate = frameWire (body <> extra)
            ByteString.length extra @?= byteCount
            ByteString.length (ByteString.drop 8 candidate) @?= bodyCount
            assertBool label
                ( Protocol.decodeProtocolMessage candidate
                    == Left (Protocol.ProtocolExcessFields Protocol.OfferRequestTag 1 byteCount)
                )
        Protocol.protocolErrorMessage
            (Protocol.ProtocolExcessFields Protocol.OfferRequestTag 1 3)
            @?= "handoff protocol: OfferRequestTag has 3 excess bytes (expected field count 1)"
        Protocol.protocolErrorMessage
            (Protocol.ProtocolExcessFields Protocol.OfferRequestTag 1 40)
            @?= "handoff protocol: OfferRequestTag has 40 excess bytes (expected field count 1)"
    , testCase "every legal child-state tag pair has its exact successor" $
        withProtocolDataStates $ \_ _ messages rows -> do
            length protocolDataTagFields @?= 24
            length rows @?= 13
            length (nub [state | (_, state, _, _) <- rows]) @?= 13
            withHandoffPackageRoot $ \packageRoot -> do
                path <- handoffModulePath packageRoot "HostBootstrap.Handoff.Protocol"
                bytes <- ByteString.readFile path
                source <- either (assertFailure . show) (pure . Text.unpack)
                    (TextEncoding.decodeUtf8' bytes)
                declaredTags <- either assertFailure pure
                    (SourceGuard.nullaryDataConstructorNames "ProtocolTag" source)
                sort (map (show . fst) protocolDataTagFields) @?= sort declaredTags
            sum [length receives | (_, _, receives, _) <- rows] @?= 19
            sum [length sends | (_, _, _, sends) <- rows] @?= 20
            forM_ rows $ \(label, state, receives, sends) -> do
                Protocol.childProtocolFinished state @?= (label == "finished")
                forM_ receives $ \(tag, successor) -> do
                    message <- requireProtocolDataMessage tag messages
                    Protocol.childProtocolReceive state message @?= Right successor
                forM_ sends $ \(tag, successor) -> do
                    message <- requireProtocolDataMessage tag messages
                    Protocol.childProtocolSend state message @?= Right successor
    , testCase "every illegal receive and send retains its actual opaque state and tag" $
        withProtocolDataStates $ \_ _ messages rows -> do
            let receivePairs =
                    [ (state, tag)
                    | (_, state, receives, _) <- rows
                    , (tag, _) <- messages
                    , tag `notElem` map fst receives
                    ]
                sendPairs =
                    [ (state, tag)
                    | (_, state, _, sends) <- rows
                    , (tag, _) <- messages
                    , tag `notElem` map fst sends
                    ]
            length receivePairs @?= 293
            length sendPairs @?= 292
            forM_ receivePairs $ \(state, tag) -> do
                message <- requireProtocolDataMessage tag messages
                Protocol.childProtocolReceive state message
                    @?= Left (Protocol.ProtocolInvalidTransition "receive" state tag)
            forM_ sendPairs $ \(state, tag) -> do
                message <- requireProtocolDataMessage tag messages
                Protocol.childProtocolSend state message
                    @?= Left (Protocol.ProtocolInvalidTransition "send" state tag)
    , testCase "all request-bound legal operations reject a different request" $
        withProtocolDataStates $ \_ _ messages rows -> do
            let receivePairs =
                    [ (state, tag)
                    | (label, state, receives, _) <- rows
                    , label /= "awaiting offer"
                    , (tag, _) <- receives
                    ]
                sendPairs =
                    [(state, tag) | (_, state, _, sends) <- rows, (tag, _) <- sends]
            length receivePairs @?= 17
            length sendPairs @?= 20
            forM_ receivePairs $ \(state, tag) -> do
                original <- requireProtocolDataMessage tag messages
                changed <- expectRight
                    (Protocol.protocolMessage tag 18 (Protocol.protocolMessageFields original))
                Protocol.childProtocolReceive state changed
                    @?= Left (Protocol.ProtocolRequestMismatch 17 18)
            forM_ sendPairs $ \(state, tag) -> do
                original <- requireProtocolDataMessage tag messages
                changed <- expectRight
                    (Protocol.protocolMessage tag 18 (Protocol.protocolMessageFields original))
                Protocol.childProtocolSend state changed
                    @?= Left (Protocol.ProtocolRequestMismatch 17 18)
    , testCase "connected rooted replies and acknowledgements retain request seven before field checks" $
        withProtocolDataStates $ \_ acknowledgement messages _ -> do
            let initial = Protocol.initialChildProtocolState
                messageFor tag request = do
                    original <- requireProtocolDataMessage tag messages
                    expectRight (Protocol.protocolMessage tag request (Protocol.protocolMessageFields original))
                receive state tag = messageFor tag 7 >>= expectRight . Protocol.childProtocolReceive state
                send state tag = messageFor tag 7 >>= expectRight . Protocol.childProtocolSend state
            mustChallenge <- receive initial Protocol.OfferTag
            awaitingGrant <- send mustChallenge Protocol.ChallengeTag
            mustAccept <- receive awaitingGrant Protocol.GrantTag
            running <- send mustAccept Protocol.AcceptedTag
            awaitingRooted <- send running Protocol.RootedLifecycleRequestTag
            resumed <- receive awaitingRooted Protocol.RootedLifecycleResponseTag
            resumed @?= running
            awaitingAcknowledgement <- send running Protocol.CompletedTag
            finished <- receive awaitingAcknowledgement Protocol.AcknowledgedTag
            Protocol.childProtocolFinished finished @?= True
            let invalid state = Left (Protocol.ProtocolInvalidTransition "receive" state Protocol.RootedLifecycleResponseTag)
                mismatch = Left (Protocol.ProtocolRequestMismatch 7 8)
                rows =
                    [ ("matching rooted reply resumes", awaitingRooted, Protocol.RootedLifecycleResponseTag, 7, ["field"], Right running)
                    , ("foreign rooted reply", awaitingRooted, Protocol.RootedLifecycleResponseTag, 8, ["field"], mismatch)
                    , ("matching rooted refusal finishes", awaitingRooted, Protocol.RefusedTag, 7, ["code", "detail"], Right finished)
                    , ("foreign rooted refusal", awaitingRooted, Protocol.RefusedTag, 8, ["code", "detail"], mismatch)
                    , ("matching acknowledgement finishes", awaitingAcknowledgement, Protocol.AcknowledgedTag, 7, [acknowledgement], Right finished)
                    , ("foreign acknowledgement", awaitingAcknowledgement, Protocol.AcknowledgedTag, 8, [acknowledgement], mismatch)
                    , ("foreign acknowledgement precedes altered bytes", awaitingAcknowledgement, Protocol.AcknowledgedTag, 8, [acknowledgement <> "changed"], mismatch)
                    , ("matching identity checks altered bytes", awaitingAcknowledgement, Protocol.AcknowledgedTag, 7, [acknowledgement <> "changed"], Left Protocol.ProtocolAcknowledgementMismatch)
                    , ("matching acknowledgement refusal finishes", awaitingAcknowledgement, Protocol.RefusedTag, 7, ["code", "detail"], Right finished)
                    , ("foreign acknowledgement refusal", awaitingAcknowledgement, Protocol.RefusedTag, 8, ["code", "detail"], mismatch)
                    , ("initial refusal has no retained request", initial, Protocol.RefusedTag, 8, ["code", "detail"], Right finished)
                    , ("unsolicited rooted response", running, Protocol.RootedLifecycleResponseTag, 7, ["field"], invalid running)
                    , ("duplicate after actual rooted reply", resumed, Protocol.RootedLifecycleResponseTag, 7, ["field"], invalid resumed)
                    , ("post-terminal rooted response", finished, Protocol.RootedLifecycleResponseTag, 7, ["field"], invalid finished)
                    , ("wrong response to rooted request", awaitingRooted, Protocol.GrantResponseTag, 7, ["field"], Left (Protocol.ProtocolInvalidTransition "receive" awaitingRooted Protocol.GrantResponseTag))
                    ]
            connected <- forM rows $ \(label, state, tag, request, fields, expected) -> do
                message <- expectRight (Protocol.protocolMessage tag request fields)
                pure (label, state, message, expected)
            withHandoffChannels $ \inbound outbound _ _ ->
                withHandoffWorker
                    (forM_ connected $ \(_, _, message, _) -> Protocol.channelSend outbound message >>= (@?= Right ())) $ \awaitWriter -> do
                        boundedHandoff "the finite connected request-identity matrix" $
                            forM_ connected $ \(label, state, message, expected) -> do
                                observed <- Protocol.channelReceive inbound >>= expectRight
                                observed @?= message
                                assertBool (label <> ": " <> show (Protocol.childProtocolReceive state observed))
                                    (Protocol.childProtocolReceive state observed == expected)
                        awaitWriter >>= (@?= ())
    , testCase "acknowledgement and lifecycle-report refusals are exact values" $
        withProtocolDataStates $ \report acknowledgement messages rows -> do
            running <- requireProtocolDataState "running" rows
            awaiting <- requireProtocolDataState "awaiting acknowledgement" rows
            finished <- requireProtocolDataState "finished" rows
            good <- requireProtocolDataMessage Protocol.AcknowledgedTag messages
            badRequest <- expectRight
                (Protocol.protocolMessage Protocol.AcknowledgedTag 18 [acknowledgement])
            badBytes <- expectRight
                (Protocol.protocolMessage Protocol.AcknowledgedTag 17 [acknowledgement <> "changed"])
            badReport <- expectRight
                (Protocol.protocolMessage Protocol.CompletedTag 17 ["not a lifecycle report"])
            verifyLifecycleAcknowledgement report acknowledgement @?= Right ()
            Protocol.childProtocolReceive awaiting good @?= Right finished
            Protocol.childProtocolReceive awaiting badRequest
                @?= Left (Protocol.ProtocolRequestMismatch 17 18)
            Protocol.childProtocolReceive awaiting badBytes
                @?= Left Protocol.ProtocolAcknowledgementMismatch
            Protocol.childProtocolSend running badReport
                @?= Left Protocol.ProtocolLifecycleReportInvalid
            show awaiting @?= "ChildAwaitingAcknowledgement 17 <exact>"
    ]

-- A concrete list of DATA tags and counts; existing closed tag-byte/field-table
-- source contracts must remain, so this list cannot silently omit a new tag.
protocolDataTagFields :: [(Protocol.ProtocolTag, Int)]
protocolDataTagFields =
    [ (Protocol.OfferRequestTag, 1)
    , (Protocol.OfferResponseTag, 1)
    , (Protocol.OfferTag, 4)
    , (Protocol.ChallengeTag, 1)
    , (Protocol.GrantRequestTag, 2)
    , (Protocol.GrantResponseTag, 1)
    , (Protocol.GrantTag, 2)
    , (Protocol.AcceptedTag, 1)
    , (Protocol.CompletedTag, 1)
    , (Protocol.ActivationSignRequestTag, 1)
    , (Protocol.ActivationSignResponseTag, 1)
    , (Protocol.RecoveryRequestTag, 2)
    , (Protocol.RecoveryResponseTag, 1)
    , (Protocol.RefusedTag, 2)
    , (Protocol.AcknowledgedTag, 1)
    , (Protocol.LifecycleAckRequestTag, 1)
    , (Protocol.LifecycleAckResponseTag, 1)
    , (Protocol.RootedLifecycleRequestTag, 1)
    , (Protocol.RootedLifecycleResponseTag, 1)
    , (Protocol.FrameTransactionTag, 1)
    , (Protocol.FrameOutcomeTag, 1)
    , (Protocol.ProviderDependencyPackageTag, 1)
    , (Protocol.ProviderDependencyProbeRequestTag, 1)
    , (Protocol.ProviderDependencyProbeResponseTag, 1)
    ]

-- States are opaque values returned by the actual transition API. No constructor
-- is imported, matched, cast, or copied. The report is made by the existing
-- genuine binding fixture and public lifecycle renderer, then acknowledged by
-- the public acknowledgement renderer.
withProtocolDataStates ::
    ( ByteString.ByteString -> ByteString.ByteString ->
      [(Protocol.ProtocolTag, Protocol.ProtocolMessage)] ->
      [(String, Protocol.ChildProtocolState,
          [(Protocol.ProtocolTag, Protocol.ChildProtocolState)],
          [(Protocol.ProtocolTag, Protocol.ChildProtocolState)])] -> IO ()
    ) -> IO ()
withProtocolDataStates use =
    withForwardLifecycleFixture 70 $ \_ origin -> do
        report <- expectRight (renderForwardCompletedLifecycleReport origin)
        acknowledgement <- expectRight (renderLifecycleAcknowledgement report)
        messages <- forM protocolDataTagFields $ \(tag, count) -> do
            let fields
                    | tag == Protocol.CompletedTag = [report]
                    | tag == Protocol.AcknowledgedTag = [acknowledgement]
                    | otherwise = replicate count "field"
            message <- expectRight (Protocol.protocolMessage tag 17 fields)
            Protocol.decodeProtocolMessage (Protocol.encodeProtocolMessage message) @?= Right message
            pure (tag, message)
        let initial = Protocol.initialChildProtocolState
            receive state tag = do
                message <- requireProtocolDataMessage tag messages
                expectRight (Protocol.childProtocolReceive state message)
            send state tag = do
                message <- requireProtocolDataMessage tag messages
                expectRight (Protocol.childProtocolSend state message)
        mustChallenge <- receive initial Protocol.OfferTag
        awaitingGrant <- send mustChallenge Protocol.ChallengeTag
        mustAccept <- receive awaitingGrant Protocol.GrantTag
        running <- send mustAccept Protocol.AcceptedTag
        let relayPairs =
                [ (Protocol.OfferRequestTag, Protocol.OfferResponseTag)
                , (Protocol.GrantRequestTag, Protocol.GrantResponseTag)
                , (Protocol.ActivationSignRequestTag, Protocol.ActivationSignResponseTag)
                , (Protocol.RecoveryRequestTag, Protocol.RecoveryResponseTag)
                , (Protocol.LifecycleAckRequestTag, Protocol.LifecycleAckResponseTag)
                , (Protocol.RootedLifecycleRequestTag, Protocol.RootedLifecycleResponseTag)
                ]
        outstanding <- forM relayPairs $ \(request, response) -> do
            state <- send running request
            receive state response >>= (@?= running)
            pure (request, response, state)
        awaitingAcknowledgement <- send running Protocol.CompletedTag
        finished <- receive awaitingAcknowledgement Protocol.AcknowledgedTag
        let rows =
                [ ("awaiting offer", initial,
                    [(Protocol.OfferTag, mustChallenge), (Protocol.RefusedTag, finished)], [])
                , ("must send challenge", mustChallenge, [],
                    [(Protocol.ChallengeTag, awaitingGrant), (Protocol.RefusedTag, finished)])
                , ("awaiting grant", awaitingGrant,
                    [(Protocol.GrantTag, mustAccept), (Protocol.RefusedTag, finished)],
                    [(Protocol.RefusedTag, finished)])
                , ("must send accepted", mustAccept, [],
                    [(Protocol.AcceptedTag, running), (Protocol.RefusedTag, finished)])
                , ("running", running, [(Protocol.RefusedTag, finished)],
                    [(request, state) | (request, _, state) <- outstanding]
                        <> [(Protocol.CompletedTag, awaitingAcknowledgement), (Protocol.RefusedTag, finished)])
                ]
                <> [ ("awaiting " <> show response, state,
                        [(response, running), (Protocol.RefusedTag, finished)],
                        [(Protocol.RefusedTag, finished)])
                   | (_, response, state) <- outstanding
                   ]
                <> [ ("awaiting acknowledgement", awaitingAcknowledgement,
                        [(Protocol.AcknowledgedTag, finished), (Protocol.RefusedTag, finished)],
                        [(Protocol.RefusedTag, finished)])
                   , ("finished", finished, [], [])
                   ]
        use report acknowledgement messages rows

requireProtocolDataMessage ::
    Protocol.ProtocolTag -> [(Protocol.ProtocolTag, Protocol.ProtocolMessage)] ->
    IO Protocol.ProtocolMessage
requireProtocolDataMessage tag messages =
    maybe (assertFailure ("missing protocol DATA message: " <> show tag)) pure
        (lookup tag messages)

requireProtocolDataState ::
    String ->
    [(String, Protocol.ChildProtocolState,
        [(Protocol.ProtocolTag, Protocol.ChildProtocolState)],
        [(Protocol.ProtocolTag, Protocol.ChildProtocolState)])] ->
    IO Protocol.ChildProtocolState
requireProtocolDataState name rows =
    maybe (assertFailure ("missing protocol DATA state: " <> name)) pure
        (lookup name [(label, state) | (label, state, _, _) <- rows])

-- ---------------------------------------------------------------------------
-- Source guard contracts

sourceGuardTests :: [TestTree]
sourceGuardTests =
    [ testCase "ordered fragments ignore line and nested block comments" $
        forM_
            [ "-- ProjectUp: refused\nx = y"
            , "{- outer {- ProjectUp -} still a comment -}\nx = y"
            ]
            (\source -> fragmentsInOrder ["ProjectUp"] source @?= Left "ProjectUp")
    , testCase "ordered fragments distinguish identifiers from complete string tokens" $ do
        fragmentsInOrder ["ProjectUp"] "x = \"ProjectUp\"" @?= Left "ProjectUp"
        fragmentsInOrder ["\"ProjectUp\""] "x = \"ProjectUp\"" @?= Right ()
        fragmentsInOrder ["ProjectUp"] "x = \"-- ProjectUp\"" @?= Left "ProjectUp"
        fragmentsInOrder ["\"-- ProjectUp\""] "x = \"-- ProjectUp\"" @?= Right ()
        fragmentsInOrder ["\"{- ProjectUp -}\""] "x = \"{- ProjectUp -}\"" @?= Right ()
    , testCase "ordered fragments retain layout-independent code and pragma tokens" $ do
        fragmentsInOrder ["run x", "finish"] "run\n x\n-- separate stages\nfinish" @?= Right ()
        fragmentsInOrder ["{-# OPAQUE run #-}", "run x"] "{-# OPAQUE run #-}\nrun x" @?= Right ()
    , testCase "ordered fragments require complete contiguous tokens" $ do
        fragmentsInOrder ["ProjectUp"] "ProjectUpward" @?= Left "ProjectUp"
        fragmentsInOrder ["run x"] "run another x" @?= Left "run x"
    , testCase "ordered fragments report the first unmatched fragment" $
        fragmentsInOrder ["finish", "run"] "run finish" @?= Left "run"
    , testCase "ordered fragments consume each matched occurrence" $
        fragmentsInOrder ["run x", "run x"] "run x" @?= Left "run x"
    , testCase "ordered fragments refuse empty and comment-only requirements" $
        forM_ ["", "-- ProjectUp", "{- ProjectUp -}"] $ \fragment ->
            fragmentsInOrder [fragment] "ProjectUp" @?= Left fragment
    , testCase "Cabal seam checks see inline and comma-separated registration fields" $
        forM_
            [ "exposed-modules: HostBootstrap.Keep, HostBootstrap.Forbidden"
            , "other-modules: HostBootstrap.Keep, HostBootstrap.Forbidden"
            , "reexported-modules: HostBootstrap.Keep, HostBootstrap.Forbidden"
            , "signatures: HostBootstrap.Keep, HostBootstrap.Forbidden"
            , "autogen-modules: HostBootstrap.Keep, HostBootstrap.Forbidden"
            , "virtual-modules: HostBootstrap.Keep, HostBootstrap.Forbidden"
            ]
            ( \field ->
                assertBool "the forbidden module is registered inline"
                    ("HostBootstrap.Forbidden" `elem` registeredCabalModules ("library helper\n  " <> field <> "\n"))
            )
    , testCase "Cabal seam checks include common and conditional registrations" $ do
        let source = unlines
                [ "common shared"
                , "  other-modules: HostBootstrap.CommonSeam"
                , "library helper"
                , "  import: shared"
                , "  if os(windows)"
                , "    other-modules: HostBootstrap.WindowsSeam"
                , "  else"
                , "    other-modules: HostBootstrap.PosixSeam"
                ]
        forM_ ["HostBootstrap.CommonSeam", "HostBootstrap.WindowsSeam", "HostBootstrap.PosixSeam"] $ \name ->
            assertBool (name <> " is a module registration") (name `elem` registeredCabalModules source)
    , testCase "Cabal seam checks ignore comments and similarly named modules" $ do
        let source = unlines
                [ "-- other-modules: HostBootstrap.Forbidden"
                , "library helper"
                , "  other-modules: HostBootstrap.ForbiddenExtra -- HostBootstrap.Forbidden"
                ]
        registeredCabalModules source @?= ["HostBootstrap.ForbiddenExtra"]
    ]

-- ---------------------------------------------------------------------------
-- Bindings

bindingTests :: [TestTree]
bindingTests =
    [ testCase "binding input round-trips and refuses malformed public request bytes" $ do
        let input = bindingInputFor childPayload
            wire = renderHandoffBindingInput input
            emptyPhase = input{requestedPhase = ""}
        fields <- framesOf wire
        length fields @?= 7
        handoffBindingInputFromWire wire @?= Right input
        -- Requests are descriptive data; semantic required-field admission is
        -- separately checked by mkHandoffBinding before signing.
        handoffBindingInputFromWire (renderHandoffBindingInput emptyPhase) @?= Right emptyPhase
        specLength <- case fields of
            spec : _ -> pure (ByteString.length spec)
            [] -> assertFailure "the canonical binding input has no specification field"
        let refusals =
                [ ("short header", ByteString.take 7 wire, HandoffWireTruncated 8 7)
                , ("short field body", ByteString.take (8 + specLength - 1) wire, HandoffWireTruncated specLength (specLength - 1))
                , ("oversized field", ByteString.replicate 8 0xff <> "x", HandoffWireTooLarge maxBound maxWireBytes)
                , ("missing phase", renderFrameFields (take 6 fields), HandoffWireTruncated 8 0)
                , ("unknown payload kind", wireWithFrames [(1, "unknown-kind")] fields, HandoffBindingMismatch "unknown handoff payload kind unknown-kind")
                , ("invalid UTF-8", wireWithFrames [(0, ByteString.singleton 0xff)] fields, HandoffBindingMismatch "a binding field is not valid UTF-8")
                , ("trailing bytes", wire <> "xyz", HandoffWireTrailingBytes 3)
                ]
        forM_ refusals $ \(label, malformed, expected) -> do
            assertBool (label <> " changes the request") (malformed /= wire)
            handoffBindingInputFromWire malformed @?= Left expected
    , testCase "canonical bindings refuse malformed fields before delivery" $
        withNamedHandoff 7 ProjectUp $ \project broker -> do
            token <- freshHandoffToken
            binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
            let wire = renderHandoffBinding binding
                scope = productionHandoffScope project
            fields <- framesOf wire
            length fields @?= 13
            withHandoffBindingFromWire scope wire renderHandoffBinding @?= Right wire
            let refusals =
                    [ ("unknown payload kind", wireWithFrames [(2, "unknown-kind")] fields, HandoffBindingMismatch "unknown handoff payload kind unknown-kind")
                    , ("seven-byte generation", wireWithFrames [(6, ByteString.replicate 7 0)] fields, HandoffBindingMismatch "the binding's broker generation is not a 64-bit field")
                    , ("empty required phase", wireWithFrames [(11, "")] fields, HandoffBindingMismatch "phase must not be empty")
                    , ("invalid UTF-8", wireWithFrames [(1, ByteString.singleton 0xff)] fields, HandoffBindingMismatch "a binding field is not valid UTF-8")
                    , ("trailing bytes", wire <> "xyz", HandoffWireTrailingBytes 3)
                    , ("another installed project", wireWithFrames [(0, TextEncoding.encodeUtf8 (installedProjectName project <> "-other"))] fields, HandoffBindingMismatch "the received binding names a different installed project than the fixed handoff scope")
                    , ("another scope", wireWithFrames [(3, "Harness other-run")] fields, HandoffBindingMismatch "the received binding names a different scope than the fixed handoff scope")
                    ]
            forM_ refusals $ \(label, malformed, expected) -> do
                assertBool (label <> " changes the canonical binding") (malformed /= wire)
                withHandoffBindingFromWire scope malformed (const ()) @?= Left expected
    , testCase "challenges require exactly 32 bytes" $ do
        fresh <- freshChallenge
        let bytes = challengeBytes fresh
        ByteString.length bytes @?= 32
        fmap challengeBytes (handoffChallengeFromBytes bytes) @?= Right bytes
        forM_ [31, 33] $ \width ->
            fmap challengeBytes (handoffChallengeFromBytes (ByteString.replicate width 0))
                @?= Left (HandoffBindingMismatch ("a challenge is 32 bytes, received " <> Text.pack (show width)))
    , testCase "field boundaries are unambiguous across the frame edge" $
        withHandoff 7 ProjectUp $ \broker -> do
            token <- freshHandoffToken
            left <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload){requestedParentFrame = "a-b", requestedChildFrame = "c"} token)
            right <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload){requestedParentFrame = "a", requestedChildFrame = "b-c"} token)
            assertBool
                "distinct edges render distinctly"
                (renderHandoffBinding left /= renderHandoffBinding right)
    , testCase "every caller-bound field and the token change canonical rendering" $
        withHandoff 7 ProjectUp $ \broker -> do
            token <- freshHandoffToken
            otherToken <- freshHandoffToken
            let input = bindingInputFor childPayload
                variants =
                    [ input{requestedSpecDigest = "spec-2"}
                    , input{requestedPayloadKind = RecoveryAdapterWire}
                    , input{requestedPlanRevision = "rev-2"}
                    , input{requestedParentFrame = "elsewhere"}
                    , input{requestedChildFrame = "elsewhere"}
                    , input{requestedChildConfigDigest = "deadbeef"}
                    , input{requestedPhase = "teardown"}
                    ]
            base <- expectRight (mkHandoffBinding broker input token)
            changed <- traverse (\variant -> expectRight (mkHandoffBinding broker variant token)) variants
            changedToken <- expectRight (mkHandoffBinding broker input otherToken)
            let rendered = map renderHandoffBinding (base : changed <> [changedToken])
            length (dedupe rendered) @?= length rendered
    , testCase "project, scope, generation, and verb derive from typed root evidence" $
        do
            expectedProject <- Fixture.fixtureExecutableName
            withHandoff 7 ProjectUp $ \broker -> do
                token <- freshHandoffToken
                binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
                handoffInstalledProject binding @?= expectedProject
                handoffScope binding @?= "Production"
                handoffBrokerGeneration binding @?= 1
                handoffVerb binding @?= "up"
    , testCase "the canonical and verified binding retain the root protected-store identity" $
        withSystemTempDirectory "hostbootstrap-handoff-store-binding" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 31))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            let expectedStore = protectedStoreIdentityText (protectedStoreIdentity store)
            withRootFor signing store ProjectUp $ \broker -> do
                let input = bindingInputFor childPayload
                (relay, token) <- expectRightIO =<< registerHandoffEdge broker input
                let binding = relayBinding relay
                decodedRelay <-
                    expectRight
                        ( brokerRelayFromRouteWire
                            (rootBrokerRoute broker)
                            (Just input)
                            (renderHandoffBinding binding)
                        )
                let decoded = relayBinding decodedRelay
                decoded @?= binding
                handoffStoreIdentity decoded @?= expectedStore
                offer <- expectRight (mkHandoffOffer relay childPayload token)
                challenge <- freshChallenge
                grant <- expectRightIO =<< grantHandoff broker offer challenge
                verified <-
                    expectRight
                        ( verifyHandoff
                            (rootBrokerVerificationKey broker)
                            (handoffOfferWire offer)
                            decoded
                            challenge
                            grant
                        )
                handoffStoreIdentity (verifiedHandoffBinding verified) @?= expectedStore
    , testCase "a real Harness root derives its exact generative run scope" $
        withHarnessHandoff 7 $ \_ broker authority -> do
            token <- freshHandoffToken
            binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
            handoffScope binding @?= "Harness " <> harnessRunName authority
            assertBool "Harness scope is never Production" (handoffScope binding /= "Production")
    , testCase "scope-fixed parsing refuses signed Harness bytes at a Production boundary" $
        withHarnessHandoff 8 $ \project broker _ -> do
            token <- freshHandoffToken
            binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
            expectBindingRefusal "different scope than the fixed handoff scope"
                ( withHandoffBindingFromWire
                    (productionHandoffScope project)
                    (renderHandoffBinding binding)
                    (const ())
                )
    , testCase "an empty required field is rejected before signing" $
        withHandoff 7 ProjectUp $ \broker -> do
            token <- freshHandoffToken
            let input = bindingInputFor childPayload
                requiredFields =
                    [ ("spec digest", \value -> value{requestedSpecDigest = ""})
                    , ("plan revision", \value -> value{requestedPlanRevision = ""})
                    , ("parent frame", \value -> value{requestedParentFrame = ""})
                    , ("child frame", \value -> value{requestedChildFrame = ""})
                    , ("child config digest", \value -> value{requestedChildConfigDigest = ""})
                    , ("phase", \value -> value{requestedPhase = ""})
                    ]
            _ <- expectRight (mkHandoffBinding broker input token)
            forM_ requiredFields $ \(field, clear) ->
                mkHandoffBinding broker (clear input) token
                    @?= Left (HandoffBindingMismatch (field <> " must not be empty"))
    , testCase "rooted payload bindings preserve the immediate edge and keep recovery a signed digest claim without admission" $ do
        withHandoff 73 ProjectUp $ \broker -> do
            verified <- verifiedHandoffFor broker childPayload
            let binding = verifiedHandoffBinding verified
                edge = renderHandoffBinding binding
                digest = childConfigDigest childPayload
                key = rootBrokerVerificationKey broker
            legacyFields <- framesOf edge
            legacyFields
                @?= [ TextEncoding.encodeUtf8 (handoffInstalledProject binding)
                    , "spec-digest-1"
                    , "narrowed-project-config"
                    , "Production"
                    , TextEncoding.encodeUtf8 (handoffStoreIdentity binding)
                    , "rev-1"
                    , lifecycleWordBytesFor 1
                    , "vm-orchestrator-1"
                    , "vm-project-container-2"
                    , TextEncoding.encodeUtf8 digest
                    , "up"
                    , "execute"
                    , TextEncoding.encodeUtf8 (handoffTokenCommitment binding)
                    ]
            rooted <-
                rootedOracleWire
                    73
                    canonicalRootedPayloadSigningDomain
                    key
                    edge
                    digest
                    digest
            withVerifiedRootedPayloadBinding
                verified
                rooted
                (\bindingProof -> (renderRootedPayloadBinding bindingProof, rootedPayloadDigest bindingProof, rootedChildConfigDigest bindingProof))
                @?= Right (rooted, digest, digest)
            renderHandoffBinding (verifiedHandoffBinding verified) @?= edge

            foreignEdge <-
                rootedOracleWire 73 canonicalRootedPayloadSigningDomain key "foreign-edge" digest digest
            expectBindingRefusal "the rooted edge is not the verified one-use edge"
                (withVerifiedRootedPayloadBinding verified foreignEdge (const ()))
            let otherDigest = childConfigDigest "other exact bytes"
            splitConfig <-
                rootedOracleWire 73 canonicalRootedPayloadSigningDomain key edge digest otherDigest
            expectBindingRefusal "a config payload has different payload and child-config digests"
                (withVerifiedRootedPayloadBinding verified splitConfig (const ()))
            foreignPayload <-
                rootedOracleWire 73 canonicalRootedPayloadSigningDomain key edge otherDigest otherDigest
            expectBindingRefusal "the rooted payload digest differs from the immediate edge"
                (withVerifiedRootedPayloadBinding verified foreignPayload (const ()))
            expectBindingRefusal "rooted payload binding is truncated inside a field"
                (withVerifiedRootedPayloadBinding verified (ByteString.init rooted) (const ()))
            expectBindingRefusal "rooted payload binding has trailing bytes"
                (withVerifiedRootedPayloadBinding verified (rooted <> "trailing") (const ()))
            let shortSignature = rootedPayloadUnsigned edge digest digest <> frameWire (ByteString.replicate 63 0)
            expectBindingRefusal "rooted payload binding has a signature whose width is not 64 bytes"
                (withVerifiedRootedPayloadBinding verified shortSignature (const ()))
            expectBindingRefusal "is larger than the bounded authentication field"
                ( withVerifiedRootedPayloadBinding
                    verified
                    (ByteString.replicate (fromIntegral maxWireBytes + 1) 0)
                    (const ())
                )
            let oversizedEdgeHeader =
                    renderFrameFields
                        [ "hostbootstrap/rooted-payload-binding"
                        , lifecycleWordBytesFor 1
                        ]
                        <> ByteString.pack [0, 0, 0, 0, 0, 128, 0, 1]
            expectBindingRefusal "contains an oversized field"
                (withVerifiedRootedPayloadBinding verified oversizedEdgeHeader (const ()))

            emptyVerified <- verifiedHandoffFor broker ByteString.empty
            let emptyBinding = verifiedHandoffBinding emptyVerified
                emptyDigest = childConfigDigest ByteString.empty
            emptyRooted <-
                rootedOracleWire
                    73
                    canonicalRootedPayloadSigningDomain
                    key
                    (renderHandoffBinding emptyBinding)
                    emptyDigest
                    emptyDigest
            expectBindingRefusal "the complete payload is empty"
                (withVerifiedRootedPayloadBinding emptyVerified emptyRooted (const ()))

        withHandoff 74 ProjectDestroy $ \broker -> do
            let package = "canonical-child-config-and-adapter-package"
                childConfig = "canonical-child-config"
                packageDigest = childConfigDigest package
                configDigest = childConfigDigest childConfig
                input =
                    HandoffBindingInput
                        { requestedSpecDigest = "spec-digest-1"
                        , requestedPayloadKind = RecoveryAdapterWire
                        , requestedPlanRevision = "rev-1"
                        , requestedParentFrame = "vm-orchestrator-1"
                        , requestedChildFrame = "vm-project-container-2"
                        , requestedChildConfigDigest = packageDigest
                        , requestedPhase = "teardown"
                        }
            verified <- verifiedHandoffForInput broker input package
            let edge = renderHandoffBinding (verifiedHandoffBinding verified)
                key = rootBrokerVerificationKey broker
            rooted <-
                rootedOracleWire
                    74
                    canonicalRootedPayloadSigningDomain
                    key
                    edge
                    packageDigest
                    configDigest
            withVerifiedRootedPayloadBinding
                verified
                rooted
                (\bindingProof -> (rootedPayloadDigest bindingProof, rootedChildConfigDigest bindingProof))
                @?= Right (packageDigest, configDigest)
            conflated <-
                rootedOracleWire
                    74
                    canonicalRootedPayloadSigningDomain
                    key
                    edge
                    packageDigest
                    packageDigest
            expectBindingRefusal "a recovery payload has conflated payload and child-config digests"
                (withVerifiedRootedPayloadBinding verified conflated (const ()))
    , testCase "the genuine rooted config signer refuses each reachable kind and byte mismatch" $
        withHandoff 104 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            signed <- signRootedPayloadBindingKernel HandoffInternal.recoverySigningKernel broker offer childPayload >>= expectRight
            verified <- verifyOfferedHandoff broker binding offer
            withVerifiedRootedPayloadBinding verified (renderRootedPayloadBinding signed)
                (\rooted -> (rootedPayloadDigest rooted, rootedChildConfigDigest rooted, renderRootedPayloadBinding rooted))
                @?= Right (childConfigDigest childPayload, childConfigDigest childPayload, renderRootedPayloadBinding signed)
            (_, recoveryOffer) <- newOfferWith broker
                (bindingInputFor childPayload){requestedPayloadKind = RecoveryAdapterWire} childPayload
            (_, emptyOffer) <- newOffer broker ByteString.empty
            let refusals =
                    [ ("recovery signing requires canonical RecoveryChildPackage admission", recoveryOffer, childPayload)
                    , ("the complete payload is empty", emptyOffer, childPayload)
                    , ("the child config is empty", offer, ByteString.empty)
                    , ("a config payload and its child config are not the same exact bytes", offer, "another nonempty config")
                    ]
            forM_ refusals $ \(detail, candidate, childConfig) -> do
                outcome <- signRootedPayloadBindingKernel HandoffInternal.recoverySigningKernel broker candidate childConfig
                (() <$ outcome) @?= Left (HandoffBindingMismatch detail)
            -- A mismatched immediate digest cannot inhabit an actual offer:
            -- mkHandoffOffer's exact refusal and existing constructor/nominal
            -- compiler subjects own that invariant, rather than a forged row.
    , testCase "the rooted signer checks another verb's genuine broker under the same epoch" $
        withSystemTempDirectory "hostbootstrap-rooted-signer-checked-verbs" $ \directory -> do
            store <- openProtectedStore (directory </> "authority") >>= expectRight
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 105))
            -- Use the real private validators, as in the grant backstop case;
            -- public lifecycle mode is not claimed to admit both verbs.
            prepared <- Fixture.withFixtureInstalledProject $ \project ->
                withProtectedEntry store $ \session -> do
                    principal <- expectRight =<< verifyOsPrincipal session
                    Right <$> AuthorityFixture.withFreshBrokerEpochKernel session project (\epoch ->
                        AuthorityFixture.withVerifiedRootInvocationKernel AuthorityFixture.ProductionRootScope
                            session project principal epoch ProjectUp $ \upRoot ->
                                AuthorityFixture.withVerifiedRootInvocationKernel AuthorityFixture.ProductionRootScope
                                    session project principal epoch ProjectDown $ \downRoot ->
                                        pure (Right (do
                                            opened <- withRootBroker (productionHandoffScope project) store signing upRoot $ \upBroker -> do
                                                (binding, offer) <- newOffer upBroker childPayload
                                                signed <- signRootedPayloadBindingKernel HandoffInternal.recoverySigningKernel upBroker offer childPayload >>= expectRight
                                                verified <- verifyOfferedHandoff upBroker binding offer
                                                withVerifiedRootedPayloadBinding verified (renderRootedPayloadBinding signed)
                                                    (\rooted -> (rootedPayloadDigest rooted, rootedChildConfigDigest rooted))
                                                    @?= Right (childConfigDigest childPayload, childConfigDigest childPayload)
                                                before <- protectedHandoffImage store
                                                other <- withRootBroker (productionHandoffScope project) store signing downRoot $ \downBroker -> do
                                                    refused <- signRootedPayloadBindingKernel HandoffInternal.recoverySigningKernel downBroker offer childPayload
                                                    (() <$ refused) @?= Left (HandoffBindingMismatch
                                                        "the binding names a different verb than the root invocation authorized")
                                                    protectedHandoffImage store >>= (@?= before)
                                                other @?= Right ()
                                            opened @?= Right ()
                                        )))
            checked <- expectRight prepared
            action <- expectRight checked
            action
    , testCase "rooted payload verification uses the installed key and fixed domain" $ do
        forced <-
            try @SomeException
                (evaluate (signRootedPayloadBindingKernel (error "forced hidden rooted signing capability")))
        case forced of
            Left failure ->
                assertBool
                    "the hidden capability is forced before a broker-taking rooted signer is returned"
                    ("forced hidden rooted signing capability" `contains` show failure)
            Right _ -> assertFailure "the partial rooted signer did not force its hidden capability"
        withHandoff 75 ProjectUp $ \broker -> do
            verified <- verifiedHandoffFor broker childPayload
            let binding = verifiedHandoffBinding verified
                edge = renderHandoffBinding binding
                digest = childConfigDigest childPayload
                key = rootBrokerVerificationKey broker
                verify raw = withVerifiedRootedPayloadBinding verified raw (const ())
            canonical <-
                rootedOracleWire
                    75
                    canonicalRootedPayloadSigningDomain
                    key
                    edge
                    digest
                    digest
            verify canonical @?= Right ()

            wrongDomain <-
                rootedOracleWire
                    75
                    "hostbootstrap/rooted-payload-binding/not-v1"
                    key
                    edge
                    digest
                    digest
            verify wrongDomain @?= Left HandoffRootedSignatureInvalid
            wrongSigner <-
                rootedOracleWire
                    76
                    canonicalRootedPayloadSigningDomain
                    key
                    edge
                    digest
                    digest
            verify wrongSigner @?= Left HandoffRootedSignatureInvalid
            otherSigning <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 76))
            wrongKeyDigest <-
                rootedOracleWire
                    75
                    canonicalRootedPayloadSigningDomain
                    (projectSigningVerificationKey otherSigning)
                    edge
                    digest
                    digest
            verify wrongKeyDigest @?= Left HandoffRootedSignatureInvalid
            let lastByte = ByteString.last canonical
                changedSignature =
                    ByteString.init canonical
                        <> ByteString.singleton (lastByte + 1)
            verify changedSignature @?= Left HandoffRootedSignatureInvalid
            canonicalFields <- framesOf canonical
            expectBindingRefusal "rooted payload binding has the wrong domain"
                (verify (wireWithFrames [(0, "hostbootstrap/rooted-payload-binding/not-v1")] canonicalFields))
            expectBindingRefusal "rooted payload binding has the wrong version"
                (verify (wireWithFrames [(1, lifecycleWordBytesFor 2)] canonicalFields))
    , testCase "recovery child packages reveal fields only after both authenticated digests agree" $ do
        forced <-
            try @SomeException
                ( evaluate
                    ( signRecoveryChildPackageBindingKernel
                        (error "forced hidden recovery-package signing capability")
                    )
                )
        case forced of
            Left failure ->
                assertBool
                    "the hidden capability is forced before a recovery-package signer is returned"
                    ("forced hidden recovery-package signing capability" `contains` show failure)
            Right _ -> assertFailure "the partial recovery-package signer did not force its hidden capability"
        withHandoff 77 ProjectDestroy $ \broker -> do
            let childConfig = "canonical-recovery-child-config"
                adapter = "canonical-recovery-adapter"
                packageBytes = frameWire childConfig <> frameWire adapter
                packageDigest = childConfigDigest packageBytes
                configDigest = childConfigDigest childConfig
                inputFor payload =
                    HandoffBindingInput
                        { requestedSpecDigest = "spec-digest-1"
                        , requestedPayloadKind = RecoveryAdapterWire
                        , requestedPlanRevision = "rev-1"
                        , requestedParentFrame = "vm-orchestrator-1"
                        , requestedChildFrame = "vm-project-container-2"
                        , requestedChildConfigDigest = childConfigDigest payload
                        , requestedPhase = "teardown"
                        }
                verifyPackage payload claimedConfigDigest = do
                    (binding, offer) <- newOfferWith broker (inputFor payload) payload
                    verified <- verifyOfferedHandoff broker binding offer
                    rootedWire <-
                        rootedOracleWire
                            77
                            canonicalRootedPayloadSigningDomain
                            (rootBrokerVerificationKey broker)
                            (renderHandoffBinding binding)
                            (childConfigDigest payload)
                            claimedConfigDigest
                    rooted <-
                        expectRight
                            (withVerifiedRootedPayloadBinding verified rootedWire id)
                    pure (verified, rooted)
                expectPackageRefusal (detail, payload, extractedConfig) = do
                    assertBool "the malformed recovery payload and its extracted config have distinct digest claims"
                        (childConfigDigest payload /= childConfigDigest extractedConfig)
                    (verified, rooted) <-
                        verifyPackage payload (childConfigDigest extractedConfig)
                    expectBindingRefusal detail
                        (withVerifiedRecoveryChildPackage verified rooted (\_ _ _ -> ()))

            assertBool "the valid recovery package and extracted config have distinct digest claims"
                (packageDigest /= configDigest)
            (verified, rooted) <- verifyPackage packageBytes configDigest
            withVerifiedRecoveryChildPackage
                verified
                rooted
                ( \package exactConfig exactAdapter ->
                    (renderRecoveryChildPackage package, exactConfig, exactAdapter)
                )
                @?= Right (packageBytes, childConfig, adapter)

            wrongConfigRootedWire <-
                rootedOracleWire
                    77
                    canonicalRootedPayloadSigningDomain
                    (rootBrokerVerificationKey broker)
                    (renderHandoffBinding (verifiedHandoffBinding verified))
                    packageDigest
                    (childConfigDigest "wrong child config")
            wrongConfigRooted <-
                expectRight
                    (withVerifiedRootedPayloadBinding verified wrongConfigRootedWire id)
            expectBindingRefusal "the rooted child-config digest does not name the package field"
                (withVerifiedRecoveryChildPackage verified wrongConfigRooted (\_ _ _ -> ()))

            traverse_
                expectPackageRefusal
                [ ("recovery child package is truncated before a frame header", frameWire childConfig, childConfig)
                , ("recovery child package has an empty child config", frameWire "" <> frameWire adapter, "")
                , ("recovery child package has an empty recovery adapter", frameWire childConfig <> frameWire "", childConfig)
                , ("recovery child package has trailing bytes", packageBytes <> frameWire "third", childConfig)
                , ("recovery child package is truncated inside a field", ByteString.init packageBytes, childConfig)
                , ("recovery child package contains an oversized field", frameWire childConfig <> ByteString.replicate 8 0xff <> "x", childConfig)
                ]

            configVerified <- verifiedHandoffFor broker childPayload
            let configBinding = verifiedHandoffBinding configVerified
                configDigest' = childConfigDigest childPayload
            configRootedWire <-
                rootedOracleWire
                    77
                    canonicalRootedPayloadSigningDomain
                    (rootBrokerVerificationKey broker)
                    (renderHandoffBinding configBinding)
                    configDigest'
                    configDigest'
            configRooted <-
                expectRight
                    (withVerifiedRootedPayloadBinding configVerified configRootedWire id)
            expectBindingRefusal "the authenticated payload is not a recovery child package"
                (withVerifiedRecoveryChildPackage configVerified configRooted (\_ _ _ -> ()))
    , testCase "the genuine recovery package signer joins canonical fields and refuses reachable cross-pairs" $
        withHandoff 106 ProjectDown $ \broker -> do
            let childConfig = "the exact recovery signer child config"
                adapter = "the exact recovery signer adapter"
                packageBytes = frameWire childConfig <> frameWire adapter
                input = (bindingInputFor packageBytes){requestedPayloadKind = RecoveryAdapterWire, requestedPhase = "teardown"}
            assertBool "the valid recovery package carries a distinct complete-payload digest"
                (childConfigDigest packageBytes /= childConfigDigest childConfig)
            (admittedBinding, admittedOffer) <- newOfferWith broker input packageBytes
            admitted <- verifyOfferedHandoff broker admittedBinding admittedOffer
            admittedWire <- rootedOracleWire 106 canonicalRootedPayloadSigningDomain
                (rootBrokerVerificationKey broker) (renderHandoffBinding admittedBinding)
                (childConfigDigest packageBytes) (childConfigDigest childConfig)
            admittedRooted <- expectRight (withVerifiedRootedPayloadBinding admitted admittedWire id)
            -- The package comes from the existing authenticated public join,
            -- with every returned IO action forced while the real broker lives.
            usePackage <- expectRight (withVerifiedRecoveryChildPackage admitted admittedRooted $ \package exactConfig exactAdapter -> do
                (renderRecoveryChildPackage package, exactConfig, exactAdapter) @?= (packageBytes, childConfig, adapter)
                (binding, offer) <- newOfferWith broker input packageBytes
                signed <- signRecoveryChildPackageBindingKernel HandoffInternal.recoverySigningKernel broker offer package >>= expectRight
                verified <- verifyOfferedHandoff broker binding offer
                rooted <- expectRight (withVerifiedRootedPayloadBinding verified (renderRootedPayloadBinding signed) id)
                withVerifiedRecoveryChildPackage verified rooted
                    (\joined configBytes adapterBytes -> (renderRecoveryChildPackage joined, configBytes, adapterBytes))
                    @?= Right (packageBytes, childConfig, adapter)
                (_, configOffer) <- newOfferWith broker input{requestedPayloadKind = NarrowedProjectConfig} packageBytes
                let differentPackage = frameWire childConfig <> frameWire "another canonical adapter"
                    otherInput = input{requestedChildConfigDigest = childConfigDigest differentPackage}
                assertBool "the second recovery offer carries a genuinely different canonical package" (differentPackage /= packageBytes)
                (_, otherOffer) <- newOfferWith broker otherInput differentPackage
                forM_
                    [ ("a recovery child package requires a recovery-adapter-wire edge", configOffer)
                    , ("the recovery offer does not carry the exact canonical package", otherOffer)
                    ] $ \(detail, candidate) -> do
                        refused <- signRecoveryChildPackageBindingKernel HandoffInternal.recoverySigningKernel broker candidate package
                        (() <$ refused) @?= Left (HandoffBindingMismatch detail)
                )
            usePackage
            -- The immediate digest follows from mkHandoffOffer plus exact
            -- package equality. Constructor/nominal proofs remain its boundary;
            -- no malformed opaque package or offer is manufactured here.
    , testCase "the recovery package signer checks a genuine other verb under the same epoch" $
        withSystemTempDirectory "hostbootstrap-recovery-signer-checked-verbs" $ \directory -> do
            store <- openProtectedStore (directory </> "authority") >>= expectRight
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 107))
            prepared <- Fixture.withFixtureInstalledProject $ \project ->
                withProtectedEntry store $ \session -> do
                    principal <- expectRight =<< verifyOsPrincipal session
                    Right <$> AuthorityFixture.withFreshBrokerEpochKernel session project (\epoch ->
                        AuthorityFixture.withVerifiedRootInvocationKernel AuthorityFixture.ProductionRootScope
                            session project principal epoch ProjectDown $ \downRoot ->
                                AuthorityFixture.withVerifiedRootInvocationKernel AuthorityFixture.ProductionRootScope
                                    session project principal epoch ProjectDestroy $ \destroyRoot ->
                                        pure (Right (do
                                            opened <- withRootBroker (productionHandoffScope project) store signing downRoot $ \downBroker -> do
                                                let childConfig = "same-epoch recovery config"
                                                    packageBytes = frameWire childConfig <> frameWire "same-epoch recovery adapter"
                                                    input = (bindingInputFor packageBytes){requestedPayloadKind = RecoveryAdapterWire, requestedPhase = "teardown"}
                                                (binding, offer) <- newOfferWith downBroker input packageBytes
                                                verified <- verifyOfferedHandoff downBroker binding offer
                                                wire <- rootedOracleWire 107 canonicalRootedPayloadSigningDomain
                                                    (rootBrokerVerificationKey downBroker) (renderHandoffBinding binding)
                                                    (childConfigDigest packageBytes) (childConfigDigest childConfig)
                                                rooted <- expectRight (withVerifiedRootedPayloadBinding verified wire id)
                                                usePackage <- expectRight (withVerifiedRecoveryChildPackage verified rooted $ \package _ _ -> do
                                                    matching <- signRecoveryChildPackageBindingKernel HandoffInternal.recoverySigningKernel downBroker offer package >>= expectRight
                                                    matchingRooted <- expectRight (withVerifiedRootedPayloadBinding verified (renderRootedPayloadBinding matching) id)
                                                    withVerifiedRecoveryChildPackage verified matchingRooted
                                                        (\joined configBytes _ -> (renderRecoveryChildPackage joined, configBytes)) @?= Right (packageBytes, childConfig)
                                                    before <- protectedHandoffImage store
                                                    other <- withRootBroker (productionHandoffScope project) store signing destroyRoot $ \destroyBroker -> do
                                                        refused <- signRecoveryChildPackageBindingKernel HandoffInternal.recoverySigningKernel destroyBroker offer package
                                                        (() <$ refused) @?= Left (HandoffBindingMismatch
                                                            "the binding names a different verb than the root invocation authorized")
                                                        protectedHandoffImage store >>= (@?= before)
                                                    other @?= Right ()
                                                    )
                                                usePackage
                                            opened @?= Right ()
                                        )))
            -- Release protected entry before the returned action re-enters it.
            checked <- expectRight prepared
            action <- expectRight checked
            action
    , testCase "authenticated root scopes verify exact Production and generative Harness branches" $ do
        forced <-
            try @SomeException
                ( evaluate
                    ( signAuthenticatedRootScopeKernel
                        (error "forced hidden authenticated-root-scope signing capability")
                    )
                )
        case forced of
            Left failure ->
                assertBool
                    "the hidden capability is forced before a root-scope signer is returned"
                    ("forced hidden authenticated-root-scope signing capability" `contains` show failure)
            Right _ -> assertFailure "the partial authenticated-root-scope signer did not force its hidden capability"

        withNamedHandoff 78 ProjectUp $ \project broker -> do
            let key = rootBrokerVerificationKey broker
                projectName = installedProjectName project
            wire <-
                authenticatedRootScopeOracleWire
                    78
                    canonicalAuthenticatedRootScopeSigningDomain
                    key
                    projectName
                    "production"
                    ""
            fields <- framesOf wire
            map ByteString.length fields
                @?= [ ByteString.length canonicalAuthenticatedRootScopeDomain
                    , 8
                    , Text.length projectName
                    , ByteString.length ("production" :: ByteString.ByteString)
                    , 0
                    , 64
                    , 64
                    ]
            fields
                @?= [ canonicalAuthenticatedRootScopeDomain
                    , lifecycleWordBytesFor 1
                    , TextEncoding.encodeUtf8 projectName
                    , "production"
                    , ""
                    , TextEncoding.encodeUtf8 (verificationKeyDigest key)
                    , last fields
                    ]
            withAuthenticatedRootScopeFromWire
                project
                key
                wire
                ( \authenticated scope ->
                    ( "production" :: String
                    , renderAuthenticatedRootScope authenticated
                    , handoffScopeProject scope
                    , handoffScopeTag scope
                    )
                )
                ( \authenticated scope ->
                    ( "harness" :: String
                    , renderAuthenticatedRootScope authenticated
                    , handoffScopeProject scope
                    , handoffScopeTag scope
                    )
                )
                @?= Right ("production", wire, projectName, productionScopeTag)

        withHarnessHandoff 79 $ \project broker authority -> do
            let key = rootBrokerVerificationKey broker
                projectName = installedProjectName project
                run = harnessRunName authority
            wire <-
                authenticatedRootScopeOracleWire
                    79
                    canonicalAuthenticatedRootScopeSigningDomain
                    key
                    projectName
                    "harness"
                    (TextEncoding.encodeUtf8 run)
            withAuthenticatedRootScopeFromWire
                project
                key
                wire
                ( \authenticated scope ->
                    ( "production" :: String
                    , renderAuthenticatedRootScope authenticated
                    , handoffScopeProject scope
                    , handoffScopeTag scope
                    )
                )
                ( \authenticated scope ->
                    ( "harness" :: String
                    , renderAuthenticatedRootScope authenticated
                    , handoffScopeProject scope
                    , handoffScopeTag scope
                    )
                )
                @?= Right ("harness", wire, projectName, harnessScopeTagFor run)
    , testCase "authenticated root scopes refuse every structural and cryptographic substitution" $
        withNamedHandoff 80 ProjectUp $ \project broker -> do
            let key = rootBrokerVerificationKey broker
                projectName = installedProjectName project
                verifyWith installedKey raw =
                    withAuthenticatedRootScopeFromWire
                        project
                        installedKey
                        raw
                        (\_ _ -> "production" :: String)
                        (\_ _ -> "harness" :: String)
                signedMutation replacements =
                    authenticatedRootScopeOracleWireFromUnsigned
                        80
                        canonicalAuthenticatedRootScopeSigningDomain
                        key
                        ( wireWithFrames
                            replacements
                            [ canonicalAuthenticatedRootScopeDomain
                            , lifecycleWordBytesFor 1
                            , TextEncoding.encodeUtf8 projectName
                            , "production"
                            , ""
                            , TextEncoding.encodeUtf8 (verificationKeyDigest key)
                            ]
                        )
                assertRefused (label, expected, outcome) =
                    assertBool (label <> ": expected " <> show expected <> ", got " <> show outcome)
                        (outcome == Left expected)
            canonical <-
                authenticatedRootScopeOracleWire
                    80
                    canonicalAuthenticatedRootScopeSigningDomain
                    key
                    projectName
                    "production"
                    ""
            verifyWith key canonical @?= Right "production"
            canonicalFields <- framesOf canonical

            wrongCodec <- signedMutation [(0, "hostbootstrap/authenticated-root-scope/not-v1")]
            wrongVersion <- signedMutation [(1, lifecycleWordBytesFor 2)]
            wrongProject <-
                signedMutation
                    [(2, TextEncoding.encodeUtf8 (projectName <> "-other"))]
            wrongKind <- signedMutation [(3, "Production")]
            productionRun <- signedMutation [(4, "other-run")]
            emptyHarnessRun <- signedMutation [(3, "harness")]
            noncanonicalHarnessRun <- signedMutation [(3, "harness"), (4, "bad/run")]
            oversizedHarnessRun <-
                signedMutation [(3, "harness"), (4, ByteString.replicate 49 97)]
            malformedRun <-
                signedMutation [(3, "harness"), (4, ByteString.pack [0xff])]
            otherSigning <-
                expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 81))
            wrongKeyDigest <-
                signedMutation
                    [
                        ( 5
                        , TextEncoding.encodeUtf8
                            (verificationKeyDigest (projectSigningVerificationKey otherSigning))
                        )
                    ]
            wrongSigningDomain <-
                authenticatedRootScopeOracleWire
                    80
                    "hostbootstrap/authenticated-root-scope/not-v1"
                    key
                    projectName
                    "production"
                    ""
            crossKeySignature <-
                authenticatedRootScopeOracleWire
                    81
                    canonicalAuthenticatedRootScopeSigningDomain
                    key
                    projectName
                    "production"
                    ""
            harnessWire <-
                authenticatedRootScopeOracleWire
                    80
                    canonicalAuthenticatedRootScopeSigningDomain
                    key
                    projectName
                    "harness"
                    "run-a"
            verifyWith key harnessWire @?= Right "harness"
            harnessFields <- framesOf harnessWire
            let changedSignature =
                    ByteString.init canonical
                        <> ByteString.singleton (ByteString.last canonical + 1)
                substitutedHarness =
                    wireWithFrames [(3, "harness"), (4, "other-run")] canonicalFields
                substitutedRun = wireWithFrames [(4, "run-b")] harnessFields
                shortSignature =
                    wireWithFrames [(6, ByteString.replicate 63 0)] canonicalFields
                oversizedDeclaredField =
                    ByteString.pack [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
                        <> "x"
                malformedWires =
                    [ ("empty wire", ByteString.empty, HandoffWireTruncated 8 0)
                    , ("missing seventh frame", renderFrameFields (take 6 canonicalFields), HandoffWireTruncated 8 0)
                    , ("truncated body", ByteString.init canonical, HandoffWireTruncated 64 63)
                    , ("trailing eighth frame", canonical <> frameWire "trailing", HandoffBindingMismatch "a lifecycle wire has trailing bytes")
                    , ("short signature", shortSignature, HandoffBindingMismatch "the authenticated root scope signature has the wrong width")
                    , ("oversized declared field", oversizedDeclaredField, HandoffWireTooLarge maxBound maxWireBytes)
                    ,
                        ( "oversized total wire"
                        , ByteString.replicate (fromIntegral maxWireBytes + 1) 0
                        , HandoffBindingMismatch "authenticated root scope exceeds the wire bound"
                        )
                    ]
            traverse_
                assertRefused
                [ ("wrong codec domain", HandoffBindingMismatch "the authenticated root scope codec domain differs", verifyWith key wrongCodec)
                , ("wrong version", HandoffBindingMismatch "the authenticated root scope version differs", verifyWith key wrongVersion)
                , ("wrong installed project", HandoffBindingMismatch "the authenticated root scope names another installed project", verifyWith key wrongProject)
                , ("unclosed kind", HandoffBindingMismatch "the authenticated root scope kind is not closed", verifyWith key wrongKind)
                , ("Production with a run", HandoffBindingMismatch "a Production authenticated root scope carries a Harness run", verifyWith key productionRun)
                , ("Harness with an empty run", HandoffBindingMismatch "a Harness authenticated root scope has an empty run", verifyWith key emptyHarnessRun)
                , ("Harness with a noncanonical run", HandoffBindingMismatch "a Harness authenticated root scope run is not canonical", verifyWith key noncanonicalHarnessRun)
                , ("Harness with an oversized run", HandoffBindingMismatch "a Harness authenticated root scope run exceeds 48 characters", verifyWith key oversizedHarnessRun)
                , ("Harness with malformed UTF-8", HandoffBindingMismatch "the authenticated root scope run is not UTF-8", verifyWith key malformedRun)
                , ("wrong installed key digest", HandoffBindingMismatch "the authenticated root scope names another installed verification key", verifyWith key wrongKeyDigest)
                , ("wrong signing domain", HandoffAuthenticatedRootScopeSignatureInvalid, verifyWith key wrongSigningDomain)
                , ("cross-key signature", HandoffAuthenticatedRootScopeSignatureInvalid, verifyWith key crossKeySignature)
                , ("changed signature", HandoffAuthenticatedRootScopeSignatureInvalid, verifyWith key changedSignature)
                , ("unsigned kind/run substitution", HandoffAuthenticatedRootScopeSignatureInvalid, verifyWith key substitutedHarness)
                , ("unsigned Harness run substitution", HandoffAuthenticatedRootScopeSignatureInvalid, verifyWith key substitutedRun)
                ,
                    ( "foreign installed verification key"
                    , HandoffBindingMismatch "the authenticated root scope names another installed verification key"
                    , verifyWith (projectSigningVerificationKey otherSigning) canonical
                    )
                ]
            forM_ malformedWires $ \(label, wire, expected) ->
                assertRefused (label, expected, verifyWith key wire)
    ]

dedupe :: (Eq a) => [a] -> [a]
dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- ---------------------------------------------------------------------------
-- The protocol

protocolTests :: [TestTree]
protocolTests =
    [ testCase "post-CAS reread policy preserves exact bytes and typed error provenance" $ do
        let planned = "planned:fixture binding"
            granted = "granted:fixture transcript"
            writeFailure = ProtectedIOFailure "write" "original write failure"
            readFailure = ProtectedIOFailure "reread" "actual reread failure"
            cases =
                [ ("exact granted", Right (Just granted), HandoffInternal.RegisteredEdgeGranted)
                , ("exact planned", Right (Just planned), HandoffInternal.RegisteredEdgeStoreFailure writeFailure)
                , ("absent", Right Nothing, HandoffInternal.RegisteredEdgeStoreFailure writeFailure)
                , ("foreign", Right (Just "foreign retained bytes"), HandoffInternal.RegisteredEdgeConsumed)
                , ("read failure", Left readFailure, HandoffInternal.RegisteredEdgeStoreFailure readFailure)
                ]
        assertBool "the two error DATA values differ" (writeFailure /= readFailure)
        length cases @?= 5
        forM_ cases $ \(label, reread, expected) -> do
            let actual = HandoffInternal.classifyRegisteredEdgeReread planned granted writeFailure reread
            assertBool (label <> ": " <> show actual) (actual == expected)
    , testCase "post-CAS classification has one private pure DATA owner and actual consumer" $
        withHandoffPackageRoot $ \packageRoot -> do
            description <- SourceGuard.readPackageDescription
            sources <- SourceGuard.readLibrarySources packageRoot description
            let actualSource name = case [source | (owner, _, source) <- sources, owner == name] of
                    [source] -> pure source
                    other -> assertFailure ("expected one actual policy source for " <> name <> ", found " <> show (length other))
                policy = "classifyRegisteredEdgeReread"
                mentioned = sort [name | (name, _, source) <- sources, SourceGuard.countHaskellIdentifier policy source > 0]
            internal <- actualSource "HostBootstrap.Handoff.Internal"
            facade <- actualSource "HostBootstrap.Handoff"
            mentioned @?= ["HostBootstrap.Handoff", "HostBootstrap.Handoff.Internal"]
            declarations <- forM sources $ \(name, _, source) ->
                if SourceGuard.countHaskellIdentifier policy source == 0
                    then pure []
                    else case SourceGuard.haskellDefinitionClauseTokens policy source of
                        Right clauses -> do
                            length clauses @?= 1
                            pure [name]
                        Left missing | missing == "value definition missing: " <> policy -> pure []
                        Left failure -> assertFailure failure
            concat declarations @?= ["HostBootstrap.Handoff.Internal"]
            signature <- requiredSourceSection "the private descriptive reread policy"
                "classifyRegisteredEdgeReread ::" "classifyRegisteredEdgeReread planned" internal
            SourceGuard.haskellTokens signature @?= SourceGuard.haskellTokens
                "classifyRegisteredEdgeReread :: ByteString -> ByteString -> failure -> Either failure (Maybe ByteString) -> RegisteredEdgeRereadResult failure"
            body <- either assertFailure pure (SourceGuard.haskellDefinitionClauseTokens policy internal)
            forM_ ["IO", "ProtectedStore", "ProtectedSession", "RootBroker", "HandoffGrant", "unsafePerformIO", "compareAndSwapProtectedRecord"] $
                \forbidden -> assertBool ("policy includes " <> forbidden) (forbidden `notElem` concat body)
            consumer <- either assertFailure pure (SourceGuard.haskellDefinitionClauseTokens "consumeRegisteredEdge" facade)
            length (filter (== policy) (concat consumer)) @?= 1
            assertFragmentsInOrder "actual failed CAS rereads before the private result is interpreted"
                [ "Left writeFailure -> do"
                , "raced <- readProtectedRecord session key"
                , "case classifyRegisteredEdgeReread"
                , "(plannedEdgeRecord binding)"
                , "granted"
                , "writeFailure"
                , "(fmap (fmap protectedRecordBytes) raced) of"
                , "RegisteredEdgeGranted -> Right ()"
                , "RegisteredEdgeConsumed -> Left HandoffTokenConsumed"
                , "RegisteredEdgeStoreFailure failure -> Left (HandoffStoreFailure failure)"
                ] facade
            public <- either assertFailure pure (SourceGuard.effectiveMainExposedModules description)
            assertBool "the private policy owner is publicly exposed" ("HostBootstrap.Handoff.Internal" `notElem` public)
            forM_ public $ \name -> do
                source <- actualSource name
                case SourceGuard.moduleExportTokens name source of
                    Nothing -> pure ()
                    Just exports -> do
                        forM_ [policy, "RegisteredEdgeRereadResult", "RegisteredEdgeGranted", "RegisteredEdgeConsumed", "RegisteredEdgeStoreFailure"] $
                            \forbidden -> assertBool (name <> " exports " <> forbidden) (forbidden `notElem` exports)
                        assertBool (name <> " reexports the private policy owner")
                            ("moduleHostBootstrap.Handoff.Internal" `notElem` normalizedModuleExports exports)
    , testCase "a rejected admitted edge creates no registration or grantable token" $
        withSystemTempDirectory "hostbootstrap-rejected-edge" $ \directory -> do
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 35))
            withRootFor signing store ProjectUp $ \broker -> do
                let input = bindingInputFor childPayload
                    reason = "the actual fixture plan refuses this edge" :: Text.Text
                token <- freshHandoffToken
                binding <- expectRight (mkHandoffBinding broker input token)
                relay <- expectRight (brokerRelay broker binding)
                prospective <- expectRight (mkHandoffOffer relay childPayload token)
                challenge <- freshChallenge
                before <- protectedHandoffImage store
                calls <- newIORef (0 :: Int)
                rejected <- registerAdmittedHandoffEdge broker
                    (modifyIORef' calls (+ 1) >> pure (Left reason)) input
                fmap (fmap (const ())) rejected @?= Right (Left reason)
                readIORef calls >>= (@?= 1)
                protectedHandoffImage store >>= (@?= before)
                grantHandoff broker prospective challenge >>= (@?= Left HandoffEdgeUnregistered)
                protectedHandoffImage store >>= (@?= before)
                acceptedCalls <- newIORef (0 :: Int)
                accepted <- expectRightIO =<< registerAdmittedHandoffEdge broker
                    (modifyIORef' acceptedCalls (+ 1) >> pure (Right () :: Either Text.Text ())) input
                (acceptedRelay, acceptedToken) <- expectRight accepted
                acceptedOffer <- expectRight (mkHandoffOffer acceptedRelay childPayload acceptedToken)
                _ <- expectRightIO =<< grantHandoff broker acceptedOffer challenge
                readIORef acceptedCalls >>= (@?= 1)
    , testCase "independently checked verbs under one epoch retain the real grant backstop" $
        withSystemTempDirectory "hostbootstrap-handoff-checked-verbs" $ \directory -> do
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 36))
            -- This is the existing private root-validator fixture, not a claim
            -- that ordinary lifecycle mode admission accepts two verbs.
            prepared <- Fixture.withFixtureInstalledProject $ \project ->
                withProtectedEntry store $ \session -> do
                    principal <- expectRight =<< verifyOsPrincipal session
                    Right <$> AuthorityFixture.withFreshBrokerEpochKernel session project (\epoch ->
                        AuthorityFixture.withVerifiedRootInvocationKernel AuthorityFixture.ProductionRootScope
                            session project principal epoch ProjectUp $ \upRoot ->
                                AuthorityFixture.withVerifiedRootInvocationKernel AuthorityFixture.ProductionRootScope
                                    session project principal epoch ProjectDown $ \downRoot ->
                                        pure (Right (do
                                            opened <- withRootBroker (productionHandoffScope project) store signing upRoot $ \upBroker -> do
                                                (positiveBinding, positiveOffer) <- newOffer upBroker childPayload
                                                challenge <- freshChallenge
                                                positiveGrant <- expectRightIO =<< grantHandoff upBroker positiveOffer challenge
                                                (() <$ verifyHandoff (rootBrokerVerificationKey upBroker)
                                                    (handoffOfferWire positiveOffer) positiveBinding challenge positiveGrant) @?= Right ()
                                                (_, offer) <- newOffer upBroker childPayload
                                                before <- protectedHandoffImage store
                                                other <- withRootBroker (productionHandoffScope project) store signing downRoot $ \downBroker -> do
                                                    refused <- grantHandoff downBroker offer challenge
                                                    refused @?= Left (HandoffBindingMismatch
                                                        "the binding names a different verb than the root invocation authorized")
                                                    protectedHandoffImage store >>= (@?= before)
                                                other @?= Right ()
                                            opened @?= Right ()
                                        )))
            -- Both actual protected and authority results return before any
            -- broker/grant operation re-enters the store.
            checked <- expectRight prepared
            action <- expectRight checked
            action
    , testCase "a root broker refuses a protected store outside its root authority" $
        withSystemTempDirectory "hostbootstrap-handoff-wrong-store" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 32))
            rootStore <- openProtectedStore (directory </> "root-authority") >>= expectRightIO
            otherStore <- openProtectedStore (directory </> "other-authority") >>= expectRightIO
            outcome <-
                Fixture.withFixtureInstalledProject $ \project ->
                    withProductionRoot rootStore project ProjectUp $ \root -> do
                        brokered <-
                            withRootBroker
                                (productionHandoffScope project)
                                otherStore
                                signing
                                (productionRootAuthority root)
                                (const (pure ()))
                        pure (Right brokered)
            brokered <- either (assertFailure . show) pure outcome
            case brokered of
                Left (HandoffBindingMismatch detail) ->
                    assertBool
                        "the refusal names the protected-store origin"
                        ("protected store" `Text.isInfixOf` detail)
                other -> assertFailure ("expected a cross-store broker refusal, got " <> show other)
    , testCase "durable registration and grant operations refuse after the broker bracket closes" $ do
        (registerAfterClose, grantAfterClose) <-
            withNamedHandoff 33 ProjectDestroy $ \_ broker ->
                do
                    (relay, token) <-
                        expectRight =<< registerHandoffEdge broker (bindingInputFor childPayload)
                    offer <- expectRight (mkHandoffOffer relay childPayload token)
                    challenge <- freshChallenge
                    pure
                        ( fmap
                            (fmap (const ()))
                            (registerHandoffEdge broker (bindingInputFor childPayload))
                        , fmap
                            (fmap (const ()))
                            (grantHandoff broker offer challenge)
                        )
        registerAfterClose >>= (@?= Left HandoffBrokerExpired)
        grantAfterClose >>= (@?= Left HandoffBrokerExpired)
    , testCase "ordinary edge registration remains fresh for identical input" $
        withHandoff 34 ProjectUp $ \broker -> do
            let input = bindingInputFor childPayload
            (firstRelay, firstToken) <- expectRightIO =<< registerHandoffEdge broker input
            (secondRelay, secondToken) <- expectRightIO =<< registerHandoffEdge broker input
            assertBool
                "ordinary registration allocates a fresh token"
                (handoffTokenBytes firstToken /= handoffTokenBytes secondToken)
            assertBool
                "the fresh token changes the complete canonical binding"
                ( renderHandoffBinding (relayBinding firstRelay)
                    /= renderHandoffBinding (relayBinding secondRelay)
                )
            firstOffer <- expectRight (mkHandoffOffer firstRelay childPayload firstToken)
            secondOffer <- expectRight (mkHandoffOffer secondRelay childPayload secondToken)
            firstChallenge <- freshChallenge
            secondChallenge <- freshChallenge
            _ <- expectRightIO =<< grantHandoff broker firstOffer firstChallenge
            _ <- expectRightIO =<< grantHandoff broker secondOffer secondChallenge
            pure ()
    , testCase "a root grant verifies and yields only authenticated config evidence" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            handoff <-
                expectRight
                    ( verifyHandoff
                        (rootBrokerVerificationKey broker)
                        (handoffOfferWire offer)
                        binding
                        challenge
                        grant
                    )
            verifiedHandoffPayload handoff @?= childPayload
            config <- expectRight (verifiedConfigPayload handoff)
            authenticatedConfigBytes config @?= childPayload
            authenticatedConfigDigest config @?= childConfigDigest childPayload
    , testCase "authenticated config bytes mint a fresh scope-correct local config identity" $
        withHandoff 13 ProjectUp $ \broker ->
            withProductionProjectCodec @Fixture.ProjectConfig $ \codec -> do
                let cfg =
                        Fixture.defaultProjectConfig
                            "hostbootstrap-demo"
                            "/workspace/demo"
                            Context.HostOrchestrator
                    payload = canonicalConfigBytes codec cfg
                authenticated <- authenticatedPayload broker payload
                admitted <-
                    withAuthenticatedConfigWire codec authenticated $ \wire validated -> do
                        verifiedConfigDigest wire @?= childConfigDigest payload
                        validatedConfigValue validated @?= cfg
                admitted @?= Right ()
    , testCase "authenticated config admission refuses invalid UTF-8, codec failure, and non-canonical source" $
        withHandoff 14 ProjectUp $ \broker ->
            withProductionProjectCodec @Fixture.ProjectConfig $ \codec -> do
                let cfg =
                        Fixture.defaultProjectConfig
                            "hostbootstrap-demo"
                            "/workspace/demo"
                            Context.HostOrchestrator
                    canonical = canonicalConfigBytes codec cfg
                    admit payload = do
                        authenticated <- authenticatedPayload broker payload
                        withAuthenticatedConfigWire codec authenticated (\_ _ -> pure ())
                admit (ByteString.pack [0xff]) >>= (@?= Left ConfigWireInvalidUtf8)
                admit "this is not a project config" >>= (@?= Left ConfigWireCodecRejected)
                admit (canonical <> " ") >>= (@?= Left ConfigWireNonCanonical)
    , testCase "authenticated config admission rejects an environment import before its callback" $
        rejectAuthenticatedConfigImport 74 (const "env:HOSTBOOTSTRAP_PROBE")
    , testCase "authenticated config admission rejects an unused-let import before normalization" $
        rejectAuthenticatedConfigImport 75 (\canonical -> "let unused = env:HOSTBOOTSTRAP_PROBE in " <> canonical)
    , testCase "authenticated sibling install is atomic, idempotent, and conflict-preserving" $
        -- Other specs write this sibling too; test/Spec.hs holds NumThreads 1.
        withProductionSibling $ \project authenticated path payload -> do
            forM_ ([1 .. 50] :: [Int]) $ \roundNumber -> do
                removeIfPresent path
                removeIfPresent (path <> ".hostbootstrap-handoff.lock")
                start <- newEmptyMVar
                leftReady <- newEmptyMVar
                rightReady <- newEmptyMVar
                leftResult <- newEmptyMVar
                rightResult <- newEmptyMVar
                let worker ready = do
                        putMVar ready ()
                        readMVar start
                        installAuthenticatedProductionSiblingConfig project authenticated
                bracket (forkFinally (worker leftReady) (putMVar leftResult)) killThread $ \leftThread ->
                    bracket (forkFinally (worker rightReady) (putMVar rightResult)) killThread $ \rightThread -> do
                        completed <- timeout 10000000 $ do
                            takeMVar leftReady
                            takeMVar rightReady
                            awaitSiblingStartBarrier [leftThread, rightThread]
                            putMVar start ()
                            left <- expectRight =<< takeMVar leftResult
                            right <- expectRight =<< takeMVar rightResult
                            pure [left, right]
                        observed <- maybe (assertFailure "sibling installers did not complete their shared barrier") pure completed
                        assertBool
                            ("round " <> show roundNumber <> ": one creator and one replay, observed " <> show observed)
                            ( observed
                                `elem` [ [Right SiblingConfigInstalled, Right SiblingConfigAlreadyPresent]
                                       , [Right SiblingConfigAlreadyPresent, Right SiblingConfigInstalled]
                                       ]
                            )
                ByteString.readFile path >>= (@?= payload)
                assertNoSiblingTemporaries path
            ByteString.writeFile path "foreign replacement"
            installAuthenticatedProductionSiblingConfig project authenticated
                >>= (@?= Left (SiblingConfigConflict path))
            ByteString.readFile path >>= (@?= "foreign replacement")
            assertNoSiblingTemporaries path
    , testCase "authenticated sibling install refuses a regular directory without touching it" $
        withProductionSibling $ \project authenticated path _ -> do
            createDirectory path
            ByteString.writeFile (path </> "sentinel") "directory bytes"
            installAuthenticatedProductionSiblingConfig project authenticated
                >>= (@?= Left (SiblingConfigUnsafeDestination path))
            listDirectory path >>= (@?= ["sentinel"])
            ByteString.readFile (path </> "sentinel") >>= (@?= "directory bytes")
    , testCase "authenticated Harness sibling config installs and replays" $
        withHarnessHandoff 16 $ \project broker _ -> do
            let payload = "fixture harness config bytes"
            authenticated <- authenticatedPayload broker payload
            path <- siblingProjectConfigPath (installedProjectName project)
            withCleanSiblingDestination path $ do
                installAuthenticatedHarnessSiblingConfig project authenticated
                    >>= (@?= Right SiblingConfigInstalled)
                assertNoSiblingTemporaries path
                ByteString.readFile path >>= (@?= payload)
                installAuthenticatedHarnessSiblingConfig project authenticated
                    >>= (@?= Right SiblingConfigAlreadyPresent)
                ByteString.readFile path >>= (@?= payload)
    , testCase "the native no-replace link preserves a taken destination" $ do
        CompileFailSpec.assertNativeLinkNoReplacePreservesDestination
        executable <- getExecutablePath
        assertNoSiblingTemporaries executable
    , testCase "sibling cleanup preserves completed publication and asynchronous cancellation" $
        withHandoffPackageRoot $ \packageRoot -> do
            path <- handoffModulePath packageRoot "HostBootstrap.Config.Schema"
            source <- readFile path
            actual <- either assertFailure pure (SourceGuard.haskellDefinitionClauseTokens "createSiblingConfig" source)
            clause <- case actual of
                [tokens] -> pure (unwords tokens)
                _ -> assertFailure "createSiblingConfig must retain one complete clause"
            assertFragmentsInOrder "post-publication classification always cleans up"
                [ "mask $ \\restore -> do"
                , "let removeTemporary ="
                , "catchIOError"
                , "linked <- trySynchronous (restore (linkNoReplace temporary path))"
                , "case linked of"
                , "Right () -> do"
                , "installed <- trySynchronous (inspectSiblingConfig path payload)"
                , "Left _ -> Right SiblingConfigInstalled"
                , "Right SiblingDifferent -> Left (SiblingConfigConflict path)"
                , "classifyPublication `finally` removeTemporary"
                ] clause
            assertFragmentsInOrder "synchronous handlers preserve cancellation"
                [ "trySynchronous = tryJust"
                , "fromException err :: Maybe SomeAsyncException"
                , "Just _ -> Nothing"
                , "Nothing -> Just err"
                ] source
    , testCase "an edge the root never opened is refused, so relaying is weaker than signing" $
        withHandoff 9 ProjectUp $ \broker -> do
            -- Everything an intermediate frame could construct on its own: a
            -- fresh token, a well-formed binding for a child frame the root
            -- never planned, and the offer that carries them.
            token <- freshHandoffToken
            invented <-
                expectRight
                    ( mkHandoffBinding
                        broker
                        (bindingInputFor childPayload){requestedChildFrame = "invented-frame"}
                        token
                    )
            relay <- expectRight (brokerRelay broker invented)
            offer <- expectRight (mkHandoffOffer relay childPayload token)
            challenge <- freshChallenge
            granted <- grantHandoff broker offer challenge
            granted @?= Left HandoffEdgeUnregistered
            -- And the same root still authorizes an edge it did open, so the
            -- refusal is about the edge rather than about the broker.
            (_, planned) <- newOffer broker childPayload
            plannedGrant <- grantHandoff broker planned challenge
            assertBool "an opened edge still authenticates" (isRight plannedGrant)
    , testCase "the root makes an identical grant retry idempotent and refuses token reuse" $
        withSystemTempDirectory "hostbootstrap-handoff-grant-retry" $ \directory -> do
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 7))
            withRootFor signing store ProjectUp $ \broker -> do
                before <- protectedHandoffImage store
                (binding, offer) <- newOffer broker childPayload
                plannedImage <- protectedHandoffImage store
                let added = [row | row@(key, _, _) <- plannedImage, key `notElem` [oldKey | (oldKey, _, _) <- before]]
                (key, version, bytes) <- requireSingleHandoffRow added
                version @?= 1
                bytes @?= "planned:" <> renderHandoffBinding binding
                challenge <- freshChallenge
                first <- expectRightIO =<< grantHandoff broker offer challenge
                settled <- protectedHandoffImage store
                (_, actualVersion, retained) <- requireSingleHandoffRow [row | row@(name, _, _) <- settled, name == key]
                actualVersion @?= 2
                assertBool "the actual selected row is a granted transcript" ("granted:" `ByteString.isPrefixOf` retained)
                filter (\(name, _, _) -> name /= key) settled @?= filter (\(name, _, _) -> name /= key) plannedImage
                retry <- expectRightIO =<< grantHandoff broker offer challenge
                grantSignature retry @?= grantSignature first
                protectedHandoffImage store >>= (@?= settled)
                otherChallenge <- freshChallenge
                assertBool "the conflicting challenge differs" (challengeBytes otherChallenge /= challengeBytes challenge)
                grantHandoff broker offer otherChallenge >>= (@?= Left HandoffTokenConsumed)
                protectedHandoffImage store >>= (@?= settled)
    , testCase "concurrent identical grant requests converge on one signature" $
        withSystemTempDirectory "hostbootstrap-handoff-concurrent-grant" $ \directory -> do
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 7))
            withRootFor signing store ProjectUp $ \broker -> do
                before <- protectedHandoffImage store
                (binding, offer) <- newOffer broker childPayload
                plannedImage <- protectedHandoffImage store
                let added = [row | row@(key, _, _) <- plannedImage, key `notElem` [oldKey | (oldKey, _, _) <- before]]
                (key, version, bytes) <- requireSingleHandoffRow added
                version @?= 1
                bytes @?= "planned:" <> renderHandoffBinding binding
                challenge <- freshChallenge
                (firstResult, secondResult) <- mask $ \restore -> do
                    ready <- newEmptyMVar
                    start <- newEmptyMVar
                    firstDone <- newEmptyMVar
                    secondDone <- newEmptyMVar
                    let worker = putMVar ready () >> readMVar start >> restore (grantHandoff broker offer challenge)
                        spawn result = forkFinally worker (putMVar result)
                    bracket (spawn firstDone) killThread $ \_ ->
                        bracket (spawn secondDone) killThread $ \_ -> restore $ do
                            completed <- timeout 5000000 $ do
                                takeMVar ready
                                takeMVar ready
                                putMVar start ()
                                (,) <$> takeMVar firstDone <*> takeMVar secondDone
                            maybe (assertFailure "concurrent grants did not finish within five seconds") pure completed
                first <- either (assertFailure . show) expectRightIO firstResult
                second <- either (assertFailure . show) expectRightIO secondResult
                grantSignature second @?= grantSignature first
                settled <- protectedHandoffImage store
                (_, actualVersion, retained) <- requireSingleHandoffRow [row | row@(name, _, _) <- settled, name == key]
                actualVersion @?= 2
                assertBool "one actual granted row replaced the planned row" ("granted:" `ByteString.isPrefixOf` retained)
                filter (\(name, _, _) -> name /= key) settled @?= filter (\(name, _, _) -> name /= key) plannedImage
                retry <- expectRightIO =<< grantHandoff broker offer challenge
                grantSignature retry @?= grantSignature first
                protectedHandoffImage store >>= (@?= settled)
                otherChallenge <- freshChallenge
                assertBool "the conflicting challenge differs" (challengeBytes otherChallenge /= challengeBytes challenge)
                grantHandoff broker offer otherChallenge >>= (@?= Left HandoffTokenConsumed)
                protectedHandoffImage store >>= (@?= settled)
    , testCase "a grant for another challenge does not authenticate this one" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            recorded <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer recorded
            fresh <- freshChallenge
            assertBool "the receiver issued a different challenge" (challengeBytes fresh /= challengeBytes recorded)
            expectSignatureRefusal
                ( verifyHandoff
                    (rootBrokerVerificationKey broker)
                    (handoffOfferWire offer)
                    binding
                    fresh
                    grant
                )
    , testCase "a payload swapped after signing fails its bound digest" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            let original = handoffOfferWire offer
                swapped = frameWire "message = \"attacker\"" <> dropFirstFrame original
            case verifyHandoff (rootBrokerVerificationKey broker) swapped binding challenge grant of
                Left (HandoffPayloadDigestMismatch expected actual) ->
                    assertBool "the digests differ" (expected /= actual)
                other -> assertFailure ("expected a digest refusal, got " <> show other)
    , testCase "a substituted well-formed token refuses its bound commitment" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            (_, otherOffer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            let key = rootBrokerVerificationKey broker
                original = handoffOfferWire offer
                (payload, tokenBytes, bindingBytes) = handoffOfferFrames offer
                (otherPayload, otherTokenBytes, _) = handoffOfferFrames otherOffer
                substituted = frameWire payload <> frameWire otherTokenBytes <> frameWire bindingBytes
            otherPayload @?= payload
            ByteString.length tokenBytes @?= 32
            ByteString.length otherTokenBytes @?= 32
            assertBool "the actual other offer carries another token" (otherTokenBytes /= tokenBytes)
            assertBool "the substitution changes the received wire" (substituted /= original)
            (() <$ verifyHandoff key original binding challenge grant) @?= Right ()
            (() <$ verifyHandoff key substituted binding challenge grant)
                @?= Left (HandoffBindingMismatch "the received token does not match the bound token commitment")
    , testCase "the transmitted canonical binding cannot be substituted" $
        withHandoff 7 ProjectUp $ \broker -> do
            (relay, token) <- expectRightIO =<< registerHandoffEdge broker (bindingInputFor childPayload)
            let binding = relayBinding relay
            otherBinding <-
                expectRight
                    ( mkHandoffBinding
                        broker
                        (bindingInputFor childPayload){requestedChildFrame = "sibling-2"}
                        token
                    )
            otherRelay <- expectRight (brokerRelay broker otherBinding)
            offer <- expectRight (mkHandoffOffer relay childPayload token)
            substituted <- expectRight (mkHandoffOffer otherRelay childPayload token)
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            case verifyHandoff (rootBrokerVerificationKey broker) (handoffOfferWire substituted) binding challenge grant of
                Left (HandoffBindingMismatch _) -> pure ()
                other -> assertFailure ("expected a canonical-binding refusal, got " <> show other)
    , testCase "another installed project key cannot authenticate this root's grant" $
        withHandoff 7 ProjectUp $ \broker -> do
            otherSigning <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 8))
            let otherKey = projectSigningVerificationKey otherSigning
            (binding, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            expectSignatureRefusal
                ( verifyHandoff
                    otherKey
                    (handoffOfferWire offer)
                    binding
                    challenge
                    grant
                )
            assertBool
                "the two independently provisioned keys differ"
                ( verificationKeyDigest (rootBrokerVerificationKey broker)
                    /= verificationKeyDigest otherKey
                )
    , testCase "the verified handoff retains the exact authenticated child frame" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            handoff <- expectRight (verifyHandoff (rootBrokerVerificationKey broker) (handoffOfferWire offer) binding challenge grant)
            handoffChildFrame (verifiedHandoffBinding handoff) @?= "vm-project-container-2"
    , testCase "an up handoff cannot be refined as a teardown config edge" $
        withHandoff 7 ProjectUp $ \broker ->
            withProductionProjectCodec @Fixture.ProjectConfig $ \codec -> do
                let cfg =
                        Fixture.defaultProjectConfig
                            "hostbootstrap-demo"
                            "/workspace/demo"
                            Context.HostOrchestrator
                    payload = canonicalConfigBytes codec cfg
                    input = (bindingInputFor payload){requestedSpecDigest = projectCodecSpecDigest codec}
                    observe choice edge wire config = do
                        callbacks <- newIORef (0 :: Int)
                        outcome <- case withVerifiedConfigHandoff choice edge wire config
                            (\_ -> modifyIORef' callbacks (+ 1)) of
                                Left failure -> pure (Left failure)
                                Right action -> action >> pure (Right ())
                        count <- readIORef callbacks
                        pure (outcome, count)
                handoff <- verifiedHandoffForInput broker input payload
                authenticated <- expectRight (verifiedConfigPayload handoff)
                admitted <-
                    withAuthenticatedConfigWire codec authenticated $ \wire validated -> do
                        verifiedConfigDigest wire @?= validatedConfigDigest validated
                        validatedConfigSpecDigest validated @?= projectCodecSpecDigest codec
                        observe ProjectUp handoff wire validated >>= (@?= (Right (), 1))
                        observe ProjectDestroy handoff wire validated
                            >>= (@?= (Left (HandoffBindingMismatch "the handoff does not authorize the requested project verb"), 0))
                admitted @?= Right ()
    , testCase "config handoff refinement isolates kind, paired-wire, specification, and phase refusals" $
        withHandoff 71 ProjectUp $ \broker ->
            withProductionProjectCodec @Fixture.ProjectConfig $ \codec -> do
                let cfgA = Fixture.defaultProjectConfig
                        "hostbootstrap-demo" "/workspace/demo" Context.HostOrchestrator
                    cfgB = Fixture.defaultProjectConfig
                        "hostbootstrap-demo" "/workspace/other-demo" Context.HostOrchestrator
                    payloadA = canonicalConfigBytes codec cfgA
                    payloadB = canonicalConfigBytes codec cfgB
                    specDigest = projectCodecSpecDigest codec
                    input = (bindingInputFor payloadA){requestedSpecDigest = specDigest}
                    observe edge wire config = do
                        callbacks <- newIORef (0 :: Int)
                        outcome <- case withVerifiedConfigHandoff ProjectUp edge wire config
                            (\_ -> modifyIORef' callbacks (+ 1)) of
                                Left failure -> pure (Left failure)
                                Right action -> action >> pure (Right ())
                        count <- readIORef callbacks
                        pure (outcome, count)
                assertBool "the genuine configurations have different canonical bytes" (payloadA /= payloadB)
                assertBool "the genuine configurations have different canonical digests"
                    (childConfigDigest payloadA /= childConfigDigest payloadB)
                matching <- verifiedHandoffForInput broker input payloadA
                authenticated <- expectRight (verifiedConfigPayload matching)
                admitted <- withAuthenticatedConfigWire codec authenticated $ \wireA configA -> do
                    verifiedConfigDigest wireA @?= childConfigDigest payloadA
                    validatedConfigDigest configA @?= verifiedConfigDigest wireA
                    validatedConfigSpecDigest configA @?= specDigest
                    observe matching wireA configA >>= (@?= (Right (), 1))
                    -- Only the signed kind changes; use the genuine joint A pair
                    -- directly so the earlier config-payload extractor cannot mask it.
                    recovery <- verifiedHandoffForInput broker
                        input{requestedPayloadKind = RecoveryAdapterWire} payloadA
                    observe recovery wireA configA
                        >>= (@?= (Left (HandoffBindingMismatch "the authenticated payload is not a project config"), 0))
                    -- B is independently admitted under this exact codec and scope;
                    -- BOTH its wire and its validated config share B's own configId.
                    other <- withValidatedConfig codec cfgB $ \wireB configB -> do
                        verifiedConfigDigest wireB @?= childConfigDigest payloadB
                        validatedConfigDigest configB @?= verifiedConfigDigest wireB
                        validatedConfigSpecDigest configB @?= specDigest
                        assertBool "the actual joint wire identities name different digests"
                            (verifiedConfigDigest wireA /= verifiedConfigDigest wireB)
                        observe matching wireB configB
                            >>= (@?= (Left (HandoffBindingMismatch "the handoff and verified config wire digests differ"), 0))
                    other @?= Right ()
                    differentSpec <- verifiedHandoffForInput broker
                        input{requestedSpecDigest = specDigest <> ":other"} payloadA
                    observe differentSpec wireA configA
                        >>= (@?= (Left (HandoffBindingMismatch "the handoff and validated config specification digests differ"), 0))
                    unknownPhase <- verifiedHandoffForInput broker
                        input{requestedPhase = "future-phase"} payloadA
                    observe unknownPhase wireA configA
                        >>= (@?= (Left (HandoffBindingMismatch "the handoff names an unknown lifecycle phase"), 0))
                admitted @?= Right ()
    , testCase "a parent cannot offer payload or token bytes the binding does not describe" $
        withHandoff 7 ProjectUp $ \broker -> do
            token <- freshHandoffToken
            replacement <- freshHandoffToken
            binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
            relay <- expectRight (brokerRelay broker binding)
            expectBindingRefusal "the binding's child config digest does not describe the payload being offered"
                (mkHandoffOffer relay "different bytes entirely" token)
            expectBindingRefusal "the binding's token commitment does not describe the offered token"
                (mkHandoffOffer relay childPayload replacement)
    , testCase "a missing, malformed, or trailing token frame is refused" $
        withHandoff 7 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            let key = rootBrokerVerificationKey broker
                verifyWire wire = verifyHandoff key wire binding challenge grant
            case verifyWire (frameWire childPayload) of
                Left (HandoffWireTruncated{}) -> pure ()
                other -> assertFailure ("expected a truncated-wire refusal, got " <> show other)
            case verifyWire (frameWire childPayload <> frameWire "" <> frameWire (renderHandoffBinding binding)) of
                Left HandoffTokenInvalid -> pure ()
                other -> assertFailure ("expected an invalid-token refusal, got " <> show other)
            case verifyWire (handoffOfferWire offer <> "junk") of
                Left (HandoffWireTrailingBytes _) -> pure ()
                other -> assertFailure ("expected a trailing-bytes refusal, got " <> show other)
    , testCase "granting one edge does not consume another edge's token" $
        withHandoff 7 ProjectUp $ \broker -> do
            (_, signedOffer) <- newOffer broker childPayload
            (binding, untouchedOffer) <- newOffer broker childPayload
            challenge <- freshChallenge
            wrongGrant <- expectRightIO =<< grantHandoff broker signedOffer challenge
            expectSignatureRefusal
                ( verifyHandoff
                    (rootBrokerVerificationKey broker)
                    (handoffOfferWire untouchedOffer)
                    binding
                    challenge
                    wrongGrant
                )
            goodGrant <- expectRightIO =<< grantHandoff broker untouchedOffer challenge
            assertBool
                "the root can still authorize the untouched token"
                (isRight (verifyHandoff (rootBrokerVerificationKey broker) (handoffOfferWire untouchedOffer) binding challenge goodGrant))
    , testCase "installed signing and verification files are validated independently" $
        withSystemTempDirectory "hostbootstrap-handoff-key" $ \directory -> do
            let signingPath = directory </> "project.key"
                publicPath = directory </> "project.pub"
                seed = ByteString.replicate 32 19
            signing <- expectRight (projectSigningKeyFromBytes seed)
            ByteString.writeFile signingPath seed
            ByteString.writeFile publicPath (verificationKeyBytes (projectSigningVerificationKey signing))
            loadedSigning <- installedProjectSigningKey signingPath >>= expectRightIO
            loadedPublic <- installedVerificationKey publicPath >>= expectRightIO
            verificationKeyBytes (projectSigningVerificationKey loadedSigning)
                @?= verificationKeyBytes loadedPublic
            installedProjectSigningKey (directory </> "absent.key") >>= expectSigningKeyUnavailable
            installedVerificationKey (directory </> "absent.pub") >>= expectVerificationKeyUnavailable
            ByteString.writeFile signingPath "not a key"
            installedProjectSigningKey signingPath >>= \result -> case result of
                Left HandoffSigningKeyInvalid -> pure ()
                other -> assertFailure ("expected a malformed signing-key refusal, got " <> show other)
            ByteString.writeFile publicPath "not a key"
            installedVerificationKey publicPath >>= expectVerificationKeyUnavailable
    , testCase "Show and errors redact payload, token, and key bytes" $
        withHandoff 7 ProjectUp $ \broker -> do
            (_, offer) <- newOffer broker secretPayload
            challenge <- freshChallenge
            grant <- expectRightIO =<< grantHandoff broker offer challenge
            let (_, tokenBytes, _) = handoffOfferFrames offer
                seed = ByteString.replicate 32 7
                publicBytes = verificationKeyBytes (rootBrokerVerificationKey broker)
                values =
                    [ ("offer", show offer, "<redacted>")
                    , ("broker", show broker, "<signing>")
                    , ("grant", show grant, "<signed>")
                    ]
                secrets = [("payload", secretPayload), ("token", tokenBytes), ("signing seed", seed), ("verification key", publicBytes)]
                forms bytes =
                    let hexadecimal = concatMap (\byte -> let digits = showHex byte "" in if length digits == 1 then '0' : digits else digits) (ByteString.unpack bytes)
                     in [("raw", ByteStringChar8.unpack bytes), ("hex", hexadecimal), ("upper hex", map toUpper hexadecimal), ("show", show bytes)]
            ByteString.length tokenBytes @?= 32
            ByteString.length publicBytes @?= 32
            forM_ values $ \(valueName, rendered, marker) -> do
                assertBool (valueName <> " has its own opaque marker") (marker `isInfixOf` rendered)
                forM_ secrets $ \(secretName, bytes) ->
                    forM_ (forms bytes) $ \(form, spelling) ->
                        assertBool (valueName <> " exposes " <> secretName <> " in " <> form <> " form") (not (spelling `isInfixOf` rendered))
            forM_ secrets $ \(secretName, bytes) ->
                forM_ (forms bytes) $ \(form, spelling) ->
                    assertBool ("the consumed-token error exposes " <> secretName <> " in " <> form <> " form") (not (spelling `isInfixOf` show HandoffTokenConsumed))
            assertBool "consumed-token diagnostics carry no token" (handoffErrorMessage HandoffTokenConsumed == "handoff: one-time token has already authorized another transcript")
    , testCase "handoff errors omit the dormant frame-mismatch alternative" $
        withHandoffPackageRoot $ \packageRoot -> do
            -- DEVELOPMENT_PLAN/rationale.md#child-plan-admission-retains-authenticated-origin
            (source, _) <- readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff"
            SourceGuard.countHaskellIdentifier "HandoffFrameMismatch" source @?= 0
    , testCase "installed key reads catch only IO exceptions" $
        withHandoffPackageRoot $ \packageRoot -> do
            -- DEVELOPMENT_PLAN/rationale.md#handoff-bindings-retain-their-admitted-fields
            source <- Text.unpack . TextEncoding.decodeUtf8 <$> (ByteString.readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            SourceGuard.countHaskellIdentifier "SomeException" source @?= 0
            forM_ ["installedProjectSigningKey", "installedVerificationKey"] $ \name -> do
                body <- either assertFailure pure (SourceGuard.haskellDefinitionTokens name source)
                assertBool (name <> " catches only read IO failures")
                    (SourceGuard.haskellTokens "try (ByteString.readFile path) :: IO (Either IOException ByteString)" `isInfixOf` body)
    ]

-- ---------------------------------------------------------------------------
-- Recovery wire

recoveryTests :: [TestTree]
recoveryTests =
    [ testCase "partial recovery-signer application forces the hidden capability" $ do
        forced <-
            try @SomeException
                (evaluate (signRecoveryWireKernel (error "forced hidden recovery capability")))
        case forced of
            Left failure ->
                assertBool
                    "the hidden capability is forced before a broker-taking function is returned"
                    ("forced hidden recovery capability" `contains` show failure)
            Right _ -> assertFailure "the partial recovery signer did not force its hidden capability"
    , testCase "partial recoverable registration forces the hidden capability" $ do
        forced <-
            try @SomeException
                ( evaluate
                    ( registerRecoverableAdmittedHandoffEdgeKernel
                        (error "forced hidden recoverable-open capability")
                    )
                )
        case forced of
            Left failure ->
                assertBool
                    "the hidden capability is forced before a broker-taking function is returned"
                    ("forced hidden recoverable-open capability" `contains` show failure)
            Right _ -> assertFailure "the partial recoverable registration did not force its hidden capability"
    , testCase "the canonical request/response verifies only with the independent key" $
        withHandoff 21 ProjectDestroy $ \broker ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryBinding broker recoveryInput recoveryPayload $ \binding -> do
                    request <- expectRight (recoveryRequestFields binding recoveryPayload)
                    decoded <-
                        expectRight
                            ( recoveryRequestFromFields broker recoveryInput request $ \decodedBinding decodedWire ->
                                (renderRecoveryProjectionBinding decodedBinding, decodedWire)
                            )
                    decoded @?= (renderRecoveryProjectionBinding binding, recoveryPayload)
                    grant <-
                        recoveryOracleGrant
                            21
                            (rootBrokerVerificationKey broker)
                            binding
                            recoveryPayload
                    response <- expectRight (recoveryResponseFromFields binding (recoveryResponseFields grant))
                    withVerifiedRecoveryWire
                        (rootBrokerVerificationKey broker)
                        binding
                        recoveryPayload
                        response
                        verifiedRecoveryWireBytes
                        @?= Right recoveryPayload
    , testCase "wrong key, domain, wire, raw signature, plan, and edge each refuse" $
        withHandoff 22 ProjectDestroy $ \broker ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryBinding broker recoveryInput recoveryPayload $ \binding -> do
                    let verificationKey = rootBrokerVerificationKey broker
                    grant <- recoveryOracleGrant 22 verificationKey binding recoveryPayload
                    otherSigning <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 91))
                    let verifyWith key bytes candidate =
                            withVerifiedRecoveryWire key binding bytes candidate (const ())
                    verifyWith (projectSigningVerificationKey otherSigning) recoveryPayload grant
                        @?= Left HandoffRecoverySignatureInvalid
                    wrongDomain <-
                        recoveryOracleGrantWithDomain
                            22
                            "hostbootstrap/recovery-wire/not-v1"
                            verificationKey
                            binding
                            recoveryPayload
                    verifyWith verificationKey recoveryPayload wrongDomain
                        @?= Left HandoffRecoverySignatureInvalid
                    case verifyWith (rootBrokerVerificationKey broker) "changed-wire" grant of
                        Left (HandoffPayloadDigestMismatch _ _) -> pure ()
                        other -> assertFailure ("expected wrong-wire refusal, got " <> show other)
                    raw <- expectRight (recoveryWireGrantFromSignature binding (ByteString.replicate 64 0))
                    verifyWith (rootBrokerVerificationKey broker) recoveryPayload raw
                        @?= Left HandoffRecoverySignatureInvalid
                    traverse_
                        ( \coordinates ->
                            withRecoveryInput coordinates $ \substituted ->
                                assertSubstitutedRecoveryRefuses
                                    broker
                                    (recoveryWireGrantSignature grant)
                                    substituted
                        )
                        [ baseRecoveryCoordinates{recoveryPlanCoordinate = "other-plan"}
                        , baseRecoveryCoordinates{recoveryParentCoordinate = "other-parent"}
                        , baseRecoveryCoordinates{recoveryChildCoordinate = "other-child"}
                        ]
    , testCase "the binding and response codecs reject truncation, trailing bytes, and wrong field counts" $
        withHandoff 23 ProjectDestroy $ \broker ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryBinding broker recoveryInput recoveryPayload $ \binding -> do
                    let encoded = renderRecoveryProjectionBinding binding
                        parse raw = recoveryProjectionBindingFromWire broker recoveryInput raw (const ())
                    case parse (ByteString.take (ByteString.length encoded - 1) encoded) of
                        Left (HandoffWireTruncated _ _) -> pure ()
                        other -> assertFailure ("expected truncated binding refusal, got " <> show other)
                    parse (encoded <> "trailing") @?= Left (HandoffWireTrailingBytes 8)
                    recoveryRequestFromFields broker recoveryInput [encoded] (\_ _ -> ())
                        @?= Left (HandoffRecoveryFieldCount "request" 2 1)
                    case recoveryResponseFromFields binding [] of
                        Left failure -> failure @?= HandoffRecoveryFieldCount "response" 1 0
                        Right _ -> assertFailure "expected an empty recovery response to refuse"
                    case recoveryResponseFromFields binding [ByteString.replicate 63 0] of
                        Left (HandoffRecoverySignatureLength 64 63) -> pure ()
                        _ -> assertFailure "expected a truncated recovery response to refuse"
    , testCase "an externally signed Up recovery projection cannot enter the teardown join" $
        withHandoff 24 ProjectUp $ \broker ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryBinding broker recoveryInput recoveryPayload $ \projection -> do
                    recoveryGrant <-
                        recoveryOracleGrant
                            24
                            (rootBrokerVerificationKey broker)
                            projection
                            recoveryPayload
                    (binding, offer) <-
                        newOfferWith
                            broker
                            (recoveryBindingInput recoveryInput recoveryPayload)
                            recoveryPayload
                    challenge <- freshChallenge
                    configGrant <- expectRightIO =<< grantHandoff broker offer challenge
                    handoff <-
                        expectRight
                            ( verifyHandoff
                                (rootBrokerVerificationKey broker)
                                (handoffOfferWire offer)
                                binding
                                challenge
                                configGrant
                            )
                    withVerifiedRecoveryHandoff
                        ProjectUp
                        projection
                        recoveryGrant
                        handoff
                        (const ())
                        @?= Left (HandoffRecoveryVerbInvalid "up")
    , testCase "config and recovery handoffs do not substitute" $ do
        withHandoff 25 ProjectDestroy $ \broker ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryBinding broker recoveryInput recoveryPayload $ \projection -> do
                    recoveryGrant <-
                        recoveryOracleGrant
                            25
                            (rootBrokerVerificationKey broker)
                            projection
                            recoveryPayload
                    (recoveryBinding, recoveryOffer) <- newOfferWith broker (recoveryBindingInput recoveryInput recoveryPayload) recoveryPayload
                    challenge <- freshChallenge
                    ordinaryGrant <- expectRightIO =<< grantHandoff broker recoveryOffer challenge
                    recoveryHandoff <-
                        expectRight
                            ( verifyHandoff
                                (rootBrokerVerificationKey broker)
                                (handoffOfferWire recoveryOffer)
                                recoveryBinding
                                challenge
                                ordinaryGrant
                            )
                    case verifiedConfigPayload recoveryHandoff of
                        Left (HandoffBindingMismatch _) -> pure ()
                        other -> assertFailure ("expected recovery-as-config refusal, got " <> show other)
                    withVerifiedRecoveryHandoff
                        ProjectDestroy
                        projection
                        recoveryGrant
                        recoveryHandoff
                        (const ())
                        @?= Right ()
                    (_, configOffer) <- newOffer broker childPayload
                    configChallenge <- freshChallenge
                    configGrant <- expectRightIO =<< grantHandoff broker configOffer configChallenge
                    configHandoff <-
                        expectRight
                            ( verifyHandoff
                                (rootBrokerVerificationKey broker)
                                (handoffOfferWire configOffer)
                                (handoffOfferBinding configOffer)
                                configChallenge
                                configGrant
                            )
                    case withVerifiedRecoveryHandoff
                        ProjectDestroy
                        projection
                        recoveryGrant
                        configHandoff
                        (const ()) of
                        Left (HandoffBindingMismatch _) -> pure ()
                        other -> assertFailure ("expected config-as-recovery refusal, got " <> show other)
    , testCase "a recovery join uses the key retained by the verified handoff" $
        withHandoffPair 26 27 ProjectDestroy $ \handoffBroker recoveryBroker ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryBinding handoffBroker recoveryInput recoveryPayload $ \projection -> do
                    -- Both brokers are valid for the same root evidence and durable
                    -- route, but only the first key authenticated this handoff.
                    -- A caller must not be able to replace that retained key at the
                    -- config/recovery join.
                    foreignRecoveryGrant <-
                        recoveryOracleGrant
                            27
                            (rootBrokerVerificationKey recoveryBroker)
                            projection
                            recoveryPayload
                    (binding, offer) <-
                        newOfferWith
                            handoffBroker
                            (recoveryBindingInput recoveryInput recoveryPayload)
                            recoveryPayload
                    challenge <- freshChallenge
                    grant <- expectRightIO =<< grantHandoff handoffBroker offer challenge
                    handoff <-
                        expectRight
                            ( verifyHandoff
                                (rootBrokerVerificationKey handoffBroker)
                                (handoffOfferWire offer)
                                binding
                                challenge
                                grant
                            )
                    withVerifiedRecoveryHandoff
                        ProjectDestroy
                        projection
                        foreignRecoveryGrant
                        handoff
                        (const ())
                        @?= Left HandoffRecoverySignatureInvalid
    , testCase "a recovery grant cannot replay across protected stores" $
        withSystemTempDirectory "hostbootstrap-recovery-cross-store" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 28))
            firstStore <- openProtectedStore (directory </> "first") >>= expectRightIO
            secondStore <- openProtectedStore (directory </> "second") >>= expectRightIO
            Fixture.withFixtureInstalledProject $ \project -> do
                signature <-
                    captureRecoverySignature 28 signing firstStore project ProjectDestroy
                withRecoveryBroker signing secondStore project ProjectDestroy $ \broker ->
                    withRecoveryInput baseRecoveryCoordinates $ \input ->
                        assertRecoveryReplayRefused
                            broker
                            ProjectDestroy
                            input
                            signature
    , testCase "a recovery grant cannot replay across broker generations" $
        withSystemTempDirectory "hostbootstrap-recovery-cross-generation" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 29))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            Fixture.withFixtureInstalledProject $ \project -> do
                signature <- captureRecoverySignature 29 signing store project ProjectDestroy
                withRecoveryBroker signing store project ProjectDestroy $ \broker ->
                    withRecoveryInput baseRecoveryCoordinates $ \input ->
                        assertRecoveryReplayRefused
                            broker
                            ProjectDestroy
                            input
                            signature
    , testCase "down and destroy recovery grants refuse substitution in both directions" $
        withSystemTempDirectory "hostbootstrap-recovery-cross-verb" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 30))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            Fixture.withFixtureInstalledProject $ \project -> do
                downSignature <- captureRecoverySignature 30 signing store project ProjectDown
                destroySignature <- captureRecoverySignature 30 signing store project ProjectDestroy
                withRecoveryBroker signing store project ProjectDestroy $ \broker ->
                    withRecoveryInput baseRecoveryCoordinates $ \input ->
                        assertRecoveryReplayRefused
                            broker
                            ProjectDestroy
                            input
                            downSignature
                withRecoveryBroker signing store project ProjectDown $ \broker ->
                    withRecoveryInput baseRecoveryCoordinates $ \input ->
                        assertRecoveryReplayRefused
                            broker
                            ProjectDown
                            input
                            destroySignature
    ]

-- ---------------------------------------------------------------------------
-- Lifecycle completion wire

lifecycleCompletionWireTests :: [TestTree]
lifecycleCompletionWireTests =
    [ testCase "child lifecycle rows publish, converge, receive, and refuse conflicts against a real store" $
        withSystemTempDirectory "hostbootstrap-lifecycle-child-rows" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 51))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            foreignStore <- openProtectedStore (directory </> "foreign") >>= expectRightIO
            Fixture.withFixtureInstalledProject $ \project ->
                withRecoveryBroker signing store project ProjectUp $ \broker -> do
                    token <- freshHandoffToken
                    binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
                    let bindingBytes = renderHandoffBinding binding
                        conflict = Left (HandoffBindingMismatch "the lifecycle durable row conflicts")
                        kernel = HandoffInternal.recoverySigningKernel
                    report <- expectRight (renderForwardRefusedLifecycleReport bindingBytes "policy")
                    different <- expectRight (renderForwardFailedLifecycleReport bindingBytes "boom")
                    acknowledgement <- expectRight (renderLifecycleAcknowledgement report)
                    -- A fresh publish and an exact re-publish converge.
                    publishLifecycleReportKernel kernel store report >>= (@?= Right ())
                    publishLifecycleReportKernel kernel store report >>= (@?= Right ())
                    -- A different report under the same binding conflicts.
                    publishLifecycleReportKernel kernel store different >>= (@?= conflict)
                    -- Receive writes the exact acknowledgement; a retry and a late re-publish converge.
                    receiveLifecycleAcknowledgementKernel kernel store report acknowledgement >>= (@?= Right ())
                    receiveLifecycleAcknowledgementKernel kernel store report acknowledgement >>= (@?= Right ())
                    publishLifecycleReportKernel kernel store report >>= (@?= Right ())
                    -- A report naming another store refuses before any write.
                    foreignPublish <- publishLifecycleReportKernel kernel foreignStore report
                    foreignPublish @?= Left (HandoffBindingMismatch "the lifecycle report names a different protected store")
                    -- Receiving a report that was never published finds no row.
                    otherToken <- freshHandoffToken
                    otherBinding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) otherToken)
                    unpublished <- expectRight (renderForwardRefusedLifecycleReport (renderHandoffBinding otherBinding) "policy")
                    unpublishedAcknowledgement <- expectRight (renderLifecycleAcknowledgement unpublished)
                    receiveLifecycleAcknowledgementKernel kernel store unpublished unpublishedAcknowledgement >>= (@?= conflict)
    , testCase "parent lifecycle rows advance one to two to three and answer pending, fresh, and replay exactly" $
        withSystemTempDirectory "hostbootstrap-lifecycle-parent-rows" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 53))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            Fixture.withFixtureInstalledProject $ \project ->
                withRecoveryBroker signing store project ProjectUp $ \broker -> do
                    (binding, offer) <- newOffer broker childPayload
                    challenge <- freshChallenge
                    _ <- expectRightIO =<< grantHandoff broker offer challenge
                    let bindingBytes = renderHandoffBinding binding
                        kernel = HandoffInternal.recoverySigningKernel
                    report <- expectRight (renderForwardRefusedLifecycleReport bindingBytes "policy")
                    acknowledgement <- expectRight (renderLifecycleAcknowledgement report)
                    pendingRuns <- newIORef (0 :: Int)
                    replayRuns <- newIORef (0 :: Int)
                    freshRuns <- newIORef (0 :: Int)
                    let bump counter = modifyIORef' counter (+ 1) >> pure (Right ()) :: IO (Either () ())
                        prepare =
                            prepareLifecycleAcknowledgementKernel
                                kernel
                                broker
                                offer
                                challenge
                                report
                                acknowledgement
                                (const (bump pendingRuns))
                                (const (bump replayRuns))
                        adopt = adoptLifecycleAcknowledgementKernel kernel broker offer challenge report acknowledgement (bump freshRuns) (bump replayRuns)
                        parentVersions = do
                            image <- readProtectedRecordsImage store
                            pure [version | (key, version, _) <- image, "lifecycle-parent." `Text.isPrefixOf` key]
                        counts = (,,) <$> readIORef pendingRuns <*> readIORef freshRuns <*> readIORef replayRuns
                    prepare >>= (@?= Right (Right ()))
                    parentVersions >>= (@?= [2])
                    counts >>= (@?= (1, 0, 0))
                    -- A version-two row is still pending: the same exact prepare repeats.
                    prepare >>= (@?= Right (Right ()))
                    parentVersions >>= (@?= [2])
                    counts >>= (@?= (2, 0, 0))
                    -- Adoption advances to version three and takes the fresh continuation once.
                    adopt >>= (@?= Right (Right ()))
                    parentVersions >>= (@?= [3])
                    counts >>= (@?= (2, 1, 0))
                    -- An exact version-three replay takes the replay continuation and writes nothing.
                    adopt >>= (@?= Right (Right ()))
                    prepare >>= (@?= Right (Right ()))
                    parentVersions >>= (@?= [3])
                    counts >>= (@?= (2, 1, 2))
                    -- A challenge the broker never granted authenticates no edge.
                    stale <- freshChallenge
                    refusal <-
                        prepareLifecycleAcknowledgementKernel kernel broker offer stale report acknowledgement (const (bump pendingRuns)) (const (bump replayRuns))
                    refusal @?= Left (HandoffBindingMismatch "the lifecycle offer is not an authenticated granted edge")
    , testCase "of two concurrent adopters exactly one is the fresh winner" $
        withSystemTempDirectory "hostbootstrap-lifecycle-concurrent-adopt" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 54))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            Fixture.withFixtureInstalledProject $ \project ->
                withRecoveryBroker signing store project ProjectUp $ \broker -> do
                    (binding, offer) <- newOffer broker childPayload
                    challenge <- freshChallenge
                    _ <- expectRightIO =<< grantHandoff broker offer challenge
                    report <- expectRight (renderForwardRefusedLifecycleReport (renderHandoffBinding binding) "policy")
                    acknowledgement <- expectRight (renderLifecycleAcknowledgement report)
                    let kernel = HandoffInternal.recoverySigningKernel
                    prepared <-
                        prepareLifecycleAcknowledgementKernel kernel broker offer challenge report acknowledgement (const (pure (Right ()))) (const (pure (Right ())))
                    (prepared :: Either HandoffError (Either () ())) @?= Right (Right ())
                    winners <- newIORef (0 :: Int)
                    replays <- newIORef (0 :: Int)
                    done <- newEmptyMVar
                    let adopt =
                            adoptLifecycleAcknowledgementKernel
                                kernel
                                broker
                                offer
                                challenge
                                report
                                acknowledgement
                                (modifyIORef' winners (+ 1) >> pure (Right ()))
                                (modifyIORef' replays (+ 1) >> pure (Right ()))
                        racer = do
                            outcome <- adopt
                            putMVar done (outcome :: Either HandoffError (Either () ()))
                    _ <- forkIO racer
                    _ <- forkIO racer
                    first <- takeMVar done
                    second <- takeMVar done
                    (first, second) @?= (Right (Right ()), Right (Right ()))
                    (,) <$> readIORef winners <*> readIORef replays >>= (@?= (1, 1))
    , testCase "parent lifecycle rows refuse an ungranted edge, an unprepared adoption, and a foreign row" $
        withSystemTempDirectory "hostbootstrap-lifecycle-parent-refusals" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 55))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            Fixture.withFixtureInstalledProject $ \project ->
                withRecoveryBroker signing store project ProjectUp $ \broker -> do
                    let kernel = HandoffInternal.recoverySigningKernel
                        conflict = Left (HandoffBindingMismatch "the lifecycle durable row conflicts")
                        notGranted = Left (HandoffBindingMismatch "the lifecycle offer is not an authenticated granted edge")
                        keep = const (pure (Right ())) :: ByteString.ByteString -> IO (Either () ())
                        prepareWith offer challenge report acknowledgement =
                            prepareLifecycleAcknowledgementKernel kernel broker offer challenge report acknowledgement keep keep
                        adoptWith offer challenge report acknowledgement =
                            adoptLifecycleAcknowledgementKernel kernel broker offer challenge report acknowledgement (pure (Right ())) (pure (Right ())) :: IO (Either HandoffError (Either () ()))
                    -- An edge whose token row is still planned (never granted) authenticates nothing.
                    (planned, plannedOffer) <- newOffer broker childPayload
                    plannedChallenge <- freshChallenge
                    plannedReport <- expectRight (renderForwardRefusedLifecycleReport (renderHandoffBinding planned) "policy")
                    plannedAcknowledgement <- expectRight (renderLifecycleAcknowledgement plannedReport)
                    prepareWith plannedOffer plannedChallenge plannedReport plannedAcknowledgement >>= (@?= notGranted)
                    -- A granted edge whose parent row was never prepared cannot be adopted.
                    (granted, grantedOffer) <- newOffer broker childPayload
                    grantedChallenge <- freshChallenge
                    _ <- expectRightIO =<< grantHandoff broker grantedOffer grantedChallenge
                    grantedReport <- expectRight (renderForwardRefusedLifecycleReport (renderHandoffBinding granted) "policy")
                    grantedAcknowledgement <- expectRight (renderLifecycleAcknowledgement grantedReport)
                    adoptWith grantedOffer grantedChallenge grantedReport grantedAcknowledgement >>= (@?= conflict)
                    -- A foreign row at the parent key conflicts and is left byte-identical.
                    parentKey <-
                        either (assertFailure . show) pure $
                            mkRecordKey ("lifecycle-parent." <> recoveryWireDigest (renderHandoffBinding granted))
                    written <- withProtectedEntry store (\session -> compareAndSwapProtectedRecord session parentKey ExpectAbsent "foreign row")
                    either (assertFailure . show) (const (pure ())) written
                    before <- readProtectedRecordsImage store
                    prepareWith grantedOffer grantedChallenge grantedReport grantedAcknowledgement >>= (@?= conflict)
                    readProtectedRecordsImage store >>= (@?= before)
    , testCase "a store that cannot write a lifecycle row reports a store failure, not a row conflict" $
        withSystemTempDirectory "hostbootstrap-lifecycle-store-failure" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 56))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            Fixture.withFixtureInstalledProject $ \project ->
                withRecoveryBroker signing store project ProjectUp $ \broker -> do
                    (binding, offer) <- newOffer broker childPayload
                    challenge <- freshChallenge
                    _ <- expectRightIO =<< grantHandoff broker offer challenge
                    let bindingBytes = renderHandoffBinding binding
                        kernel = HandoffInternal.recoverySigningKernel
                        obstruct prefix = do
                            key <- either (assertFailure . show) pure (mkRecordKey (prefix <> recoveryWireDigest bindingBytes))
                            createDirectory (protectedStoreRoot store </> "records" </> Text.unpack (recordKeyText key) <.> "rec")
                        isStoreFailure outcome = case outcome of
                            Left (HandoffStoreFailure _) -> True
                            _ -> False
                    report <- expectRight (renderForwardRefusedLifecycleReport bindingBytes "policy")
                    acknowledgement <- expectRight (renderLifecycleAcknowledgement report)
                    -- A directory where the child row belongs cannot hold a record.
                    obstruct "lifecycle-child."
                    published <- publishLifecycleReportKernel kernel store report
                    assertBool ("the child row write was not a store failure: " <> show published) (isStoreFailure published)
                    -- The same for the parent row.
                    obstruct "lifecycle-parent."
                    prepared <-
                        prepareLifecycleAcknowledgementKernel
                            kernel
                            broker
                            offer
                            challenge
                            report
                            acknowledgement
                            (const (pure (Right ())))
                            (const (pure (Right ()))) ::
                            IO (Either HandoffError (Either () ()))
                    assertBool ("the parent row write was not a store failure: " <> show (() <$ prepared)) (isStoreFailure (() <$ prepared))
    , testCase "the relay's lifecycle response codec accepts only its exact canonical wire" $
        withSystemTempDirectory "hostbootstrap-lifecycle-response-codec" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 57))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            Fixture.withFixtureInstalledProject $ \project ->
                withRecoveryBroker signing store project ProjectUp $ \broker -> do
                    (binding, _offer) <- newOffer broker childPayload
                    report <- expectRight (renderForwardRefusedLifecycleReport (renderHandoffBinding binding) "policy")
                    acknowledgement <- expectRight (renderLifecycleAcknowledgement report)
                    canonical <- expectRight (Relay.renderLifecycleAcknowledgementResponse "adopt" "fresh" report acknowledgement)
                    fields <- framesOf canonical
                    length fields @?= 5
                    first <- newIORef (0 :: Int)
                    second <- newIORef (0 :: Int)
                    let bump counter = modifyIORef' counter (+ 1) >> pure (Right ())
                        decode raw =
                            Relay.withLifecycleAcknowledgementResponse "adopt" report acknowledgement raw "fresh" (bump first) "replay" (bump second)
                        rewrite index replacement = ByteString.concat (map frameWire [if i == index then replacement else field | (i, field) <- zip [0 :: Int ..] fields])
                        mismatch detail = Left (Relay.RelayHandoffFailure (HandoffBindingMismatch detail))
                        differs = mismatch "the lifecycle response differs from the exact request"
                    decode canonical >>= (@?= Right ())
                    readIORef first >>= (@?= 1)
                    -- The other accepted disposition takes the other continuation.
                    replay <- expectRight (Relay.renderLifecycleAcknowledgementResponse "adopt" "replay" report acknowledgement)
                    decode replay >>= (@?= Right ())
                    (,) <$> readIORef first <*> readIORef second >>= (@?= (1, 1))
                    let refusals =
                            [ ("domain", rewrite 0 "other-domain", differs)
                            , ("version", rewrite 1 "2", differs)
                            , ("stage", rewrite 2 "prepare", differs)
                            , ("disposition", rewrite 3 "pending", differs)
                            , ("acknowledgement", rewrite 4 "another acknowledgement", differs)
                            , ("trailing byte", canonical <> "x", mismatch "the lifecycle envelope has trailing bytes")
                            , ("a sixth field", canonical <> frameWire "extra", mismatch "the lifecycle envelope has trailing bytes")
                            ]
                    forM_ refusals $ \(label, wire, expected) -> do
                        outcome <- decode wire
                        (label :: String, outcome) @?= (label, expected)
                    (,) <$> readIORef first <*> readIORef second >>= (@?= (1, 1))
                    -- A truncated wire is a framing failure, never a continuation.
                    truncated <- decode (ByteString.init canonical)
                    case truncated of
                        Left (Relay.RelayHandoffFailure _) -> pure ()
                        other -> assertFailure ("a truncated response was not refused: " <> show other)
                    (,) <$> readIORef first <*> readIORef second >>= (@?= (1, 1))
    , testCase "a recoverable open rotates its token once the edge is granted and refuses a corrupt map" $
        withSystemTempDirectory "hostbootstrap-recoverable-rotation" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 58))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            let kernel = HandoffInternal.recoverySigningKernel
                input =
                    (bindingInputFor recoveryPayload)
                        { requestedPayloadKind = RecoveryAdapterWire
                        , requestedPhase = "teardown"
                        , requestedChildConfigDigest = childConfigDigest recoveryPayload
                        }
                register broker =
                    registerRecoverableAdmittedHandoffEdgeKernel kernel broker (pure (Right ()) :: IO (Either () ())) input recoveryPayload
                mapRows = filter (\(key, _, _) -> "recovery-open." `Text.isPrefixOf` key)
            Fixture.withFixtureInstalledProject $ \project ->
                withRecoveryBroker signing store project ProjectDestroy $ \broker -> do
                    first <- register broker
                    (firstRelay, firstToken) <- case first of
                        Right (Right edge) -> pure edge
                        other -> assertFailure ("the first registration was not admitted: " <> show (() <$ other))
                    [(mapKeyText, firstMapVersion, _)] <- mapRows <$> readProtectedRecordsImage store
                    firstMapVersion @?= 1
                    -- Granting the edge consumes its token; the next exact registration rotates.
                    offer <- expectRight (mkHandoffOffer firstRelay recoveryPayload firstToken)
                    challenge <- freshChallenge
                    _ <- expectRightIO =<< grantHandoff broker offer challenge
                    rotated <- register broker
                    (rotatedRelay, rotatedToken) <- case rotated of
                        Right (Right edge) -> pure edge
                        other -> assertFailure ("the rotated registration was not admitted: " <> show (() <$ other))
                    assertBool
                        "the rotated registration carries a fresh token"
                        (handoffTokenBytes rotatedToken /= handoffTokenBytes firstToken)
                    assertBool
                        "the rotated registration carries a fresh binding"
                        (renderHandoffBinding (relayBinding rotatedRelay) /= renderHandoffBinding (relayBinding firstRelay))
                    [(_, rotatedMapVersion, _)] <- mapRows <$> readProtectedRecordsImage store
                    rotatedMapVersion @?= 2
                    -- An exact retry after rotation is stable.
                    again <- register broker
                    case again of
                        Right (Right (againRelay, againToken)) -> do
                            handoffTokenBytes againToken @?= handoffTokenBytes rotatedToken
                            renderHandoffBinding (relayBinding againRelay) @?= renderHandoffBinding (relayBinding rotatedRelay)
                        other -> assertFailure ("the post-rotation retry was not admitted: " <> show (() <$ other))
                    -- A corrupt map record refuses with the exact malformed-map text and writes nothing.
                    mapKey <- either (assertFailure . show) pure (mkRecordKey mapKeyText)
                    corrupted <-
                        withProtectedEntry store $ \session -> do
                            found <- readProtectedRecord session mapKey >>= either (assertFailure . show) pure
                            current <- maybe (assertFailure "the recoverable-open map row is missing") pure found
                            compareAndSwapProtectedRecord session mapKey (ExpectVersion (protectedRecordVersion current)) (ByteString.concat (map frameWire ["other-domain", "1", "identity", "binding", "token"]))
                    either (assertFailure . show) (const (pure ())) corrupted
                    before <- readProtectedRecordsImage store
                    refusal <- register broker
                    case refusal of
                        Left failure -> failure @?= HandoffBindingMismatch "the recoverable-open map is malformed or conflicting"
                        Right _ -> assertFailure "a corrupt recoverable-open map was admitted"
                    readProtectedRecordsImage store >>= (@?= before)
                    -- A map record the store cannot serve is a store failure, not a map conflict.
                    let mapPath = protectedStoreRoot store </> "records" </> Text.unpack mapKeyText <.> "rec"
                    removePathForcibly mapPath
                    createDirectory mapPath
                    unreadable <- register broker
                    case unreadable of
                        Left (HandoffStoreFailure _) -> pure ()
                        other -> assertFailure ("an unreadable map was not a store failure: " <> show (() <$ other))
    , testCase "a recoverable open refuses a token row that is neither planned nor granted, writing nothing" $
        withSystemTempDirectory "hostbootstrap-recoverable-token-conflict" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 59))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            let kernel = HandoffInternal.recoverySigningKernel
                input =
                    (bindingInputFor recoveryPayload)
                        { requestedPayloadKind = RecoveryAdapterWire
                        , requestedPhase = "teardown"
                        , requestedChildConfigDigest = childConfigDigest recoveryPayload
                        }
                register broker =
                    registerRecoverableAdmittedHandoffEdgeKernel kernel broker (pure (Right ()) :: IO (Either () ())) input recoveryPayload
            Fixture.withFixtureInstalledProject $ \project ->
                withRecoveryBroker signing store project ProjectDestroy $ \broker -> do
                    before <- readProtectedRecordsImage store
                    first <- register broker
                    case first of
                        Right (Right _) -> pure ()
                        other -> assertFailure ("the first registration was not admitted: " <> show (() <$ other))
                    afterFirst <- readProtectedRecordsImage store
                    let created = [row | row@(key, _, _) <- afterFirst, row `notElem` before, not ("recovery-open." `Text.isPrefixOf` key)]
                    (tokenKeyText, _, _) <- case created of
                        [row] -> pure row
                        rows -> assertFailure ("expected exactly one planned token row, found " <> show (length rows))
                    tokenKey <- either (assertFailure . show) pure (mkRecordKey tokenKeyText)
                    -- Replace the planned token row with bytes that are neither planned nor granted.
                    replaced <-
                        withProtectedEntry store $ \session -> do
                            found <- readProtectedRecord session tokenKey >>= either (assertFailure . show) pure
                            current <- maybe (assertFailure "the token row is missing") pure found
                            compareAndSwapProtectedRecord session tokenKey (ExpectVersion (protectedRecordVersion current)) "foreign token row"
                    either (assertFailure . show) (const (pure ())) replaced
                    changed <- readProtectedRecordsImage store
                    refusal <- register broker
                    case refusal of
                        Left failure -> failure @?= HandoffBindingMismatch "the recoverable token record conflicts"
                        Right _ -> assertFailure "a foreign token row was admitted"
                    readProtectedRecordsImage store >>= (@?= changed)
    , testCase "a recoverable open registers once, retries exactly, and refuses each malformed coordinate" $
        withSystemTempDirectory "hostbootstrap-recoverable-open" $ \directory -> do
            signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 52))
            store <- openProtectedStore (directory </> "authority") >>= expectRightIO
            let kernel = HandoffInternal.recoverySigningKernel
                input =
                    (bindingInputFor recoveryPayload)
                        { requestedPayloadKind = RecoveryAdapterWire
                        , requestedPhase = "teardown"
                        , requestedChildConfigDigest = childConfigDigest recoveryPayload
                        }
                admit = pure (Right ()) :: IO (Either () ())
                mismatch = HandoffBindingMismatch
                register broker candidate adapter =
                    registerRecoverableAdmittedHandoffEdgeKernel kernel broker admit candidate adapter
                refused broker label candidate adapter expected = do
                    outcome <- register broker candidate adapter
                    case outcome of
                        Left failure -> (label, failure) @?= (label, expected)
                        Right _ -> assertFailure (label <> " was admitted")
            Fixture.withFixtureInstalledProject $ \project -> do
                withRecoveryBroker signing store project ProjectDestroy $ \broker -> do
                    before <- readProtectedRecordsImage store
                    first <- register broker input recoveryPayload
                    (firstRelay, firstToken) <- case first of
                        Right (Right edge) -> pure edge
                        other -> assertFailure ("the first registration was not admitted: " <> show (() <$ other))
                    afterFirst <- readProtectedRecordsImage store
                    length afterFirst @?= length before + 2
                    retry <- register broker input recoveryPayload
                    case retry of
                        Right (Right (retryRelay, retryToken)) -> do
                            renderHandoffBinding (relayBinding retryRelay) @?= renderHandoffBinding (relayBinding firstRelay)
                            handoffTokenBytes retryToken @?= handoffTokenBytes firstToken
                        other -> assertFailure ("the exact retry was not admitted: " <> show (() <$ other))
                    readProtectedRecordsImage store >>= (@?= afterFirst)
                    refused broker "empty adapter" input ByteString.empty (mismatch "the recovery adapter wire is empty")
                    refused broker "adapter digest" input "another adapter" (mismatch "the recovery adapter digest differs from the binding input")
                    refused broker "phase" input{requestedPhase = "execute"} recoveryPayload (mismatch "recoverable open requires teardown")
                    refused broker "payload kind" input{requestedPayloadKind = NarrowedProjectConfig} recoveryPayload (mismatch "recoverable open requires recovery-adapter-wire")
                    refused broker "empty coordinate" input{requestedPlanRevision = ""} recoveryPayload (mismatch "the recoverable-open binding input contains an empty coordinate")
                    readProtectedRecordsImage store >>= (@?= afterFirst)
                withRecoveryBroker signing store project ProjectUp $ \broker ->
                    refused broker "up verb" input recoveryPayload (HandoffRecoveryVerbInvalid "up")
    , testCase "ordered lifecycle observations round-trip through the exact closed table" $ do
        let rows =
                [ ("release", "released", "none")
                , ("foreign", "foreign-retained", "owned elsewhere")
                , ("refusal", "refused", "policy")
                , ("failure", "failed", "provider")
                ]
            expectedFields =
                [ "hostbootstrap/lifecycle-observations"
                , lifecycleWordBytesFor 1
                , lifecycleWordBytesFor 4
                , "release"
                , "released"
                , "none"
                , "foreign"
                , "foreign-retained"
                , "owned elsewhere"
                , "refusal"
                , "refused"
                , "policy"
                , "failure"
                , "failed"
                , "provider"
                ]
        wire <- expectRight (renderLifecycleObservations rows)
        lifecycleObservationsFromWire wire @?= Right rows
        framesOf wire >>= (@?= expectedFields)
        empty <- expectRight (renderLifecycleObservations [])
        lifecycleObservationsFromWire empty @?= Right []
        framesOf empty
            >>= ( @?=
                    [ "hostbootstrap/lifecycle-observations"
                    , lifecycleWordBytesFor 1
                    , lifecycleWordBytesFor 0
                    ]
                )
    , testCase "observation parsing rejects malformed rows, counts, UTF-8, truncation, and trailing bytes" $ do
        valid <- expectRight (renderLifecycleObservations [("one", "released", "none")])
        validFields <- framesOf valid
        let malformedWires =
                [ ("domain", wireWithFrames [(0, "other-domain")] validFields)
                , ("version", wireWithFrames [(1, lifecycleWordBytesFor 2)] validFields)
                , ("short count", wireWithFrames [(2, "\NUL")] validFields)
                , ("count too small", wireWithFrames [(2, lifecycleWordBytesFor 0)] validFields)
                , ("count too large", wireWithFrames [(2, lifecycleWordBytesFor 2)] validFields)
                , ("truncated", ByteString.init valid)
                , ("trailing", valid <> frameWire "trailing")
                ]
        forM_ malformedWires $ \(label, wire) ->
            assertLifecycleRefusal label (lifecycleObservationsFromWire wire)
        forM_ [3, 4, 5] $ \field ->
            assertLifecycleRefusal
                ("malformed UTF-8 field " <> show field)
                ( lifecycleObservationsFromWire
                    (wireWithFrames [(field, ByteString.pack [0xff])] validFields)
                )
        forM_
            [ ("empty key", [("", "released", "none")])
            , ("duplicate key", [("same", "released", "none"), ("same", "released", "none")])
            , ("unknown status", [("one", "unknown", "detail")])
            , ("released detail", [("one", "released", "detail")])
            , ("empty foreign detail", [("one", "foreign-retained", "")])
            , ("none foreign detail", [("one", "foreign-retained", "none")])
            , ("empty refusal detail", [("one", "refused", "")])
            , ("none refusal detail", [("one", "refused", "none")])
            , ("empty failure detail", [("one", "failed", "")])
            , ("none failure detail", [("one", "failed", "none")])
            ]
            $ \(label, rows) -> assertLifecycleRefusal label (renderLifecycleObservations rows)
    , testCase "observation and enclosing report bounds apply to the complete wire" $ do
        let overBound = fromIntegral maxWireBytes + 1
            oversizedDetail = Text.replicate (fromIntegral maxWireBytes) "x"
            nearBoundDetail = Text.replicate (fromIntegral maxWireBytes - 256) "x"
        assertLifecycleRefusal
            "oversized rendered observations"
            (renderLifecycleObservations [("one", "failed", oversizedDetail)])
        -- Pad an otherwise well-formed wire past the bound, so only the bound check can refuse it.
        emptyObservations <- expectRight (renderLifecycleObservations [])
        lifecycleObservationsFromWire (emptyObservations <> ByteString.replicate overBound 0)
            @?= Left (HandoffBindingMismatch "lifecycle observations exceeds the wire bound")
        withForwardLifecycleFixture 60 $ \binding _origin -> do
            report <- expectRight (renderForwardRefusedLifecycleReport binding "policy")
            acknowledgement <- expectRight (renderLifecycleAcknowledgement report)
            verifyLifecycleAcknowledgement report (acknowledgement <> ByteString.replicate overBound 0)
                @?= Left (HandoffBindingMismatch "lifecycle acknowledgement exceeds the wire bound")
        nearBound <-
            expectRight
                (renderLifecycleObservations [("one", "failed", nearBoundDetail)])
        withReverseLifecycleFixture 61 ProjectDestroy $ \binding _origin ->
            assertLifecycleRefusal
                "an individually bounded observation wire cannot make an oversized report"
                (renderReverseFailedLifecycleReport binding nearBound "child failed")
    , testCase "the exhaustive fold distinguishes all six canonical report branches" $
        withForwardLifecycleFixture 62 $ \forwardBinding forwardOrigin ->
            withReverseLifecycleFixture 63 ProjectDestroy $ \reverseBinding reverseOrigin -> do
                empty <- expectRight (renderLifecycleObservations [])
                completedRows <-
                    expectRight
                        ( renderLifecycleObservations
                            [ ("released", "released", "none")
                            , ("foreign", "foreign-retained", "retained")
                            , ("refused", "refused", "policy")
                            ]
                        )
                failedRows <-
                    expectRight
                        ( renderLifecycleObservations
                            [ ("released", "released", "none")
                            , ("failed", "failed", "boom")
                            ]
                        )
                forwardCompleted <- expectRight (renderForwardCompletedLifecycleReport forwardOrigin)
                forwardRefused <- expectRight (renderForwardRefusedLifecycleReport forwardBinding "policy")
                forwardFailed <- expectRight (renderForwardFailedLifecycleReport forwardBinding "boom")
                forwardFailedObserved <-
                    expectRight
                        ( renderForwardFailedLifecycleReportWithObservations
                            forwardBinding
                            [("prepared-node", "failed", "boom")]
                            "boom"
                        )
                forwardFailedRows <-
                    expectRight (renderLifecycleObservations [("prepared-node", "failed", "boom")])
                reverseCompleted <- expectRight (renderReverseCompletedLifecycleReport reverseOrigin completedRows)
                reverseRefused <- expectRight (renderReverseRefusedLifecycleReport reverseBinding completedRows "policy")
                reverseFailed <- expectRight (renderReverseFailedLifecycleReport reverseBinding failedRows "boom")
                let cases =
                        [ ("forward-completed", forwardCompleted, forwardBinding, Just forwardOrigin, empty, "none", "up")
                        , ("forward-refused", forwardRefused, forwardBinding, Nothing, empty, "policy", "up")
                        , ("forward-failed", forwardFailed, forwardBinding, Nothing, empty, "boom", "up")
                        , ("forward-failed", forwardFailedObserved, forwardBinding, Nothing, forwardFailedRows, "boom", "up")
                        , ("reverse-completed", reverseCompleted, reverseBinding, Just reverseOrigin, completedRows, "none", "destroy")
                        , ("reverse-refused", reverseRefused, reverseBinding, Nothing, completedRows, "policy", "destroy")
                        , ("reverse-failed", reverseFailed, reverseBinding, Nothing, failedRows, "boom", "destroy")
                        ]
                forM_ cases $ \(expectedBranch, report, expectedBinding, expectedOrigin, expectedRows, expectedDetail, expectedVerb) -> do
                    reportFields <- framesOf report
                    length reportFields @?= 8
                    take 2 reportFields
                        @?= ["hostbootstrap/lifecycle-report", lifecycleWordBytesFor 1]
                    (branch, binding, origin, observations, detail, verb) <-
                        expectRight (foldLifecycleReport report)
                    branch @?= expectedBranch
                    binding @?= expectedBinding
                    observations @?= expectedRows
                    detail @?= expectedDetail
                    verb @?= expectedVerb
                    case expectedOrigin of
                        Just terminal -> origin @?= terminal
                        Nothing -> assertNonterminalOrigin expectedBranch binding origin
    , testCase "terminal origins enforce exact fields, versions, and every reverse binding join" $
        withForwardLifecycleFixture 64 $ \_forwardBinding forwardOrigin ->
            withReverseLifecycleFixture 65 ProjectDestroy $ \reverseBinding reverseOrigin ->
                withForwardLifecycleFixture 66 $ \foreignForwardBinding _ -> do
                    forwardFields <- framesOf forwardOrigin
                    reverseFields <- framesOf reverseOrigin
                    length forwardFields @?= 9
                    length reverseFields @?= 16
                    -- Positive controls: the unmutated origins are admitted, so each refusal below
                    -- is caused by its one mutation and not by the fixture.
                    controlRows <- expectRight (renderLifecycleObservations [("one", "released", "none")])
                    _ <- expectRight (renderForwardCompletedLifecycleReport forwardOrigin)
                    _ <- expectRight (renderReverseCompletedLifecycleReport reverseOrigin controlRows)
                    let versionsDiffer = "the forward terminal record versions are not 1/2/3"
                        verbOrPhase = "the forward terminal verb or phase differs"
                        badForward =
                            [ ("domain", [(0, "wrong")], "the forward terminal origin domain differs")
                            , ("reverse binding", [(1, reverseBinding)], "a forward lifecycle binding has the wrong kind")
                            , ("empty invocation", [(2, "")], "the forward terminal invocation is empty")
                            , ("acquisition zero", [(3, "0")], "forward terminal version is not a canonical positive word")
                            , ("acquisition positive but wrong", [(3, "2")], versionsDiffer)
                            , ("execute positive but wrong", [(4, "1")], versionsDiffer)
                            , ("teardown positive but wrong", [(5, "2")], versionsDiffer)
                            , ("verb", [(6, "down")], verbOrPhase)
                            , ("execute phase", [(7, "teardown")], verbOrPhase)
                            , ("teardown phase", [(8, "execute")], verbOrPhase)
                            ]
                    forM_ badForward $ \(label, replacements, message) ->
                        ("forward origin " <> label :: String, renderForwardCompletedLifecycleReport (wireWithFrames replacements forwardFields))
                            @?= ("forward origin " <> label, Left (HandoffBindingMismatch message))
                    let alternateDigest = ByteString.replicate 64 97
                        differsFromBinding = "the reverse terminal origin differs from its binding"
                        reverseVersions = "the reverse terminal record versions differ from the lifecycle branch"
                        badReverse =
                            [ ("domain", [(0, "wrong")], "the reverse terminal origin domain or version differs")
                            , ("version", [(1, "2")], "the reverse terminal origin domain or version differs")
                            , ("forward binding", [(2, foreignForwardBinding)], "a reverse lifecycle binding has the wrong kind")
                            , ("plan join", [(3, "other-plan"), (4, "other-plan")], differsFromBinding)
                            , ("empty invocation", [(5, "")], "a reverse terminal coordinate is empty")
                            , ("acquisition zero", [(6, "0")], "reverse terminal version is not a canonical positive word")
                            , ("acquisition positive but wrong", [(6, "2")], reverseVersions)
                            , ("cursor positive but wrong", [(7, "2")], reverseVersions)
                            , ("child-frame join", [(8, "other-child"), (13, "other-child")], differsFromBinding)
                            , ("broker-generation join", [(9, "2")], differsFromBinding)
                            , ("verb joins", [(10, "down"), (11, "down"), (14, "down")], differsFromBinding)
                            , ("phase", [(12, "execute")], "the reverse terminal phase differs")
                            , ("adapter join", [(15, alternateDigest)], differsFromBinding)
                            ]
                    observations <- expectRight (renderLifecycleObservations [("one", "released", "none")])
                    forM_ badReverse $ \(label, replacements, message) ->
                        ( "reverse origin " <> label :: String
                        , renderReverseCompletedLifecycleReport (wireWithFrames replacements reverseFields) observations
                        )
                            @?= ("reverse origin " <> label, Left (HandoffBindingMismatch message))
    , testCase "report decoding rejects illegal branch semantics and noncanonical origins" $
        withForwardLifecycleFixture 67 $ \forwardBinding forwardOrigin ->
            withReverseLifecycleFixture 68 ProjectDown $ \reverseBinding reverseOrigin -> do
                empty <- expectRight (renderLifecycleObservations [])
                released <- expectRight (renderLifecycleObservations [("one", "released", "none")])
                failed <- expectRight (renderLifecycleObservations [("one", "failed", "boom")])
                completed <- expectRight (renderForwardCompletedLifecycleReport forwardOrigin)
                refused <- expectRight (renderForwardRefusedLifecycleReport forwardBinding "policy")
                reverseCompleted <- expectRight (renderReverseCompletedLifecycleReport reverseOrigin released)
                completedFields <- framesOf completed
                refusedFields <- framesOf refused
                reverseFields <- framesOf reverseCompleted
                let malformed =
                        [ ("wrong domain", wireWithFrames [(0, "wrong")] completedFields)
                        , ("wrong version", wireWithFrames [(1, lifecycleWordBytesFor 2)] completedFields)
                        , ("unknown branch", wireWithFrames [(2, "sideways")] completedFields)
                        , ("illegal status", wireWithFrames [(3, "pending")] completedFields)
                        , ("completed detail", wireWithFrames [(7, "detail")] completedFields)
                        , ("forward observations", wireWithFrames [(6, released)] completedFields)
                        , ("nonterminal detail none", wireWithFrames [(7, "none")] refusedFields)
                        , ("nonterminal origin splice", wireWithFrames [(5, forwardOrigin)] refusedFields)
                        , ("reverse completed empty", wireWithFrames [(6, empty)] reverseFields)
                        , ("reverse completed failed", wireWithFrames [(6, failed)] reverseFields)
                        , ("reverse binding on forward", wireWithFrames [(4, reverseBinding)] completedFields)
                        , ("truncated", ByteString.init completed)
                        , ("trailing", completed <> frameWire "extra")
                        , ("extra field", renderFrameFields (completedFields <> ["extra"]))
                        , ("malformed UTF-8 branch", wireWithFrames [(2, ByteString.pack [0xff])] completedFields)
                        ]
                forM_ malformed $ \(label, wire) ->
                    assertLifecycleRefusal label (foldLifecycleReport wire)
                -- Refusal cannot claim a failed teardown observation; failure may.
                assertLifecycleRefusal
                    "reverse refusal with a failed row"
                    (renderReverseRefusedLifecycleReport reverseBinding failed "policy")
                _ <- expectRight (renderReverseFailedLifecycleReport reverseBinding failed "boom")
                -- "succeeded" is a forward-completion status; a reverse child never reports it.
                succeeded <- expectRight (renderLifecycleObservations [("one", "succeeded", "none")])
                assertLifecycleRefusal
                    "reverse failed with a succeeded row"
                    (renderReverseFailedLifecycleReport reverseBinding succeeded "boom")
                pure ()
    , testCase "acknowledgements are exact three-field commitments and refuse another report" $
        withForwardLifecycleFixture 69 $ \binding origin -> do
            completed <- expectRight (renderForwardCompletedLifecycleReport origin)
            failed <- expectRight (renderForwardFailedLifecycleReport binding "boom")
            acknowledgement <- expectRight (renderLifecycleAcknowledgement completed)
            fields <- framesOf acknowledgement
            fields
                @?= [ "hostbootstrap/lifecycle-acknowledgement"
                    , lifecycleWordBytesFor 1
                    , TextEncoding.encodeUtf8 (recoveryWireDigest completed)
                    ]
            verifyLifecycleAcknowledgement completed acknowledgement @?= Right ()
            assertLifecycleRefusal
                "cross-report acknowledgement"
                (verifyLifecycleAcknowledgement failed acknowledgement)
            forM_
                [ ("domain", wireWithFrames [(0, "wrong")] fields)
                , ("version", wireWithFrames [(1, lifecycleWordBytesFor 2)] fields)
                , ("digest", wireWithFrames [(2, ByteString.replicate 64 48)] fields)
                , ("truncated", ByteString.init acknowledgement)
                , ("trailing", acknowledgement <> frameWire "extra")
                , ("extra field", renderFrameFields (fields <> ["extra"]))
                , ("over bound", ByteString.replicate (fromIntegral maxWireBytes + 1) 0)
                ]
                $ \(label, candidate) ->
                    assertLifecycleRefusal
                        ("acknowledgement " <> label)
                        (verifyLifecycleAcknowledgement completed candidate)
            assertLifecycleRefusal
                "acknowledgement renderer rejects a malformed report"
                (renderLifecycleAcknowledgement (ByteString.init completed))
    , testCase "codec ownership remains public, effect-free, and one-way" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            teardownSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Teardown")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            lifecycleSection <-
                requiredSourceSection
                    "the lifecycle codec section"
                    "-- ---------------------------------------------------------------------------\n-- Lifecycle completion wire\n\nrenderLifecycleObservations"
                    "-- ---------------------------------------------------------------------------\n-- Durable lifecycle acknowledgement"
                    handoffSource
            teardownCodecSection <-
                requiredSourceSection
                    "the typed teardown observation codec"
                    "renderTeardownObservations ::"
                    "{- | Root-only proof"
                    teardownSource
            exports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            let users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                publicCodecNames =
                    [ "renderLifecycleObservations"
                    , "lifecycleObservationsFromWire"
                    , "renderForwardCompletedLifecycleReport"
                    , "renderForwardRefusedLifecycleReport"
                    , "renderForwardFailedLifecycleReport"
                    , "renderForwardFailedLifecycleReportWithObservations"
                    , "renderReverseCompletedLifecycleReport"
                    , "renderReverseRefusedLifecycleReport"
                    , "renderReverseFailedLifecycleReport"
                    , "eliminateLifecycleReport"
                    , "renderLifecycleAcknowledgement"
                    , "verifyLifecycleAcknowledgement"
                    ]
                forbiddenEffects =
                    [ "LifecycleCompletion"
                    , "withProtectedEntry"
                    , "readProtectedRecord"
                    , "compareAndSwapProtectedRecord"
                    , "createProcess"
                    , "waitForProcess"
                    , "terminateProcess"
                    , "writeProtocolMessage"
                    , "readProtocolMessage"
                    , "CompletedTag"
                    , "AcknowledgedTag"
                    , "ExitSuccess"
                    , "EOF"
                    , "Handle"
                    , "IO "
                    ]
            forM_ publicCodecNames $ \name ->
                assertBool (name <> " is public") (name `elem` exports)
            users "renderLifecycleObservations"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Teardown.hs"]
            users "lifecycleObservationsFromWire"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown.hs"
                    , "src/HostBootstrap/Authority/FailedUp/Internal.hs"
                    ]
            users "renderForwardCompletedLifecycleReport"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "src/HostBootstrap/Handoff/TerminalReport.hs"
                    ]
            users "renderReverseCompletedLifecycleReport"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    ]
            users "eliminateLifecycleReport"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    , "src/HostBootstrap/Authority/FailedUp/Internal.hs"
                    , "src/HostBootstrap/Handoff/Completion.hs"
                    ]
            users "renderLifecycleAcknowledgement"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Protocol.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Handoff/Completion.hs"
                    ]
            forM_
                [ "renderForwardRefusedLifecycleReport"
                , "renderForwardFailedLifecycleReport"
                , "renderReverseRefusedLifecycleReport"
                ]
                $ \name -> users name @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs"]
            users "renderReverseFailedLifecycleReport"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    ]
            users "renderForwardFailedLifecycleReportWithObservations"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Handoff/TerminalReport.hs"
                    ]
            users "verifyLifecycleAcknowledgement"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    ]
            users "renderTeardownObservations"
                @?= [ "internal/handoff-implementation/HostBootstrap/Teardown.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Teardown/Executor/Internal.hs"
                    ]
            users "teardownObservationsFromWire"
                @?= [ "internal/handoff-implementation/HostBootstrap/Teardown.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Handoff/Completion.hs"
                    , "src/HostBootstrap/Teardown/Executor/Internal.hs"
                    ]
            assertBool
                "Teardown imports the public Handoff structural codec"
                (SourceGuard.importsModule "HostBootstrap.Handoff" teardownSource)
            assertBool
                "Handoff does not depend on Teardown"
                (not (SourceGuard.importsModule "HostBootstrap.Teardown" handoffSource))
            forM_ forbiddenEffects $ \identifier -> do
                assertBool
                    (identifier <> " is absent from the Handoff codec")
                    (not (identifier `isInfixOf` lifecycleSection))
                assertBool
                    (identifier <> " is absent from the Teardown codec")
                    (not (identifier `isInfixOf` teardownCodecSection))
            forM_ ["data ", "newtype ", "type Lifecycle"] $ \declaration ->
                assertBool
                    ("no named codec type declaration contains " <> show declaration)
                    (not (declaration `isInfixOf` lifecycleSection))
            assertContains
                "observation decoding canonically rerenders"
                "canonical <- renderLifecycleObservations rows"
                lifecycleSection
            assertContains
                "report decoding canonically rerenders"
                "canonical <- renderLifecycleReport branch status binding origin detail observations"
                lifecycleSection
            assertContains
                "acknowledgement verification canonically rerenders"
                "expected <- renderLifecycleAcknowledgement report"
                lifecycleSection
            assertBool
                "typed decoding cannot mint settlement"
                (not ("verifySubtreeSettled" `isInfixOf` teardownCodecSection))
            length (filter (== "HostBootstrap.Handoff") exposed) @?= 1
            length (filter (== "HostBootstrap.Teardown") exposed) @?= 1
            forM_
                [ "HostBootstrap.Handoff.Completion"
                ]
                $ \moduleName ->
                    assertBool
                        (moduleName <> " is registered exactly once and remains hidden")
                        ( moduleName `notElem` exposed
                            && length (filter (== moduleName) private) == 1
                        )
            forM_
                [ "HostBootstrap.Handoff.Completion.Testing"
                , "HostBootstrap.Handoff.Lifecycle.Testing"
                ]
                $ \moduleName ->
                    assertBool
                        (moduleName <> " is absent from Cabal")
                        (moduleName `notElem` registeredCabalModules cabalSource)
    ]

framesOf :: ByteString.ByteString -> IO [ByteString.ByteString]
framesOf = expectRight . frameFields

frameFields :: ByteString.ByteString -> Either HandoffError [ByteString.ByteString]
frameFields raw
    | ByteString.null raw = Right []
    | otherwise = do
        (field, rest) <- takeHandoffFrame raw
        (field :) <$> frameFields rest

renderFrameFields :: [ByteString.ByteString] -> ByteString.ByteString
renderFrameFields = ByteString.concat . map frameWire

wireWithFrames ::
    [(Int, ByteString.ByteString)] ->
    [ByteString.ByteString] ->
    ByteString.ByteString
wireWithFrames replacements fields =
    renderFrameFields
        [ maybe field id (lookup index replacements)
        | (index, field) <- zip [0 ..] fields
        ]

lifecycleWordBytesFor :: Word8 -> ByteString.ByteString
lifecycleWordBytesFor value = ByteString.replicate 7 0 <> ByteString.singleton value

foldLifecycleReport ::
    ByteString.ByteString ->
    Either
        HandoffError
        (String, ByteString.ByteString, ByteString.ByteString, ByteString.ByteString, Text.Text, Text.Text)
foldLifecycleReport raw =
    eliminateLifecycleReport
        raw
        (capture "forward-completed")
        (capture "forward-refused")
        (capture "forward-failed")
        (capture "reverse-completed")
        (capture "reverse-refused")
        (capture "reverse-failed")
  where
    capture branch binding origin observations detail verb =
        (branch, binding, origin, observations, detail, verb)

assertLifecycleRefusal :: (Show value) => String -> Either HandoffError value -> IO ()
assertLifecycleRefusal _ (Left _) = pure ()
assertLifecycleRefusal label (Right value) =
    assertFailure (label <> " was accepted: " <> show value)

assertNonterminalOrigin ::
    String ->
    ByteString.ByteString ->
    ByteString.ByteString ->
    IO ()
assertNonterminalOrigin branchStatus binding origin =
    case break (== '-') branchStatus of
        (branch, '-' : status) ->
            framesOf origin
                >>= ( @?=
                        [ "hostbootstrap/lifecycle-nonterminal-origin"
                        , lifecycleWordBytesFor 1
                        , ByteStringChar8.pack branch
                        , ByteStringChar8.pack status
                        , TextEncoding.encodeUtf8 (recoveryWireDigest binding)
                        ]
                    )
        _ -> assertFailure ("invalid branch/status fixture " <> branchStatus)

withForwardLifecycleFixture ::
    Word8 ->
    (ByteString.ByteString -> ByteString.ByteString -> IO ()) ->
    IO ()
withForwardLifecycleFixture seed use =
    withHandoff seed ProjectUp $ \broker -> do
        token <- freshHandoffToken
        binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
        let bindingBytes = renderHandoffBinding binding
        use bindingBytes (forwardLifecycleOrigin bindingBytes)

withReverseLifecycleFixture ::
    Word8 ->
    ProjectVerb verb ->
    (ByteString.ByteString -> ByteString.ByteString -> IO ()) ->
    IO ()
withReverseLifecycleFixture seed verb use =
    withHandoff seed verb $ \broker ->
        withRecoveryInput baseRecoveryCoordinates $ \input -> do
            token <- freshHandoffToken
            binding <-
                expectRight
                    (mkHandoffBinding broker (recoveryBindingInput input recoveryPayload) token)
            let bindingBytes = renderHandoffBinding binding
            use bindingBytes (reverseLifecycleOrigin binding)

forwardLifecycleOrigin :: ByteString.ByteString -> ByteString.ByteString
forwardLifecycleOrigin binding =
    renderFrameFields
        [ "forward-terminal-origin-v1"
        , binding
        , "invocation-1"
        , "1"
        , "2"
        , "3"
        , "up"
        , "execute"
        , "teardown"
        ]

reverseLifecycleOrigin ::
    HandoffBinding scope brokerGeneration ->
    ByteString.ByteString
reverseLifecycleOrigin binding =
    renderFrameFields
        [ "child-recovery-terminal-origin-v1"
        , "1"
        , renderHandoffBinding binding
        , encoded (handoffPlanRevision binding)
        , encoded (handoffPlanRevision binding)
        , "invocation-1"
        , "1"
        , "3"
        , encoded (handoffChildFrame binding)
        , ByteStringChar8.pack (show (handoffBrokerGeneration binding))
        , encoded (handoffVerb binding)
        , encoded (handoffVerb binding)
        , "teardown"
        , encoded (handoffChildFrame binding)
        , encoded (handoffVerb binding)
        , encoded (handoffChildConfigDigest binding)
        ]
  where
    encoded = TextEncoding.encodeUtf8

-- ---------------------------------------------------------------------------
-- Durable lifecycle acknowledgement substrate

lifecycleAcknowledgementSubstrateTests :: [TestTree]
lifecycleAcknowledgementSubstrateTests =
    [ testCase "all five lifecycle kernels force hidden admission at partial application" $ do
        let expectForced :: forall result. String -> result -> IO ()
            expectForced marker operation = do
                forced <- try @SomeException (evaluate operation)
                case forced of
                    Left failure ->
                        assertBool
                            ("the hidden capability was not forced for " <> marker)
                            (marker `contains` show failure)
                    Right _ -> assertFailure ("partial lifecycle kernel application accepted " <> marker)
        expectForced
            "publish lifecycle capability"
            (publishLifecycleReportKernel (error "publish lifecycle capability"))
        expectForced
            "receive lifecycle capability"
            (receiveLifecycleAcknowledgementKernel (error "receive lifecycle capability"))
        expectForced
            "prepare lifecycle capability"
            (prepareLifecycleAcknowledgementKernel (error "prepare lifecycle capability"))
        expectForced
            "adopt lifecycle capability"
            (adoptLifecycleAcknowledgementKernel (error "adopt lifecycle capability"))
        expectForced
            "rehydrate adopted lifecycle capability"
            (rehydrateAdoptedLifecycleAcknowledgementKernel (error "rehydrate adopted lifecycle capability"))
    , testCase "placement: the durable lifecycle row source keeps its exact, transcript-bound, convergent, callback-safe shape (behaviour: the store-backed row cases)" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            durableSource <-
                requiredSourceSection
                    "durable lifecycle acknowledgement substrate"
                    "-- Durable lifecycle acknowledgement"
                    "validateLifecycleReport ::"
                    handoffSource
            publishSource <-
                requiredSourceSection
                    "child report publication kernel"
                    "publishLifecycleReportKernel ::"
                    "receiveLifecycleAcknowledgementKernel ::"
                    durableSource
            receiveSource <-
                requiredSourceSection
                    "child acknowledgement receipt kernel"
                    "receiveLifecycleAcknowledgementKernel ::"
                    "prepareLifecycleAcknowledgementKernel ::"
                    durableSource
            prepareSource <-
                requiredSourceSection
                    "parent acknowledgement preparation kernel"
                    "prepareLifecycleAcknowledgementKernel ::"
                    "adoptLifecycleAcknowledgementKernel ::"
                    durableSource
            adoptSource <-
                requiredSourceSection
                    "parent acknowledgement adoption kernel"
                    "adoptLifecycleAcknowledgementKernel ::"
                    "lifecycleChildMaterial ::"
                    durableSource
            childMaterial <-
                requiredSourceSection
                    "child durable material"
                    "lifecycleChildMaterial ::"
                    "lifecycleParentMaterial ::"
                    durableSource
            parentMaterial <-
                requiredSourceSection
                    "parent durable material"
                    "lifecycleParentMaterial ::"
                    "lifecycleReportBinding ::"
                    durableSource
            grantValidation <-
                requiredSourceSection
                    "exact lifecycle grant validation"
                    "validateGrantedLifecycleOffer ::"
                    "prepareParentRow ::"
                    durableSource
            prepareRows <-
                requiredSourceSection
                    "parent prepare transition table"
                    "prepareParentRow ::"
                    "publishChildRow ::"
                    durableSource
            publishRows <-
                requiredSourceSection
                    "child publish transition table"
                    "publishChildRow ::"
                    "adoptParentRow ::"
                    durableSource
            adoptRows <-
                requiredSourceSection
                    "parent adopt transition table"
                    "adoptParentRow ::"
                    "writeLifecycleRow ::"
                    durableSource
            rowReadback <-
                requiredSourceSection
                    "central lifecycle row readback"
                    "writeLifecycleRow ::"
                    "inLifecycleEntry ::"
                    durableSource
            entrySource <-
                requiredSourceSection
                    "strict protected lifecycle entry"
                    "inLifecycleEntry ::"
                    "lifecycleRowConflict ::"
                    durableSource
            handoffExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            protectedImports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff does not explicitly import HostBootstrap.Protected")
                    pure
                    (SourceGuard.moduleImportTokens "HostBootstrap.Protected" handoffSource)
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            let kernels =
                    [ "publishLifecycleReportKernel"
                    , "receiveLifecycleAcknowledgementKernel"
                    , "prepareLifecycleAcknowledgementKernel"
                    , "adoptLifecycleAcknowledgementKernel"
                    ]
                exports = normalizedModuleExports handoffExports
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                namedDeclarations =
                    [ stripped
                    | sourceLine <- lines durableSource
                    , let stripped = dropWhile isSpace sourceLine
                    , "data " `isPrefixOf` stripped
                        || "newtype " `isPrefixOf` stripped
                        || "type " `isPrefixOf` stripped
                    ]
                durable = normalizeWhitespace durableSource
                publish = normalizeWhitespace publishSource
                receiveAck = normalizeWhitespace receiveSource
                prepare = normalizeWhitespace prepareSource
                adopt = normalizeWhitespace adoptSource
                child = normalizeWhitespace childMaterial
                parent = normalizeWhitespace parentMaterial
                granted = normalizeWhitespace grantValidation
                readback = normalizeWhitespace rowReadback
            namedDeclarations @?= []
            significantHaskellLineCount durableSource @?= 450
            length (filter (== "RecordKey") protectedImports) @?= 1
            traverse_
                ( \kernel -> do
                    length (filter (== kernel) exports) @?= 1
                    SourceGuard.countHaskellIdentifier kernel handoffSource @?= 4
                )
                kernels
            traverse_
                ( \kernel ->
                    users kernel
                        @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                            , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                            ]
                )
                [ "publishLifecycleReportKernel"
                , "receiveLifecycleAcknowledgementKernel"
                , "prepareLifecycleAcknowledgementKernel"
                , "adoptLifecycleAcknowledgementKernel"
                ]
            traverse_
                (\hidden -> assertBool (hidden <> " remains hidden") (hidden `notElem` exports))
                [ "RecoverySigningKernel"
                , "recoverySigningKernel"
                , "consumeRecoverySigningKernel"
                ]
            mapM_
                (\(label, fragment, body) -> assertContains label fragment body)
                [
                    ( "publish admission is first and strict"
                    , "publishLifecycleReportKernel kernel = case consumeRecoverySigningKernel kernel () of () -> \\store report"
                    , publish
                    )
                ,
                    ( "receive admission is first and strict"
                    , "receiveLifecycleAcknowledgementKernel kernel = case consumeRecoverySigningKernel kernel () of () -> \\store report acknowledgement"
                    , receiveAck
                    )
                ,
                    ( "prepare admission is first and strict"
                    , "prepareLifecycleAcknowledgementKernel kernel = case consumeRecoverySigningKernel kernel () of () -> \\broker offer challenge report acknowledgement pending alreadyAdopted"
                    , prepare
                    )
                ,
                    ( "adopt admission is first and strict"
                    , "adoptLifecycleAcknowledgementKernel kernel = case consumeRecoverySigningKernel kernel () of () -> \\broker offer challenge report acknowledgement fresh replay"
                    , adopt
                    )
                ,
                    ( "child report must name the exact store"
                    , "handoffStoreIdentity binding == protectedStoreIdentityText (protectedStoreIdentity store)"
                    , child
                    )
                ,
                    ( "child publication is binding-keyed"
                    , "lifecycleRecordKey \"child\" bindingBytes"
                    , child
                    )
                ,
                    ( "child publication is exact v1 Published"
                    , "lifecycleDurableRow \"child\" \"published\" bindingBytes report ByteString.empty"
                    , child
                    )
                ,
                    ( "child receipt is exact v2 Received"
                    , "lifecycleDurableRow \"child\" \"received\" bindingBytes report acknowledgement"
                    , child
                    )
                ,
                    ( "parent material revalidates the live broker"
                    , "brokerRelay broker binding"
                    , parent
                    )
                ,
                    ( "parent report joins the exact offer binding"
                    , "bindingBytes == renderHandoffBinding binding"
                    , parent
                    )
                ,
                    ( "parent offer payload joins its binding"
                    , "handoffChildConfigDigest binding == childConfigDigest (offerPayload offer)"
                    , parent
                    )
                ,
                    ( "parent offer token joins its binding"
                    , "handoffTokenCommitment binding == tokenCommitment (offerToken offer)"
                    , parent
                    )
                ,
                    ( "parent acknowledgement is canonical for the report"
                    , "verifyLifecycleAcknowledgement report acknowledgement"
                    , parent
                    )
                ,
                    ( "parent rows use a distinct binding key"
                    , "lifecycleRecordKey \"parent\" bindingBytes"
                    , parent
                    )
                ,
                    ( "the token row must be exactly v2"
                    , "recordVersionWord (protectedRecordVersion record) == 2"
                    , granted
                    )
                ,
                    ( "the complete granted transcript is byte-equal"
                    , "protectedRecordBytes record == grantedEdgeRecord (TextEncoding.encodeUtf8 (sha256Hex material))"
                    , granted
                    )
                ,
                    ( "the grant digest retains the exact root key, binding, token, and challenge"
                    , "material = signedMaterial (rootBrokerVerificationKey broker) binding (tokenFrame (offerToken offer)) challenge"
                    , granted
                    )
                ,
                    ( "durable rows are bounded before storage"
                    , "bounded \"lifecycle durable row\" raw"
                    , durable
                    )
                ,
                    ( "durable keys hash the complete canonical binding"
                    , "mkRecordKey (\"lifecycle-\" <> side <> \".\" <> recoveryWireDigest binding)"
                    , durable
                    )
                ,
                    ( "row equality includes version and bytes"
                    , "recordVersionWord (protectedRecordVersion record) == version && protectedRecordBytes record == bytes"
                    , readback
                    )
                ]
            assertBool
                "grant validation admits no prefix-only transcript"
                (not ("isPrefixOf" `isInfixOf` grantValidation))
            assertFragmentsInOrder
                "child receive validates the exact acknowledgement before store entry and v2 readback"
                [ "verifyLifecycleAcknowledgement report acknowledgement"
                , "lifecycleChildMaterial store report"
                , "inLifecycleEntry store"
                , "exactLifecycleRow 2 received record"
                , "exactLifecycleRow 1 published record"
                , "ExpectVersion (protectedRecordVersion record)"
                , "2 received"
                , "Right Nothing -> pure lifecycleRowConflict"
                ]
                receiveSource
            assertFragmentsInOrder
                "prepare authenticates under the live broker and store before post-guard delivery"
                [ "prepared <- withActiveRootBroker broker"
                , "lifecycleParentMaterial broker offer report acknowledgement"
                , "inLifecycleEntry (brokerProtectedStore broker)"
                , "validateGrantedLifecycleOffer session broker offer challenge"
                , "prepareParentRow session key reported acknowledged adopted"
                , "case prepared of"
                , "Right False -> Right <$> pending acknowledgement"
                , "Right True -> Right <$> alreadyAdopted acknowledgement"
                ]
                prepareSource
            assertFragmentsInOrder
                "adopt authenticates under the live broker and store before post-guard completion"
                [ "advanced <- withActiveRootBroker broker"
                , "lifecycleParentMaterial broker offer report acknowledgement"
                , "inLifecycleEntry (brokerProtectedStore broker)"
                , "validateGrantedLifecycleOffer session broker offer challenge"
                , "adoptParentRow session key acknowledged adopted"
                , "case advanced of"
                , "Right True -> Right <$> fresh"
                , "Right False -> Right <$> replay"
                ]
                adoptSource
            assertFragmentsInOrder
                "parent absence converges only through exact Reported, Acknowledged, or Adopted rows"
                [ "Right Nothing -> do"
                , "ExpectAbsent reported"
                , "exactLifecycleRow 1 reported record"
                , "exactLifecycleRow 2 acknowledged record"
                , "exactLifecycleRow 3 adopted record"
                , "advance = do"
                , "exactLifecycleRow 1 reported record"
                , "ExpectVersion (protectedRecordVersion record)"
                , "acknowledged"
                , "exactLifecycleRow 2 acknowledged row"
                , "exactLifecycleRow 3 adopted row"
                ]
                prepareRows
            assertFragmentsInOrder
                "child absence converges only on exact Published or Received"
                [ "ExpectAbsent published"
                , "exactLifecycleRow 1 published record"
                , "exactLifecycleRow 2 received record"
                , "lifecycleRowConflict"
                ]
                publishRows
            assertFragmentsInOrder
                "adoption distinguishes one exact v2 winner from exact v3 replay"
                [ "exactLifecycleRow 3 adopted record"
                , "Right False"
                , "exactLifecycleRow 2 acknowledged record"
                , "ExpectVersion (protectedRecordVersion record)"
                , "adopted"
                , "exactLifecycleRow 3 adopted row"
                , "recordVersionWord version == 3"
                , "Right True"
                , "Left _ -> Right False"
                ]
                adoptRows
            assertFragmentsInOrder
                "all protected classification is forced under entry and before the broker guard returns"
                [ "entered <- withProtectedEntry store"
                , "classified <- action session"
                , "Left failure -> failure `seq` pure (Right (Left failure))"
                , "Right result -> result `seq` pure (Right (Right result))"
                , "case entered of"
                , "Left failure -> failure `seq` pure (Left (HandoffStoreFailure failure))"
                , "Right result -> result `seq` pure result"
                ]
                entrySource
            SourceGuard.countHaskellIdentifier "RecoverySigningKernel" durableSource @?= 6
            SourceGuard.countHaskellIdentifier "consumeRecoverySigningKernel" durableSource @?= 6
            SourceGuard.countHaskellIdentifier "withActiveRootBroker" durableSource @?= 2
            SourceGuard.countHaskellIdentifier "withProtectedEntry" durableSource @?= 1
            SourceGuard.countHaskellIdentifier "readProtectedRecord" durableSource @?= 13
            SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" durableSource @?= 5
            SourceGuard.countHaskellIdentifier "ExpectAbsent" durableSource @?= 2
            SourceGuard.countHaskellIdentifier "ExpectVersion" durableSource @?= 3
            SourceGuard.countHaskellIdentifier "result" prepareSource @?= 0
            SourceGuard.countHaskellIdentifier "result" adoptSource @?= 0
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier durableSource @?= 0)
                [ "LifecycleCompletion"
                , "ProtocolMessage"
                , "channelSend"
                , "createProcess"
                , "waitForProcess"
                , "terminateProcess"
                , "ProcessHandle"
                , "timeout"
                , "spawn"
                , "reap"
                , "unsafeCoerce"
                ]
            assertBool
                "Handoff remains independent of its hidden protocol"
                (not (SourceGuard.importsModule "HostBootstrap.Handoff.Protocol" handoffSource))
            length (filter (== "HostBootstrap.Handoff.Protocol") private) @?= 1
            assertBool
                "the protocol remains hidden"
                ("HostBootstrap.Handoff.Protocol" `notElem` exposed)
            traverse_
                ( \seam ->
                    assertBool
                        (seam <> " is absent from Cabal")
                        (seam `notElem` registeredCabalModules cabalSource)
                )
                [ "HostBootstrap.Handoff.Acknowledgement.Testing"
                , "HostBootstrap.Handoff.Process.Testing"
                ]
    , testCase "protocol tags and one-outstanding-response state are closed, exact, redacted, and private" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            (protocolSource, _) <- (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Protocol")
            receiverSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            durableSource <-
                requiredSourceSection
                    "durable lifecycle acknowledgement attribution"
                    "-- Durable lifecycle acknowledgement"
                    "validateLifecycleReport ::"
                    handoffSource
            fieldCounts <-
                requiredSourceSection
                    "protocol field-count table"
                    "expectedFieldCount ::"
                    "encodeProtocolMessage ::"
                    protocolSource
            childState <-
                requiredSourceSection
                    "child acknowledgement state machine"
                    "data ChildProtocolState"
                    "{- | Structural and transport failures."
                    protocolSource
            protocolErrors <-
                requiredSourceSection
                    "protocol error table"
                    "data ProtocolError"
                    "frame :: ByteString"
                    protocolSource
            tagTable <-
                requiredSourceSection
                    "protocol tag-byte table"
                    "tagByte ::"
                    "word16BigEndian ::"
                    protocolSource
            handoffExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            protectedImports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff does not explicitly import HostBootstrap.Protected")
                    pure
                    (SourceGuard.moduleImportTokens "HostBootstrap.Protected" handoffSource)
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            let tags = ["AcknowledgedTag", "LifecycleAckRequestTag", "LifecycleAckResponseTag"]
                rootedTags = ["RootedLifecycleRequestTag", "RootedLifecycleResponseTag"]
                providerTags = ["ProviderDependencyPackageTag", "ProviderDependencyProbeRequestTag", "ProviderDependencyProbeResponseTag"]
                kernels =
                    [ "publishLifecycleReportKernel"
                    , "receiveLifecycleAcknowledgementKernel"
                    , "prepareLifecycleAcknowledgementKernel"
                    , "adoptLifecycleAcknowledgementKernel"
                    ]
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                namedDeclarations =
                    [ dropWhile isSpace sourceLine
                    | sourceLine <- lines protocolSource
                    , let stripped = dropWhile isSpace sourceLine
                    , "data " `isPrefixOf` stripped
                        || "newtype " `isPrefixOf` stripped
                        || "type " `isPrefixOf` stripped
                    ]
                fields = normalizeWhitespace fieldCounts
                state = normalizeWhitespace childState
                errors = normalizeWhitespace protocolErrors
                exports = normalizedModuleExports handoffExports
                handoffAttribution =
                    significantHaskellLineCount durableSource
                        - 29
                        - 71
                        + length (filter (`elem` exports) kernels)
                        + length (filter (== "RecordKey") protectedImports)
            namedDeclarations
                @?= [ "data ProtocolTag"
                    , "data ProtocolMessage = ProtocolMessage ProtocolTag Word64 [ByteString]"
                    , "data HandoffChannel = HandoffChannel"
                    , "data ChildProtocolState"
                    , "data ProtocolError"
                    ]
            mapM_
                (\fragment -> assertContains (fragment <> " is one-field") (fragment <> " -> 1") fields)
                (tags <> rootedTags <> providerTags)
            assertFragmentsInOrder
                "new tag bytes append after the existing recovery response"
                [ "RecoveryResponseTag -> 14"
                , "AcknowledgedTag -> 15"
                , "LifecycleAckRequestTag -> 16"
                , "LifecycleAckResponseTag -> 17"
                , "RootedLifecycleRequestTag -> 18"
                , "RootedLifecycleResponseTag -> 19"
                , "FrameTransactionTag -> 20"
                , "FrameOutcomeTag -> 21"
                , "ProviderDependencyPackageTag -> 22"
                , "ProviderDependencyProbeRequestTag -> 23"
                , "ProviderDependencyProbeResponseTag -> 24"
                , "14 -> Right RecoveryResponseTag"
                , "15 -> Right AcknowledgedTag"
                , "16 -> Right LifecycleAckRequestTag"
                , "17 -> Right LifecycleAckResponseTag"
                , "18 -> Right RootedLifecycleRequestTag"
                , "19 -> Right RootedLifecycleResponseTag"
                , "22 -> Right ProviderDependencyPackageTag"
                , "23 -> Right ProviderDependencyProbeRequestTag"
                , "24 -> Right ProviderDependencyProbeResponseTag"
                ]
                tagTable
            assertFragmentsInOrder
                "every admitted request records its one exact response before another request may start"
                [ "(ChildRunning expected, OfferRequestTag)"
                , "ChildAwaitingResponse expected OfferResponseTag"
                , "(ChildRunning expected, GrantRequestTag)"
                , "ChildAwaitingResponse expected GrantResponseTag"
                , "(ChildRunning expected, ActivationSignRequestTag)"
                , "ChildAwaitingResponse expected ActivationSignResponseTag"
                , "(ChildRunning expected, RecoveryRequestTag)"
                , "ChildAwaitingResponse expected RecoveryResponseTag"
                , "(ChildRunning expected, LifecycleAckRequestTag)"
                , "ChildAwaitingResponse expected LifecycleAckResponseTag"
                , "(ChildRunning expected, RootedLifecycleRequestTag)"
                , "ChildAwaitingResponse expected RootedLifecycleResponseTag"
                ]
                childState
            assertFragmentsInOrder
                "only the stored response tag and request id return an admitted child to running"
                [ "(ChildAwaitingResponse expected response, observed)"
                , "observed == response -> requireRequest expected requestId (ChildRunning expected)"
                , "(ChildAwaitingResponse expected _, RefusedTag)"
                , "requireRequest expected requestId ChildFinished"
                ]
                childState
            assertFragmentsInOrder
                "Completed derives and retains the exact acknowledgement before awaiting it"
                [ "(ChildRunning expected, CompletedTag) -> do"
                , "requireRequest expected requestId ()"
                , "[report] -> case renderLifecycleAcknowledgement report of"
                , "Left _ -> Left ProtocolLifecycleReportInvalid"
                , "Right acknowledgement -> Right (ChildAwaitingAcknowledgement expected acknowledgement)"
                ]
                childState
            assertFragmentsInOrder
                "only the exact direct acknowledgement and request identity finish the child"
                [ "(ChildAwaitingAcknowledgement expected acknowledgement, AcknowledgedTag)"
                , "requireAcknowledgement expected acknowledgement message"
                , "requireRequest expected (protocolMessageRequestId message) ()"
                , "[observed]"
                , "observed == acknowledgement -> Right ChildFinished"
                , "otherwise -> Left ProtocolAcknowledgementMismatch"
                ]
                childState
            assertContains
                "a local refusal can close the one outstanding response without exposing its fields"
                "ChildAwaitingResponse expected _ -> requireRequest expected actual successor"
                state
            assertContains
                "the expected response tag is redacted only to its closed constructor name"
                "ChildAwaitingResponse request response -> \"ChildAwaitingResponse \" ++ show request ++ \" \" ++ show response"
                state
            assertContains
                "the retained acknowledgement is redacted from Show"
                "ChildAwaitingAcknowledgement request _ -> \"ChildAwaitingAcknowledgement \" ++ show request ++ \" <exact>\""
                state
            assertContains
                "invalid report diagnostics are fixed and field-free"
                "ProtocolLifecycleReportInvalid -> \"handoff protocol: invalid lifecycle report\""
                errors
            SourceGuard.countHaskellTokenSequence
                ["ProtocolLifecycleReportInvalid", "String"]
                protocolSource
                @?= 0
            SourceGuard.countHaskellIdentifier "handoffErrorMessage" protocolSource @?= 0
            SourceGuard.countHaskellIdentifier "AcknowledgedTag" protocolSource @?= 6
            SourceGuard.countHaskellIdentifier "LifecycleAckRequestTag" protocolSource @?= 5
            SourceGuard.countHaskellIdentifier "LifecycleAckResponseTag" protocolSource @?= 5
            SourceGuard.countHaskellIdentifier "RootedLifecycleRequestTag" protocolSource @?= 5
            SourceGuard.countHaskellIdentifier "RootedLifecycleResponseTag" protocolSource @?= 5
            SourceGuard.countHaskellIdentifier "ChildAwaitingResponse" protocolSource @?= 11
            SourceGuard.countHaskellIdentifier "ChildAwaitingAcknowledgement" protocolSource @?= 6
            SourceGuard.countHaskellIdentifier "ProtocolLifecycleReportInvalid" protocolSource @?= 3
            SourceGuard.countHaskellIdentifier "ProtocolAcknowledgementMismatch" protocolSource @?= 3
            assertBool
                "Protocol depends on the public lifecycle codec"
                (SourceGuard.importsModule "HostBootstrap.Handoff" protocolSource)
            assertBool
                "Handoff has no Protocol dependency cycle"
                (not (SourceGuard.importsModule "HostBootstrap.Handoff.Protocol" handoffSource))
            users "AcknowledgedTag"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Protocol.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    ]
            mapM_
                ( \tag ->
                    users tag
                        @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Protocol.hs"
                            , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                            ]
                )
                ["LifecycleAckRequestTag", "LifecycleAckResponseTag"]
            mapM_
                ( \tag ->
                    users tag
                        @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Protocol.hs"
                            , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                            ]
                )
                rootedTags
            mapM_
                ( \kernel ->
                    users kernel
                        @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                            , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                            ]
                )
                [ "publishLifecycleReportKernel"
                , "receiveLifecycleAcknowledgementKernel"
                , "prepareLifecycleAcknowledgementKernel"
                , "adoptLifecycleAcknowledgementKernel"
                ]
            mapM_
                ( \identifier -> do
                    SourceGuard.countHaskellIdentifier identifier receiverSource @?= 0
                )
                (filter (/= "AcknowledgedTag") tags <> rootedTags <> kernels)
            SourceGuard.countHaskellIdentifier "AcknowledgedTag" receiverSource @?= 2
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier protocolSource @?= 0)
                [ "LifecycleCompletion"
                , "createProcess"
                , "waitForProcess"
                , "terminateProcess"
                , "ProcessHandle"
                , "timeout"
                , "spawn"
                , "reap"
                , "unsafeCoerce"
                ]
            length (filter (== "HostBootstrap.Handoff.Protocol") private) @?= 1
            assertBool
                "Protocol remains hidden from the public library"
                ("HostBootstrap.Handoff.Protocol" `notElem` exposed)
            traverse_
                ( \seam ->
                    assertBool
                        (seam <> " is absent from Cabal")
                        (seam `notElem` registeredCabalModules cabalSource)
                )
                [ "HostBootstrap.Handoff.Acknowledgement.Testing"
                , "HostBootstrap.Handoff.Protocol.Testing"
                , "HostBootstrap.Handoff.Process.Testing"
                ]
            -- Historical parent-acknowledgement landing (2026-08-11):
            -- Handoff 343, Protocol 71, total 414. The shared Protocol increment
            -- remains dated evidence, not a current whole-file size oracle.
            handoffAttribution @?= 355
            -- DEVELOPMENT_PLAN/rationale.md#handoff-freezes-cover-owned-declarations
            frozenHandoffDefinitionDigest ["requireAcknowledgement"] protocolSource
                >>= (@?= "116088b6fbcb48a1e31e920b6c8146362c6923fed4eec178e186f3ee28587b54")
    , testCase "Relay retains the frozen caller-free canonical routed-ack transport" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            protocolSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Protocol")
            receiverSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver")
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            brokerLinkSource <-
                requiredSourceSection
                    "the routed BrokerLink field"
                    "data BrokerLink scope brokerGeneration ="
                    "type role BrokerLink nominal nominal"
                    relaySource
            linkConstructionSource <-
                requiredSourceSection
                    "root and relayed acknowledgement link construction"
                    "rootBrokerLink ::"
                    "withConfigBrokerLink ::"
                    relaySource
            publicRouteSource <-
                requiredSourceSection
                    "the typed fixed-unit acknowledgement route"
                    "prepareLifecycleAcknowledgementThroughLink ::"
                    "signRecoveryThroughLink ::"
                    relaySource
            routedSource <-
                requiredSourceSection
                    "the canonical acknowledgement request and response route"
                    "-- Routed lifecycle acknowledgement"
                    "{- | Extract the three plan-owned coordinates"
                    relaySource
            rootRouteSource <-
                requiredSourceSection
                    "the root acknowledgement route"
                    "rootLifecycleAcknowledgement ::"
                    "flattenLifecycleKernel ::"
                    relaySource
            relayedRouteSource <-
                requiredSourceSection
                    "the relayed acknowledgement route"
                    "relayLifecycleAcknowledgement ::"
                    "exactLifecycleFrames ::"
                    relaySource
            requesterSource <-
                requiredSourceSection
                    "the sealed requester provenance checks"
                    "requesterEnvelopeDomain ::"
                    "requesterMismatch ::"
                    relaySource
            serveDispatchSource <-
                requiredSourceSection
                    "the admitted-child service dispatch"
                    "serveMessage ::"
                    "serveLifecycleAcknowledgement ::"
                    relaySource
            serveRouteSource <-
                requiredSourceSection
                    "the one-hop acknowledgement service"
                    "serveLifecycleAcknowledgement ::"
                    "serveOpen ::"
                    relaySource
            handoffExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            relayExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Relay has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Relay" relaySource)
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            let brokerLink = normalizeWhitespace brokerLinkSource
                publicRoute = normalizeWhitespace publicRouteSource
                routed = normalizeWhitespace routedSource
                requester = normalizeWhitespace requesterSource
                serveDispatch = normalizeWhitespace serveDispatchSource
                publicHandoff = normalizedModuleExports handoffExports
                privateRelay = normalizedModuleExports relayExports
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                namedRouteDeclarations =
                    [ stripped
                    | sourceLine <- lines routedSource
                    , let stripped = dropWhile isSpace sourceLine
                    , "data " `isPrefixOf` stripped
                        || "newtype " `isPrefixOf` stripped
                        || "type " `isPrefixOf` stripped
                    ]
            let brokerLinkWords = words brokerLink
            [ field
                | (field, following) <- zip brokerLinkWords (drop 1 brokerLinkWords)
                , following == "::"
                , "link" `isPrefixOf` field
                ]
                @?= [ "linkRoute"
                    , "linkAuthenticatedRootScope"
                    , "linkOpenRaw"
                    , "linkRecoverableOpenRaw"
                    , "linkGrantRaw"
                    , "linkSignActivationRaw"
                    , "linkRootedBindingRaw"
                    , "linkRecoveryFieldsRaw"
                    , "linkLifecycleAcknowledgementRaw"
                    , "linkRootedLifecycleRaw"
                    , "linkProviderDependencyRaw"
                    , "linkProviderDependencyPackage"
                    , "linkRejectResponse"
                    , "linkKeyDigest"
                    ]
            assertContains
                "BrokerLink carries only a fixed-unit raw acknowledgement continuation"
                "linkLifecycleAcknowledgementRaw :: RequesterPath -> ByteString -> (ByteString -> IO (Either RelayError ())) -> IO (Either RelayError ())"
                brokerLink
            assertContains
                "prepare routing has two stored-acknowledgement fixed-unit branches"
                "prepareLifecycleAcknowledgementThroughLink :: BrokerLink scope brokerGeneration -> HandoffOffer scope brokerGeneration -> HandoffChallenge -> ByteString -> ByteString -> (ByteString -> IO (Either RelayError ())) -> (ByteString -> IO (Either RelayError ())) -> IO (Either RelayError ())"
                publicRoute
            assertContains
                "adopt routing has fresh/replay fixed-unit branches"
                "adoptLifecycleAcknowledgementThroughLink :: BrokerLink scope brokerGeneration -> HandoffOffer scope brokerGeneration -> HandoffChallenge -> ByteString -> ByteString -> IO (Either RelayError ()) -> IO (Either RelayError ()) -> IO (Either RelayError ())"
                publicRoute
            SourceGuard.countHaskellIdentifier "result" publicRouteSource @?= 0
            namedRouteDeclarations @?= []
            assertFragmentsInOrder
                "requests have exactly seven bounded canonical frames"
                [ "boundedLifecycleField LifecycleAckRequestTag raw"
                , "fields <- exactLifecycleFrames 7 raw"
                , "[domain, version, stage, offerWire, challengeWire, report, acknowledgement]"
                , "domain == lifecycleAcknowledgementRequestDomain"
                , "version == lifecycleAcknowledgementVersion"
                , "requireLifecycleStage stage"
                , "adoptRelayedRequest route offerWire challengeWire"
                , "binding == renderHandoffBinding (handoffOfferBinding offer)"
                , "verifyLifecycleAcknowledgement report acknowledgement"
                , "canonical <- renderLifecycleAcknowledgementRequest stage offer challenge report acknowledgement"
                , "canonical == raw"
                ]
                routedSource
            assertContains
                "request rendering fixes domain, version, stage, offer, challenge, report, and acknowledgement"
                "[ lifecycleAcknowledgementRequestDomain , lifecycleAcknowledgementVersion , stage , offerWireOf offer , challengeBytes challenge , report , acknowledgement ]"
                routed
            assertFragmentsInOrder
                "responses have exactly five request-bound canonical frames"
                [ "boundedLifecycleField LifecycleAckResponseTag raw"
                , "fields <- exactLifecycleFrames 5 raw"
                , "[domain, version, stage, disposition, acknowledgement]"
                , "domain == lifecycleAcknowledgementResponseDomain"
                , "version == lifecycleAcknowledgementVersion"
                , "stage == expectedStage"
                , "acknowledgement == expectedAcknowledgement"
                , "disposition `elem` [firstDisposition, secondDisposition]"
                , "canonical <- renderLifecycleAcknowledgementResponse stage disposition report acknowledgement"
                , "canonical == raw"
                ]
                routedSource
            assertContains
                "response rendering fixes domain, version, stage, disposition, and acknowledgement"
                "[ lifecycleAcknowledgementResponseDomain , lifecycleAcknowledgementVersion , stage , disposition , acknowledgement ]"
                routed
            assertContains
                "each routed envelope remains one bounded Protocol field"
                "boundedLifecycleField tag raw = either (Left . RelayProtocolFailure) (const (Right ())) (protocolMessage tag 1 [raw])"
                routed
            assertContains
                "prepare admits only pending and already-adopted"
                "stage == lifecyclePrepareStage && disposition `elem` [lifecyclePending, lifecycleAlreadyAdopted]"
                routed
            assertContains
                "adopt admits only fresh and replay"
                "stage == lifecycleAdoptStage && disposition `elem` [lifecycleFresh, lifecycleReplay]"
                routed
            assertFragmentsInOrder
                "the root reconstructs against its root route and alone calls both durable kernels"
                [ "rootLifecycleAcknowledgement broker route raw respond = withLifecycleAcknowledgementRequest route raw prepare adopt"
                , "prepareLifecycleAcknowledgementKernel recoverySigningKernel broker offer challenge report acknowledgement"
                , "respondWith lifecyclePrepareStage lifecyclePending report"
                , "respondWith lifecyclePrepareStage lifecycleAlreadyAdopted report"
                , "adoptLifecycleAcknowledgementKernel recoverySigningKernel broker offer challenge report acknowledgement"
                , "respondWith lifecycleAdoptStage lifecycleFresh report acknowledgement"
                , "respondWith lifecycleAdoptStage lifecycleReplay report acknowledgement"
                , "renderLifecycleAcknowledgementResponse stage disposition report acknowledgement"
                , "Right response -> respond response"
                ]
                rootRouteSource
            SourceGuard.countHaskellIdentifier "prepareLifecycleAcknowledgementKernel" rootRouteSource @?= 1
            SourceGuard.countHaskellIdentifier "adoptLifecycleAcknowledgementKernel" rootRouteSource @?= 1
            assertFragmentsInOrder
                "the root link uses only rootBrokerRoute for lifecycle reconstruction"
                [ "linkLifecycleAcknowledgementRaw = \\_ request respond -> rootLifecycleAcknowledgement broker route request respond"
                , "route = rootBrokerRoute broker"
                ]
                linkConstructionSource
            assertFragmentsInOrder
                "a keyless link prefixes its authenticated current frame before relaying"
                [ "linkLifecycleAcknowledgementRaw = \\downstream lifecycleRequest respond -> mask $ \\restore -> whileReceivedEdgeOpen edge (relayLifecycleAcknowledgement edge (currentFrame : downstream) lifecycleRequest (restore . respond))"
                , "currentFrame = handoffChildFrame (verifiedHandoffBinding (receivedEdgeHandoff edge))"
                ]
                linkConstructionSource
            assertFragmentsInOrder
                "a relayed response is validated against its exact request before either callback"
                [ "renderRequesterEnvelope path raw"
                , "transmit channel LifecycleAckRequestTag request [enveloped]"
                , "awaitReceived edge LifecycleAckResponseTag"
                , "Right [response]"
                , "withLifecycleAcknowledgementResponse stage report acknowledgement response"
                , "firstDisposition (respond response)"
                , "secondDisposition (respond response)"
                ]
                relayedRouteSource
            assertContains
                "only an admitted serving child reaches acknowledgement routing"
                "(ParentServingAdmittedChild childFrame, LifecycleAckRequestTag) -> continueAfter childFrame (serveLifecycleAcknowledgement childFrame link channel request message)"
                serveDispatch
            assertFragmentsInOrder
                "serving parses one requester field, revalidates it, and forwards one response field"
                [ "[enveloped] -> case parseRequesterEnvelope enveloped of"
                , "Right (path, raw)"
                , "withLifecycleAcknowledgementRequest (linkRoute link) raw"
                , "requireServedRequester childFrame (handoffParentFrame (handoffOfferBinding offer)) path"
                , "linkLifecycleAcknowledgementRaw link path raw"
                , "transmit channel LifecycleAckResponseTag request [response]"
                ]
                serveRouteSource
            assertContains
                "serving requires the exact admitted child at the requester-path head"
                "case path of firstFrame : _ | firstFrame == childFrame -> Right ()"
                requester
            assertFragmentsInOrder
                "serving requires the requested parent at the requester-path origin tail"
                [ "requireServedProvenance childFrame path"
                , "case reverse path of"
                , "originFrame : _ | originFrame == requestedParent -> Right ()"
                ]
                requesterSource
            users "prepareLifecycleAcknowledgementKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    ]
            users "adoptLifecycleAcknowledgementKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    ]
            mapM_
                (\identifier -> users identifier @?= ["internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"])
                [ "prepareLifecycleAcknowledgementThroughLink"
                , "adoptLifecycleAcknowledgementThroughLink"
                , "linkLifecycleAcknowledgementRaw"
                , "rootLifecycleAcknowledgement"
                , "relayLifecycleAcknowledgement"
                , "serveLifecycleAcknowledgement"
                ]
            importers "HostBootstrap.Handoff.Relay"
                @?= ["src/HostBootstrap/Command/Child.hs", "src/HostBootstrap/Command/LifecycleEntry.hs", "src/HostBootstrap/Handoff/Process.hs"]
            mapM_
                ( \identifier -> do
                    assertBool (identifier <> " is exported only from hidden Relay") (identifier `elem` privateRelay)
                    assertBool (identifier <> " is absent from public Handoff") (identifier `notElem` publicHandoff)
                )
                [ "BrokerLink"
                , "prepareLifecycleAcknowledgementThroughLink"
                , "adoptLifecycleAcknowledgementThroughLink"
                ]
            assertBool
                "Relay stays Cabal-private and singly registered"
                ( "HostBootstrap.Handoff.Relay" `notElem` exposed
                    && length (filter (== "HostBootstrap.Handoff.Relay") private) == 1
                )
            assertBool
                "Relay keeps the one-way Handoff/Protocol/Receiver-internal DAG"
                ( SourceGuard.importsModule "HostBootstrap.Handoff" relaySource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Internal" relaySource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Protocol" relaySource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Receiver.Internal" relaySource
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Completion" relaySource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Lifecycle" relaySource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Receiver" relaySource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Relay" handoffSource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Relay" protocolSource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Relay" receiverSource)
                )
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier routedSource @?= 0)
                [ "LifecycleCompletion"
                , "AcknowledgedTag"
                , "publishLifecycleReportKernel"
                , "receiveLifecycleAcknowledgementKernel"
                , "withReceivedHandoffEdge"
                , "ProtectedStore"
                , "withProtectedEntry"
                , "MVar"
                , "newMVar"
                , "createProcess"
                , "waitForProcess"
                , "terminateProcess"
                , "ProcessHandle"
                , "signalProcess"
                , "interruptProcessGroupOf"
                , "getProcessExitCode"
                , "unsafeCoerce"
                ]
            traverse_
                ( \seam ->
                    assertBool
                        (seam <> " is absent from Cabal")
                        (seam `notElem` registeredCabalModules cabalSource)
                )
                [ "HostBootstrap.Handoff.Relay.Testing"
                , "HostBootstrap.Handoff.Acknowledgement.Testing"
                , "HostBootstrap.Handoff.Process.Testing"
                ]
            SourceGuard.countHaskellIdentifier "prepareLifecycleAcknowledgementThroughLink" publicRouteSource @?= 2
            SourceGuard.countHaskellIdentifier "adoptLifecycleAcknowledgementThroughLink" publicRouteSource @?= 2
            SourceGuard.countHaskellIdentifier "linkLifecycleAcknowledgementRaw" relaySource @?= 7
            SourceGuard.countHaskellIdentifier "rootLifecycleAcknowledgement" relaySource @?= 5
            SourceGuard.countHaskellIdentifier "relayLifecycleAcknowledgement" relaySource @?= 3
            SourceGuard.countHaskellIdentifier "exactLifecycleFrames" relaySource @?= 4
    , testCase "Relay owns terminal persistence and complete serve without a child-store receipt" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            protocolSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Protocol")
            receiverSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            ordinaryOfferSource <-
                requiredSourceSection
                    "the complete ordinary offer"
                    "offerHandoffEdge ::"
                    "{- | Recoverably bind one prepared reverse edge before signing or sending it."
                    relaySource
            reverseOfferSource <-
                requiredSourceSection
                    "the complete Bound reverse offer"
                    "offerReverseDescentKernel ::"
                    "{- | Build the fourth Offer field from the exact validated offer."
                    relaySource
            fullServeSource <-
                requiredSourceSection
                    "the complete parent serve"
                    "awaitChallenge ::"
                    "runLifecycleTerminal ::"
                    relaySource
            terminalSource <-
                requiredSourceSection
                    "the lexical terminal acknowledgement gate"
                    "runLifecycleTerminal ::"
                    "serveLifecycleAcknowledgement ::"
                    relaySource
            failureSource <-
                requiredSourceSection
                    "the fixed Relay failure vocabulary"
                    "refusalCode ::"
                    "fromHandoff ::"
                    relaySource
            handoffExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            relayExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Relay has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Relay" relaySource)
            protectedImports <-
                maybe
                    (assertFailure "Relay has no exact Protected import")
                    pure
                    (SourceGuard.moduleImportTokens "HostBootstrap.Protected" relaySource)
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            let reverseOffer = normalizeWhitespace reverseOfferSource
                terminal = normalizeWhitespace terminalSource
                failures = normalizeWhitespace failureSource
                publicHandoff = normalizedModuleExports handoffExports
                privateRelay = normalizedModuleExports relayExports
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                namedDeclarations =
                    [ stripped
                    | sourceLine <- lines relaySource
                    , let stripped = dropWhile isSpace sourceLine
                    , "data " `isPrefixOf` stripped
                        || "newtype " `isPrefixOf` stripped
                        || ("type " `isPrefixOf` stripped && not ("type role " `isPrefixOf` stripped))
                    ]
            SourceGuard.countHaskellTokenSequence
                [ "offerHandoffEdge"
                , "::"
                , "BrokerLink"
                , "scope"
                , "brokerGeneration"
                , "->"
                , "HandoffChannel"
                , "->"
                , "Word64"
                , "->"
                , "HandoffBindingInput"
                , "->"
                , "ByteString"
                , "->"
                , "("
                , "HandoffOffer"
                , "scope"
                , "brokerGeneration"
                , "->"
                , "ByteString"
                , "->"
                , "("
                , "ByteString"
                , "->"
                , "ByteString"
                , "->"
                , "IO"
                , "("
                , "Either"
                , "Text"
                , "("
                , ")"
                , ")"
                , ")"
                , "->"
                , "IO"
                , "("
                , "Either"
                , "Text"
                , "("
                , ")"
                , ")"
                , ")"
                , "->"
                , "IO"
                , "("
                , "Either"
                , "RelayError"
                , "("
                , ")"
                , ")"
                ]
                ordinaryOfferSource
                @?= 1
            assertContains
                "reverse offer retains its closed Bound-descent signature"
                "offerReverseDescentKernel :: BrokerLink scope brokerGeneration -> HandoffChannel -> Word64 -> ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId -> ( ReverseDescent (HandoffOffer scope brokerGeneration) scope planId parentFrame childFrame brokerGeneration verb descentId -> ByteString -> (ByteString -> ByteString -> IO (Either Text ())) -> IO (Either Text ()) ) -> IO (Either RelayError ())"
                reverseOffer
            mapM_
                (\section -> SourceGuard.countHaskellIdentifier "result" section @?= 0)
                [ ordinaryOfferSource
                , reverseOfferSource
                , terminalSource
                ]
            assertFragmentsInOrder
                "ordinary serve retains the exact offer and terminal callback through completion"
                [ "offerHandoffEdge link channel request input payload terminal"
                , "opened <- openEdgeThroughLink link input"
                , "Right offer -> do authenticated <- offerAuthentication link offer"
                , "transmit channel OfferTag request (offerFieldsOf offer authentication)"
                , "Right () -> awaitChallenge link channel request offer (terminal offer)"
                ]
                ordinaryOfferSource
            assertFragmentsInOrder
                "reverse serve binds durably, opens recoverably, then authenticates and transmits the package"
                [ "offerReverseDescentKernel link channel request descent terminal = do"
                , "bound <- withBoundReverseDescentKernel recoverySigningKernel descent open serve"
                , "refuse channel request (RelayRecoveryNotPlanned (Text.pack (teardownErrorMessage failure)))"
                , "open input package = case requireOfferPayloadBound package of"
                , "opened <- openRecoverableEdgeThroughLink link input package"
                , "Right (relay, token) -> case mkHandoffOffer relay package token of"
                , "serve bound offer = do authenticated <- offerAuthentication link offer"
                , "transmit channel OfferTag request (offerFieldsOf offer authentication)"
                , "Right () -> awaitChallenge link channel request offer (terminal bound)"
                ]
                reverseOfferSource
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier reverseOfferSource @?= 0)
                [ "linkRecoverableOpenRaw"
                , "RootBroker"
                , "ProtectedStore"
                , "renderRecoveryChildPackageKernel"
                , "recoveryChildPackageKernel"
                ]
            assertFragmentsInOrder
                "Challenge, Grant, Accepted, recursive service, and Completed retain offer and challenge"
                [ "awaitChallenge link channel request offer terminal"
                , "handoffChallengeFromBytes raw"
                , "grantThroughLink link offer challenge"
                , "transmit channel GrantTag request [grantSignature grant, linkKeyDigest link]"
                , "serveUntilDone ( ParentAwaitingAcceptance"
                , "offer challenge terminal"
                , "(ParentAwaitingAcceptance expectedDigest childFrame, AcceptedTag)"
                , "serveUntilDone (ParentServingAdmittedChild childFrame) link channel request offer challenge terminal"
                , "(ParentServingAdmittedChild _, CompletedTag)"
                , "[report] -> runLifecycleTerminal link channel request offer challenge report terminal"
                ]
                fullServeSource
            assertFragmentsInOrder
                "the terminal gate is unnamed, masked, one-shot, and always signals an entrant"
                [ "Right acknowledgement -> mask $ \\restore -> do"
                , "gate <- newMVar (False, False, False, Nothing :: Maybe Bool)"
                , "completed <- newEmptyMVar"
                , "persist observedReport observedAcknowledgement = mask $ \\restorePersist -> do"
                , "modifyMVar gate $ \\state@(closed, entered, attempted, fresh) ->"
                , "if closed || entered"
                , "else pure ((closed, True, attempted, fresh), True)"
                , "restorePersist (persistClaim observedReport observedAcknowledgement) `finally` putMVar completed ()"
                ]
                terminalSource
            assertFragmentsInOrder
                "closing seals late entry before waiting for the one in-flight call"
                [ "closeGate retained = do"
                , "modifyMVar gate $ \\(_, wasEntered, attempted, fresh) -> pure ((True, wasEntered, attempted, fresh), wasEntered)"
                , "Left failure -> closeGate (retainException retained failure)"
                , "Right entered -> if entered then waitForCompletion retained else pure retained"
                , "waited <- try (takeMVar completed)"
                , "Left failure -> waitForCompletion (retainException retained failure)"
                , "retainException retained failure = case retained of"
                , "Nothing -> Just failure"
                , "existing -> existing"
                ]
                terminalSource
            assertFragmentsInOrder
                "persist requires the callback's same report and canonical acknowledgement before prepare"
                [ "observedReport /= report || observedAcknowledgement /= acknowledgement"
                , "prepareLifecycleAcknowledgementThroughLink link offer challenge report acknowledgement pending alreadyAdopted"
                , "readMVar gate"
                , "Just True -> Right ()"
                , "Just False -> fixedReplay"
                ]
                terminalSource
            assertContains
                "pending durably adopts before sending the acknowledgement and publishes its disposition only after the send"
                "pending storedAcknowledgement = do adoptedStage <- newMVar (Nothing :: Maybe Bool) let keep fresh = modifyMVar_ adoptedStage (\\_ -> pure (Just fresh)) >> pure (Right ()) adopted <- adoptLifecycleAcknowledgementThroughLink link offer challenge report acknowledgement (keep True) (keep False) case adopted of Left _ -> pure (Left RelayLifecycleAdoptionFailure) Right () -> sendAcknowledgement storedAcknowledgement $ do kept <- readMVar adoptedStage maybe (pure (Right ())) recordDisposition kept"
                terminal
            assertContains
                "already-Adopted records acknowledgement-only replay"
                "alreadyAdopted storedAcknowledgement = sendAcknowledgement storedAcknowledgement (recordDisposition False)"
                terminal
            assertFragmentsInOrder
                "acknowledgement attempt is marked before direct child I/O"
                [ "sendAcknowledgement storedAcknowledgement after"
                , "storedAcknowledgement /= acknowledgement"
                , "modifyMVar_ gate $ \\(closed, entered, _, fresh) -> pure (closed, entered, True, fresh)"
                , "sent <- transmit channel AcknowledgedTag request [acknowledgement]"
                , "Right () -> after"
                ]
                terminalSource
            assertFragmentsInOrder
                "Fresh alone permits terminal callback success while replay and already-Adopted are acknowledgement-only"
                [ "recordDisposition fresh = do"
                , "Just fresh"
                , "(Right _, Just False) -> pure (Right ())"
                , "(Right (Right ()), Just True) -> pure (Right ())"
                , "(Right (Left reason), Just True) -> pure (Left (RelayLifecycleCallbackRefused reason))"
                ]
                terminalSource
            assertContains
                "post-attempt failure is local and only a pre-ack failure refuses"
                "fixedResult attempted = if attempted then pure (Left RelayLifecycleCallbackAfterAcknowledgement) else refuse channel request RelayLifecycleCallbackBeforeAcknowledgement"
                terminal
            assertFragmentsInOrder
                "callback exceptions are classified before an async exit is rethrown"
                [ "callbackResult <- try ( restore"
                , "terminalResult <- terminal report persist"
                , "Left reason -> pure (Left reason)"
                , "Right value -> evaluate value >> pure (Right ())"
                , "closeException <- closeGate Nothing"
                , "acknowledgementAttempted, disposition"
                , "classified <- case (callbackResult, disposition) of"
                , "deferredAsync callbackResult closeException"
                , "Just failure -> throwIO failure"
                ]
                terminalSource
            assertFragmentsInOrder
                "terminal report canonicality and binding precede acknowledgement derivation"
                [ "binding <- lifecycleReportBinding report"
                , "binding == renderHandoffBinding (handoffOfferBinding offer)"
                , "fromHandoff (renderLifecycleAcknowledgement report)"
                ]
                terminalSource
            assertContains
                "only asynchronous callback exceptions are deferred for rethrow"
                "fromException failure :: Maybe SomeAsyncException"
                terminal
            SourceGuard.countHaskellIdentifier "reason" terminalSource @?= 4
            SourceGuard.countHaskellIdentifier "refuse" terminalSource @?= 2
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier terminalSource @?= 0)
                [ "isInfixOf"
                , "relayErrorMessage"
                , "TextEncoding"
                , "Text.unpack"
                ]
            assertContains
                "Relay lifecycle failures carry no hostile text"
                "RelayLifecycleAdoptionFailure -> \"handoff relay: lifecycle acknowledgement failed at durable acknowledgement adoption\""
                failures
            SourceGuard.countHaskellTokenSequence ["RelayLifecycleAdoptionFailure", "Text"] failureSource @?= 0
            SourceGuard.countHaskellTokenSequence ["RelayLifecycleAdoptionFailure", "String"] failureSource @?= 0
            namedDeclarations
                @?= [ "type EdgeAdmission = HandoffBindingInput -> IO (Either Text ())"
                    , "type RecoveryAdmission ="
                    , "type RequesterPath = [Text]"
                    , "type RootedLifecycleService ="
                    , "data BrokerLink scope brokerGeneration = BrokerLink"
                    , "data ParentRelayState"
                    , "data RelayError"
                    ]
            protectedImports @?= ["ProtectedStore"]
            assertBool
                "Relay keeps the intended hidden DAG with explicit store ownership"
                ( SourceGuard.importsModule "HostBootstrap.Handoff" relaySource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Internal" relaySource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Protocol" relaySource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Receiver.Internal" relaySource
                    && SourceGuard.importsModule "HostBootstrap.Protected" relaySource
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Completion" relaySource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Lifecycle" relaySource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Receiver" relaySource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Process" relaySource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Relay" handoffSource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Relay" protocolSource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Relay" receiverSource)
                )
            mapM_
                ( \identifier ->
                    users identifier
                        @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                            , "src/HostBootstrap/Handoff/Process.hs"
                            ]
                )
                [ "offerHandoffEdge"
                , "offerReverseDescentKernel"
                ]
            mapM_
                (\identifier -> users identifier @?= ["internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"])
                [ "prepareLifecycleAcknowledgementThroughLink"
                , "adoptLifecycleAcknowledgementThroughLink"
                , "runLifecycleTerminal"
                ]
            importers "HostBootstrap.Handoff.Relay"
                @?= ["src/HostBootstrap/Command/Child.hs", "src/HostBootstrap/Command/LifecycleEntry.hs", "src/HostBootstrap/Handoff/Process.hs"]
            mapM_
                ( \identifier -> do
                    assertBool (identifier <> " is exported only from hidden Relay") (identifier `elem` privateRelay)
                    assertBool (identifier <> " is absent from public Handoff") (identifier `notElem` publicHandoff)
                )
                [ "BrokerLink"
                , "offerHandoffEdge"
                , "offerReverseDescentKernel"
                ]
            assertBool
                "Relay stays Cabal-private without a new module row"
                ( "HostBootstrap.Handoff.Relay" `notElem` exposed
                    && length (filter (== "HostBootstrap.Handoff.Relay") private) == 1
                )
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier relaySource @?= 0)
                [ "LifecycleCompletion"
                , "withAcknowledgedForwardLifecycleCompletionKernel"
                , "withAcknowledgedBoundReverseLifecycleCompletionKernel"
                , "withRehydratedAcknowledgedReverseLifecycleCompletionKernel"
                , "withReceivedHandoffEdge"
                , "ReceiverExpectation"
                , "withProtectedEntry"
                , "readProtectedRecord"
                , "compareAndSwapProtectedRecord"
                , "createProcess"
                , "waitForProcess"
                , "terminateProcess"
                , "ProcessHandle"
                , "signalProcess"
                , "interruptProcessGroupOf"
                , "getProcessExitCode"
                , "stdioHandoffChannel"
                , "handoffChannel"
                , "unsafeCoerce"
                ]
            traverse_
                ( \seam ->
                    assertBool
                        (seam <> " is absent from Cabal")
                        (seam `notElem` registeredCabalModules cabalSource)
                )
                [ "HostBootstrap.Handoff.Relay.Testing"
                , "HostBootstrap.Handoff.Acknowledgement.Testing"
                , "HostBootstrap.Handoff.Process.Testing"
                ]
            SourceGuard.countHaskellIdentifier "prepareLifecycleAcknowledgementThroughLink" relaySource @?= 4
            SourceGuard.countHaskellIdentifier "adoptLifecycleAcknowledgementThroughLink" relaySource @?= 4
            SourceGuard.countHaskellIdentifier "publishLifecycleReportKernel" relaySource @?= 3
            SourceGuard.countHaskellIdentifier "receiveLifecycleAcknowledgementKernel" relaySource @?= 3
            SourceGuard.countHaskellIdentifier "withReceivedLifecycleAcknowledgementKernel" relaySource @?= 0
            SourceGuard.countHaskellIdentifier "withReceivedRecoveryLifecycleAcknowledgementKernel" relaySource @?= 0
            SourceGuard.countHaskellIdentifier "receiveLifecycleAcknowledgementForEdge" relaySource @?= 0
            SourceGuard.countHaskellIdentifier "runLifecycleTerminal" relaySource @?= 3
            SourceGuard.countHaskellIdentifier "AcknowledgedTag" relaySource @?= 2
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier terminalSource @?= 1)
                [ "RelayLifecycleInvalidReport"
                , "RelayLifecycleAdoptionFailure"
                , "RelayLifecycleStoredMismatch"
                , "RelayLifecycleTransmissionFailure"
                , "RelayLifecycleCallbackBeforeAcknowledgement"
                , "RelayLifecycleCallbackAfterAcknowledgement"
                ]
            -- Measured from the live source, so the figure follows the module and cannot drift as a constant.
            significantHaskellLineCount relaySource @?= 2728
    ]

-- ---------------------------------------------------------------------------
-- Sealed facade and private signing ownership

sealedFacadeTests :: [TestTree]
sealedFacadeTests =
    [ testCase "handoff implementation has one private owner and selected test imports" $
        withHandoffPackageRoot $ \packageRoot -> do
            description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            main <- maybe (assertFailure "the main library stanza is absent") pure (mainLibraryStanza description)
            implementation <- maybe (assertFailure "the handoff implementation stanza is absent") pure $
                SourceGuard.namedStanza "library handoff-implementation-internal" description
            testsSource <- maybe (assertFailure "the core-test stanza is absent") pure $
                SourceGuard.namedStanza "test-suite hostbootstrap-core-test" description
            owners <- either assertFailure pure (SourceGuard.mainImplementationOwners description)
            let registered = handoffImplementationPublicModules <> handoffTestModules
                    <> handoffImplementationMainOnlyModules <> handoffImplementationOtherModules
                unit = "hostbootstrap-core:handoff-implementation-internal"
            SourceGuard.fieldValues "hs-source-dirs" main @?= ["src", "internal/cluster-backend"]
            SourceGuard.fieldValues "visibility" implementation @?= ["private"]
            SourceGuard.fieldValues "hs-source-dirs" implementation @?= ["internal/handoff-implementation"]
            sort (fieldModules "exposed-modules" implementation)
                @?= sort (handoffImplementationPublicModules <> handoffTestModules <> handoffImplementationMainOnlyModules)
            sort (fieldModules "other-modules" implementation) @?= sort handoffImplementationOtherModules
            forM_ registered $ \moduleName -> do
                filter ((== moduleName) . fst) owners @?= [(moduleName, "library handoff-implementation-internal")]
                assertBool (moduleName <> " remains a Main home module") $
                    moduleName `notElem` (fieldModules "exposed-modules" main <> fieldModules "other-modules" main)
            sort (filter (`elem` registered) (fieldModules "reexported-modules" main))
                @?= sort handoffImplementationPublicModules
            length (filter (== unit) (SourceGuard.fieldValues "build-depends" main)) @?= 1
            length (filter (== unit) (SourceGuard.fieldValues "build-depends" testsSource)) @?= 1
            SourceGuard.fieldValues "mixins" testsSource
                @?= [unit, "(", "HostBootstrap.Lifecycle.Dependency.Internal", "as", "TestDependency"] <> handoffTestModules <> [")"]
            SourceGuard.fieldValues "hs-source-dirs" testsSource @?= ["test"]
    , testCase "Cabal exposes only the handoff facade and selects five private test owners" $
        withHandoffPackageRoot $ \packageRoot -> do
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            specSource <- readFile (packageRoot </> "test" </> "Spec.hs")
            testSources <- readHaskellSources (packageRoot </> "test")
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            let hiddenHandoffModules =
                    [ "HostBootstrap.Handoff.Completion"
                    , "HostBootstrap.Handoff.Internal"
                    , "HostBootstrap.Handoff.Protocol"
                    , "HostBootstrap.Handoff.Receiver"
                    , "HostBootstrap.Handoff.Receiver.Internal"
                    , "HostBootstrap.Handoff.Recovery"
                    , "HostBootstrap.Handoff.Relay"
                    , "HostBootstrap.Handoff.Rooted"
                    ]
                runtimeTestImporters moduleName =
                    sort
                        [ sourcePath (packageRoot </> "test") path
                        | (path, source) <- testSources
                        , '/' `notElem` sourcePath (packageRoot </> "test") path
                        , SourceGuard.importsModule moduleName source
                        ]
            -- The handoff *machinery* is sealed; the frame-child entry is not
            -- machinery but an entry, and `runCLI` — a public entry — routes to
            -- it. It is also the only module in this family a process that is
            -- not this library's own `main` has to be able to reach, because
            -- the far side of a crossing is reached by launching a binary. Its
            -- public surface grants nothing `HostBootstrap.Lift` and
            -- `HostBootstrap.CLI` do not already grant.
            sort (filter ("HostBootstrap.Handoff" `isPrefixOf`) exposed)
                @?= ["HostBootstrap.Handoff", "HostBootstrap.Handoff.Transaction"]
            traverse_
                (\moduleName -> assertBool (moduleName <> " is hidden") (moduleName `notElem` exposed))
                hiddenHandoffModules
            traverse_
                (\moduleName -> assertBool (moduleName <> " is registered privately") (moduleName `elem` private))
                hiddenHandoffModules
            testsSource <- maybe (assertFailure "the core-test stanza is absent") pure $
                SourceGuard.namedStanza "test-suite hostbootstrap-core-test" cabalSource
            let testModules = "Spec" : fieldModules "other-modules" testsSource
            forM_ hiddenHandoffModules $ \moduleName ->
                if moduleName `elem` handoffTestModules
                    then forM_ (runtimeTestImporters moduleName) $ \path ->
                        assertBool (path <> " is not a registered core-test source") $
                            takeWhile (/= '.') path `elem` testModules
                    else runtimeTestImporters moduleName @?= []
            runtimeTestImporters "HostBootstrap.Handoff.Rooted" @?= ["HandoffSpec.hs"]
            traverse_
                ( \formerSpec -> do
                    assertBool
                        (formerSpec <> " is deregistered from Cabal")
                        (not (formerSpec `isInfixOf` cabalSource))
                    assertBool
                        (formerSpec <> " is absent from the test runner")
                        (not (formerSpec `isInfixOf` specSource))
                )
                [ "HandoffProtocolSpec"
                , "HandoffReceiverSpec"
                , "HandoffRelaySpec"
                ]
            traverse_
                ( \formerProbe ->
                    assertBool
                        (formerProbe <> " dispatch is absent from the test runner")
                        (not (formerProbe `isInfixOf` specSource))
                )
                [ "--hostbootstrap-handoff-receiver-probe"
                , "--hostbootstrap-handoff-relay-probe"
                ]
    , testCase "the selected Rooted codec shares the facade's genuinely signed payload identity" $
        withHandoff 73 ProjectUp $ \broker -> do
            (binding, offer) <- newOffer broker childPayload
            signed <- signRootedPayloadBindingKernel HandoffInternal.recoverySigningKernel broker offer childPayload >>= expectRight
            let exactWire = renderRootedPayloadBinding signed
            -- Both renderers accept the other owner's opaque value directly;
            -- neither identity crosses a copied implementation or raw adapter.
            Rooted.renderRootedPayloadBindingKernel signed @?= exactWire
            decoded <- expectRight (Rooted.rootedPayloadBindingFromWireKernel exactWire)
            renderRootedPayloadBinding decoded @?= exactWire
            Rooted.rootedPayloadBindingEdgeKernel decoded @?= renderHandoffBinding binding
            Rooted.payloadDigestText (Rooted.rootedPayloadDigestKernel decoded) @?= rootedPayloadDigest signed
            Rooted.childConfigDigestText (Rooted.rootedChildConfigDigestKernel decoded) @?= rootedChildConfigDigest signed
            verified <- verifyOfferedHandoff broker binding offer
            withVerifiedRootedPayloadBinding verified (Rooted.renderRootedPayloadBindingKernel decoded)
                Rooted.renderRootedPayloadBindingKernel @?= Right exactWire
    , testCase "the checked payload digest refuses malformed text and eliminates exact canonical data" $ do
        let malformed =
                [ Text.empty
                , Text.replicate 63 "a"
                , Text.replicate 65 "a"
                , Text.replicate 64 "A"
                , Text.replicate 63 "a" <> "g"
                ]
        forM_ malformed $ \raw ->
            Rooted.mkPayloadDigest raw @?= Left "payload digest is not canonical lowercase SHA-256"
        forM_ [Text.replicate 64 "0", Text.replicate 64 "f", childConfigDigest childPayload] $ \raw -> do
            checked <- expectRight (Rooted.mkPayloadDigest raw)
            Rooted.payloadDigestText checked @?= raw
    , testCase "the checked child config digest refuses malformed text and eliminates exact canonical data" $ do
        let malformed =
                [ Text.empty
                , Text.replicate 63 "a"
                , Text.replicate 65 "a"
                , Text.replicate 64 "A"
                , Text.replicate 63 "a" <> "g"
                ]
        forM_ malformed $ \raw ->
            Rooted.mkChildConfigDigest raw @?= Left "child config digest is not canonical lowercase SHA-256"
        forM_ [Text.replicate 64 "0", Text.replicate 64 "f", childConfigDigest childPayload] $ \raw -> do
            checked <- expectRight (Rooted.mkChildConfigDigest raw)
            Rooted.childConfigDigestText checked @?= raw
    , testCase "the checked request digest refuses malformed text and eliminates exact canonical data" $ do
        let malformed =
                [ Text.empty
                , Text.replicate 63 "a"
                , Text.replicate 65 "a"
                , Text.replicate 64 "A"
                , Text.replicate 63 "a" <> "g"
                ]
        forM_ malformed $ \raw ->
            Rooted.mkRequestDigest raw @?= Left "rooted lifecycle request digest is not canonical lowercase SHA-256"
        forM_ [Text.replicate 64 "0", Text.replicate 64 "f", childConfigDigest childPayload] $ \raw -> do
            checked <- expectRight (Rooted.mkRequestDigest raw)
            Rooted.requestDigestText checked @?= raw
    , testCase "the checked lifecycle session enforces the UTF-8 byte bound and eliminates exact text" $ do
        let invalid =
                [ (Text.empty, 0, "has an empty response session")
                , (Text.replicate 4097 "a", 4097, "has an oversized response session")
                , (Text.replicate 2048 "\x03bb" <> "a", 4097, "has an oversized response session")
                , (Text.replicate 1025 "\x1f642", 4100, "has an oversized response session")
                ]
            valid =
                [ (Text.replicate 4096 "a", 4096)
                , (Text.replicate 2048 "\x03bb", 4096)
                , (Text.replicate 1024 "\x1f642", 4096)
                , ("session-\x03bb-\x1f642", 15)
                ]
        forM_ invalid $ \(raw, expectedBytes, detail) -> do
            ByteString.length (TextEncoding.encodeUtf8 raw) @?= expectedBytes
            Rooted.mkLifecycleSession raw @?= Left detail
        forM_ valid $ \(raw, expectedBytes) -> do
            ByteString.length (TextEncoding.encodeUtf8 raw) @?= expectedBytes
            checked <- expectRight (Rooted.mkLifecycleSession raw)
            Rooted.lifecycleSessionText checked @?= raw
    , testCase "the checked lifecycle stage enforces the UTF-8 byte bound and eliminates exact text" $ do
        let invalid =
                [ (Text.empty, 0, "has an empty response stage")
                , (Text.replicate 4097 "a", 4097, "has an oversized response stage")
                , (Text.replicate 2048 "\x03bb" <> "a", 4097, "has an oversized response stage")
                , (Text.replicate 1025 "\x1f642", 4100, "has an oversized response stage")
                ]
            valid =
                [ (Text.replicate 4096 "a", 4096)
                , (Text.replicate 2048 "\x03bb", 4096)
                , (Text.replicate 1024 "\x1f642", 4096)
                , ("session-\x03bb-\x1f642", 15)
                ]
        forM_ invalid $ \(raw, expectedBytes, detail) -> do
            ByteString.length (TextEncoding.encodeUtf8 raw) @?= expectedBytes
            Rooted.mkLifecycleStage raw @?= Left detail
        forM_ valid $ \(raw, expectedBytes) -> do
            ByteString.length (TextEncoding.encodeUtf8 raw) @?= expectedBytes
            checked <- expectRight (Rooted.mkLifecycleStage raw)
            Rooted.lifecycleStageText checked @?= raw
    , testCase "the checked lifecycle ordinal rejects zero and retains nonzero Word64 values and wraparound" $ do
        Rooted.mkLifecycleOrdinal 0 @?= Left "has a zero response ordinal"
        let maximumOrdinal = maxBound :: Word64
            wrappedOrdinal = maximumOrdinal + 1
        forM_ [1, maximumOrdinal] $ \raw -> do
            checked <- expectRight (Rooted.mkLifecycleOrdinal raw)
            Rooted.lifecycleOrdinalWord64 checked @?= raw
        wrappedOrdinal @?= 0
        Rooted.mkLifecycleOrdinal wrappedOrdinal @?= Left "has a zero response ordinal"
    , testCase "the checked receipt predecessor digest refuses malformed text and eliminates exact canonical data" $ do
        let malformed =
                [ Text.empty
                , Text.replicate 63 "a"
                , Text.replicate 65 "a"
                , Text.replicate 64 "A"
                , Text.replicate 63 "a" <> "g"
                ]
        forM_ malformed $ \raw ->
            Rooted.mkPredecessorDigest raw @?= Left "completed response digest is not canonical lowercase SHA-256"
        forM_ [Text.replicate 64 "0", Text.replicate 64 "f", childConfigDigest childPayload] $ \raw -> do
            checked <- expectRight (Rooted.mkPredecessorDigest raw)
            Rooted.predecessorDigestText checked @?= raw
    , testCase "all six typed post-open response builders retain canonical bytes and exact request pairing" $ do
        let session = "session-45"
            stage = "response-stage"
        checkedSession <- expectRight (Rooted.mkLifecycleSession session)
        checkedStage <- expectRight (Rooted.mkLifecycleStage stage)
        checkedOrdinal <- expectRight (Rooted.mkLifecycleOrdinal 2)
        let path = ["root", "child"]
            nonce = ByteString.replicate 32 45
            predecessor = childConfigDigest "previous signed response DATA"
            completion = childConfigDigest "matching frame-complete response DATA"
            request variant body =
                rootedLifecyclePostRequest variant path session "request-stage" 1 nonce predecessor body
            nextRequest = request "next-node" Nothing
            settleRequest = request "settle-node" (Just "settlement DATA")
            closeRequest = request "close-frame" Nothing
            receiptRequest =
                rootedLifecyclePostRequest "receipt-confirm" path session "request-stage" 1 nonce completion Nothing
            preparedBody = renderFrameFields ["node DATA", "dependencies DATA", "operation gate DATA", "projected gates DATA"]
            completeBody = "frame-complete DATA"
            signature = ByteString.replicate 64 0
            cases =
                [ ( "prepared", nextRequest, preparedBody
                  , \digest -> Rooted.rootedPreparedResponseUnsignedKernel digest path checkedSession checkedStage checkedOrdinal nonce "node DATA" "dependencies DATA" "operation gate DATA" "projected gates DATA"
                  , Nothing
                  )
                , ( "descend", nextRequest, "descent DATA"
                  , \digest -> Rooted.rootedDescendResponseUnsignedKernel digest path checkedSession checkedStage checkedOrdinal nonce "descent DATA"
                  , Nothing
                  )
                , ( "settled", settleRequest, "settled DATA"
                  , \digest -> Rooted.rootedSettledResponseUnsignedKernel digest path checkedSession checkedStage checkedOrdinal nonce "settled DATA"
                  , Nothing
                  )
                , ( "frame-complete", closeRequest, completeBody
                  , \digest -> Rooted.rootedFrameCompleteResponseUnsignedKernel digest path checkedSession checkedStage checkedOrdinal nonce completeBody
                  , Just completeBody
                  )
                , ( "receipt-recorded", receiptRequest, TextEncoding.encodeUtf8 completion
                  , \digest -> do
                        checkedPredecessor <- Rooted.mkPredecessorDigest completion
                        Rooted.rootedReceiptRecordedResponseUnsignedKernel digest path checkedSession checkedStage checkedOrdinal nonce checkedPredecessor
                  , Nothing
                  )
                , ( "refused", nextRequest, "refusal DATA"
                  , \digest -> Rooted.rootedRefusedResponseUnsignedKernel digest path checkedSession checkedStage checkedOrdinal nonce "refusal DATA"
                  , Nothing
                  )
                ]
        forM_ cases $ \(variant, exactRequest, body, build, pairedBody) -> do
            digest <- expectRight (Rooted.mkRequestDigest (childConfigDigest exactRequest))
            unsigned <- expectRight (build digest)
            let expected = rootedLifecyclePostUnsigned variant exactRequest path session stage 2 nonce body
                exactWire = expected <> renderFrameFields [signature]
            assertEqual (show variant <> " retains the independent canonical bytes") expected unsigned
            -- The placeholder signature is descriptive codec DATA; existing
            -- seven-family public verifier cases retain the cryptographic proof.
            response <- expectRight (Rooted.rootedLifecycleResponseFromUnsignedKernel unsigned signature)
            Rooted.renderRootedLifecycleUnsignedResponseKernel response @?= expected
            Rooted.renderRootedLifecycleResponseKernel response @?= exactWire
            decoded <- expectRight (Rooted.rootedLifecycleResponseFromWireKernel exactWire)
            Rooted.renderRootedLifecycleResponseKernel decoded @?= exactWire
            requestValue <- expectRight (Rooted.rootedLifecycleRequestFromWireKernel exactRequest)
            Rooted.rootedLifecycleUnsignedResponsePairKernel (childConfigDigest exactRequest) requestValue unsigned @?= Right pairedBody
            Rooted.rootedLifecycleResponsePairKernel (childConfigDigest exactRequest) requestValue decoded @?= Right pairedBody
    , testCase "the rooted request response and framing owners retain their measured declarations" $
        withHandoffPackageRoot $ \packageRoot -> do
            bytes <- ByteString.readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Rooted"
            source <- either (assertFailure . show) (pure . Text.unpack) (TextEncoding.decodeUtf8' bytes)
            frozenRootedPreservationDigests source >>= (@?=
                [ ("closed shapes and payload roles", "2f669c249c2291c98b4ce57e0b307479b2be669834e823d60b7683f22b19ae42")
                , ("request declarations", "5460d05bf207b1fe47943a2eed3cd7c54ebfdaee39e29fc143316ee4c43c70ae")
                , ("response framing and descriptions", "48fbcb826f5bae7f727276a3950e05679bda7fd9892250e00dd634e1cbdd9b6f")
                , ("shared framing and constants", "50411bdbff15a847d7550bd78b189104ca05fadd593467a7039e237889a2cf11")
                ])
    , testCase "rooted payload ownership is neutral, nominal, hidden, acyclic, and exactly attributed" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            rootedSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Rooted")
            rootedPayloadSource <-
                requiredSourceSection
                    "historical rooted payload codec"
                    "-- | One root-signed complete-payload and child-config identity."
                    "-- Rooted lifecycle request"
                    rootedSource
            handoffSpecSource <- readFile (packageRoot </> "test" </> "HandoffSpec.hs")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            rootedFacade <-
                requiredSourceSection
                    "rooted payload facade"
                    "-- Rooted payload binding"
                    "-- Canonical recovery child package"
                    handoffSource
            rootedExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Rooted has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Rooted" rootedSource)
            handoffExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            let rooted = normalizeWhitespace rootedSource
                publicHandoff = normalizedModuleExports handoffExports
                importers moduleName =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
            normalizedModuleExports rootedExports
                @?= [ "PayloadDigest"
                    , "mkPayloadDigest"
                    , "payloadDigestText"
                    , "ChildConfigDigest"
                    , "mkChildConfigDigest"
                    , "childConfigDigestText"
                    , "RequestDigest"
                    , "mkRequestDigest"
                    , "requestDigestText"
                    , "LifecycleSession"
                    , "mkLifecycleSession"
                    , "lifecycleSessionText"
                    , "LifecycleStage"
                    , "mkLifecycleStage"
                    , "lifecycleStageText"
                    , "LifecycleOrdinal"
                    , "mkLifecycleOrdinal"
                    , "lifecycleOrdinalWord64"
                    , "PredecessorDigest"
                    , "mkPredecessorDigest"
                    , "predecessorDigestText"
                    , "RootedPayloadBinding"
                    , "rootedPayloadBindingKernel"
                    , "rootedPayloadBindingFromWireKernel"
                    , "rootedPayloadBindingEdgeKernel"
                    , "rootedPayloadDigestKernel"
                    , "rootedChildConfigDigestKernel"
                    , "rootedPayloadSignatureKernel"
                    , "renderRootedPayloadBindingKernel"
                    , "renderRootedPayloadUnsignedKernel"
                    , "renderRootedPayloadUnsignedPartsKernel"
                    , "RootedLifecycleRequest"
                    , "rootedOpenFrameRequestKernel"
                    , "rootedNextNodeRequestKernel"
                    , "rootedSettleNodeRequestKernel"
                    , "rootedDescendResultRequestKernel"
                    , "rootedCloseFrameRequestKernel"
                    , "rootedReceiptConfirmRequestKernel"
                    , "rootedLifecycleRequestFromWireKernel"
                    , "renderRootedLifecycleRequestKernel"
                    , "withRootedLifecycleRequestKernel"
                    , "RootedLifecycleResponse"
                    , "rootedOpenedResponseUnsignedKernel"
                    , "rootedPreparedResponseUnsignedKernel"
                    , "rootedDescendResponseUnsignedKernel"
                    , "rootedSettledResponseUnsignedKernel"
                    , "rootedFrameCompleteResponseUnsignedKernel"
                    , "rootedReceiptRecordedResponseUnsignedKernel"
                    , "rootedRefusedResponseUnsignedKernel"
                    , "rootedLifecycleResponseFromUnsignedKernel"
                    , "rootedLifecycleResponseFromWireKernel"
                    , "rootedLifecycleResponseSignatureKernel"
                    , "renderRootedLifecycleResponseKernel"
                    , "renderRootedLifecycleUnsignedResponseKernel"
                    , "rootedLifecycleResponsePairKernel"
                    , "rootedLifecycleUnsignedResponsePairKernel"
                    , "withRootedLifecycleResponseKernel"
                    ]
            mapM_
                (\identifier -> assertBool (identifier <> " is exposed only through the facade") (identifier `elem` publicHandoff))
                [ "RootedPayloadBinding"
                , "rootedPayloadDigest"
                , "rootedChildConfigDigest"
                , "renderRootedPayloadBinding"
                , "signRootedPayloadBindingKernel"
                , "withVerifiedRootedPayloadBinding"
                ]
            assertBool
                "the rooted constructor remains absent from the public facade"
                ("RootedPayloadBinding(..)" `notElem` publicHandoff)
            assertContains
                "the rooted binding has exactly two nominal authority roles"
                "data RootedPayloadBinding scope brokerGeneration = RootedPayloadBinding ByteString PayloadDigest ChildConfigDigest ByteString type role RootedPayloadBinding nominal nominal"
                rooted
            forM_ ["PayloadDigest", "mkPayloadDigest", "payloadDigestText"] $ \identifier ->
                assertBool (identifier <> " stays outside the public facade") (identifier `notElem` publicHandoff)
            forM_ ["ChildConfigDigest", "mkChildConfigDigest", "childConfigDigestText"] $ \identifier ->
                assertBool (identifier <> " stays outside the public facade") (identifier `notElem` publicHandoff)
            forM_ ["RequestDigest", "mkRequestDigest", "requestDigestText"] $ \identifier ->
                assertBool (identifier <> " stays outside the public facade") (identifier `notElem` publicHandoff)
            forM_ ["LifecycleSession", "mkLifecycleSession", "lifecycleSessionText"] $ \identifier ->
                assertBool (identifier <> " stays outside the public facade") (identifier `notElem` publicHandoff)
            forM_ ["LifecycleStage", "mkLifecycleStage", "lifecycleStageText"] $ \identifier ->
                assertBool (identifier <> " stays outside the public facade") (identifier `notElem` publicHandoff)
            forM_ ["LifecycleOrdinal", "mkLifecycleOrdinal", "lifecycleOrdinalWord64"] $ \identifier ->
                assertBool (identifier <> " stays outside the public facade") (identifier `notElem` publicHandoff)
            forM_ ["PredecessorDigest", "mkPredecessorDigest", "predecessorDigestText"] $ \identifier ->
                assertBool (identifier <> " stays outside the public facade") (identifier `notElem` publicHandoff)
            SourceGuard.countHaskellTokenSequence ["newtype", "PayloadDigest"] rootedSource @?= 1
            SourceGuard.countHaskellTokenSequence ["type", "role", "PayloadDigest"] rootedSource @?= 0
            assertFragmentsInOrder
                "the private payload scalar has one validating factory and a total description"
                [ "newtype PayloadDigest = PayloadDigest Text"
                , "deriving (Eq, Show)"
                , "mkPayloadDigest :: Text -> Either Text PayloadDigest"
                , "mkPayloadDigest digest = do"
                , "requireDigest \"payload\" digest"
                , "pure (PayloadDigest digest)"
                , "payloadDigestText :: PayloadDigest -> Text"
                , "payloadDigestText (PayloadDigest digest) = digest"
                ] rootedSource
            SourceGuard.countHaskellTokenSequence ["newtype", "ChildConfigDigest"] rootedSource @?= 1
            SourceGuard.countHaskellTokenSequence ["type", "role", "ChildConfigDigest"] rootedSource @?= 0
            assertFragmentsInOrder
                "the private child config scalar has one validating factory and a total description"
                [ "newtype ChildConfigDigest = ChildConfigDigest Text"
                , "deriving (Eq, Show)"
                , "mkChildConfigDigest :: Text -> Either Text ChildConfigDigest"
                , "mkChildConfigDigest digest = do"
                , "requireDigest \"child config\" digest"
                , "pure (ChildConfigDigest digest)"
                , "childConfigDigestText :: ChildConfigDigest -> Text"
                , "childConfigDigestText (ChildConfigDigest digest) = digest"
                ] rootedSource
            SourceGuard.countHaskellTokenSequence ["data", "RootedPayloadBinding"] rootedPayloadSource @?= 1
            SourceGuard.countHaskellIdentifier "data" rootedPayloadSource @?= 1
            SourceGuard.countHaskellIdentifier "newtype" rootedPayloadSource @?= 0
            SourceGuard.countHaskellIdentifier "RootedPayloadBinding" rootedSource @?= 17
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier rootedSource @?= 4)
                [ "rootedPayloadBindingKernel"
                , "rootedPayloadBindingEdgeKernel"
                , "rootedPayloadDigestKernel"
                , "rootedChildConfigDigestKernel"
                , "rootedPayloadSignatureKernel"
                , "renderRootedPayloadBindingKernel"
                , "renderRootedPayloadUnsignedKernel"
                , "renderRootedPayloadUnsignedPartsKernel"
                ]
            SourceGuard.countHaskellIdentifier "rootedPayloadBindingFromWireKernel" rootedSource @?= 3
            assertFragmentsInOrder
                "the unsigned rooted binding has one fixed domain/version and exact edge/payload/config order"
                [ "rootedPayloadDomain = \"hostbootstrap/rooted-payload-binding\""
                , "rootedPayloadVersion = ByteString.pack [0, 0, 0, 0, 0, 0, 0, 1]"
                , "rootedPayloadSignatureBytes = 64"
                , "renderRootedPayloadUnsignedParts edge payloadDigest childConfigDigest = ByteString.concat"
                , "rootedFrame rootedPayloadDomain"
                , "rootedFrame rootedPayloadVersion"
                , "rootedFrame edge"
                , "rootedFrame (TextEncoding.encodeUtf8 (payloadDigestText payloadDigest))"
                , "rootedFrame (TextEncoding.encodeUtf8 (childConfigDigestText childConfigDigest))"
                ]
                rootedSource
            assertFragmentsInOrder
                "the complete rooted decoder consumes exactly six canonical fields"
                [ "fromIntegral (ByteString.length raw) <= rootedFieldLimit"
                , "\"is larger than the bounded authentication field\""
                , "(domain, afterDomain) <- takeRootedFrame raw"
                , "(version, afterVersion) <- takeRootedFrame afterDomain"
                , "(edge, afterEdge) <- takeRootedFrame afterVersion"
                , "(payloadBytes, afterPayload) <- takeRootedFrame afterEdge"
                , "(configBytes, afterConfig) <- takeRootedFrame afterPayload"
                , "(signature, trailing) <- takeRootedFrame afterConfig"
                , "require (ByteString.null trailing) \"has trailing bytes\""
                , "require (domain == rootedPayloadDomain) \"has the wrong domain\""
                , "require (version == rootedPayloadVersion) \"has the wrong version\""
                , "payloadDigest <- decodeDigest \"payload\" payloadBytes >>= mkPayloadDigest"
                , "childConfigDigest <- decodeDigest \"child config\" configBytes >>= mkChildConfigDigest"
                , "require (renderRootedPayloadBindingKernel binding == raw) \"is not canonical\""
                ]
                rootedSource
            assertFragmentsInOrder
                "construction bounds the edge and complete authentication field before rendering"
                [ "not (ByteString.null edge)"
                , "fromIntegral (ByteString.length edge) <= rootedFieldLimit"
                , "\"has an oversized edge binding\""
                , "let unsigned = renderRootedPayloadUnsignedParts edge payloadDigest childConfigDigest"
                , "ByteString.length unsigned + 8 + rootedPayloadSignatureBytes"
                , "<= rootedFieldLimit"
                , "\"is larger than the bounded authentication field\""
                ]
                rootedSource
            assertFragmentsInOrder
                "the shared frame reader refuses oversized declarations before splitting a body"
                [ "ByteString.length raw < 8"
                , "declared > rootedFieldLimit"
                , "\"contains an oversized field\""
                , "ByteString.splitAt (fromIntegral declared) body"
                ]
                rootedSource
            assertContains
                "both rooted digests are exact lowercase SHA-256 text"
                "Text.length digest == 64 && Text.all isLowerHex digest"
                rooted
            assertFragmentsInOrder
                "the live facade forces admission and invokes exact config validation before fixed-domain signing"
                [ "signRootedPayloadBindingKernel kernel = kernel `seq` consumeRecoverySigningKernel kernel sign"
                , "withActiveRootBroker broker"
                , "case validateRootedConfigSigning broker offer childConfig of"
                , "rootedUnsigned edge payloadDigest configDigest"
                , "Ed25519.sign"
                , "rootedPayloadSignedMaterial (rootBrokerVerificationKey broker) unsigned"
                ]
                rootedFacade
            assertFragmentsInOrder
                "config signing validation fixes broker, kind, nonempty bytes, equality, and the immediate digest"
                [ "validateRootedConfigSigning broker offer childConfig = do"
                , "_ <- brokerRelay broker binding"
                , "handoffPayloadKind binding == NarrowedProjectConfig"
                , "not (ByteString.null payload)"
                , "not (ByteString.null childConfig)"
                , "payload == childConfig"
                , "handoffChildConfigDigest binding == payloadDigest"
                ]
                rootedFacade
            assertFragmentsInOrder
                "verification first fixes the ordinary edge and both exact digest relations"
                [ "rooted <- rootedFailure (Rooted.rootedPayloadBindingFromWireKernel raw)"
                , "binding = verifiedHandoffBinding verified"
                , "payloadDigest = childConfigDigest (verifiedHandoffPayload verified)"
                , "Rooted.rootedPayloadBindingEdgeKernel rooted == renderHandoffBinding binding"
                , "claimedPayloadDigest == handoffChildConfigDigest binding"
                , "claimedPayloadDigest /= payloadDigest"
                , "NarrowedProjectConfig -> requireRooted (claimedConfigDigest == claimedPayloadDigest)"
                , "RecoveryAdapterWire -> requireRooted (claimedConfigDigest /= claimedPayloadDigest)"
                , "verifyRootedPayloadSignature (verifiedProjectKey verified) rooted"
                ]
                rootedFacade
            assertFragmentsInOrder
                "the rooted signature has one facade-owned domain and installed-key digest"
                [ "rootedPayloadBindingDomain = \"hostbootstrap/rooted-payload-binding/v1\""
                , "rootedPayloadSignedMaterial key unsigned = frameWire rootedPayloadBindingDomain"
                , "frameWire (TextEncoding.encodeUtf8 (verificationKeyDigest key))"
                , "frameWire unsigned"
                ]
                rootedFacade
            assertBool
                "the signing admission is opaque and forced before the live broker"
                ( "{-# OPAQUE signRootedPayloadBindingKernel #-}" `isInfixOf` rootedFacade
                    && SourceGuard.countHaskellIdentifier "RecoverySigningKernel" rootedFacade == 1
                    && SourceGuard.countHaskellIdentifier "consumeRecoverySigningKernel" rootedFacade == 1
                )
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier rootedSource @?= 0)
                [ "Ed25519"
                , "ProjectVerificationKey"
                , "RootBroker"
                , "HandoffBinding"
                , "HandoffError"
                , "ProtectedStore"
                , "ProtectedSession"
                , "compareAndSwapProtectedRecord"
                , "withProtectedEntry"
                , "IO"
                , "unsafeCoerce"
                ]
            mapM_
                ( \moduleName ->
                    assertBool
                        ("the neutral rooted codec imports no authority/effect owner " <> moduleName)
                        (not (SourceGuard.importsModule moduleName rootedSource))
                )
                [ "Crypto.PubKey.Ed25519"
                , "HostBootstrap.Authority"
                , "HostBootstrap.Chain"
                , "HostBootstrap.Command"
                , "HostBootstrap.Handoff"
                , "HostBootstrap.Handoff.Internal"
                , "HostBootstrap.Protected"
                , "System.IO"
                , "System.Process"
                ]
            importers "HostBootstrap.Handoff.Rooted"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "src/HostBootstrap/Lifecycle/Rooted/Node.hs"
                    ]
            users "RootedPayloadBinding"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs"
                    ]
            users "signRootedPayloadBindingKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "withVerifiedRootedPayloadBinding"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"]
            cryptoSources <- concat <$> traverse (readHaskellSources . (packageRoot </>)) ["src", "internal", "app"]
            sort
                [ sourcePath packageRoot path
                | (path, source) <- cryptoSources
                , SourceGuard.importsModule "Crypto.PubKey.Ed25519" source
                ]
                @?= [ "internal/handoff-implementation/HostBootstrap/Activation.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "src/HostBootstrap/Build.hs"
                    ]
            assertBool "the facade imports its neutral rooted codec without moving crypto into it"
                (SourceGuard.importsModule "HostBootstrap.Handoff.Rooted" handoffSource
                    && SourceGuard.countHaskellIdentifier "Ed25519" rootedSource == 0)
            length (filter (== "HostBootstrap.Handoff.Rooted") private) @?= 1
            assertBool
                "the rooted codec remains hidden from every exposed library surface"
                ("HostBootstrap.Handoff.Rooted" `notElem` exposed)
            sort (filter ("HostBootstrap.Handoff." `isPrefixOf`) (SourceGuard.haskellImports handoffSpecSource))
                @?= sort (handoffTestModules <> ["HostBootstrap.Handoff.Transaction"])
            traverse_
                ( \seam ->
                    assertBool
                        (seam <> " is absent from Cabal")
                        (seam `notElem` registeredCabalModules cabalSource)
                )
                [ "HostBootstrap.Handoff.Rooted.Testing"
                , "HostBootstrap.Handoff.Rooted.Internal"
                ]
    , testCase "rooted lifecycle requests have one opaque closed six-variant shape and fold" $
        withHandoffPackageRoot $ \packageRoot -> do
            rootedSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Rooted")
            rootedExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Rooted has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Rooted" rootedSource)
            let rooted = normalizeWhitespace rootedSource
                exports = normalizedModuleExports rootedExports
                constructors =
                    [ "OpenFrame"
                    , "NextNode"
                    , "SettleNode"
                    , "DescendResult"
                    , "CloseFrame"
                    , "ReceiptConfirm"
                    ]
                builders =
                    [ "rootedOpenFrameRequestKernel"
                    , "rootedNextNodeRequestKernel"
                    , "rootedSettleNodeRequestKernel"
                    , "rootedDescendResultRequestKernel"
                    , "rootedCloseFrameRequestKernel"
                    , "rootedReceiptConfirmRequestKernel"
                    ]
            assertContains
                "the non-indexed request is exactly the closed six-variant carrier"
                "data RootedLifecycleRequest = OpenFrame ByteString | NextNode [Text] Text Text Word64 ByteString Text | SettleNode [Text] Text Text Word64 ByteString Text ByteString | DescendResult [Text] Text Text Word64 ByteString Text ByteString | CloseFrame [Text] Text Text Word64 ByteString Text | ReceiptConfirm [Text] Text Text Word64 ByteString Text"
                rooted
            SourceGuard.countHaskellTokenSequence ["data", "RootedLifecycleRequest"] rootedSource @?= 1
            SourceGuard.countHaskellTokenSequence ["newtype", "RootedLifecycleRequest"] rootedSource @?= 0
            SourceGuard.countHaskellIdentifier "RootedLifecycleRequest" rootedSource @?= 24
            mapM_
                (\constructor -> SourceGuard.countHaskellIdentifier constructor rootedSource @?= 5)
                constructors
            mapM_
                (\builder -> SourceGuard.countHaskellIdentifier builder rootedSource @?= 4)
                builders
            assertBool
                "only the opaque request name and checked operations are exported"
                ( "RootedLifecycleRequest" `elem` exports
                    && "RootedLifecycleRequest(..)" `notElem` exports
                    && all (`elem` exports) builders
                    && all (`notElem` exports) constructors
                )
            assertFragmentsInOrder
                "OpenFrame alone has only a nonce while every post-open builder fixes path, session, stage, ordinal, nonce, and predecessor"
                [ "rootedOpenFrameRequestKernel :: ByteString -> Either Text RootedLifecycleRequest"
                , "rootedOpenFrameRequestKernel nonce = do requireLifecycleNonce nonce boundedLifecycleRequest (OpenFrame nonce)"
                , "rootedNextNodeRequestKernel :: [Text] -> Text -> Text -> Word64 -> ByteString -> Text -> Either Text RootedLifecycleRequest"
                , "rootedNextNodeRequestKernel = rootedPostOpenRequest NextNode"
                , "rootedSettleNodeRequestKernel :: [Text] -> Text -> Text -> Word64 -> ByteString -> Text -> ByteString -> Either Text RootedLifecycleRequest"
                , "rootedSettleNodeRequestKernel = rootedPostOpenBodyRequest SettleNode"
                , "rootedDescendResultRequestKernel = rootedPostOpenBodyRequest DescendResult"
                , "rootedCloseFrameRequestKernel = rootedPostOpenRequest CloseFrame"
                , "rootedReceiptConfirmRequestKernel = rootedPostOpenRequest ReceiptConfirm"
                ]
                rootedSource
            assertFragmentsInOrder
                "the sole eliminator has six fixed callbacks and exhaustively preserves every field"
                [ "withRootedLifecycleRequestKernel :: RootedLifecycleRequest -> (ByteString -> result)"
                , "([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> result)"
                , "([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> ByteString -> result)"
                , "([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> ByteString -> result)"
                , "([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> result)"
                , "([Text] -> Text -> Text -> Word64 -> ByteString -> Text -> result)"
                , "withRootedLifecycleRequestKernel request onOpen onNext onSettle onDescend onClose onReceipt = case request of"
                , "OpenFrame nonce -> onOpen nonce"
                , "NextNode path session stage ordinal nonce predecessor -> onNext path session stage ordinal nonce predecessor"
                , "SettleNode path session stage ordinal nonce predecessor body -> onSettle path session stage ordinal nonce predecessor body"
                , "DescendResult path session stage ordinal nonce predecessor body -> onDescend path session stage ordinal nonce predecessor body"
                , "CloseFrame path session stage ordinal nonce predecessor -> onClose path session stage ordinal nonce predecessor"
                , "ReceiptConfirm path session stage ordinal nonce predecessor -> onReceipt path session stage ordinal nonce predecessor"
                ]
                rootedSource
            SourceGuard.countHaskellIdentifier "withRootedLifecycleRequestKernel" rootedSource @?= 3
    , testCase "rooted lifecycle request framing is exact, bounded, canonical, and variant-closed" $
        withHandoffPackageRoot $ \packageRoot -> do
            rootedSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Rooted")
            assertFragmentsInOrder
                "the codec fixes one domain/version and the 7 MiB, 6 MiB, text, path, and nonce limits"
                [ "rootedLifecycleDomain = \"hostbootstrap/rooted-lifecycle-request\""
                , "rootedLifecycleVersion = ByteString.pack [0, 0, 0, 0, 0, 0, 0, 1]"
                , "rootedLifecycleWireLimit = 7 * 1024 * 1024"
                , "rootedLifecycleBodyLimit = 6 * 1024 * 1024"
                , "rootedLifecycleTextLimit = 4096"
                , "rootedLifecyclePathLimit = 256"
                , "rootedLifecycleNonceBytes = 32"
                ]
                rootedSource
            assertFragmentsInOrder
                "body-bearing construction checks the common admission before its opaque body and complete bound"
                [ "rootedPostOpenBodyRequest makeRequest path session stage ordinal nonce predecessor body = do"
                , "requireLifecyclePostOpen path session stage ordinal nonce predecessor"
                , "not (ByteString.null body)"
                , "ByteString.length body <= rootedLifecycleBodyLimit"
                , "boundedLifecycleRequest (makeRequest path session stage ordinal nonce predecessor body)"
                ]
                rootedSource
            assertFragmentsInOrder
                "common post-open construction checks every path and scalar before complete rendering"
                [ "requireLifecyclePostOpen path session stage ordinal nonce predecessor = do"
                , "not (null path) && length path <= rootedLifecyclePathLimit"
                , "mapM_ (requireLifecycleText \"requester path component\") path"
                , "requireLifecycleText \"session\" session"
                , "requireLifecycleText \"stage\" stage"
                , "ordinal /= 0"
                , "requireLifecycleNonce nonce"
                , "requireDigest \"predecessor response\" predecessor"
                , "boundedLifecycleRequest request = do"
                , "ByteString.length (renderRootedLifecycleRequestKernel request) <= rootedLifecycleWireLimit"
                ]
                rootedSource
            assertFragmentsInOrder
                "strict decoding prebounds the complete wire, fixes domain/version, and requires canonical rerendering"
                [ "rootedLifecycleRequestFromWireKernel raw = do"
                , "ByteString.length raw <= rootedLifecycleWireLimit"
                , "frames <- collectLifecycleFrames raw"
                , "domain : version : variant : fields"
                , "domain == rootedLifecycleDomain"
                , "version == rootedLifecycleVersion"
                , "decodeLifecycleVariant variant fields"
                , "renderRootedLifecycleRequestKernel request == raw"
                , "\"is not a canonical rooted lifecycle request\""
                ]
                rootedSource
            assertFragmentsInOrder
                "the decoder admits only exact 4, 9, and 10 top-level frame shapes and all six discriminators"
                [ "decodeLifecycleVariant \"open-frame\" [nonce] = rootedOpenFrameRequestKernel nonce"
                , "decodeLifecycleVariant \"open-frame\" _ = Left \"open-frame has the wrong field count\""
                , "decodeLifecycleVariant \"next-node\" fields = decodeLifecyclePostOpen rootedNextNodeRequestKernel fields"
                , "decodeLifecycleVariant \"settle-node\" fields = decodeLifecyclePostOpenBody rootedSettleNodeRequestKernel fields"
                , "decodeLifecycleVariant \"descend-result\" fields = decodeLifecyclePostOpenBody rootedDescendResultRequestKernel fields"
                , "decodeLifecycleVariant \"close-frame\" fields = decodeLifecyclePostOpen rootedCloseFrameRequestKernel fields"
                , "decodeLifecycleVariant \"receipt-confirm\" fields = decodeLifecyclePostOpen rootedReceiptConfirmRequestKernel fields"
                , "decodeLifecycleVariant _ _ = Left \"has an unknown rooted lifecycle request variant\""
                , "[pathRaw, sessionRaw, stageRaw, ordinalRaw, nonce, predecessorRaw]"
                , "case reverse fields of body : reversedCommon"
                ]
                rootedSource
            assertFragmentsInOrder
                "rendering preserves root-nearest-to-leaf path order and yields four, nine, or ten outer frames"
                [ "OpenFrame nonce -> lifecycleRequestWire \"open-frame\" [nonce]"
                , "NextNode path session stage ordinal nonce predecessor -> lifecyclePostOpenWire \"next-node\" path session stage ordinal nonce predecessor []"
                , "SettleNode path session stage ordinal nonce predecessor body -> lifecyclePostOpenWire \"settle-node\" path session stage ordinal nonce predecessor [body]"
                , "DescendResult path session stage ordinal nonce predecessor body -> lifecyclePostOpenWire \"descend-result\" path session stage ordinal nonce predecessor [body]"
                , "CloseFrame path session stage ordinal nonce predecessor -> lifecyclePostOpenWire \"close-frame\" path session stage ordinal nonce predecessor []"
                , "ReceiptConfirm path session stage ordinal nonce predecessor -> lifecyclePostOpenWire \"receipt-confirm\" path session stage ordinal nonce predecessor []"
                , "[ renderLifecyclePath path , TextEncoding.encodeUtf8 session , TextEncoding.encodeUtf8 stage , ByteString.pack (word64BigEndian ordinal) , nonce , TextEncoding.encodeUtf8 predecessor ] ++ body"
                , "map rootedFrame ([rootedLifecycleDomain, rootedLifecycleVersion, variant] ++ fields)"
                , "renderLifecyclePath = ByteString.concat . map (rootedFrame . TextEncoding.encodeUtf8)"
                ]
                rootedSource
            assertFragmentsInOrder
                "raw text and predecessor fields are bounded before UTF-8 or digest decoding"
                [ "decodeLifecycleText label raw = do require (not (ByteString.null raw))"
                , "ByteString.length raw <= rootedLifecycleTextLimit"
                , "TextEncoding.decodeUtf8' raw"
                , "decodeLifecyclePredecessor raw = do require (ByteString.length raw == 64)"
                , "decodeDigest \"predecessor response\" raw"
                ]
                rootedSource
            assertFragmentsInOrder
                "nested paths and top-level fields refuse excess count and oversized declarations before splitting"
                [ "collectLifecycleFrames = collect 10 takeLifecycleFrame \"has more than ten rooted lifecycle request fields\""
                , "collect rootedLifecyclePathLimit takeLifecyclePathFrame \"has more than 256 requester path components\""
                , "count >= limit = Left tooMany"
                , "ByteString.length raw < 8"
                , "declared > fromIntegral limit"
                , "fromIntegral (ByteString.length body) < declared"
                , "ByteString.splitAt (fromIntegral declared) body"
                ]
                rootedSource
            SourceGuard.countHaskellIdentifier "lifecycleRequestWire" rootedSource @?= 4
            SourceGuard.countHaskellIdentifier "decodeLifecycleVariant" rootedSource @?= 10
            SourceGuard.countHaskellIdentifier "rootedLifecycleRequestFromWireKernel" rootedSource @?= 3
    , testCase "rooted lifecycle request ownership is neutral, single-owner, budgeted, and freezes shared surfaces" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            (handoffSource, _) <-
                (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            rootedSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Rooted")
            (protocolSource, _) <-
                (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Protocol")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            cabalRows <- handoffPackageRows cabalSource
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            let importers moduleName =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
            importers "HostBootstrap.Handoff.Rooted"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "src/HostBootstrap/Lifecycle/Rooted/Node.hs"
                    ]
            users "RootedLifecycleRequest"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs"
                    ]
            users "rootedLifecycleRequestFromWireKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Lifecycle/Rooted/Node.hs"
                    ]
            users "withRootedLifecycleRequestKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Lifecycle/Rooted/Node.hs"
                    ]
            assertBool
                "the request remains structurally private and absent from frozen Protocol while the facade consumes its hidden decoder"
                ( SourceGuard.countHaskellIdentifier "RootedLifecycleRequest" handoffSource > 0
                    && SourceGuard.countHaskellIdentifier "RootedLifecycleRequest" protocolSource == 0
                )
            assertBool
                "Rooted remains one Cabal-private module with no testing or internal companion"
                ( "HostBootstrap.Handoff.Rooted" `notElem` exposed
                    && length (filter (== "HostBootstrap.Handoff.Rooted") private) == 1
                    && not ("HostBootstrap.Handoff.Rooted.Testing" `isInfixOf` cabalSource)
                    && not ("HostBootstrap.Handoff.Rooted.Internal" `isInfixOf` cabalSource)
                )
            assertBool
                "the neutral request owner imports no authority, effect, storage, command, or cryptography owner"
                ( all
                    (\moduleName -> not (SourceGuard.importsModule moduleName rootedSource))
                    [ "Crypto.PubKey.Ed25519"
                    , "HostBootstrap.Authority"
                    , "HostBootstrap.Command"
                    , "HostBootstrap.Handoff"
                    , "HostBootstrap.Handoff.Internal"
                    , "HostBootstrap.Lifecycle"
                    , "HostBootstrap.Protected"
                    , "System.IO"
                    ]
                )
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier rootedSource @?= 0)
                [ "Ed25519"
                , "RootBroker"
                , "ProtectedStore"
                , "CommandAuthority"
                , "LifecycleCursor"
                , "Map"
                , "HashMap"
                , "IO"
                , "unsafeCoerce"
                ]
            SourceGuard.countHaskellTokenSequence ["data", "RootedLifecycleRequest"] rootedSource @?= 1
            SourceGuard.countHaskellTokenSequence ["newtype", "RootedLifecycleRequest"] rootedSource @?= 0
            frozenHandoffDefinitionDigest [ "rootedLifecycleRequestFromExactWire" ] handoffSource
                >>= (@?= "81d964e757a7b2fdcb1b706ed37624d546b73144c28553d8663f282f98e26426")
            cabalRows @?= frozenHandoffPackageRows
            assertFragmentsInOrder
                "Protocol retains the pre-existing singleton rooted outer request field and tags"
                [ "RootedLifecycleRequestTag -> 1"
                , "RootedLifecycleResponseTag -> 1"
                , "RootedLifecycleRequestTag -> 18"
                , "RootedLifecycleResponseTag -> 19"
                , "18 -> Right RootedLifecycleRequestTag"
                , "19 -> Right RootedLifecycleResponseTag"
                ]
                protocolSource
    , testCase "rooted lifecycle responses have one opaque seven-variant shape, seven unsigned builders, and one signature-attaching fold" $
        withHandoffPackageRoot $ \packageRoot -> do
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            rootedSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Rooted")
            rootedExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Rooted has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Rooted" rootedSource)
            let rooted = normalizeWhitespace rootedSource
                exports = normalizedModuleExports rootedExports
                constructors =
                    [ "Opened"
                    , "Prepared"
                    , "Descend"
                    , "Settled"
                    , "FrameComplete"
                    , "ReceiptRecorded"
                    , "Refused"
                    ]
                builders =
                    [ "rootedOpenedResponseUnsignedKernel"
                    , "rootedPreparedResponseUnsignedKernel"
                    , "rootedDescendResponseUnsignedKernel"
                    , "rootedSettledResponseUnsignedKernel"
                    , "rootedFrameCompleteResponseUnsignedKernel"
                    , "rootedReceiptRecordedResponseUnsignedKernel"
                    , "rootedRefusedResponseUnsignedKernel"
                    ]
            SourceGuard.countHaskellTokenSequence ["newtype", "RequestDigest"] rootedSource @?= 1
            SourceGuard.countHaskellTokenSequence ["type", "role", "RequestDigest"] rootedSource @?= 0
            assertFragmentsInOrder
                "the request scalar has one validating factory and a total description"
                [ "newtype RequestDigest = RequestDigest Text"
                , "deriving (Eq, Show)"
                , "mkRequestDigest :: Text -> Either Text RequestDigest"
                , "mkRequestDigest digest = do"
                , "requireDigest \"rooted lifecycle request\" digest"
                , "pure (RequestDigest digest)"
                , "requestDigestText :: RequestDigest -> Text"
                , "requestDigestText (RequestDigest digest) = digest"
                ] rootedSource
            SourceGuard.countHaskellTokenSequence ["newtype", "LifecycleSession"] rootedSource @?= 1
            SourceGuard.countHaskellTokenSequence ["type", "role", "LifecycleSession"] rootedSource @?= 0
            assertFragmentsInOrder
                "the lifecycle session scalar validates the existing encoded-byte bound and has a total description"
                [ "newtype LifecycleSession = LifecycleSession Text"
                , "deriving (Eq, Show)"
                , "mkLifecycleSession :: Text -> Either Text LifecycleSession"
                , "mkLifecycleSession session = do"
                , "requireLifecycleText \"response session\" session"
                , "pure (LifecycleSession session)"
                , "lifecycleSessionText :: LifecycleSession -> Text"
                , "lifecycleSessionText (LifecycleSession session) = session"
                ] rootedSource
            SourceGuard.countHaskellTokenSequence ["newtype", "LifecycleStage"] rootedSource @?= 1
            SourceGuard.countHaskellTokenSequence ["type", "role", "LifecycleStage"] rootedSource @?= 0
            assertFragmentsInOrder
                "the lifecycle stage scalar validates the existing encoded-byte bound and has a total description"
                [ "newtype LifecycleStage = LifecycleStage Text"
                , "deriving (Eq, Show)"
                , "mkLifecycleStage :: Text -> Either Text LifecycleStage"
                , "mkLifecycleStage stage = do"
                , "requireLifecycleText \"response stage\" stage"
                , "pure (LifecycleStage stage)"
                , "lifecycleStageText :: LifecycleStage -> Text"
                , "lifecycleStageText (LifecycleStage stage) = stage"
                ] rootedSource
            SourceGuard.countHaskellTokenSequence ["newtype", "LifecycleOrdinal"] rootedSource @?= 1
            SourceGuard.countHaskellTokenSequence ["type", "role", "LifecycleOrdinal"] rootedSource @?= 0
            forM_ ["Num", "Enum", "Bounded"] $ \className ->
                SourceGuard.countHaskellTokenSequence ["instance", className, "LifecycleOrdinal"] rootedSource @?= 0
            assertFragmentsInOrder
                "the lifecycle ordinal scalar has only the existing nonzero predicate and a total description"
                [ "newtype LifecycleOrdinal = LifecycleOrdinal Word64"
                , "deriving (Eq, Show)"
                , "mkLifecycleOrdinal :: Word64 -> Either Text LifecycleOrdinal"
                , "mkLifecycleOrdinal ordinal = do"
                , "require (ordinal /= 0) \"has a zero response ordinal\""
                , "pure (LifecycleOrdinal ordinal)"
                , "lifecycleOrdinalWord64 :: LifecycleOrdinal -> Word64"
                , "lifecycleOrdinalWord64 (LifecycleOrdinal ordinal) = ordinal"
                ] rootedSource
            SourceGuard.countHaskellTokenSequence ["newtype", "PredecessorDigest"] rootedSource @?= 1
            SourceGuard.countHaskellTokenSequence ["type", "role", "PredecessorDigest"] rootedSource @?= 0
            assertFragmentsInOrder
                "the receipt predecessor scalar validates only the completed-response digest format and has a total description"
                [ "newtype PredecessorDigest = PredecessorDigest Text"
                , "deriving (Eq, Show)"
                , "mkPredecessorDigest :: Text -> Either Text PredecessorDigest"
                , "mkPredecessorDigest digest = do"
                , "requireDigest \"completed response\" digest"
                , "pure (PredecessorDigest digest)"
                , "predecessorDigestText :: PredecessorDigest -> Text"
                , "predecessorDigestText (PredecessorDigest digest) = digest"
                ] rootedSource
            assertContains
                "the response is exactly one closed, non-indexed seven-variant descriptive carrier"
                "data RootedLifecycleResponse = Opened Text [Text] Text Text Word64 ByteString | Prepared Text [Text] Text Text Word64 ByteString ByteString ByteString ByteString ByteString ByteString | Descend Text [Text] Text Text Word64 ByteString ByteString ByteString | Settled Text [Text] Text Text Word64 ByteString ByteString ByteString | FrameComplete Text [Text] Text Text Word64 ByteString ByteString ByteString | ReceiptRecorded Text [Text] Text Text Word64 ByteString Text ByteString | Refused Text [Text] Text Text Word64 ByteString Text ByteString"
                rooted
            SourceGuard.countHaskellTokenSequence ["data", "RootedLifecycleResponse"] rootedSource @?= 1
            SourceGuard.countHaskellTokenSequence ["newtype", "RootedLifecycleResponse"] rootedSource @?= 0
            SourceGuard.countHaskellIdentifier "RootedLifecycleResponse" rootedSource @?= 9
            mapM_
                (\constructor -> SourceGuard.countHaskellIdentifier constructor rootedSource @?= 3)
                constructors
            mapM_
                (\builder -> SourceGuard.countHaskellIdentifier builder rootedSource @?= 4)
                builders
            assertBool
                "only the opaque response name, seven unsigned builders, checked codecs, pairing, and fold are exported"
                ( "RootedLifecycleResponse" `elem` exports
                    && "RootedLifecycleResponse(..)" `notElem` exports
                    && all (`elem` exports) builders
                    && all (`notElem` exports) constructors
                    && all
                        (`elem` exports)
                        [ "rootedLifecycleResponseFromUnsignedKernel"
                        , "rootedLifecycleResponseFromWireKernel"
                        , "rootedLifecycleResponseSignatureKernel"
                        , "renderRootedLifecycleResponseKernel"
                        , "renderRootedLifecycleUnsignedResponseKernel"
                        , "rootedLifecycleResponsePairKernel"
                        , "rootedLifecycleUnsignedResponsePairKernel"
                        , "withRootedLifecycleResponseKernel"
                        ]
                )
            assertFragmentsInOrder
                "exactly seven checked unsigned builders return canonical bytes without a signature parameter"
                [ "rootedOpenedResponseUnsignedKernel :: Text -> [Text] -> Text -> Text -> Word64 -> Either Text ByteString"
                , "rootedOpenedResponseUnsignedKernel digest path session stage ordinal = do"
                , "requireResponseCommon digest path session stage ordinal"
                , "boundedResponseUnsigned (responseWire \"opened\" (responseCommon digest path session stage ordinal))"
                , "rootedPreparedResponseUnsignedKernel :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> Either Text ByteString"
                , "rootedPreparedResponseUnsignedKernel requestDigest path lifecycleSession lifecycleStage lifecycleOrdinal nonce node dependencies operationGate projectedGates = do"
                , "let digest = requestDigestText requestDigest"
                , "session = lifecycleSessionText lifecycleSession"
                , "stage = lifecycleStageText lifecycleStage"
                , "ordinal = lifecycleOrdinalWord64 lifecycleOrdinal"
                , "requireResponsePostOpen digest path session stage ordinal nonce"
                , "body <- preparedResponseBody node dependencies operationGate projectedGates"
                , "boundedResponseUnsigned (responsePostOpenWire \"prepared\" digest path session stage ordinal nonce body)"
                , "rootedDescendResponseUnsignedKernel :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString"
                , "rootedDescendResponseUnsignedKernel = opaqueResponseUnsigned \"descend\""
                , "rootedSettledResponseUnsignedKernel = opaqueResponseUnsigned \"settled\""
                , "rootedFrameCompleteResponseUnsignedKernel = opaqueResponseUnsigned \"frame-complete\""
                , "rootedReceiptRecordedResponseUnsignedKernel :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> PredecessorDigest -> Either Text ByteString"
                , "rootedReceiptRecordedResponseUnsignedKernel requestDigest path lifecycleSession lifecycleStage lifecycleOrdinal nonce predecessorDigest = do"
                , "let digest = requestDigestText requestDigest"
                , "session = lifecycleSessionText lifecycleSession"
                , "stage = lifecycleStageText lifecycleStage"
                , "ordinal = lifecycleOrdinalWord64 lifecycleOrdinal"
                , "completionDigest = predecessorDigestText predecessorDigest"
                , "rootedRefusedResponseUnsignedKernel :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> Text -> Either Text ByteString"
                , "rootedRefusedResponseUnsignedKernel requestDigest path lifecycleSession lifecycleStage lifecycleOrdinal nonce detail = do"
                , "let digest = requestDigestText requestDigest"
                , "session = lifecycleSessionText lifecycleSession"
                , "stage = lifecycleStageText lifecycleStage"
                , "ordinal = lifecycleOrdinalWord64 lifecycleOrdinal"
                ]
                rootedSource
            mapM_
                (\signedBuilder -> SourceGuard.countHaskellIdentifier signedBuilder rootedSource @?= 0)
                [ "rootedOpenedResponseKernel"
                , "rootedPreparedResponseKernel"
                , "rootedDescendResponseKernel"
                , "rootedSettledResponseKernel"
                , "rootedFrameCompleteResponseKernel"
                , "rootedReceiptRecordedResponseKernel"
                , "rootedRefusedResponseKernel"
                ]
            assertFragmentsInOrder
                "the sole signature attachment accepts canonical unsigned bytes plus one exact signature and reconstructs every closed branch"
                [ "rootedLifecycleResponseFromUnsignedKernel :: ByteString -> ByteString -> Either Text RootedLifecycleResponse"
                , "rootedLifecycleResponseFromUnsignedKernel unsigned signature = do"
                , "ByteString.length signature == rootedLifecycleResponseSignatureBytes"
                , "withUnsignedResponse unsigned"
                , "Opened digest path session stage ordinal signature"
                , "Prepared digest path session stage ordinal nonce node dependencies operationGate projectedGates signature"
                , "Descend digest path session stage ordinal nonce body signature"
                , "Settled digest path session stage ordinal nonce body signature"
                , "FrameComplete digest path session stage ordinal nonce body signature"
                , "ReceiptRecorded digest path session stage ordinal nonce completion signature"
                , "Refused digest path session stage ordinal nonce detail signature"
                ]
                rootedSource
            assertFragmentsInOrder
                "the sole response eliminator has seven fixed callbacks and preserves every field"
                [ "withRootedLifecycleResponseKernel :: RootedLifecycleResponse"
                , "withRootedLifecycleResponseKernel response onOpened onPrepared onDescend onSettled onComplete onReceipt onRefused = case response of"
                , "Opened digest path session stage ordinal signature -> onOpened digest path session stage ordinal signature"
                , "Prepared digest path session stage ordinal nonce node dependencies operationGate projectedGates signature -> onPrepared digest path session stage ordinal nonce node dependencies operationGate projectedGates signature"
                , "Descend digest path session stage ordinal nonce body signature -> onDescend digest path session stage ordinal nonce body signature"
                , "Settled digest path session stage ordinal nonce body signature -> onSettled digest path session stage ordinal nonce body signature"
                , "FrameComplete digest path session stage ordinal nonce body signature -> onComplete digest path session stage ordinal nonce body signature"
                , "ReceiptRecorded digest path session stage ordinal nonce completion signature -> onReceipt digest path session stage ordinal nonce completion signature"
                , "Refused digest path session stage ordinal nonce detail signature -> onRefused digest path session stage ordinal nonce detail signature"
                ]
                rootedSource
            SourceGuard.countHaskellIdentifier "rootedLifecycleResponseFromUnsignedKernel" rootedSource @?= 4
            SourceGuard.countHaskellIdentifier "withRootedLifecycleResponseKernel" rootedSource @?= 5
            assertFragmentsInOrder
                "Prepared constructs its checked digest from the exact request after attached-session and grant evidence"
                [ "withRootedPreparedResponseKernel broker session request grant use ="
                , "withRootedFrameSessionKernel session"
                , "if not attached"
                , "postOpenNonce \"prepared\" request"
                , "withPreparedNodeGrantKernel grant"
                , "signAndUse broker request"
                , "digest <- Rooted.mkRequestDigest (childConfigDigest request)"
                , "checkedSession <- Rooted.mkLifecycleSession token"
                , "checkedStage <- Rooted.mkLifecycleStage \"prepared\""
                , "checkedOrdinal <- Rooted.mkLifecycleOrdinal (ordinal + 1)"
                , "Rooted.rootedPreparedResponseUnsignedKernel digest path checkedSession checkedStage checkedOrdinal"
                ] relaySource
            genericBeforeFamily <-
                requiredSourceSection
                    "the generic response prefix before selected-family validation"
                    "withRootedPostOpenResponseKernel broker session family request body use ="
                    "build path token ordinal nonce digest stage = case family of"
                    relaySource
            SourceGuard.countHaskellIdentifier "mkLifecycleOrdinal" genericBeforeFamily @?= 0
            SourceGuard.countHaskellIdentifier "mkPredecessorDigest" genericBeforeFamily @?= 0
            assertFragmentsInOrder
                "the closed post-open family derives its checked digest inside the existing signing result"
                [ "withRootedPostOpenResponseKernel broker session family request body use ="
                , "withRootedFrameSessionKernel session"
                , "if not attached"
                , "postOpenNonce family request"
                , "signAndUse broker request"
                , "digest <- Rooted.mkRequestDigest (childConfigDigest request)"
                , "checkedSession <- Rooted.mkLifecycleSession token"
                , "checkedStage <- Rooted.mkLifecycleStage family"
                , "build path checkedSession ordinal nonce digest checkedStage"
                , "use"
                , "build path token ordinal nonce digest stage = case family of"
                , "\"descend\" -> opaque Rooted.rootedDescendResponseUnsignedKernel path token ordinal nonce"
                , "\"settled\" -> opaque Rooted.rootedSettledResponseUnsignedKernel path token ordinal nonce"
                , "\"frame-complete\" -> opaque Rooted.rootedFrameCompleteResponseUnsignedKernel path token ordinal nonce"
                , "\"receipt-recorded\" -> do"
                , "checkedOrdinal <- Rooted.mkLifecycleOrdinal (ordinal + 1)"
                , "checkedPredecessor <- Rooted.mkPredecessorDigest (TextEncoding.decodeUtf8Lenient body)"
                , "Rooted.rootedReceiptRecordedResponseUnsignedKernel digest path token stage checkedOrdinal nonce checkedPredecessor"
                , "\"refused\" -> do"
                , "checkedOrdinal <- Rooted.mkLifecycleOrdinal (ordinal + 1)"
                , "Rooted.rootedRefusedResponseUnsignedKernel digest path token stage checkedOrdinal"
                , "_ -> Left (responseFailure \"the post-open response family is not closed\")"
                , "opaque builder p s o n = do"
                , "checkedOrdinal <- Rooted.mkLifecycleOrdinal (o + 1)"
                , "builder digest p s stage checkedOrdinal n body"
                ] relaySource
    , testCase "rooted lifecycle response framing is exact nine-or-eleven-field, bounded, canonical, and prepared-body closed" $
        withHandoffPackageRoot $ \packageRoot -> do
            rootedSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Rooted")
            assertFragmentsInOrder
                "the response fixes its own domain, the canonical version, and every scalar, body, signature, and total limit"
                [ "rootedLifecycleWireLimit = 7 * 1024 * 1024"
                , "rootedLifecycleBodyLimit = 6 * 1024 * 1024"
                , "rootedLifecycleTextLimit = 4096"
                , "rootedLifecyclePathLimit = 256"
                , "rootedLifecycleNonceBytes = 32"
                , "rootedLifecycleResponseDomain = \"hostbootstrap/rooted-lifecycle-response\""
                , "rootedLifecycleResponseSignatureBytes = 64"
                , "requireResponseCommon digest path session stage ordinal = do"
                , "requireDigest \"rooted lifecycle request\" digest"
                , "not (null path) && length path <= rootedLifecyclePathLimit"
                , "mapM_ (requireLifecycleText \"response path component\") path"
                , "requireLifecycleText \"response session\" session"
                , "requireLifecycleText \"response stage\" stage"
                , "ordinal /= 0"
                , "requireResponsePostOpen digest path session stage ordinal nonce = requireResponseCommon digest path session stage ordinal >> requireLifecycleNonce nonce"
                , "requireResponseBody body = do"
                , "not (ByteString.null body)"
                , "ByteString.length body <= rootedLifecycleBodyLimit"
                ]
                rootedSource
            assertFragmentsInOrder
                "rendering fixes domain, version, discriminator, request digest, root-nearest path, successor coordinates, nonce, body, then signature"
                [ "responseCommon digest path session stage ordinal = [ TextEncoding.encodeUtf8 digest , renderLifecyclePath path , TextEncoding.encodeUtf8 session , TextEncoding.encodeUtf8 stage , ByteString.pack (word64BigEndian ordinal) ]"
                , "responseWire variant fields = ByteString.concat (map rootedFrame ([rootedLifecycleResponseDomain, rootedLifecycleVersion, variant] ++ fields))"
                , "responsePostOpenWire variant digest path session stage ordinal nonce body = responseWire variant (responseCommon digest path session stage ordinal ++ [nonce, body])"
                , "ByteString.length wire + 8 + rootedLifecycleResponseSignatureBytes <= rootedLifecycleWireLimit"
                , "renderRootedLifecycleResponseKernel response = renderRootedLifecycleUnsignedResponseKernel response <> rootedFrame (rootedLifecycleResponseSignatureKernel response)"
                ]
                rootedSource
            assertFragmentsInOrder
                "signed decoding admits at most eleven fields, detaches only the last signature, and requires exact canonical rerendering"
                [ "rootedLifecycleResponseFromWireKernel raw = do"
                , "ByteString.length raw <= rootedLifecycleWireLimit"
                , "frames <- collect 11 takeLifecycleFrame \"has more than eleven rooted lifecycle response fields\" raw"
                , "case reverse frames of signature : reversedUnsigned"
                , "let unsigned = ByteString.concat (map rootedFrame (reverse reversedUnsigned))"
                , "rootedLifecycleResponseFromUnsignedKernel unsigned signature"
                , "renderRootedLifecycleResponseKernel response == raw"
                , "\"is not a canonical rooted lifecycle response\""
                , "_ -> Left \"has no rooted lifecycle response signature\""
                ]
                rootedSource
            assertFragmentsInOrder
                "unsigned decoding admits only the exact eight-field Opened and ten-field post-open forms and all seven discriminators"
                [ "frames <- collect 10 takeLifecycleFrame \"has more than ten unsigned rooted lifecycle response fields\" raw"
                , "domain : version : variant : fields"
                , "domain == rootedLifecycleResponseDomain"
                , "version == rootedLifecycleVersion"
                , "decodeUnsignedResponse raw variant fields"
                , "(\"opened\", [digestRaw, pathRaw, sessionRaw, stageRaw, ordinalRaw])"
                , "rootedOpenedResponseUnsignedKernel digest path session stage ordinal"
                , "(\"prepared\", postFields)"
                , "checkedDigest <- mkRequestDigest digest"
                , "checkedSession <- mkLifecycleSession session"
                , "checkedStage <- mkLifecycleStage stage"
                , "checkedOrdinal <- mkLifecycleOrdinal ordinal"
                , "rootedPreparedResponseUnsignedKernel checkedDigest path checkedSession checkedStage checkedOrdinal nonce node dependencies operationGate projectedGates"
                , "(\"descend\", postFields) -> decodeOpaqueResponse raw rootedDescendResponseUnsignedKernel onDescend postFields"
                , "(\"settled\", postFields) -> decodeOpaqueResponse raw rootedSettledResponseUnsignedKernel onSettled postFields"
                , "(\"frame-complete\", postFields) -> decodeOpaqueResponse raw rootedFrameCompleteResponseUnsignedKernel onComplete postFields"
                , "(\"receipt-recorded\", postFields)"
                , "completion <- decodeResponseDigest \"completed response\" body"
                , "checkedDigest <- mkRequestDigest digest"
                , "checkedSession <- mkLifecycleSession session"
                , "checkedStage <- mkLifecycleStage stage"
                , "checkedOrdinal <- mkLifecycleOrdinal ordinal"
                , "checkedPredecessor <- mkPredecessorDigest completion"
                , "rootedReceiptRecordedResponseUnsignedKernel checkedDigest path checkedSession checkedStage checkedOrdinal nonce checkedPredecessor"
                , "(\"refused\", postFields)"
                , "checkedDigest <- mkRequestDigest digest"
                , "checkedSession <- mkLifecycleSession session"
                , "checkedStage <- mkLifecycleStage stage"
                , "checkedOrdinal <- mkLifecycleOrdinal ordinal"
                , "rootedRefusedResponseUnsignedKernel checkedDigest path checkedSession checkedStage checkedOrdinal nonce detail"
                , "_ -> Left \"has an unknown rooted lifecycle response variant or field count\""
                , "decodeResponsePost [digestRaw, pathRaw, sessionRaw, stageRaw, ordinalRaw, nonce, body] = do"
                , "decodeResponsePost _ = Left \"post-open rooted lifecycle response has the wrong field count\""
                , "decodeOpaqueResponse :: ByteString -> (RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString)"
                , "checkedDigest <- mkRequestDigest digest"
                , "checkedSession <- mkLifecycleSession session"
                , "checkedStage <- mkLifecycleStage stage"
                , "checkedOrdinal <- mkLifecycleOrdinal ordinal"
                , "canonical <- build checkedDigest path checkedSession checkedStage checkedOrdinal nonce body"
                , "pure (use digest path session stage ordinal nonce body)"
                ]
                rootedSource
            assertFragmentsInOrder
                "Prepared alone owns exactly four non-empty nested frames whose encoded aggregate remains inside the common body bound"
                [ "preparedResponseBody node dependencies operationGate projectedGates = do"
                , "mapM_ requireResponseBody [node, dependencies, operationGate, projectedGates]"
                , "ByteString.concat (map rootedFrame [node, dependencies, operationGate, projectedGates])"
                , "requireResponseBody body"
                , "decodePreparedResponseBody raw = do"
                , "requireResponseBody raw"
                , "collect 4 (takeLifecycleBoundedFrame rootedLifecycleBodyLimit \"prepared response field\") \"has more than four prepared response fields\" raw"
                , "length fields == 4"
                , "\"has fewer than four prepared response fields\""
                , "mapM_ requireResponseBody fields"
                ]
                rootedSource
            assertFragmentsInOrder
                "receipt and refusal bodies retain exact lowercase-digest and bounded UTF-8 grammars while the other bodies remain non-empty opaque bytes"
                [ "requireDigest \"completed response\" completionDigest"
                , "responsePostOpenWire \"receipt-recorded\" digest path session stage ordinal nonce (TextEncoding.encodeUtf8 completionDigest)"
                , "requireLifecycleText \"refusal detail\" detail"
                , "responsePostOpenWire \"refused\" digest path session stage ordinal nonce (TextEncoding.encodeUtf8 detail)"
                , "opaqueResponseUnsigned variant requestDigest path lifecycleSession lifecycleStage lifecycleOrdinal nonce body = do"
                , "let digest = requestDigestText requestDigest"
                , "session = lifecycleSessionText lifecycleSession"
                , "stage = lifecycleStageText lifecycleStage"
                , "ordinal = lifecycleOrdinalWord64 lifecycleOrdinal"
                , "requireResponseBody body"
                ]
                rootedSource
            SourceGuard.countHaskellIdentifier "decodeUnsignedResponse" rootedSource @?= 3
            SourceGuard.countHaskellIdentifier "decodePreparedResponseBody" rootedSource @?= 3
            SourceGuard.countHaskellIdentifier "rootedLifecycleResponseFromWireKernel" rootedSource @?= 3
    , testCase "rooted lifecycle response pairing is exact, neutral, single-owner, budgeted, and freezes shared surfaces" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            (handoffSource, _) <-
                (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            (handoffInternalSource, _) <-
                (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Internal")
            (rootedSource, _) <-
                (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Rooted")
            (protocolSource, _) <-
                (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Protocol")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            cabalRows <- handoffPackageRows cabalSource
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            let importers moduleName =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
            assertFragmentsInOrder
                "pairing fixes the exact request digest, admits only the closed family matrix, echoes post-open coordinates, and keeps successor stage and ordinal independent"
                [ "rootedLifecycleResponsePairKernel expected request = rootedLifecycleUnsignedResponsePairKernel expected request . renderRootedLifecycleUnsignedResponseKernel"
                , "rootedLifecycleUnsignedResponsePairKernel expected request unsigned = do"
                , "requireDigest \"rooted lifecycle request\" expected"
                , "withUnsignedResponse unsigned opened prepared descend settled complete receipt refused >>= id"
                , "opened digest _ _ _ _ = require (digest == expected) \"names a different rooted lifecycle request\" >> case request of"
                , "OpenFrame _ -> Right Nothing"
                , "_ -> Left \"opened does not answer this rooted lifecycle request\""
                , "prepared digest path session stage ordinal nonce _ _ _ _ = post \"prepared\" Nothing Nothing digest path session stage ordinal nonce"
                , "descend digest path session stage ordinal nonce _ = post \"descend\" Nothing Nothing digest path session stage ordinal nonce"
                , "settled digest path session stage ordinal nonce _ = post \"settled\" Nothing Nothing digest path session stage ordinal nonce"
                , "complete digest path session stage ordinal nonce body = post \"frame-complete\" (Just body) Nothing digest path session stage ordinal nonce"
                , "receipt digest path session stage ordinal nonce completion = post \"receipt-recorded\" Nothing (Just completion) digest path session stage ordinal nonce"
                , "refused digest path session stage ordinal nonce _ = post \"refused\" Nothing Nothing digest path session stage ordinal nonce"
                , "post variant report completion digest path session _ _ nonce = do"
                , "require (digest == expected) \"names a different rooted lifecycle request\""
                , "NextNode p s _ _ n _ | variant `elem` [\"prepared\", \"descend\", \"refused\"]"
                , "SettleNode p s _ _ n _ _ | variant `elem` [\"settled\", \"refused\"]"
                , "DescendResult p s _ _ n _ _ | variant `elem` [\"settled\", \"refused\"]"
                , "CloseFrame p s _ _ n _ | variant `elem` [\"frame-complete\", \"refused\"]"
                , "ReceiptConfirm p s _ _ n predecessorDigest | variant `elem` [\"receipt-recorded\", \"refused\"]"
                , "_ -> Left \"rooted lifecycle response does not answer this request family\""
                , "path == requestPath && session == requestSession && nonce == requestNonce"
                , "\"does not echo the rooted lifecycle request coordinates\""
                , "(Just actual, Just wanted) -> require (actual == wanted) \"does not name the confirmed frame-complete response\""
                , "(Just _, Nothing) -> Left \"receipt-recorded does not answer a receipt confirmation\""
                , "pure report"
                ]
                rootedSource
            importers "HostBootstrap.Handoff.Rooted"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "src/HostBootstrap/Lifecycle/Rooted/Node.hs"
                    ]
            users "RootedLifecycleResponse"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    ]
            mapM_
                ( \identifier ->
                    users identifier
                        @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs"]
                )
                [ "rootedLifecycleResponseFromUnsignedKernel"
                , "rootedLifecycleUnsignedResponsePairKernel"
                ]
            mapM_
                ( \identifier ->
                    users identifier
                        @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                            , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                            , "internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs"
                            ]
                )
                ["rootedLifecycleResponsePairKernel"]
            users "rootedLifecycleResponseFromWireKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "src/HostBootstrap/Lifecycle/Rooted/Node.hs"
                    ]
            users "withRootedLifecycleResponseKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "src/HostBootstrap/Lifecycle/Rooted/Node.hs"
                    ]
            assertBool
                "the frozen Protocol remains independent while the facade and existing capability owner consume the neutral response"
                ( SourceGuard.countHaskellIdentifier "RootedLifecycleResponse" protocolSource == 0
                    && SourceGuard.countHaskellIdentifier "RootedLifecycleResponse" handoffSource > 0
                    && SourceGuard.countHaskellIdentifier "RootedLifecycleResponse" handoffInternalSource > 0
                )
            assertBool
                "Rooted remains one Cabal-private owner with no testing, response, or internal companion"
                ( "HostBootstrap.Handoff.Rooted" `notElem` exposed
                    && length (filter (== "HostBootstrap.Handoff.Rooted") private) == 1
                    && all
                        (\seam -> not (seam `isInfixOf` cabalSource))
                        [ "HostBootstrap.Handoff.Rooted.Testing"
                        , "HostBootstrap.Handoff.Rooted.Response"
                        , "HostBootstrap.Handoff.Rooted.Internal"
                        ]
                )
            assertBool
                "the neutral response owner imports no authority, cryptography, facade, storage, process, or runtime effect owner"
                ( all
                    (\moduleName -> not (SourceGuard.importsModule moduleName rootedSource))
                    [ "Crypto.PubKey.Ed25519"
                    , "HostBootstrap.Authority"
                    , "HostBootstrap.Command"
                    , "HostBootstrap.Handoff"
                    , "HostBootstrap.Handoff.Internal"
                    , "HostBootstrap.Lifecycle"
                    , "HostBootstrap.Protected"
                    , "System.IO"
                    , "System.Process"
                    ]
                )
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier rootedSource @?= 0)
                [ "Ed25519"
                , "RootBroker"
                , "ProtectedStore"
                , "ProtectedSession"
                , "CommandAuthority"
                , "LifecycleCursor"
                , "Map"
                , "HashMap"
                , "IO"
                , "unsafeCoerce"
                ]
            SourceGuard.countHaskellTokenSequence ["data", "RootedLifecycleResponse"] rootedSource @?= 1
            SourceGuard.countHaskellTokenSequence ["newtype", "RootedLifecycleResponse"] rootedSource @?= 0
            frozenHandoffDefinitionDigest [ "renderRootedLifecycleResponse", "rootedLifecycleUnsignedPair" ] handoffSource
                >>= (@?= "3e4758bcc69e72989965d4ea8c85197a4299ca4ee2ead60db7a1c848067e78b5")
            frozenSigningCapabilityDigest handoffInternalSource
                >>= (@?= "78fee3610ada63f9c2c38a8a07589c152e9a90824bbf16fed2ce5f5af5001954")
            cabalRows @?= frozenHandoffPackageRows
    , testCase "rooted lifecycle response verification independently authenticates all seven closed families" $
        withHandoff 92 ProjectUp $ \broker -> do
            (binding, _offer) <- newOffer broker childPayload
            report <-
                expectRight
                    ( renderForwardRefusedLifecycleReport
                        (renderHandoffBinding binding)
                        "rooted lifecycle refusal"
                    )
            let key = rootBrokerVerificationKey broker
                nonce = ByteString.replicate 32 17
                path = ["root", "child"]
                session = "session-92"
                requestStage = "request-stage"
                responseStage = "response-stage"
                predecessor = childConfigDigest "previous signed response"
                completion = childConfigDigest "matching frame-complete response"
                openRequest = rootedLifecycleOpenRequest nonce
                nextRequest =
                    rootedLifecyclePostRequest
                        "next-node"
                        path
                        session
                        requestStage
                        1
                        nonce
                        predecessor
                        Nothing
                settleRequest =
                    rootedLifecyclePostRequest
                        "settle-node"
                        path
                        session
                        requestStage
                        2
                        nonce
                        predecessor
                        (Just "settlement")
                descendResultRequest =
                    rootedLifecyclePostRequest
                        "descend-result"
                        path
                        session
                        requestStage
                        3
                        nonce
                        predecessor
                        (Just "observation")
                closeRequest =
                    rootedLifecyclePostRequest
                        "close-frame"
                        path
                        session
                        requestStage
                        4
                        nonce
                        predecessor
                        Nothing
                receiptRequest =
                    rootedLifecyclePostRequest
                        "receipt-confirm"
                        path
                        session
                        requestStage
                        5
                        nonce
                        completion
                        Nothing
                preparedBody =
                    renderFrameFields
                        [ "node-package"
                        , "dependency-package"
                        , "operation-gate-package"
                        , "projected-gates-package"
                        ]
                cases =
                    [
                        ( "opened"
                        , openRequest
                        , rootedLifecycleOpenedUnsigned
                            openRequest
                            path
                            session
                            responseStage
                            1
                        , 9
                        )
                    ,
                        ( "prepared"
                        , nextRequest
                        , rootedLifecyclePostUnsigned
                            "prepared"
                            nextRequest
                            path
                            session
                            responseStage
                            2
                            nonce
                            preparedBody
                        , 11
                        )
                    ,
                        ( "descend"
                        , nextRequest
                        , rootedLifecyclePostUnsigned
                            "descend"
                            nextRequest
                            path
                            session
                            responseStage
                            3
                            nonce
                            "descent-package"
                        , 11
                        )
                    ,
                        ( "settled"
                        , settleRequest
                        , rootedLifecyclePostUnsigned
                            "settled"
                            settleRequest
                            path
                            session
                            responseStage
                            4
                            nonce
                            "settled-package"
                        , 11
                        )
                    ,
                        ( "frame-complete"
                        , closeRequest
                        , rootedLifecyclePostUnsigned
                            "frame-complete"
                            closeRequest
                            path
                            session
                            responseStage
                            5
                            nonce
                            report
                        , 11
                        )
                    ,
                        ( "receipt-recorded"
                        , receiptRequest
                        , rootedLifecyclePostUnsigned
                            "receipt-recorded"
                            receiptRequest
                            path
                            session
                            responseStage
                            6
                            nonce
                            (TextEncoding.encodeUtf8 completion)
                        , 11
                        )
                    ,
                        ( "refused"
                        , descendResultRequest
                        , rootedLifecyclePostUnsigned
                            "refused"
                            descendResultRequest
                            path
                            session
                            responseStage
                            7
                            nonce
                            "root policy refused descent"
                        , 11
                        )
                    ]
            forM_ cases $ \(label, request, unsigned, fieldCount) -> do
                signed <-
                    rootedLifecycleResponseOracleWire
                        92
                        canonicalRootedLifecycleResponseSigningDomain
                        key
                        request
                        unsigned
                withVerifiedRootedLifecycleResponse
                    key
                    request
                    signed
                    renderRootedLifecycleResponse
                    @?= Right signed
                forM_
                    [ (94, canonicalRootedLifecycleResponseSigningDomain)
                    , (92, "hostbootstrap/rooted-lifecycle-response/not-v1")
                    ] $ \(seed, domain) -> do
                        refused <- rootedLifecycleResponseOracleWire seed domain key request unsigned
                        withVerifiedRootedLifecycleResponse key request refused (const ())
                            @?= Left HandoffRootedLifecycleSignatureInvalid
                fields <- framesOf signed
                assertBool (label <> " retains its exact signed field count") (length fields == fieldCount)
    , testCase "the public response verifier refuses nineteen exact malformed requests before its callback" $
        withHandoff 111 ProjectUp $ \broker -> do
            let key = rootBrokerVerificationKey broker
                path = ["root-child", "requester"]
                session = "request-table-session"
                requestStage = "request-table-stage"
                responseStage = "request-table-successor"
                nonce = ByteString.replicate 32 23
                predecessor = childConfigDigest "the exact request table predecessor"
                next = rootedLifecyclePostRequest "next-node" path session requestStage 1 nonce predecessor Nothing
                settle = rootedLifecyclePostRequest "settle-node" path session requestStage 1 nonce predecessor (Just "observations")
                unsigned bodyBearing exactRequest =
                    rootedLifecyclePostUnsigned
                        (if bodyBearing then "settled" else "prepared") exactRequest
                        path session responseStage 2 nonce
                        (if bodyBearing then "settled observations" else renderFrameFields ["node", "dependencies", "operation-gate", "projected-gates"])
                sign bodyBearing exactRequest = rootedLifecycleResponseOracleWire
                    111 canonicalRootedLifecycleResponseSigningDomain key exactRequest (unsigned bodyBearing exactRequest)
            -- Both complete supported pairs enter their actual public callback
            -- before any malformed request is submitted to that same boundary.
            forM_ [(False, next), (True, settle)] $ \(bodyBearing, exactRequest) -> do
                signed <- sign bodyBearing exactRequest
                calls <- newIORef (0 :: Int)
                action <- expectRight (withVerifiedRootedLifecycleResponse key exactRequest signed $ \response -> do
                    modifyIORef' calls (+ 1)
                    renderRootedLifecycleResponse response @?= signed)
                action
                readIORef calls >>= (@?= 1)
            nextFields <- framesOf next
            settleFields <- framesOf settle
            let malformed =
                    [ ("version two", False, wireWithFrames [(1, lifecycleWordBytesFor 2)] nextFields,
                        "has the wrong lifecycle request version")
                    , ("unknown discriminator", False, wireWithFrames [(2, "unknown-request")] nextFields,
                        "has an unknown rooted lifecycle request variant")
                    , ("eight NextNode frames", False, renderFrameFields (take 8 nextFields),
                        "post-open rooted lifecycle request has the wrong field count")
                    , ("ten NextNode frames", False, renderFrameFields (nextFields <> ["surplus"]),
                        "post-open rooted lifecycle request has the wrong field count")
                    , ("empty requester path", False, wireWithFrames [(3, "")] nextFields,
                        "has an empty requester path")
                    , ("257 requester components", False, wireWithFrames [(3, rootedLifecyclePathWire (replicate 257 "child"))] nextFields,
                        "has more than 256 requester path components")
                    , ("4097-byte requester component", False, wireWithFrames [(3, frameWire (ByteString.replicate 4097 120))] nextFields,
                        "requester path component is oversized")
                    , ("empty session", False, wireWithFrames [(4, "")] nextFields,
                        "has an empty session")
                    , ("invalid UTF-8 session", False, wireWithFrames [(4, ByteString.singleton 255)] nextFields,
                        "has a session that is not valid UTF-8")
                    , ("empty stage", False, wireWithFrames [(5, "")] nextFields,
                        "has an empty stage")
                    , ("invalid UTF-8 stage", False, wireWithFrames [(5, ByteString.singleton 255)] nextFields,
                        "has a stage that is not valid UTF-8")
                    , ("4097-byte session", False, wireWithFrames [(4, ByteString.replicate 4097 120)] nextFields,
                        "has an oversized session")
                    , ("63-byte predecessor", False, wireWithFrames [(8, ByteString.replicate 63 48)] nextFields,
                        "has a predecessor response digest whose width is not 64 bytes")
                    , ("uppercase predecessor", False, wireWithFrames [(8, ByteString.replicate 64 65)] nextFields,
                        "predecessor response digest is not canonical lowercase SHA-256")
                    , ("zero ordinal", False, wireWithFrames [(6, lifecycleWordBytesFor 0)] nextFields,
                        "has a zero ordinal")
                    , ("seven-byte ordinal", False, wireWithFrames [(6, ByteString.replicate 7 0)] nextFields,
                        "has a noncanonical ordinal width")
                    , ("31-byte nonce", False, wireWithFrames [(7, ByteString.replicate 31 23)] nextFields,
                        "has a nonce whose width is not 32 bytes")
                    , ("empty SettleNode observation", True, wireWithFrames [(9, "")] settleFields,
                        "has an empty lifecycle request body")
                    , ("one raw trailing byte", False, next <> "!",
                        "rooted lifecycle request field is truncated before its frame header")
                    ]
            length malformed @?= 19
            forM_ malformed $ \(label, bodyBearing, exactRequest, detail) -> do
                assertBool (label <> " changes its otherwise canonical request")
                    (exactRequest /= (if bodyBearing then settle else next))
                -- This DATA signature covers the exact malformed request and
                -- its digest in an otherwise canonical response. No semantic
                -- pair is claimed for a request that cannot be decoded.
                signed <- sign bodyBearing exactRequest
                calls <- newIORef (0 :: Int)
                case withVerifiedRootedLifecycleResponse key exactRequest signed
                    (\_ -> modifyIORef' calls (+ 1)) of
                    Left failure -> failure @?= HandoffBindingMismatch ("rooted lifecycle response " <> detail)
                    Right action -> do
                        action
                        assertFailure (label <> " unexpectedly entered the response callback")
                readIORef calls >>= (@?= 0)
    , testCase "rooted lifecycle response verification refuses malformed and cross-paired transcripts before its callback" $ do
        forced <-
            try @SomeException
                ( evaluate
                    ( signRootedLifecycleResponseKernel
                        (error "forced hidden rooted lifecycle response signing capability")
                    )
                )
        case forced of
            Left failure ->
                assertBool
                    "the hidden capability is forced before the broker-taking response signer is returned"
                    ("forced hidden rooted lifecycle response signing capability" `contains` show failure)
            Right _ -> assertFailure "the partial rooted lifecycle response signer did not force its hidden capability"

        withHandoff 93 ProjectUp $ \broker -> do
            (binding, _offer) <- newOffer broker childPayload
            report <-
                expectRight
                    ( renderForwardRefusedLifecycleReport
                        (renderHandoffBinding binding)
                        "canonical rooted report"
                    )
            otherSigning <-
                expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 94))
            let key = rootBrokerVerificationKey broker
                otherKey = projectSigningVerificationKey otherSigning
                nonce = ByteString.replicate 32 18
                otherNonce = ByteString.replicate 32 19
                path = ["root", "nested"]
                session = "session-93"
                requestStage = "request-stage"
                responseStage = "response-stage"
                predecessor = childConfigDigest "predecessor response"
                completion = childConfigDigest "frame-complete response"
                openRequest = rootedLifecycleOpenRequest nonce
                nextRequest =
                    rootedLifecyclePostRequest
                        "next-node"
                        path
                        session
                        requestStage
                        1
                        nonce
                        predecessor
                        Nothing
                settleRequest =
                    rootedLifecyclePostRequest
                        "settle-node"
                        path
                        session
                        requestStage
                        2
                        nonce
                        predecessor
                        (Just "settlement")
                closeRequest =
                    rootedLifecyclePostRequest
                        "close-frame"
                        path
                        session
                        requestStage
                        3
                        nonce
                        predecessor
                        Nothing
                receiptRequest =
                    rootedLifecyclePostRequest
                        "receipt-confirm"
                        path
                        session
                        requestStage
                        4
                        nonce
                        completion
                        Nothing
                preparedBody =
                    renderFrameFields ["node", "dependencies", "operation-gate", "projected-gates"]
                canonicalUnsigned =
                    rootedLifecyclePostUnsigned
                        "frame-complete"
                        closeRequest
                        path
                        session
                        responseStage
                        4
                        nonce
                        report
                verifyWith installedKey exactRequest signed =
                    withVerifiedRootedLifecycleResponse
                        installedKey
                        exactRequest
                        signed
                        (const ())
                assertRefused label expected outcome = case outcome of
                    Left failure -> failure @?= expected
                    Right () -> assertFailure (label <> " unexpectedly entered the verified response callback")
            canonical <-
                rootedLifecycleResponseOracleWire
                    93
                    canonicalRootedLifecycleResponseSigningDomain
                    key
                    closeRequest
                    canonicalUnsigned
            verifyWith key closeRequest canonical @?= Right ()

            wrongSigningDomain <-
                rootedLifecycleResponseOracleWire
                    93
                    "hostbootstrap/rooted-lifecycle-response/not-v1"
                    key
                    closeRequest
                    canonicalUnsigned
            verifyWith key closeRequest wrongSigningDomain
                @?= Left HandoffRootedLifecycleSignatureInvalid
            wrongSigner <-
                rootedLifecycleResponseOracleWire
                    94
                    canonicalRootedLifecycleResponseSigningDomain
                    key
                    closeRequest
                    canonicalUnsigned
            verifyWith key closeRequest wrongSigner
                @?= Left HandoffRootedLifecycleSignatureInvalid
            verifyWith otherKey closeRequest canonical
                @?= Left HandoffRootedLifecycleSignatureInvalid
            let changedSignature =
                    ByteString.init canonical
                        <> ByteString.singleton (ByteString.last canonical + 1)
            verifyWith key closeRequest changedSignature
                @?= Left HandoffRootedLifecycleSignatureInvalid

            canonicalFields <- framesOf canonical
            closeFields <- framesOf closeRequest
            let shortSignature =
                    wireWithFrames [(10, ByteString.replicate 63 0)] canonicalFields
                malformedRequest =
                    wireWithFrames [(0, "hostbootstrap/rooted-lifecycle-request/not-v1")] closeFields
                crossRequest =
                    rootedLifecyclePostRequest
                        "close-frame"
                        path
                        session
                        requestStage
                        3
                        otherNonce
                        predecessor
                        Nothing
            traverse_
                (\(label, expected, outcome) -> assertRefused label expected outcome)
                [ ("empty signed response", HandoffBindingMismatch "rooted lifecycle response has no rooted lifecycle response signature",
                    verifyWith key closeRequest ByteString.empty)
                , ("truncated signed response", HandoffBindingMismatch "rooted lifecycle response rooted lifecycle request field is truncated",
                    verifyWith key closeRequest (ByteString.init canonical))
                , ("trailing response frame", HandoffBindingMismatch "rooted lifecycle response has more than eleven rooted lifecycle response fields",
                    verifyWith key closeRequest (canonical <> frameWire "trailing"))
                , ("short response signature", HandoffBindingMismatch "rooted lifecycle response has a rooted lifecycle response signature whose width is not 64 bytes",
                    verifyWith key closeRequest shortSignature)
                , ("malformed exact request", HandoffBindingMismatch "rooted lifecycle response has the wrong lifecycle request domain",
                    verifyWith key malformedRequest canonical)
                , ("cross-request replay", HandoffBindingMismatch "rooted lifecycle response names a different rooted lifecycle request",
                    verifyWith key crossRequest canonical)
                ]

            let malformedUnsigneds =
                    [ (closeRequest, wireWithFrames
                        [(0, "hostbootstrap/rooted-lifecycle-response/not-v1")]
                        (take 10 canonicalFields), HandoffBindingMismatch "rooted lifecycle response has the wrong lifecycle response domain")
                    , (closeRequest, wireWithFrames [(1, lifecycleWordBytesFor 2)] (take 10 canonicalFields),
                        HandoffBindingMismatch "rooted lifecycle response has the wrong lifecycle response version")
                    , (closeRequest, wireWithFrames [(2, "unknown-response")] (take 10 canonicalFields),
                        HandoffBindingMismatch "rooted lifecycle response has an unknown rooted lifecycle response variant or field count")
                    , (nextRequest, rootedLifecyclePostUnsigned
                        "prepared"
                        nextRequest
                        path
                        session
                        responseStage
                        2
                        nonce
                        (renderFrameFields ["node", "dependencies", "operation-gate"]),
                        HandoffBindingMismatch "rooted lifecycle response has fewer than four prepared response fields")
                    , (nextRequest, rootedLifecyclePostUnsigned
                        "refused"
                        nextRequest
                        path
                        session
                        responseStage
                        2
                        nonce
                        ByteString.empty, HandoffBindingMismatch "rooted lifecycle response has an empty refusal detail")
                    ]
            forM_ malformedUnsigneds $ \(request, unsigned, expected) -> do
                signed <- rootedLifecycleResponseOracleWire 93 canonicalRootedLifecycleResponseSigningDomain key request unsigned
                assertRefused "malformed canonical response" expected (verifyWith key request signed)

            let familyCrossPairs =
                    [
                        ( nextRequest
                        , rootedLifecycleOpenedUnsigned
                            nextRequest
                            path
                            session
                            responseStage
                            2
                        )
                    ,
                        ( closeRequest
                        , rootedLifecyclePostUnsigned
                            "prepared"
                            closeRequest
                            path
                            session
                            responseStage
                            4
                            nonce
                            preparedBody
                        )
                    ,
                        ( settleRequest
                        , rootedLifecyclePostUnsigned
                            "descend"
                            settleRequest
                            path
                            session
                            responseStage
                            3
                            nonce
                            "descent"
                        )
                    ,
                        ( nextRequest
                        , rootedLifecyclePostUnsigned
                            "settled"
                            nextRequest
                            path
                            session
                            responseStage
                            2
                            nonce
                            "settled"
                        )
                    ,
                        ( receiptRequest
                        , rootedLifecyclePostUnsigned
                            "frame-complete"
                            receiptRequest
                            path
                            session
                            responseStage
                            5
                            nonce
                            report
                        )
                    ,
                        ( closeRequest
                        , rootedLifecyclePostUnsigned
                            "receipt-recorded"
                            closeRequest
                            path
                            session
                            responseStage
                            4
                            nonce
                            (TextEncoding.encodeUtf8 completion)
                        )
                    ,
                        ( openRequest
                        , rootedLifecyclePostUnsigned
                            "refused"
                            openRequest
                            path
                            session
                            responseStage
                            1
                            nonce
                            "refused"
                        )
                    ]
            familyCrossWires <-
                traverse
                    ( \(request, unsigned) -> do
                        signed <-
                            rootedLifecycleResponseOracleWire
                                93
                                canonicalRootedLifecycleResponseSigningDomain
                                key
                                request
                                unsigned
                        pure (request, signed)
                    )
                    familyCrossPairs
            let familyFailures =
                    HandoffBindingMismatch "rooted lifecycle response opened does not answer this rooted lifecycle request"
                        : replicate 6 (HandoffBindingMismatch "rooted lifecycle response rooted lifecycle response does not answer this request family")
            length familyCrossWires @?= length familyFailures
            forM_ (zip familyFailures familyCrossWires) $ \(expected, (request, signed)) ->
                assertRefused "cross-family response" expected (verifyWith key request signed)

            wrongReceipt <-
                rootedLifecycleResponseOracleWire
                    93
                    canonicalRootedLifecycleResponseSigningDomain
                    key
                    receiptRequest
                    ( rootedLifecyclePostUnsigned
                        "receipt-recorded"
                        receiptRequest
                        path
                        session
                        responseStage
                        5
                        nonce
                        (TextEncoding.encodeUtf8 (childConfigDigest "another completion"))
                    )
            invalidReport <-
                rootedLifecycleResponseOracleWire
                    93
                    canonicalRootedLifecycleResponseSigningDomain
                    key
                    closeRequest
                    ( rootedLifecyclePostUnsigned
                        "frame-complete"
                        closeRequest
                        path
                        session
                        responseStage
                        4
                        nonce
                        "not a canonical lifecycle report"
                    )
            assertRefused
                "receipt body from another FrameComplete"
                (HandoffBindingMismatch "rooted lifecycle response does not name the confirmed frame-complete response")
                (verifyWith key receiptRequest wrongReceipt)
            assertRefused
                "cryptographically valid malformed lifecycle report"
                (HandoffWireTooLarge 0x6e6f742061206361 maxWireBytes)
                (verifyWith key closeRequest invalidReport)

            unsignedFields <- framesOf canonicalUnsigned
            let foreignDigest = childConfigDigest crossRequest
                digestOnly = wireWithFrames [(3, TextEncoding.encodeUtf8 foreignDigest)] unsignedFields
            assertBool "the isolated digest differs from the exact target request"
                (foreignDigest /= childConfigDigest closeRequest)
            -- The signature covers this exact target, while only the response's
            -- digest field names a different request. Its nonce/family still match.
            digestOnlySigned <- rootedLifecycleResponseOracleWire 93
                canonicalRootedLifecycleResponseSigningDomain key closeRequest digestOnly
            assertRefused "a correctly signed response naming only another request digest"
                (HandoffBindingMismatch "rooted lifecycle response names a different rooted lifecycle request")
                (verifyWith key closeRequest digestOnlySigned)

            -- Exercise the actual fixed-domain producer with the existing live
            -- broker/capability before sending its exact refusal table.
            produced <- signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker
                closeRequest canonicalUnsigned >>= expectRight
            let producedWire = renderRootedLifecycleResponse produced
            producedWire @?= canonical
            verifyWith key closeRequest producedWire @?= Right ()
            reportFields <- framesOf report
            let wrongReportDomain = wireWithFrames [(0, "hostbootstrap/lifecycle-report/not-v1")] reportFields
                producerFailures =
                    [ ("unpaired response family",
                        wireWithFrames [(2, "prepared"), (9, preparedBody)] unsignedFields,
                        HandoffBindingMismatch "rooted lifecycle response rooted lifecycle response does not answer this request family")
                    , ("foreign request digest", digestOnly,
                        HandoffBindingMismatch "rooted lifecycle response names a different rooted lifecycle request")
                    , ("otherwise canonical report with the wrong domain",
                        wireWithFrames [(9, wrongReportDomain)] unsignedFields,
                        HandoffBindingMismatch "the lifecycle report domain or version differs")
                    , ("trailing unsigned bytes", canonicalUnsigned <> "!",
                        HandoffBindingMismatch "rooted lifecycle response has more than ten unsigned rooted lifecycle response fields")
                    ]
            forM_ producerFailures $ \(label, unsigned, expected) -> do
                refused <- signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker closeRequest unsigned
                assertRefused ("the actual rooted response signer: " <> label) expected (() <$ refused)
    , testCase "rooted lifecycle response authentication is capability-specialized, ordered, acyclic, and exactly budgeted" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffBytes <- (ByteString.readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            let handoffSource = Text.unpack (TextEncoding.decodeUtf8 handoffBytes)
            (internalSource, _) <- (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Internal")
            (rootedSource, _) <- (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Rooted")
            (protocolSource, _) <- (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Protocol")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            responseFacade <-
                requiredSourceSection
                    "rooted lifecycle response facade"
                    "-- Rooted lifecycle response authentication"
                    "-- Recovery-wire signing"
                    handoffSource
            -- DEVELOPMENT_PLAN/rationale.md#handoff-freezes-cover-owned-declarations
            -- The public binding readers belong to the earlier binding boundary,
            -- independently of this historical response-authentication increment.
            bindingReaders <-
                requiredSourceSection
                    "public handoff-binding readers"
                    "handoffInstalledProject ::"
                    "instance Show (HandoffBinding"
                    handoffSource
            readerDeclarations <- either assertFailure pure (SourceGuard.haskellDefinitionNames bindingReaders)
            let bindingReaderLines = significantHaskellLineCount bindingReaders
            bindingReaderLines @?= 26
            length readerDeclarations @?= 13
            sort readerDeclarations @?= sort
                [ "handoffInstalledProject", "handoffSpecDigest", "handoffPayloadKind", "handoffScope"
                , "handoffStoreIdentity", "handoffPlanRevision", "handoffBrokerGeneration"
                , "handoffParentFrame", "handoffChildFrame", "handoffChildConfigDigest"
                , "handoffVerb", "handoffPhase", "handoffTokenCommitment"
                ]
            handoffExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            internalExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Internal has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Internal" internalSource)
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            let publicHandoff = normalizedModuleExports handoffExports
                privateInternal = normalizedModuleExports internalExports
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
            assertBool
                "the facade exposes only the abstract response, complete renderer, gated signer, and CPS verifier"
                ( all
                    (`elem` publicHandoff)
                    [ "RootedLifecycleResponse"
                    , "renderRootedLifecycleResponse"
                    , "signRootedLifecycleResponseKernel"
                    , "withVerifiedRootedLifecycleResponse"
                    ]
                    && "RootedLifecycleResponse(..)" `notElem` publicHandoff
                )
            traverse_
                ( \identifier ->
                    assertBool
                        (identifier <> " is not a public lifecycle-response authority surface")
                        (identifier `notElem` publicHandoff)
                )
                [ "rootedLifecycleResponseFromUnsignedKernel"
                , "rootedLifecycleResponseSignatureKernel"
                , "renderRootedLifecycleUnsignedResponseKernel"
                , "rootedLifecycleResponseSignedMaterial"
                , "consumeRootedLifecycleResponseSigningKernel"
                , "RecoverySigningKernel"
                ]
            assertFragmentsInOrder
                "the signer strictly consumes the existing specialized capability before live-broker pairing, report validation, fixed signing, and real attachment"
                [ "signRootedLifecycleResponseKernel kernel = kernel `seq` consumeRootedLifecycleResponseSigningKernel kernel sign"
                , "withActiveRootBroker broker"
                , "rootedLifecycleUnsignedPair exactRequest canonicalUnsigned"
                , "validateRootedLifecycleResponseReport report"
                , "Ed25519.sign"
                , "rootedLifecycleResponseSignedMaterial (rootBrokerVerificationKey broker) exactRequest canonicalUnsigned"
                , "Rooted.rootedLifecycleResponseFromUnsignedKernel canonicalUnsigned signature"
                ]
                responseFacade
            assertFragmentsInOrder
                "the verifier canonically decodes and pairs before exact signature verification, report validation, and its fixed fold"
                [ "withVerifiedRootedLifecycleResponse key exactRequest signedWire use = do"
                , "rootedLifecycleRequestFromExactWire exactRequest"
                , "Rooted.rootedLifecycleResponseFromWireKernel signedWire"
                , "Rooted.rootedLifecycleResponsePairKernel (childConfigDigest exactRequest) request response"
                , "verifyRootedLifecycleResponseSignature key exactRequest response"
                , "validateRootedLifecycleResponseReport report"
                , "enterRootedLifecycleResponseFold response use"
                , "Rooted.withRootedLifecycleResponseKernel response opened prepared post post post textPost textPost"
                ]
                responseFacade
            assertFragmentsInOrder
                "the exact transcript fixes domain, installed key digest, complete request, then canonical unsigned response"
                [ "rootedLifecycleResponseSigningDomain = \"hostbootstrap/rooted-lifecycle-response/v1\""
                , "rootedLifecycleResponseSignedMaterial key exactRequest unsigned = ByteString.concat"
                , "frameWire rootedLifecycleResponseSigningDomain"
                , "frameWire (TextEncoding.encodeUtf8 (verificationKeyDigest key))"
                , "frameWire exactRequest"
                , "frameWire unsigned"
                ]
                responseFacade
            assertFragmentsInOrder
                "the verifier validates only FrameComplete's optional report after cryptography"
                [ "verifyRootedLifecycleResponseSignature key exactRequest response"
                , "validateRootedLifecycleResponseReport report"
                , "validateRootedLifecycleResponseReport Nothing = Right ()"
                , "validateRootedLifecycleResponseReport (Just report) = validateLifecycleReport report"
                ]
                responseFacade
            assertContains
                "the facade owns one distinct signature refusal"
                "HandoffRootedLifecycleSignatureInvalid"
                handoffSource
            assertBool
                "the fixed facade adds no named carrier or generic signer"
                ( SourceGuard.countHaskellIdentifier "data" responseFacade == 0
                    && SourceGuard.countHaskellIdentifier "newtype" responseFacade == 0
                    && SourceGuard.countHaskellIdentifier "unsafeCoerce" responseFacade == 0
                    && SourceGuard.countHaskellIdentifier "ProtectedStore" responseFacade == 0
                    && SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" responseFacade == 0
                )
            assertFragmentsInOrder
                "Internal specializes the existing sole capability to only the fixed broker/request/unsigned response shape"
                [ "consumeRootedLifecycleResponseSigningKernel :: RecoverySigningKernel -> (broker -> ByteString -> ByteString -> IO (Either failure RootedLifecycleResponse)) -> broker -> ByteString -> ByteString -> IO (Either failure RootedLifecycleResponse)"
                , "{-# OPAQUE consumeRootedLifecycleResponseSigningKernel #-}"
                , "consumeRootedLifecycleResponseSigningKernel kernel = consumeRecoverySigningKernel kernel"
                ]
                internalSource
            assertBool
                "Internal exports the specialization without exporting a signing-capability constructor"
                ( "consumeRootedLifecycleResponseSigningKernel" `elem` privateInternal
                    && "RecoverySigningKernel" `elem` privateInternal
                    && "RecoverySigningKernel(..)" `notElem` privateInternal
                    && SourceGuard.countHaskellTokenSequence ["data", "RecoverySigningKernel"] internalSource == 1
                    && SourceGuard.countHaskellIdentifier "newtype" internalSource == 0
                )
            importers "HostBootstrap.Handoff.Rooted"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "src/HostBootstrap/Lifecycle/Rooted/Node.hs"
                    ]
            importers "HostBootstrap.Handoff.Internal"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    , "src/HostBootstrap/Handoff/Completion.hs"
                    ]
            users "RootedLifecycleResponse"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    ]
            users "consumeRootedLifecycleResponseSigningKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs"]
            users "signRootedLifecycleResponseKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "withVerifiedRootedLifecycleResponse"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    ]
            assertBool
                "the production DAG is Handoff to Internal to neutral Rooted, never the reverse"
                ( SourceGuard.importsModule "HostBootstrap.Handoff.Internal" handoffSource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Rooted" handoffSource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Rooted" internalSource
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff" internalSource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff" rootedSource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Internal" rootedSource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Rooted" protocolSource)
                )
            assertBool
                "the two hidden owners remain singly registered and have no testing companion"
                ( all (`notElem` exposed) ["HostBootstrap.Handoff.Internal", "HostBootstrap.Handoff.Rooted"]
                    && all
                        (\moduleName -> length (filter (== moduleName) private) == 1)
                        ["HostBootstrap.Handoff.Internal", "HostBootstrap.Handoff.Rooted"]
                    && all
                        (\seam -> not (seam `isInfixOf` cabalSource))
                        [ "HostBootstrap.Handoff.Rooted.Response"
                        , "HostBootstrap.Handoff.Rooted.Testing"
                        , "HostBootstrap.Handoff.Internal.Testing"
                        ]
                )
            -- DEVELOPMENT_PLAN/rationale.md#handoff-freezes-cover-owned-declarations
            -- Captured 2026-11-01 before this adoption: after excluding the 26
            -- binding-reader lines, the shared facade had 3,521 significant lines.
            -- Baselines 3,085/12 and later allowances 30/54/129 yielded the dated
            -- (223, 13, 236) attribution against 240; this was not an owned freeze.
            -- The actual 2026-08-12 landing increment was 139/180 (126 plus 13).
            -- Keep the owned response bytes and independent capability owners live.
            -- Dated pre-policy evidence: the shared Internal owner had 25
            -- significant lines; its unrelated DATA policy is outside this freeze.
            significantHaskellLineCount responseFacade @?= 119
            responseBytes <-
                requiredFrozenSourceSection
                    "rooted lifecycle response authentication bytes"
                    "-- Rooted lifecycle response authentication"
                    "-- Recovery-wire signing"
                    handoffBytes
            ByteString.length responseBytes @?= 6323
            childConfigDigest responseBytes @?= "8017cb84eb922ba3448e54e5fa33ed1d825798089fe7190d52842a0e9827fe69"
            frozenSigningCapabilityDigest internalSource
                >>= (@?= "78fee3610ada63f9c2c38a8a07589c152e9a90824bbf16fed2ce5f5af5001954")
            cabalRows <- handoffPackageRows cabalSource
            cabalRows @?= frozenHandoffPackageRows
    , testCase "rooted relay envelopes are bounded before splitting and match exact authenticated paths" $
        withHandoffPackageRoot $ \packageRoot -> do
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            receiverInternalSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver.Internal")
            envelopeSource <-
                requiredSourceSection
                    "rooted requester envelope"
                    "requesterEnvelopeDomain :: ByteString"
                    "requireServedProvenance ::"
                    relaySource
            boundedFrameSource <-
                requiredSourceSection
                    "bounded requester path frame"
                    "takeRequesterPathFrame ::"
                    "rootedRequestPath ::"
                    relaySource
            assertFragmentsInOrder
                "requester envelopes are non-empty, bounded to 256 UTF-8 components, and reject encoded widths above 4096 before rendering"
                [ "maxRequesterPathDepth = 256"
                , "maxRequesterPathComponentBytes = 4096"
                , "null path"
                , "length path > maxRequesterPathDepth"
                , "any Text.null path"
                , "any ((> maxRequesterPathComponentBytes) . ByteString.length . TextEncoding.encodeUtf8) path"
                , "map (frameWire . TextEncoding.encodeUtf8) path"
                ]
                envelopeSource
            assertFragmentsInOrder
                "declared component width is rejected before the attacker-controlled body is split or decoded"
                [ "ByteString.length raw < 8"
                , "declared > fromIntegral maxRequesterPathComponentBytes"
                , "fromIntegral (ByteString.length body) < declared"
                , "ByteString.splitAt (fromIntegral declared) body"
                ]
                boundedFrameSource
            assertFragmentsInOrder
                "a bounded component is taken before UTF-8 decoding"
                [ "(rawFrame, rest) <- takeRequesterPathFrame remaining"
                , "TextEncoding.decodeUtf8' rawFrame"
                ]
                envelopeSource
            assertFragmentsInOrder
                "the neutral folds expose no OpenFrame ancestry and only structurally paired response paths"
                [ "rootedLifecycleRequestPathKernel raw = do"
                , "Rooted.rootedLifecycleRequestFromWireKernel raw"
                , "(const Nothing)"
                , "rootedLifecycleResponsePairPathKernel exactRequest signedResponse = do"
                , "Rooted.rootedLifecycleResponseFromWireKernel signedResponse"
                , "Rooted.rootedLifecycleResponsePairKernel"
                ]
                receiverInternalSource
            assertFragmentsInOrder
                "root comparison is complete equality while an intermediate comparison is the exact leaf suffix"
                [ "Nothing -> Right ()"
                , "atRoot && complete == envelope"
                , "not atRoot && envelope `isPathSuffixOf` complete"
                , "drop (length complete - length suffix) complete == suffix"
                ]
                envelopeSource
    , testCase "rooted relay alternates one typed singleton exchange and preserves both refusal forms" $
        withHandoffPackageRoot $ \packageRoot -> do
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            brokerFieldSource <-
                requiredSourceSection
                    "rooted BrokerLink raw field"
                    "    , linkRootedLifecycleRaw ::"
                    "    , linkRejectResponse ::"
                    relaySource
            linkConstructionSource <-
                requiredSourceSection
                    "root and relayed rooted link construction"
                    "rootBrokerLink ::"
                    "withConfigBrokerLink ::"
                    relaySource
            requesterSource <-
                requiredSourceSection
                    "typed rooted requester"
                    "receiveRootedLifecycleResponseThroughLink ::"
                    "rootedSigningDomain, rootedSigningVersion ::"
                    relaySource
            routeSource <-
                requiredSourceSection
                    "rooted singleton route"
                    "relayRootedLifecycle ::"
                    "exactLifecycleFrames ::"
                    relaySource
            dispatchSource <-
                requiredSourceSection
                    "admitted serve dispatch"
                    "serveMessage ::"
                    "runLifecycleTerminal ::"
                    relaySource
            serveSource <-
                requiredSourceSection
                    "admitted rooted serve arm"
                    "serveRootedLifecycle ::"
                    "serveOpen ::"
                    relaySource
            let brokerField = normalizeWhitespace brokerFieldSource
                linkConstruction = normalizeWhitespace linkConstructionSource
                requester = normalizeWhitespace requesterSource
                route = normalizeWhitespace routeSource
                dispatch = normalizeWhitespace dispatchSource
            assertContains
                "the hidden raw route distinguishes exact outer refusal fields from signed response bytes"
                "linkRootedLifecycleRaw :: RequesterPath -> ByteString -> IO (Either RelayError (Either (ByteString, ByteString) ByteString))"
                brokerField
            assertContains
                "the only requester returns the abstract typed response, never raw or callback-polymorphic output"
                "receiveRootedLifecycleResponseThroughLink :: ProjectVerificationKey -> BrokerLink scope brokerGeneration -> ByteString -> IO (Either RelayError RootedLifecycleResponse)"
                requester
            assertBool
                "the typed requester has neither a raw ByteString result nor a polymorphic result variable"
                ( not
                    ( "IO (Either RelayError ByteString)" `isInfixOf` requester
                        || "-> result" `isInfixOf` requester
                        || "forall" `isInfixOf` requester
                    )
                )
            assertFragmentsInOrder
                "the root validates exact structure and complete ancestry before its live endpoint runs"
                [ "linkRootedLifecycleRaw = \\path exactRequest -> case rootedRequestPath exactRequest >>= requireRootedRequesterPath True path of"
                , "Left failure -> pure (Left failure)"
                , "Right () -> serveRooted path exactRequest"
                ]
                linkConstructionSource
            assertBool
                "every keyless hop prepends only its verified current frame"
                ( "linkRootedLifecycleRaw = \\downstream exactRequest -> whileReceivedRootedOpen edge (relayRootedLifecycle edge (currentFrame : downstream) exactRequest)"
                    `isInfixOf` linkConstruction
                    && "currentFrame = handoffChildFrame (verifiedHandoffBinding (receivedEdgeHandoff edge))"
                        `isInfixOf` linkConstruction
                )
            assertFragmentsInOrder
                "one rooted request is validated, sent as one field, then synchronously receives one exact paired response"
                [ "rootedRequestPath exactRequest >>= requireRootedRequesterPath False path"
                , "renderRequesterEnvelope path exactRequest"
                , "transmit channel RootedLifecycleRequestTag request [enveloped]"
                , "received <- receive channel"
                , "protocolMessageRequestId message /= request"
                , "protocolMessageTag message == RootedLifecycleResponseTag"
                , "[signedResponse]"
                , "rootedResponsePath exactRequest signedResponse"
                , "pure (Right (Right signedResponse))"
                ]
                routeSource
            assertContains
                "an upstream outer refusal remains the exact two uninterpreted fields"
                "protocolMessageTag message == RefusedTag -> case protocolMessageFields message of [code, detail] -> pure (Right (Left (code, detail)))"
                route
            assertContains
                "only an admitted running child can enter the singleton rooted serve arm"
                "(ParentServingAdmittedChild childFrame, RootedLifecycleRequestTag) -> continueAfter childFrame (serveRootedLifecycle childFrame link channel request message)"
                dispatch
            assertFragmentsInOrder
                "serving validates the admitted child and forwards the exact request and exact signed response bytes"
                [ "[enveloped] -> case parseRequesterEnvelope enveloped"
                , "requireServedProvenance childFrame path"
                , "rootedRequestPath exactRequest >>= requireRootedRequesterPath False path"
                , "linkRootedLifecycleRaw link path exactRequest"
                , "Right (Right signedResponse)"
                , "rootedResponsePath exactRequest signedResponse"
                , "transmit channel RootedLifecycleResponseTag request [signedResponse]"
                ]
                serveSource
            assertFragmentsInOrder
                "serving re-emits upstream outer refusal fields byte-for-byte without translating them"
                [ "Right (Left (code, detail))"
                , "transmit channel RefusedTag request [code, detail]"
                ]
                serveSource
            assertFragmentsInOrder
                "only the originating typed requester verifies signed bytes, so a signed rooted Refused remains a typed response"
                [ "Right (Left (code, detail))"
                , "RelayRefusedByPeer"
                , "Right (Right signedResponse)"
                , "withVerifiedRootedLifecycleResponse key exactRequest signedResponse id"
                , "Right response -> pure (Right response)"
                ]
                requesterSource
    , testCase "rooted relay transport is keyless, acyclic, exactly owned, frozen, and budgeted" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            relayBytes <- (ByteString.readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            let relaySource = Text.unpack (TextEncoding.decodeUtf8 relayBytes)
            (receiverInternalSource, _) <- (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver.Internal")
            (handoffSource, _) <- (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            (handoffInternalSource, _) <- (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Internal")
            recoverySourceDigest <- (frozenSourceDigest =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Recovery")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            rootedTransport <-
                requiredSourceSection
                    "rooted transport-only Relay increment"
                    "receiveRootedLifecycleResponseThroughLink ::"
                    "rootedSigningDomain, rootedSigningVersion ::"
                    relaySource
            rootedRoute <-
                requiredSourceSection
                    "rooted private raw route"
                    "relayRootedLifecycle ::"
                    "exactLifecycleFrames ::"
                    relaySource
            rootedServe <-
                requiredSourceSection
                    "rooted admitted serve route"
                    "serveRootedLifecycle ::"
                    "serveOpen ::"
                    relaySource
            let users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                transportOnly = rootedTransport <> rootedRoute <> rootedServe
            users "rootedLifecycleRequestPathKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    ]
            users "rootedLifecycleResponsePairPathKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    ]
            users "receiveRootedLifecycleResponseThroughLink"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs", "src/HostBootstrap/Command/Child.hs"]
            users "signRootedLifecycleResponseKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "withVerifiedRootedLifecycleResponse"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    ]
            importers "HostBootstrap.Handoff.Rooted"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "src/HostBootstrap/Lifecycle/Rooted/Node.hs"
                    ]
            importers "HostBootstrap.Handoff.Receiver.Internal"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    ]
            traverse_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier transportOnly @?= 0)
                [ "signRootedLifecycleResponseKernel"
                , "RecoverySigningKernel"
                , "RootBroker"
                , "ProtectedStore"
                , "RootedPlanCatalog"
                , "RootedFrameSession"
                , "CommandAuthority"
                , "createProcess"
                , "compareAndSwapProtectedRecord"
                ]
            assertBool
                "the transport increment adds no data, newtype, type synonym, process owner, or generic semantic callback"
                ( SourceGuard.countHaskellIdentifier "data" transportOnly == 0
                    && SourceGuard.countHaskellIdentifier "newtype" transportOnly == 0
                    && SourceGuard.countHaskellIdentifier "type" transportOnly == 0
                    && SourceGuard.countHaskellIdentifier "forall" transportOnly == 0
                    && not ("-> result" `isInfixOf` transportOnly)
                )
            SourceGuard.countHaskellTokenSequence ["System", ".", "Process"] transportOnly @?= 0
            assertBool "neither rooted transport owner imports a process API"
                (not (SourceGuard.importsModule "System.Process" relaySource)
                    && not (SourceGuard.importsModule "System.Process" receiverInternalSource))
            assertFragmentsInOrder "the admitted await classifies only its exact retained channel and request"
                [ "awaitReceived edge expected = do"
                , "receiveControlFrame (receivedEdgeChannel edge)"
                , "classifyAwaited (receivedEdgeRequestId edge) expected received"
                , "Left failure -> refuseReceived edge failure"
                , "Right outcome -> pure outcome"
                ] relaySource
            assertFragmentsInOrder "only a successful actual refusal send stops the retained route while preserving its original error"
                [ "refuseReceived edge failure = mask $ \\_ -> do"
                , "receivedEdgeProgressOpen edge"
                , "transmit (receivedEdgeChannel edge) RefusedTag (receivedEdgeRequestId edge)"
                , "[refusalCode failure, refusalDetail failure]"
                , "Right () -> stopReceivedEdgeAnnouncement edge"
                , "Left _ -> pure ()"
                , "pure (Left failure)"
                ] relaySource
            unchangedTransportSections <-
                traverse
                    (\(opening, closing) -> requiredFrozenSourceSection "unchanged rooted requester and served transport bytes" opening closing relayBytes)
                    [ ("receiveRootedLifecycleResponseThroughLink ::", "rootedSigningDomain, rootedSigningVersion ::")
                    , ("serveRootedLifecycle ::", "serveOpen ::")
                    ]
            -- The middle raw route is this sprint's declared terminal-send fix;
            -- its two unchanged neighbours retain the saved pre-change subject.
            let unchangedTransportBytes = ByteString.concat unchangedTransportSections
            ByteString.length unchangedTransportBytes @?= 4292
            childConfigDigest unchangedTransportBytes @?= "5e88ea61407d69faa7870e6be733169a644987b907ba090d708d6d5f8027591e"
            frozenRootedTransportPathsDigest receiverInternalSource
                >>= (@?= "2c1d3856ecd5b29ec4951c4899f2fa59aa31cde5fcabb314413cbf46f0740ea9")
            recoverySourceDigest @?= "815f5f78ecc803d3749a3aedd3dea52d3e6123a22b059ac1ecce983f6d5453dc"
            frozenSigningCapabilityDigest handoffInternalSource
                >>= (@?= "78fee3610ada63f9c2c38a8a07589c152e9a90824bbf16fed2ce5f5af5001954")
            frozenHandoffDefinitionDigest [ "signRootedLifecycleResponseKernel", "withVerifiedRootedLifecycleResponse" ] handoffSource
                >>= (@?= "d00bda468053456e2c343643f67eb8a57ee5272bd516e2fbbcd1f74a47fdb1ea")
            cabalRows <- handoffPackageRows cabalSource
            cabalRows @?= frozenHandoffPackageRows
    , testCase "recovery child package ownership is bounded, hidden, additive, and exactly attributed" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            recoverySource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Recovery")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            recoveryFacade <-
                requiredSourceSection
                    "recovery child package facade"
                    "-- Canonical recovery child package"
                    "-- Rooted lifecycle response authentication"
                    handoffSource
            recoveryExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Recovery has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Recovery" recoverySource)
            handoffExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            let recovery = normalizeWhitespace recoverySource
                publicHandoff = normalizedModuleExports handoffExports
                importers moduleName =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                recoveryAttribution = significantHaskellLineCount recoverySource
            normalizedModuleExports recoveryExports
                @?= [ "RecoveryChildPackage"
                    , "recoveryChildPackageKernel"
                    , "recoveryChildPackageFromWireKernel"
                    , "renderRecoveryChildPackageKernel"
                    , "withRecoveryChildPackageKernel"
                    ]
            mapM_
                (\identifier -> assertBool (identifier <> " is exposed through the facade") (identifier `elem` publicHandoff))
                [ "RecoveryChildPackage"
                , "renderRecoveryChildPackage"
                , "signRecoveryChildPackageBindingKernel"
                , "withVerifiedRecoveryChildPackage"
                ]
            traverse_
                (\identifier -> assertBool (identifier <> " remains hidden") (identifier `notElem` publicHandoff))
                [ "recoveryChildPackageKernel"
                , "recoveryChildPackageFromWireKernel"
                , "withRecoveryChildPackageKernel"
                ]
            assertContains
                "the package is the sole neutral two-field type"
                "data RecoveryChildPackage = RecoveryChildPackage ByteString ByteString"
                recovery
            SourceGuard.countHaskellTokenSequence ["data", "RecoveryChildPackage"] recoverySource @?= 1
            SourceGuard.countHaskellIdentifier "data" recoverySource @?= 1
            SourceGuard.countHaskellIdentifier "newtype" recoverySource @?= 0
            assertFragmentsInOrder
                "package construction checks both fields and the complete size before constructing"
                [ "not (ByteString.null childConfig)"
                , "not (ByteString.null adapter)"
                , "16 + toInteger (ByteString.length childConfig) + toInteger (ByteString.length adapter) <= toInteger recoveryPackageLimit"
                , "pure (RecoveryChildPackage childConfig adapter)"
                ]
                recoverySource
            assertFragmentsInOrder
                "the decoder bounds raw input and admits exactly two canonical frames"
                [ "fromIntegral (ByteString.length raw) <= recoveryPackageLimit"
                , "(childConfig, afterConfig) <- takeRecoveryFrame raw"
                , "(adapter, trailing) <- takeRecoveryFrame afterConfig"
                , "require (ByteString.null trailing) \"has trailing bytes\""
                , "package <- recoveryChildPackageKernel childConfig adapter"
                , "renderRecoveryChildPackageKernel package == raw"
                ]
                recoverySource
            assertFragmentsInOrder
                "oversized declarations refuse before body splitting"
                [ "ByteString.length raw < 8"
                , "declared > recoveryPackageLimit"
                , "\"contains an oversized field\""
                , "ByteString.splitAt (fromIntegral declared) body"
                ]
                recoverySource
            assertFragmentsInOrder
                "recovery signing derives both claims from one exact package and live broker"
                [ "signRecoveryChildPackageBindingKernel kernel = kernel `seq` consumeRecoverySigningKernel kernel sign"
                , "withActiveRootBroker broker"
                , "case validateRecoveryChildPackageSigning broker offer package of"
                , "Recovery.withRecoveryChildPackageKernel package $ \\childConfig _adapter -> do"
                , "packageBytes = renderRecoveryChildPackage package"
                , "payloadDigest = childConfigDigest packageBytes"
                , "configDigest = childConfigDigest childConfig"
                , "_ <- brokerRelay broker binding"
                , "handoffPayloadKind binding == RecoveryAdapterWire"
                , "offerPayload offer == packageBytes"
                , "handoffChildConfigDigest binding == payloadDigest"
                ]
                recoveryFacade
            assertFragmentsInOrder
                "the package join reverifies the rooted signature before decoding the verified payload"
                [ "withVerifiedRecoveryChildPackage verified suppliedRooted use = do"
                , "withVerifiedRootedPayloadBinding verified (renderRootedPayloadBinding suppliedRooted) id"
                , "packageBytes = verifiedHandoffPayload verified"
                , "handoffPayloadKind binding == RecoveryAdapterWire"
                , "Recovery.recoveryChildPackageFromWireKernel packageBytes"
                , "rootedPayloadDigest rooted == childConfigDigest packageBytes"
                , "rootedChildConfigDigest rooted == childConfigDigest childConfig"
                , "pure (use package childConfig adapter)"
                ]
                recoveryFacade
            assertBool
                "the recovery-package signer is opaque and forces hidden admission"
                ( "{-# OPAQUE signRecoveryChildPackageBindingKernel #-}" `isInfixOf` recoveryFacade
                    && SourceGuard.countHaskellIdentifier "RecoverySigningKernel" recoveryFacade == 1
                    && SourceGuard.countHaskellIdentifier "consumeRecoverySigningKernel" recoveryFacade == 1
                )
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier recoverySource @?= 0)
                [ "Ed25519"
                , "RootBroker"
                , "HandoffBinding"
                , "HandoffError"
                , "ProtectedStore"
                , "Receiver"
                , "Lifecycle"
                , "Command"
                , "Chain"
                , "IO"
                , "unsafeCoerce"
                ]
            mapM_
                ( \moduleName ->
                    assertBool
                        ("the neutral package imports no authority/effect owner " <> moduleName)
                        (not (SourceGuard.importsModule moduleName recoverySource))
                )
                [ "Crypto.PubKey.Ed25519"
                , "HostBootstrap.Authority"
                , "HostBootstrap.Chain"
                , "HostBootstrap.Command"
                , "HostBootstrap.Handoff"
                , "HostBootstrap.Handoff.Internal"
                , "HostBootstrap.Handoff.Receiver"
                , "HostBootstrap.Lifecycle"
                , "HostBootstrap.Protected"
                , "System.IO"
                , "System.Process"
                ]
            importers "HostBootstrap.Handoff.Recovery"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    ]
            users "RecoveryChildPackage"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Recovery.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    ]
            users "signRecoveryChildPackageBindingKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "withVerifiedRecoveryChildPackage"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"]
            length (filter (== "HostBootstrap.Handoff.Recovery") private) @?= 1
            assertBool
                "the recovery codec remains hidden from every exposed library surface"
                ("HostBootstrap.Handoff.Recovery" `notElem` exposed)
            -- The shared facade slice's old line attribution remains dated evidence.
            recoveryDeclarations <- rootedPreservationDeclarations
                [ "renderRecoveryChildPackage"
                , "signRecoveryChildPackageBindingKernel"
                , "withVerifiedRecoveryChildPackage"
                ] handoffSource
            childConfigDigest (LazyByteString.toStrict (Aeson.encode recoveryDeclarations))
                @?= "a6baca281b530a958047e1eca25112d80a729058388b47d0674f9a145abd9451"
            recoveryAttribution @?= 78
    , testCase "authenticated root scope remains nominal, scope-only, and exactly attributed" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            scopeSection <-
                requiredSourceSection
                    "authenticated root scope"
                    "-- Root-authenticated project scope"
                    "{- | The exact tuple a handoff token"
                    handoffSource
            receivedConstructor <-
                requiredSourceSection
                    "private received Harness scope constructor"
                    "    ReceivedHarnessHandoffScope ::"
                    "type role HandoffScope nominal"
                    handoffSource
            handoffExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            let scope = normalizeWhitespace scopeSection
                received = normalizeWhitespace receivedConstructor
                publicHandoff = normalizedModuleExports handoffExports
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                scopeSectionAttribution = significantHaskellLineCount scopeSection
                receivedConstructorAttribution = significantHaskellLineCount receivedConstructor
            traverse_
                (\identifier -> assertBool (identifier <> " is exposed through Handoff") (identifier `elem` publicHandoff))
                [ "AuthenticatedRootScope"
                , "renderAuthenticatedRootScope"
                , "signAuthenticatedRootScopeKernel"
                , "withAuthenticatedRootScopeFromWire"
                ]
            assertBool
                "the authenticated scope constructor remains absent from the public facade"
                ("AuthenticatedRootScope(..)" `notElem` publicHandoff)
            assertContains
                "the sole new type is a nominal opaque capsule"
                "newtype AuthenticatedRootScope scope = AuthenticatedRootScope ByteString type role AuthenticatedRootScope nominal"
                scope
            SourceGuard.countHaskellTokenSequence ["newtype", "AuthenticatedRootScope"] scopeSection @?= 1
            SourceGuard.countHaskellIdentifier "newtype" scopeSection @?= 1
            SourceGuard.countHaskellIdentifier "data" scopeSection @?= 0
            assertFragmentsInOrder
                "the unsigned capsule has exactly six derived fields and the complete wire adds one fixed-width signature"
                [ "authenticatedRootScopeCodecDomain = \"hostbootstrap/authenticated-root-scope\""
                , "authenticatedRootScopeSigningDomain = \"hostbootstrap/authenticated-root-scope/v1\""
                , "authenticatedRootScopeVersion = ByteString.pack (word64BigEndian 1)"
                , "authenticatedRootScopeSignatureBytes = 64"
                , "wire = unsigned <> frameWire signature"
                , "authenticatedRootScopeUnsigned broker scope = do"
                , "let project = TextEncoding.encodeUtf8 (handoffScopeProject scope)"
                , "(kind, run) = authenticatedRootScopeKindAndRun scope"
                , "verificationKeyDigest (rootBrokerVerificationKey broker)"
                , "[ authenticatedRootScopeCodecDomain , authenticatedRootScopeVersion , project , kind , TextEncoding.encodeUtf8 run , keyDigest ]"
                ]
                scopeSection
            assertFragmentsInOrder
                "the producer forces hidden admission and checks the live broker before deriving and signing its exact scope"
                [ "signAuthenticatedRootScopeKernel kernel = kernel `seq` consumeRecoverySigningKernel kernel sign"
                , "sign broker scope = withActiveRootBroker broker"
                , "case authenticatedRootScopeUnsigned broker scope of"
                , "authenticatedRootScopeSignedMaterial keyDigest unsigned"
                , "bounded \"authenticated root scope\" wire"
                ]
                scopeSection
            assertFragmentsInOrder
                "scope signing refuses a project or kind/run relation different from its root broker"
                [ "authenticatedRootScopeUnsigned broker scope = do"
                , "handoffScopeProject scope == brokerProjectName broker"
                , "handoffScopeTag scope == brokerScopeTag broker"
                , "validateAuthenticatedRootScopeKindRun kind run"
                , "bounded \"authenticated root scope unsigned wire\" unsigned"
                ]
                scopeSection
            assertFragmentsInOrder
                "the signed material fixes its own domain, installed-key digest, and canonical unsigned capsule"
                [ "authenticatedRootScopeSignedMaterial keyDigest unsigned = frameWire authenticatedRootScopeSigningDomain"
                , "frameWire keyDigest"
                , "frameWire unsigned"
                ]
                scopeSection
            assertFragmentsInOrder
                "the receiver prebounds raw input and admits exactly seven canonical frames before either callback"
                [ "withAuthenticatedRootScopeFromWire project key raw useProduction useHarness = do"
                , "bounded \"authenticated root scope\" raw"
                , "fields <- takeExactFrames 7 raw"
                , "[domain, version, projectBytes, kind, runBytes, keyDigest, signatureBytes]"
                , "domain == authenticatedRootScopeCodecDomain"
                , "version == authenticatedRootScopeVersion"
                , "projectBytes == installedProject"
                , "keyDigest == installedKeyDigest"
                , "ByteString.length signatureBytes == authenticatedRootScopeSignatureBytes"
                , "canonical == raw"
                , "validateAuthenticatedRootScopeKindRun kind run"
                , "verifyAuthenticatedRootScopeSignature key keyDigest unsigned signatureBytes"
                , "useProduction (AuthenticatedRootScope canonical) (ProductionHandoffScope project)"
                , "useHarness (AuthenticatedRootScope canonical) (ReceivedHarnessHandoffScope project run)"
                ]
                scopeSection
            assertFragmentsInOrder
                "the closed kind/run relation keeps Production empty and Harness canonical and bounded"
                [ "validateAuthenticatedRootScopeKindRun \"production\" run"
                , "Text.null run"
                , "validateAuthenticatedRootScopeKindRun \"harness\" run = do"
                , "not (Text.null run)"
                , "Text.length run <= 48"
                , "Text.all isCanonicalRunCharacter run"
                , "character == '-'"
                , "('a' <= character && character <= 'z')"
                , "('A' <= character && character <= 'Z')"
                , "('0' <= character && character <= '9')"
                ]
                scopeSection
            assertContains
                "the verifier's Harness callback introduces a fresh run identity"
                "( forall runId. AuthenticatedRootScope (Harness projectId runId) -> HandoffScope (Harness projectId runId) -> result )"
                scope
            assertContains
                "received Harness scope evidence retains only installed identity and verified run text"
                "ReceivedHarnessHandoffScope :: InstalledProjectIdentity projectId -> Text -> HandoffScope (Harness projectId runId)"
                received
            SourceGuard.countHaskellIdentifier "HarnessAuthority" receivedConstructor @?= 0
            traverse_
                ( \identifier ->
                    assertBool
                        (identifier <> " is not granted by authenticated scope verification")
                        (SourceGuard.countHaskellIdentifier identifier scopeSection == 0)
                )
                [ "HandoffOffer"
                , "BrokerRelay"
                , "ProtectedStore"
                , "CommandAuthority"
                , "LifecycleCursor"
                , "HarnessAuthority"
                , "unsafeCoerce"
                ]
            users "AuthenticatedRootScope"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    ]
            users "signAuthenticatedRootScopeKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "withAuthenticatedRootScopeFromWire"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"]
            assertBool
                "no separate capsule module or testing signer seam is registered"
                ( not ("HostBootstrap.Handoff.AuthenticatedRootScope" `isInfixOf` cabalSource)
                    && not ("AuthenticatedRootScope.Testing" `isInfixOf` cabalSource)
                )
            scopeSectionAttribution @?= 193
            receivedConstructorAttribution @?= 4
    , testCase "recoverable edge registration is token-gated, durable, and Relay-owned" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            internalSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Internal")
            relaySource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            teardownInternalSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Teardown.Internal")
            kernelSource <-
                requiredSourceSection
                    "recoverable admitted edge kernel"
                    "registerRecoverableAdmittedHandoffEdgeKernel ::"
                    "registerHandoffEdgeActive ::"
                    handoffSource
            identitySource <-
                requiredSourceSection
                    "complete recoverable-open identity"
                    "    recoveryOpenIdentity broker input adapter"
                    "    select session key broker input identity = do"
                    kernelSource
            selectionSource <-
                requiredSourceSection
                    "recoverable-open map selection"
                    "    select session key broker input identity = do"
                    "    publishMap session key broker input identity bytes = do"
                    kernelSource
            publicationSource <-
                requiredSourceSection
                    "recoverable-open map publication"
                    "    publishMap session key broker input identity bytes = do"
                    "    recoveryRecord identity relay token ="
                    kernelSource
            recordSource <-
                requiredSourceSection
                    "complete recoverable-open record"
                    "    recoveryRecord identity relay token ="
                    "    decode broker input identity raw = do"
                    kernelSource
            decodeSource <-
                requiredSourceSection
                    "strict recoverable-open record decoder"
                    "    decode broker input identity raw = do"
                    "    repair session mapKey broker input identity selected@"
                    kernelSource
            repairSource <-
                requiredSourceSection
                    "ordinary token repair and abandoned-transcript rotation"
                    "    repair session mapKey broker input identity selected@"
                    "    verify session mapKey identity mapVersion relay token = do"
                    kernelSource
            verificationSource <-
                requiredSourceSection
                    "recoverable map and token readback"
                    "    verify session mapKey identity mapVersion relay token = do"
                    "    require True = Right ()"
                    kernelSource
            handoffExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            let kernel = normalizeWhitespace kernelSource
                identity = normalizeWhitespace identitySource
                selection = normalizeWhitespace selectionSource
                publication = normalizeWhitespace publicationSource
                record = normalizeWhitespace recordSource
                decoded = normalizeWhitespace decodeSource
                repair = normalizeWhitespace repairSource
                verification = normalizeWhitespace verificationSource
                exports = normalizedModuleExports handoffExports
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                namedDeclarations =
                    [ stripped
                    | sourceLine <- lines kernelSource
                    , let stripped = dropWhile isSpace sourceLine
                    , "data " `isPrefixOf` stripped
                        || "newtype " `isPrefixOf` stripped
                        || "type " `isPrefixOf` stripped
                    ]
            assertBool
                "the strict recoverable kernel is public only through the ordinary Handoff facade"
                ("registerRecoverableAdmittedHandoffEdgeKernel" `elem` exports)
            traverse_
                ( \hidden ->
                    assertBool
                        (hidden <> " remains hidden from the public Handoff facade")
                        (hidden `notElem` exports)
                )
                [ "RecoverySigningKernel"
                , "recoverySigningKernel"
                , "consumeRecoverySigningKernel"
                ]
            namedDeclarations @?= []
            mapM_
                (\(label, fragment, body) -> assertContains label fragment body)
                [
                    ( "the existing hidden capability is the first argument"
                    , "registerRecoverableAdmittedHandoffEdgeKernel :: RecoverySigningKernel -> RootBroker scope brokerGeneration verb"
                    , kernel
                    )
                ,
                    ( "the result is only the ordinary opaque relay and token pair"
                    , "Either rejection (BrokerRelay scope brokerGeneration, HandoffToken)"
                    , kernel
                    )
                ,
                    ( "partial application strictly consumes the hidden capability"
                    , "{-# OPAQUE registerRecoverableAdmittedHandoffEdgeKernel #-} registerRecoverableAdmittedHandoffEdgeKernel kernel = kernel `seq` consumeRecoverySigningKernel kernel recover"
                    , kernel
                    )
                ,
                    ( "the complete identity is bounded before it can name a map key"
                    , "fromIntegral (ByteString.length identity) > maxWireBytes = Left (HandoffWireTooLarge (fromIntegral (ByteString.length identity)) maxWireBytes)"
                    , identity
                    )
                ,
                    ( "the map key is a bounded digest of the complete identity"
                    , "mkRecordKey (\"recovery-open.\" <> sha256Hex identity)"
                    , kernel
                    )
                ,
                    ( "the complete unhashed identity is retained in the map value"
                    , "frameWire identity"
                    , record
                    )
                ,
                    ( "the map value retains the complete canonical binding"
                    , "frameWire (renderHandoffBinding (relayBinding relay))"
                    , record
                    )
                ,
                    ( "the map value retains the exact raw token"
                    , "frameWire (handoffTokenBytes token)"
                    , record
                    )
                ,
                    ( "an existing positive-version map is strictly decoded with its CAS version"
                    , "recordVersionWord (protectedRecordVersion record) < 1 -> pure mapConflict"
                    , selection
                    )
                ,
                    ( "an absent map alone allocates a fresh exact edge choice"
                    , "Right Nothing -> do token <- freshHandoffToken case mkHandoffBinding broker input token >>= brokerRelay broker of"
                    , selection
                    )
                ,
                    ( "map publication is absent-only"
                    , "compareAndSwapProtectedRecord session key ExpectAbsent bytes"
                    , publication
                    )
                ,
                    ( "publication rereads both an exact winner and a concurrent peer"
                    , "_ -> do observed <- readProtectedRecord session key"
                    , publication
                    )
                ,
                    ( "only exact version-one map bytes are admitted after publication"
                    , "recordVersionWord (protectedRecordVersion record) == 1"
                    , publication
                    )
                ,
                    ( "record decoding rejects every trailing byte"
                    , "require (ByteString.null trailing)"
                    , decoded
                    )
                ,
                    ( "record decoding reconstructs the relay from the live broker route and exact input"
                    , "brokerRelayFromRouteWire (rootBrokerRoute broker) (Just input) bindingBytes"
                    , decoded
                    )
                ,
                    ( "record decoding reconstructs the hidden token from stored bytes"
                    , "token <- handoffTokenFromBytes tokenBytes"
                    , decoded
                    )
                ,
                    ( "record decoding rejects a noncanonical binding re-render"
                    , "expected <- mkHandoffBinding broker input token require (renderHandoffBinding expected == bindingBytes)"
                    , decoded
                    )
                ,
                    ( "record decoding rejects a noncanonical complete value re-render"
                    , "require (recoveryRecord identity relay token == raw)"
                    , decoded
                    )
                ,
                    ( "an exact planned token row is retained"
                    , "protectedRecordBytes record == plannedEdgeRecord binding , recordVersionWord (protectedRecordVersion record) == 1 -> pure (Right selected)"
                    , repair
                    )
                ,
                    ( "a granted token remains consumed while its exact map advances to a fresh token"
                    , "\"granted:\" `ByteString.isPrefixOf` protectedRecordBytes record -> rotate session mapKey broker input identity mapVersion"
                    , repair
                    )
                ,
                    ( "a missing token row is recreated as the exact planned edge"
                    , "Right Nothing -> fmap (selected <$) (writeExact session key (plannedEdgeRecord binding) tokenConflict)"
                    , repair
                    )
                ,
                    ( "rotation plans a fresh token before CAS-advancing the exact map"
                    , "planned <- writeExact session tokenKey (plannedEdgeRecord (relayBinding relay)) tokenConflict case planned of Left failure -> pure (Left failure) Right () -> do let bytes = recoveryRecord identity relay token advanced <- compareAndSwapProtectedRecord session mapKey (ExpectVersion mapVersion) bytes"
                    , repair
                    )
                ,
                    ( "verification rereads the exact complete map version before the token"
                    , "checked <- readExact session mapKey mapVersion (recoveryRecord identity relay token) mapReadbackConflict"
                    , verification
                    )
                ,
                    ( "the final token readback retains granted-token refusal"
                    , "\"granted:\" `ByteString.isPrefixOf` protectedRecordBytes record -> Left HandoffTokenConsumed"
                    , verification
                    )
                ]
            assertFragmentsInOrder
                "capability, liveness, structural admission, plan admission, and protected mutation are ordered"
                [ "kernel `seq` consumeRecoverySigningKernel kernel recover"
                , "recover broker admission input adapter = withActiveRootBroker broker"
                , "recoveryOpenIdentity broker input adapter"
                , "admitted <- admission"
                , "Right () -> do entered <- withProtectedEntry"
                , "recoverEdge session broker input identity"
                ]
                kernelSource
            assertFragmentsInOrder
                "the durable map is selected before token repair or rotation and both readbacks"
                [ "selection <- select session mapKey broker input identity"
                , "Right selected"
                , "repaired <- repair session mapKey broker input identity selected"
                , "Right (mapVersion, edge@(relay, token))"
                , "fmap (edge <$) (verify session mapKey identity mapVersion relay token)"
                ]
                kernelSource
            assertFragmentsInOrder
                "the complete identity contains every broker, input, and adapter coordinate"
                [ "frameWire \"hostbootstrap/recovery-open-map\""
                , "word64BigEndian 1"
                , "brokerProjectName broker"
                , "brokerScopeTag broker"
                , "brokerStoreIdentity broker"
                , "brokerEpochValue broker"
                , "brokerVerbName broker"
                , "verificationKeyDigest (rootBrokerVerificationKey broker)"
                , "renderHandoffBindingInput input"
                , "frameWire adapter"
                ]
                identitySource
            assertFragmentsInOrder
                "recovery kind, closed verb, complete coordinates, Teardown, and adapter digest precede identity admission"
                [ "requestedPayloadKind input /= RecoveryAdapterWire"
                , "brokerVerbName broker /= \"down\" && brokerVerbName broker /= \"destroy\""
                , "requestedSpecDigest input"
                , "requestedPlanRevision input"
                , "requestedParentFrame input"
                , "requestedChildFrame input"
                , "requestedPhase input /= \"teardown\""
                , "ByteString.null adapter"
                , "requestedChildConfigDigest input /= childConfigDigest adapter"
                , "ByteString.length identity"
                ]
                identitySource
            assertFragmentsInOrder
                "the record decoder consumes exactly five frames before strict equality checks"
                [ "takeFrame raw"
                , "takeFrame afterDomain"
                , "takeFrame afterVersion"
                , "takeFrame afterIdentity"
                , "takeFrame afterBinding"
                , "domain == \"hostbootstrap/recovery-open-record\""
                , "storedIdentity == identity"
                , "ByteString.null trailing"
                , "renderHandoffBinding expected == bindingBytes"
                , "recoveryRecord identity relay token == raw"
                ]
                decodeSource
            assertFragmentsInOrder
                "token repair CASes only absence and strictly rereads every winner"
                [ "written <- compareAndSwapProtectedRecord session key ExpectAbsent bytes"
                , "Left writeFailure -> readExactInitial session key bytes conflict writeFailure"
                , "recordVersionWord version /= 1"
                , "otherwise -> readExact session key version bytes conflict"
                , "readProtectedRecord session key"
                , "protectedRecordBytes record == bytes"
                ]
                verificationSource
            SourceGuard.countHaskellIdentifier "frameWire" identitySource @?= 10
            SourceGuard.countHaskellIdentifier "frameWire" recordSource @?= 5
            SourceGuard.countHaskellIdentifier "takeFrame" decodeSource @?= 5
            SourceGuard.countHaskellIdentifier "consumeRecoverySigningKernel" kernelSource @?= 1
            SourceGuard.countHaskellIdentifier "withActiveRootBroker" kernelSource @?= 1
            SourceGuard.countHaskellIdentifier "withProtectedEntry" kernelSource @?= 1
            SourceGuard.countHaskellIdentifier "readProtectedRecord" kernelSource @?= 6
            SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" kernelSource @?= 3
            SourceGuard.countHaskellIdentifier "freshHandoffToken" kernelSource @?= 2
            SourceGuard.countHaskellIdentifier "registerHandoffEdgeActive" kernelSource @?= 0
            mapM_
                (\name -> SourceGuard.countHaskellIdentifier name kernelSource @?= 0)
                [ "HandoffOffer"
                , "mkHandoffOffer"
                , "offerHandoffEdge"
                , "grantHandoff"
                , "signRecoveryWireKernel"
                , "signValidatedRecoveryWireActive"
                , "RecoveryWireGrant"
                , "ReverseDescent"
                , "BoundReverseDescent"
                , "LifecycleCompletion"
                , "writeProtocolMessage"
                , "send"
                , "unsafeCoerce"
                , "result"
                ]
            users "registerRecoverableAdmittedHandoffEdgeKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    ]
            SourceGuard.countHaskellIdentifier
                "registerRecoverableAdmittedHandoffEdgeKernel"
                handoffSource
                @?= 4
            SourceGuard.countHaskellIdentifier
                "registerRecoverableAdmittedHandoffEdgeKernel"
                relaySource
                @?= 3
            SourceGuard.countHaskellIdentifier
                "registerRecoverableAdmittedHandoffEdgeKernel"
                teardownInternalSource
                @?= 0
            SourceGuard.countHaskellIdentifier "BoundReverseDescent" handoffSource @?= 0
            SourceGuard.countHaskellIdentifier "BoundReverseDescent" relaySource @?= 0
            SourceGuard.countHaskellIdentifier "BoundReverseDescent" teardownInternalSource @?= 10
            assertBool
                "the public Handoff facade consumes only the existing hidden capability"
                (SourceGuard.importsModule "HostBootstrap.Handoff.Internal" handoffSource)
            SourceGuard.countHaskellIdentifier "RecoverySigningKernel" internalSource @?= 8
            SourceGuard.countHaskellIdentifier "consumeRecoverySigningKernel" internalSource @?= 5
            traverse_
                ( \helper ->
                    assertBool
                        (helper <> " remains local to the guarded kernel")
                        (helper `notElem` exports)
                )
                [ "recoveryOpenIdentity"
                , "select"
                , "publishMap"
                , "recoveryRecord"
                , "decode"
                , "repair"
                , "verify"
                , "writeExact"
                , "readExact"
                , "readToken"
                ]
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            length (filter (== "HostBootstrap.Handoff") exposed) @?= 1
            length (filter (== "HostBootstrap.Handoff.Internal") private) @?= 1
            assertBool
                "the recovery capability module remains hidden"
                ("HostBootstrap.Handoff.Internal" `notElem` exposed)
            traverse_
                ( \seam ->
                    assertBool
                        (seam <> " is absent from Cabal")
                        (seam `notElem` registeredCabalModules cabalSource)
                )
                [ "HostBootstrap.Handoff.RecoveryOpen.Testing"
                , "HostBootstrap.Handoff.Recoverable.Testing"
                , "HostBootstrap.Handoff.TokenRepair.Testing"
                ]
    , testCase "reverse descent attachment is ordered, durable, replayable, and closed" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            protocolSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Protocol")
            teardownSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Teardown")
            teardownInternalSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Teardown.Internal")
            brokerLinkSource <-
                requiredSourceSection
                    "the split BrokerLink open boundary"
                    "data BrokerLink scope brokerGeneration ="
                    "type role BrokerLink nominal nominal"
                    relaySource
            linkConstructionSource <-
                requiredSourceSection
                    "root and relayed BrokerLink construction"
                    "rootBrokerLink ::"
                    "{- | Open a keyless child route only inside the exact config-kind branch."
                    relaySource
            recoverableCodecSource <-
                requiredSourceSection
                    "recoverable-open routing and codec"
                    "relayOpen ::"
                    "adoptOpenedEdge ::"
                    relaySource
            ordinaryOpenSource <-
                requiredSourceSection
                    "the kind-separated ordinary and recoverable openers"
                    "openEdgeThroughLink ::"
                    "{- | Ask this frame's route to the root to authenticate one offer"
                    relaySource
            serveOpenSource <-
                requiredSourceSection
                    "kind-directed open service"
                    "serveOpen ::"
                    "answerOpen ::"
                    relaySource
            offerSource <-
                requiredSourceSection
                    "ordinary and reverse offer flows"
                    "offerHandoffEdge ::"
                    "{- | Build the fourth Offer field from the exact validated offer."
                    relaySource
            reverseOfferSource <-
                requiredSourceSection
                    "the Bound reverse offer boundary"
                    "offerReverseDescentKernel ::"
                    "{- | Build the fourth Offer field from the exact validated offer."
                    relaySource
            offerShapeSource <-
                requiredSourceSection
                    "the four-field offer shape"
                    "offerFieldsOf ::"
                    "offerWireOf ::"
                    relaySource
            familySource <-
                requiredSourceSection
                    "the Prepared and Bound family"
                    "{- | One parent-local reverse descent through its durable lifecycle states."
                    "{- | Prepare one exact root-entry descent, or return its unchanged work."
                    teardownInternalSource
            bindingSource <-
                requiredSourceSection
                    "the live Bound transition"
                    "{- | Bind one prepared descent to the exact recoverably opened offer."
                    "{- | Rehydrate one exact durable Bound descent without opening its token map."
                    teardownInternalSource
            rehydrationSource <-
                requiredSourceSection
                    "the observation-only Bound rehydration"
                    "{- | Rehydrate one exact durable Bound descent without opening its token map."
                    "-- | Revalidate one Bound report coordinate without minting settlement proof."
                    teardownInternalSource
            observationSource <-
                requiredSourceSection
                    "the future Bound observation eliminator"
                    "-- | Verify acknowledged terminal observations without exposing Bound state."
                    "classifyPrepared ::"
                    teardownInternalSource
            recordCodecSource <-
                requiredSourceSection
                    "the canonical Prepared-or-Bound codec"
                    "classifyPrepared ::"
                    "sameCommandAuthority ::"
                    teardownInternalSource
            handoffExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            relayExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Relay has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Relay" relaySource)
            teardownExports <-
                maybe
                    (assertFailure "HostBootstrap.Teardown has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Teardown" teardownSource)
            let brokerLink = normalizeWhitespace brokerLinkSource
                linkConstruction = normalizeWhitespace linkConstructionSource
                recoverableCodec = normalizeWhitespace recoverableCodecSource
                ordinaryOpen = normalizeWhitespace ordinaryOpenSource
                offerShape = normalizeWhitespace offerShapeSource
                family = normalizeWhitespace familySource
                binding = normalizeWhitespace bindingSource
                rehydration = normalizeWhitespace rehydrationSource
                observation = normalizeWhitespace observationSource
                recordCodec = normalizeWhitespace recordCodecSource
                publicHandoff = normalizedModuleExports handoffExports
                privateRelay = normalizedModuleExports relayExports
                publicTeardown = normalizedModuleExports teardownExports
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
            mapM_
                (\(label, fragment, body) -> assertContains label fragment body)
                [
                    ( "BrokerLink keeps ordinary and recoverable opens in distinct fields"
                    , "linkOpenRaw :: RequesterPath -> HandoffBindingInput -> IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken)) , linkRecoverableOpenRaw :: RequesterPath -> HandoffBindingInput -> ByteString -> IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken))"
                    , brokerLink
                    )
                ,
                    ( "the root recoverable field is the sole call to the durable recoverable opener"
                    , "linkRecoverableOpenRaw = \\_ input adapter -> registered <$> registerRecoverableAdmittedHandoffEdgeKernel recoverySigningKernel broker (admits input) input adapter"
                    , linkConstruction
                    )
                ,
                    ( "an intermediate link only forwards the recoverable request"
                    , "linkRecoverableOpenRaw = \\downstream input adapter -> whileReceivedEdgeOpen edge (relayRecoverableOpen edge (currentFrame : downstream) input adapter)"
                    , linkConstruction
                    )
                ,
                    ( "recoverable requests use the existing one-field OfferRequest route"
                    , "sent <- transmit channel OfferRequestTag request [enveloped]"
                    , recoverableCodec
                    )
                ,
                    ( "the recoverable request has one versioned four-frame vocabulary"
                    , "frameWire recoverableOpenDomain <> frameWire recoverableOpenVersion <> frameWire (renderHandoffBindingInput input) <> frameWire adapter"
                    , recoverableCodec
                    )
                ,
                    ( "recoverable decoding is strict, kind-specific, digest-bound, and canonical"
                    , "not (ByteString.null trailing) || requestedPayloadKind input /= RecoveryAdapterWire || requestedChildConfigDigest input /= childConfigDigest adapter || ByteString.null adapter || renderHandoffBindingInput input /= inputBytes || renderRecoverableOpen input adapter /= raw"
                    , recoverableCodec
                    )
                ,
                    ( "ordinary opening accepts only narrowed config"
                    , "requireConfigOpen input | requestedPayloadKind input == NarrowedProjectConfig = Right () | otherwise = requesterMismatch \"ordinary edge opening requires narrowed-project-config\""
                    , ordinaryOpen
                    )
                ,
                    ( "the Bound constructor retains binding bytes and exact durable readback, not a live offer"
                    , "BoundReverseDescent :: ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId -> ByteString -> RecordVersion -> ByteString -> ReverseDescent (HandoffOffer scope brokerGeneration) scope planId parentFrame childFrame brokerGeneration verb descentId"
                    , family
                    )
                ,
                    ( "the hidden capability is the first live-transition argument"
                    , "withBoundReverseDescentKernel :: RecoverySigningKernel -> ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId"
                    , binding
                    )
                ,
                    ( "the live transition strictly consumes the capability"
                    , "{-# OPAQUE withBoundReverseDescentKernel #-} withBoundReverseDescentKernel kernel = kernel `seq` consumeRecoverySigningKernel kernel"
                    , binding
                    )
                ,
                    ( "live replay accepts either its exact v1 row or a canonical v2 Bound row"
                    , "protectedRecordVersion record == version , exactRecord 1 bytes record -> Right () | recordVersionWord (protectedRecordVersion record) >= 2 , Right _ <- parseBoundRecord bytes (protectedRecordBytes record) -> Right ()"
                    , binding
                    )
                ,
                    ( "the Bound CAS consumes only the exact Prepared version"
                    , "compareAndSwapProtectedRecord session key (ExpectVersion preparedVersion) boundBytes"
                    , binding
                    )
                ,
                    ( "the Bound winner is exactly reread at its next version"
                    , "Right (Just record) | recordVersionWord (protectedRecordVersion record) == expectedVersion , protectedRecordBytes record == bytes -> Right (protectedRecordVersion record)"
                    , binding
                    )
                ,
                    ( "the live offer remains lexical beside the binding-only Bound package"
                    , "use (BoundReverseDescent prepared bindingBytes version boundBytes) offer"
                    , binding
                    )
                ,
                    ( "the rehydration capability is strict and first"
                    , "{-# OPAQUE withRehydratedBoundReverseDescentKernel #-} withRehydratedBoundReverseDescentKernel kernel = kernel `seq` consumeRecoverySigningKernel kernel"
                    , rehydration
                    )
                ,
                    ( "rehydration exposes only a fixed-unit Bound callback"
                    , "ReverseDescent (HandoffOffer scope brokerGeneration) scope planId parentFrame childFrame brokerGeneration verb descentId -> IO (Either Text ())"
                    , rehydration
                    )
                ,
                    ( "rehydration accepts only canonical Bound bytes at version two or later"
                    , "recordVersionWord (protectedRecordVersion record) >= 2 -> do binding <- parseBoundRecord expected (protectedRecordBytes record) pure (binding, protectedRecordVersion record, protectedRecordBytes record)"
                    , rehydration
                    )
                ,
                    ( "the future observation fold has a fixed unit result"
                    , "(SubtreeSettled scope planId childFrame verb -> IO (Either Text ())) -> IO (Either Text ())"
                    , observation
                    )
                ,
                    ( "the observation fold requires exact retained Bound version and bytes"
                    , "protectedRecordVersion record == boundVersion , protectedRecordBytes record == boundBytes"
                    , observation
                    )
                ,
                    ( "the Bound codec nests exact Prepared and canonical binding bytes"
                    , "framedText \"hostbootstrap/reverse-descent\" , framedWord 1 , framedText \"bound\" , frameWire prepared , frameWire binding"
                    , recordCodec
                    )
                ,
                    ( "Bound decoding rejects empty binding, trailing bytes, and rerender drift"
                    , "prepared == expected , not (ByteString.null binding) , ByteString.null trailing , raw == renderBoundRecord prepared binding"
                    , recordCodec
                    )
                ]
            assertFragmentsInOrder
                "ordinary root and relayed fields refuse RecoveryAdapterWire before any open"
                [ "linkOpenRaw = \\_ input -> case requireConfigOpen input of"
                , "registerAdmittedHandoffEdge"
                , "linkOpenRaw = \\downstream input -> case requireConfigOpen input of"
                , "relayOpen edge"
                ]
                linkConstructionSource
            assertFragmentsInOrder
                "ordinary offers enforce the embedded payload bound and config kind before fresh opening"
                [ "offerHandoffEdge link channel request input payload terminal = case requireOfferPayloadBound payload >> requireConfigOpen input of"
                , "opened <- openEdgeThroughLink link input"
                ]
                offerSource
            assertFragmentsInOrder
                "service dispatch parses recoverable framing before the ordinary no-fallback branch"
                [ "parseRecoverableOpen raw"
                , "Right (Just (input, adapter))"
                , "linkRecoverableOpenRaw link path input adapter"
                , "Right Nothing"
                , "handoffBindingInputFromWire raw"
                , "requireConfigOpen input"
                , "linkOpenRaw link path input"
                ]
                serveOpenSource
            assertFragmentsInOrder
                "the live attachment reauthorizes and checks before open, then checks again before Bound CAS"
                [ "replayed <- reauthorize"
                , "sameCommandAuthority store retained authority"
                , "checked <- withProtectedEntry store"
                , "validateCurrentLifecycleCursor session cursor"
                , "precheckRecord session key preparedVersion preparedBytes"
                , "case checked of"
                , "Right (Right ())"
                , "opened <- open input package"
                , "validateOffer root verb plan journal input package preparedBytes offer"
                , "entered <- withProtectedEntry store"
                , "validateCurrentLifecycleCursor session cursor"
                , "bindRecord session key preparedVersion preparedBytes boundBytes"
                , "case entered of"
                , "Right (Right version)"
                , "use (BoundReverseDescent prepared bindingBytes version boundBytes) offer"
                ]
                bindingSource
            assertFragmentsInOrder
                "the reverse offer is the durable Bound transition wrapped in transport, never a second edge"
                [ "bound <- withBoundReverseDescentKernel recoverySigningKernel descent open serve"
                , "open input package"
                , "opened <- openRecoverableEdgeThroughLink link input package"
                , "mkHandoffOffer relay package token"
                , "serve bound offer"
                , "offerAuthentication link offer"
                , "transmit channel OfferTag request (offerFieldsOf offer authentication)"
                ]
                reverseOfferSource
            assertContains
                "the reverse opener carries the complete package through the frame's own keyless route"
                "openRecoverableEdgeThroughLink link input package = case requireRecoveryOpen input >> requireOwnFrame link \"recovery parent frame\" (requestedParentFrame input) of Left failure -> pure (Left failure) Right () -> linkRecoverableOpenRaw link [] input package"
                ordinaryOpen
            assertContains
                "recoverable opening accepts only the recovery-adapter-wire kind"
                "requireRecoveryOpen input | requestedPayloadKind input == RecoveryAdapterWire = Right () | otherwise = requesterMismatch \"reverse-descent opening requires recovery-adapter-wire\""
                ordinaryOpen
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier reverseOfferSource @?= 0)
                [ "linkRecoverableOpenRaw"
                , "RootBroker"
                , "ProtectedStore"
                , "renderRecoveryChildPackageKernel"
                , "recoveryChildPackageKernel"
                ]
            assertContains
                "the final Offer retains exactly payload, token, binding, and authentication"
                "offerFieldsOf offer authentication = [payload, token, binding, authentication]"
                offerShape
            assertFragmentsInOrder
                "no-open rehydration reauthorizes, rereads cursor and exact Bound state, unlocks, then calls back"
                [ "replayed <- reauthorize"
                , "sameCommandAuthority store retained authority"
                , "checked <- withProtectedEntry store"
                , "validateCurrentLifecycleCursor session cursor"
                , "readProtectedRecord session key"
                , "rehydrateRecord preparedBytes observed"
                , "case checked of"
                , "Right (Right (bindingBytes, version, boundBytes))"
                , "use (BoundReverseDescent prepared bindingBytes version boundBytes)"
                ]
                rehydrationSource
            assertFragmentsInOrder
                "observation validation remains inside one read-only entry and its callback follows unlock"
                [ "observedBinding /= bindingBytes"
                , "observedVerb /= projectVerbName verb"
                , "checked <- withProtectedEntry store"
                , "validateCurrentLifecycleCursor session cursor"
                , "readProtectedRecord session key"
                , "case checked of"
                , "Right (Right settled) -> use settled"
                ]
                observationSource
            assertFragmentsInOrder
                "exact Bound readback precedes private observation verification"
                [ "protectedRecordVersion record == boundVersion"
                , "protectedRecordBytes record == boundBytes"
                , "verify observations"
                ]
                observationSource
            SourceGuard.countHaskellIdentifier "HandoffToken" familySource @?= 0
            SourceGuard.countHaskellIdentifier "HandoffOffer" familySource @?= 1
            SourceGuard.countHaskellIdentifier "withProtectedEntry" bindingSource @?= 2
            SourceGuard.countHaskellIdentifier "validateCurrentLifecycleCursor" bindingSource @?= 2
            SourceGuard.countHaskellIdentifier "withProtectedEntry" rehydrationSource @?= 2
            SourceGuard.countHaskellIdentifier "validateCurrentLifecycleCursor" rehydrationSource @?= 1
            SourceGuard.countHaskellIdentifier "readProtectedRecord" rehydrationSource @?= 3
            SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" rehydrationSource @?= 1
            SourceGuard.countHaskellIdentifier "withProtectedEntry" observationSource @?= 1
            SourceGuard.countHaskellIdentifier "validateCurrentLifecycleCursor" observationSource @?= 1
            SourceGuard.countHaskellIdentifier "readProtectedRecord" observationSource @?= 1
            SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" observationSource @?= 0
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier rehydrationSource @?= 0)
                [ "registerRecoverableAdmittedHandoffEdgeKernel"
                , "linkRecoverableOpenRaw"
                , "mkHandoffOffer"
                , "HandoffToken"
                , "transmit"
                ]
            SourceGuard.countHaskellTokenSequence ["data", "BoundReverseDescent"] teardownInternalSource @?= 0
            SourceGuard.countHaskellTokenSequence ["newtype", "BoundReverseDescent"] teardownInternalSource @?= 0
            SourceGuard.countHaskellTokenSequence ["type", "BoundReverseDescent"] teardownInternalSource @?= 0
            mapM_
                ( \identifier ->
                    assertBool
                        (identifier <> " is absent from the public facades")
                        (identifier `notElem` publicHandoff && identifier `notElem` publicTeardown)
                )
                [ "ReverseDescent"
                , "BoundReverseDescent"
                , "offerReverseDescentKernel"
                , "withBoundReverseDescentKernel"
                , "withRehydratedBoundReverseDescentKernel"
                , "withRehydratedSettledReverseDescentKernel"
                , "withVerifiedBoundReverseDescentObservationsKernel"
                ]
            assertBool
                "the attachment driver is exported only by the hidden Relay module"
                ("offerReverseDescentKernel" `elem` privateRelay)
            users "registerRecoverableAdmittedHandoffEdgeKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    ]
            users "withBoundReverseDescentKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    ]
            users "withRehydratedBoundReverseDescentKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"]
            users "withRehydratedAdoptedReverseDescentKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    , "src/HostBootstrap/Handoff/Completion.hs"
                    ]
            users "withVerifiedBoundReverseDescentObservationsKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    , "src/HostBootstrap/Handoff/Completion.hs"
                    ]
            users "offerReverseDescentKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Handoff/Process.hs"
                    ]
            importers "HostBootstrap.Teardown.Internal"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Handoff/Completion.hs"
                    , "src/HostBootstrap/Handoff/Process.hs"
                    ]
            importers "HostBootstrap.Handoff.Relay"
                @?= ["src/HostBootstrap/Command/Child.hs", "src/HostBootstrap/Command/LifecycleEntry.hs", "src/HostBootstrap/Handoff/Process.hs"]
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier protocolSource @?= 0)
                [ "BoundReverseDescent"
                , "RecoverableOpenTag"
                , "BoundOfferTag"
                , "ReverseDescentTag"
                ]
            mapM_
                ( \identifier ->
                    assertBool
                        (identifier <> " projection is absent from production")
                        (all (\(_, source) -> SourceGuard.countHaskellIdentifier identifier source == 0) sources)
                )
                [ "boundReverseDescentOffer"
                , "boundReverseDescentToken"
                , "boundReverseDescentBinding"
                , "reverseDescentOffer"
                , "reverseDescentToken"
                ]
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            length (filter (== "HostBootstrap.Handoff.Relay") private) @?= 1
            length (filter (== "HostBootstrap.Teardown.Internal") private) @?= 1
            assertBool "Relay remains hidden" ("HostBootstrap.Handoff.Relay" `notElem` exposed)
            assertBool "Teardown.Internal remains hidden" ("HostBootstrap.Teardown.Internal" `notElem` exposed)
            traverse_
                ( \seam ->
                    assertBool
                        (seam <> " is absent from Cabal")
                        (seam `notElem` registeredCabalModules cabalSource)
                )
                [ "HostBootstrap.Handoff.Completion.Testing"
                , "HostBootstrap.Handoff.Lifecycle.Testing"
                , "HostBootstrap.Handoff.Relay.Testing"
                , "HostBootstrap.Teardown.Internal.Testing"
                , "HostBootstrap.Teardown.ReverseDescent.Testing"
                ]
    , testCase "child report rendering cannot recover root-store cursor authority" $
        withHandoffPackageRoot $ \packageRoot -> do
            -- rationale.md: the root owns durable lifecycle authority; a child
            -- reports through the authenticated rooted terminal receipt.
            sources <- handoffImplementationSources packageRoot
            forM_
                [ "AuthorizedChildCursor"
                , "childCommandReservationKernel"
                , "ChildRecoveryOrigin"
                , "ChildUpLifecycleEntry"
                , "withForwardLifecycleReportKernel"
                , "withReverseLifecycleReportKernel"
                , "withReceivedLifecycleAcknowledgementKernel"
                , "withReceivedRecoveryLifecycleAcknowledgementKernel"
                ]
                $ \name -> do
                    SourceGuard.countHaskellIdentifier name ("data " <> name <> " = Forbidden") @?= 1
                    [ (sourcePath packageRoot path, name)
                      | (path, source) <- sources
                      , SourceGuard.countHaskellIdentifier name source > 0
                      ]
                        @?= []
    , testCase "the hidden handoff modules and sealed folds have exact production owners" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            receiverSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver")
            receiverInternalSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver.Internal")
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            handoffSpecSource <- readFile (packageRoot </> "test" </> "HandoffSpec.hs")
            relayExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Relay has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Relay" relaySource)
            brokerLink <-
                requiredSourceSection
                    "private BrokerLink representation"
                    "data BrokerLink scope brokerGeneration ="
                    "type role BrokerLink nominal nominal"
                    relaySource
            let importers moduleName =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
            importers "HostBootstrap.Handoff.Internal"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    , "src/HostBootstrap/Handoff/Completion.hs"
                    ]
            importers "HostBootstrap.Handoff.Protocol"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Handoff/Process.hs"
                    , "src/HostBootstrap/Handoff/Transaction.hs"
                    ]
            importers "HostBootstrap.Handoff.Rooted"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "src/HostBootstrap/Lifecycle/Rooted/Node.hs"
                    ]
            importers "HostBootstrap.Handoff.Recovery"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    ]
            importers "HostBootstrap.Handoff.Receiver"
                @?= ["src/HostBootstrap/Command/Child.hs"]
            importers "HostBootstrap.Handoff.Receiver.Internal"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    ]
            importers "HostBootstrap.Handoff.Relay"
                @?= ["src/HostBootstrap/Command/Child.hs", "src/HostBootstrap/Command/LifecycleEntry.hs", "src/HostBootstrap/Handoff/Process.hs"]
            users "signRecoveryWireKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "signRootedPayloadBindingKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "signRecoveryChildPackageBindingKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "withVerifiedRootedPayloadBinding"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"]
            users "withVerifiedRecoveryChildPackage"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"]
            users "recoverySigningKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    , "src/HostBootstrap/Handoff/Completion.hs"
                    ]
            users "consumeRecoverySigningKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    ]
            users "withReceivedHandoffEdge"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"]
            users "mkReceivedEdge"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    ]
            users "mkReceivedRecoveryDescent"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    ]
            users "withReceivedRecoveryDescent"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    ]
            users "withConfigBrokerLink"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "withRecoveryBrokerLink"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "relayedBrokerLinkKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "offerHandoffEdge"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Handoff/Process.hs"
                    ]
            users "offerReverseDescentKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Handoff/Process.hs"
                    ]
            sort (normalizedModuleExports relayExports)
                @?= sort
                    [ "BrokerLink"
                    , "persistRootedLifecycleCompletionKernel"
                    , "publishRootedLifecycleReportKernel"
                    , "rootBrokerLink"
                    , "rootForwardBrokerLink"
                    , "rootReverseBrokerLink"
                    , "withConfigBrokerLink"
                    , "withRecoveryBrokerLink"
                    , "withNestedRecursiveHandoffRuntimeKernel"
                    , "receiveRootedLifecycleResponseThroughLink"
                    , "prepareLifecycleAcknowledgementThroughLink"
                    , "adoptLifecycleAcknowledgementThroughLink"
                    , "offerHandoffEdge"
                    , "offerReverseDescentKernel"
                    , "withRootedOpenedResponseKernel"
                    , "withRootedPreparedResponseKernel"
                    , "withRootedPostOpenResponseKernel"
                    , "withRootedTerminalReceiptKernel"
                    , "withProviderDependencyReprobeServiceKernel"
                    , "withProviderDependencyReprobeEndpointKernel"
                    , "linkSignActivation"
                    , "EdgeAdmission"
                    , "RecoveryAdmission"
                    , "RelayError(..)"
                    , "relayErrorMessage"
                    , "renderLifecycleAcknowledgementResponse"
                    , "withLifecycleAcknowledgementResponse"
                    ]
            traverse_
                ( \identifier -> do
                    assertBool
                        (identifier <> " is module-private")
                        (identifier `notElem` relayExports)
                    SourceGuard.countHaskellIdentifier identifier relaySource @?= 3
                )
                [ "openEdgeThroughLink"
                , "openRecoverableEdgeThroughLink"
                , "grantThroughLink"
                , "signRecoveryThroughLink"
                , "withSignedRecoveryThroughLink"
                ]
            sort (filter ("HostBootstrap.Handoff." `isPrefixOf`) (SourceGuard.haskellImports handoffSource))
                @?= [ "HostBootstrap.Handoff.Internal"
                    , "HostBootstrap.Handoff.Recovery"
                    , "HostBootstrap.Handoff.Recovery"
                    , "HostBootstrap.Handoff.Rooted"
                    , "HostBootstrap.Handoff.Rooted"
                    ]
            SourceGuard.countHaskellTokenSequence
                ["module", "HostBootstrap", ".", "Handoff", ".", "Protocol"]
                handoffSource
                @?= 0
            SourceGuard.countHaskellIdentifier "ReceiverExpectation" receiverSource @?= 0
            SourceGuard.countHaskellIdentifier "relayedBrokerLink" relaySource @?= 0
            SourceGuard.countHaskellIdentifier "unsafeCoerce" receiverSource @?= 0
            SourceGuard.countHaskellIdentifier "unsafeCoerce" receiverInternalSource @?= 0
            SourceGuard.countHaskellIdentifier "unsafeCoerce" relaySource @?= 0
            assertBool
                "the hidden signing capability is not retained in BrokerLink"
                (SourceGuard.countHaskellIdentifier "RecoverySigningKernel" brokerLink == 0)
            assertContains
                "BrokerLink nominal roles"
                "type role BrokerLink nominal nominal"
                (normalizeWhitespace relaySource)
            traverse_
                ( \moduleName ->
                    assertBool
                        ("HandoffSpec does not import " <> moduleName)
                        (not (SourceGuard.importsModule moduleName handoffSpecSource))
                )
                [ "HostBootstrap.Handoff.Completion"
                , "HostBootstrap.Handoff.Receiver.Internal"
                ]
    , testCase "received packages and branch-specific relay links remain closed" $
        withHandoffPackageRoot $ \packageRoot -> do
            receiverSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver")
            receiverInternalSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver.Internal")
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            receivedEdge <-
                requiredSourceSection
                    "payload-neutral received edge"
                    "data ReceivedEdge scope"
                    "{- | One exact recovery-kind edge"
                    receiverInternalSource
            recoveryDescent <-
                requiredSourceSection
                    "sealed received recovery descent"
                    "data\n    ReceivedRecoveryDescent"
                    "type role ReceivedRecoveryDescent"
                    receiverInternalSource
            receiverFold <-
                requiredSourceSection
                    "closed receiver fold signature"
                    "withReceivedHandoffEdge ::"
                    "withReceivedHandoffEdge\n    project\n    channel\n    key"
                    receiverSource
            recoveryFold <-
                requiredSourceSection
                    "closed recovery descent fold signature"
                    "withReceivedRecoveryDescent ::"
                    "withReceivedRecoveryDescent\n    (ReceivedRecoveryDescent"
                    receiverInternalSource
            configLink <-
                requiredSourceSection
                    "config-specific relay link bracket"
                    "withConfigBrokerLink ::"
                    "withRecoveryBrokerLink ::"
                    relaySource
            recoveryLink <-
                requiredSourceSection
                    "recovery-specific relay link bracket"
                    "withRecoveryBrokerLink ::"
                    "linkSignActivation ::"
                    relaySource
            SourceGuard.countHaskellIdentifier "AuthenticatedConfigPayload" receivedEdge @?= 0
            SourceGuard.countHaskellIdentifier "ByteString" receivedEdge @?= 0
            assertContains "the received edge shares the receiver's exact private progress"
                "receivedProgress :: IORef (Word64, Maybe ChildProtocolState)"
                (normalizeWhitespace receivedEdge)
            SourceGuard.countHaskellIdentifier "ReceivedEdge" recoveryDescent @?= 1
            SourceGuard.countHaskellIdentifier "RootedPayloadBinding" recoveryDescent @?= 1
            SourceGuard.countHaskellIdentifier "RecoveryChildPackage" recoveryDescent @?= 1
            SourceGuard.countHaskellIdentifier "RecoveryProjectionBinding" recoveryDescent @?= 1
            SourceGuard.countHaskellIdentifier "RecoveryWireGrant" recoveryDescent @?= 1
            SourceGuard.countHaskellIdentifier "VerifiedRecoveryWire" recoveryDescent @?= 1
            SourceGuard.countHaskellIdentifier "VerifiedRecoveryHandoff" recoveryDescent @?= 0
            SourceGuard.countHaskellIdentifier "ProjectVerb" recoveryDescent @?= 1
            SourceGuard.countHaskellIdentifier "ByteString" recoveryDescent @?= 0
            assertContains
                "ReceivedEdge nominal roles"
                "type role ReceivedEdge nominal nominal"
                (normalizeWhitespace receiverInternalSource)
            assertContains
                "ReceivedRecoveryDescent nominal roles"
                "type role ReceivedRecoveryDescent nominal nominal nominal nominal nominal nominal nominal nominal"
                (normalizeWhitespace receiverInternalSource)
            SourceGuard.countHaskellIdentifier "result" receiverFold @?= 0
            assertContains
                "config callback has a fixed unit result"
                "AuthenticatedConfigPayload (Production projectId) receivedGeneration -> (ByteString -> IO (Either ReceiverError ())) -> IO (Either Text ())"
                (normalizeWhitespace receiverFold)
            assertContains
                "the Harness config callback has its own fixed unit result"
                "AuthenticatedConfigPayload (Harness projectId runId) receivedGeneration -> (ByteString -> IO (Either ReceiverError ())) -> IO (Either Text ())"
                (normalizeWhitespace receiverFold)
            assertContains
                "recovery callback has a fixed unit result"
                "recoveryWireDigest recoveryWireId verb -> (ByteString -> IO (Either ReceiverError ())) -> IO (Either Text ())"
                (normalizeWhitespace receiverFold)
            assertBool
                "the receiver itself has a fixed unit result"
                (SourceGuard.haskellTokens ") -> IO (Either ReceiverError ())"
                    `isSuffixOf` SourceGuard.haskellTokens receiverFold)
            SourceGuard.countHaskellIdentifier "result" recoveryFold @?= 0
            assertContains
                "the internal recovery callback derives four fixed raw views from retained values"
                "ReceivedEdge scope brokerGeneration -> ByteString -> ProjectVerb verb -> ByteString -> ByteString -> ByteString -> IO (Either Text ())"
                (normalizeWhitespace recoveryFold)
            assertBool
                "the internal recovery fold has a fixed unit result"
                (SourceGuard.haskellTokens ") -> IO (Either Text ())"
                    `isSuffixOf` SourceGuard.haskellTokens recoveryFold)
            assertFragmentsInOrder
                "the config bracket re-derives config evidence before deriving its link"
                [ "verifiedConfigPayload (receivedEdgeHandoff edge)"
                , "authenticated `seq` use authenticated (relayedBrokerLinkKernel edge)"
                ]
                configLink
            SourceGuard.countHaskellIdentifier "result" configLink @?= 0
            assertFragmentsInOrder
                "the recovery bracket consumes the joint package before deriving its link"
                [ "withReceivedRecoveryDescent descent"
                , "use descent (relayedBrokerLinkKernel edge)"
                ]
                recoveryLink
            SourceGuard.countHaskellIdentifier "result" recoveryLink @?= 0
    , testCase "Relay authenticates an opened four-field offer before transmission" $
        withHandoffPackageRoot $ \packageRoot -> do
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            offerFlow <-
                requiredSourceSection
                    "validated offer transmission"
                    "offerHandoffEdge ::"
                    "offerAuthentication ::"
                    relaySource
            offerAuthenticationSource <-
                requiredSourceSection
                    "kind-specific offer authentication"
                    "offerAuthentication ::"
                    "awaitChallenge ::"
                    relaySource
            offerShape <-
                requiredSourceSection
                    "four-field offer shape"
                    "offerFieldsOf ::"
                    "offerWireOf ::"
                    relaySource
            parentAcceptance <-
                requiredSourceSection
                    "parent payload-digest acceptance"
                    "serveMessage ::"
                    "serveOpen ::"
                    relaySource
            assertFragmentsInOrder
                "edge opening, offer validation, recovery pre-signing, and transmission stay ordered"
                [ "opened <- openEdgeThroughLink link input"
                , "mkHandoffOffer relay payload token"
                , "authenticated <- offerAuthentication link offer"
                , "transmit channel OfferTag request (offerFieldsOf offer authentication)"
                ]
                offerFlow
            assertContains
                "the wire protocol keeps exactly four Offer fields"
                "offerFieldsOf offer authentication = [payload, token, binding, authentication]"
                (normalizeWhitespace offerShape)
            assertFragmentsInOrder
                "config evidence is the root-scope, installed key, and exact rooted binding"
                [ "rootedResult <- rootedBindingThroughLink link offer"
                , "Right rooted -> case handoffPayloadKind binding of"
                , "NarrowedProjectConfig -> pure (Right (authenticationPrelude <> frameWire rooted))"
                , "authenticationPrelude ="
                , "frameWire (renderAuthenticatedRootScope (linkAuthenticatedRootScope link))"
                , "frameWire (linkKeyDigest link)"
                ]
                offerAuthenticationSource
            assertFragmentsInOrder
                "recovery coordinates and verb come only from the validated binding"
                [ "(\"down\", \"teardown\") -> recoveryAuthentication rooted ProjectDown"
                , "(\"destroy\", \"teardown\") -> recoveryAuthentication rooted ProjectDestroy"
                , "Recovery.recoveryChildPackageFromWireKernel payload"
                , "Recovery.withRecoveryChildPackageKernel package"
                , "withRecoveryProjectionBindingInput"
                , "handoffPlanRevision binding"
                , "handoffParentFrame binding"
                , "handoffChildFrame binding"
                , "withSignedRecoveryThroughLink verb link input adapter"
                ]
                offerAuthenticationSource
            assertFragmentsInOrder
                "recovery evidence frames the key, rooted binding, canonical projection, and grant"
                [ "frameWire (linkKeyDigest link)"
                , "frameWire rooted"
                , "frameWire (renderRecoveryProjectionBinding projection)"
                , "frameWire (recoveryWireGrantSignature grant)"
                ]
                offerAuthenticationSource
            SourceGuard.countHaskellIdentifier "frameWire" offerAuthenticationSource @?= 6
            SourceGuard.countHaskellIdentifier "withSignedRecoveryThroughLink" offerAuthenticationSource @?= 1
            assertFragmentsInOrder
                "the parent advances only on the exact accepted payload digest"
                [ "[actualDigest]"
                , "actualDigest == expectedDigest"
                , "serveUntilDone (ParentServingAdmittedChild childFrame)"
                , "\"the child accepted a different payload digest\""
                ]
                parentAcceptance
    , testCase "the child process owner spawns one sanitized route and leaves nothing running" $
        withHandoffPackageRoot $ \packageRoot -> do
            processSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Process")
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            routeSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Process.Route")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            processExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Process has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Process" processSource)
            let owner = normalizeWhitespace processSource
                relay = normalizeWhitespace relaySource
                route = normalizeWhitespace routeSource
            normalizedModuleExports processExports
                @?= [ "withForwardLifecycleChildProcess"
                    , "withProviderDependencyForwardLifecycleChildProcess"
                    , "withCarriedProviderDependencyForwardLifecycleChildProcess"
                    , "seedProviderDependencyCarrierKernel"
                    , "withCarriedProviderDependencyFromCarrierKernel"
                    , "withPreparedReverseLifecycleChildProcess"
                    , "withReverseLifecycleChildProcess"
                    ]
            assertBool
                "the process owner stays Cabal-private without an exposed row"
                ( "HostBootstrap.Handoff.Process" `notElem` exposed
                    && length (filter (== "HostBootstrap.Handoff.Process") private) == 1
                )
            assertBool
                "the process owner introduces no named type"
                ( SourceGuard.countHaskellIdentifier "data" processSource == 0
                    && SourceGuard.countHaskellIdentifier "newtype" processSource == 0
                )
            assertContains
                "a forward edge is completed through the fixed forward kernel and no caller callback"
                "withLifecycleChild config route $ \\channel -> offerHandoffEdge link channel request input payload $ \\offer report persist -> withAcknowledgedForwardLifecycleCompletionKernel offer report persist $ \\_ -> pure (Right ())"
                owner
            assertContains
                "a reverse edge is completed through the fixed reverse kernel and carries no payload argument"
                "withLifecycleChild config route $ \\channel -> offerReverseDescentKernel link channel request descent $ \\bound report persist -> withAcknowledgedBoundReverseLifecycleCompletionKernel bound report persist $ \\_ -> pure (Right ())"
                owner
            assertFragmentsInOrder
                "the route's own launch is the only thing spawned, and only at an absolute resolved path"
                [ "withLifecycleProcessRouteLaunchKernel route $ \\tool argv _interactivity -> do"
                , "resolved <- resolveInstalled config tool"
                , "case resolved of"
                , "\"the route's host tool resolves to no absolute path\""
                , "Just exe -> spawned (absExePath exe) (hostToolProcessArguments tool exe (map Text.unpack argv))"
                ]
                processSource
            assertContains
                "one process shape exists: private pipes, inherited diagnostics, and its own group"
                "childProcess executable arguments = (proc executable arguments) { std_in = CreatePipe , std_out = CreatePipe , std_err = Inherit , create_group = True , close_fds = True }"
                owner
            assertContains
                "the launch is bounded because a child that never speaks is indistinguishable from one that never started"
                "opened <- timeout launchMicros (handoffChannel childStdout childStdin)"
                owner
            assertBool
                "the launch bound is the owner's only deadline, so admitted work keeps its own policy"
                (SourceGuard.countHaskellIdentifier "timeout" processSource == 2)
            assertFragmentsInOrder
                "the group is terminated, graced, escalated, reaped unconditionally, and only then are the pipes closed"
                [ "askChildGroupToStop group"
                , "ended <- awaitChildGroupExit terminationGraceMicros group"
                , "if ended then pure () else killChildGroup group"
                , "Exception.try (waitForProcess child)"
                , "closeQuietly childStdin"
                , "closeQuietly childStdout"
                ]
                processSource
            -- The escalation's ordering is the owner's, above; its two platform
            -- rows are the shared child-group module's. Both transports that end
            -- a child group carried byte-identical copies of those rows and of
            -- the three timeouts beside them, so this guard now reads the one
            -- implementation rather than asserting the same property twice about
            -- two copies that were free to drift apart.
            childGroupSource <-
                readFile
                    ( packageRoot
                        </> "internal"
                        </> "effect"
                        </> "HostBootstrap"
                        </> "Effect"
                        </> "ChildGroup.hs"
                    )
            let childGroup = normalizeWhitespace childGroupSource
            assertContains
                "the whole group is signalled rather than the process alone"
                "signalChildGroup (ChildGroup _ processGroup) signal = do signalled <- Exception.try (signalProcessGroup signal processGroup)"
                childGroup
            assertFragmentsInOrder
                "the POSIX owner captures identity before polling and observes only the retained group"
                [ "(process{create_group = True})"
                , "identity <- getPid child"
                , "Just pid -> pure (ChildGroup child (fromIntegral pid))"
                , "stop `Exception.finally` finishRemaining"
                , "present <- posixGroupPresent group"
                , "if present then killAndObserve else pure ()"
                , "askChildGroupToStop group = signalChildGroup group sigTERM"
                , "killChildGroup group = signalChildGroup group sigKILL"
                , "signalProcessGroup signal processGroup"
                , "Left failure | isDoesNotExistError failure -> pure ()"
                , "Left failure -> Exception.throwIO failure"
                , "posixGroupPresent (ChildGroup _ processGroup) = do"
                , "signalProcessGroup nullSignal processGroup"
                , "Left failure | isDoesNotExistError failure -> pure False"
                , "Left failure -> Exception.throwIO failure"
                , "pure (ended && not present)"
                ]
                childGroupSource
            case SourceGuard.haskellDefinitionClauseTokens "captureChildGroup" childGroupSource of
                Left failure -> assertFailure failure
                Right capturedGroupClauses -> do
                    let capturedGroupTokens = concat capturedGroupClauses
                    length (filter (== "getPid") capturedGroupTokens) @?= 1
                    length (filter (== "getProcessExitCode") capturedGroupTokens) @?= 0
            assertFragmentsInOrder
                "the Windows row retains and ends the exact acquired job independently of leader polling"
                [ "withChildGroupProcess process use = Exception.mask"
                , "withCreateProcess"
                , "(process{use_process_jobs = True})"
                , "Exception.bracket (captureChildGroup child) releaseChildGroup"
                , "OpenExtHandle leader job -> pure (OpenHandle leader, ChildGroup child leader job)"
                , "releaseChildGroup group@(ChildGroup _ _ job) = Exception.mask_"
                , "killChildGroup group"
                , "awaitChildGroupExit terminationGraceMicros group"
                , "closePHANDLE job"
                , "askChildGroupToStop = terminateWindowsGroup"
                , "killChildGroup = terminateWindowsGroup"
                , "terminateWindowsGroup (ChildGroup _ leader job) ="
                , "terminateJobUnsafe (OpenExtHandle leader job) 1"
                ]
                childGroupSource
            assertContains
                "termination runs on every exit from the exchange"
                "Exception.bracket_ (pure ()) (terminateChildGroup group child childStdin childStdout) (exchange childStdin childStdout serve)"
                owner
            assertFragmentsInOrder
                "authenticated provider seeding transfers ownership without claiming the parent settlement"
                [ "Right package | Dependency.runtimeDependencyPackageDomain package `notElem` [\"provider\", \"provider-share\"]"
                , "pushCarriedResource carrier ( mintTransferredCarriedResource (Dependency.runtimeDependencyPackageResource package) (Dependency.runtimeDependencyPackageGeneration package) 1 (Dependency.runtimeDependencyPackageResource package) )"
                , "registerStepRuntimeDependencyPackage runtime package"
                ]
                processSource
            SourceGuard.countHaskellIdentifier "mintSettledCarriedResource" processSource @?= 0
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier processSource @?= 0)
                [ "ProtectedStore"
                , "RecordKey"
                , "RootBroker"
                , "ProjectSigningKey"
                , "withReceivedHandoffEdge"
                , "stdioHandoffChannel"
                , "RootedPlanCatalog"
                , "FrameExecutor"
                , "unsafeCoerce"
                ]
            assertContains
                "the relay bounds a frame the peer owes immediately"
                "receiveControlFrame channel = do answered <- timeout controlFrameMicros (receive channel) pure (maybe (Left RelayControlFrameTimeout) id answered)"
                relay
            assertContains
                "the challenge is a control frame"
                "await channel request expected = do received <- receiveControlFrame channel"
                relay
            assertContains
                "admission is bounded and the wait for admitted work is not"
                "next <- case state of ParentAwaitingAcceptance _ _ -> receiveControlFrame channel ParentServingAdmittedChild _ -> receive channel"
                relay
            assertContains
                "the launch a route renders is the only thing an owner may spawn"
                "withLifecycleProcessRouteLaunchKernel route use = case route of LifecycleProcessRoute _ _ _ tool argv interactivity -> use tool argv interactivity"
                route
            assertBool
                "the process owner and the route stay inside their sprint line budgets"
                ( significantHaskellLineCount processSource < 400
                    && significantHaskellLineCount routeSource < 400
                )
    , testCase "the dedicated child receiver takes its protocol descriptors before any callback runs" $
        withHandoffPackageRoot $ \packageRoot -> do
            receiverSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver")
            protocolSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Protocol")
            transactionSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Transaction")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            isolationSource <-
                requiredSourceSection
                    "the protocol standard-I/O isolation"
                    "withPrivateProtocolStdio ::"
                    "-- | Read one complete message from the channel's inbound stream."
                    protocolSource
            entryIsolationSource <-
                requiredSourceSection
                    "the receiver's adoption of that isolation"
                    "withIsolatedReceivedHandoffEdge ::"
                    "{- | Run the child half of one handoff exchange"
                    receiverSource
            protocolExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Protocol has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Protocol" protocolSource)
            entrySignature <-
                requiredSourceSection
                    "the dedicated entry signature"
                    "withIsolatedReceivedHandoffEdge ::"
                    "withIsolatedReceivedHandoffEdge\n    project\n    key"
                    receiverSource
            receiverExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Receiver has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Receiver" receiverSource)
            let isolation = normalizeWhitespace isolationSource
                entryIsolation = normalizeWhitespace entryIsolationSource
            normalizedModuleExports receiverExports
                @?= [ "ReceivedEdge"
                    , "ReceivedRecoveryDescent"
                    , "withIsolatedReceivedHandoffEdge"
                    , "withReceivedHandoffEdge"
                    , "withProviderDependencyClientKernel"
                    , "ReceiverError(..)"
                    , "receiverErrorMessage"
                    ]
            assertBool
                "the receiver stays Cabal-private without a new module row"
                ( "HostBootstrap.Handoff.Receiver" `notElem` exposed
                    && length (filter (== "HostBootstrap.Handoff.Receiver") private) == 1
                )
            assertBool
                "the dedicated entry accepts no channel and no handle"
                ( not ("HandoffChannel" `isInfixOf` entrySignature)
                    && not ("Handle" `isInfixOf` entrySignature)
                )
            assertContains
                "the dedicated entry runs the ordinary exchange on the channel the one owner built"
                "withPrivateProtocolStdio $ \\channel -> withReceivedHandoffEdge project channel key"
                entryIsolation
            assertContains
                "one outer bracket owns the duplicates and one inner bracket owns the redirection"
                "bracket openProtocolStdio closeProtocolStdio $ \\(inbound, outbound, savedIn, savedOut, sink) -> bracket_ (isolateGlobalStdio savedIn savedOut sink) (restoreGlobalStdio savedIn savedOut) (handoffChannel inbound outbound >>= use)"
                isolation
            assertFragmentsInOrder
                "the protocol pair, the restore pair, and the sink are taken before any redirection"
                [ "openProtocolStdio = do"
                , "hFlush stdout"
                , "inbound <- hDuplicate stdin"
                , "outbound <- hDuplicate stdout"
                , "savedIn <- hDuplicate stdin"
                , "savedOut <- hDuplicate stdout"
                , "sink <- openFile nullDevicePath ReadMode"
                ]
                isolationSource
            assertContains
                "the callback reads the null device and writes to standard error"
                "isolateGlobalStdio savedIn savedOut sink = do hFlush stdout hDuplicateTo sink stdin `onException` restoreGlobalStdio savedIn savedOut hDuplicateTo stderr stdout `onException` restoreGlobalStdio savedIn savedOut"
                isolation
            assertContains
                "restoration attempts both handles regardless of either"
                "restoreGlobalStdio savedIn savedOut = do flushQuietly stdout restoreQuietly savedIn stdin restoreQuietly savedOut stdout"
                isolation
            assertContains
                "every duplicate the bracket opened is closed and nothing global is"
                "closeProtocolStdio (inbound, outbound, savedIn, savedOut, sink) = mapM_ closeQuietly [inbound, outbound, savedIn, savedOut, sink]"
                isolation
            assertContains
                "the null device is chosen by host rather than probed"
                "nullDevicePath | os == \"mingw32\""
                isolation
            assertContains
                "the POSIX null device is the default"
                "otherwise = \"/dev/null\""
                isolation
            assertBool
                "the standard-I/O isolation introduces no named type"
                ( SourceGuard.countHaskellIdentifier "data" isolationSource == 0
                    && SourceGuard.countHaskellIdentifier "newtype" isolationSource == 0
                    && SourceGuard.countHaskellIdentifier "type" isolationSource == 0
                )
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier receiverSource @?= 0)
                [ "stdioHandoffChannel"
                , "hIsTerminalDevice"
                , "hGetEcho"
                , "fdToHandle"
                , "handleToFd"
                , "hSetFileSize"
                , "lookupEnv"
                , "getEnvironment"
                , "createProcess"
                , "ProcessHandle"
                , "unsafeCoerce"
                ]
            assertBool
                "the receiver builds no channel of its own and reaches the isolation once"
                ( SourceGuard.countHaskellIdentifier "handoffChannel" receiverSource == 0
                    && SourceGuard.countHaskellIdentifier "withPrivateProtocolStdio" receiverSource == 2
                )
            assertBool
                "the frame-child entry reaches the same isolation once and builds no channel of its own"
                ( SourceGuard.countHaskellIdentifier "withPrivateProtocolStdio" transactionSource == 2
                    && SourceGuard.countHaskellIdentifier "hDuplicate" transactionSource == 0
                    && SourceGuard.countHaskellIdentifier "hDuplicateTo" transactionSource == 0
                    && SourceGuard.countHaskellIdentifier "stdioHandoffChannel" transactionSource == 0
                )
            assertBool
                "the isolation itself is the one entry the owner publishes"
                ("withPrivateProtocolStdio" `elem` normalizedModuleExports protocolExports)
            mapM_
                ( \identifier ->
                    assertBool
                        (identifier <> " stays private to the isolation's owner")
                        (identifier `notElem` normalizedModuleExports protocolExports)
                )
                [ "openProtocolStdio"
                , "closeProtocolStdio"
                , "isolateGlobalStdio"
                , "restoreGlobalStdio"
                , "nullDevicePath"
                ]
            mapM_
                ( \identifier ->
                    assertBool
                        (identifier <> " has exactly one implementation, in the isolation's owner")
                        (SourceGuard.countHaskellIdentifier identifier receiverSource == 0)
                )
                [ "openProtocolStdio"
                , "closeProtocolStdio"
                , "isolateGlobalStdio"
                , "restoreGlobalStdio"
                , "nullDevicePath"
                ]
            traverse_
                ( \seam ->
                    assertBool
                        (seam <> " is absent from Cabal")
                        (seam `notElem` registeredCabalModules cabalSource)
                )
                [ "HostBootstrap.Handoff.Receiver.Testing"
                , "HostBootstrap.Handoff.Process.Testing"
                ]
            assertBool
                "the standard-I/O isolation stays inside its 400-line budget"
                (significantHaskellLineCount isolationSource <= 400)
    , testCase "Receiver verifies, classifies exhaustively, accepts, and only then enters a branch" $
        withHandoffPackageRoot $ \packageRoot -> do
            receiverSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver")
            exchangeSource <-
                requiredSourceSection
                    "ordinary verification and callback ordering"
                    "withReceivedHandoffEdge ::"
                    "-- Message shapes"
                    receiverSource
            offerParser <-
                requiredSourceSection
                    "unconditional Offer authentication parsing"
                    "offerFields ::"
                    "grantFields ::"
                    receiverSource
            classification <-
                requiredSourceSection
                    "authenticated payload classification"
                    "classifyVerified ::"
                    "configEvidence ::"
                    receiverSource
            recoveryParser <-
                requiredSourceSection
                    "exact recovery evidence parser"
                    "recoveryEvidence ::"
                    "-- Sequenced transport"
                    receiverSource
            assertFragmentsInOrder
                "ordinary challenge verification precedes classification and Accepted precedes callback entry"
                [ "checkScope scope binding"
                , "challenge <- liftAttempt freshChallenge"
                , "sendMessage active channel afterOffer ChallengeTag"
                , "requireInstalledKey key signerKeyDigest"
                , "verifyHandoff key"
                , "classifyVerified authenticated channel requestId active key evidence verified"
                , "sendMessage active channel afterGrant AcceptedTag"
                , "[TextEncoding.encodeUtf8 acceptedDigest]"
                , "try (runTerminalAction channel afterAccepted requestId active branch)"
                ]
                exchangeSource
            assertContains
                "Offer remains an exact four-field message"
                "[payload, token, binding, authentication]"
                (normalizeWhitespace offerParser)
            SourceGuard.countHaskellIdentifier "takeHandoffFrame" offerParser @?= 0
            assertContains
                "the outer parser leaves authentication opaque"
                "pure (payload, token, binding, authentication)"
                (normalizeWhitespace offerParser)
            let normalizedClassification = normalizeWhitespace classification
            assertFragmentsInOrder
                "authenticated config admits only one exact rooted frame before config refinement"
                [ "case handoffPayloadKind binding of"
                , "NarrowedProjectConfig -> do"
                , "rootedBytes <- configEvidence evidence"
                , "withVerifiedRootedPayloadBinding verified rootedBytes id"
                , "verifiedConfigPayload verified"
                , "authenticatedConfigDigest admitted"
                , "useConfig edge admitted sendReport"
                , "RecoveryAdapterWire ->"
                ]
                classification
            SourceGuard.countHaskellIdentifier "verifiedConfigPayload" classification @?= 1
            SourceGuard.countHaskellIdentifier "liftAttempt" classification @?= 0
            assertFragmentsInOrder
                "recovery classification fixes verb/phase and joins the rooted package before adapter evidence"
                [ "(\"down\", \"teardown\") -> classifyRecovery ProjectDown"
                , "(\"destroy\", \"teardown\") -> classifyRecovery ProjectDestroy"
                , "(rootedBytes, projectionBytes, signature) <- recoveryEvidence evidence"
                , "withVerifiedRootedPayloadBinding verified rootedBytes"
                , "withVerifiedRecoveryChildPackage verified rooted"
                , "withRecoveryProjectionBindingInput"
                , "handoffPlanRevision binding"
                , "handoffParentFrame binding"
                , "handoffChildFrame binding"
                , "mkRecoveryProjectionBindingFromRoute verb"
                , "verifiedHandoffRoute verified"
                , "adapter"
                , "renderRecoveryProjectionBinding projection /= projectionBytes"
                , "recoveryWireGrantFromSignature projection signature"
                , "withVerifiedRecoveryWire key projection adapter grant"
                , "mkReceivedRecoveryDescent edge rooted package verb projection grant wire"
                , "useRecovery descent sendReport"
                ]
                classification
            assertContains
                "recovery acceptance names the authenticated payload digest"
                "handoffChildConfigDigest binding"
                normalizedClassification
            SourceGuard.countHaskellIdentifier "NarrowedProjectConfig" classification @?= 1
            SourceGuard.countHaskellIdentifier "RecoveryAdapterWire" classification @?= 1
            assertFragmentsInOrder
                "recovery evidence is exactly rooted, projection, and grant frames with no trailing bytes"
                [ "takeHandoffFrame evidence"
                , "takeHandoffFrame afterRooted"
                , "takeHandoffFrame afterProjection"
                , "ByteString.null trailing"
                , "pure (rooted, projection, signature)"
                ]
                recoveryParser
    , testCase "Relay owns one root-issued scope prelude and preserves it through every keyless link" $
        withHandoffPackageRoot $ \packageRoot -> do
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            receiverInternalSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver.Internal")
            brokerLink <-
                requiredSourceSection
                    "scope-retaining BrokerLink"
                    "data BrokerLink scope brokerGeneration ="
                    "type role BrokerLink nominal nominal"
                    relaySource
            linkConstruction <-
                requiredSourceSection
                    "root and relayed scope ownership"
                    "rootBrokerLink ::"
                    "{- | Open a keyless child route only inside the exact config-kind branch."
                    relaySource
            offerAuthenticationSource <-
                requiredSourceSection
                    "scope-first Offer authentication"
                    "offerAuthentication ::"
                    "awaitChallenge ::"
                    relaySource
            receivedEdge <-
                requiredSourceSection
                    "scope-retaining received edge"
                    "data ReceivedEdge scope"
                    "{- | One exact recovery-kind edge"
                    receiverInternalSource
            let link = normalizeWhitespace brokerLink
            assertContains
                "BrokerLink retains the typed root-issued capsule"
                "linkAuthenticatedRootScope :: AuthenticatedRootScope scope"
                link
            assertFragmentsInOrder
                "the root link signs its matching live scope before construction and stores only that result"
                [ "rootBrokerLink broker scope activation admits admitsRecovery serveRooted = do"
                , "signAuthenticatedRootScopeKernel recoverySigningKernel broker scope"
                , "rootScope <- either (Left . RelayHandoffFailure) Right authenticated"
                , "linkAuthenticatedRootScope = rootScope"
                ]
                linkConstruction
            assertFragmentsInOrder
                "a relayed link copies the capsule retained by its authenticated parent edge"
                [ "relayedBrokerLinkKernel edge = BrokerLink"
                , "linkAuthenticatedRootScope = receivedEdgeAuthenticatedRootScope edge"
                ]
                linkConstruction
            assertFragmentsInOrder
                "every Offer authentication field starts with capsule then installed-key digest"
                [ "authenticationPrelude ="
                , "frameWire (renderAuthenticatedRootScope (linkAuthenticatedRootScope link))"
                , "frameWire (linkKeyDigest link)"
                , "authenticationPrelude <> frameWire rooted"
                , "frameWire (renderRecoveryProjectionBinding projection)"
                , "frameWire (recoveryWireGrantSignature grant)"
                ]
                offerAuthenticationSource
            assertFragmentsInOrder
                "ReceivedEdge retains the same typed capsule beside the verified edge"
                [ "receivedRootScope :: AuthenticatedRootScope scope"
                , "receivedHandoff :: VerifiedHandoff scope brokerGeneration"
                , "receivedEdgeAuthenticatedRootScope ::"
                , "receivedEdgeAuthenticatedRootScope = receivedRootScope"
                , "mkReceivedEdge :: AuthenticatedRootScope scope -> VerifiedHandoff scope brokerGeneration"
                ]
                receivedEdge
            SourceGuard.countHaskellIdentifier "signAuthenticatedRootScopeKernel" linkConstruction @?= 3
            SourceGuard.countHaskellIdentifier "ProjectSigningKey" relaySource @?= 0
            SourceGuard.countHaskellIdentifier "RecoverySigningKernel" brokerLink @?= 0
    , testCase "Receiver verifies the leading scope capsule before any binding, challenge, or payload semantics" $
        withHandoffPackageRoot $ \packageRoot -> do
            receiverSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver")
            receiverSignature <-
                requiredSourceSection
                    "closed four-arm scope-first receiver signature"
                    "withReceivedHandoffEdge ::"
                    "withReceivedHandoffEdge\n    project\n    channel\n    key"
                    receiverSource
            outerExchange <-
                requiredSourceSection
                    "scope-first outer exchange"
                    "withReceivedHandoffEdge\n    project\n    channel\n    key"
                    "-- | Continue only after the capsule verifier has fixed the execution scope."
                    receiverSource
            scopedExchange <-
                requiredSourceSection
                    "post-scope semantic exchange"
                    "receiveScopedHandoffEdge ::"
                    "runTerminalAction ::"
                    receiverSource
            offerParser <-
                requiredSourceSection
                    "opaque four-field Offer parser"
                    "offerFields ::"
                    "grantFields ::"
                    receiverSource
            let parser = normalizeWhitespace offerParser
            assertFragmentsInOrder
                "the hidden API accepts installed identity and key and exposes four closed branches"
                [ "InstalledProjectIdentity projectId"
                , "ProjectVerificationKey"
                , "ReceivedEdge (Production projectId) receivedGeneration"
                , "ReceivedRecoveryDescent (Production projectId) receivedGeneration"
                , "forall runId receivedGeneration. ReceivedEdge (Harness projectId runId) receivedGeneration"
                , "forall runId receivedGeneration planDigest parentFrame childFrame recoveryWireDigest recoveryWireId verb. ReceivedRecoveryDescent (Harness projectId runId)"
                ]
                receiverSignature
            SourceGuard.countHaskellIdentifier "HandoffScope" receiverSignature @?= 0
            assertContains
                "Protocol leaves the unchanged four Offer fields opaque"
                "[payload, token, binding, authentication] -> pure (payload, token, binding, authentication)"
                parser
            SourceGuard.countHaskellIdentifier "takeHandoffFrame" offerParser @?= 0
            assertFragmentsInOrder
                "only the leading capsule is opened before the closed Production/Harness verifier fold"
                [ "(payload, token, bindingBytes, authentication) <- offerFields offer"
                , "(scopeWire, authenticationRemainder) <- fromHandoff (takeHandoffFrame authentication)"
                , "withAuthenticatedRootScopeFromWire project key scopeWire"
                , "receiveScopedHandoffEdge authenticated scope channel key"
                ]
                outerExchange
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier outerExchange @?= 0)
                [ "withHandoffBindingFromWire"
                , "freshChallenge"
                , "verifyHandoff"
                , "classifyVerified"
                , "handoffPayloadKind"
                , "verifiedConfigPayload"
                ]
            assertFragmentsInOrder
                "binding, challenge, grant, and branch semantics occur only inside the verified scope"
                [ "takeHandoffFrame authentication"
                , "requireInstalledKey key offeredKeyDigest"
                , "withHandoffBindingFromWire scope bindingBytes"
                , "checkScope scope binding"
                , "freshChallenge"
                , "requireInstalledKey key signerKeyDigest"
                , "verifyHandoff key"
                , "classifyVerified authenticated channel requestId active key evidence verified"
                ]
                scopedExchange
    , testCase "scope-first transport remains acyclic and leaves Protocol and facade frozen" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            (handoffSource, _) <-
                (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            (protocolSource, _) <-
                (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Protocol")
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            receiverSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver")
            receiverInternalSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver.Internal")
            cabalRows <- handoffPackageRows =<< readFile (packageRoot </> "hostbootstrap-core.cabal")
            let users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
            assertBool
                "the private scope-first dependency graph is one-way"
                ( SourceGuard.importsModule "HostBootstrap.Handoff" relaySource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Protocol" relaySource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Receiver.Internal" relaySource
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Receiver" relaySource)
                    && SourceGuard.importsModule "HostBootstrap.Handoff" receiverSource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Protocol" receiverSource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Receiver.Internal" receiverSource
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Relay" receiverSource)
                    && SourceGuard.importsModule "HostBootstrap.Handoff" receiverInternalSource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Protocol" receiverInternalSource
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Relay" protocolSource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Receiver" protocolSource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Relay" handoffSource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Receiver" handoffSource)
                )
            users "AuthenticatedRootScope"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Lifecycle/FrameExecutor.hs"
                    ]
            users "signAuthenticatedRootScopeKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "withAuthenticatedRootScopeFromWire"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"]
            users "receivedEdgeAuthenticatedRootScope"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    ]
            frozenHandoffDefinitionDigest [ "signAuthenticatedRootScopeKernel", "withAuthenticatedRootScopeFromWire" ] handoffSource
                >>= (@?= "621e82df4064acb7a5d6cffd852c253626da4626003754613c4a7217f0d7b037")
            cabalRows @?= frozenHandoffPackageRows
            mapM_
                ( \source -> do
                    SourceGuard.countHaskellTokenSequence ["data", "AuthenticatedRootScope"] source @?= 0
                    SourceGuard.countHaskellTokenSequence ["newtype", "AuthenticatedRootScope"] source @?= 0
                )
                [relaySource, receiverSource, receiverInternalSource, protocolSource]
    , testCase "rooted signing stays live at the root, canonical through relays, and shapes both Offer branches" $
        withHandoffPackageRoot $ \packageRoot -> do
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            brokerLink <-
                requiredSourceSection
                    "rooted-signing BrokerLink route"
                    "data BrokerLink scope brokerGeneration ="
                    "type role BrokerLink nominal nominal"
                    relaySource
            linkConstruction <-
                requiredSourceSection
                    "root and relayed rooted-signing routes"
                    "rootBrokerLink ::"
                    "{- | Open a keyless child route only inside the exact config-kind branch."
                    relaySource
            rootedRoute <-
                requiredSourceSection
                    "canonical rooted signing route"
                    "rootedSigningDomain, rootedSigningVersion :: ByteString"
                    "{- | Route the exact first acknowledgement stage"
                    relaySource
            dispatch <-
                requiredSourceSection
                    "multiplexed rooted signing dispatch"
                    "serveRecoverySigning ::"
                    "{- | Rebuild the offer and challenge a relayed request describes."
                    relaySource
            authentication <-
                requiredSourceSection
                    "rooted Offer authentication"
                    "offerAuthentication ::"
                    "awaitChallenge ::"
                    relaySource
            let broker = normalizeWhitespace brokerLink
            assertContains
                "BrokerLink retains an exact-offer rooted-signing route, not a signer"
                "linkRootedBindingRaw :: RequesterPath -> HandoffOffer scope brokerGeneration -> IO (Either RelayError ByteString)"
                broker
            SourceGuard.countHaskellIdentifier "RecoverySigningKernel" brokerLink @?= 0
            assertFragmentsInOrder
                "only the root route reaches the live rooted signer while relayed links forward"
                [ "linkRootedBindingRaw = \\_ -> rootSignRootedBinding broker"
                , "relayedBrokerLinkKernel edge = BrokerLink"
                , "linkRootedBindingRaw = \\downstream offer -> whileReceivedEdgeOpen edge (relayRootedBinding edge (currentFrame : downstream) offer)"
                ]
                linkConstruction
            assertFragmentsInOrder
                "the strict root route derives config or recovery-package signing from the exact offer"
                [ "rootSignRootedBinding broker offer = case handoffPayloadKind (handoffOfferBinding offer) of"
                , "NarrowedProjectConfig -> renderSigned (signRootedPayloadBindingKernel recoverySigningKernel broker offer payload)"
                , "RecoveryAdapterWire -> case Recovery.recoveryChildPackageFromWireKernel payload of"
                , "signRecoveryChildPackageBindingKernel recoverySigningKernel broker offer package"
                , "Right . renderRootedPayloadBinding"
                ]
                rootedRoute
            assertFragmentsInOrder
                "a keyless route sends one closed three-frame header and the exact offer through the existing tags"
                [ "frameWire rootedSigningDomain"
                , "frameWire rootedSigningVersion"
                , "frameWire (rootedSigningKindName (handoffPayloadKind (handoffOfferBinding offer)))"
                , "renderRequesterEnvelope path (renderRootedSigningHeader offer)"
                , "transmit channel RecoveryRequestTag request [enveloped, offerWireOf offer]"
                , "awaitReceived edge RecoveryResponseTag"
                , "Right [rooted] -> pure (Right rooted)"
                ]
                rootedRoute
            assertFragmentsInOrder
                "each serving parent re-adopts and kind-checks the exact offer before forwarding"
                [ "rootedSigningKind requestHeader"
                , "adoptRelayedOffer (linkRoute link) wire"
                , "handoffPayloadKind (handoffOfferBinding offer) /= kind"
                , "requireServedRequester childFrame (handoffParentFrame (handoffOfferBinding offer)) path"
                , "linkRootedBindingRaw link path offer"
                , "transmit channel RecoveryResponseTag request [response]"
                ]
                dispatch
            assertFragmentsInOrder
                "rooted signing follows exact Offer construction and config emits capsule, key, rooted binding"
                [ "rootedResult <- rootedBindingThroughLink link offer"
                , "Right rooted -> case handoffPayloadKind binding of"
                , "NarrowedProjectConfig -> pure (Right (authenticationPrelude <> frameWire rooted))"
                , "frameWire (renderAuthenticatedRootScope (linkAuthenticatedRootScope link))"
                , "frameWire (linkKeyDigest link)"
                ]
                authentication
            assertFragmentsInOrder
                "recovery emits capsule, key, rooted binding, projection, then grant"
                [ "authenticationPrelude <> frameWire rooted"
                , "frameWire (renderRecoveryProjectionBinding projection)"
                , "frameWire (recoveryWireGrantSignature grant)"
                ]
                authentication
            SourceGuard.countHaskellIdentifier "frameWire" authentication @?= 6
            SourceGuard.countHaskellIdentifier "ProjectSigningKey" relaySource @?= 0
    , testCase "Receiver joins rooted config and complete recovery packages before callbacks and refuses adapter-only descent" $
        withHandoffPackageRoot $ \packageRoot -> do
            receiverSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver")
            receiverInternalSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver.Internal")
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            classification <-
                requiredSourceSection
                    "rooted receiver classification"
                    "classifyVerified ::"
                    "configEvidence ::"
                    receiverSource
            evidenceParsers <-
                requiredSourceSection
                    "closed rooted evidence parsers"
                    "configEvidence ::"
                    "-- Sequenced transport"
                    receiverSource
            carrier <-
                requiredSourceSection
                    "typed rooted recovery carrier"
                    "data\n    ReceivedRecoveryDescent"
                    "type role ReceivedRecoveryDescent"
                    receiverInternalSource
            adapterOnly <-
                requiredSourceSection
                    "the package-valued reverse route"
                    "offerReverseDescentKernel ::"
                    "offerAuthentication ::"
                    relaySource
            let eliminated = normalizeWhitespace receiverInternalSource
                refused = normalizeWhitespace adapterOnly
            assertFragmentsInOrder
                "config admits one exact rooted frame before deriving config evidence or entering its callback"
                [ "NarrowedProjectConfig -> do"
                , "rootedBytes <- configEvidence evidence"
                , "withVerifiedRootedPayloadBinding verified rootedBytes id"
                , "verifiedConfigPayload verified"
                , "authenticatedConfigDigest admitted"
                , "mkReceivedEdge authenticated verified channel requestId active"
                , "useConfig edge admitted sendReport"
                ]
                classification
            assertFragmentsInOrder
                "recovery verifies the rooted binding, package membership, adapter grant, and wire before callback construction"
                [ "(rootedBytes, projectionBytes, signature) <- recoveryEvidence evidence"
                , "withVerifiedRootedPayloadBinding verified rootedBytes"
                , "withVerifiedRecoveryChildPackage verified rooted"
                , "\\package _childConfig adapter ->"
                , "mkRecoveryProjectionBindingFromRoute verb (verifiedHandoffRoute verified) input adapter"
                , "recoveryWireGrantFromSignature projection signature"
                , "withVerifiedRecoveryWire key projection adapter grant"
                , "mkReceivedRecoveryDescent edge rooted package verb projection grant wire"
                , "useRecovery descent sendReport"
                ]
                classification
            SourceGuard.countHaskellIdentifier "withVerifiedRecoveryHandoff" classification @?= 0
            assertFragmentsInOrder
                "config and recovery evidence have exact one- and three-frame cardinalities"
                [ "configEvidence evidence = do"
                , "(rooted, trailing) <- fromHandoff (takeHandoffFrame evidence)"
                , "ByteString.null trailing"
                , "then pure rooted"
                , "recoveryEvidence evidence = do"
                , "(rooted, afterRooted) <- fromHandoff (takeHandoffFrame evidence)"
                , "(projection, afterProjection) <- fromHandoff (takeHandoffFrame afterRooted)"
                , "(signature, trailing) <- fromHandoff (takeHandoffFrame afterProjection)"
                , "ByteString.null trailing"
                , "pure (rooted, projection, signature)"
                ]
                evidenceParsers
            assertFragmentsInOrder
                "the carrier retains only the typed rooted/package/projection/grant/wire DAG"
                [ "ReceivedEdge scope brokerGeneration"
                , "RootedPayloadBinding scope brokerGeneration"
                , "RecoveryChildPackage"
                , "ProjectVerb verb"
                , "RecoveryProjectionBinding"
                , "RecoveryWireGrant"
                , "VerifiedRecoveryWire"
                ]
                carrier
            SourceGuard.countHaskellIdentifier "ByteString" carrier @?= 0
            SourceGuard.countHaskellIdentifier "VerifiedRecoveryHandoff" carrier @?= 0
            assertContains
                "the six-argument eliminator exposes retained edge and verb plus derived bytes, while forcing rather than exposing the rooted proof"
                "`seq` use edge (renderRecoveryChildPackage package) verb (verifiedRecoveryWireBytes wire) (renderRecoveryProjectionBinding projection) (recoveryWireGrantSignature grant)"
                eliminated
            assertContains
                "the reverse route transmits only the package the durable Bound transition supplies"
                "open input package = case requireOfferPayloadBound package of"
                refused
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier adapterOnly @?= 0)
                [ "linkRecoverableOpenRaw"
                , "RootBroker"
                , "ProtectedStore"
                , "renderRecoveryChildPackageKernel"
                , "recoveryChildPackageKernel"
                ]
    , testCase "rooted carrier adoption is bounded, acyclic, exactly attributed, and freezes shared surfaces" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            (handoffSource, _) <- (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            (protocolSource, _) <-
                (readFrozenSource =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Protocol")
            recoverySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Recovery")
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            receiverSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver")
            receiverInternalSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Receiver.Internal")
            cabalRows <- handoffPackageRows =<< readFile (packageRoot </> "hostbootstrap-core.cabal")
            offerBound <-
                requiredSourceSection
                    "sender-side Offer payload bound"
                    "maxEmbeddedOfferPayloadBytes :: Int"
                    "awaitChallenge ::"
                    relaySource
            receiveBound <-
                requiredSourceSection
                    "receiver-side Offer payload bound"
                    "receiveScopedHandoffEdge ::"
                    "grantFields ::"
                    receiverSource
            packageBound <-
                requiredSourceSection
                    "standalone recovery package bound"
                    "recoveryPackageLimit :: Word64"
                    "-- | Strictly decode exactly two canonical frames."
                    recoverySource
            protocolBound <-
                requiredSourceSection
                    "whole-message protocol bound"
                    "protocolMaximumBytes :: Word64"
                    "-- | Encode one message as a complete outer frame."
                    protocolSource
            admission <-
                requiredSourceSection
                    "adapter-only recovery admission"
                    "type RecoveryAdmission ="
                    "{- | Repository-sealed requester ancestry"
                    relaySource
            let users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                productionOwners = [relaySource, receiverSource, receiverInternalSource]
            assertBool
                "the carrier dependency graph remains one-way and excludes catalog/application producers"
                ( SourceGuard.importsModule "HostBootstrap.Handoff" relaySource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Recovery" relaySource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Protocol" relaySource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Receiver.Internal" relaySource
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Receiver" relaySource)
                    && SourceGuard.importsModule "HostBootstrap.Handoff" receiverSource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Protocol" receiverSource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Receiver.Internal" receiverSource
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Relay" receiverSource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Recovery" receiverSource)
                    && SourceGuard.importsModule "HostBootstrap.Handoff" receiverInternalSource
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Protocol" receiverInternalSource
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Relay" receiverInternalSource)
                    && all
                        ( \source ->
                            all
                                (\moduleName -> not (SourceGuard.importsModule moduleName source))
                                [ "HostBootstrap.Authority.ProjectPlan"
                                , "HostBootstrap.Command"
                                , "HostBootstrap.ProjectPlan"
                                , "HostBootstrap.ProjectPlan.Child.Internal"
                                ]
                        )
                        productionOwners
                )
            users "RootedPayloadBinding"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs"
                    ]
            users "RecoveryChildPackage"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Recovery.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    ]
            users "signRootedPayloadBindingKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "signRecoveryChildPackageBindingKernel"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"]
            users "withVerifiedRootedPayloadBinding"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"]
            users "withVerifiedRecoveryChildPackage"
                @?= ["internal/handoff-implementation/HostBootstrap/Handoff.hs", "internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs"]
            users "recoveryChildPackageKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Recovery.hs"
                    , "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs"
                    ]
            assertContains
                "RecoveryAdmission still authenticates only one exact adapter"
                "RecoveryProjectionBindingInput planDigest parentFrame childFrame -> IO (Either Text ByteString)"
                (normalizeWhitespace admission)
            ( SourceGuard.countHaskellTokenSequence ["data"] relaySource
                , SourceGuard.countHaskellTokenSequence ["newtype"] relaySource
                , SourceGuard.countHaskellTokenSequence ["data"] receiverSource
                , SourceGuard.countHaskellTokenSequence ["newtype"] receiverSource
                , SourceGuard.countHaskellTokenSequence ["data"] receiverInternalSource
                , SourceGuard.countHaskellTokenSequence ["newtype"] receiverInternalSource
                )
                @?= (3, 0, 1, 1, 2, 0)
            assertFragmentsInOrder
                "both endpoints impose the same explicit 7 MiB payload limit before semantics"
                [ "maxEmbeddedOfferPayloadBytes = 7 * 1024 * 1024"
                , "requireOfferPayloadBound payload >> requireConfigOpen input"
                , "mkHandoffOffer relay payload token"
                , "transmit channel OfferTag request (offerFieldsOf offer authentication)"
                ]
                offerBound
            assertFragmentsInOrder
                "after verifying the scope capsule the receiver bounds payload before installed-key digest, binding, or branch interpretation"
                [ "requireOfferPayloadBound payload"
                , "takeHandoffFrame authentication"
                , "requireInstalledKey key offeredKeyDigest"
                , "withHandoffBindingFromWire scope bindingBytes"
                , "maxEmbeddedOfferPayloadBytes = 7 * 1024 * 1024"
                ]
                receiveBound
            assertContains
                "the standalone package codec retains its complete 8 MiB limit"
                "recoveryPackageLimit = 8 * 1024 * 1024"
                (normalizeWhitespace packageBound)
            assertFragmentsInOrder
                "the unchanged four-field protocol charges every field and header to the whole 8 MiB body"
                [ "protocolMaximumBytes = 8 * 1024 * 1024"
                , "encodedLength > fromIntegral protocolMaximumBytes"
                , "fromIntegral messageHeaderBytes + sum [fromIntegral outerHeaderBytes + fromIntegral (ByteString.length field) | field <- fields]"
                , "OfferTag -> 4"
                ]
                protocolBound
            frozenHandoffDefinitionDigest [ "signRootedPayloadBindingKernel", "withVerifiedRootedPayloadBinding", "renderRecoveryChildPackage", "signRecoveryChildPackageBindingKernel", "withVerifiedRecoveryChildPackage" ] handoffSource
                >>= (@?= "fe95ce390d386f779e420f4e5f851ddbafb2ff0c9047fe3d4f681eed33f9c88f")
            SourceGuard.recordFieldNames "RecoveryProjectionBindingInput" handoffSource
                @?= Right ["recoveryInputPlanDigestValue", "recoveryInputParentFrameValue", "recoveryInputChildFrameValue"]
            exports <- maybe (assertFailure "the handoff facade needs an explicit export list") pure
                (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            forM_
                [ ("requestedRecoveryPlanDigest", "recoveryInputPlanDigestValue")
                , ("requestedRecoveryParentFrame", "recoveryInputParentFrameValue")
                , ("requestedRecoveryChildFrame", "recoveryInputChildFrameValue")
                ] $ \(getter, selector) -> do
                    assertBool "the plain recovery accessor remains public" (getter `elem` exports)
                    assertBool "the private recovery field label stays hidden" (selector `notElem` exports)
                    SourceGuard.haskellDefinitionTokens getter handoffSource @?= Right [getter, "=", selector]
                    assertFragmentsInOrder "the recovery getter retains all three nominal coordinates"
                        [getter <> " :: RecoveryProjectionBindingInput planDigest parentFrame childFrame -> Text", getter <> " = " <> selector]
                        handoffSource
            assertFragmentsInOrder "the recovery input keeps its three nominal roles"
                ["type role RecoveryProjectionBindingInput nominal nominal nominal"] handoffSource
            cabalRows @?= frozenHandoffPackageRows
    , testCase "the token is forced before one live validation/admission/signing sequence" $
        withHandoffPackageRoot $ \packageRoot -> do
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            signer <-
                requiredSourceSection
                    "recovery signing kernel"
                    "signRecoveryWireKernel ::"
                    "validateRecoverySigningEnvelopeActive ::"
                    handoffSource
            validation <-
                requiredSourceSection
                    "recovery signing validation"
                    "validateRecoverySigningEnvelopeActive ::"
                    "signValidatedRecoveryWireActive ::"
                    handoffSource
            signedMaterial <-
                requiredSourceSection
                    "canonical recovery signed material"
                    "recoverySignedMaterial ::"
                    "{- | What an immediate parent is given"
                    handoffSource
            admission <-
                requiredSourceSection
                    "plan-derived recovery admission"
                    "type RecoveryAdmission ="
                    "{- | Repository-sealed requester ancestry"
                    relaySource
            let normalizedSigner = normalizeWhitespace signer
                normalizedValidation = normalizeWhitespace validation
                normalizedAdmission = normalizeWhitespace admission
            assertContains
                "strict token-only partial application"
                "signRecoveryWireKernel kernel = kernel `seq` consumeRecoverySigningKernel kernel sign"
                normalizedSigner
            SourceGuard.countHaskellIdentifier "withActiveRootBroker" signer @?= 1
            assertFragmentsInOrder
                "validation precedes admission, exact-byte equality, and signing"
                [ "withActiveRootBroker broker"
                , "validateRecoverySigningEnvelopeActive broker binding wire"
                , "admitted <- admission"
                , "Right expectedWire"
                , "expectedWire /= wire"
                , "signValidatedRecoveryWireActive broker binding wire"
                ]
                signer
            assertContains
                "candidate bytes are validated before admission"
                "ByteString.null wire"
                normalizedValidation
            assertContains
                "the canonical binding digest covers the candidate"
                "recoveryWireDigest wire /= recoveryProjectionWireDigest binding"
                normalizedValidation
            assertContains
                "the admission returns exact expected adapter bytes"
                "RecoveryProjectionBindingInput planDigest parentFrame childFrame -> IO (Either Text ByteString)"
                normalizedAdmission
            SourceGuard.countHaskellIdentifier "ByteString" admission @?= 1
            SourceGuard.countHaskellIdentifier "frameWire" signedMaterial @?= 4
            traverse_
                (\field -> assertContains ("signed material retains " <> field) field signedMaterial)
                [ "recoveryWireDomain"
                , "verificationKeyDigest"
                , "renderRecoveryProjectionBinding"
                , "wire"
                ]
    , testCase "the recursive handoff runtime installs trust and arm without any capability" $
        withHandoffPackageRoot $ \packageRoot -> do
            sources <- handoffImplementationSources packageRoot
            handoffSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff")
            runtimeSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Runtime")
            relaySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay")
            entrySource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Command.LifecycleEntry")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            rootArmSource <-
                requiredSourceSection
                    "the root arm producer"
                    "rootRecursiveHandoffRuntimeKernel ::"
                    "{- | Install a nested arm from one already authenticated parent edge."
                    runtimeSource
            nestedArmSource <-
                requiredSourceSection
                    "the nested arm producer"
                    "nestedRecursiveHandoffRuntimeKernel ::"
                    "{- | Read one runtime's arm and identity without opening a route."
                    runtimeSource
            eliminatorSource <-
                requiredSourceSection
                    "the fixed-unit runtime eliminator"
                    "withRecursiveHandoffRuntimeKernel ::"
                    "requireIdentity ::"
                    runtimeSource
            relayInstallerSource <-
                requiredSourceSection
                    "the keyless runtime installer"
                    "withNestedRecursiveHandoffRuntimeKernel ::"
                    "lifecycleAcknowledgementUnavailable ::"
                    relaySource
            entryInstallerSource <-
                requiredSourceSection
                    "the sealed root runtime installer"
                    "withRootRecursiveHandoffRuntimeKernel ::"
                    "{- | Admit the recursive catalog one reverse root entry stands on"
                    entrySource
            runtimeExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Runtime has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Runtime" runtimeSource)
            handoffExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            let runtime = normalizeWhitespace runtimeSource
                eliminator = normalizeWhitespace eliminatorSource
                relayInstaller = normalizeWhitespace relayInstallerSource
                publicHandoff = normalizedModuleExports handoffExports
                users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
            normalizedModuleExports runtimeExports
                @?= [ "RecursiveHandoffRuntime"
                    , "rootRecursiveHandoffRuntimeKernel"
                    , "nestedRecursiveHandoffRuntimeKernel"
                    , "withRecursiveHandoffRuntimeKernel"
                    , "withRootArmRecursiveHandoffRuntimeKernel"
                    , "withNestedArmRecursiveHandoffRuntimeKernel"
                    ]
            traverse_
                ( \identifier ->
                    assertBool
                        (identifier <> " stays out of the public handoff facade")
                        (identifier `notElem` publicHandoff)
                )
                [ "RecursiveHandoffRuntime"
                , "RootRecursiveHandoffRuntime"
                , "NestedRecursiveHandoffRuntime"
                , "rootRecursiveHandoffRuntimeKernel"
                , "nestedRecursiveHandoffRuntimeKernel"
                , "withRecursiveHandoffRuntimeKernel"
                ]
            assertBool
                "the runtime stays Cabal-private without a second module row"
                ( "HostBootstrap.Handoff.Runtime" `notElem` exposed
                    && length (filter (== "HostBootstrap.Handoff.Runtime") private) == 1
                )
            assertContains
                "the sole named type is all-nominal in scope, generation, and verb"
                "type role RecursiveHandoffRuntime nominal nominal nominal"
                runtime
            SourceGuard.countHaskellTokenSequence ["data", "RecursiveHandoffRuntime"] runtimeSource @?= 1
            SourceGuard.countHaskellIdentifier "data" runtimeSource @?= 1
            SourceGuard.countHaskellIdentifier "newtype" runtimeSource @?= 0
            SourceGuard.countHaskellIdentifier "type" runtimeSource @?= 1
            assertContains
                "the root arm retains identity coordinates and no authenticated frame"
                "RootRecursiveHandoffRuntime :: ProjectVerb verb -> Text -> Text -> Text -> Word64 -> ByteString -> RecursiveHandoffRuntime scope brokerGeneration verb"
                runtime
            assertContains
                "the nested arm additionally retains the frame its keyless relay speaks for"
                "NestedRecursiveHandoffRuntime :: ProjectVerb verb -> Text -> Text -> Text -> Word64 -> ByteString -> Text -> RecursiveHandoffRuntime scope brokerGeneration verb"
                runtime
            assertFragmentsInOrder
                "the root arm cross-checks scope, verb, installed key, and path-agnostic route before it exists"
                [ "handoffScopeProject scope == project"
                , "verbName == projectVerbName (rootAuthorityVerb root)"
                , "brokerRouteVerificationKeyDigest route == keyDigest"
                , "isNothing (brokerRouteCurrentFrame route)"
                , "requireIdentity project tag store generation keyDigest verbName"
                , "pure (RootRecursiveHandoffRuntime verb project tag store generation keyDigest)"
                ]
                rootArmSource
            assertFragmentsInOrder
                "every root coordinate is derived from the admitted root environment, not a caller"
                [ "project = rootAuthorityProjectName root"
                , "tag = handoffScopeTag scope"
                , "store = rootAuthorityStoreIdentity root"
                , "generation = brokerEpochWord (rootAuthorityEpoch root)"
                , "keyDigest = TextEncoding.encodeUtf8 (verificationKeyDigest (rootBrokerVerificationKey broker))"
                ]
                rootArmSource
            assertFragmentsInOrder
                "the nested arm requires the authenticated frame the relayed route names"
                [ "verbName == handoffVerb binding"
                , "brokerRouteCurrentFrame route == Just frame"
                , "not (Text.null frame)"
                , "requireIdentity project tag store generation keyDigest verbName"
                , "pure (NestedRecursiveHandoffRuntime verb project tag store generation keyDigest frame)"
                ]
                nestedArmSource
            assertContains
                "shared identity admission refuses an empty coordinate or a zero generation"
                "require \"the broker generation is zero\" (generation > 0)"
                runtime
            assertContains
                "the eliminator is a fixed-unit fold over derived coordinates"
                "withRecursiveHandoffRuntimeKernel :: RecursiveHandoffRuntime scope brokerGeneration verb -> ( Bool -> Text -> Text -> Text -> Word64 -> Text -> ByteString -> Maybe Text -> IO (Either Text ()) ) -> IO (Either Text ())"
                eliminator
            assertFragmentsInOrder
                "only the root arm reports that it signs locally"
                [ "RootRecursiveHandoffRuntime verb project tag store generation keyDigest -> use True"
                , "NestedRecursiveHandoffRuntime verb project tag store generation keyDigest frame -> use False"
                ]
                eliminatorSource
            assertBool
                "both producers and the eliminator are opaque"
                ( all
                    (`isInfixOf` runtimeSource)
                    [ "{-# OPAQUE rootRecursiveHandoffRuntimeKernel #-}"
                    , "{-# OPAQUE nestedRecursiveHandoffRuntimeKernel #-}"
                    , "{-# OPAQUE withRecursiveHandoffRuntimeKernel #-}"
                    ]
                )
            assertContains
                "a nested frame receives the runtime only beside its keyless route"
                "Right runtime -> use runtime (relayedBrokerLinkKernel edge)"
                relayInstaller
            assertFragmentsInOrder
                "the keyless installer derives both terms from the same authenticated edge"
                [ "nestedRecursiveHandoffRuntimeKernel route binding verb"
                , "route = verifiedHandoffRoute (receivedEdgeHandoff edge)"
                , "binding = verifiedHandoffBinding (receivedEdgeHandoff edge)"
                ]
                relayInstallerSource
            assertFragmentsInOrder
                "only a sealed root entry installs the root arm, and a child entry is refused"
                [ "RootUpLifecycleEntry root verb _ _ _ _ _ _ -> install root verb"
                , "RootDownLifecycleEntry root verb _ _ _ _ _ _ _ -> install root verb"
                , "RootDestroyLifecycleEntry root verb _ _ _ _ _ _ _ -> install root verb"
                , "rootRecursiveHandoffRuntimeKernel broker scope (rootBrokerRoute broker) root verb"
                ]
                entryInstallerSource
            traverse_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier runtimeSource @?= 0)
                [ "RootedPlanCatalog"
                , "RootedFrameSession"
                , "ProtectedStore"
                , "ProtectedSession"
                , "AcquisitionJournal"
                , "CommandAuthority"
                , "compareAndSwapProtectedRecord"
                , "withProtectedEntry"
                , "HandoffChannel"
                , "BrokerLink"
                , "RequesterPath"
                , "ActivationManifest"
                , "ActivationBroker"
                , "BuildSigningKey"
                , "ProtocolTag"
                , "ProjectSigningKey"
                , "Ed25519"
                , "createProcess"
                , "unsafeCoerce"
                ]
            traverse_
                ( \moduleName ->
                    assertBool
                        ("the runtime imports no effect or transport owner " <> moduleName)
                        (not (SourceGuard.importsModule moduleName runtimeSource))
                )
                [ "HostBootstrap.Activation"
                , "HostBootstrap.Build"
                , "HostBootstrap.Chain"
                , "HostBootstrap.Command"
                , "HostBootstrap.Handoff.Protocol"
                , "HostBootstrap.Handoff.Receiver"
                , "HostBootstrap.Handoff.Receiver.Internal"
                , "HostBootstrap.Handoff.Relay"
                , "HostBootstrap.Lifecycle.RootedPlan"
                , "HostBootstrap.Lifecycle.Session"
                , "HostBootstrap.Protected"
                , "System.Process"
                ]
            users "rootRecursiveHandoffRuntimeKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Runtime.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    ]
            users "nestedRecursiveHandoffRuntimeKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Handoff/Runtime.hs"
                    ]
            users "withRecursiveHandoffRuntimeKernel"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Runtime.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "src/HostBootstrap/Lifecycle/Rooted/Node.hs"
                    ]
            importers "HostBootstrap.Handoff.Runtime"
                @?= [ "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs"
                    , "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    , "src/HostBootstrap/Command/Child.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    , "src/HostBootstrap/Handoff/Process/Route.hs"
                    , "src/HostBootstrap/Lifecycle/Rooted/Node.hs"
                    ]
            assertBool
                "the installed runtime stays inside its 400-line sprint budget"
                (significantHaskellLineCount runtimeSource <= 400)
    , testCase "the reverse lifecycle child is storeless and exact" $
        withHandoffPackageRoot $ \packageRoot -> do
            childSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Command.Child")
            reverseActionSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Command.Child.Reverse")
            executorSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Teardown.Executor.Internal")
            sources <- handoffImplementationSources packageRoot
            exports <-
                maybe
                    (assertFailure "Teardown.Executor.Internal has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Teardown.Executor.Internal" executorSource)
            sort (normalizedModuleExports exports)
                @?= sort
                    [ "runStorelessReversePreparedKernel"
                    , "withStorelessReverseDescentResultKernel"
                    , "withStorelessReverseExecutorKernel"
                    ]
            reverseChildSource <-
                requiredSourceSection
                    "reverse child adoption"
                    "runProductionRecovery ::"
                    "runProduction ::"
                    childSource
            let reverseChild = normalizeWhitespace reverseChildSource
                reverseAction = normalizeWhitespace reverseActionSource
                lower = normalizeWhitespace executorSource
                importers moduleName =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
            assertFragmentsInOrder
                "recovery is decoded, re-admitted, projected, then opened as a rooted executor"
                [ "withReceivedRecoveryDescent descent"
                , "recoveryChildPackageFromWireKernel packageBytes"
                , "decodeProjectCodecWithSettings"
                , "renderScopedProjectConfigBytes"
                , "withValidatedConfig"
                , "withChildProjectPlanKernel"
                , "withCurrentFrame"
                , "withStorelessReverseExecutorKernel"
                , "openTeardownForest"
                , "withNestedRecursiveHandoffRuntimeKernel"
                , "withOpenedFrameExecutorKernel"
                , "runCoreManagedReverse root context plan host"
                , "withExecutedFrameNodeKernel"
                , "runStorelessReversePreparedKernel"
                , "withStorelessReverseDescentResultKernel"
                , "\"frame-complete\""
                , "\"receipt-recorded\""
                ]
                reverseChildSource
            assertContains
                "callback-free reverse work is interpreted by the authenticated child rather than assumed released"
                "Nothing -> runCoreManaged local"
                lower
            assertBool
                "the storeless executor does not mint a released observation for unexecuted core work"
                (not ("Nothing -> pure TeardownReleased" `isInfixOf` lower))
            assertFragmentsInOrder
                "the child derives the retained cluster from its admitted profile and releases exposure before cluster ownership"
                [ "profileFromPlanName (projectPlanProfileName plan)"
                , "releaseRecordedClusterExposure host clusterPlan"
                , "releaseRetainedCluster host clusterPlan"
                ]
                reverseActionSource
            assertFragmentsInOrder
                "reverse recovery derives the exact Production or Harness run profile from the verified handoff binding"
                [ "recoveryProfileName binding"
                , "profileName"
                , "withChildProjectPlanKernel profileName"
                ]
                reverseChildSource
            assertContains
                "Harness recovery retains the run identity in the lifecycle profile"
                "Right (\"harness:\" <> runName)"
                reverseAction
            assertBool
                "reverse recovery does not collapse every Harness run into one invalid ambient profile"
                (not ("runScopedRecovery \"harness\"" `isInfixOf` reverseChild))
            assertContains
                "callback-free non-core work is terminally classified as having acquired nothing"
                "TeardownForeignRetained \"the node acquired nothing this frame must release\""
                reverseAction
            assertBool
                "callback-free non-core work cannot enter the teardown failure retry pass"
                (not ("callback-free work that is not core-managed" `isInfixOf` reverseAction))
            traverse_
                (\name -> assertContains (name <> " is retained by the lower verifier") name lower)
                [ "the supplied reverse child adapter is not canonical"
                , "the Prepared response names another reverse operation"
                , "the Descend response names another child frame"
                , "verifySubtreeSettled"
                ]
            traverse_
                ( \moduleName ->
                    assertBool
                        ("the lower reverse executor imports no root authority owner " <> moduleName)
                        (not (SourceGuard.importsModule moduleName executorSource))
                )
                [ "HostBootstrap.Command"
                , "HostBootstrap.Chain"
                , "HostBootstrap.Protected"
                , "HostBootstrap.Lifecycle.Context"
                , "HostBootstrap.Lifecycle.Session"
                , "System.Process"
                ]
            importers "HostBootstrap.Teardown.Executor.Internal"
                @?= ["src/HostBootstrap/Command/Child.hs"]
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            exposed <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
            private <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
            assertBool
                "the reverse executor is registered exactly once and remains hidden"
                ( "HostBootstrap.Teardown.Executor.Internal" `notElem` exposed
                    && length (filter (== "HostBootstrap.Teardown.Executor.Internal") private) == 1
                )
            assertBool
                "the child reverse action is registered exactly once and remains hidden"
                ( "HostBootstrap.Command.Child.Reverse" `notElem` exposed
                    && length (filter (== "HostBootstrap.Command.Child.Reverse") private) == 1
                )
            assertBool
                "the lower reverse executor stays inside its 400-line sprint budget"
                (significantHaskellLineCount executorSource <= 400)
            assertBool
                "the child reverse action stays inside its 400-line sprint budget"
                (significantHaskellLineCount reverseActionSource <= 400)
    , testCase "cluster cleanup is bound to the sealed root reverse entry" $
        withHandoffPackageRoot $ \packageRoot -> do
            clusterSource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Cluster.Reconcile")
            entrySource <-
                (readFile =<< handoffModulePath packageRoot "HostBootstrap.Command.LifecycleEntry")
            clusterKernel <-
                requiredSourceSection
                    "exact cluster cleanup kernel"
                    "runExactClusterCleanupKernel ::"
                    "sameObservedResource ::"
                    clusterSource
            entryKernel <-
                requiredSourceSection
                    "sealed root cluster cleanup kernel"
                    "runPreparedRootClusterCleanupKernel ::"
                    "{- | Interpret exactly one admitted root @project up@ leaf."
                    entrySource
            assertFragmentsInOrder
                "cluster cleanup checks plan, operation, action, then the closed verb"
                [ "preparedGatePlan gate /= stablePlanSnapshotDigest (renderSnapshot plan)"
                , "preparedGateOperation gate /= localWorkKey local"
                , "localWorkAction local /= DeleteCluster"
                , "case verb of"
                , "ProjectUp"
                , "ProjectDown -> run runDown"
                , "ProjectDestroy -> run runDestroy"
                ]
                clusterKernel
            assertFragmentsInOrder
                "only sealed root reverse entries disclose their retained plan and verb"
                [ "case entry of"
                , "RootDownLifecycleEntry _ verb plan"
                , "runExactClusterCleanupKernel plan verb gate local runDown runDestroy"
                , "RootDestroyLifecycleEntry _ verb plan"
                , "runExactClusterCleanupKernel plan verb gate local runDown runDestroy"
                , "RootUpLifecycleEntry"
                ]
                entryKernel
            traverse_
                (\name -> SourceGuard.countHaskellIdentifier name clusterKernel @?= 0)
                ["data", "newtype", "Bool", "ProtectedStore", "compareAndSwapProtectedRecord"]
            traverse_
                (\name -> SourceGuard.countHaskellIdentifier name entryKernel @?= 0)
                ["data", "newtype", "Bool", "ProtectedStore", "compareAndSwapProtectedRecord"]
            sources <- handoffImplementationSources packageRoot
            let users identifier =
                    sort
                        [ sourcePath packageRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
            users "runExactClusterCleanupKernel"
                @?= [ "src/HostBootstrap/Cluster/Reconcile.hs"
                    , "src/HostBootstrap/Command/LifecycleEntry.hs"
                    ]
            users "runPreparedRootClusterCleanupKernel"
                @?= ["src/HostBootstrap/Command/LifecycleEntry.hs"]
    , testCase "reverse terminalization is exact, retained, and root-owned" $
        withHandoffPackageRoot $ \packageRoot -> do
            modeSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Lifecycle.Mode")
            entrySource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Command.LifecycleEntry")
            terminalKernel <-
                requiredSourceSection
                    "reverse terminal kernel"
                    "terminalizeExistingBoundReverseRootKernel ::"
                    "{- | Resume only the exact same-verb"
                    modeSource
            entryKernel <-
                requiredSourceSection
                    "root reverse terminal call site"
                    "terminalizeRootReverseLifecycleEntryKernel ::"
                    "-- End reverse terminalization kernel"
                    entrySource
            assertFragmentsInOrder
                "Down terminalization checks exact settlement before its retained-intent CAS"
                [ "case validateEvidence of"
                , "subtreeSettledPlanDigest settled"
                , "allSessionsClosedPlanDigest sessions"
                , "ProjectDestroy, Just (SettledProductionClosure root exact closed proof)"
                , "validateLive session common target"
                , "compareAndSwapProtectedRecord session intentKey"
                , "exactTerminal session intentKey bytes"
                , "releaseIfDestroy session"
                ]
                terminalKernel
            assertFragmentsInOrder
                "only root Down or Destroy can reach terminal mutation"
                [ "case entry of"
                , "RootDownLifecycleEntry"
                , "terminalize verb Nothing"
                , "RootDestroyLifecycleEntry"
                , "verifyDestroySettled plan current settled"
                , "authorizeProductionDestroy root lease sessions destroy"
                , "terminalize verb (Just closure)"
                , "RootUpLifecycleEntry"
                ]
                entryKernel
            SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" terminalKernel @?= 1
            SourceGuard.countHaskellIdentifier "terminalizeExistingBoundReverseRootKernel" entryKernel @?= 1
            traverse_
                (\name -> SourceGuard.countHaskellIdentifier name terminalKernel @?= 0)
                ["data", "newtype", "Bool"]
            assertBool
                "terminal and rearm additions stay within the sprint's 400 significant lines"
                (significantHaskellLineCount terminalKernel <= 400)
    , testCase "prepared reverse process launch retains its nominal lineage" $
        withHandoffPackageRoot $ \packageRoot -> do
            internalSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Teardown.Internal")
            routeSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Process.Route")
            processSource <- (readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Process")
            inputs <-
                requiredSourceSection
                    "prepared reverse process inputs"
                    "withReverseDescentProcessInputsKernel ::"
                    "{- | Prepare one exact root-entry descent"
                    internalSource
            route <-
                requiredSourceSection
                    "typed prepared recovery route"
                    "withRecoveryLifecycleProcessRouteForKernel ::"
                    "{- | Seal one route from an already admitted edge"
                    routeSource
            launch <-
                requiredSourceSection
                    "prepared reverse child process"
                    "withPreparedReverseLifecycleChildProcess ::"
                    "{- | Hold one child, its pipes, and its group"
                    processSource
            assertFragmentsInOrder
                "the owner canonically decodes only retained package bytes"
                [ "withReverseDescentLiftContextKernel descent"
                , "PreparedReverseDescent"
                , "recoveryChildPackageFromWireKernel package"
                , "use recovered route input verb"
                ]
                inputs
            assertFragmentsInOrder
                "route indices come from the prepared lineage"
                [ "proxyScope scope"
                , "proxyBroker brokerGeneration"
                , "LifecycleProcessRoute scope rootPlanId brokerGeneration"
                , "use (LifecycleProcessRoute verb"
                , "derive verb \"teardown\" (withoutConfigDelivery route) input targetBinary"
                ]
                route
            assertFragmentsInOrder
                "the process owner derives then launches exactly one route"
                [ "withReverseDescentProcessInputsKernel descent"
                , "withRecoveryLifecycleProcessRouteForKernel"
                , "Proxy :: Proxy scope"
                , "Proxy :: Proxy brokerGeneration"
                , "withReverseLifecycleChildProcess config link processRoute request descent"
                ]
                launch
            traverse_
                (\name -> SourceGuard.countHaskellIdentifier name (inputs <> route <> launch) @?= 0)
                ["unsafeCoerce", "ProtectedStore", "data", "newtype", "Bool"]
    ]

-- ---------------------------------------------------------------------------
-- Keyless relay exchanges

duplexRelayTests :: [TestTree]
duplexRelayTests =
    [ testCase "route refinement compares all twelve coordinates after canonical decoding" $
        withNamedHandoff 101 ProjectUp $ \_ broker -> do
            let input = bindingInputFor childPayload
                route = rootBrokerRoute broker
            (relay, _token) <- registerHandoffEdge broker input >>= expectRight
            let wire = renderHandoffBinding (relayBinding relay)
                refine expected bytes = renderHandoffBinding . relayBinding <$> brokerRelayFromRouteWire route expected bytes
            fields <- framesOf wire
            length fields @?= 13
            refine (Just input) wire @?= Right wire
            refine Nothing wire @?= Right wire
            let routeChanges =
                    [ ("installed project", 0, "another-installed-project")
                    , ("scope", 3, "Harness another-run")
                    , ("protected store", 4, "another-protected-store")
                    , ("broker generation", 6, lifecycleWordBytesFor 2)
                    , ("verb", 10, "down")
                    ]
                inputChanges =
                    [ ("specification digest", input{requestedSpecDigest = "another-spec"})
                    , ("payload kind", input{requestedPayloadKind = RecoveryAdapterWire})
                    , ("plan revision", input{requestedPlanRevision = "another-revision"})
                    , ("parent frame", input{requestedParentFrame = "another-parent"})
                    , ("child frame", input{requestedChildFrame = "another-child"})
                    , ("child config digest", input{requestedChildConfigDigest = "another-config"})
                    , ("phase", input{requestedPhase = "teardown"})
                    ]
                refusal field = Left (HandoffBindingMismatch ("the relayed binding's " <> field <> " does not match its authenticated route or opening request"))
            length routeChanges + length inputChanges @?= 12
            forM_ routeChanges $ \(field, index, replacement) -> do
                let changed = wireWithFrames [(index, replacement)] fields
                assertBool (Text.unpack field <> " changes the binding") (changed /= wire)
                refine Nothing changed @?= refusal field
                refine (Just input) changed @?= refusal field
            forM_ inputChanges $ \(field, changed) -> do
                assertBool (Text.unpack field <> " changes only its opening input") (changed /= input)
                handoffBindingInputFromWire (renderHandoffBindingInput changed) @?= Right changed
                refine (Just changed) wire @?= refusal field
    , testCase "ordinary offer documentation owns its config payload and retains the sender bound" $
        withHandoffPackageRoot $ \packageRoot -> do
            relaySource <- readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Relay"
            offerDocumentation <- requiredSourceSection
                "the ordinary offer's own documentation and argument"
                "{- | Open one edge through this frame's link"
                "offerHandoffEdge _ _ 0"
                relaySource
            assertBool "the argument documents the exact narrowed project config bytes"
                ("the exact narrowed project config bytes" `isInfixOf` offerDocumentation)
            assertBool "recovery uses the actual separate reverse descent opener"
                ("offerReverseDescentKernel" `isInfixOf` offerDocumentation)
            assertBool "the ordinary payload is not documented as recovery-adapter bytes"
                (not ("config or recovery-adapter bytes" `isInfixOf` offerDocumentation))
            senderBound <- requiredSourceSection "the complete retained sender bound"
                "maxEmbeddedOfferPayloadBytes :: Int" "awaitChallenge ::" relaySource
            assertFragmentsInOrder "the existing byte bound remains before ordinary opening and offer transmission"
                [ "maxEmbeddedOfferPayloadBytes = 7 * 1024 * 1024"
                , "offerHandoffEdge link channel request input payload terminal = case requireOfferPayloadBound payload >> requireConfigOpen input of"
                , "opened <- openEdgeThroughLink link input"
                , "mkHandoffOffer relay payload token"
                , "offerAuthentication link offer"
                , "requireOfferPayloadBound payload"
                , "ByteString.length payload <= maxEmbeddedOfferPayloadBytes"
                ] senderBound
    , testCase "a nested real Relay consumer preserves the exact trailing-offer peer refusal" $
        forM_ [False, True] $ \appendTrailing ->
            withDuplexHandoffRoot $ \project store broker link admissions ->
                withHandoffChannels $ \rootChannel rootProxy closeRootOutput _ ->
                    withHandoffChannels $ \relayProxy relayChannel _ closeRelayOutput -> do
                        nestedCallbacks <- newIORef (0 :: Int)
                        rootedReplies <- newIORef (0 :: Int)
                        peerRefusal <- newIORef Nothing
                        let upward message
                                | appendTrailing && Protocol.protocolMessageTag message == Protocol.RecoveryRequestTag =
                                    case Protocol.protocolMessageFields message of
                                        [header, offerWire] -> Just <$> relayMessage Protocol.RecoveryRequestTag [header, offerWire <> "xyz"]
                                        _ -> assertFailure "the real nested rooted request did not have its two fields"
                                | otherwise = pure (Just message)
                            downward message = do
                                when (Protocol.protocolMessageTag message == Protocol.RecoveryResponseTag)
                                    (modifyIORef' rootedReplies (+ 1))
                                when (Protocol.protocolMessageTag message == Protocol.RefusedTag)
                                    (writeIORef peerRefusal (Just (Protocol.protocolMessageFields message)))
                                pure (Just message)
                            parent = Relay.offerHandoffEdge link rootChannel relayRequest outerRelayInput childPayload unusedRelayTerminal
                            child = receiveConfigRelay project relayChannel (rootBrokerVerificationKey broker) $ \nestedLink -> do
                                withHandoffChannels $ \nestedChannel leafChannel _ _ ->
                                    withHandoffWorker
                                        (receiveConfigRelay project leafChannel (rootBrokerVerificationKey broker) $ \_ -> do
                                            modifyIORef' nestedCallbacks (+ 1)
                                            pure (Left relayFinished)) $ \awaitLeaf -> do
                                            nested <- Relay.offerHandoffEdge nestedLink nestedChannel relayRequest innerRelayInput childPayload unusedRelayTerminal
                                            if appendTrailing
                                                then do
                                                    nested @?= Left (Relay.RelayRefusedByPeer "unauthenticated" (Text.pack (handoffErrorMessage (HandoffWireTrailingBytes 3))))
                                                    awaitLeaf >>= (@?= Left (Receiver.ReceiverRefusedByParent "peer-refused" (Text.pack (Relay.relayErrorMessage (Relay.RelayRefusedByPeer "unauthenticated" (Text.pack (handoffErrorMessage (HandoffWireTrailingBytes 3))))))))
                                                else do
                                                    nested @?= Left (relayChildDeclined relayFinished)
                                                    awaitLeaf >>= (@?= Left (Receiver.ReceiverDeclined relayFinished))
                                pure (Left relayFinished)
                        withHandoffWorker (forwardHandoffMessages rootProxy relayProxy downward) $ \awaitDown ->
                            withHandoffWorker (forwardHandoffMessages relayProxy rootProxy upward) $ \awaitUp ->
                                withHandoffWorker parent $ \awaitParent -> do
                                    childResult <- boundedHandoff "the real nested receiver" child
                                    childResult @?= Left (Receiver.ReceiverDeclined relayFinished)
                                    -- A consumed parent refusal ends this route;
                                    -- the receiver must no longer echo it upstream.
                                    when appendTrailing closeRelayOutput
                                    parentResult <- awaitParent
                                    closeRootOutput
                                    if appendTrailing
                                        then do
                                            parentResult @?= Left (Relay.RelayHandoffFailure (HandoffWireTrailingBytes 3))
                                            readIORef peerRefusal >>= (@?= Just ["unauthenticated", TextEncoding.encodeUtf8 (Text.pack (handoffErrorMessage (HandoffWireTrailingBytes 3)))])
                                            readIORef nestedCallbacks >>= (@?= 0)
                                            readIORef rootedReplies >>= (@?= 0)
                                        else do
                                            parentResult @?= Left (relayChildDeclined relayFinished)
                                            readIORef nestedCallbacks >>= (@?= 1)
                                            readIORef rootedReplies >>= (@?= 1)
                                    awaitUp >>= (@?= if appendTrailing then Left (Protocol.ProtocolTruncated 8 0) else Right ())
                                    awaitDown >>= (@?= if appendTrailing then Right () else Left (Protocol.ProtocolTruncated 8 0))
                        readIORef admissions >>= (@?= 2)
                        -- The actual store and broker remain held through every result.
                        assertBool "the real root retains its settled outer token" . not . null =<< protectedHandoffImage store
    , testCase "a severed admitted route refuses before nested admission or root mutation" $
        withDuplexHandoffRoot $ \project store broker link admissions ->
            withHandoffChannels $ \rootChannel rootProxy _ cutToRoot ->
                withHandoffChannels $ \relayProxy relayChannel cutToRelay _ -> do
                    severed <- newIORef False
                    before <- newEmptyMVar
                    nestedCallbacks <- newIORef (0 :: Int)
                    let upward message
                            | Protocol.protocolMessageTag message == Protocol.OfferRequestTag = do
                                writeIORef severed True
                                cutToRelay
                                cutToRoot
                                pure Nothing
                            | otherwise = pure (Just message)
                        downward message = do
                            isSevered <- readIORef severed
                            pure (if isSevered then Nothing else Just message)
                        parent = Relay.offerHandoffEdge link rootChannel relayRequest outerRelayInput childPayload unusedRelayTerminal
                        child = receiveConfigRelay project relayChannel (rootBrokerVerificationKey broker) $ \nestedLink -> do
                            protectedHandoffImage store >>= putMVar before
                            withHandoffChannels $ \nestedChannel leafChannel _ _ ->
                                withHandoffWorker
                                    (receiveConfigRelay project leafChannel (rootBrokerVerificationKey broker) $ \_ -> do
                                        modifyIORef' nestedCallbacks (+ 1)
                                        pure (Left relayFinished)) $ \awaitLeaf -> do
                                    nested <- Relay.offerHandoffEdge nestedLink nestedChannel relayRequest innerRelayInput childPayload unusedRelayTerminal
                                    nested @?= Left (Relay.RelayProtocolFailure (Protocol.ProtocolTruncated 8 0))
                                    awaitLeaf >>= (@?= Left (Receiver.ReceiverRefusedByParent "protocol" (Text.pack (Protocol.protocolErrorMessage (Protocol.ProtocolTruncated 8 0)))))
                            pure (Left relayFinished)
                    withHandoffWorker (forwardHandoffMessages rootProxy relayProxy downward) $ \awaitDown ->
                        withHandoffWorker (forwardHandoffMessages relayProxy rootProxy upward) $ \awaitUp ->
                            withHandoffWorker parent $ \awaitParent -> do
                                boundedHandoff "the severed child" child >>= (@?= Left (Receiver.ReceiverDeclined relayFinished))
                                awaitParent >>= (@?= Left (Relay.RelayProtocolFailure (Protocol.ProtocolTruncated 8 0)))
                                awaitUp >>= (@?= Right ())
                                awaitDown >>= (@?= Right ())
                    readIORef severed >>= (@?= True)
                    readIORef admissions >>= (@?= 1)
                    readIORef nestedCallbacks >>= (@?= 0)
                    snapshot <- boundedHandoff "the post-admission store image" (readMVar before)
                    protectedHandoffImage store >>= (@?= snapshot)
    , testCase "a settled grant replays byte-for-byte through a fresh route to the same live root" $
        withDuplexHandoffRoot $ \project store broker link admissions -> do
            originalRequest <- newIORef Nothing
            originalResponse <- newIORef Nothing
            openedRow <- newIORef Nothing
            settledRow <- newIORef Nothing
            nestedBefore <- newEmptyMVar
            nestedCallbacks <- newIORef (0 :: Int)
            -- Closing all first-route handles really severs that route before the next opens.
            withHandoffChannels $ \rootChannel rootProxy closeRootOutput _ ->
                withHandoffChannels $ \relayProxy relayChannel _ _ -> do
                    let upward message = do
                            when (Protocol.protocolMessageTag message == Protocol.GrantRequestTag)
                                (writeIORef originalRequest (Just message))
                            pure (Just message)
                        downward message = do
                            when (Protocol.protocolMessageTag message == Protocol.OfferResponseTag) $ do
                                snapshot <- readMVar nestedBefore
                                image <- protectedHandoffImage store
                                row <- requireSingleHandoffRow [entry | entry@(key, _, _) <- image, key `notElem` [oldKey | (oldKey, _, _) <- snapshot]]
                                writeIORef openedRow (Just row)
                            when (Protocol.protocolMessageTag message == Protocol.GrantResponseTag) $ do
                                writeIORef originalResponse (Just message)
                                (key, _, _) <- readIORef openedRow >>= requireObserved "the selected opened token row"
                                image <- protectedHandoffImage store
                                requireSingleHandoffRow [entry | entry@(observed, _, _) <- image, observed == key] >>= writeIORef settledRow . Just
                            pure (Just message)
                        child = receiveConfigRelay project relayChannel (rootBrokerVerificationKey broker) $ \nestedLink -> do
                            protectedHandoffImage store >>= putMVar nestedBefore
                            withHandoffChannels $ \nestedChannel leafChannel _ _ ->
                                withHandoffWorker
                                    (receiveConfigRelay project leafChannel (rootBrokerVerificationKey broker) $ \_ -> do
                                        modifyIORef' nestedCallbacks (+ 1)
                                        pure (Left relayFinished)) $ \awaitLeaf -> do
                                            Relay.offerHandoffEdge nestedLink nestedChannel relayRequest innerRelayInput childPayload unusedRelayTerminal >>= (@?= Left (relayChildDeclined relayFinished))
                                            awaitLeaf >>= (@?= Left (Receiver.ReceiverDeclined relayFinished))
                            pure (Left relayFinished)
                    withHandoffWorker (forwardHandoffMessages rootProxy relayProxy downward) $ \awaitDown ->
                        withHandoffWorker (forwardHandoffMessages relayProxy rootProxy upward) $ \awaitUp ->
                            withHandoffWorker (Relay.offerHandoffEdge link rootChannel relayRequest outerRelayInput childPayload unusedRelayTerminal) $ \awaitParent -> do
                                boundedHandoff "the original grant route" child >>= (@?= Left (Receiver.ReceiverDeclined relayFinished))
                                awaitParent >>= (@?= Left (relayChildDeclined relayFinished))
                                closeRootOutput
                                awaitUp >>= (@?= Right ())
                                awaitDown >>= (@?= Left (Protocol.ProtocolTruncated 8 0))
            sent <- readIORef originalRequest >>= requireObserved "the actual grant request"
            answered <- readIORef originalResponse >>= requireObserved "the actual grant response"
            opened@(selectedKey, openedVersion, openedBytes) <- readIORef openedRow >>= requireObserved "the actual initial token row"
            settled@(settledKey, settledVersion, settledBytes) <- readIORef settledRow >>= requireObserved "the actual settled token row"
            openedVersion @?= 1
            settledVersion @?= 2
            selectedKey @?= settledKey
            assertBool "the original row is planned" ("planned:" `ByteString.isPrefixOf` openedBytes)
            assertBool "the successful row is granted" ("granted:" `ByteString.isPrefixOf` settledBytes)
            assertBool "granting actually changes the selected row" (opened /= settled)
            readIORef nestedCallbacks >>= (@?= 1)
            withHandoffChannels $ \rootChannel relayChannel _ _ ->
                withHandoffWorker (Relay.offerHandoffEdge link rootChannel relayRequest outerRelayInput childPayload unusedRelayTerminal) $ \awaitParent -> do
                    retried <- boundedHandoff "the fresh grant replay route" $ receiveConfigRelay project relayChannel (rootBrokerVerificationKey broker) $ \_ -> do
                        before <- protectedHandoffImage store
                        Protocol.channelSend relayChannel sent >>= (@?= Right ())
                        replayed <- Protocol.channelReceive relayChannel >>= expectRight
                        Protocol.encodeProtocolMessage replayed @?= Protocol.encodeProtocolMessage answered
                        protectedHandoffImage store >>= (@?= before)
                        requireSingleHandoffRow [entry | entry@(key, _, _) <- before, key == selectedKey] >>= (@?= settled)
                        pure (Left relayFinished)
                    retried @?= Left (Receiver.ReceiverDeclined relayFinished)
                    awaitParent >>= (@?= Left (relayChildDeclined relayFinished))
            readIORef admissions >>= (@?= 3)
    ]

-- ---------------------------------------------------------------------------
-- Scripted parent, real receiver

receiverScriptTests :: [TestTree]
receiverScriptTests =
    [ testCase "the genuine receiver accepts its scoped offer and exact report acknowledgement" $
        withReceiverScriptOffer $ \project broker offer offered report ->
            withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                calls <- newIORef (0 :: Int)
                let receiver = runScriptedReceiver project child (rootBrokerVerificationKey broker) $ \_ sendReport -> do
                        modifyIORef' calls (+ 1)
                        sendReport report >>= (@?= Right ())
                        pure (Right ())
                withHandoffWorker receiver $ \awaitReceiver -> do
                    admitScriptedReceiver broker offer offered parent
                    acknowledgeScriptedReport parent report
                    awaitReceiver >>= (@?= Right ())
                    assertReceiverSilence parent closeChild
                readIORef calls >>= (@?= 1)
    , testCase "the receiver refuses a different advertised key after its valid capsule" $
        withReceiverScriptOffer $ \project broker _ offered _ -> do
            otherSigning <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 109))
            changed <- changeScriptedAuthentication offered $ \capsule _ evidence ->
                pure (frameWire capsule <> frameWire (TextEncoding.encodeUtf8 (verificationKeyDigest (projectSigningVerificationKey otherSigning))) <> evidence)
            checkEarlyReceiverRefusal project (rootBrokerVerificationKey broker) changed
                Receiver.ReceiverKeyMismatch "installed-key-mismatch"
    , testCase "the receiver refuses a valid capsule naming another installed project" $
        withReceiverScriptOffer $ \project broker _ offered _ -> do
            capsule <- authenticatedRootScopeOracleWire 108 canonicalAuthenticatedRootScopeSigningDomain
                (rootBrokerVerificationKey broker) (installedProjectName project <> "-other") "production" ""
            changed <- changeScriptedAuthentication offered $ \_ keyDigest evidence ->
                pure (frameWire capsule <> frameWire keyDigest <> evidence)
            checkEarlyReceiverRefusal project (rootBrokerVerificationKey broker) changed
                (Receiver.ReceiverHandoffFailure (HandoffBindingMismatch "the authenticated root scope names another installed project")) "unauthenticated"
    , testCase "a valid Harness capsule cannot reclassify a Production offer binding" $
        withReceiverScriptOffer $ \project broker _ offered _ -> do
            let key = rootBrokerVerificationKey broker
            capsule <- authenticatedRootScopeOracleWire 108 canonicalAuthenticatedRootScopeSigningDomain
                key (installedProjectName project) "harness" "scripted-run"
            withAuthenticatedRootScopeFromWire project key capsule
                (\_ _ -> "production" :: String) (\_ _ -> "harness") @?= Right "harness"
            changed <- changeScriptedAuthentication offered $ \_ keyDigest evidence ->
                pure (frameWire capsule <> frameWire keyDigest <> evidence)
            checkEarlyReceiverRefusal project key changed
                (Receiver.ReceiverHandoffFailure (HandoffBindingMismatch "the received binding names a different scope than the fixed handoff scope")) "unauthenticated"
    , testCase "raw three and five field Offers fail before a decoded request can be answered" $
        forM_ [3, 5] $ \fieldCount ->
            withReceiverScriptOffer $ \project broker _ offered _ ->
                withScriptedHandoffChannels $ \parent child rawParent _ closeChild -> do
                    calls <- newIORef (0 :: Int)
                    let expected = if fieldCount == 3
                            then Protocol.ProtocolWrongFieldCount Protocol.OfferTag 4 3
                            else Protocol.ProtocolExcessFields Protocol.OfferTag 4 8
                        receiver = runScriptedReceiver project child (rootBrokerVerificationKey broker) $ \_ _ ->
                            modifyIORef' calls (+ 1) >> pure (Left receiverFinished)
                    withHandoffWorker receiver $ \awaitReceiver -> do
                        writeScriptedArity rawParent offered fieldCount
                        awaitReceiver >>= (@?= Left (Receiver.ReceiverProtocolFailure expected))
                        assertReceiverSilence parent closeChild
                    readIORef calls >>= (@?= 0)
    , testCase "raw one and three field Grants refuse through the actual protocol decoder" $
        forM_ [1, 3] $ \fieldCount ->
            withReceiverScriptOffer $ \project broker offer offered _ ->
                withScriptedHandoffChannels $ \parent child rawParent _ closeChild -> do
                    calls <- newIORef (0 :: Int)
                    let expected = Receiver.ReceiverProtocolFailure $ if fieldCount == 1
                            then Protocol.ProtocolWrongFieldCount Protocol.GrantTag 2 1
                            else Protocol.ProtocolExcessFields Protocol.GrantTag 2 8
                        receiver = runScriptedReceiver project child (rootBrokerVerificationKey broker) $ \_ _ ->
                            modifyIORef' calls (+ 1) >> pure (Left receiverFinished)
                    withHandoffWorker receiver $ \awaitReceiver -> do
                        Protocol.channelSend parent offered >>= (@?= Right ())
                        granted <- scriptedGrant broker offer parent
                        writeScriptedArity rawParent granted fieldCount
                        assertScriptedRefusal parent expected "protocol"
                        awaitReceiver >>= (@?= Left expected)
                        assertReceiverSilence parent closeChild
                    readIORef calls >>= (@?= 0)
    , testCase "a wrong-identity parent refusal preserves the pending protocol error" $
        withReceiverScriptOffer $ \project broker offer offered _ ->
            withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                calls <- newIORef (0 :: Int)
                let expected = Receiver.ReceiverProtocolFailure (Protocol.ProtocolRequestMismatch relayRequest (relayRequest + 1))
                    receiver = runScriptedReceiver project child (rootBrokerVerificationKey broker) $ \_ _ ->
                        modifyIORef' calls (+ 1) >> pure (Left receiverFinished)
                withHandoffWorker receiver $ \awaitReceiver -> do
                    Protocol.channelSend parent offered >>= (@?= Right ())
                    _ <- scriptedGrant broker offer parent
                    refused <- expectRight (Protocol.protocolMessage Protocol.RefusedTag (relayRequest + 1) ["scripted-refusal", "wrong identity"])
                    Protocol.channelSend parent refused >>= (@?= Right ())
                    assertScriptedRefusal parent expected "protocol"
                    awaitReceiver >>= (@?= Left expected)
                    assertReceiverSilence parent closeChild
                readIORef calls >>= (@?= 0)
    , testCase "an invalid acknowledgement preserves its error and leaves one refusal to announce" $
        forM_ [False, True] $ \wrongIdentity ->
            withReceiverScriptOffer $ \project broker offer offered report ->
                withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                    let protocolFailure = if wrongIdentity
                            then Protocol.ProtocolRequestMismatch relayRequest (relayRequest + 1)
                            else Protocol.ProtocolAcknowledgementMismatch
                        expected = Receiver.ReceiverDeclined "the terminal action returned without one successful report send"
                        receiver = runScriptedReceiver project child (rootBrokerVerificationKey broker) $ \_ sendReport -> do
                            sendReport report >>= (@?= Left (Receiver.ReceiverProtocolFailure protocolFailure))
                            pure (Right ())
                    withHandoffWorker receiver $ \awaitReceiver -> do
                        admitScriptedReceiver broker offer offered parent
                        requireScriptedMessage parent Protocol.CompletedTag [report]
                        acknowledgement <- expectRight (renderLifecycleAcknowledgement report)
                        changed <- expectRight (Protocol.protocolMessage Protocol.AcknowledgedTag
                            (if wrongIdentity then relayRequest + 1 else relayRequest)
                            [if wrongIdentity then acknowledgement else acknowledgement <> "wrong"])
                        Protocol.channelSend parent changed >>= (@?= Right ())
                        assertScriptedRefusal parent expected "child-declined"
                        awaitReceiver >>= (@?= Left expected)
                        assertReceiverSilence parent closeChild
    , testCase "a callback Left before reporting sends one actual child refusal" $
        withReceiverScriptOffer $ \project broker offer offered _ ->
            withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                let expected = Receiver.ReceiverDeclined receiverFinished
                    receiver = runScriptedReceiver project child (rootBrokerVerificationKey broker) $ \_ _ -> pure (Left receiverFinished)
                withHandoffWorker receiver $ \awaitReceiver -> do
                    admitScriptedReceiver broker offer offered parent
                    assertScriptedRefusal parent expected "child-declined"
                    awaitReceiver >>= (@?= Left expected)
                    assertReceiverSilence parent closeChild
    , testCase "a callback IOException before reporting is announced once and rethrown" $
        withReceiverScriptOffer $ \project broker offer offered _ ->
            withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                let expected = Receiver.ReceiverCrashed (Text.pack (show (userError receiverCrashMarker)))
                    receiver = runScriptedReceiver project child (rootBrokerVerificationKey broker) $ \_ _ -> throwIO (userError receiverCrashMarker)
                withHandoffWorker (try @IOException receiver) $ \awaitReceiver -> do
                    admitScriptedReceiver broker offer offered parent
                    assertScriptedRefusal parent expected "child-failed"
                    awaitReceiver >>= assertScriptedIOException
                    assertReceiverSilence parent closeChild
    , testCase "a terminal callback that throws UserInterrupt escapes the receiver unwrapped" $
        withReceiverScriptOffer $ \project broker offer offered _ ->
            withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                let receiver = runScriptedReceiver project child (rootBrokerVerificationKey broker) $ \_ _ -> throwIO UserInterrupt
                -- An asynchronous exit is not announced as a child refusal; it leaves the receiver as itself.
                withHandoffWorker (try @SomeException receiver) $ \awaitReceiver -> do
                    admitScriptedReceiver broker offer offered parent
                    escaped <- awaitReceiver
                    case escaped of
                        Left failure -> (fromException failure :: Maybe AsyncException) @?= Just UserInterrupt
                        Right value -> assertFailure ("the interrupted terminal callback returned: " <> show (() <$ value))
                    assertReceiverSilence parent closeChild
    , testCase "a consumed terminal-report refusal cannot be echoed by callback Left" $
        withReceiverScriptOffer $ \project broker offer offered report ->
            withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                let receiver = runScriptedReceiver project child (rootBrokerVerificationKey broker) $ \_ sendReport -> do
                        sendReport report >>= (@?= Left (Receiver.ReceiverRefusedByParent "scripted-refusal" "the scripted parent refused"))
                        pure (Left receiverFinished)
                withHandoffWorker receiver $ \awaitReceiver -> do
                    admitScriptedReceiver broker offer offered parent
                    requireScriptedMessage parent Protocol.CompletedTag [report]
                    sendScriptedRefusal parent
                    awaitReceiver >>= (@?= Left (Receiver.ReceiverDeclined receiverFinished))
                    assertReceiverSilence parent closeChild
    , testCase "consumed relay refusals close the first report and any repeated parent operation" $
        forM_ [False, True] $ \rooted ->
            withReceiverScriptOffer $ \project broker offer offered report ->
                withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                    let key = rootBrokerVerificationKey broker
                        closedReport = Left (Receiver.ReceiverDeclined "the handoff protocol is already finished")
                        receiver = runScriptedReceiver project child key $ \edge sendReport ->
                            Relay.withConfigBrokerLink edge $ \_ link -> do
                                if rooted
                                    then do
                                        let request = rootedLifecycleOpenRequest (ByteString.replicate 32 17)
                                        first <- Relay.receiveRootedLifecycleResponseThroughLink key link request
                                        (() <$ first) @?= Left (Relay.RelayRefusedByPeer "scripted-refusal" "the scripted parent refused")
                                        sendReport report >>= (@?= closedReport)
                                        repeated <- Relay.receiveRootedLifecycleResponseThroughLink key link request
                                        (() <$ repeated) @?= Left Relay.RelayClosed
                                    else do
                                        withHandoffChannels $ \nested leaf _ _ ->
                                            withHandoffWorker (Protocol.channelReceive leaf) $ \awaitLeaf -> do
                                                Relay.offerHandoffEdge link nested relayRequest innerRelayInput childPayload unusedRelayTerminal
                                                    >>= (@?= Left (Relay.RelayRefusedByPeer "scripted-refusal" "the scripted parent refused"))
                                                refused <- awaitLeaf >>= expectRight
                                                Protocol.protocolMessageTag refused @?= Protocol.RefusedTag
                                                Protocol.protocolMessageFields refused @?= ["peer-refused", TextEncoding.encodeUtf8 (Text.pack (Relay.relayErrorMessage (Relay.RelayRefusedByPeer "scripted-refusal" "the scripted parent refused")))]
                                        sendReport report >>= (@?= closedReport)
                                        withHandoffChannels $ \nested leaf _ _ ->
                                            withHandoffWorker (Protocol.channelReceive leaf) $ \awaitLeaf -> do
                                                Relay.offerHandoffEdge link nested relayRequest innerRelayInput childPayload unusedRelayTerminal >>= (@?= Left Relay.RelayClosed)
                                                refused <- awaitLeaf >>= expectRight
                                                Protocol.protocolMessageTag refused @?= Protocol.RefusedTag
                                                Protocol.protocolMessageFields refused @?= ["route-closed", "handoff relay: the admitted parent route is closed"]
                                pure (Left receiverFinished)
                    withHandoffWorker receiver $ \awaitReceiver -> do
                        admitScriptedReceiver broker offer offered parent
                        requested <- boundedHandoff "the receiver's actual relay request" (Protocol.channelReceive parent) >>= expectRight
                        Protocol.protocolMessageRequestId requested @?= relayRequest
                        Protocol.protocolMessageTag requested @?= if rooted then Protocol.RootedLifecycleRequestTag else Protocol.OfferRequestTag
                        sendScriptedRefusal parent
                        awaitReceiver >>= (@?= Left (Receiver.ReceiverDeclined receiverFinished))
                        assertReceiverSilence parent closeChild
    , testCase "a signed rooted Refused leaves the admitted report route open" $
        withReceiverScriptOffer $ \project broker offer offered report ->
            withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                let key = rootBrokerVerificationKey broker
                    nonce = ByteString.replicate 32 19
                    predecessor = childConfigDigest "the scripted predecessor DATA"
                    request = rootedLifecyclePostRequest "next-node" ["relay-child"] "script-session" "script-stage" 1 nonce predecessor Nothing
                    unsigned = rootedLifecyclePostUnsigned "refused" request ["relay-child"] "script-session" "script-stage" 1 nonce "the signed DATA refusal"
                signed <- rootedLifecycleResponseOracleWire 108 canonicalRootedLifecycleResponseSigningDomain key request unsigned
                let receiver = runScriptedReceiver project child key $ \edge sendReport ->
                        Relay.withConfigBrokerLink edge $ \_ link -> do
                            answered <- Relay.receiveRootedLifecycleResponseThroughLink key link request
                            fmap renderRootedLifecycleResponse answered @?= Right signed
                            sendReport report >>= (@?= Right ())
                            pure (Right ())
                withHandoffWorker receiver $ \awaitReceiver -> do
                    admitScriptedReceiver broker offer offered parent
                    requested <- boundedHandoff "the receiver's signed-DATA request" (Protocol.channelReceive parent) >>= expectRight
                    Protocol.protocolMessageTag requested @?= Protocol.RootedLifecycleRequestTag
                    Protocol.protocolMessageRequestId requested @?= relayRequest
                    response <- relayMessage Protocol.RootedLifecycleResponseTag [signed]
                    Protocol.channelSend parent response >>= (@?= Right ())
                    acknowledgeScriptedReport parent report
                    awaitReceiver >>= (@?= Right ())
                    assertReceiverSilence parent closeChild
    , testCase "an acknowledged report leaves no frame for a later Left or IOException" $
        forM_ [False, True] $ \crash ->
            withReceiverScriptOffer $ \project broker offer offered report ->
                withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                    let receiver = runScriptedReceiver project child (rootBrokerVerificationKey broker) $ \_ sendReport -> do
                            sendReport report >>= (@?= Right ())
                            if crash then throwIO (userError receiverCrashMarker) else pure (Left receiverFinished)
                    withHandoffWorker (try @IOException receiver) $ \awaitReceiver -> do
                        admitScriptedReceiver broker offer offered parent
                        acknowledgeScriptedReport parent report
                        outcome <- awaitReceiver
                        if crash then assertScriptedIOException outcome else case outcome of
                            Right returned -> returned @?= Left (Receiver.ReceiverDeclined receiverFinished)
                            Left failure -> assertFailure (show failure)
                        assertReceiverSilence parent closeChild
    ]

-- ---------------------------------------------------------------------------
-- The receiver's untrusted wire boundary and embedded-payload limits

receiverCarrierTests :: [TestTree]
receiverCarrierTests =
    [ testCase "recovery projection coordinates retain read-only getters and their public Show form" $
        withRecoveryInput (RecoveryCoordinates "plan" "parent" "child") $ \input -> do
            (requestedRecoveryPlanDigest input, requestedRecoveryParentFrame input, requestedRecoveryChildFrame input)
                @?= ("plan", "parent", "child")
            let expected = "RecoveryProjectionBindingInput {requestedRecoveryPlanDigest = \"plan\", requestedRecoveryParentFrame = \"parent\", requestedRecoveryChildFrame = \"child\"}"
            show input @?= expected
            showsPrec 10 input "" @?= expected
            showsPrec 11 input "" @?= "(" <> expected <> ")"
    , testCase "the receiver admits exactly seven MiB before a successful report and acknowledgement" $
        withReceiverCarrierConfig (ByteString.replicate receiverCarrierLimit 120) $ \project broker offer offered report ->
            boundedHandoff "the exact-limit receiver dialogue" $
                withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                    calls <- newIORef (0 :: Int)
                    let receiver = Receiver.withReceivedHandoffEdge project child (rootBrokerVerificationKey broker)
                            (\_ config sendReport -> do
                                modifyIORef' calls (+ 1)
                                authenticatedConfigBytes config @?= ByteString.replicate receiverCarrierLimit 120
                                sendReport report >>= (@?= Right ())
                                pure (Right ()))
                            (\_ _ -> assertFailure "the bounded config entered recovery")
                            (\_ _ _ -> assertFailure "the bounded config entered Harness")
                            (\_ _ -> assertFailure "the bounded config entered Harness recovery")
                    withHandoffWorker receiver $ \awaitReceiver -> do
                        admitScriptedReceiver broker offer offered parent
                        acknowledgeScriptedReport parent report
                        awaitReceiver >>= (@?= Right ())
                        assertReceiverSilence parent closeChild
                    readIORef calls >>= (@?= 1)
    , testCase "the receiver refuses one byte over seven MiB before a challenge or branch" $
        withReceiverCarrierConfig (ByteString.replicate (receiverCarrierLimit + 1) 120) $ \project broker _ offered _ ->
            boundedHandoff "the over-limit receiver dialogue" $
                checkEarlyReceiverRefusal project (rootBrokerVerificationKey broker) offered
                    (Receiver.ReceiverWrongEdge "the embedded Offer payload exceeds its strict sub-ceiling")
                    "wrong-edge"
    , testCase "the real root Relay refuses an oversized payload before opening any edge" $
        withDuplexHandoffRoot $ \_ store _ link admissions ->
            boundedHandoff "the over-limit root Relay dialogue" $
                withHandoffChannels $ \parent child closeParent _ -> do
                    let payload = ByteString.replicate (receiverCarrierLimit + 1) 120
                        input = bindingInputFor payload
                        expected = Relay.RelayHandoffFailure
                            (HandoffBindingMismatch "the embedded Offer payload exceeds its strict sub-ceiling")
                    before <- protectedHandoffImage store
                    readIORef admissions >>= (@?= 0)
                    withHandoffWorker (Relay.offerHandoffEdge link parent relayRequest input payload unusedRelayTerminal) $ \awaitParent -> do
                        requireScriptedMessage child Protocol.RefusedTag
                            ["unauthenticated", TextEncoding.encodeUtf8 (Text.pack (Relay.relayErrorMessage expected))]
                        awaitParent >>= (@?= Left expected)
                        assertReceiverSilence child closeParent
                    readIORef admissions >>= (@?= 0)
                    protectedHandoffImage store >>= (@?= before)
    , testCase "the whole Offer body remains independently bounded when its payload is seven MiB" $
        withReceiverCarrierConfig (ByteString.replicate receiverCarrierLimit 120) $ \_ _ _ offered _ ->
            case Protocol.protocolMessageFields offered of
                [payload, token, binding, authentication] -> do
                    let bodyLength = ByteString.length (Protocol.encodeProtocolMessage offered) - 8
                        padding = 8388609 - bodyLength
                    assertBool "the genuine exact-limit Offer leaves positive whole-body headroom" (padding > 0)
                    (() <$ Protocol.protocolMessage Protocol.OfferTag relayRequest
                        [payload, token, binding, authentication <> ByteString.replicate padding 0])
                        @?= Left (Protocol.ProtocolBodyTooLarge 8388609 8388608)
                fields -> assertFailure ("the genuine carrier Offer had " <> show (length fields) <> " fields")
    , testCase "the genuine recovery package and adapter grant reach the recovery report route" $
        withReceiverRecoveryCarrier "teardown" False $ \project broker offer offered ->
            completeReceiverRecoveryCarrier project broker offer offered Nothing
    , testCase "a genuine recovery grant with the wrong phase refuses before branch exposure" $
        withReceiverRecoveryCarrier "execute" False $ \project broker offer offered ->
            refuseReceiverRecoveryCarrier project broker offer offered
                (Receiver.ReceiverWrongEdge "a recovery adapter must authorize teardown, received execute")
                "wrong-edge"
    , testCase "a genuine other rooted proof cannot be paired with the recovery offer" $
        withReceiverRecoveryCarrier "teardown" True $ \project broker offer offered ->
            refuseReceiverRecoveryCarrier project broker offer offered
                (Receiver.ReceiverHandoffFailure (HandoffBindingMismatch "the rooted edge is not the verified one-use edge"))
                "unauthenticated"
    , testCase "a supported Down oracle control precedes the hostile teardown verb refusal" $
        forM_ [False, True] $ \hostile ->
            withReceiverRecoveryCarrier "teardown" False $ \project broker offer original -> do
                offered <- case Protocol.protocolMessageFields original of
                    [payload, token, binding, authentication] -> do
                        fields <- framesOf binding
                        length fields @?= 13
                        let changed = wireWithFrames [(10, "unsupported-scripted-verb")] fields
                        assertBool "the hostile wire changes the canonical verb coordinate" (changed /= binding)
                        relayMessage Protocol.OfferTag
                            [payload, token, if hostile then changed else binding, authentication]
                    fields -> assertFailure ("the genuine recovery Offer had " <> show (length fields) <> " fields")
                -- Only the descriptive binding and its dependent ordinary grant
                -- change. The genuine Down package/projection/signatures stay
                -- intact; verb classification precedes their interpretation.
                if hostile
                    then refuseReceiverRecoveryCarrierWith project broker offered
                        (scriptedOracleGrant 110 (rootBrokerVerificationKey broker) offered)
                        (Receiver.ReceiverWrongEdge "a recovery adapter has an unsupported verb, received unsupported-scripted-verb")
                        "wrong-edge"
                    else completeReceiverRecoveryCarrier project broker offer offered
                        (Just (scriptedOracleGrant 110 (rootBrokerVerificationKey broker) offered))
    ]

receiverCarrierLimit :: Int
receiverCarrierLimit = 7 * 1024 * 1024

withReceiverCarrierConfig ::
    ByteString.ByteString ->
    (forall projectId generation.
        InstalledProjectIdentity projectId -> RootBroker (Production projectId) generation VerbUp ->
        HandoffOffer (Production projectId) generation -> Protocol.ProtocolMessage -> ByteString.ByteString -> IO ()) ->
    IO ()
withReceiverCarrierConfig payload use =
    withNamedHandoff 109 ProjectUp $ \project broker -> do
        (binding, offer) <- newOfferWith broker (bindingInputFor payload) payload
        capsule <- signAuthenticatedRootScopeKernel HandoffInternal.recoverySigningKernel broker (productionHandoffScope project) >>= expectRight
        rooted <- signRootedPayloadBindingKernel HandoffInternal.recoverySigningKernel broker offer payload >>= expectRight
        let key = rootBrokerVerificationKey broker
            authentication = renderFrameFields
                [renderAuthenticatedRootScope capsule, TextEncoding.encodeUtf8 (verificationKeyDigest key), renderRootedPayloadBinding rooted]
            (exactPayload, token, bindingBytes) = handoffOfferFrames offer
        offered <- relayMessage Protocol.OfferTag [exactPayload, token, bindingBytes, authentication]
        report <- expectRight (renderForwardCompletedLifecycleReport (forwardLifecycleOrigin (renderHandoffBinding binding)))
        use project broker offer offered report

withReceiverRecoveryCarrier ::
    Text.Text -> Bool ->
    (forall projectId generation.
        InstalledProjectIdentity projectId -> RootBroker (Production projectId) generation VerbDown ->
        HandoffOffer (Production projectId) generation -> Protocol.ProtocolMessage -> IO ()) ->
    IO ()
withReceiverRecoveryCarrier phase crossProof use =
    withNamedHandoff 110 ProjectDown $ \project broker -> do
        let childConfig = "the scripted recovery child config"
            adapter = "the scripted recovery adapter"
            packageBytes = renderFrameFields [childConfig, adapter]
            input = (bindingInputFor packageBytes){requestedPayloadKind = RecoveryAdapterWire, requestedPhase = phase}
            key = rootBrokerVerificationKey broker
        assertBool "the package and child config have distinct digests"
            (childConfigDigest packageBytes /= childConfigDigest childConfig)
        (joinedBinding, joinedOffer) <- newOfferWith broker input{requestedPhase = "teardown"} packageBytes
        joined <- verifyOfferedHandoff broker joinedBinding joinedOffer
        joinedWire <- rootedOracleWire 110 canonicalRootedPayloadSigningDomain key
            (renderHandoffBinding joinedBinding) (childConfigDigest packageBytes) (childConfigDigest childConfig)
        joinedRooted <- expectRight (withVerifiedRootedPayloadBinding joined joinedWire id)
        action <- expectRight (withVerifiedRecoveryChildPackage joined joinedRooted $ \package configBytes adapterBytes -> do
            (renderRecoveryChildPackage package, configBytes, adapterBytes) @?= (packageBytes, childConfig, adapter)
            withRecoveryInput (RecoveryCoordinates (requestedPlanRevision input) (requestedParentFrame input) (requestedChildFrame input)) $ \coordinates ->
                withRecoveryBinding broker coordinates adapter $ \projection -> do
                    granted <- signRecoveryWireKernel HandoffInternal.recoverySigningKernel broker
                        (pure (Right adapter :: Either Text.Text ByteString.ByteString)) projection adapter
                        >>= expectRight >>= expectRight
                    withVerifiedRecoveryWire key projection adapter granted verifiedRecoveryWireBytes @?= Right adapter
                    (binding, offer) <- newOfferWith broker input packageBytes
                    rooted <- if crossProof
                        then do
                            (otherBinding, otherOffer) <- newOfferWith broker input packageBytes
                            assertBool "the cross-paired proof names a genuinely different edge"
                                (renderHandoffBinding otherBinding /= renderHandoffBinding binding)
                            other <- signRecoveryChildPackageBindingKernel HandoffInternal.recoverySigningKernel broker otherOffer package >>= expectRight
                            verifiedOther <- verifyOfferedHandoff broker otherBinding otherOffer
                            withVerifiedRootedPayloadBinding verifiedOther (renderRootedPayloadBinding other) (const ()) @?= Right ()
                            pure other
                        else signRecoveryChildPackageBindingKernel HandoffInternal.recoverySigningKernel broker offer package >>= expectRight
                    capsule <- signAuthenticatedRootScopeKernel HandoffInternal.recoverySigningKernel broker (productionHandoffScope project) >>= expectRight
                    let authentication = renderFrameFields
                            [ renderAuthenticatedRootScope capsule, TextEncoding.encodeUtf8 (verificationKeyDigest key)
                            , renderRootedPayloadBinding rooted, renderRecoveryProjectionBinding projection, recoveryWireGrantSignature granted
                            ]
                        (payload, token, bindingBytes) = handoffOfferFrames offer
                    offered <- relayMessage Protocol.OfferTag [payload, token, bindingBytes, authentication]
                    use project broker offer offered
            )
        action

completeReceiverRecoveryCarrier ::
    InstalledProjectIdentity projectId -> RootBroker (Production projectId) generation VerbDown ->
    HandoffOffer (Production projectId) generation -> Protocol.ProtocolMessage ->
    Maybe (Protocol.HandoffChannel -> IO Protocol.ProtocolMessage) -> IO ()
completeReceiverRecoveryCarrier project broker offer offered oracle =
    boundedHandoff "the complete recovery carrier dialogue" $
        withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
            calls <- newIORef (0 :: Int)
            observations <- expectRight (renderLifecycleObservations [(handoffChildFrame (handoffOfferBinding offer), "released", "none")])
            report <- expectRight (renderReverseCompletedLifecycleReport (reverseLifecycleOrigin (handoffOfferBinding offer)) observations)
            let receiver = Receiver.withReceivedHandoffEdge project child (rootBrokerVerificationKey broker)
                    (\_ _ _ -> assertFailure "the recovery carrier entered config")
                    (\descent sendReport -> Relay.withRecoveryBrokerLink descent $ \_ _ -> do
                        modifyIORef' calls (+ 1)
                        sendReport report >>= (@?= Right ())
                        pure (Right ()))
                    (\_ _ _ -> assertFailure "the recovery carrier entered Harness config")
                    (\_ _ -> assertFailure "the recovery carrier entered Harness recovery")
            withHandoffWorker receiver $ \awaitReceiver -> do
                Protocol.channelSend parent offered >>= (@?= Right ())
                granted <- maybe (scriptedGrant broker offer parent) ($ parent) oracle
                Protocol.channelSend parent granted >>= (@?= Right ())
                requireScriptedMessage parent Protocol.AcceptedTag
                    [TextEncoding.encodeUtf8 (handoffChildConfigDigest (handoffOfferBinding offer))]
                acknowledgeScriptedReport parent report
                awaitReceiver >>= (@?= Right ())
                assertReceiverSilence parent closeChild
            readIORef calls >>= (@?= 1)

refuseReceiverRecoveryCarrier ::
    InstalledProjectIdentity projectId -> RootBroker (Production projectId) generation VerbDown ->
    HandoffOffer (Production projectId) generation -> Protocol.ProtocolMessage ->
    Receiver.ReceiverError -> ByteString.ByteString -> IO ()
refuseReceiverRecoveryCarrier project broker offer offered =
    refuseReceiverRecoveryCarrierWith project broker offered (scriptedGrant broker offer)

refuseReceiverRecoveryCarrierWith ::
    InstalledProjectIdentity projectId -> RootBroker (Production projectId) generation VerbDown ->
    Protocol.ProtocolMessage -> (Protocol.HandoffChannel -> IO Protocol.ProtocolMessage) ->
    Receiver.ReceiverError -> ByteString.ByteString -> IO ()
refuseReceiverRecoveryCarrierWith project broker offered grant expected code =
    boundedHandoff "the refused recovery carrier dialogue" $
        withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
            calls <- newIORef (0 :: Int)
            let exposed = modifyIORef' calls (+ 1) >> pure (Right ())
                receiver = Receiver.withReceivedHandoffEdge project child (rootBrokerVerificationKey broker)
                    (\_ _ _ -> exposed) (\_ _ -> exposed) (\_ _ _ -> exposed) (\_ _ -> exposed)
            withHandoffWorker receiver $ \awaitReceiver -> do
                Protocol.channelSend parent offered >>= (@?= Right ())
                granted <- grant parent
                Protocol.channelSend parent granted >>= (@?= Right ())
                assertScriptedRefusal parent expected code
                awaitReceiver >>= (@?= Left expected)
                assertReceiverSilence parent closeChild
            readIORef calls >>= (@?= 0)

-- Ordinary hostile-wire DATA, not a RootBroker issuance function. The matching
-- Down control exercises this exact oracle through every receiver join first.
scriptedOracleGrant ::
    Word8 -> ProjectVerificationKey -> Protocol.ProtocolMessage ->
    Protocol.HandoffChannel -> IO Protocol.ProtocolMessage
scriptedOracleGrant seed key offered parent = do
    challenge <- boundedHandoff "the oracle's actual receiver challenge" (Protocol.channelReceive parent) >>= expectRight
    Protocol.protocolMessageTag challenge @?= Protocol.ChallengeTag
    Protocol.protocolMessageRequestId challenge @?= relayRequest
    case (Protocol.protocolMessageFields offered, Protocol.protocolMessageFields challenge) of
        ([_payload, token, binding, _authentication], [nonce]) -> do
            parsed <- expectRight (handoffChallengeFromBytes nonce)
            challengeBytes parsed @?= nonce
            case Ed25519.secretKey (ByteString.replicate 32 seed) of
                CryptoFailed failure -> assertFailure ("the ordinary grant DATA seed failed: " <> show failure)
                CryptoPassed secret -> do
                    let material = renderFrameFields
                            [ "hostbootstrap/handoff-grant", lifecycleWordBytesFor 1
                            , TextEncoding.encodeUtf8 (verificationKeyDigest key), binding, token, nonce
                            ]
                        signature :: ByteString.ByteString
                        signature = convert (Ed25519.sign secret (Ed25519.toPublic secret) material)
                    relayMessage Protocol.GrantTag [signature, TextEncoding.encodeUtf8 (verificationKeyDigest key)]
        _ -> assertFailure "the genuine Offer or Challenge changed its exact field shape"

-- ---------------------------------------------------------------------------
-- Rooted requester parsing and terminal progress through the real duplex route

rootedRequesterTransportTests :: [TestTree]
rootedRequesterTransportTests =
    [ testCase "the actual root parses requester path limits before its DATA service" $ do
        let admitted = "relay-child"
            pathBytes = renderFrameFields . map TextEncoding.encodeUtf8
            limitPath = admitted : replicate 255 "nested"
            widePath = [admitted, Text.replicate 4096 "x"]
            mismatch = Relay.RelayHandoffFailure . HandoffBindingMismatch
            serviceReached = Relay.RelayEdgeNotPlanned "the requester parser DATA service was reached"
            cases =
                [ (pathBytes (admitted : replicate 256 "nested"), [], mismatch "the relay requester path exceeds the protocol depth limit")
                , (pathBytes [admitted, ""], [], mismatch "the relay requester path contains an empty frame")
                , (frameWire (TextEncoding.encodeUtf8 admitted) <> frameWire (ByteString.singleton 255), [],
                    mismatch "the relay requester path contains invalid UTF-8")
                , (frameWire (TextEncoding.encodeUtf8 admitted) <> ByteString.take 8 (frameWire (ByteString.replicate 4097 120)) <> "x", [],
                    mismatch "the relay requester path declares an oversized frame")
                , (pathBytes limitPath, [limitPath], serviceReached)
                , (pathBytes widePath, [widePath], serviceReached)
                , (pathBytes ["another-served-child"], [], mismatch "the relay requester path does not begin at the exact admitted child")
                ]
        forM_ cases $ \(rawPath, expectedPaths, expected) ->
            checkRequesterRelayMutation False expectedPaths expected $ \message ->
                case Protocol.protocolMessageFields message of
                    [enveloped] -> do
                        fields <- framesOf enveloped
                        case fields of
                            [domain, originalPath, exactRequest] -> do
                                domain @?= "hostbootstrap-relay-requester-path-v1"
                                assertBool "the path mutation changes the genuine envelope" (originalPath /= rawPath)
                                relayMessage Protocol.RootedLifecycleRequestTag
                                    [renderFrameFields [domain, rawPath, exactRequest]]
                            _ -> assertFailure "the real rooted envelope did not have its three fields"
                    _ -> assertFailure "the real rooted request did not have its singleton field"
    , testCase "the actual root refuses another requested parent before edge admission" $
        checkRequesterRelayMutation True []
            (Relay.RelayHandoffFailure (HandoffBindingMismatch "the requested parent frame is not the authenticated path origin")) $ \message ->
                case Protocol.protocolMessageFields message of
                    [enveloped] -> do
                        fields <- framesOf enveloped
                        case fields of
                            [domain, path, rawInput] -> do
                                input <- expectRight (handoffBindingInputFromWire rawInput)
                                input @?= innerRelayInput
                                let changed = input{requestedParentFrame = "another-parent"}
                                assertBool "only the requested parent coordinate changes" (changed /= input)
                                relayMessage Protocol.OfferRequestTag
                                    [renderFrameFields [domain, path, renderHandoffBindingInput changed]]
                            _ -> assertFailure "the real open envelope did not have its three fields"
                    _ -> assertFailure "the real open request did not have its singleton field"
    , testCase "a real self-sent Relay refusal closes the first report and repeated parent operation" $
        forM_ [False, True] $ \rooted ->
            withReceiverScriptOffer $ \project broker offer offered report ->
                boundedHandoff "the self-sent refusal dialogue" $
                    withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                        let key = rootBrokerVerificationKey broker
                            request = rootedLifecycleOpenRequest (ByteString.replicate 32 29)
                            expected = Relay.RelayUnexpectedMessage Protocol.GrantResponseTag
                            receiver = runScriptedReceiver project child key $ \edge sendReport ->
                                Relay.withConfigBrokerLink edge $ \_ link -> do
                                    if rooted
                                        then do
                                            first <- Relay.receiveRootedLifecycleResponseThroughLink key link request
                                            (() <$ first) @?= Left expected
                                        else checkNestedRelayRefusal link expected
                                    sendReport report >>= (@?= Left (Receiver.ReceiverDeclined "the handoff protocol is already finished"))
                                    repeated <- Relay.receiveRootedLifecycleResponseThroughLink key link request
                                    (() <$ repeated) @?= Left Relay.RelayClosed
                                    pure (Left receiverFinished)
                        withHandoffWorker receiver $ \awaitReceiver -> do
                            admitScriptedReceiver broker offer offered parent
                            sent <- boundedHandoff "the actual upstream Relay operation" (Protocol.channelReceive parent) >>= expectRight
                            Protocol.protocolMessageRequestId sent @?= relayRequest
                            Protocol.protocolMessageTag sent @?= if rooted then Protocol.RootedLifecycleRequestTag else Protocol.OfferRequestTag
                            wrong <- relayMessage Protocol.GrantResponseTag ["the wrong upstream tag"]
                            Protocol.channelSend parent wrong >>= (@?= Right ())
                            requireScriptedMessage parent Protocol.RefusedTag
                                ["unexpected-message", TextEncoding.encodeUtf8 (Text.pack (Relay.relayErrorMessage expected))]
                            awaitReceiver >>= (@?= Left (Receiver.ReceiverDeclined receiverFinished))
                            assertReceiverSilence parent closeChild
    , testCase "a genuine pre-send envelope failure inside the fixed Relay wrapper leaves notification live" $
        withReceiverPathOffer (Text.replicate 4097 "x") $ \project broker offer offered ->
            boundedHandoff "the local pre-send failure dialogue" $
                withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
                    calls <- newIORef (0 :: Int)
                    let key = rootBrokerVerificationKey broker
                        request = rootedLifecycleOpenRequest (ByteString.replicate 32 30)
                        expected = Relay.RelayHandoffFailure (HandoffBindingMismatch "the relay requester path contains an oversized frame")
                        receiver = runScriptedReceiver project child key $ \edge _ ->
                            Relay.withConfigBrokerLink edge $ \_ link -> do
                                modifyIORef' calls (+ 1)
                                local <- Relay.receiveRootedLifecycleResponseThroughLink key link request
                                (() <$ local) @?= Left expected
                                pure (Left receiverFinished)
                    withHandoffWorker receiver $ \awaitReceiver -> do
                        admitScriptedReceiver broker offer offered parent
                        -- No rooted request was transmitted: the first next frame
                        -- is the Receiver's legitimate callback-failure notice.
                        assertScriptedRefusal parent (Receiver.ReceiverDeclined receiverFinished) "child-declined"
                        awaitReceiver >>= (@?= Left (Receiver.ReceiverDeclined receiverFinished))
                        assertReceiverSilence parent closeChild
                    readIORef calls >>= (@?= 1)
    ]

checkRequesterRelayMutation ::
    Bool -> [[Text.Text]] -> Relay.RelayError ->
    (Protocol.ProtocolMessage -> IO Protocol.ProtocolMessage) -> IO ()
checkRequesterRelayMutation opening expectedPaths expected mutate = do
    serviceCalls <- newIORef []
    let service path exactRequest = do
            modifyIORef' serviceCalls (<> [(path, exactRequest)])
            pure (Left (Relay.RelayEdgeNotPlanned "the requester parser DATA service was reached"))
    withDuplexHandoffRootService service $ \project store broker link admissions ->
        boundedHandoff "the requester-parser duplex dialogue" $
            withHandoffChannels $ \rootChannel rootProxy closeRootOutput _ ->
                withHandoffChannels $ \relayProxy relayChannel _ closeRelayOutput -> do
                    mutations <- newIORef (0 :: Int)
                    before <- newEmptyMVar
                    let key = rootBrokerVerificationKey broker
                        request = rootedLifecycleOpenRequest (ByteString.replicate 32 28)
                        target = if opening then Protocol.OfferRequestTag else Protocol.RootedLifecycleRequestTag
                        upward message
                            | Protocol.protocolMessageTag message == target = do
                                modifyIORef' mutations (+ 1)
                                Just <$> mutate message
                            | otherwise = pure (Just message)
                        downward message
                            | Protocol.protocolMessageTag message == Protocol.RefusedTag = do
                                Protocol.channelSend relayProxy message >>= (@?= Right ())
                                pure Nothing
                            | otherwise = pure (Just message)
                        expectedPeer = Relay.RelayRefusedByPeer
                            (case expected of Relay.RelayEdgeNotPlanned _ -> "edge-not-planned"; _ -> "unauthenticated")
                            (Text.pack (Relay.relayErrorMessage expected))
                        parent = Relay.offerHandoffEdge link rootChannel relayRequest outerRelayInput childPayload unusedRelayTerminal
                        child = receiveConfigRelay project relayChannel key $ \nestedLink -> do
                            protectedHandoffImage store >>= putMVar before
                            if opening
                                then checkNestedRelayRefusal nestedLink expectedPeer
                                else do
                                    answered <- Relay.receiveRootedLifecycleResponseThroughLink key nestedLink request
                                    (() <$ answered) @?= Left expectedPeer
                            pure (Left relayFinished)
                    withHandoffWorker (forwardHandoffMessages rootProxy relayProxy downward) $ \awaitDown ->
                        withHandoffWorker (forwardHandoffMessages relayProxy rootProxy upward) $ \awaitUp ->
                            withHandoffWorker parent $ \awaitParent -> do
                                child >>= (@?= Left (Receiver.ReceiverDeclined relayFinished))
                                closeRelayOutput
                                awaitParent >>= (@?= Left expected)
                                closeRootOutput
                                awaitDown >>= (@?= Right ())
                                awaitUp >>= (@?= Left (Protocol.ProtocolTruncated 8 0))
                    readIORef mutations >>= (@?= 1)
                    readIORef admissions >>= (@?= 1)
                    readIORef serviceCalls >>= (@?= [(path, request) | path <- expectedPaths])
                    original <- readMVar before
                    protectedHandoffImage store >>= (@?= original)

checkNestedRelayRefusal :: Relay.BrokerLink scope generation -> Relay.RelayError -> IO ()
checkNestedRelayRefusal link expected =
    withHandoffChannels $ \nested leaf _ _ ->
        withHandoffWorker (Protocol.channelReceive leaf) $ \awaitLeaf -> do
            Relay.offerHandoffEdge link nested relayRequest innerRelayInput childPayload unusedRelayTerminal
                >>= (@?= Left expected)
            refused <- awaitLeaf >>= expectRight
            Protocol.protocolMessageTag refused @?= Protocol.RefusedTag
            Protocol.protocolMessageRequestId refused @?= relayRequest
            code <- case expected of
                Relay.RelayRefusedByPeer _ _ -> pure "peer-refused"
                Relay.RelayUnexpectedMessage _ -> pure "unexpected-message"
                Relay.RelayClosed -> pure "route-closed"
                _ -> assertFailure "the nested refusal helper received an unsupported expected category"
            Protocol.protocolMessageFields refused @?=
                [code, TextEncoding.encodeUtf8 (Text.pack (Relay.relayErrorMessage expected))]

withReceiverPathOffer ::
    Text.Text ->
    (forall projectId generation.
        InstalledProjectIdentity projectId -> RootBroker (Production projectId) generation VerbUp ->
        HandoffOffer (Production projectId) generation -> Protocol.ProtocolMessage -> IO ()) -> IO ()
withReceiverPathOffer childFrame use =
    withNamedHandoff 112 ProjectUp $ \project broker -> do
        (binding, offer) <- newOfferWith broker outerRelayInput{requestedChildFrame = childFrame} childPayload
        handoffChildFrame binding @?= childFrame
        capsule <- signAuthenticatedRootScopeKernel HandoffInternal.recoverySigningKernel broker (productionHandoffScope project) >>= expectRight
        rooted <- signRootedPayloadBindingKernel HandoffInternal.recoverySigningKernel broker offer childPayload >>= expectRight
        let authentication = renderFrameFields
                [renderAuthenticatedRootScope capsule, TextEncoding.encodeUtf8 (verificationKeyDigest (rootBrokerVerificationKey broker)), renderRootedPayloadBinding rooted]
            (payload, token, bindingBytes) = handoffOfferFrames offer
        offered <- relayMessage Protocol.OfferTag [payload, token, bindingBytes, authentication]
        use project broker offer offered

-- ---------------------------------------------------------------------------
-- Native Windows observations are test-owned. Their unsupported row says
-- nothing about a POSIX group's behavior or an unavailable production API.
windowsChildGroupObservationSupported :: Bool
#if defined(mingw32_HOST_OS)
windowsChildGroupObservationSupported = True
#else
windowsChildGroupObservationSupported = False
#endif

windowsChildGroupTests :: [TestTree]
windowsChildGroupTests =
    [ row "returning from the acquired group ends its live child and grandchild" (directChildGroupExit "return")
    , row "an ordinary callback exception ends the acquired child tree and is preserved" (directChildGroupExit "exception")
    , row "ThreadKilled ends the acquired child tree and remains asynchronous cancellation" (directChildGroupExit "cancel")
    , row "reaping the leader first leaves its grandchild owned until bracket exit" (directChildGroupExit "leader-first")
    , row "the actual frame transaction owns and ends its interpreter's native grandchild" frameChildGroupIntegration
    ]
  where
    row name action = conditionalCase ["HandoffSpec", "native Windows child groups"]
        windowsChildGroupObservationSupported name action assertNativeObservationUnavailable

nativeObservationUnavailable :: String
nativeObservationUnavailable = "native Windows job observation unavailable on this host"

assertNativeObservationUnavailable :: IO ()
assertNativeObservationUnavailable = do
    observed <- acquireNativeTreeObservation (0, 0)
    case observed of
        Left detail -> detail @?= nativeObservationUnavailable
        Right _ -> assertFailure "native Windows observation unexpectedly succeeded on this host"
    executable <- getExecutablePath
    crossed <- boundedChildGroup "the unsupported-row local frame control" $
        withFrameChildTransaction unresolvedHostConfig
            (mkSelfRef (LocalSelfPath executable) (InVMSelfPath executable)) localContext
            "hostbootstrap/cluster-exposure/request/v1\0"
    crossed @?= Left "frame child: the frame refused the transaction: unavailable: the cluster exposure request does not contain exactly three fields"
    withHandoffPackageRoot $ \packageRoot -> do
        transaction <- readFile =<< handoffModulePath packageRoot "HostBootstrap.Handoff.Transaction"
        SourceGuard.countHaskellIdentifier "CPP" transaction @?= 0
        childGroup <- readFile (packageRoot </> "internal" </> "effect" </> "HostBootstrap" </> "Effect" </> "ChildGroup.hs")
        assertBool "native job operations stay within the platform owner" ("#if defined(mingw32_HOST_OS)" `isInfixOf` childGroup)
        assertBool "the transaction delegates its acquired group" (SourceGuard.countHaskellIdentifier "withChildGroupProcess" transaction > 0)

boundedChildGroup :: String -> IO value -> IO value
boundedChildGroup label action =
    timeout (30 * 1000000) action >>= maybe (assertFailure (label <> " exceeded thirty seconds")) pure

withChildTreeWorker :: IO value -> (ThreadId -> MVar (Either SomeException value) -> IO result) -> IO result
withChildTreeWorker action use = mask $ \restore -> do
    completed <- newEmptyMVar
    worker <- forkFinally (restore action) (putMVar completed)
    restore (use worker completed) `finally`
        boundedChildGroup "the native child-tree worker finalizer" (killThread worker >> readMVar completed >> pure ())

awaitTreePids :: FilePath -> IO (Word32, Word32)
awaitTreePids directory = boundedChildGroup "native child and grandchild readiness" loop
  where
    loop = do
        leader <- readPid (directory </> "leader.pid")
        descendant <- readPid (directory </> "grandchild.pid")
        case (leader, descendant) of
            (Just first, Just second) -> pure (first, second)
            _ -> threadDelay 10000 >> loop
    readPid path = do
        attempted <- try (ByteString.readFile path) :: IO (Either IOException ByteString.ByteString)
        case attempted of
            Left failure | isDoesNotExistError failure -> pure Nothing
            Left failure -> throwIO failure
            Right bytes ->
                let value = ByteStringChar8.unpack bytes
                 in case reverse value of
                        '\n' : _ -> pure (readMaybe value)
                        _ -> pure Nothing

directChildGroupExit :: String -> IO ()
directChildGroupExit disposition = withSystemTempDirectory "hostbootstrap-native-child-tree" $ \directory -> do
    executable <- getExecutablePath
    release <- newEmptyMVar
    launched <- newEmptyMVar :: IO (MVar ProcessHandle)
    let command = (proc executable ["--hostbootstrap-child-group-probe", "leader", directory])
            { std_in = NoStream, std_out = NoStream, std_err = Inherit, create_group = True, close_fds = True }
        launch = ChildGroup.withChildGroupProcess command $ \_ _ _ child _ ->
            putMVar launched child >> takeMVar release
    withChildTreeWorker launch $ \worker completed -> do
        child <- boundedChildGroup "the acquired child callback" (readMVar launched)
        pids <- awaitTreePids directory
        bracket (acquireNativeTreeObservation pids >>= expectRight) releaseNativeTreeObservation $ \observation -> do
            assertNativeTreeAlive observation
            case disposition of
                "return" -> putMVar release ()
                "exception" -> throwTo worker (userError "the child-group callback failed")
                "cancel" -> killThread worker
                "leader-first" -> do
                    writeFile (directory </> "exit-leader") "exit\n"
                    assertNativeLeaderExited observation
                    getProcessExitCode child >>= (@?= Just ExitSuccess)
                    assertNativeGrandchildAlive observation
                    putMVar release ()
                _ -> assertFailure ("unknown child-tree disposition: " <> disposition)
            outcome <- boundedChildGroup "the acquired group result" (readMVar completed)
            case (disposition, outcome) of
                ("exception", Left failure) -> case fromException failure :: Maybe IOException of
                    Just cause -> ioeGetErrorString cause @?= "the child-group callback failed"
                    Nothing -> assertFailure ("callback changed exception: " <> show failure)
                ("cancel", Left failure) -> (fromException failure :: Maybe AsyncException) @?= Just ThreadKilled
                (_, Right ()) | disposition `elem` ["return", "leader-first"] -> pure ()
                _ -> assertFailure ("unexpected child-tree completion: " <> show outcome)
            assertNativeTreeGone observation

frameChildGroupIntegration :: IO ()
frameChildGroupIntegration = withSystemTempDirectory "hostbootstrap-frame-child-tree" $ \directory -> do
    executable <- getExecutablePath
    let transaction = LazyByteString.toStrict (Aeson.encode ("hostbootstrap/frame-tree-fixture/v1" :: String, directory))
        launch = withFrameChildTransaction unresolvedHostConfig
            (mkSelfRef (LocalSelfPath executable) (InVMSelfPath executable)) localContext transaction
    withChildTreeWorker launch $ \_ completed -> do
        pids <- awaitTreePids directory
        bracket (acquireNativeTreeObservation pids >>= expectRight) releaseNativeTreeObservation $ \observation -> do
            assertNativeTreeAlive observation
            writeFile (directory </> "exit-leader") "exit\n"
            outcome <- boundedChildGroup "the frame transaction tree result" (readMVar completed)
            case outcome of
                Right result -> result @?= Right "frame-tree-fixture-complete"
                Left failure -> throwIO failure
            assertNativeTreeGone observation

-- The test executable alone extends its interpreter with this fixed DATA case.
-- The ordinary frame interpreter and production entry remain unchanged.
frameChildFixtureInterpreter ::
    (ByteString.ByteString -> IO (Either Text.Text ByteString.ByteString)) ->
    ByteString.ByteString -> IO (Either Text.Text ByteString.ByteString)
frameChildFixtureInterpreter ordinary transaction =
    case Aeson.eitherDecodeStrict' transaction :: Either String (String, FilePath) of
        Right ("hostbootstrap/frame-tree-fixture/v1", directory) -> do
            runChildGroupProbe "leader" directory
            pure (Right "frame-tree-fixture-complete")
        _ -> ordinary transaction

runChildGroupProbe :: String -> FilePath -> IO ()
#if defined(mingw32_HOST_OS)
runChildGroupProbe mode directory = do
    identity <- rawTreeCurrentProcessId
    case mode of
        "grandchild" -> do
            writeFile (directory </> "grandchild.pid") (show identity <> "\n")
            -- A failed setup cannot leave an unbounded unobserved fixture.
            threadDelay (60 * 1000000)
        "leader" -> do
            writeFile (directory </> "leader.pid") (show identity <> "\n")
            executable <- getExecutablePath
            _ <- createProcess (proc executable ["--hostbootstrap-child-group-probe", "grandchild", directory])
                { std_in = NoStream, std_out = NoStream, std_err = NoStream, close_fds = True }
            let awaitRelease remaining = do
                    ready <- doesPathExist (directory </> "exit-leader")
                    if ready || remaining <= (0 :: Int)
                        then pure ()
                        else threadDelay 10000 >> awaitRelease (remaining - 10000)
            awaitRelease (60 * 1000000)
        _ -> ioError (userError ("unknown private child-group probe: " <> mode))
#else
runChildGroupProbe _ _ = ioError (userError nativeObservationUnavailable)
#endif

#if defined(mingw32_HOST_OS)
type NativeTreeObservation = (HANDLE, HANDLE)

acquireNativeTreeObservation :: (Word32, Word32) -> IO (Either String NativeTreeObservation)
acquireNativeTreeObservation (leaderPid, grandchildPid) = do
    let acquire identity = failIfNull "OpenProcess native tree observation" $
            rawTreeOpenProcess (treeSynchronizeAccess .|. treeTerminateAccess) False identity
    leader <- acquire leaderPid
    grandchild <- acquire grandchildPid `onException` closeNativeTreeHandle leader
    pure (Right (leader, grandchild))

closeNativeTreeHandle :: HANDLE -> IO ()
closeNativeTreeHandle handle = failIfFalse_ "CloseHandle native tree observation" (rawTreeCloseHandle handle)

waitNativeTreeHandle :: HANDLE -> DWORD -> IO DWORD
waitNativeTreeHandle handle milliseconds = do
    result <- rawTreeWait handle milliseconds
    when (result == treeWaitFailed) (throwGetLastError "WaitForSingleObject native tree observation")
    pure result

assertNativeTreeAlive :: NativeTreeObservation -> IO ()
assertNativeTreeAlive (leader, grandchild) = forM_ [leader, grandchild] $ \handle ->
    waitNativeTreeHandle handle 0 >>= (@?= treeWaitTimeout)

assertNativeTreeGone :: NativeTreeObservation -> IO ()
assertNativeTreeGone (leader, grandchild) = forM_ [leader, grandchild] $ \handle ->
    waitNativeTreeHandle handle 10000 >>= (@?= treeWaitObject0)

assertNativeLeaderExited :: NativeTreeObservation -> IO ()
assertNativeLeaderExited (leader, _) = waitNativeTreeHandle leader 10000 >>= (@?= treeWaitObject0)

assertNativeGrandchildAlive :: NativeTreeObservation -> IO ()
assertNativeGrandchildAlive (_, grandchild) = waitNativeTreeHandle grandchild 0 >>= (@?= treeWaitTimeout)

releaseNativeTreeObservation :: NativeTreeObservation -> IO ()
releaseNativeTreeObservation (leader, grandchild) = mask $ \_ -> do
    outcomes <- forM [grandchild, leader] $ \handle -> try $
        (do
            status <- waitNativeTreeHandle handle 0
            when (status /= treeWaitObject0) $ do
                stopped <- rawTreeTerminate handle 123
                unless stopped $ do
                    ended <- waitNativeTreeHandle handle 0
                    unless (ended == treeWaitObject0) (throwGetLastError "TerminateProcess native tree cleanup")
            waitNativeTreeHandle handle 10000 >>= (@?= treeWaitObject0))
        `finally` closeNativeTreeHandle handle
    forM_ (outcomes :: [Either SomeException ()]) (either throwIO pure)

foreign import capi unsafe "windows.h OpenProcess"
    rawTreeOpenProcess :: DWORD -> BOOL -> DWORD -> IO HANDLE
foreign import capi unsafe "windows.h GetCurrentProcessId"
    rawTreeCurrentProcessId :: IO DWORD
foreign import capi safe "windows.h WaitForSingleObject"
    rawTreeWait :: HANDLE -> DWORD -> IO DWORD
foreign import capi unsafe "windows.h TerminateProcess"
    rawTreeTerminate :: HANDLE -> DWORD -> IO BOOL
foreign import capi unsafe "windows.h CloseHandle"
    rawTreeCloseHandle :: HANDLE -> IO BOOL
foreign import capi unsafe "windows.h value SYNCHRONIZE"
    treeSynchronizeAccess :: DWORD
foreign import capi unsafe "windows.h value PROCESS_TERMINATE"
    treeTerminateAccess :: DWORD
foreign import capi unsafe "windows.h value WAIT_OBJECT_0"
    treeWaitObject0 :: DWORD
foreign import capi unsafe "windows.h value WAIT_TIMEOUT"
    treeWaitTimeout :: DWORD
foreign import capi unsafe "windows.h value WAIT_FAILED"
    treeWaitFailed :: DWORD
#else
type NativeTreeObservation = ()

acquireNativeTreeObservation :: (Word32, Word32) -> IO (Either String NativeTreeObservation)
acquireNativeTreeObservation _ = pure (Left nativeObservationUnavailable)

releaseNativeTreeObservation :: NativeTreeObservation -> IO ()
releaseNativeTreeObservation _ = pure ()

assertNativeTreeAlive, assertNativeTreeGone, assertNativeLeaderExited, assertNativeGrandchildAlive :: NativeTreeObservation -> IO ()
assertNativeTreeAlive _ = ioError (userError nativeObservationUnavailable)
assertNativeTreeGone _ = ioError (userError nativeObservationUnavailable)
assertNativeLeaderExited _ = ioError (userError nativeObservationUnavailable)
assertNativeGrandchildAlive _ = ioError (userError nativeObservationUnavailable)
#endif

-- Fixtures

relayRequest :: Word64
relayRequest = 101

relayFinished :: Text.Text
relayFinished = "the duplex fixture observed its result"

outerRelayInput :: HandoffBindingInput
outerRelayInput = (bindingInputFor childPayload){requestedChildFrame = "relay-child"}

innerRelayInput :: HandoffBindingInput
innerRelayInput = (bindingInputFor childPayload){requestedParentFrame = "relay-child", requestedChildFrame = "relay-grandchild"}

relayChildDeclined :: Text.Text -> Relay.RelayError
relayChildDeclined reason =
    Relay.RelayRefusedByPeer "child-declined" (Text.pack (Receiver.receiverErrorMessage (Receiver.ReceiverDeclined reason)))

unusedRelayTerminal ::
    HandoffOffer scope generation -> ByteString.ByteString ->
    (ByteString.ByteString -> ByteString.ByteString -> IO (Either Text.Text ())) ->
    IO (Either Text.Text ())
unusedRelayTerminal _ _ _ = assertFailure "the refusal-only duplex fixture reached a terminal effect"

-- This composes the existing genuine root factories. No test creates or
-- changes the representation of a broker, link, root, scope, or received edge.
withDuplexHandoffRoot ::
    ( forall projectId generation.
      InstalledProjectIdentity projectId -> ProtectedStore ->
      RootBroker (Production projectId) generation VerbUp ->
      Relay.BrokerLink (Production projectId) generation ->
      IORef Int -> IO ()
    ) -> IO ()
withDuplexHandoffRoot use =
    withDuplexHandoffRootService
        (\_ _ -> pure (Left (Relay.RelayEdgeNotPlanned "the duplex fixture admits no rooted lifecycle request")))
        use

-- The optional endpoint is a DATA service observer returning a declared
-- refusal. It proves parser entry without producing a lifecycle response or
-- performing any durable action.
withDuplexHandoffRootService ::
    ([Text.Text] -> ByteString.ByteString -> IO (Either Relay.RelayError (Either (ByteString.ByteString, ByteString.ByteString) ByteString.ByteString))) ->
    ( forall projectId generation.
      InstalledProjectIdentity projectId -> ProtectedStore ->
      RootBroker (Production projectId) generation VerbUp ->
      Relay.BrokerLink (Production projectId) generation ->
      IORef Int -> IO ()
    ) -> IO ()
withDuplexHandoffRootService service use =
    withSystemTempDirectory "hostbootstrap-duplex-handoff" $ \directory -> do
        signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 102))
        activationSigning <- expectRight (Activation.activationSigningKeyFromBytes (ByteString.replicate 32 103))
        let secretDigest = Activation.activationSecretDigestFromBytes "duplex fixture secret"
        manifest <-
            expectRight $
                Activation.activationManifest
                    ( Activation.ActivationManifestInput
                        { Activation.manifestInputScope = "Production"
                        , Activation.manifestInputPlanDigest = "duplex-plan"
                        , Activation.manifestInputSpecDigest = "duplex-spec"
                        , Activation.manifestInputBinaryDigest = "duplex-binary"
                        , Activation.manifestInputFrame = "relay-child"
                        , Activation.manifestInputRevision = "duplex-revision"
                        , Activation.manifestInputConfigDigest = "duplex-config"
                        , Activation.manifestInputSecretDigest = secretDigest
                        , Activation.manifestInputService = "duplex-service"
                        , Activation.manifestInputRolePlanDigest = "duplex-role"
                        , Activation.manifestInputPermittedEffects = ["duplex-effect"]
                        , Activation.manifestInputSecretChannel = "duplex-secret-channel"
                        }
                    )
        policy <- expectRight (Activation.activationSigningPolicy [manifest])
        store <- openProtectedStore (directory </> "authority") >>= expectRight
        admissions <- newIORef (0 :: Int)
        let admits input = do
                modifyIORef' admissions (+ 1)
                pure $ if input `elem` [outerRelayInput, innerRelayInput]
                    then Right () else Left "the duplex fixture admits only its two exact edges"
        outcome <- Fixture.withFixtureInstalledProject $ \project ->
            withProductionRoot store project ProjectUp $ \root -> do
                brokered <- withRootBroker (productionHandoffScope project) store signing (productionRootAuthority root) $ \broker ->
                    Activation.withActivationBroker activationSigning (productionRootAuthority root) policy $ \activation -> do
                        link <- Relay.rootBrokerLink broker (productionHandoffScope project) activation admits
                            (\_ -> pure (Left "the duplex fixture admits no recovery projection"))
                            service >>= expectRight
                        use project store broker link admissions
                _ <- expectRight brokered
                pure (Right ())
        _ <- expectRight outcome
        pure ()

receiveConfigRelay ::
    InstalledProjectIdentity projectId -> Protocol.HandoffChannel -> ProjectVerificationKey ->
    (forall generation. Relay.BrokerLink (Production projectId) generation -> IO (Either Text.Text ())) ->
    IO (Either Receiver.ReceiverError ())
receiveConfigRelay project channel key use =
    Receiver.withReceivedHandoffEdge project channel key
        (\edge _ _ -> Relay.withConfigBrokerLink edge (\_ link -> use link))
        (\_ _ -> assertFailure "a config duplex fixture entered the recovery branch")
        (\_ _ _ -> assertFailure "a Production duplex fixture entered the Harness branch")
        (\_ _ -> assertFailure "a Production duplex fixture entered the Harness recovery branch")

withHandoffChannels ::
    (Protocol.HandoffChannel -> Protocol.HandoffChannel -> IO () -> IO () -> IO result) -> IO result
withHandoffChannels use =
    withScriptedHandoffChannels (\first second _ closeFirst closeSecond -> use first second closeFirst closeSecond)

withScriptedHandoffChannels ::
    (Protocol.HandoffChannel -> Protocol.HandoffChannel -> Handle -> IO () -> IO () -> IO result) -> IO result
withScriptedHandoffChannels use =
    bracket createPipe closePair $ \(firstInbound, secondOutbound) ->
        bracket createPipe closePair $ \(secondInbound, firstOutbound) -> do
            first <- Protocol.handoffChannel firstInbound firstOutbound
            second <- Protocol.handoffChannel secondInbound secondOutbound
            use first second firstOutbound (closeHandoffHandle firstOutbound) (closeHandoffHandle secondOutbound)
  where
    closePair (inbound, outbound) = closeHandoffHandle inbound `finally` closeHandoffHandle outbound

closeHandoffHandle :: Handle -> IO ()
closeHandoffHandle handle = do
    closed <- hIsClosed handle
    when (not closed) (hClose handle)

boundedHandoff :: String -> IO result -> IO result
boundedHandoff label action =
    timeout (60 * 1000000) action >>= maybe (assertFailure (label <> " exceeded sixty seconds")) pure

withHandoffWorker :: IO value -> (IO value -> IO result) -> IO result
withHandoffWorker action use = mask $ \restore -> do
    completed <- newEmptyMVar
    let await = boundedHandoff "a duplex worker result" (readMVar completed) >>= either throwIO pure
        stop worker = do
            killThread worker
            _ <- boundedHandoff "a duplex worker cleanup" (readMVar completed)
            pure ()
    bracket (forkFinally (restore action) (putMVar completed)) stop (\_ -> restore (use await))

relayMessage :: Protocol.ProtocolTag -> [ByteString.ByteString] -> IO Protocol.ProtocolMessage
relayMessage tag fields = expectRight (Protocol.protocolMessage tag relayRequest fields)

forwardHandoffMessages ::
    Protocol.HandoffChannel -> Protocol.HandoffChannel ->
    (Protocol.ProtocolMessage -> IO (Maybe Protocol.ProtocolMessage)) ->
    IO (Either Protocol.ProtocolError ())
forwardHandoffMessages source target transform = go
  where
    go = do
        received <- Protocol.channelReceive source
        case received of
            Left failure -> pure (Left failure)
            Right message -> do
                selected <- transform message
                case selected of
                    Nothing -> pure (Right ())
                    Just forwarded -> do
                        sent <- Protocol.channelSend target forwarded
                        case sent of
                            Left failure -> pure (Left failure)
                            Right () | Protocol.protocolMessageTag forwarded == Protocol.RefusedTag -> pure (Right ())
                            Right () -> go

requireObserved :: String -> Maybe value -> IO value
requireObserved label = maybe (assertFailure ("the fixture did not observe " <> label)) pure

receiverFinished :: Text.Text
receiverFinished = "the scripted receiver callback declined"

receiverCrashMarker :: String
receiverCrashMarker = "the scripted receiver IOException"

withReceiverScriptOffer ::
    ( forall projectId generation.
      InstalledProjectIdentity projectId ->
      RootBroker (Production projectId) generation VerbUp ->
      HandoffOffer (Production projectId) generation ->
      Protocol.ProtocolMessage -> ByteString.ByteString -> IO ()
    ) -> IO ()
withReceiverScriptOffer use =
    withNamedHandoff 108 ProjectUp $ \project broker -> do
        (binding, offer) <- newOfferWith broker outerRelayInput childPayload
        capsule <- signAuthenticatedRootScopeKernel HandoffInternal.recoverySigningKernel broker (productionHandoffScope project) >>= expectRight
        rooted <- signRootedPayloadBindingKernel HandoffInternal.recoverySigningKernel broker offer childPayload >>= expectRight
        let keyDigest = TextEncoding.encodeUtf8 (verificationKeyDigest (rootBrokerVerificationKey broker))
            authentication = frameWire (renderAuthenticatedRootScope capsule) <> frameWire keyDigest <> frameWire (renderRootedPayloadBinding rooted)
            (payload, token, bindingBytes) = handoffOfferFrames offer
        offered <- relayMessage Protocol.OfferTag [payload, token, bindingBytes, authentication]
        -- This is existing canonical report DATA for protocol sequencing, not
        -- an assertion that a lifecycle session or backend effect committed.
        report <- expectRight (renderForwardCompletedLifecycleReport (forwardLifecycleOrigin (renderHandoffBinding binding)))
        use project broker offer offered report

runScriptedReceiver ::
    InstalledProjectIdentity projectId -> Protocol.HandoffChannel -> ProjectVerificationKey ->
    ( forall generation.
      Receiver.ReceivedEdge (Production projectId) generation ->
      (ByteString.ByteString -> IO (Either Receiver.ReceiverError ())) -> IO (Either Text.Text ())
    ) -> IO (Either Receiver.ReceiverError ())
runScriptedReceiver project channel key use =
    Receiver.withReceivedHandoffEdge project channel key
        (\edge _ sendReport -> use edge sendReport)
        (\_ _ -> assertFailure "the scripted config receiver entered recovery")
        (\_ _ _ -> assertFailure "the scripted Production receiver entered Harness")
        (\_ _ -> assertFailure "the scripted Production receiver entered Harness recovery")

changeScriptedAuthentication ::
    Protocol.ProtocolMessage ->
    (ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString -> IO ByteString.ByteString) ->
    IO Protocol.ProtocolMessage
changeScriptedAuthentication offered change = case Protocol.protocolMessageFields offered of
    [payload, token, binding, authentication] -> do
        (capsule, afterCapsule) <- expectRight (takeHandoffFrame authentication)
        (keyDigest, evidence) <- expectRight (takeHandoffFrame afterCapsule)
        altered <- change capsule keyDigest evidence
        assertBool "the scripted authentication mutation changes its input" (altered /= authentication)
        relayMessage Protocol.OfferTag [payload, token, binding, altered]
    fields -> assertFailure ("the genuine offer had " <> show (length fields) <> " fields")

checkEarlyReceiverRefusal ::
    InstalledProjectIdentity projectId -> ProjectVerificationKey -> Protocol.ProtocolMessage ->
    Receiver.ReceiverError -> ByteString.ByteString -> IO ()
checkEarlyReceiverRefusal project key offered expected code =
    withScriptedHandoffChannels $ \parent child _ _ closeChild -> do
        calls <- newIORef (0 :: Int)
        let receiver = runScriptedReceiver project child key $ \_ _ -> modifyIORef' calls (+ 1) >> pure (Left receiverFinished)
        withHandoffWorker receiver $ \awaitReceiver -> do
            Protocol.channelSend parent offered >>= (@?= Right ())
            assertScriptedRefusal parent expected code
            awaitReceiver >>= (@?= Left expected)
            assertReceiverSilence parent closeChild
        readIORef calls >>= (@?= 0)

scriptedGrant ::
    RootBroker scope generation verb -> HandoffOffer scope generation ->
    Protocol.HandoffChannel -> IO Protocol.ProtocolMessage
scriptedGrant broker offer parent = do
    challengeMessage <- boundedHandoff "the genuine receiver challenge" (Protocol.channelReceive parent) >>= expectRight
    Protocol.protocolMessageTag challengeMessage @?= Protocol.ChallengeTag
    Protocol.protocolMessageRequestId challengeMessage @?= relayRequest
    challenge <- case Protocol.protocolMessageFields challengeMessage of
        [raw] -> expectRight (handoffChallengeFromBytes raw)
        fields -> assertFailure ("the real challenge had " <> show (length fields) <> " fields")
    grant <- grantHandoff broker offer challenge >>= expectRight
    relayMessage Protocol.GrantTag [grantSignature grant, TextEncoding.encodeUtf8 (verificationKeyDigest (rootBrokerVerificationKey broker))]

admitScriptedReceiver ::
    RootBroker scope generation verb -> HandoffOffer scope generation ->
    Protocol.ProtocolMessage -> Protocol.HandoffChannel -> IO ()
admitScriptedReceiver broker offer offered parent = do
    Protocol.channelSend parent offered >>= (@?= Right ())
    granted <- scriptedGrant broker offer parent
    Protocol.channelSend parent granted >>= (@?= Right ())
    requireScriptedMessage parent Protocol.AcceptedTag [TextEncoding.encodeUtf8 (handoffChildConfigDigest (handoffOfferBinding offer))]

requireScriptedMessage :: Protocol.HandoffChannel -> Protocol.ProtocolTag -> [ByteString.ByteString] -> IO ()
requireScriptedMessage parent tag fields = do
    observed <- boundedHandoff ("the scripted peer's " <> show tag) (Protocol.channelReceive parent) >>= expectRight
    Protocol.protocolMessageTag observed @?= tag
    Protocol.protocolMessageRequestId observed @?= relayRequest
    Protocol.protocolMessageFields observed @?= fields

acknowledgeScriptedReport :: Protocol.HandoffChannel -> ByteString.ByteString -> IO ()
acknowledgeScriptedReport parent report = do
    requireScriptedMessage parent Protocol.CompletedTag [report]
    acknowledgement <- expectRight (renderLifecycleAcknowledgement report)
    message <- relayMessage Protocol.AcknowledgedTag [acknowledgement]
    Protocol.channelSend parent message >>= (@?= Right ())

assertScriptedRefusal :: Protocol.HandoffChannel -> Receiver.ReceiverError -> ByteString.ByteString -> IO ()
assertScriptedRefusal parent expected code =
    requireScriptedMessage parent Protocol.RefusedTag [code, TextEncoding.encodeUtf8 (Text.pack (Receiver.receiverErrorMessage expected))]

sendScriptedRefusal :: Protocol.HandoffChannel -> IO ()
sendScriptedRefusal parent = do
    message <- relayMessage Protocol.RefusedTag ["scripted-refusal", "the scripted parent refused"]
    Protocol.channelSend parent message >>= (@?= Right ())

assertReceiverSilence :: Protocol.HandoffChannel -> IO () -> IO ()
assertReceiverSilence parent closeChild = do
    closeChild
    boundedHandoff "EOF after the returned receiver closes its output" (Protocol.channelReceive parent)
        >>= (@?= Left (Protocol.ProtocolTruncated 8 0))

assertScriptedIOException :: (Show value) => Either IOException value -> IO ()
assertScriptedIOException result = case result of
    Left failure -> ioeGetErrorString failure @?= receiverCrashMarker
    Right value -> assertFailure ("expected the original scripted IOException, got " <> show value)

writeScriptedArity :: Handle -> Protocol.ProtocolMessage -> Int -> IO ()
writeScriptedArity output message fieldCount = do
    let encoded = Protocol.encodeProtocolMessage message
        body = ByteString.drop 8 encoded
        fields = Protocol.protocolMessageFields message
        -- Mutate only the field framing of the real encoded message. The
        -- existing v1 header remains its actual 15 bytes; no malformed opaque
        -- ProtocolMessage or alternate protocol implementation is constructed.
        changedBody = if fieldCount < length fields
            then ByteString.take 15 body <> renderFrameFields (take fieldCount fields)
            else body <> frameWire ""
    assertBool "the arity mutation changes only a genuine message's body" (changedBody /= body)
    ByteString.hPut output (frameWire changedBody)
    hFlush output

readProtectedRecordsImage :: ProtectedStore -> IO [(Text.Text, Word64, ByteString.ByteString)]
readProtectedRecordsImage store = do
    entered <-
        withProtectedEntry store $ \session -> do
            keys <- listProtectedRecords session >>= either (assertFailure . show) pure
            rows <-
                mapM
                    ( \key -> do
                        observed <- readProtectedRecord session key >>= either (assertFailure . show) pure
                        record <- maybe (assertFailure "a listed record disappeared") pure observed
                        pure (recordKeyText key, recordVersionWord (protectedRecordVersion record), protectedRecordBytes record)
                    )
                    keys
            pure (Right rows)
    either (assertFailure . show) pure entered


childPayload :: ByteString.ByteString
childPayload = ByteStringChar8.pack "{ message = \"Hello, world!\" }"

secretPayload :: ByteString.ByteString
secretPayload = "SECRET-CONFIG-BYTES-DO-NOT-PRINT"

recoveryPayload :: ByteString.ByteString
recoveryPayload = "provider=incus;instance=demo-vm;policy=destroy"

data RecoveryCoordinates = RecoveryCoordinates
    { recoveryPlanCoordinate :: Text.Text
    , recoveryParentCoordinate :: Text.Text
    , recoveryChildCoordinate :: Text.Text
    }

baseRecoveryCoordinates :: RecoveryCoordinates
baseRecoveryCoordinates =
    RecoveryCoordinates
        { recoveryPlanCoordinate = "plan-digest-1"
        , recoveryParentCoordinate = "vm-orchestrator-1"
        , recoveryChildCoordinate = "vm-project-container-2"
        }

withRecoveryInput ::
    RecoveryCoordinates ->
    ( forall planDigest parentFrame childFrame.
      RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
      IO result
    ) ->
    IO result
withRecoveryInput coordinates use =
    expectRight
        ( withRecoveryProjectionBindingInput
            (recoveryPlanCoordinate coordinates)
            (recoveryParentCoordinate coordinates)
            (recoveryChildCoordinate coordinates)
            use
        )
        >>= id

bindingInputFor :: ByteString.ByteString -> HandoffBindingInput
bindingInputFor payload =
    HandoffBindingInput
        { requestedSpecDigest = "spec-digest-1"
        , requestedPayloadKind = NarrowedProjectConfig
        , requestedPlanRevision = "rev-1"
        , requestedParentFrame = "vm-orchestrator-1"
        , requestedChildFrame = "vm-project-container-2"
        , requestedChildConfigDigest = childConfigDigest payload
        , requestedPhase = "execute"
        }

recoveryBindingInput ::
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    ByteString.ByteString ->
    HandoffBindingInput
recoveryBindingInput recoveryInput payload =
    HandoffBindingInput
        { requestedSpecDigest = "spec-digest-1"
        , requestedPayloadKind = RecoveryAdapterWire
        , requestedPlanRevision = requestedRecoveryPlanDigest recoveryInput
        , requestedParentFrame = requestedRecoveryParentFrame recoveryInput
        , requestedChildFrame = requestedRecoveryChildFrame recoveryInput
        , requestedChildConfigDigest = recoveryWireDigest payload
        , requestedPhase = "teardown"
        }

newOffer ::
    RootBroker scope brokerGeneration verb ->
    ByteString.ByteString ->
    IO
        ( HandoffBinding scope brokerGeneration
        , HandoffOffer scope brokerGeneration
        )
newOffer broker payload = do
    newOfferWith broker (bindingInputFor payload) payload

newOfferWith ::
    RootBroker scope brokerGeneration verb ->
    HandoffBindingInput ->
    ByteString.ByteString ->
    IO
        ( HandoffBinding scope brokerGeneration
        , HandoffOffer scope brokerGeneration
        )
newOfferWith broker input payload = do
    (relay, token) <- expectRightIO =<< registerHandoffEdge broker input
    offer <- expectRight (mkHandoffOffer relay payload token)
    pure (relayBinding relay, offer)

withRecoveryBinding ::
    RootBroker scope brokerGeneration verb ->
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    ByteString.ByteString ->
    ( forall recoveryWireDigest.
      RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
      IO result
    ) ->
    IO result
withRecoveryBinding broker input wire use =
    case mkRecoveryProjectionBinding broker input wire use of
        Left failure -> assertFailure (show failure)
        Right action -> action

recoveryOracleGrant ::
    Word8 ->
    ProjectVerificationKey ->
    RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    ByteString.ByteString ->
    IO
        ( RecoveryWireGrant
            scope
            brokerGeneration
            verb
            planDigest
            parentFrame
            childFrame
            recoveryWireDigest
        )
recoveryOracleGrant seedByte =
    recoveryOracleGrantWithDomain seedByte canonicalRecoveryDomain

recoveryOracleGrantWithDomain ::
    Word8 ->
    ByteString.ByteString ->
    ProjectVerificationKey ->
    RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    ByteString.ByteString ->
    IO
        ( RecoveryWireGrant
            scope
            brokerGeneration
            verb
            planDigest
            parentFrame
            childFrame
            recoveryWireDigest
        )
recoveryOracleGrantWithDomain seedByte domain verificationKey binding wire =
    case Ed25519.secretKey (ByteString.replicate 32 seedByte) of
        CryptoFailed failure ->
            assertFailure ("fixed recovery oracle seed failed: " <> show failure)
        CryptoPassed secret ->
            expectRight
                ( recoveryWireGrantFromSignature
                    binding
                    ( convert
                        ( Ed25519.sign
                            secret
                            (Ed25519.toPublic secret)
                            ( recoveryOracleMaterial
                                domain
                                verificationKey
                                binding
                                wire
                            )
                        )
                    )
                )

canonicalRootedPayloadSigningDomain :: ByteString.ByteString
canonicalRootedPayloadSigningDomain = "hostbootstrap/rooted-payload-binding/v1"

canonicalRootedLifecycleRequestDomain :: ByteString.ByteString
canonicalRootedLifecycleRequestDomain = "hostbootstrap/rooted-lifecycle-request"

canonicalRootedLifecycleResponseDomain :: ByteString.ByteString
canonicalRootedLifecycleResponseDomain = "hostbootstrap/rooted-lifecycle-response"

canonicalRootedLifecycleResponseSigningDomain :: ByteString.ByteString
canonicalRootedLifecycleResponseSigningDomain =
    "hostbootstrap/rooted-lifecycle-response/v1"

rootedLifecyclePathWire :: [Text.Text] -> ByteString.ByteString
rootedLifecyclePathWire =
    renderFrameFields . map TextEncoding.encodeUtf8

rootedLifecycleOpenRequest :: ByteString.ByteString -> ByteString.ByteString
rootedLifecycleOpenRequest nonce =
    renderFrameFields
        [ canonicalRootedLifecycleRequestDomain
        , lifecycleWordBytesFor 1
        , "open-frame"
        , nonce
        ]

rootedLifecyclePostRequest ::
    ByteString.ByteString ->
    [Text.Text] ->
    Text.Text ->
    Text.Text ->
    Word8 ->
    ByteString.ByteString ->
    Text.Text ->
    Maybe ByteString.ByteString ->
    ByteString.ByteString
rootedLifecyclePostRequest variant path session stage ordinal nonce predecessor body =
    renderFrameFields
        ( [ canonicalRootedLifecycleRequestDomain
          , lifecycleWordBytesFor 1
          , variant
          , rootedLifecyclePathWire path
          , TextEncoding.encodeUtf8 session
          , TextEncoding.encodeUtf8 stage
          , lifecycleWordBytesFor ordinal
          , nonce
          , TextEncoding.encodeUtf8 predecessor
          ]
            <> maybe [] pure body
        )

rootedLifecycleOpenedUnsigned ::
    ByteString.ByteString ->
    [Text.Text] ->
    Text.Text ->
    Text.Text ->
    Word8 ->
    ByteString.ByteString
rootedLifecycleOpenedUnsigned request path session stage ordinal =
    renderFrameFields
        [ canonicalRootedLifecycleResponseDomain
        , lifecycleWordBytesFor 1
        , "opened"
        , TextEncoding.encodeUtf8 (childConfigDigest request)
        , rootedLifecyclePathWire path
        , TextEncoding.encodeUtf8 session
        , TextEncoding.encodeUtf8 stage
        , lifecycleWordBytesFor ordinal
        ]

rootedLifecyclePostUnsigned ::
    ByteString.ByteString ->
    ByteString.ByteString ->
    [Text.Text] ->
    Text.Text ->
    Text.Text ->
    Word8 ->
    ByteString.ByteString ->
    ByteString.ByteString ->
    ByteString.ByteString
rootedLifecyclePostUnsigned variant request path session stage ordinal nonce body =
    renderFrameFields
        [ canonicalRootedLifecycleResponseDomain
        , lifecycleWordBytesFor 1
        , variant
        , TextEncoding.encodeUtf8 (childConfigDigest request)
        , rootedLifecyclePathWire path
        , TextEncoding.encodeUtf8 session
        , TextEncoding.encodeUtf8 stage
        , lifecycleWordBytesFor ordinal
        , nonce
        , body
        ]

rootedLifecycleResponseOracleWire ::
    Word8 ->
    ByteString.ByteString ->
    ProjectVerificationKey ->
    ByteString.ByteString ->
    ByteString.ByteString ->
    IO ByteString.ByteString
rootedLifecycleResponseOracleWire seedByte signingDomain verificationKey request unsigned =
    case Ed25519.secretKey (ByteString.replicate 32 seedByte) of
        CryptoFailed failure ->
            assertFailure ("fixed rooted-lifecycle-response oracle seed failed: " <> show failure)
        CryptoPassed secret -> do
            let material =
                    frameWire signingDomain
                        <> frameWire (TextEncoding.encodeUtf8 (verificationKeyDigest verificationKey))
                        <> frameWire request
                        <> frameWire unsigned
                signature :: ByteString.ByteString
                signature =
                    convert
                        (Ed25519.sign secret (Ed25519.toPublic secret) material)
            pure (unsigned <> frameWire signature)

rootedPayloadUnsigned ::
    ByteString.ByteString ->
    Text.Text ->
    Text.Text ->
    ByteString.ByteString
rootedPayloadUnsigned edge payloadDigest configDigest =
    renderFrameFields
        [ "hostbootstrap/rooted-payload-binding"
        , lifecycleWordBytesFor 1
        , edge
        , TextEncoding.encodeUtf8 payloadDigest
        , TextEncoding.encodeUtf8 configDigest
        ]

rootedOracleWire ::
    Word8 ->
    ByteString.ByteString ->
    ProjectVerificationKey ->
    ByteString.ByteString ->
    Text.Text ->
    Text.Text ->
    IO ByteString.ByteString
rootedOracleWire seedByte signingDomain verificationKey edge payloadDigest configDigest =
    case Ed25519.secretKey (ByteString.replicate 32 seedByte) of
        CryptoFailed failure ->
            assertFailure ("fixed rooted-payload oracle seed failed: " <> show failure)
        CryptoPassed secret -> do
            let unsigned = rootedPayloadUnsigned edge payloadDigest configDigest
                material =
                    frameWire signingDomain
                        <> frameWire (TextEncoding.encodeUtf8 (verificationKeyDigest verificationKey))
                        <> frameWire unsigned
                signature :: ByteString.ByteString
                signature =
                    convert
                        (Ed25519.sign secret (Ed25519.toPublic secret) material)
            pure (unsigned <> frameWire signature)

canonicalAuthenticatedRootScopeDomain :: ByteString.ByteString
canonicalAuthenticatedRootScopeDomain = "hostbootstrap/authenticated-root-scope"

canonicalAuthenticatedRootScopeSigningDomain :: ByteString.ByteString
canonicalAuthenticatedRootScopeSigningDomain = "hostbootstrap/authenticated-root-scope/v1"

authenticatedRootScopeUnsigned ::
    ProjectVerificationKey ->
    Text.Text ->
    ByteString.ByteString ->
    ByteString.ByteString ->
    ByteString.ByteString
authenticatedRootScopeUnsigned verificationKey projectName scopeKind runName =
    renderFrameFields
        [ canonicalAuthenticatedRootScopeDomain
        , lifecycleWordBytesFor 1
        , TextEncoding.encodeUtf8 projectName
        , scopeKind
        , runName
        , TextEncoding.encodeUtf8 (verificationKeyDigest verificationKey)
        ]

authenticatedRootScopeOracleWire ::
    Word8 ->
    ByteString.ByteString ->
    ProjectVerificationKey ->
    Text.Text ->
    ByteString.ByteString ->
    ByteString.ByteString ->
    IO ByteString.ByteString
authenticatedRootScopeOracleWire seedByte signingDomain verificationKey projectName scopeKind runName =
    authenticatedRootScopeOracleWireFromUnsigned
        seedByte
        signingDomain
        verificationKey
        (authenticatedRootScopeUnsigned verificationKey projectName scopeKind runName)

authenticatedRootScopeOracleWireFromUnsigned ::
    Word8 ->
    ByteString.ByteString ->
    ProjectVerificationKey ->
    ByteString.ByteString ->
    IO ByteString.ByteString
authenticatedRootScopeOracleWireFromUnsigned seedByte signingDomain verificationKey unsigned =
    case Ed25519.secretKey (ByteString.replicate 32 seedByte) of
        CryptoFailed failure ->
            assertFailure ("fixed authenticated-root-scope oracle seed failed: " <> show failure)
        CryptoPassed secret -> do
            let material =
                    frameWire signingDomain
                        <> frameWire (TextEncoding.encodeUtf8 (verificationKeyDigest verificationKey))
                        <> frameWire unsigned
                signature :: ByteString.ByteString
                signature =
                    convert
                        (Ed25519.sign secret (Ed25519.toPublic secret) material)
            pure (unsigned <> frameWire signature)

recoveryOracleMaterial ::
    ByteString.ByteString ->
    ProjectVerificationKey ->
    RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    ByteString.ByteString ->
    ByteString.ByteString
recoveryOracleMaterial domain verificationKey binding wire =
    ByteString.concat
        [ frameWire domain
        , frameWire (TextEncoding.encodeUtf8 (verificationKeyDigest verificationKey))
        , frameWire (renderRecoveryProjectionBinding binding)
        , frameWire wire
        ]

canonicalRecoveryDomain :: ByteString.ByteString
canonicalRecoveryDomain = "hostbootstrap/recovery-wire/v1"

captureRecoverySignature ::
    Word8 ->
    ProjectSigningKey ->
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ProjectVerb verb ->
    IO ByteString.ByteString
captureRecoverySignature seedByte signing store project verb =
    withRecoveryBroker signing store project verb $ \broker ->
        withRecoveryInput baseRecoveryCoordinates $ \input ->
            withRecoveryBinding broker input recoveryPayload $ \binding ->
                recoveryWireGrantSignature
                    <$> recoveryOracleGrant
                        seedByte
                        (rootBrokerVerificationKey broker)
                        binding
                        recoveryPayload

withRecoveryBroker ::
    ProjectSigningKey ->
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ProjectVerb verb ->
    ( forall brokerGeneration.
      RootBroker (Production projectId) brokerGeneration verb ->
      IO result
    ) ->
    IO result
withRecoveryBroker signing store project verb use = do
    outcome <- withProductionRoot store project verb $ \root -> do
        brokered <-
            withRootBroker
                (productionHandoffScope project)
                store
                signing
                (productionRootAuthority root)
                use
        result <- either (assertFailure . show) pure brokered
        pure (Right result)
    either (assertFailure . show) pure outcome

assertRecoveryReplayRefused ::
    RootBroker scope brokerGeneration verb ->
    ProjectVerb verb ->
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    ByteString.ByteString ->
    IO ()
assertRecoveryReplayRefused broker verb input foreignSignature =
    withRecoveryBinding broker input recoveryPayload $ \projection -> do
        replayedGrant <-
            expectRight
                (recoveryWireGrantFromSignature projection foreignSignature)
        (binding, offer) <-
            newOfferWith
                broker
                (recoveryBindingInput input recoveryPayload)
                recoveryPayload
        challenge <- freshChallenge
        configGrant <- expectRightIO =<< grantHandoff broker offer challenge
        handoff <-
            expectRight
                ( verifyHandoff
                    (rootBrokerVerificationKey broker)
                    (handoffOfferWire offer)
                    binding
                    challenge
                    configGrant
                )
        withVerifiedRecoveryHandoff
            verb
            projection
            replayedGrant
            handoff
            (const ())
            @?= Left HandoffRecoverySignatureInvalid

assertSubstitutedRecoveryRefuses ::
    RootBroker scope brokerGeneration verb ->
    ByteString.ByteString ->
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    IO ()
assertSubstitutedRecoveryRefuses broker originalSignature input =
    withRecoveryBinding broker input recoveryPayload $ \substituted -> do
        adopted <-
            expectRight
                ( recoveryWireGrantFromSignature
                    substituted
                    originalSignature
                )
        withVerifiedRecoveryWire
            (rootBrokerVerificationKey broker)
            substituted
            recoveryPayload
            adopted
            (const ())
            @?= Left HandoffRecoverySignatureInvalid

authenticatedPayload ::
    RootBroker scope brokerGeneration verb ->
    ByteString.ByteString ->
    IO (AuthenticatedConfigPayload scope brokerGeneration)
authenticatedPayload broker payload = do
    verified <- verifiedHandoffFor broker payload
    expectRight (verifiedConfigPayload verified)

verifiedHandoffFor ::
    RootBroker scope brokerGeneration verb ->
    ByteString.ByteString ->
    IO (VerifiedHandoff scope brokerGeneration)
verifiedHandoffFor broker payload = do
    (binding, offer) <- newOffer broker payload
    verifyOfferedHandoff broker binding offer

verifiedHandoffForInput ::
    RootBroker scope brokerGeneration verb ->
    HandoffBindingInput ->
    ByteString.ByteString ->
    IO (VerifiedHandoff scope brokerGeneration)
verifiedHandoffForInput broker input payload = do
    (binding, offer) <- newOfferWith broker input payload
    verifyOfferedHandoff broker binding offer

verifyOfferedHandoff ::
    RootBroker scope brokerGeneration verb ->
    HandoffBinding scope brokerGeneration ->
    HandoffOffer scope brokerGeneration ->
    IO (VerifiedHandoff scope brokerGeneration)
verifyOfferedHandoff broker binding offer = do
    challenge <- freshChallenge
    grant <- expectRightIO =<< grantHandoff broker offer challenge
    expectRight
        ( verifyHandoff
            (rootBrokerVerificationKey broker)
            (handoffOfferWire offer)
            binding
            challenge
            grant
        )

canonicalConfigBytes ::
    ProjectCodec scope specDigest Fixture.ProjectConfig ->
    Fixture.ProjectConfig scope ->
    ByteString.ByteString
canonicalConfigBytes codec =
    TextEncoding.encodeUtf8
        . (<> "\n")
        . renderProjectCodecHoisted codec Context.vocabUnions

rejectAuthenticatedConfigImport :: Word8 -> (ByteString.ByteString -> ByteString.ByteString) -> IO ()
rejectAuthenticatedConfigImport seedByte renderImport =
    withHandoff seedByte ProjectUp $ \broker ->
        withProductionProjectCodec @Fixture.ProjectConfig $ \codec -> do
            let cfg =
                    Fixture.defaultProjectConfig
                        "hostbootstrap-demo"
                        "/workspace/demo"
                        Context.HostOrchestrator
                canonical = canonicalConfigBytes codec cfg
                payload = renderImport canonical
                variable = "HOSTBOOTSTRAP_PROBE"
            canonicalText <- expectRight (TextEncoding.decodeUtf8' canonical)
            authenticated <- authenticatedPayload broker payload
            authenticatedConfigBytes authenticated @?= payload
            authenticatedConfigDigest authenticated @?= childConfigDigest payload
            callbacks <- newIORef (0 :: Int)
            bracket
                (do
                    previous <- lookupEnv variable
                    setEnv variable (Text.unpack canonicalText)
                    pure previous
                )
                (\previous -> case previous of
                    Nothing -> unsetEnv variable
                    Just value -> setEnv variable value
                )
                (\_ -> do
                    admitted <-
                        withAuthenticatedConfigWire codec authenticated $ \_ _ ->
                            modifyIORef' callbacks (+ 1)
                    admitted @?= Left ConfigWireCodecRejected
                    readIORef callbacks >>= (@?= 0)
                )

withHandoff ::
    Word8 ->
    ProjectVerb verb ->
    ( forall projectId (brokerGeneration :: Type).
      RootBroker (Production projectId) brokerGeneration verb ->
      IO ()
    ) ->
    IO ()
withHandoff seedByte verb use =
    withSystemTempDirectory "hostbootstrap-handoff" $ \directory -> do
        signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 seedByte))
        opened <- openProtectedStore (directory </> "authority")
        case opened of
            Left failure -> assertFailure (show failure)
            Right store -> withRootFor signing store verb use

withHandoffPair ::
    Word8 ->
    Word8 ->
    ProjectVerb verb ->
    ( forall projectId (brokerGeneration :: Type).
      RootBroker (Production projectId) brokerGeneration verb ->
      RootBroker (Production projectId) brokerGeneration verb ->
      IO ()
    ) ->
    IO ()
withHandoffPair firstSeed secondSeed verb use =
    withSystemTempDirectory "hostbootstrap-handoff-pair" $ \directory -> do
        firstSigning <-
            expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 firstSeed))
        secondSigning <-
            expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 secondSeed))
        store <- openProtectedStore (directory </> "authority") >>= expectRightIO
        outcome <- Fixture.withFixtureInstalledProject $ \project ->
            withProductionRoot store project verb $ \root -> do
                first <-
                    withRootBroker
                        (productionHandoffScope project)
                        store
                        firstSigning
                        (productionRootAuthority root)
                        ( \firstBroker ->
                            withRootBroker
                                (productionHandoffScope project)
                                store
                                secondSigning
                                (productionRootAuthority root)
                                (use firstBroker)
                        )
                case first of
                    Left failure -> assertFailure (show failure)
                    Right second -> do
                        _ <- either (assertFailure . show) pure second
                        pure (Right ())
        _ <- either (assertFailure . show) pure outcome
        pure ()

withNamedHandoff ::
    Word8 ->
    ProjectVerb verb ->
    ( forall projectId (brokerGeneration :: Type).
      InstalledProjectIdentity projectId ->
      RootBroker (Production projectId) brokerGeneration verb ->
      IO result
    ) ->
    IO result
withNamedHandoff seedByte verb use =
    withSystemTempDirectory "hostbootstrap-named-handoff" $ \directory -> do
        signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 seedByte))
        store <- openProtectedStore (directory </> "authority") >>= expectRightIO
        outcome <- Fixture.withFixtureInstalledProject $ \project ->
            withProductionRoot store project verb $ \root -> do
                brokered <-
                    withRootBroker
                        (productionHandoffScope project)
                        store
                        signing
                        (productionRootAuthority root)
                        (use project)
                result <- either (assertFailure . show) pure brokered
                pure (Right result)
        either (assertFailure . show) pure outcome

withRootFor ::
    ProjectSigningKey ->
    ProtectedStore ->
    ProjectVerb verb ->
    ( forall projectId (brokerGeneration :: Type).
      RootBroker (Production projectId) brokerGeneration verb ->
      IO ()
    ) ->
    IO ()
withRootFor signing store verb use = do
    outcome <- Fixture.withFixtureInstalledProject $ \project ->
        withProductionRoot store project verb $ \root -> do
            brokered <-
                withRootBroker
                    (productionHandoffScope project)
                    store
                    signing
                    (productionRootAuthority root)
                    use
            case brokered of
                Left failure -> assertFailure (show failure)
                Right () -> pure (Right ())
    case outcome of
        Left failure -> assertFailure (show failure)
        Right () -> pure ()

withHarnessHandoff ::
    Word8 ->
    ( forall projectId runId (brokerGeneration :: Type).
      InstalledProjectIdentity projectId ->
      RootBroker (Harness projectId runId) brokerGeneration VerbUp ->
      HarnessAuthority projectId runId ->
      IO result
    ) ->
    IO result
withHarnessHandoff seedByte use =
    withSystemTempDirectory "hostbootstrap-handoff-harness" $ \directory -> do
        signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 seedByte))
        opened <- openProtectedStore (directory </> "authority")
        store <- either (assertFailure . show) pure opened
        Fixture.withFixtureInstalledProject $ \project -> do
            swept <- recoverAbandonedHarnessRuns store project recoverNothing recoverNothing >>= either (assertFailure . show) pure
            outcome <-
                withHarnessRoot
                    store
                    project
                    ProjectUp
                    (harnessPreconditions project (directory </> "absent-config") (pure False))
                    swept
                    ( \root -> do
                        brokered <-
                            withRootBroker
                                (harnessHandoffScope project (harnessRootHarnessAuthority root))
                                store
                                signing
                                (harnessRootAuthority root)
                                (\broker -> use project broker (harnessRootHarnessAuthority root))
                        result <- either (assertFailure . show) pure brokered
                        pure (Right result)
                    )
            either (assertFailure . show) pure outcome

recoverNothing ::
    VerifiedIncompleteRunLease projectId ->
    IO (Either ModeError ())
recoverNothing _ = pure (Right ())

{- | Clear a fixture path whatever it currently names.

Existence checks can follow links, so inspect the link itself before checking
its target. A dangling fixture link still needs removal before the next case.
-}
removeIfPresent :: FilePath -> IO ()
removeIfPresent path = do
    inspected <- try @IOException (pathIsSymbolicLink path)
    linked <- case inspected of
        Right value -> pure value
        Left failure
            | isDoesNotExistError failure -> pure False
            | otherwise -> throwIO failure
    present <- doesPathExist path
    when (linked || present) (removePathForcibly path)

dropFirstFrame :: ByteString.ByteString -> ByteString.ByteString
dropFirstFrame = ByteString.drop (ByteString.length (frameWire childPayload))

withHandoffPackageRoot :: (FilePath -> IO result) -> IO result
withHandoffPackageRoot use =
    SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> use packageRoot

handoffModulePath :: FilePath -> String -> IO FilePath
handoffModulePath packageRoot name = do
    description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
    SourceGuard.libraryModulePath packageRoot description name

handoffImplementationSources :: FilePath -> IO [(FilePath, String)]
handoffImplementationSources packageRoot = do
    description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
    sources <- SourceGuard.mainImplementationSources packageRoot description
    pure [(path, source) | (_, path, source) <- sources]

sourcePath :: FilePath -> FilePath -> FilePath
sourcePath = SourceGuard.repoRelativePath

{- | Read a governed source once, as its own bytes and as the text of those bytes.

A frozen digest names what a file /is/, so it is a digest of that file's own
bytes (§ JJ). Decoded through the gate host's active code page and re-encoded, a
frozen digest becomes a property of the host instead of the file, and a source
shape assertion beside it reads a differently newline-translated text than the
digest covers. Both come from the one byte read here, so a freeze means the same
thing on every gate host.
-}
readFrozenSource :: FilePath -> IO (String, Text.Text)
readFrozenSource path = do
    bytes <- ByteString.readFile path
    pure (Text.unpack (TextEncoding.decodeUtf8 bytes), childConfigDigest bytes)

-- | The frozen digest of a governed source whose text no guard beside it reads.
frozenSourceDigest :: FilePath -> IO Text.Text
frozenSourceDigest = fmap snd . readFrozenSource

-- DEVELOPMENT_PLAN/rationale.md#handoff-freezes-cover-owned-declarations
-- These fixed subjects were measured from the saved pre-type Rooted source.
-- Names, typed signatures and every complete clause are ordered Aeson arrays.
frozenRootedPreservationDigests :: String -> IO [(String, Text.Text)]
frozenRootedPreservationDigests source = do
    shapes <- rootedPreservationShapes source
    requests <- rootedPreservationDeclarations rootedPreservationRequestNames source
    responses <- rootedPreservationDeclarations rootedPreservationResponseFramingNames source
    shared <- rootedPreservationDeclarations (rootedPreservationSharedNames <> rootedPreservationConstantNames) source
    let digest entries = childConfigDigest (LazyByteString.toStrict (Aeson.encode entries))
    pure
        [ ("closed shapes and payload roles", digest shapes)
        , ("request declarations", digest requests)
        , ("response framing and descriptions", digest responses)
        , ("shared framing and constants", digest shared)
        ]

type RootedPreservationDeclaration = (String, [String], [[String]])

rootedPreservationRequestNames :: [String]
rootedPreservationRequestNames =
    [ "rootedOpenFrameRequestKernel"
    , "rootedNextNodeRequestKernel"
    , "rootedSettleNodeRequestKernel"
    , "rootedDescendResultRequestKernel"
    , "rootedCloseFrameRequestKernel"
    , "rootedReceiptConfirmRequestKernel"
    , "rootedPostOpenRequest"
    , "rootedPostOpenBodyRequest"
    , "requireLifecyclePostOpen"
    , "requireLifecycleText"
    , "requireLifecycleNonce"
    , "boundedLifecycleRequest"
    , "rootedLifecycleRequestFromWireKernel"
    , "decodeLifecycleVariant"
    , "decodeLifecyclePostOpen"
    , "decodeLifecyclePostOpenBody"
    , "decodeLifecyclePath"
    , "decodeLifecycleText"
    , "decodeLifecyclePredecessor"
    , "decodeLifecycleOrdinal"
    , "renderRootedLifecycleRequestKernel"
    , "lifecyclePostOpenWire"
    , "lifecycleRequestWire"
    , "renderLifecyclePath"
    , "withRootedLifecycleRequestKernel"
    , "collectLifecycleFrames"
    , "collectLifecyclePathFrames"
    , "collect"
    , "takeLifecycleFrame"
    , "takeLifecyclePathFrame"
    , "takeLifecycleBoundedFrame"
    ]

rootedPreservationResponseFramingNames :: [String]
rootedPreservationResponseFramingNames =
    [ "rootedOpenedResponseUnsignedKernel"
    , "requireResponseCommon"
    , "requireResponsePostOpen"
    , "requireResponseBody"
    , "preparedResponseBody"
    , "responseCommon"
    , "responseWire"
    , "responsePostOpenWire"
    , "boundedResponseUnsigned"
    , "rootedLifecycleResponseFromUnsignedKernel"
    , "rootedLifecycleResponseFromWireKernel"
    , "withUnsignedResponse"
    , "decodeResponseCommon"
    , "decodeResponsePost"
    , "decodeResponseDigest"
    , "decodePreparedResponseBody"
    , "rootedLifecycleResponseSignatureKernel"
    , "renderRootedLifecycleResponseKernel"
    , "renderRootedLifecycleUnsignedResponseKernel"
    , "rootedLifecycleResponsePairKernel"
    , "rootedLifecycleUnsignedResponsePairKernel"
    , "withRootedLifecycleResponseKernel"
    ]

rootedPreservationSharedNames :: [String]
rootedPreservationSharedNames =
    [ "decodeDigest"
    , "requireDigest"
    , "require"
    , "rootedFrame"
    , "takeRootedFrame"
    , "word64BigEndian"
    , "bigEndianWord64"
    ]

rootedPreservationConstantNames :: [String]
rootedPreservationConstantNames =
    [ "rootedPayloadDomain"
    , "rootedPayloadVersion"
    , "rootedPayloadSignatureBytes"
    , "rootedFieldLimit"
    , "rootedLifecycleDomain"
    , "rootedLifecycleVersion"
    , "rootedLifecycleWireLimit"
    , "rootedLifecycleBodyLimit"
    , "rootedLifecycleTextLimit"
    , "rootedLifecyclePathLimit"
    , "rootedLifecycleNonceBytes"
    , "rootedLifecycleResponseDomain"
    , "rootedLifecycleResponseSignatureBytes"
    ]

rootedPreservationExpectedClauses :: String -> Int
rootedPreservationExpectedClauses "decodeLifecycleVariant" = 8
rootedPreservationExpectedClauses "decodeResponsePost" = 2
rootedPreservationExpectedClauses "require" = 2
rootedPreservationExpectedClauses _ = 1

rootedPreservationDeclarations :: [String] -> String -> IO [RootedPreservationDeclaration]
rootedPreservationDeclarations names source = forM names $ \name -> do
    unless (Text.count (Text.pack (name <> " ::")) (Text.pack source) == 1)
        (assertFailure (name <> " signature is missing or ambiguous"))
    signature <- requiredSourceSection (name <> " signature") (name <> " ::") ("\n" <> name <> " ") source
    let signatureTokens = SourceGuard.haskellTokens signature
    unless (take 2 signatureTokens == [name, "::"] && length signatureTokens > 2)
        (assertFailure (name <> " has an empty or malformed signature"))
    clauses <- either assertFailure pure (SourceGuard.haskellDefinitionClauseTokens name source)
    unless (length clauses == rootedPreservationExpectedClauses name && all (not . null) clauses)
        (assertFailure (name <> " has missing, ambiguous or empty complete clauses: " <> show (map length clauses)))
    pure (name, signatureTokens, clauses)

rootedPreservationShapes :: String -> IO [(String, [String])]
rootedPreservationShapes source = do
    request <- shape "RootedLifecycleRequest" "data RootedLifecycleRequest" "\nrootedLifecycleDomain ::"
    response <- shape "RootedLifecycleResponse" "data RootedLifecycleResponse" "\nrootedLifecycleResponseDomain ::"
    unless (SourceGuard.countHaskellTokenSequence ["type", "role", "RootedPayloadBinding", "nominal", "nominal"] source == 1)
        (assertFailure "the actual payload nominal-role declaration is missing or ambiguous")
    role <- requiredSourceSection "payload nominal roles" "type role RootedPayloadBinding" "\nrootedPayloadDomain ::" source
    let roleTokens = SourceGuard.haskellTokens role
    unless (not (null roleTokens)) (assertFailure "the actual role section is empty")
    pure [request, response, ("RootedPayloadBinding roles", roleTokens)]
  where
    shape name opening closing = do
        unless (SourceGuard.countHaskellTokenSequence ["data", name] source == 1)
            (assertFailure (name <> " data declaration is missing or ambiguous"))
        actual <- requiredSourceSection name opening closing source
        let tokens = SourceGuard.haskellTokens actual
        unless (not (null tokens)) (assertFailure (name <> " data declaration is empty"))
        pure (name, tokens)

-- | Freeze only the named Handoff wrapper definitions owned by a boundary.
-- DEVELOPMENT_PLAN/rationale.md#handoff-freezes-cover-owned-declarations
-- Ordered JSON arrays frame names, clauses and tokens as structured bytes.
-- Every expected digest is measured from the saved pre-change source.
-- The rooted transport baseline covers only its two neutral path folds,
-- including typed signatures and complete clauses, never shared edge progress.
frozenRootedTransportPathsDigest :: String -> IO Text.Text
frozenRootedTransportPathsDigest source = do
    declarations <- traverse
        (\(name, definition) -> do
            signature <- requiredSourceSection (name <> " signature") (name <> " ::") definition source
            clauses <- either assertFailure pure (SourceGuard.haskellDefinitionClauseTokens name source)
            length clauses @?= 1
            assertBool (name <> " has one nonempty complete clause") (all (not . null) clauses)
            pure (name, SourceGuard.haskellTokens signature, clauses))
        [ ("rootedLifecycleRequestPathKernel", "rootedLifecycleRequestPathKernel raw =")
        , ("rootedLifecycleResponsePairPathKernel", "rootedLifecycleResponsePairPathKernel exactRequest signedResponse =")
        ]
    pure (childConfigDigest (LazyByteString.toStrict (Aeson.encode declarations)))

-- The signing baseline covers only the existing capability's actual
-- data/signatures/OPAQUE tokens and three complete value clauses, never the
-- separate descriptive reread policy or a shared whole-file complement.
frozenSigningCapabilityDigest :: String -> IO Text.Text
frozenSigningCapabilityDigest source = do
    typed <- requiredSourceSection
        "the retained fixed-domain signing capability declarations"
        "data RecoverySigningKernel ="
        "consumeRootedLifecycleResponseSigningKernel kernel ="
        source
    declarations <- traverse
        (\name -> do
            clauses <- either assertFailure pure (SourceGuard.haskellDefinitionClauseTokens name source)
            length clauses @?= 1
            pure (name, clauses))
        [ "recoverySigningKernel"
        , "consumeRecoverySigningKernel"
        , "consumeRootedLifecycleResponseSigningKernel"
        ]
    pure (childConfigDigest (LazyByteString.toStrict
        (Aeson.encode (SourceGuard.haskellTokens typed, declarations))))

frozenHandoffDefinitionDigest :: [String] -> String -> IO Text.Text
frozenHandoffDefinitionDigest names source = do
    declarations <- traverse
        ( \name -> do
            clauses <- either assertFailure pure (SourceGuard.haskellDefinitionClauseTokens name source)
            pure (name, clauses)
        )
        names
    pure (childConfigDigest (LazyByteString.toStrict (Aeson.encode declarations)))

handoffTestModules :: [String]
handoffTestModules =
    [ "HostBootstrap.Handoff.Protocol"
    , "HostBootstrap.Handoff.Receiver"
    , "HostBootstrap.Handoff.Relay"
    , "HostBootstrap.Handoff.Internal"
    , "HostBootstrap.Handoff.Rooted"
    ]

handoffImplementationPublicModules :: [String]
handoffImplementationPublicModules =
    [ "HostBootstrap.Activation"
    , "HostBootstrap.Authority"
    , "HostBootstrap.Config.Class"
    , "HostBootstrap.Config.Fields"
    , "HostBootstrap.Config.Schema"
    , "HostBootstrap.Config.Vocab"
    , "HostBootstrap.Context"
    , "HostBootstrap.Dhall.Gen"
    , "HostBootstrap.Dhall.Hoist"
    , "HostBootstrap.Handoff"
    , "HostBootstrap.Harness"
    , "HostBootstrap.HostConfig"
    , "HostBootstrap.HostTool"
    , "HostBootstrap.Lifecycle.Closure"
    , "HostBootstrap.Lifecycle.Context"
    , "HostBootstrap.Lifecycle.Execution"
    , "HostBootstrap.Lifecycle.Mode"
    , "HostBootstrap.Lifecycle.Prepared"
    , "HostBootstrap.Lifecycle.Session"
    , "HostBootstrap.Lift.Context"
    , "HostBootstrap.ProjectPlan"
    , "HostBootstrap.ProjectPlan.Frame"
    , "HostBootstrap.ProjectRoot"
    , "HostBootstrap.RoleLifecycle"
    , "HostBootstrap.Service"
    , "HostBootstrap.Service.Program"
    , "HostBootstrap.Step"
    , "HostBootstrap.Substrate"
    , "HostBootstrap.Teardown"
    ]

handoffImplementationMainOnlyModules :: [String]
handoffImplementationMainOnlyModules =
    [ "HostBootstrap.Config.Authority.Internal"
    , "HostBootstrap.Config.Install.Native"
    , "HostBootstrap.Config.Schema.Internal"
    , "HostBootstrap.Handoff.Receiver.Internal"
    , "HostBootstrap.Handoff.Recovery"
    , "HostBootstrap.Handoff.Runtime"
    , "HostBootstrap.Lifecycle.Context.Internal"
    , "HostBootstrap.Lifecycle.Dependency.Internal"
    , "HostBootstrap.Lifecycle.Execution.Internal"
    , "HostBootstrap.Lifecycle.Plan"
    , "HostBootstrap.Lifecycle.Prepared.Internal"
    , "HostBootstrap.Lifecycle.ResourceRecord"
    , "HostBootstrap.Lifecycle.Rooted"
    , "HostBootstrap.Lifecycle.Rooted.Receipt"
    , "HostBootstrap.Lifecycle.RootedPlan"
    , "HostBootstrap.ProjectPlan.Construct.Internal"
    , "HostBootstrap.ProjectPlan.Projection.Internal"
    , "HostBootstrap.Teardown.Internal"
    ]

handoffImplementationOtherModules :: [String]
handoffImplementationOtherModules =
    [ "HostBootstrap.Config.Class.Internal"
    , "HostBootstrap.Config.Fields.Internal"
    , "HostBootstrap.Lifecycle.Recovery"
    , "HostBootstrap.Lifecycle.Transaction"
    , "HostBootstrap.Service.Internal"
    ]

{- | The rows of the package description a handoff sprint owns: its own module
rows across its actual Main/private owners, and the Main dependency rows already owned by handoff.

§ C: a sprint freezes the bytes of a module, a stanza, or a set of rows it is
responsible for, and may not freeze a whole shared file whose other parts belong
to other phases. A digest over the complete package description makes every
sprint that adds a module anywhere in the package break the evidence of every
handoff sprint that froze it — a coupling no dependency edge justifies and that
numerical order cannot express. Later dependencies are ignored, while removal
of one of the handoff-owned rows still fails the freeze.
-}
handoffPackageRows :: String -> IO [String]
handoffPackageRows cabalText = do
    library <-
        maybe
            (assertFailure "hostbootstrap-core.cabal has no main library stanza")
            pure
            (mainLibraryStanza cabalText)
    modules <- either assertFailure pure (SourceGuard.mainImplementationModuleNames cabalText)
    pure
        ( sort
            [ moduleName
            | moduleName <- modules
            , "HostBootstrap.Handoff" `isPrefixOf` moduleName
            ]
            ++ filter (`elem` frozenHandoffPackageRows) (libraryDependencyNames library)
        )

{- | Every package the main library depends on, by name and in order, including
the platform-conditional rows nested inside the stanza.

The stanza is read as text rather than evaluated, so both arms of a
platform condition are present on every gate host (§ JJ) — the Windows-only and
the POSIX-only dependency alike. A list that varied by gate host would be a
freeze that means a different thing on each one.
-}
libraryDependencyNames :: String -> [String]
libraryDependencyNames library = sort (go (lines library))
  where
    go [] = []
    go (line : rest)
        | trim line == "build-depends:" =
            let fieldIndent = indentation line
                (continuation, remaining) =
                    span
                        (\next -> null (trim next) || indentation next > fieldIndent)
                        rest
             in dependencyNames continuation <> go remaining
        | otherwise = go rest

    dependencyNames = concatMap (take 1 . words . dropLeadingComma . trim)

    dropLeadingComma (',' : rest) = rest
    dropLeadingComma value = value

{- | The exact rows the handoff surface is frozen at. One list, so a sprint that
adds a handoff module or a library dependency updates one place rather than six.
-}
frozenHandoffPackageRows :: [String]
frozenHandoffPackageRows =
    [ "HostBootstrap.Handoff"
    , "HostBootstrap.Handoff.Completion"
    , "HostBootstrap.Handoff.Internal"
    , "HostBootstrap.Handoff.Process"
    , "HostBootstrap.Handoff.Process.Route"
    , "HostBootstrap.Handoff.Protocol"
    , "HostBootstrap.Handoff.Receiver"
    , "HostBootstrap.Handoff.Receiver.Internal"
    , "HostBootstrap.Handoff.Recovery"
    , "HostBootstrap.Handoff.Relay"
    , "HostBootstrap.Handoff.Rooted"
    , "HostBootstrap.Handoff.Runtime"
    , "HostBootstrap.Handoff.TerminalReport"
    , "HostBootstrap.Handoff.Transaction"
    , "Win32"
    , "aeson"
    , "base"
    , "bytestring"
    , "containers"
    , "crypton"
    , "dhall"
    , "directory"
    , "filepath"
    , "hostbootstrap-core:colima-backend-internal"
    , "hostbootstrap-core:effect-internal"
    , "hostbootstrap-core:harness-lifecycle-internal"
    , "hostbootstrap-core:ownership-internal"
    , "memory"
    , "optparse-applicative"
    , "process"
    , "safe-exceptions"
    , "text"
    , "unix"
    ]

normalizedModuleExports :: [String] -> [String]
normalizedModuleExports = map concat . splitAtTopLevelCommas 0 []
  where
    splitAtTopLevelCommas :: Int -> [String] -> [String] -> [[String]]
    splitAtTopLevelCommas _depth current [] =
        [reverse current | not (null current)]
    splitAtTopLevelCommas depth current (token : remaining)
        | token == "," && depth == 0 =
            reverse current : splitAtTopLevelCommas depth [] remaining
        | token == "(" =
            splitAtTopLevelCommas (depth + 1) (token : current) remaining
        | token == ")" =
            splitAtTopLevelCommas (depth - 1) (token : current) remaining
        | otherwise =
            splitAtTopLevelCommas depth (token : current) remaining

-- | Select a frozen region directly from the source bytes, without re-encoding text.
requiredFrozenSourceSection :: String -> ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString -> IO ByteString.ByteString
requiredFrozenSourceSection label opening closing source =
    case ByteString.breakSubstring opening source of
        (_, fromOpening)
            | ByteString.null fromOpening ->
                assertFailure (label <> " is missing opening marker " <> show opening)
            | otherwise ->
                case ByteString.breakSubstring closing fromOpening of
                    (_, fromClosing)
                        | ByteString.null fromClosing ->
                            assertFailure (label <> " is missing closing marker " <> show closing)
                        | otherwise ->
                            pure (ByteString.take (ByteString.length fromOpening - ByteString.length fromClosing) fromOpening)

requiredSourceSection :: String -> String -> String -> String -> IO String
requiredSourceSection label opening closing source =
    case Text.breakOn (Text.pack opening) (Text.pack source) of
        (_, afterOpening)
            | Text.null afterOpening ->
                assertFailure (label <> " is missing opening marker " <> show opening)
            | otherwise ->
                let fromOpening = afterOpening
                    (_, fromClosing) = Text.breakOn (Text.pack closing) fromOpening
                 in if Text.null fromClosing
                        then assertFailure (label <> " is missing closing marker " <> show closing)
                        else
                            pure
                                ( Text.unpack
                                    (Text.take (Text.length fromOpening - Text.length fromClosing) fromOpening)
                                )

assertContains :: String -> String -> String -> IO ()
assertContains label fragment source =
    assertBool
        (label <> ": missing " <> show fragment)
        (fragment `isInfixOf` source)

-- | Match complete lexical fragments in order without treating comments or string contents as code.
fragmentsInOrder :: [String] -> String -> Either String ()
fragmentsInOrder fragments source = go fragments (SourceGuard.haskellTokens source)
  where
    go [] _ = Right ()
    go (fragment : remaining) input =
        if null wanted then Left fragment else search input
      where
        wanted = SourceGuard.haskellTokens fragment
        search [] = Left fragment
        search tokens@(_ : rest) = case stripPrefix wanted tokens of
            Just after -> go remaining after
            Nothing -> search rest

assertFragmentsInOrder :: String -> [String] -> String -> IO ()
assertFragmentsInOrder label fragments source =
    case fragmentsInOrder fragments source of
        Left missing -> assertFailure (label <> ": missing ordered fragment " <> show missing)
        Right () -> pure ()

-- | Read registration fields across the whole description, including common and conditional rows.
registeredCabalModules :: String -> [String]
registeredCabalModules source =
    concatMap (`SourceGuard.fieldModules` source)
        [ "exposed-modules"
        , "other-modules"
        , "reexported-modules"
        , "signatures"
        , "autogen-modules"
        , "virtual-modules"
        ]

protectedHandoffImage :: ProtectedStore -> IO [(Text.Text, Word64, ByteString.ByteString)]
protectedHandoffImage store = do
    entered <- withProtectedEntry store $ \session -> do
        keys <- listProtectedRecords session
        case keys of
            Left failure -> pure (Left failure)
            Right present -> do
                rows <- forM present $ \key -> do
                    loaded <- readProtectedRecord session key
                    actual <- expectRight loaded
                    record <- maybe (assertFailure "a listed protected record disappeared") pure actual
                    pure (recordKeyText key, recordVersionWord (protectedRecordVersion record), protectedRecordBytes record)
                pure (Right (sort rows))
    expectRight entered

requireSingleHandoffRow ::
    [(Text.Text, Word64, ByteString.ByteString)] -> IO (Text.Text, Word64, ByteString.ByteString)
requireSingleHandoffRow rows = case rows of
    [row] -> pure row
    _ -> assertFailure ("expected exactly one actual token row, saw " <> show rows)

expectSignatureRefusal :: (Show value) => Either HandoffError value -> IO ()
expectSignatureRefusal outcome = case outcome of
    Left HandoffSignatureInvalid -> pure ()
    other -> assertFailure ("expected a signature refusal, got " <> show other)

expectBindingRefusal :: (Show value) => String -> Either HandoffError value -> IO ()
expectBindingRefusal expected outcome = do
    assertBool "a binding refusal must name a nonempty expected detail" (any (not . isSpace) expected)
    case outcome of
        Left (HandoffBindingMismatch detail) ->
            assertBool ("expected binding detail " <> show expected <> ", got " <> show detail)
                (expected `isInfixOf` Text.unpack detail)
        other -> assertFailure ("expected a binding refusal, got " <> show other)

expectSigningKeyUnavailable :: Either HandoffError ProjectSigningKey -> IO ()
expectSigningKeyUnavailable outcome = case outcome of
    Left (HandoffSigningKeyUnavailable _) -> pure ()
    other -> assertFailure ("expected a missing signing-key refusal, got " <> show other)

expectVerificationKeyUnavailable :: Either HandoffError ProjectVerificationKey -> IO ()
expectVerificationKeyUnavailable outcome = case outcome of
    Left (HandoffVerificationKeyUnavailable _) -> pure ()
    other -> assertFailure ("expected a verification-key refusal, got " <> show other)

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

contains :: String -> String -> Bool
contains needle haystack = any (needle `prefixOf`) (tails haystack)
  where
    tails [] = [[]]
    tails value@(_ : rest) = value : tails rest
    prefixOf [] _ = True
    prefixOf _ [] = False
    prefixOf (x : xs) (y : ys) = x == y && prefixOf xs ys

-- | An alias retained at its call sites; the unwrapping itself is 'Expect.expectRight'.
expectRightIO :: (Show err) => Either err value -> IO value
expectRightIO = expectRight
