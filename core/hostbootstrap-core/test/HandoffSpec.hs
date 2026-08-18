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
The production recovery and root-scope signers remain inaccessible.
-}
module HandoffSpec (tests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, evaluate, finally, try)
import Control.Monad (forM_, when)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import qualified Crypto.PubKey.Ed25519 as Ed25519
import Data.ByteArray (convert)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Char (isSpace, toUpper)
import Data.Foldable (traverse_)
import Data.Kind (Type)
import Data.List (isInfixOf, isPrefixOf, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word8)
import qualified Fixture
import HostBootstrap.Authority (
    InstalledProjectIdentity,
    ProjectVerb (ProjectDestroy, ProjectDown, ProjectUp),
    VerbUp,
    installedProjectName,
 )
import HostBootstrap.Config.Class (
    ProjectCfg (withProductionProjectCodec),
    ProjectCodec,
    renderProjectCodecHoisted,
 )
import HostBootstrap.Config.Schema (
    ConfigWireAdmissionError (..),
    SiblingConfigInstallError (..),
    SiblingConfigInstallResult (..),
    installAuthenticatedProductionSiblingConfig,
    siblingProjectConfigPath,
    validatedConfigValue,
    verifiedConfigDigest,
    withAuthenticatedConfigWire,
    withVerifiedConfigHandoff,
 )
import HostBootstrap.Config.Vocab (
    Harness,
    HarnessAuthority,
    Production,
    harnessRunName,
 )
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Handoff
import HostBootstrap.Handoff.Transaction (
    FrameAnswer (FrameOutcome, FrameRefusal, FrameUnexpected),
    classifyFrameChild,
    frameChildArguments,
    readFrameAnswer,
    withFrameChildTransaction,
 )
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.Lift (localContext, mkSelfRef)
import HostBootstrap.Lift.Context (IncusVM (..), inVM)
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
import HostBootstrap.Protected (
    ProtectedStore,
    openProtectedStore,
    protectedStoreIdentity,
    protectedStoreIdentityText,
 )
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import qualified SourceGuard
import System.Directory (doesDirectoryExist, doesPathExist, getCurrentDirectory, listDirectory, removePathForcibly)
import System.Environment (getExecutablePath)
import System.FilePath ((</>), takeExtension)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "HandoffSpec"
        [ testGroup "length framing" framingTests
        , testGroup "binding rendering" bindingTests
        , testGroup "the signed handoff protocol" protocolTests
        , testGroup "the recovery wire" recoveryTests
        , testGroup "the lifecycle completion wire" lifecycleCompletionWireTests
        , testGroup "the durable lifecycle acknowledgement substrate" lifecycleAcknowledgementSubstrateTests
        , testGroup "the sealed facade" sealedFacadeTests
        , testGroup "the frame-child entry" frameCrossingTests
        ]

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
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            traverse_
                ( \marker ->
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , show marker `isInfixOf` source
                        ]
                        @?= ["HostBootstrap/Handoff/Transaction.hs"]
                )
                frameChildArguments
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
                (mkSelfRef executable executable)
                (inVM IncusVM{vmName = "absent", vmImage = "absent"} localContext)
                "one transaction"
        crossed @?= Left "frame child: the crossing's host tool resolves to no absolute path"
    , testCase "a local crossing answers one transaction across a real process boundary" $ do
        executable <- getExecutablePath
        crossed <-
            withFrameChildTransaction
                unresolvedHostConfig
                (mkSelfRef executable executable)
                localContext
                "one transaction"
        crossed
            @?= Left
                ( "frame child: the frame refused the transaction: unavailable: "
                    <> "no transaction interpreter is installed at this frame"
                )
    , testCase "the argument vector is read once, by the classifier, before the parser" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            cliSource <- readFile (sourceRoot </> "HostBootstrap" </> "CLI.hs")
            SourceGuard.countHaskellIdentifier "getArgs" cliSource @?= 2
            SourceGuard.countHaskellIdentifier "classifyFrameChild" cliSource @?= 2
            SourceGuard.countHaskellIdentifier "runFrameChildEntry" cliSource @?= 2
            assertContains
                "runCLI classifies argv once and otherwise runs the parser"
                ( "argv <- getArgs case classifyFrameChild argv of "
                    <> "Just entry -> runFrameChildEntry entry "
                    <> "Nothing -> join (customExecParser (prefs showHelpOnEmpty) opts)"
                )
                (normalizeWhitespace cliSource)
            traverse_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier cliSource @?= 0)
                ["getProgName", "lookupEnv", "getEnvironment", "withArgs"]
            transactionSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Transaction.hs")
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
            (significantHaskellLineCount transactionSource, significantHaskellLineCount cliSource)
                @?= (275, 451)
    ]

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
    ]

-- ---------------------------------------------------------------------------
-- Bindings

bindingTests :: [TestTree]
bindingTests =
    [ testCase "field boundaries are unambiguous across the frame edge" $
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
            expectBindingRefusal
                ( withHandoffBindingFromWire
                    (productionHandoffScope project)
                    (renderHandoffBinding binding)
                    (const ())
                )
    , testCase "an empty required field is rejected before signing" $
        withHandoff 7 ProjectUp $ \broker -> do
            token <- freshHandoffToken
            case mkHandoffBinding broker (bindingInputFor childPayload){requestedSpecDigest = ""} token of
                Left (HandoffBindingMismatch _) -> pure ()
                other -> assertFailure ("expected an invalid binding, got " <> show other)
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
            expectBindingRefusal
                (withVerifiedRootedPayloadBinding verified foreignEdge (const ()))
            let otherDigest = childConfigDigest "other exact bytes"
            splitConfig <-
                rootedOracleWire 73 canonicalRootedPayloadSigningDomain key edge digest otherDigest
            expectBindingRefusal
                (withVerifiedRootedPayloadBinding verified splitConfig (const ()))
            foreignPayload <-
                rootedOracleWire 73 canonicalRootedPayloadSigningDomain key edge otherDigest otherDigest
            expectBindingRefusal
                (withVerifiedRootedPayloadBinding verified foreignPayload (const ()))
            expectBindingRefusal
                (withVerifiedRootedPayloadBinding verified (ByteString.init rooted) (const ()))
            expectBindingRefusal
                (withVerifiedRootedPayloadBinding verified (rooted <> "trailing") (const ()))
            let shortSignature = rootedPayloadUnsigned edge digest digest <> frameWire (ByteString.replicate 63 0)
            expectBindingRefusal
                (withVerifiedRootedPayloadBinding verified shortSignature (const ()))
            expectBindingRefusal
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
            expectBindingRefusal
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
            expectBindingRefusal
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
            expectBindingRefusal
                (withVerifiedRootedPayloadBinding verified conflated (const ()))
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
            expectBindingRefusal
                (verify (wireWithFrames [(0, "hostbootstrap/rooted-payload-binding/not-v1")] canonicalFields))
            expectBindingRefusal
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
                expectPackageRefusal payload = do
                    (verified, rooted) <-
                        verifyPackage payload (childConfigDigest "independent claimed child config")
                    expectBindingRefusal
                        (withVerifiedRecoveryChildPackage verified rooted (\_ _ _ -> ()))

            (verified, rooted) <- verifyPackage packageBytes configDigest
            withVerifiedRecoveryChildPackage
                verified
                rooted
                (\package exactConfig exactAdapter ->
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
            expectBindingRefusal
                (withVerifiedRecoveryChildPackage verified wrongConfigRooted (\_ _ _ -> ()))

            traverse_
                expectPackageRefusal
                [ frameWire childConfig
                , frameWire "" <> frameWire adapter
                , frameWire childConfig <> frameWire ""
                , packageBytes <> frameWire "third"
                , ByteString.init packageBytes
                , ByteString.pack [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff] <> "x"
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
            expectBindingRefusal
                (withVerifiedRecoveryChildPackage configVerified configRooted (\_ _ _ -> ()))
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
                assertRefused (label, outcome) = case outcome of
                    Left _ -> pure ()
                    Right admitted ->
                        assertFailure
                            (label <> " unexpectedly admitted the " <> admitted <> " branch")
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
                    [ ( 5
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
                    [ ("empty wire", ByteString.empty)
                    , ("missing seventh frame", renderFrameFields (take 6 canonicalFields))
                    , ("truncated body", ByteString.init canonical)
                    , ("trailing eighth frame", canonical <> frameWire "trailing")
                    , ("short signature", shortSignature)
                    , ("oversized declared field", oversizedDeclaredField)
                    , ( "oversized total wire"
                      , ByteString.replicate (fromIntegral maxWireBytes + 1) 0
                      )
                    ]
            traverse_
                assertRefused
                [ ("wrong codec domain", verifyWith key wrongCodec)
                , ("wrong version", verifyWith key wrongVersion)
                , ("wrong installed project", verifyWith key wrongProject)
                , ("unclosed kind", verifyWith key wrongKind)
                , ("Production with a run", verifyWith key productionRun)
                , ("Harness with an empty run", verifyWith key emptyHarnessRun)
                , ("Harness with a noncanonical run", verifyWith key noncanonicalHarnessRun)
                , ("Harness with an oversized run", verifyWith key oversizedHarnessRun)
                , ("Harness with malformed UTF-8", verifyWith key malformedRun)
                , ("wrong installed key digest", verifyWith key wrongKeyDigest)
                , ("wrong signing domain", verifyWith key wrongSigningDomain)
                , ("cross-key signature", verifyWith key crossKeySignature)
                , ("changed signature", verifyWith key changedSignature)
                , ("unsigned kind/run substitution", verifyWith key substitutedHarness)
                , ("unsigned Harness run substitution", verifyWith key substitutedRun)
                , ( "foreign installed verification key"
                  , verifyWith (projectSigningVerificationKey otherSigning) canonical
                  )
                ]
            traverse_ (assertRefused . fmap (verifyWith key)) malformedWires
    ]

dedupe :: (Eq a) => [a] -> [a]
dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- ---------------------------------------------------------------------------
-- The protocol

protocolTests :: [TestTree]
protocolTests =
    [ testCase "a root broker refuses a protected store outside its root authority" $
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
    , testCase "authenticated sibling install is atomic, idempotent, and conflict-preserving" $
        withNamedHandoff 15 ProjectUp $ \(project :: InstalledProjectIdentity projectId) broker ->
            withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \codec -> do
                let projectName = installedProjectName project
                    cfg =
                        Fixture.defaultProjectConfig
                            projectName
                            "/workspace/demo"
                            Context.HostOrchestrator
                    payload = canonicalConfigBytes codec cfg
                authenticated <- authenticatedPayload broker payload
                path <- siblingProjectConfigPath projectName
                let lockPath = path <> ".hostbootstrap-handoff.lock"
                    cleanup = removeIfPresent path >> removeIfPresent lockPath
                    exercise = do
                        leftResult <- newEmptyMVar
                        rightResult <- newEmptyMVar
                        _ <- forkIO (installAuthenticatedProductionSiblingConfig project authenticated >>= putMVar leftResult)
                        _ <- forkIO (installAuthenticatedProductionSiblingConfig project authenticated >>= putMVar rightResult)
                        left <- takeMVar leftResult
                        right <- takeMVar rightResult
                        assertBool
                            ( "one creator installs and its concurrent peer converges, observed "
                                <> show [left, right]
                            )
                            ( [left, right]
                                `elem` [ [Right SiblingConfigInstalled, Right SiblingConfigAlreadyPresent]
                                       , [Right SiblingConfigAlreadyPresent, Right SiblingConfigInstalled]
                                       ]
                            )
                        ByteString.readFile path >>= (@?= payload)
                        ByteString.writeFile path "foreign replacement"
                        installAuthenticatedProductionSiblingConfig project authenticated
                            >>= (@?= Left (SiblingConfigConflict path))
                        ByteString.readFile path >>= (@?= "foreign replacement")
                cleanup
                exercise `finally` cleanup
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
        withHandoff 7 ProjectUp $ \broker -> do
            (_, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            first <- expectRightIO =<< grantHandoff broker offer challenge
            retry <- expectRightIO =<< grantHandoff broker offer challenge
            grantSignature retry @?= grantSignature first
            otherChallenge <- freshChallenge
            reused <- grantHandoff broker offer otherChallenge
            reused @?= Left HandoffTokenConsumed
    , testCase "concurrent identical grant requests converge on one signature" $
        withHandoff 7 ProjectUp $ \broker -> do
            (_, offer) <- newOffer broker childPayload
            challenge <- freshChallenge
            start <- newEmptyMVar
            firstResult <- newEmptyMVar
            secondResult <- newEmptyMVar
            _ <- forkIO (takeMVar start >> grantHandoff broker offer challenge >>= putMVar firstResult)
            _ <- forkIO (takeMVar start >> grantHandoff broker offer challenge >>= putMVar secondResult)
            putMVar start ()
            putMVar start ()
            first <- takeMVar firstResult >>= expectRightIO
            second <- takeMVar secondResult >>= expectRightIO
            grantSignature second @?= grantSignature first
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
        withHandoff 7 ProjectUp $ \broker -> do
            withProductionProjectCodec @Fixture.ProjectConfig $ \codec -> do
                let cfg =
                        Fixture.defaultProjectConfig
                            "hostbootstrap-demo"
                            "/workspace/demo"
                            Context.HostOrchestrator
                    payload = canonicalConfigBytes codec cfg
                handoff <- verifiedHandoffFor broker payload
                authenticated <- expectRight (verifiedConfigPayload handoff)
                admitted <-
                    withAuthenticatedConfigWire codec authenticated $ \wire validated ->
                        pure
                            ( withVerifiedConfigHandoff
                                ProjectDestroy
                                handoff
                                wire
                                validated
                                (const ())
                            )
                case admitted of
                    Right (Left (HandoffBindingMismatch _)) -> pure ()
                    other -> assertFailure ("expected a verb refusal, got " <> show other)
    , testCase "a parent cannot offer payload or token bytes the binding does not describe" $
        withHandoff 7 ProjectUp $ \broker -> do
            token <- freshHandoffToken
            replacement <- freshHandoffToken
            binding <- expectRight (mkHandoffBinding broker (bindingInputFor childPayload) token)
            relay <- expectRight (brokerRelay broker binding)
            expectBindingRefusal (mkHandoffOffer relay "different bytes entirely" token)
            expectBindingRefusal (mkHandoffOffer relay childPayload replacement)
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
    , testCase "failed child verification cannot consume the root token" $
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
            let rendered = unwords [show offer, show broker, show grant, show HandoffTokenConsumed]
            assertBool "payload bytes are absent" (not (ByteStringChar8.unpack secretPayload `contains` rendered))
            assertBool "redaction marker is present" ("<redacted>" `contains` rendered)
            assertBool "consumed-token diagnostics carry no token" (handoffErrorMessage HandoffTokenConsumed == "handoff: one-time token has already authorized another transcript")
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
    [ testCase "ordered lifecycle observations round-trip through the exact closed table" $ do
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
        assertLifecycleRefusal
            "oversized received observations"
            (lifecycleObservationsFromWire (ByteString.replicate overBound 0))
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
                reverseCompleted <- expectRight (renderReverseCompletedLifecycleReport reverseOrigin completedRows)
                reverseRefused <- expectRight (renderReverseRefusedLifecycleReport reverseBinding completedRows "policy")
                reverseFailed <- expectRight (renderReverseFailedLifecycleReport reverseBinding failedRows "boom")
                let cases =
                        [ ("forward-completed", forwardCompleted, forwardBinding, Just forwardOrigin, empty, "none", "up")
                        , ("forward-refused", forwardRefused, forwardBinding, Nothing, empty, "policy", "up")
                        , ("forward-failed", forwardFailed, forwardBinding, Nothing, empty, "boom", "up")
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
                    let badForward =
                            [ ("domain", [(0, "wrong")])
                            , ("reverse binding", [(1, reverseBinding)])
                            , ("empty invocation", [(2, "")])
                            , ("acquisition zero", [(3, "0")])
                            , ("acquisition positive but wrong", [(3, "2")])
                            , ("execute positive but wrong", [(4, "1")])
                            , ("teardown positive but wrong", [(5, "2")])
                            , ("verb", [(6, "down")])
                            , ("execute phase", [(7, "teardown")])
                            , ("teardown phase", [(8, "execute")])
                            ]
                    forM_ badForward $ \(label, replacements) ->
                        assertLifecycleRefusal
                            ("forward origin " <> label)
                            ( renderForwardCompletedLifecycleReport
                                (wireWithFrames replacements forwardFields)
                            )
                    let alternateDigest = ByteString.replicate 64 97
                        badReverse =
                            [ ("domain", [(0, "wrong")])
                            , ("version", [(1, "2")])
                            , ("forward binding", [(2, foreignForwardBinding)])
                            , ("plan join", [(3, "other-plan"), (4, "other-plan")])
                            , ("empty invocation", [(5, "")])
                            , ("acquisition zero", [(6, "0")])
                            , ("acquisition positive but wrong", [(6, "2")])
                            , ("cursor positive but wrong", [(7, "2")])
                            , ("child-frame join", [(8, "other-child"), (13, "other-child")])
                            , ("broker-generation join", [(9, "2")])
                            , ("verb joins", [(10, "down"), (11, "down"), (14, "down")])
                            , ("phase", [(12, "execute")])
                            , ("adapter join", [(15, alternateDigest)])
                            ]
                    observations <- expectRight (renderLifecycleObservations [("one", "released", "none")])
                    forM_ badReverse $ \(label, replacements) ->
                        assertLifecycleRefusal
                            ("reverse origin " <> label)
                            ( renderReverseCompletedLifecycleReport
                                (wireWithFrames replacements reverseFields)
                                observations
                            )
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
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            teardownSource <- readFile (sourceRoot </> "HostBootstrap" </> "Teardown.hs")
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
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let users identifier =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                publicCodecNames =
                    [ "renderLifecycleObservations"
                    , "lifecycleObservationsFromWire"
                    , "renderForwardCompletedLifecycleReport"
                    , "renderForwardRefusedLifecycleReport"
                    , "renderForwardFailedLifecycleReport"
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
                exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
            forM_ publicCodecNames $ \name ->
                assertBool (name <> " is public") (name `elem` exports)
            users "renderLifecycleObservations"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Teardown.hs"]
            users "lifecycleObservationsFromWire"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Teardown.hs"]
            forM_
                [ "renderForwardCompletedLifecycleReport"
                , "renderReverseCompletedLifecycleReport"
                ]
                $ \name ->
                    users name
                        @?= [ "HostBootstrap/Handoff.hs"
                            , "HostBootstrap/Handoff/Lifecycle.hs"
                            ]
            users "eliminateLifecycleReport"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Completion.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    ]
            users "renderLifecycleAcknowledgement"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Completion.hs"
                    , "HostBootstrap/Handoff/Protocol.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            forM_
                [ "renderForwardRefusedLifecycleReport"
                , "renderForwardFailedLifecycleReport"
                , "renderReverseRefusedLifecycleReport"
                , "renderReverseFailedLifecycleReport"
                ]
                $ \name -> users name @?= ["HostBootstrap/Handoff.hs"]
            users "verifyLifecycleAcknowledgement"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            users "renderTeardownObservations"
                @?= [ "HostBootstrap/Handoff/Lifecycle.hs"
                    , "HostBootstrap/Teardown.hs"
                    ]
            users "teardownObservationsFromWire"
                @?= [ "HostBootstrap/Handoff/Completion.hs"
                    , "HostBootstrap/Teardown.hs"
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
                , "HostBootstrap.Handoff.Lifecycle"
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
                        (not (moduleName `isInfixOf` cabalSource))
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
    [ testCase "all four lifecycle kernels force hidden admission at partial application" $ do
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
    , testCase "durable lifecycle rows are exact, transcript-bound, convergent, and callback-safe" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
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
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let kernels =
                    [ "publishLifecycleReportKernel"
                    , "receiveLifecycleAcknowledgementKernel"
                    , "prepareLifecycleAcknowledgementKernel"
                    , "adoptLifecycleAcknowledgementKernel"
                    ]
                exports = normalizedModuleExports handoffExports
                users identifier =
                    sort
                        [ sourcePath sourceRoot path
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
                preparedRows = normalizeWhitespace prepareRows
                publishedRows = normalizeWhitespace publishRows
                adoptedRows = normalizeWhitespace adoptRows
                readback = normalizeWhitespace rowReadback
                entry = normalizeWhitespace entrySource
                private = fieldModules "other-modules:" librarySource
                exposed = fieldModules "exposed-modules:" librarySource
            namedDeclarations @?= []
            significantHaskellLineCount durableSource @?= 308
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
                        @?= [ "HostBootstrap/Handoff.hs"
                            , "HostBootstrap/Handoff/Relay.hs"
                            ]
                )
                [ "publishLifecycleReportKernel"
                , "receiveLifecycleAcknowledgementKernel"
                , "prepareLifecycleAcknowledgementKernel"
                , "adoptLifecycleAcknowledgementKernel"
                ]
            traverse_
                ( \hidden -> assertBool (hidden <> " remains hidden") (hidden `notElem` exports)
                )
                [ "RecoverySigningKernel"
                , "recoverySigningKernel"
                , "consumeRecoverySigningKernel"
                ]
            mapM_
                (\(label, fragment, body) -> assertContains label fragment body)
                [ ( "publish admission is first and strict"
                  , "publishLifecycleReportKernel kernel = case consumeRecoverySigningKernel kernel () of () -> \\store report"
                  , publish
                  )
                , ( "receive admission is first and strict"
                  , "receiveLifecycleAcknowledgementKernel kernel = case consumeRecoverySigningKernel kernel () of () -> \\store report acknowledgement"
                  , receiveAck
                  )
                , ( "prepare admission is first and strict"
                  , "prepareLifecycleAcknowledgementKernel kernel = case consumeRecoverySigningKernel kernel () of () -> \\broker offer challenge report acknowledgement pending alreadyAdopted"
                  , prepare
                  )
                , ( "adopt admission is first and strict"
                  , "adoptLifecycleAcknowledgementKernel kernel = case consumeRecoverySigningKernel kernel () of () -> \\broker offer challenge report acknowledgement fresh replay"
                  , adopt
                  )
                , ( "child report must name the exact store"
                  , "handoffStoreIdentity binding == protectedStoreIdentityText (protectedStoreIdentity store)"
                  , child
                  )
                , ( "child publication is binding-keyed"
                  , "lifecycleRecordKey \"child\" bindingBytes"
                  , child
                  )
                , ( "child publication is exact v1 Published"
                  , "lifecycleDurableRow \"child\" \"published\" bindingBytes report ByteString.empty"
                  , child
                  )
                , ( "child receipt is exact v2 Received"
                  , "lifecycleDurableRow \"child\" \"received\" bindingBytes report acknowledgement"
                  , child
                  )
                , ( "parent material revalidates the live broker"
                  , "brokerRelay broker binding"
                  , parent
                  )
                , ( "parent report joins the exact offer binding"
                  , "bindingBytes == renderHandoffBinding binding"
                  , parent
                  )
                , ( "parent offer payload joins its binding"
                  , "handoffChildConfigDigest binding == childConfigDigest (offerPayload offer)"
                  , parent
                  )
                , ( "parent offer token joins its binding"
                  , "handoffTokenCommitment binding == tokenCommitment (offerToken offer)"
                  , parent
                  )
                , ( "parent acknowledgement is canonical for the report"
                  , "verifyLifecycleAcknowledgement report acknowledgement"
                  , parent
                  )
                , ( "parent rows use a distinct binding key"
                  , "lifecycleRecordKey \"parent\" bindingBytes"
                  , parent
                  )
                , ( "the token row must be exactly v2"
                  , "recordVersionWord (protectedRecordVersion record) == 2"
                  , granted
                  )
                , ( "the complete granted transcript is byte-equal"
                  , "protectedRecordBytes record == grantedEdgeRecord (TextEncoding.encodeUtf8 (digestBytes material))"
                  , granted
                  )
                , ( "the grant digest retains the exact root key, binding, token, and challenge"
                  , "material = signedMaterial (rootBrokerVerificationKey broker) binding (tokenFrame (offerToken offer)) challenge"
                  , granted
                  )
                , ( "durable rows are bounded before storage"
                  , "bounded \"lifecycle durable row\" raw"
                  , durable
                  )
                , ( "durable keys hash the complete canonical binding"
                  , "mkRecordKey (\"lifecycle-\" <> side <> \".\" <> recoveryWireDigest binding)"
                  , durable
                  )
                , ( "row equality includes version and bytes"
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
                receiveAck
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
                prepare
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
                adopt
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
                preparedRows
            assertFragmentsInOrder
                "child absence converges only on exact Published or Received"
                [ "ExpectAbsent published"
                , "exactLifecycleRow 1 published record"
                , "exactLifecycleRow 2 received record"
                , "lifecycleRowConflict"
                ]
                publishedRows
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
                adoptedRows
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
                entry
            SourceGuard.countHaskellIdentifier "RecoverySigningKernel" durableSource @?= 4
            SourceGuard.countHaskellIdentifier "consumeRecoverySigningKernel" durableSource @?= 4
            SourceGuard.countHaskellIdentifier "withActiveRootBroker" durableSource @?= 2
            SourceGuard.countHaskellIdentifier "withProtectedEntry" durableSource @?= 1
            SourceGuard.countHaskellIdentifier "readProtectedRecord" durableSource @?= 11
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
                        (seam `notElem` map (unwords . words) (lines cabalSource))
                )
                [ "HostBootstrap.Handoff.Acknowledgement.Testing"
                , "HostBootstrap.Handoff.Process.Testing"
                ]
    , testCase "protocol tags and one-outstanding-response state are closed, exact, redacted, and private" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            protocolSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Protocol.hs")
            receiverSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
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
                    "-- | Structural and transport failures."
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
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let tags = ["AcknowledgedTag", "LifecycleAckRequestTag", "LifecycleAckResponseTag"]
                rootedTags = ["RootedLifecycleRequestTag", "RootedLifecycleResponseTag"]
                kernels =
                    [ "publishLifecycleReportKernel"
                    , "receiveLifecycleAcknowledgementKernel"
                    , "prepareLifecycleAcknowledgementKernel"
                    , "adoptLifecycleAcknowledgementKernel"
                    ]
                users identifier =
                    sort
                        [ sourcePath sourceRoot path
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
                table = normalizeWhitespace tagTable
                exports = normalizedModuleExports handoffExports
                exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
                handoffAttribution =
                    significantHaskellLineCount durableSource
                        + length (filter (`elem` exports) kernels)
                        + length (filter (== "RecordKey") protectedImports)
                -- Protocol is shared across this phase, so what this sprint added
                -- to it is the file less everything its siblings own — the
                -- 392 lines standing before it and the 63 the frame-crossing
                -- vocabulary and its descriptor isolation added after it.
                protocolFrozenSignificantLines = 455
                protocolAttribution = significantHaskellLineCount protocolSource - protocolFrozenSignificantLines
            namedDeclarations
                @?= [ "data ProtocolTag"
                    , "data ProtocolMessage = ProtocolMessage ProtocolTag Word64 [ByteString]"
                    , "data HandoffChannel = HandoffChannel"
                    , "data ChildProtocolState"
                    , "data ProtocolError"
                    ]
            mapM_
                (\fragment -> assertContains (fragment <> " is one-field") (fragment <> " -> 1") fields)
                (tags <> rootedTags)
            assertFragmentsInOrder
                "new tag bytes append after the existing recovery response"
                [ "RecoveryResponseTag -> 14"
                , "AcknowledgedTag -> 15"
                , "LifecycleAckRequestTag -> 16"
                , "LifecycleAckResponseTag -> 17"
                , "RootedLifecycleRequestTag -> 18"
                , "RootedLifecycleResponseTag -> 19"
                , "14 -> Right RecoveryResponseTag"
                , "15 -> Right AcknowledgedTag"
                , "16 -> Right LifecycleAckRequestTag"
                , "17 -> Right LifecycleAckResponseTag"
                , "18 -> Right RootedLifecycleRequestTag"
                , "19 -> Right RootedLifecycleResponseTag"
                ]
                table
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
                state
            assertFragmentsInOrder
                "only the stored response tag and request id return an admitted child to running"
                [ "(ChildAwaitingResponse expected response, observed)"
                , "observed == response -> requireRequest expected requestId (ChildRunning expected)"
                , "(ChildAwaitingResponse expected _, RefusedTag)"
                , "requireRequest expected requestId ChildFinished"
                ]
                state
            assertFragmentsInOrder
                "Completed derives and retains the exact acknowledgement before awaiting it"
                [ "(ChildRunning expected, CompletedTag) -> do"
                , "requireRequest expected requestId ()"
                , "[report] -> case renderLifecycleAcknowledgement report of"
                , "Left _ -> Left ProtocolLifecycleReportInvalid"
                , "Right acknowledgement -> Right (ChildAwaitingAcknowledgement expected acknowledgement)"
                ]
                state
            assertFragmentsInOrder
                "only the exact direct acknowledgement and request identity finish the child"
                [ "(ChildAwaitingAcknowledgement expected acknowledgement, AcknowledgedTag)"
                , "requireAcknowledgement expected acknowledgement message"
                , "requireRequest expected (protocolMessageRequestId message) ()"
                , "[observed]"
                , "observed == acknowledgement -> Right ChildFinished"
                , "otherwise -> Left ProtocolAcknowledgementMismatch"
                ]
                state
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
                @?= [ "HostBootstrap/Handoff/Protocol.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            mapM_
                ( \tag ->
                    users tag
                        @?= [ "HostBootstrap/Handoff/Protocol.hs"
                            , "HostBootstrap/Handoff/Relay.hs"
                            ]
                )
                ["LifecycleAckRequestTag", "LifecycleAckResponseTag"]
            mapM_
                ( \tag ->
                    users tag
                        @?= [ "HostBootstrap/Handoff/Protocol.hs"
                            , "HostBootstrap/Handoff/Relay.hs"
                            ]
                )
                rootedTags
            mapM_
                ( \kernel ->
                    users kernel
                        @?= [ "HostBootstrap/Handoff.hs"
                            , "HostBootstrap/Handoff/Relay.hs"
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
                (tags <> rootedTags <> kernels)
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
                        (seam `notElem` map (unwords . words) (lines cabalSource))
                )
                [ "HostBootstrap.Handoff.Acknowledgement.Testing"
                , "HostBootstrap.Handoff.Protocol.Testing"
                , "HostBootstrap.Handoff.Process.Testing"
                ]
            significantHaskellLineCount protocolSource @?= 526
            (handoffAttribution, protocolAttribution, handoffAttribution + protocolAttribution)
                @?= (313, 71, 384)
    , testCase "Relay retains the frozen caller-free canonical routed-ack transport" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            protocolSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Protocol.hs")
            receiverSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
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
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let brokerLink = normalizeWhitespace brokerLinkSource
                linkConstruction = normalizeWhitespace linkConstructionSource
                publicRoute = normalizeWhitespace publicRouteSource
                routed = normalizeWhitespace routedSource
                rootRoute = normalizeWhitespace rootRouteSource
                relayedRoute = normalizeWhitespace relayedRouteSource
                requester = normalizeWhitespace requesterSource
                serveDispatch = normalizeWhitespace serveDispatchSource
                serveRoute = normalizeWhitespace serveRouteSource
                publicHandoff = normalizedModuleExports handoffExports
                privateRelay = normalizedModuleExports relayExports
                exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
                users identifier =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath sourceRoot path
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
                preRouteRelaySignificantLines :: Int
                preRouteRelaySignificantLines = 1099
                frozenRouteRelaySignificantLines :: Int
                frozenRouteRelaySignificantLines = 1463
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
                routed
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
                routed
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
                rootRoute
            SourceGuard.countHaskellIdentifier "prepareLifecycleAcknowledgementKernel" rootRouteSource @?= 1
            SourceGuard.countHaskellIdentifier "adoptLifecycleAcknowledgementKernel" rootRouteSource @?= 1
            assertFragmentsInOrder
                "the root link uses only rootBrokerRoute for lifecycle reconstruction"
                [ "linkLifecycleAcknowledgementRaw = \\_ request respond -> rootLifecycleAcknowledgement broker route request respond"
                , "route = rootBrokerRoute broker"
                ]
                linkConstruction
            assertFragmentsInOrder
                "a keyless link prefixes its authenticated current frame before relaying"
                [ "linkLifecycleAcknowledgementRaw = \\downstream lifecycleRequest -> relayLifecycleAcknowledgement route channel request (currentFrame : downstream) lifecycleRequest"
                , "currentFrame = handoffChildFrame (verifiedHandoffBinding (receivedEdgeHandoff edge))"
                ]
                linkConstruction
            assertFragmentsInOrder
                "a relayed response is validated against its exact request before either callback"
                [ "renderRequesterEnvelope path raw"
                , "transmit channel LifecycleAckRequestTag request [enveloped]"
                , "await channel request LifecycleAckResponseTag"
                , "Right [response]"
                , "withLifecycleAcknowledgementResponse stage report acknowledgement response"
                , "firstDisposition (respond response)"
                , "secondDisposition (respond response)"
                ]
                relayedRoute
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
                serveRoute
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
                requester
            users "prepareLifecycleAcknowledgementKernel"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            users "adoptLifecycleAcknowledgementKernel"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            mapM_
                (\identifier -> users identifier @?= ["HostBootstrap/Handoff/Relay.hs"])
                [ "prepareLifecycleAcknowledgementThroughLink"
                , "adoptLifecycleAcknowledgementThroughLink"
                , "linkLifecycleAcknowledgementRaw"
                , "rootLifecycleAcknowledgement"
                , "relayLifecycleAcknowledgement"
                , "serveLifecycleAcknowledgement"
                ]
            importers "HostBootstrap.Handoff.Relay" @?= ["HostBootstrap/Handoff/Process.hs"]
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
                        (seam `notElem` map (unwords . words) (lines cabalSource))
                )
                [ "HostBootstrap.Handoff.Relay.Testing"
                , "HostBootstrap.Handoff.Acknowledgement.Testing"
                , "HostBootstrap.Handoff.Process.Testing"
                ]
            SourceGuard.countHaskellIdentifier "prepareLifecycleAcknowledgementThroughLink" publicRouteSource @?= 2
            SourceGuard.countHaskellIdentifier "adoptLifecycleAcknowledgementThroughLink" publicRouteSource @?= 2
            SourceGuard.countHaskellIdentifier "linkLifecycleAcknowledgementRaw" relaySource @?= 5
            SourceGuard.countHaskellIdentifier "rootLifecycleAcknowledgement" relaySource @?= 3
            SourceGuard.countHaskellIdentifier "relayLifecycleAcknowledgement" relaySource @?= 3
            SourceGuard.countHaskellIdentifier "exactLifecycleFrames" relaySource @?= 4
            frozenRouteRelaySignificantLines - preRouteRelaySignificantLines @?= 364
    , testCase "Relay owns terminal persistence, complete serve, and sealed child receipt" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
            protocolSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Protocol.hs")
            receiverSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            childReceiptSource <-
                requiredSourceSection
                    "the sealed child receipt helpers"
                    "withReceivedLifecycleAcknowledgementKernel ::"
                    "{- | Ask this frame's route to sign one activation manifest."
                    relaySource
            recoveryReceiptSource <-
                requiredSourceSection
                    "the recovery receipt eliminator"
                    "withReceivedRecoveryLifecycleAcknowledgementKernel ::"
                    "receiveLifecycleAcknowledgementForEdge ::"
                    relaySource
            commonReceiptSource <-
                requiredSourceSection
                    "the common sealed-edge receipt path"
                    "receiveLifecycleAcknowledgementForEdge ::"
                    "lifecycleAcknowledgementUnavailable ::"
                    relaySource
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
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let childReceipt = normalizeWhitespace childReceiptSource
                recoveryReceipt = normalizeWhitespace recoveryReceiptSource
                commonReceipt = normalizeWhitespace commonReceiptSource
                ordinaryOffer = normalizeWhitespace ordinaryOfferSource
                reverseOffer = normalizeWhitespace reverseOfferSource
                fullServe = normalizeWhitespace fullServeSource
                terminal = normalizeWhitespace terminalSource
                failures = normalizeWhitespace failureSource
                publicHandoff = normalizedModuleExports handoffExports
                privateRelay = normalizedModuleExports relayExports
                exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
                users identifier =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath sourceRoot path
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
                frozenRouteRelaySignificantLines :: Int
                frozenRouteRelaySignificantLines = 1463
                frozenTerminalRelaySignificantLines :: Int
                frozenTerminalRelaySignificantLines = 1852
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
            assertContains
                "ordinary child receipt accepts one sealed edge, explicit store, report, and sender"
                "withReceivedLifecycleAcknowledgementKernel :: ReceivedEdge scope brokerGeneration -> ProtectedStore -> ByteString -> (ByteString -> IO (Either Text ())) -> IO (Either Text ())"
                childReceipt
            assertContains
                "recovery child receipt accepts only the sealed descent, explicit store, report, and sender"
                "withReceivedRecoveryLifecycleAcknowledgementKernel :: ReceivedRecoveryDescent scope brokerGeneration planDigest parentFrame childFrame recoveryWireDigest recoveryWireId verb -> ProtectedStore -> ByteString -> (ByteString -> IO (Either Text ())) -> IO (Either Text ())"
                childReceipt
            mapM_
                (\section -> SourceGuard.countHaskellIdentifier "result" section @?= 0)
                [ ordinaryOfferSource
                , reverseOfferSource
                , childReceiptSource
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
                ordinaryOffer
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
                reverseOffer
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
                fullServe
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
                terminal
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
                terminal
            assertFragmentsInOrder
                "persist requires the callback's same report and canonical acknowledgement before prepare"
                [ "observedReport /= report || observedAcknowledgement /= acknowledgement"
                , "prepareLifecycleAcknowledgementThroughLink link offer challenge report acknowledgement pending alreadyAdopted"
                , "readMVar gate"
                , "Just True -> Right ()"
                , "Just False -> fixedReplay"
                ]
                terminal
            assertContains
                "pending sends the acknowledgement before conditional adoption"
                "pending storedAcknowledgement = sendAcknowledgement storedAcknowledgement $ do adopted <- adoptLifecycleAcknowledgementThroughLink link offer challenge report acknowledgement (recordDisposition True) (recordDisposition False)"
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
                terminal
            assertFragmentsInOrder
                "Fresh alone permits terminal callback success while replay and already-Adopted are acknowledgement-only"
                [ "recordDisposition fresh = do"
                , "Just fresh"
                , "(Right _, Just False) -> pure (Right ())"
                , "(Right (Right ()), Just True) -> pure (Right ())"
                ]
                terminal
            assertContains
                "post-attempt failure is local and only a pre-ack failure refuses"
                "fixedResult attempted = if attempted then pure (Left RelayLifecycleFailure) else refuse channel request RelayLifecycleFailure"
                terminal
            assertFragmentsInOrder
                "callback exceptions are classified before an async exit is rethrown"
                [ "callbackResult <- try (restore"
                , "terminalResult <- terminal report persist"
                , "Left reason -> pure (Left reason)"
                , "Right value -> evaluate value >> pure (Right ())"
                , "closeException <- closeGate Nothing"
                , "acknowledgementAttempted, disposition"
                , "classified <- case (callbackResult, disposition) of"
                , "deferredAsync callbackResult closeException"
                , "Just failure -> throwIO failure"
                ]
                terminal
            assertFragmentsInOrder
                "terminal report canonicality and binding precede acknowledgement derivation"
                [ "binding <- lifecycleReportBinding report"
                , "binding == renderHandoffBinding (handoffOfferBinding offer)"
                , "fromHandoff (renderLifecycleAcknowledgement report)"
                ]
                terminal
            assertContains
                "only asynchronous callback exceptions are deferred for rethrow"
                "fromException failure :: Maybe SomeAsyncException"
                terminal
            SourceGuard.countHaskellIdentifier "reason" terminalSource @?= 2
            SourceGuard.countHaskellIdentifier "refuse" terminalSource @?= 2
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier terminalSource @?= 0)
                [ "isInfixOf"
                , "relayErrorMessage"
                , "TextEncoding"
                , "Text.unpack"
                ]
            assertFragmentsInOrder
                "the child checks binding, publishes, sends the same report once, and records only exact receipt"
                [ "case lifecycleReportBinding report of"
                , "binding == renderHandoffBinding (verifiedHandoffBinding (receivedEdgeHandoff edge))"
                , "published <- publishLifecycleReportKernel recoverySigningKernel store report"
                , "sent <- sender report"
                , "received <- receiveAcknowledgement"
                , "receiveLifecycleAcknowledgementKernel recoverySigningKernel store report acknowledgement"
                , "Right () -> pure (Right ())"
                ]
                commonReceipt
            assertFragmentsInOrder
                "direct child receipt accepts only the exact request, tag, singleton acknowledgement, and report commitment"
                [ "incoming <- channelReceive (receivedEdgeChannel edge)"
                , "protocolMessageRequestId message == receivedEdgeRequestId edge"
                , "protocolMessageTag message == AcknowledgedTag"
                , "[acknowledgement]"
                , "verifyLifecycleAcknowledgement report acknowledgement"
                , "Right acknowledgement"
                ]
                commonReceipt
            assertFragmentsInOrder
                "the recovery helper only eliminates its sealed package into the common edge path"
                [ "withReceivedRecoveryDescent descent"
                , "receiveLifecycleAcknowledgementForEdge edge store report sender"
                ]
                recoveryReceipt
            SourceGuard.countHaskellTokenSequence ["sender", "report"] commonReceiptSource @?= 1
            SourceGuard.countHaskellIdentifier "channelReceive" commonReceiptSource @?= 1
            SourceGuard.countHaskellIdentifier "publishLifecycleReportKernel" commonReceiptSource @?= 1
            SourceGuard.countHaskellIdentifier "receiveLifecycleAcknowledgementKernel" commonReceiptSource @?= 1
            mapM_
                (\identifier -> SourceGuard.countHaskellIdentifier identifier commonReceiptSource @?= 0)
                [ "await"
                , "refuse"
                , "transmit"
                , "channelSend"
                ]
            assertContains
                "Relay lifecycle failures carry no hostile text"
                "RelayLifecycleFailure -> \"handoff relay: lifecycle acknowledgement failed\""
                failures
            SourceGuard.countHaskellTokenSequence ["RelayLifecycleFailure", "Text"] failureSource @?= 0
            SourceGuard.countHaskellTokenSequence ["RelayLifecycleFailure", "String"] failureSource @?= 0
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
                        @?= [ "HostBootstrap/Handoff/Process.hs"
                            , "HostBootstrap/Handoff/Relay.hs"
                            ]
                )
                [ "offerHandoffEdge"
                , "offerReverseDescentKernel"
                ]
            mapM_
                (\identifier -> users identifier @?= ["HostBootstrap/Handoff/Relay.hs"])
                [ "prepareLifecycleAcknowledgementThroughLink"
                , "adoptLifecycleAcknowledgementThroughLink"
                , "withReceivedLifecycleAcknowledgementKernel"
                , "withReceivedRecoveryLifecycleAcknowledgementKernel"
                , "runLifecycleTerminal"
                , "receiveLifecycleAcknowledgementForEdge"
                ]
            importers "HostBootstrap.Handoff.Relay" @?= ["HostBootstrap/Handoff/Process.hs"]
            mapM_
                ( \identifier -> do
                    assertBool (identifier <> " is exported only from hidden Relay") (identifier `elem` privateRelay)
                    assertBool (identifier <> " is absent from public Handoff") (identifier `notElem` publicHandoff)
                )
                [ "BrokerLink"
                , "offerHandoffEdge"
                , "offerReverseDescentKernel"
                , "withReceivedLifecycleAcknowledgementKernel"
                , "withReceivedRecoveryLifecycleAcknowledgementKernel"
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
                        (seam `notElem` map (unwords . words) (lines cabalSource))
                )
                [ "HostBootstrap.Handoff.Relay.Testing"
                , "HostBootstrap.Handoff.Acknowledgement.Testing"
                , "HostBootstrap.Handoff.Process.Testing"
                ]
            SourceGuard.countHaskellIdentifier "prepareLifecycleAcknowledgementThroughLink" relaySource @?= 4
            SourceGuard.countHaskellIdentifier "adoptLifecycleAcknowledgementThroughLink" relaySource @?= 4
            SourceGuard.countHaskellIdentifier "publishLifecycleReportKernel" relaySource @?= 3
            SourceGuard.countHaskellIdentifier "receiveLifecycleAcknowledgementKernel" relaySource @?= 3
            SourceGuard.countHaskellIdentifier "withReceivedLifecycleAcknowledgementKernel" relaySource @?= 3
            SourceGuard.countHaskellIdentifier "withReceivedRecoveryLifecycleAcknowledgementKernel" relaySource @?= 3
            SourceGuard.countHaskellIdentifier "receiveLifecycleAcknowledgementForEdge" relaySource @?= 4
            SourceGuard.countHaskellIdentifier "runLifecycleTerminal" relaySource @?= 3
            SourceGuard.countHaskellIdentifier "AcknowledgedTag" relaySource @?= 3
            SourceGuard.countHaskellIdentifier "RelayLifecycleFailure" terminalSource @?= 6
            (frozenTerminalRelaySignificantLines, frozenTerminalRelaySignificantLines - frozenRouteRelaySignificantLines)
                @?= (1852, 389)
    ]

-- ---------------------------------------------------------------------------
-- Sealed facade and private signing ownership

sealedFacadeTests :: [TestTree]
sealedFacadeTests =
    [ testCase "Cabal exposes only the handoff facade and no private runtime test seam" $
        withHandoffSourceRoot $ \packageRoot _sourceRoot -> do
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            specSource <- readFile (packageRoot </> "test" </> "Spec.hs")
            testSources <- readHaskellSources (packageRoot </> "test")
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
                hiddenHandoffModules =
                    [ "HostBootstrap.Handoff.Completion"
                    , "HostBootstrap.Handoff.Internal"
                    , "HostBootstrap.Handoff.Lifecycle"
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
            filter ("HostBootstrap.Handoff" `isPrefixOf`) exposed
                @?= ["HostBootstrap.Handoff", "HostBootstrap.Handoff.Transaction"]
            traverse_
                (\moduleName -> assertBool (moduleName <> " is hidden") (moduleName `notElem` exposed))
                hiddenHandoffModules
            traverse_
                (\moduleName -> assertBool (moduleName <> " is registered privately") (moduleName `elem` private))
                hiddenHandoffModules
            traverse_
                (\moduleName -> runtimeTestImporters moduleName @?= [])
                hiddenHandoffModules
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
    , testCase "rooted payload ownership is neutral, nominal, hidden, acyclic, and exactly attributed" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            rootedSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Rooted.hs")
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
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let rooted = normalizeWhitespace rootedSource
                facade = normalizeWhitespace rootedFacade
                exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
                publicHandoff = normalizedModuleExports handoffExports
                importers moduleName =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                users identifier =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                rootedFacadeAttribution = significantHaskellLineCount rootedFacade
                handoffAttribution = rootedFacadeAttribution + 11
                frozenRootedPayloadHeaderAttribution = 22
                rootedPayloadAttribution = significantHaskellLineCount rootedPayloadSource
                rootedAttribution = frozenRootedPayloadHeaderAttribution + rootedPayloadAttribution
            normalizedModuleExports rootedExports
                @?= [ "RootedPayloadBinding"
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
                "data RootedPayloadBinding scope brokerGeneration = RootedPayloadBinding ByteString Text Text ByteString type role RootedPayloadBinding nominal nominal"
                rooted
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
                , "rootedFrame (TextEncoding.encodeUtf8 payloadDigest)"
                , "rootedFrame (TextEncoding.encodeUtf8 childConfigDigest)"
                ]
                rooted
            assertFragmentsInOrder
                "the complete rooted decoder consumes exactly six canonical fields"
                [ "fromIntegral (ByteString.length raw) <= rootedFieldLimit"
                , "is larger than the bounded authentication field"
                , "(domain, afterDomain) <- takeRootedFrame raw"
                , "(version, afterVersion) <- takeRootedFrame afterDomain"
                , "(edge, afterEdge) <- takeRootedFrame afterVersion"
                , "(payloadBytes, afterPayload) <- takeRootedFrame afterEdge"
                , "(configBytes, afterConfig) <- takeRootedFrame afterPayload"
                , "(signature, trailing) <- takeRootedFrame afterConfig"
                , "require (ByteString.null trailing) \"has trailing bytes\""
                , "require (domain == rootedPayloadDomain) \"has the wrong domain\""
                , "require (version == rootedPayloadVersion) \"has the wrong version\""
                , "require (renderRootedPayloadBindingKernel binding == raw) \"is not canonical\""
                ]
                rooted
            assertFragmentsInOrder
                "construction bounds the edge and complete authentication field before rendering"
                [ "not (ByteString.null edge)"
                , "fromIntegral (ByteString.length edge) <= rootedFieldLimit"
                , "has an oversized edge binding"
                , "let unsigned = renderRootedPayloadUnsignedParts edge payloadDigest childConfigDigest"
                , "ByteString.length unsigned + 8 + rootedPayloadSignatureBytes"
                , "<= rootedFieldLimit"
                , "is larger than the bounded authentication field"
                ]
                rooted
            assertFragmentsInOrder
                "the shared frame reader refuses oversized declarations before splitting a body"
                [ "ByteString.length raw < 8"
                , "declared > rootedFieldLimit"
                , "contains an oversized field"
                , "ByteString.splitAt (fromIntegral declared) body"
                ]
                rooted
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
                facade
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
                facade
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
                facade
            assertFragmentsInOrder
                "the rooted signature has one facade-owned domain and installed-key digest"
                [ "rootedPayloadBindingDomain = \"hostbootstrap/rooted-payload-binding/v1\""
                , "rootedPayloadSignedMaterial key unsigned = frameWire rootedPayloadBindingDomain"
                , "frameWire (TextEncoding.encodeUtf8 (verificationKeyDigest key))"
                , "frameWire unsigned"
                ]
                facade
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
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Internal.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "HostBootstrap/Lifecycle/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Node.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    ]
            users "RootedPayloadBinding"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Rooted.hs"
                    ]
            users "signRootedPayloadBindingKernel"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Relay.hs"]
            users "withVerifiedRootedPayloadBinding"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Receiver.hs"]
            assertBool
                "the facade alone owns rooted cryptography"
                ( SourceGuard.importsModule "HostBootstrap.Handoff.Rooted" handoffSource
                    && SourceGuard.countHaskellIdentifier "Ed25519" rootedSource == 0
                )
            length (filter (== "HostBootstrap.Handoff.Rooted") private) @?= 1
            assertBool
                "the rooted codec remains hidden from every exposed library surface"
                ("HostBootstrap.Handoff.Rooted" `notElem` exposed)
            assertBool
                "HandoffSpec tests the facade without importing the hidden codec"
                (not (SourceGuard.importsModule "HostBootstrap.Handoff.Rooted" handoffSpecSource))
            traverse_
                ( \seam ->
                    assertBool
                        (seam <> " is absent from Cabal")
                        (not (seam `isInfixOf` cabalSource))
                )
                [ "HostBootstrap.Handoff.Rooted.Testing"
                , "HostBootstrap.Handoff.Rooted.Internal"
                ]
            rootedFacadeAttribution @?= 129
            rootedPayloadAttribution @?= 147
            rootedAttribution @?= 169
            (handoffAttribution, rootedAttribution, handoffAttribution + rootedAttribution)
                @?= (140, 169, 309)
    , testCase "rooted lifecycle requests have one opaque closed six-variant shape and fold" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            rootedSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Rooted.hs")
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
                rooted
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
                rooted
            SourceGuard.countHaskellIdentifier "withRootedLifecycleRequestKernel" rootedSource @?= 3
    , testCase "rooted lifecycle request framing is exact, bounded, canonical, and variant-closed" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            rootedSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Rooted.hs")
            let rooted = normalizeWhitespace rootedSource
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
                rooted
            assertFragmentsInOrder
                "body-bearing construction checks the common admission before its opaque body and complete bound"
                [ "rootedPostOpenBodyRequest makeRequest path session stage ordinal nonce predecessor body = do"
                , "requireLifecyclePostOpen path session stage ordinal nonce predecessor"
                , "not (ByteString.null body)"
                , "ByteString.length body <= rootedLifecycleBodyLimit"
                , "boundedLifecycleRequest (makeRequest path session stage ordinal nonce predecessor body)"
                ]
                rooted
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
                rooted
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
                , "is not a canonical rooted lifecycle request"
                ]
                rooted
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
                rooted
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
                rooted
            assertFragmentsInOrder
                "raw text and predecessor fields are bounded before UTF-8 or digest decoding"
                [ "decodeLifecycleText label raw = do require (not (ByteString.null raw))"
                , "ByteString.length raw <= rootedLifecycleTextLimit"
                , "TextEncoding.decodeUtf8' raw"
                , "decodeLifecyclePredecessor raw = do require (ByteString.length raw == 64)"
                , "decodeDigest \"predecessor response\" raw"
                ]
                rooted
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
                rooted
            SourceGuard.countHaskellIdentifier "lifecycleRequestWire" rootedSource @?= 4
            SourceGuard.countHaskellIdentifier "decodeLifecycleVariant" rootedSource @?= 10
            SourceGuard.countHaskellIdentifier "rootedLifecycleRequestFromWireKernel" rootedSource @?= 3
    , testCase "rooted lifecycle request ownership is neutral, single-owner, budgeted, and freezes shared surfaces" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            (handoffSource, handoffDigest) <-
                readFrozenSource (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            rootedSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Rooted.hs")
            (protocolSource, protocolDigest) <-
                readFrozenSource (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Protocol.hs")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            cabalRows <- handoffPackageRows cabalSource
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
                importers moduleName =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                users identifier =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                frozenRootedPayloadLines :: Int
                frozenRootedPayloadLines = 169
                frozenRootedRequestLines :: Int
                frozenRootedRequestLines = 504
                frozenRootedRequestDigest :: String
                frozenRootedRequestDigest = "45ca89f24b43cbf4b02e2d82186e8c33db5e2aaedb6978d2111e039ae6933281"
                rootedRequestDelta :: Int
                rootedRequestDelta = frozenRootedRequestLines - frozenRootedPayloadLines
            importers "HostBootstrap.Handoff.Rooted"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Internal.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "HostBootstrap/Lifecycle/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Node.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    ]
            users "RootedLifecycleRequest"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Rooted.hs"
                    ]
            users "rootedLifecycleRequestFromWireKernel"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Node.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    ]
            users "withRootedLifecycleRequestKernel"
                @?= [ "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Node.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
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
            (frozenRootedRequestLines, rootedRequestDelta) @?= (504, 335)
            assertBool "the historical request attribution remains within the 340-line sprint budget" (rootedRequestDelta <= 340)
            frozenRootedRequestDigest @?= "45ca89f24b43cbf4b02e2d82186e8c33db5e2aaedb6978d2111e039ae6933281"
            significantHaskellLineCount protocolSource @?= 526
            protocolDigest @?= "04f069429b164e3d6b99ff68b900996c090e73947bc5c874859049ce49a696a4"
            handoffDigest @?= "6bbbd828b453173cf8f4be9cd1989eb0a6ddfc2cc5a9639b29d76558c0121fe5"
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
                (normalizeWhitespace protocolSource)
    , testCase "rooted lifecycle responses have one opaque seven-variant shape, seven unsigned builders, and one signature-attaching fold" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            rootedSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Rooted.hs")
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
                , "rootedPreparedResponseUnsignedKernel :: Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> Either Text ByteString"
                , "rootedPreparedResponseUnsignedKernel digest path session stage ordinal nonce node dependencies operationGate projectedGates = do"
                , "requireResponsePostOpen digest path session stage ordinal nonce"
                , "body <- preparedResponseBody node dependencies operationGate projectedGates"
                , "boundedResponseUnsigned (responsePostOpenWire \"prepared\" digest path session stage ordinal nonce body)"
                , "rootedDescendResponseUnsignedKernel :: Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> Either Text ByteString"
                , "rootedDescendResponseUnsignedKernel = opaqueResponseUnsigned \"descend\""
                , "rootedSettledResponseUnsignedKernel = opaqueResponseUnsigned \"settled\""
                , "rootedFrameCompleteResponseUnsignedKernel = opaqueResponseUnsigned \"frame-complete\""
                , "rootedReceiptRecordedResponseUnsignedKernel :: Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> Text -> Either Text ByteString"
                , "rootedReceiptRecordedResponseUnsignedKernel digest path session stage ordinal nonce completionDigest = do"
                , "rootedRefusedResponseUnsignedKernel :: Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> Text -> Either Text ByteString"
                , "rootedRefusedResponseUnsignedKernel digest path session stage ordinal nonce detail = do"
                ]
                rooted
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
                rooted
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
                rooted
            SourceGuard.countHaskellIdentifier "rootedLifecycleResponseFromUnsignedKernel" rootedSource @?= 4
            SourceGuard.countHaskellIdentifier "withRootedLifecycleResponseKernel" rootedSource @?= 5
    , testCase "rooted lifecycle response framing is exact nine-or-eleven-field, bounded, canonical, and prepared-body closed" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            rootedSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Rooted.hs")
            let rooted = normalizeWhitespace rootedSource
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
                rooted
            assertFragmentsInOrder
                "rendering fixes domain, version, discriminator, request digest, root-nearest path, successor coordinates, nonce, body, then signature"
                [ "responseCommon digest path session stage ordinal = [ TextEncoding.encodeUtf8 digest , renderLifecyclePath path , TextEncoding.encodeUtf8 session , TextEncoding.encodeUtf8 stage , ByteString.pack (word64BigEndian ordinal) ]"
                , "responseWire variant fields = ByteString.concat (map rootedFrame ([rootedLifecycleResponseDomain, rootedLifecycleVersion, variant] ++ fields))"
                , "responsePostOpenWire variant digest path session stage ordinal nonce body = responseWire variant (responseCommon digest path session stage ordinal ++ [nonce, body])"
                , "ByteString.length wire + 8 + rootedLifecycleResponseSignatureBytes <= rootedLifecycleWireLimit"
                , "renderRootedLifecycleResponseKernel response = renderRootedLifecycleUnsignedResponseKernel response <> rootedFrame (rootedLifecycleResponseSignatureKernel response)"
                ]
                rooted
            assertFragmentsInOrder
                "signed decoding admits at most eleven fields, detaches only the last signature, and requires exact canonical rerendering"
                [ "rootedLifecycleResponseFromWireKernel raw = do"
                , "ByteString.length raw <= rootedLifecycleWireLimit"
                , "frames <- collect 11 takeLifecycleFrame \"has more than eleven rooted lifecycle response fields\" raw"
                , "case reverse frames of signature : reversedUnsigned"
                , "let unsigned = ByteString.concat (map rootedFrame (reverse reversedUnsigned))"
                , "rootedLifecycleResponseFromUnsignedKernel unsigned signature"
                , "renderRootedLifecycleResponseKernel response == raw"
                , "is not a canonical rooted lifecycle response"
                , "_ -> Left \"has no rooted lifecycle response signature\""
                ]
                rooted
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
                , "(\"descend\", postFields) -> decodeOpaqueResponse raw rootedDescendResponseUnsignedKernel onDescend postFields"
                , "(\"settled\", postFields) -> decodeOpaqueResponse raw rootedSettledResponseUnsignedKernel onSettled postFields"
                , "(\"frame-complete\", postFields) -> decodeOpaqueResponse raw rootedFrameCompleteResponseUnsignedKernel onComplete postFields"
                , "(\"receipt-recorded\", postFields)"
                , "rootedReceiptRecordedResponseUnsignedKernel digest path session stage ordinal nonce completion"
                , "(\"refused\", postFields)"
                , "rootedRefusedResponseUnsignedKernel digest path session stage ordinal nonce detail"
                , "_ -> Left \"has an unknown rooted lifecycle response variant or field count\""
                , "decodeResponsePost [digestRaw, pathRaw, sessionRaw, stageRaw, ordinalRaw, nonce, body] = do"
                , "decodeResponsePost _ = Left \"post-open rooted lifecycle response has the wrong field count\""
                ]
                rooted
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
                , "has fewer than four prepared response fields"
                , "mapM_ requireResponseBody fields"
                ]
                rooted
            assertFragmentsInOrder
                "receipt and refusal bodies retain exact lowercase-digest and bounded UTF-8 grammars while the other bodies remain non-empty opaque bytes"
                [ "requireDigest \"completed response\" completionDigest"
                , "responsePostOpenWire \"receipt-recorded\" digest path session stage ordinal nonce (TextEncoding.encodeUtf8 completionDigest)"
                , "requireLifecycleText \"refusal detail\" detail"
                , "responsePostOpenWire \"refused\" digest path session stage ordinal nonce (TextEncoding.encodeUtf8 detail)"
                , "opaqueResponseUnsigned variant digest path session stage ordinal nonce body = do"
                , "requireResponseBody body"
                ]
                rooted
            SourceGuard.countHaskellIdentifier "decodeUnsignedResponse" rootedSource @?= 3
            SourceGuard.countHaskellIdentifier "decodePreparedResponseBody" rootedSource @?= 3
            SourceGuard.countHaskellIdentifier "rootedLifecycleResponseFromWireKernel" rootedSource @?= 3
    , testCase "rooted lifecycle response pairing is exact, neutral, single-owner, budgeted, and freezes shared surfaces" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            (handoffSource, handoffDigest) <-
                readFrozenSource (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            (handoffInternalSource, handoffInternalDigest) <-
                readFrozenSource (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Internal.hs")
            (rootedSource, rootedDigest) <-
                readFrozenSource (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Rooted.hs")
            (protocolSource, protocolDigest) <-
                readFrozenSource (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Protocol.hs")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            cabalRows <- handoffPackageRows cabalSource
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let rooted = normalizeWhitespace rootedSource
                exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
                importers moduleName =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                users identifier =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                frozenRootedRequestLines :: Int
                frozenRootedRequestLines = 504
                frozenRootedRequestDigest :: String
                frozenRootedRequestDigest = "45ca89f24b43cbf4b02e2d82186e8c33db5e2aaedb6978d2111e039ae6933281"
                rootedLines = significantHaskellLineCount rootedSource
                responseDelta :: Int
                responseDelta = rootedLines - frozenRootedRequestLines
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
                , "does not echo the rooted lifecycle request coordinates"
                , "(Just actual, Just wanted) -> require (actual == wanted) \"does not name the confirmed frame-complete response\""
                , "(Just _, Nothing) -> Left \"receipt-recorded does not answer a receipt confirmation\""
                , "pure report"
                ]
                rooted
            importers "HostBootstrap.Handoff.Rooted"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Internal.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "HostBootstrap/Lifecycle/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Node.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    ]
            users "RootedLifecycleResponse"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Internal.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Handoff/Rooted.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
                    ]
            mapM_
                ( \identifier ->
                    users identifier
                        @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Rooted.hs"]
                )
                [ "rootedLifecycleResponseFromUnsignedKernel"
                , "rootedLifecycleUnsignedResponsePairKernel"
                ]
            mapM_
                ( \identifier ->
                    users identifier
                        @?= [ "HostBootstrap/Handoff.hs"
                            , "HostBootstrap/Handoff/Receiver/Internal.hs"
                            , "HostBootstrap/Handoff/Rooted.hs"
                            ]
                )
                ["rootedLifecycleResponsePairKernel"]
            users "rootedLifecycleResponseFromWireKernel"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Node.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    ]
            users "withRootedLifecycleResponseKernel"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Rooted.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Node.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
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
            (SourceGuard.countHaskellIdentifier "data" rootedSource, SourceGuard.countHaskellIdentifier "newtype" rootedSource)
                @?= (3, 0)
            (frozenRootedRequestLines, frozenRootedRequestDigest)
                @?= (504, "45ca89f24b43cbf4b02e2d82186e8c33db5e2aaedb6978d2111e039ae6933281")
            (rootedLines, responseDelta) @?= (754, 250)
            assertBool "the sole production owner remains within the 280-line response sprint budget" (responseDelta <= 280)
            rootedDigest @?= "c035f05ec6c0951165d9141c8d6fccd1ce45b00266f88e5d9753dbbdf618460e"
            handoffDigest @?= "6bbbd828b453173cf8f4be9cd1989eb0a6ddfc2cc5a9639b29d76558c0121fe5"
            handoffInternalDigest @?= "305dc09a9e9ae617161f0b7ec35309aeb31d0152894988a8bc53f415cebca2bf"
            significantHaskellLineCount protocolSource @?= 526
            protocolDigest @?= "04f069429b164e3d6b99ff68b900996c090e73947bc5c874859049ce49a696a4"
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
                        "next-node" path session requestStage 1 nonce predecessor Nothing
                settleRequest =
                    rootedLifecyclePostRequest
                        "settle-node" path session requestStage 2 nonce predecessor (Just "settlement")
                descendResultRequest =
                    rootedLifecyclePostRequest
                        "descend-result" path session requestStage 3 nonce predecessor (Just "observation")
                closeRequest =
                    rootedLifecyclePostRequest
                        "close-frame" path session requestStage 4 nonce predecessor Nothing
                receiptRequest =
                    rootedLifecyclePostRequest
                        "receipt-confirm" path session requestStage 5 nonce completion Nothing
                preparedBody =
                    renderFrameFields
                        [ "node-package"
                        , "dependency-package"
                        , "operation-gate-package"
                        , "projected-gates-package"
                        ]
                cases =
                    [ ( "opened"
                      , openRequest
                      , rootedLifecycleOpenedUnsigned
                            openRequest path session responseStage 1
                      , 9
                      )
                    , ( "prepared"
                      , nextRequest
                      , rootedLifecyclePostUnsigned
                            "prepared" nextRequest path session responseStage 2 nonce preparedBody
                      , 11
                      )
                    , ( "descend"
                      , nextRequest
                      , rootedLifecyclePostUnsigned
                            "descend" nextRequest path session responseStage 3 nonce "descent-package"
                      , 11
                      )
                    , ( "settled"
                      , settleRequest
                      , rootedLifecyclePostUnsigned
                            "settled" settleRequest path session responseStage 4 nonce "settled-package"
                      , 11
                      )
                    , ( "frame-complete"
                      , closeRequest
                      , rootedLifecyclePostUnsigned
                            "frame-complete" closeRequest path session responseStage 5 nonce report
                      , 11
                      )
                    , ( "receipt-recorded"
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
                    , ( "refused"
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
                fields <- framesOf signed
                assertBool (label <> " retains its exact signed field count") (length fields == fieldCount)
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
                        "next-node" path session requestStage 1 nonce predecessor Nothing
                settleRequest =
                    rootedLifecyclePostRequest
                        "settle-node" path session requestStage 2 nonce predecessor (Just "settlement")
                closeRequest =
                    rootedLifecyclePostRequest
                        "close-frame" path session requestStage 3 nonce predecessor Nothing
                receiptRequest =
                    rootedLifecyclePostRequest
                        "receipt-confirm" path session requestStage 4 nonce completion Nothing
                preparedBody =
                    renderFrameFields ["node", "dependencies", "operation-gate", "projected-gates"]
                canonicalUnsigned =
                    rootedLifecyclePostUnsigned
                        "frame-complete" closeRequest path session responseStage 4 nonce report
                verifyWith installedKey exactRequest signed =
                    withVerifiedRootedLifecycleResponse
                        installedKey
                        exactRequest
                        signed
                        (const ())
                assertRefused label outcome = case outcome of
                    Left _ -> pure ()
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
                        "close-frame" path session requestStage 3 otherNonce predecessor Nothing
            traverse_
                (uncurry assertRefused)
                [ ("empty signed response", verifyWith key closeRequest ByteString.empty)
                , ("truncated signed response", verifyWith key closeRequest (ByteString.init canonical))
                , ("trailing response frame", verifyWith key closeRequest (canonical <> frameWire "trailing"))
                , ("short response signature", verifyWith key closeRequest shortSignature)
                , ("malformed exact request", verifyWith key malformedRequest canonical)
                , ("cross-request replay", verifyWith key crossRequest canonical)
                ]

            let malformedUnsigneds =
                    [ wireWithFrames
                        [(0, "hostbootstrap/rooted-lifecycle-response/not-v1")]
                        (take 10 canonicalFields)
                    , wireWithFrames [(1, lifecycleWordBytesFor 2)] (take 10 canonicalFields)
                    , wireWithFrames [(2, "unknown-response")] (take 10 canonicalFields)
                    , rootedLifecyclePostUnsigned
                        "prepared"
                        nextRequest
                        path
                        session
                        responseStage
                        2
                        nonce
                        (renderFrameFields ["node", "dependencies", "operation-gate"])
                    , rootedLifecyclePostUnsigned
                        "refused" nextRequest path session responseStage 2 nonce ByteString.empty
                    ]
            malformedWires <-
                traverse
                    ( rootedLifecycleResponseOracleWire
                        93
                        canonicalRootedLifecycleResponseSigningDomain
                        key
                        closeRequest
                    )
                    malformedUnsigneds
            traverse_
                (assertRefused "malformed canonical response" . verifyWith key closeRequest)
                malformedWires

            let familyCrossPairs =
                    [ ( nextRequest
                      , rootedLifecycleOpenedUnsigned
                            nextRequest path session responseStage 2
                      )
                    , ( closeRequest
                      , rootedLifecyclePostUnsigned
                            "prepared" closeRequest path session responseStage 4 nonce preparedBody
                      )
                    , ( settleRequest
                      , rootedLifecyclePostUnsigned
                            "descend" settleRequest path session responseStage 3 nonce "descent"
                      )
                    , ( nextRequest
                      , rootedLifecyclePostUnsigned
                            "settled" nextRequest path session responseStage 2 nonce "settled"
                      )
                    , ( receiptRequest
                      , rootedLifecyclePostUnsigned
                            "frame-complete" receiptRequest path session responseStage 5 nonce report
                      )
                    , ( closeRequest
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
                    , ( openRequest
                      , rootedLifecyclePostUnsigned
                            "refused" openRequest path session responseStage 1 nonce "refused"
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
            traverse_
                (\(request, signed) -> assertRefused "cross-family response" (verifyWith key request signed))
                familyCrossWires

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
                (verifyWith key receiptRequest wrongReceipt)
            assertRefused
                "cryptographically valid malformed lifecycle report"
                (verifyWith key closeRequest invalidReport)
    , testCase "rooted lifecycle response authentication is capability-specialized, ordered, acyclic, and exactly budgeted" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            internalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Internal.hs")
            rootedSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Rooted.hs")
            protocolSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Protocol.hs")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            responseFacade <-
                requiredSourceSection
                    "rooted lifecycle response facade"
                    "-- Rooted lifecycle response authentication"
                    "-- Recovery-wire signing"
                    handoffSource
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
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let facade = normalizeWhitespace responseFacade
                internal = normalizeWhitespace internalSource
                publicHandoff = normalizedModuleExports handoffExports
                privateInternal = normalizedModuleExports internalExports
                exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
                users identifier =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                handoffBaselineLines :: Int
                handoffBaselineLines = 2967
                internalBaselineLines :: Int
                internalBaselineLines = 12
                handoffLines = significantHaskellLineCount handoffSource
                internalLines = significantHaskellLineCount internalSource
                rootedLines = significantHaskellLineCount rootedSource
                sprintDelta =
                    handoffLines - handoffBaselineLines
                        + internalLines
                        - internalBaselineLines
                digest = childConfigDigest . TextEncoding.encodeUtf8 . Text.pack
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
                facade
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
                facade
            assertFragmentsInOrder
                "the exact transcript fixes domain, installed key digest, complete request, then canonical unsigned response"
                [ "rootedLifecycleResponseSigningDomain = \"hostbootstrap/rooted-lifecycle-response/v1\""
                , "rootedLifecycleResponseSignedMaterial key exactRequest unsigned = ByteString.concat"
                , "frameWire rootedLifecycleResponseSigningDomain"
                , "frameWire (TextEncoding.encodeUtf8 (verificationKeyDigest key))"
                , "frameWire exactRequest"
                , "frameWire unsigned"
                ]
                facade
            assertFragmentsInOrder
                "the verifier validates only FrameComplete's optional report after cryptography"
                [ "verifyRootedLifecycleResponseSignature key exactRequest response"
                , "validateRootedLifecycleResponseReport report"
                , "validateRootedLifecycleResponseReport Nothing = Right ()"
                , "validateRootedLifecycleResponseReport (Just report) = validateLifecycleReport report"
                ]
                facade
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
                internal
            assertBool
                "Internal exports the specialization but neither another capability nor any constructor"
                ( "consumeRootedLifecycleResponseSigningKernel" `elem` privateInternal
                    && "RecoverySigningKernel" `elem` privateInternal
                    && "RecoverySigningKernel(..)" `notElem` privateInternal
                    && SourceGuard.countHaskellTokenSequence ["data", "RecoverySigningKernel"] internalSource == 1
                    && SourceGuard.countHaskellIdentifier "newtype" internalSource == 0
                )
            importers "HostBootstrap.Handoff.Rooted"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Internal.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "HostBootstrap/Lifecycle/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Node.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    ]
            importers "HostBootstrap.Handoff.Internal"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Completion.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Teardown/Internal.hs"
                    ]
            users "RootedLifecycleResponse"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Internal.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Handoff/Rooted.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
                    ]
            users "consumeRootedLifecycleResponseSigningKernel"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Internal.hs"]
            users "signRootedLifecycleResponseKernel"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Relay.hs"]
            users "withVerifiedRootedLifecycleResponse"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
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
            (handoffLines, internalLines, rootedLines) @?= (3093, 25, 754)
            (handoffLines - handoffBaselineLines, internalLines - internalBaselineLines, sprintDelta)
                @?= (126, 13, 139)
            assertBool "the three-owner response authentication increment is within its 180-line budget" (sprintDelta <= 180)
            digest handoffSource @?= "6bbbd828b453173cf8f4be9cd1989eb0a6ddfc2cc5a9639b29d76558c0121fe5"
            digest internalSource @?= "305dc09a9e9ae617161f0b7ec35309aeb31d0152894988a8bc53f415cebca2bf"
            digest rootedSource @?= "c035f05ec6c0951165d9141c8d6fccd1ce45b00266f88e5d9753dbbdf618460e"
            significantHaskellLineCount protocolSource @?= 526
            digest protocolSource @?= "04f069429b164e3d6b99ff68b900996c090e73947bc5c874859049ce49a696a4"
            cabalRows <- handoffPackageRows cabalSource
            cabalRows @?= frozenHandoffPackageRows
    , testCase "rooted relay envelopes are bounded before splitting and match exact authenticated paths" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
            receiverInternalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver" </> "Internal.hs")
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
            let envelope = normalizeWhitespace envelopeSource
                boundedFrame = normalizeWhitespace boundedFrameSource
                receiverInternal = normalizeWhitespace receiverInternalSource
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
                envelope
            assertFragmentsInOrder
                "declared component width is rejected before the attacker-controlled body is split or decoded"
                [ "ByteString.length raw < 8"
                , "declared > fromIntegral maxRequesterPathComponentBytes"
                , "fromIntegral (ByteString.length body) < declared"
                , "ByteString.splitAt (fromIntegral declared) body"
                ]
                boundedFrame
            assertFragmentsInOrder
                "a bounded component is taken before UTF-8 decoding"
                [ "(rawFrame, rest) <- takeRequesterPathFrame remaining"
                , "TextEncoding.decodeUtf8' rawFrame"
                ]
                envelope
            assertFragmentsInOrder
                "the neutral folds expose no OpenFrame ancestry and only structurally paired response paths"
                [ "rootedLifecycleRequestPathKernel raw = do"
                , "Rooted.rootedLifecycleRequestFromWireKernel raw"
                , "(const Nothing)"
                , "rootedLifecycleResponsePairPathKernel exactRequest signedResponse = do"
                , "Rooted.rootedLifecycleResponseFromWireKernel signedResponse"
                , "Rooted.rootedLifecycleResponsePairKernel"
                ]
                receiverInternal
            assertFragmentsInOrder
                "root comparison is complete equality while an intermediate comparison is the exact leaf suffix"
                [ "Nothing -> Right ()"
                , "atRoot && complete == envelope"
                , "not atRoot && envelope `isPathSuffixOf` complete"
                , "drop (length complete - length suffix) complete == suffix"
                ]
                envelope
    , testCase "rooted relay alternates one typed singleton exchange and preserves both refusal forms" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
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
                serve = normalizeWhitespace serveSource
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
                linkConstruction
            assertBool
                "every keyless hop prepends only its verified current frame"
                ( "linkRootedLifecycleRaw = \\downstream exactRequest -> relayRootedLifecycle channel request (currentFrame : downstream) exactRequest"
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
                route
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
                serve
            assertFragmentsInOrder
                "serving re-emits upstream outer refusal fields byte-for-byte without translating them"
                [ "Right (Left (code, detail))"
                , "transmit channel RefusedTag request [code, detail]"
                ]
                serve
            assertFragmentsInOrder
                "only the originating typed requester verifies signed bytes, so a signed rooted Refused remains a typed response"
                [ "Right (Left (code, detail))"
                , "RelayRefusedByPeer"
                , "Right (Right signedResponse)"
                , "withVerifiedRootedLifecycleResponse key exactRequest signedResponse id"
                , "Right response -> pure (Right response)"
                ]
                requester
    , testCase "rooted relay transport is keyless, acyclic, exactly owned, frozen, and budgeted" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
            receiverInternalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver" </> "Internal.hs")
            receiverSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            handoffInternalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Internal.hs")
            rootedSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Rooted.hs")
            recoverySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Recovery.hs")
            protocolSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Protocol.hs")
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
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                digest = childConfigDigest . TextEncoding.encodeUtf8 . Text.pack
                frozenRelayLines :: Int
                frozenRelayLines = 1852
                frozenReceiverInternalLines :: Int
                frozenReceiverInternalLines = 122
                frozenTransportRelayLines :: Int
                frozenTransportRelayLines = 2203
                receiverInternalLines = significantHaskellLineCount receiverInternalSource
                transportDelta =
                    frozenTransportRelayLines - frozenRelayLines
                        + receiverInternalLines
                        - frozenReceiverInternalLines
                transportOnly = rootedTransport <> rootedRoute <> rootedServe
            users "rootedLifecycleRequestPathKernel"
                @?= [ "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            users "rootedLifecycleResponsePairPathKernel"
                @?= [ "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            users "receiveRootedLifecycleResponseThroughLink"
                @?= ["HostBootstrap/Handoff/Relay.hs"]
            users "signRootedLifecycleResponseKernel"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Relay.hs"]
            users "withVerifiedRootedLifecycleResponse"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
                    ]
            importers "HostBootstrap.Handoff.Rooted"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Internal.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "HostBootstrap/Lifecycle/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Node.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    ]
            importers "HostBootstrap.Handoff.Receiver.Internal"
                @?= [ "HostBootstrap/Authority/ProjectPlan/Internal.hs"
                    , "HostBootstrap/Handoff/Receiver.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/ProjectPlan/Child/Internal.hs"
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
                , "System.Process"
                , "createProcess"
                , "compareAndSwapProtectedRecord"
                ]
            assertBool
                "the transport increment adds no data, newtype, type synonym, process owner, or generic semantic callback"
                ( SourceGuard.countHaskellIdentifier "data" transportOnly == 0
                    && SourceGuard.countHaskellIdentifier "newtype" transportOnly == 0
                    && SourceGuard.countHaskellIdentifier "type" transportOnly == 0
                    && "forall" `notElem` words transportOnly
                    && not ("-> result" `isInfixOf` transportOnly)
                )
            (frozenTransportRelayLines, receiverInternalLines, transportDelta) @?= (2203, 170, 399)
            assertBool
                "the two-owner rooted transport increment and its two adopted root call sites stay within 400 significant lines"
                (transportDelta <= 400)
            digest relaySource @?= "1f7953c8813f44f20f84e96b691fd8ec2d7f5f65d40a783fc1221acd03aaed13"
            digest receiverInternalSource @?= "0a481b39e02ef02f4e1c4e47ca306794e8727ff8e15f2baae6d579e6554a2834"
            digest receiverSource @?= "514941f9d28ccb29ab6acb883f5f4797e6552842f9cc5e40c089684415544615"
            digest recoverySource @?= "15244530789cfe080ff84c543881158422143758cf9e15885ad47f08839424d1"
            digest handoffInternalSource @?= "305dc09a9e9ae617161f0b7ec35309aeb31d0152894988a8bc53f415cebca2bf"
            digest handoffSource @?= "6bbbd828b453173cf8f4be9cd1989eb0a6ddfc2cc5a9639b29d76558c0121fe5"
            digest rootedSource @?= "c035f05ec6c0951165d9141c8d6fccd1ce45b00266f88e5d9753dbbdf618460e"
            significantHaskellLineCount protocolSource @?= 526
            digest protocolSource @?= "04f069429b164e3d6b99ff68b900996c090e73947bc5c874859049ce49a696a4"
            cabalRows <- handoffPackageRows cabalSource
            cabalRows @?= frozenHandoffPackageRows
    , testCase "recovery child package ownership is bounded, hidden, additive, and exactly attributed" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            recoverySource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Recovery.hs")
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
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let recovery = normalizeWhitespace recoverySource
                facade = normalizeWhitespace recoveryFacade
                exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
                publicHandoff = normalizedModuleExports handoffExports
                importers moduleName =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                users identifier =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                handoffAttribution = significantHaskellLineCount recoveryFacade + 6
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
                recovery
            assertFragmentsInOrder
                "the decoder bounds raw input and admits exactly two canonical frames"
                [ "fromIntegral (ByteString.length raw) <= recoveryPackageLimit"
                , "(childConfig, afterConfig) <- takeRecoveryFrame raw"
                , "(adapter, trailing) <- takeRecoveryFrame afterConfig"
                , "require (ByteString.null trailing) \"has trailing bytes\""
                , "package <- recoveryChildPackageKernel childConfig adapter"
                , "renderRecoveryChildPackageKernel package == raw"
                ]
                recovery
            assertFragmentsInOrder
                "oversized declarations refuse before body splitting"
                [ "ByteString.length raw < 8"
                , "declared > recoveryPackageLimit"
                , "contains an oversized field"
                , "ByteString.splitAt (fromIntegral declared) body"
                ]
                recovery
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
                facade
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
                facade
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
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Teardown/Internal.hs"
                    ]
            users "RecoveryChildPackage"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Recovery.hs"
                    ]
            users "signRecoveryChildPackageBindingKernel"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Relay.hs"]
            users "withVerifiedRecoveryChildPackage"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Receiver.hs"]
            length (filter (== "HostBootstrap.Handoff.Recovery") private) @?= 1
            assertBool
                "the recovery codec remains hidden from every exposed library surface"
                ("HostBootstrap.Handoff.Recovery" `notElem` exposed)
            significantHaskellLineCount recoveryFacade @?= 95
            recoveryAttribution @?= 78
            (handoffAttribution, recoveryAttribution, handoffAttribution + recoveryAttribution)
                @?= (101, 78, 179)
    , testCase "authenticated root scope remains nominal, scope-only, and exactly attributed" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
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
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                scopeSectionAttribution = significantHaskellLineCount scopeSection
                exportAttribution = 4
                receivedConstructorAttribution = significantHaskellLineCount receivedConstructor
                receivedProjectionAttribution = 2
                errorAttribution = 3
                handoffAttribution =
                    scopeSectionAttribution
                        + exportAttribution
                        + receivedConstructorAttribution
                        + receivedProjectionAttribution
                        + errorAttribution
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
                scope
            assertFragmentsInOrder
                "the producer forces hidden admission and checks the live broker before deriving and signing its exact scope"
                [ "signAuthenticatedRootScopeKernel kernel = kernel `seq` consumeRecoverySigningKernel kernel sign"
                , "sign broker scope = withActiveRootBroker broker"
                , "case authenticatedRootScopeUnsigned broker scope of"
                , "authenticatedRootScopeSignedMaterial keyDigest unsigned"
                , "bounded \"authenticated root scope\" wire"
                ]
                scope
            assertFragmentsInOrder
                "scope signing refuses a project or kind/run relation different from its root broker"
                [ "authenticatedRootScopeUnsigned broker scope = do"
                , "handoffScopeProject scope == brokerProjectName broker"
                , "handoffScopeTag scope == brokerScopeTag broker"
                , "validateAuthenticatedRootScopeKindRun kind run"
                , "bounded \"authenticated root scope unsigned wire\" unsigned"
                ]
                scope
            assertFragmentsInOrder
                "the signed material fixes its own domain, installed-key digest, and canonical unsigned capsule"
                [ "authenticatedRootScopeSignedMaterial keyDigest unsigned = frameWire authenticatedRootScopeSigningDomain"
                , "frameWire keyDigest"
                , "frameWire unsigned"
                ]
                scope
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
                scope
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
                scope
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
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Receiver.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
                    ]
            users "signAuthenticatedRootScopeKernel"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Relay.hs"]
            users "withAuthenticatedRootScopeFromWire"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Receiver.hs"]
            assertBool
                "no separate capsule module or testing signer seam is registered"
                ( not ("HostBootstrap.Handoff.AuthenticatedRootScope" `isInfixOf` cabalSource)
                    && not ("AuthenticatedRootScope.Testing" `isInfixOf` cabalSource)
                )
            ( scopeSectionAttribution
                , exportAttribution
                , receivedConstructorAttribution
                , receivedProjectionAttribution
                , errorAttribution
                , handoffAttribution
                )
                @?= (192, 4, 4, 2, 3, 205)
    , testCase "recoverable edge registration is token-gated, durable, and Relay-owned" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            internalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Internal.hs")
            relaySource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
            teardownInternalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Teardown" </> "Internal.hs")
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
                    "    repair session binding ="
                    kernelSource
            repairSource <-
                requiredSourceSection
                    "ordinary token repair"
                    "    repair session binding ="
                    "    verify session mapKey identity relay token = do"
                    kernelSource
            verificationSource <-
                requiredSourceSection
                    "recoverable map and token readback"
                    "    verify session mapKey identity relay token = do"
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
                        [ sourcePath sourceRoot path
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
                [ ( "the existing hidden capability is the first argument"
                  , "registerRecoverableAdmittedHandoffEdgeKernel :: RecoverySigningKernel -> RootBroker scope brokerGeneration verb"
                  , kernel
                  )
                , ( "the result is only the ordinary opaque relay and token pair"
                  , "Either rejection (BrokerRelay scope brokerGeneration, HandoffToken)"
                  , kernel
                  )
                , ( "partial application strictly consumes the hidden capability"
                  , "{-# OPAQUE registerRecoverableAdmittedHandoffEdgeKernel #-} registerRecoverableAdmittedHandoffEdgeKernel kernel = kernel `seq` consumeRecoverySigningKernel kernel recover"
                  , kernel
                  )
                , ( "the complete identity is bounded before it can name a map key"
                  , "fromIntegral (ByteString.length identity) > maxWireBytes = Left (HandoffWireTooLarge (fromIntegral (ByteString.length identity)) maxWireBytes)"
                  , identity
                  )
                , ( "the map key is a bounded digest of the complete identity"
                  , "mkRecordKey (\"recovery-open.\" <> digestBytes identity)"
                  , kernel
                  )
                , ( "the complete unhashed identity is retained in the map value"
                  , "frameWire identity"
                  , record
                  )
                , ( "the map value retains the complete canonical binding"
                  , "frameWire (renderHandoffBinding (relayBinding relay))"
                  , record
                  )
                , ( "the map value retains the exact raw token"
                  , "frameWire (handoffTokenBytes token)"
                  , record
                  )
                , ( "an existing map must be version one and strictly decoded"
                  , "Right (Just record) | recordVersionWord (protectedRecordVersion record) /= 1 -> pure mapConflict | otherwise -> pure (decode broker input identity (protectedRecordBytes record))"
                  , selection
                  )
                , ( "an absent map alone allocates a fresh exact edge choice"
                  , "Right Nothing -> do token <- freshHandoffToken case mkHandoffBinding broker input token >>= brokerRelay broker of"
                  , selection
                  )
                , ( "map publication is absent-only"
                  , "compareAndSwapProtectedRecord session key ExpectAbsent bytes"
                  , publication
                  )
                , ( "publication rereads both an exact winner and a concurrent peer"
                  , "_ -> do observed <- readProtectedRecord session key"
                  , publication
                  )
                , ( "only exact version-one map bytes are admitted after publication"
                  , "recordVersionWord (protectedRecordVersion record) == 1 -> decode broker input identity (protectedRecordBytes record)"
                  , publication
                  )
                , ( "record decoding rejects every trailing byte"
                  , "require (ByteString.null trailing)"
                  , decoded
                  )
                , ( "record decoding reconstructs the relay from the live broker route and exact input"
                  , "brokerRelayFromRouteWire (rootBrokerRoute broker) (Just input) bindingBytes"
                  , decoded
                  )
                , ( "record decoding reconstructs the hidden token from stored bytes"
                  , "token <- handoffTokenFromBytes tokenBytes"
                  , decoded
                  )
                , ( "record decoding rejects a noncanonical binding re-render"
                  , "expected <- mkHandoffBinding broker input token require (renderHandoffBinding expected == bindingBytes)"
                  , decoded
                  )
                , ( "record decoding rejects a noncanonical complete value re-render"
                  , "require (recoveryRecord identity relay token == raw)"
                  , decoded
                  )
                , ( "an exact planned token row is retained"
                  , "protectedRecordBytes record == plannedEdgeRecord binding , recordVersionWord (protectedRecordVersion record) == 1 -> pure (Right ())"
                  , repair
                  )
                , ( "a granted token is never reopened"
                  , "\"granted:\" `ByteString.isPrefixOf` protectedRecordBytes record -> pure (Left HandoffTokenConsumed)"
                  , repair
                  )
                , ( "a missing token row is recreated as the exact planned edge"
                  , "Right Nothing -> writeExact session key (plannedEdgeRecord binding) tokenConflict"
                  , repair
                  )
                , ( "verification rereads the exact complete map before the token"
                  , "checked <- readExact session mapKey (recoveryRecord identity relay token) mapReadbackConflict"
                  , verification
                  )
                , ( "the final token readback retains granted-token refusal"
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
                kernel
            assertFragmentsInOrder
                "the durable map is selected before ordinary token repair and both readbacks"
                [ "selected <- select session mapKey broker input identity"
                , "Right edge@(relay, token)"
                , "repaired <- repair session (relayBinding relay)"
                , "Right () -> fmap (edge <$) (verify session mapKey identity relay token)"
                ]
                kernel
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
                identity
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
                identity
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
                decoded
            assertFragmentsInOrder
                "token repair CASes only absence and strictly rereads every winner"
                [ "written <- compareAndSwapProtectedRecord session key ExpectAbsent bytes"
                , "Left _ -> readExact session key bytes conflict"
                , "recordVersionWord version /= 1"
                , "otherwise -> readExact session key bytes conflict"
                , "readProtectedRecord session key"
                , "protectedRecordBytes record == bytes"
                ]
                verification
            SourceGuard.countHaskellIdentifier "frameWire" identitySource @?= 10
            SourceGuard.countHaskellIdentifier "frameWire" recordSource @?= 5
            SourceGuard.countHaskellIdentifier "takeFrame" decodeSource @?= 5
            SourceGuard.countHaskellIdentifier "consumeRecoverySigningKernel" kernelSource @?= 1
            SourceGuard.countHaskellIdentifier "withActiveRootBroker" kernelSource @?= 1
            SourceGuard.countHaskellIdentifier "withProtectedEntry" kernelSource @?= 1
            SourceGuard.countHaskellIdentifier "readProtectedRecord" kernelSource @?= 5
            SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" kernelSource @?= 2
            SourceGuard.countHaskellIdentifier "freshHandoffToken" kernelSource @?= 1
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
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            SourceGuard.countHaskellIdentifier
                "registerRecoverableAdmittedHandoffEdgeKernel"
                handoffSource
                @?= 4
            SourceGuard.countHaskellIdentifier
                "registerRecoverableAdmittedHandoffEdgeKernel"
                relaySource
                @?= 2
            SourceGuard.countHaskellIdentifier
                "registerRecoverableAdmittedHandoffEdgeKernel"
                teardownInternalSource
                @?= 0
            SourceGuard.countHaskellIdentifier "BoundReverseDescent" handoffSource @?= 0
            SourceGuard.countHaskellIdentifier "BoundReverseDescent" relaySource @?= 0
            SourceGuard.countHaskellIdentifier "BoundReverseDescent" teardownInternalSource @?= 6
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
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
            length (filter (== "HostBootstrap.Handoff") exposed) @?= 1
            length (filter (== "HostBootstrap.Handoff.Internal") private) @?= 1
            assertBool
                "the recovery capability module remains hidden"
                ("HostBootstrap.Handoff.Internal" `notElem` exposed)
            traverse_
                ( \seam ->
                    assertBool
                        (seam <> " is absent from Cabal")
                        (not (seam `isInfixOf` cabalSource))
                )
                [ "HostBootstrap.Handoff.RecoveryOpen.Testing"
                , "HostBootstrap.Handoff.Recoverable.Testing"
                , "HostBootstrap.Handoff.TokenRepair.Testing"
                ]
    , testCase "reverse descent attachment is ordered, durable, replayable, and closed" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
            protocolSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Protocol.hs")
            teardownSource <- readFile (sourceRoot </> "HostBootstrap" </> "Teardown.hs")
            teardownInternalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Teardown" </> "Internal.hs")
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
                    "{- | Revalidate one Bound report coordinate without minting settlement proof."
                    teardownInternalSource
            observationSource <-
                requiredSourceSection
                    "the future Bound observation eliminator"
                    "{- | Verify acknowledged terminal observations without exposing Bound state."
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
                serveOpenBody = normalizeWhitespace serveOpenSource
                offerFlow = normalizeWhitespace offerSource
                reverseOffer = normalizeWhitespace reverseOfferSource
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
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
            mapM_
                (\(label, fragment, body) -> assertContains label fragment body)
                [ ( "BrokerLink keeps ordinary and recoverable opens in distinct fields"
                  , "linkOpenRaw :: RequesterPath -> HandoffBindingInput -> IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken)) , linkRecoverableOpenRaw :: RequesterPath -> HandoffBindingInput -> ByteString -> IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken))"
                  , brokerLink
                  )
                , ( "the root recoverable field is the sole call to the durable recoverable opener"
                  , "linkRecoverableOpenRaw = \\_ input adapter -> registered <$> registerRecoverableAdmittedHandoffEdgeKernel recoverySigningKernel broker (admits input) input adapter"
                  , linkConstruction
                  )
                , ( "an intermediate link only forwards the recoverable request"
                  , "linkRecoverableOpenRaw = \\downstream -> relayRecoverableOpen route channel request (currentFrame : downstream)"
                  , linkConstruction
                  )
                , ( "recoverable requests use the existing one-field OfferRequest route"
                  , "sent <- transmit channel OfferRequestTag request [enveloped]"
                  , recoverableCodec
                  )
                , ( "the recoverable request has one versioned four-frame vocabulary"
                  , "frameWire recoverableOpenDomain <> frameWire recoverableOpenVersion <> frameWire (renderHandoffBindingInput input) <> frameWire adapter"
                  , recoverableCodec
                  )
                , ( "recoverable decoding is strict, kind-specific, digest-bound, and canonical"
                  , "not (ByteString.null trailing) || requestedPayloadKind input /= RecoveryAdapterWire || requestedChildConfigDigest input /= childConfigDigest adapter || ByteString.null adapter || renderHandoffBindingInput input /= inputBytes || renderRecoverableOpen input adapter /= raw"
                  , recoverableCodec
                  )
                , ( "ordinary opening accepts only narrowed config"
                  , "requireConfigOpen input | requestedPayloadKind input == NarrowedProjectConfig = Right () | otherwise = requesterMismatch \"ordinary edge opening requires narrowed-project-config\""
                  , ordinaryOpen
                  )
                , ( "the Bound constructor retains binding bytes and exact durable readback, not a live offer"
                  , "BoundReverseDescent :: ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId -> ByteString -> RecordVersion -> ByteString -> ReverseDescent (HandoffOffer scope brokerGeneration) scope planId parentFrame childFrame brokerGeneration verb descentId"
                  , family
                  )
                , ( "the hidden capability is the first live-transition argument"
                  , "withBoundReverseDescentKernel :: RecoverySigningKernel -> ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId"
                  , binding
                  )
                , ( "the live transition strictly consumes the capability"
                  , "{-# OPAQUE withBoundReverseDescentKernel #-} withBoundReverseDescentKernel kernel = kernel `seq` consumeRecoverySigningKernel kernel"
                  , binding
                  )
                , ( "live replay accepts either its exact v1 row or a canonical v2 Bound row"
                  , "protectedRecordVersion record == version , exactRecord 1 bytes record -> Right () | recordVersionWord (protectedRecordVersion record) == 2 , Right _ <- parseBoundRecord bytes (protectedRecordBytes record) -> Right ()"
                  , binding
                  )
                , ( "the Bound CAS consumes only the exact Prepared version"
                  , "compareAndSwapProtectedRecord session key (ExpectVersion preparedVersion) boundBytes"
                  , binding
                  )
                , ( "the Bound winner is exactly reread at version two"
                  , "Right (Just record) | exactRecord 2 bytes record -> Right (protectedRecordVersion record)"
                  , binding
                  )
                , ( "the live offer remains lexical beside the binding-only Bound package"
                  , "use (BoundReverseDescent prepared bindingBytes version boundBytes) offer"
                  , binding
                  )
                , ( "the rehydration capability is strict and first"
                  , "{-# OPAQUE withRehydratedBoundReverseDescentKernel #-} withRehydratedBoundReverseDescentKernel kernel = kernel `seq` consumeRecoverySigningKernel kernel"
                  , rehydration
                  )
                , ( "rehydration exposes only a fixed-unit Bound callback"
                  , "ReverseDescent (HandoffOffer scope brokerGeneration) scope planId parentFrame childFrame brokerGeneration verb descentId -> IO (Either Text ())"
                  , rehydration
                  )
                , ( "rehydration accepts only canonical version-two Bound bytes"
                  , "recordVersionWord (protectedRecordVersion record) == 2 -> do binding <- parseBoundRecord expected (protectedRecordBytes record) pure (binding, protectedRecordVersion record, protectedRecordBytes record)"
                  , rehydration
                  )
                , ( "the future observation fold has a fixed unit result"
                  , "(SubtreeSettled scope planId childFrame verb -> IO (Either Text ())) -> IO (Either Text ())"
                  , observation
                  )
                , ( "the observation fold requires exact retained Bound version and bytes"
                  , "protectedRecordVersion record == boundVersion , protectedRecordBytes record == boundBytes"
                  , observation
                  )
                , ( "the Bound codec nests exact Prepared and canonical binding bytes"
                  , "framedText \"hostbootstrap/reverse-descent\" , framedWord 1 , framedText \"bound\" , frameWire prepared , frameWire binding"
                  , recordCodec
                  )
                , ( "Bound decoding rejects empty binding, trailing bytes, and rerender drift"
                  , "prepared == expected , not (ByteString.null binding) , ByteString.null trailing , raw == renderBoundRecord prepared binding"
                  , recordCodec
                  )
                ]
            assertFragmentsInOrder
                "ordinary root and relayed fields refuse RecoveryAdapterWire before any open"
                [ "linkOpenRaw = \\_ input -> case requireConfigOpen input of"
                , "registerAdmittedHandoffEdge"
                , "linkOpenRaw = \\downstream input -> case requireConfigOpen input of"
                , "relayOpen route channel request"
                ]
                linkConstruction
            assertFragmentsInOrder
                "ordinary offers enforce the embedded payload bound and config kind before fresh opening"
                [ "offerHandoffEdge link channel request input payload terminal = case requireOfferPayloadBound payload >> requireConfigOpen input of"
                , "opened <- openEdgeThroughLink link input"
                ]
                offerFlow
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
                serveOpenBody
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
                binding
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
                reverseOffer
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
                rehydration
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
                observation
            assertFragmentsInOrder
                "exact Bound readback precedes private observation verification"
                [ "protectedRecordVersion record == boundVersion"
                , "protectedRecordBytes record == boundBytes"
                , "verify observations"
                ]
                observation
            SourceGuard.countHaskellIdentifier "HandoffToken" familySource @?= 0
            SourceGuard.countHaskellIdentifier "HandoffOffer" familySource @?= 1
            SourceGuard.countHaskellIdentifier "withProtectedEntry" bindingSource @?= 2
            SourceGuard.countHaskellIdentifier "validateCurrentLifecycleCursor" bindingSource @?= 2
            SourceGuard.countHaskellIdentifier "withProtectedEntry" rehydrationSource @?= 1
            SourceGuard.countHaskellIdentifier "validateCurrentLifecycleCursor" rehydrationSource @?= 1
            SourceGuard.countHaskellIdentifier "readProtectedRecord" rehydrationSource @?= 1
            SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" rehydrationSource @?= 0
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
                , "withVerifiedBoundReverseDescentObservationsKernel"
                ]
            assertBool
                "the attachment driver is exported only by the hidden Relay module"
                ("offerReverseDescentKernel" `elem` privateRelay)
            users "registerRecoverableAdmittedHandoffEdgeKernel"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            users "withBoundReverseDescentKernel"
                @?= [ "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Teardown/Internal.hs"
                    ]
            users "withRehydratedBoundReverseDescentKernel"
                @?= [ "HostBootstrap/Handoff/Completion.hs"
                    , "HostBootstrap/Teardown/Internal.hs"
                    ]
            users "withVerifiedBoundReverseDescentObservationsKernel"
                @?= [ "HostBootstrap/Handoff/Completion.hs"
                    , "HostBootstrap/Teardown/Internal.hs"
                    ]
            users "offerReverseDescentKernel"
                @?= [ "HostBootstrap/Handoff/Process.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            importers "HostBootstrap.Teardown.Internal"
                @?= [ "HostBootstrap/Command/LifecycleEntry.hs"
                    , "HostBootstrap/Handoff/Completion.hs"
                    , "HostBootstrap/Handoff/Process.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/ProjectPlan/Child/Internal.hs"
                    ]
            importers "HostBootstrap.Handoff.Relay" @?= ["HostBootstrap/Handoff/Process.hs"]
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
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
            length (filter (== "HostBootstrap.Handoff.Relay") private) @?= 1
            length (filter (== "HostBootstrap.Teardown.Internal") private) @?= 1
            assertBool "Relay remains hidden" ("HostBootstrap.Handoff.Relay" `notElem` exposed)
            assertBool "Teardown.Internal remains hidden" ("HostBootstrap.Teardown.Internal" `notElem` exposed)
            traverse_
                ( \seam ->
                    assertBool
                        (seam <> " is absent from Cabal")
                        (not (seam `isInfixOf` cabalSource))
                )
                [ "HostBootstrap.Handoff.Completion.Testing"
                , "HostBootstrap.Handoff.Lifecycle.Testing"
                , "HostBootstrap.Handoff.Relay.Testing"
                , "HostBootstrap.Teardown.Internal.Testing"
                , "HostBootstrap.Teardown.ReverseDescent.Testing"
                ]
    , testCase "semantic lifecycle completion is sealed, exact, fixed-unit, and caller-free" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            completionSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Completion.hs")
            lifecycleSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Lifecycle.hs")
            receiverSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
            protocolSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Protocol.hs")
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
            teardownSource <- readFile (sourceRoot </> "HostBootstrap" </> "Teardown.hs")
            teardownInternalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Teardown" </> "Internal.hs")
            completionFamilySource <-
                requiredSourceSection
                    "the hidden semantic completion family"
                    "data LifecycleCompletion proof scope brokerGeneration verb where"
                    "{- | Acknowledge a canonical forward report against one exact offer."
                    completionSource
            forwardReporterSource <-
                requiredSourceSection
                    "the completed forward reporter"
                    "{- | Render one completed forward report only from its terminal cursor."
                    "{- | Render one completed reverse report from the same-index sealed entry"
                    lifecycleSource
            reverseReporterSource <-
                requiredSourceSection
                    "the completed reverse reporter"
                    "{- | Render one completed reverse report from the same-index sealed entry"
                    "renderObservations ::"
                    lifecycleSource
            forwardAcknowledgementSource <-
                requiredSourceSection
                    "the acknowledged forward producer"
                    "{- | Acknowledge a canonical forward report against one exact offer."
                    "{- | Validate and acknowledge one canonical reverse report against live Bound"
                    completionSource
            reverseAcknowledgementSource <-
                requiredSourceSection
                    "the common acknowledged Bound reverse producer"
                    "{- | Validate and acknowledge one canonical reverse report against live Bound"
                    "{- | Rehydrate observation-only Bound state without reopening a token or map,"
                    completionSource
            rehydratedAcknowledgementSource <-
                requiredSourceSection
                    "the no-open rehydrated reverse producer"
                    "{- | Rehydrate observation-only Bound state without reopening a token or map,"
                    "{- | Eliminate semantic completion without exposing its retained wire identity."
                    completionSource
            completionFoldSource <-
                requiredSourceSection
                    "the strict semantic completion fold"
                    "{- | Eliminate semantic completion without exposing its retained wire identity."
                    "acknowledge ::"
                    completionSource
            acknowledgementActionSource <-
                requiredSourceSection
                    "the caller-supplied acknowledgement action"
                    "acknowledge ::"
                    "requireBinding ::"
                    completionSource
            reverseOriginSource <-
                requiredSourceSection
                    "the exact reverse origin and proof join"
                    "reverseOriginMatches ::"
                    "exactFrames ::"
                    lifecycleSource
            receiverSignatureSource <-
                requiredSourceSection
                    "the Receiver owner-supplied terminal action signature"
                    "withReceivedHandoffEdge ::"
                    "withReceivedHandoffEdge\n    project channel key"
                    receiverSource
            receiverExchangeSource <-
                requiredSourceSection
                    "the Receiver authenticated exchange"
                    "withReceivedHandoffEdge\n    project channel key"
                    "runTerminalAction ::"
                    receiverSource
            terminalActionSource <-
                requiredSourceSection
                    "the masked one-shot terminal report action"
                    "runTerminalAction ::"
                    "-- ---------------------------------------------------------------------------\n-- Message shapes"
                    receiverSource
            receiverClassificationSource <-
                requiredSourceSection
                    "the two rank-N terminal-report branches"
                    "classifyVerified ::"
                    "configEvidence ::"
                    receiverSource
            liftContextSource <-
                requiredSourceSection
                    "the plan-owned reverse LiftContext fold"
                    "withReverseDescentLiftContextKernel ::"
                    "{- | Prepare one exact root-entry descent, or return its unchanged work."
                    teardownInternalSource
            boundReportSource <-
                requiredSourceSection
                    "the no-proof Bound report validator"
                    "{- | Revalidate one Bound report coordinate without minting settlement proof."
                    "{- | Verify acknowledged terminal observations without exposing Bound state."
                    teardownInternalSource
            boundObservationSource <-
                requiredSourceSection
                    "the proof-producing Bound observation validator"
                    "{- | Verify acknowledged terminal observations without exposing Bound state."
                    "forceProtectedResult ::"
                    teardownInternalSource
            lifecycleExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Lifecycle has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Lifecycle" lifecycleSource)
            completionExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Completion has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Completion" completionSource)
            handoffExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff" handoffSource)
            teardownExports <-
                maybe
                    (assertFailure "HostBootstrap.Teardown has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Teardown" teardownSource)
            let family = normalizeWhitespace completionFamilySource
                forwardReporter = normalizeWhitespace forwardReporterSource
                reverseReporter = normalizeWhitespace reverseReporterSource
                forwardAcknowledgement = normalizeWhitespace forwardAcknowledgementSource
                reverseAcknowledgement = normalizeWhitespace reverseAcknowledgementSource
                rehydratedAcknowledgement = normalizeWhitespace rehydratedAcknowledgementSource
                completionFold = normalizeWhitespace completionFoldSource
                acknowledgementAction = normalizeWhitespace acknowledgementActionSource
                reverseOrigin = normalizeWhitespace reverseOriginSource
                receiverSignature = normalizeWhitespace receiverSignatureSource
                receiverExchange = normalizeWhitespace receiverExchangeSource
                terminalAction = normalizeWhitespace terminalActionSource
                receiverClassification = normalizeWhitespace receiverClassificationSource
                liftContext = normalizeWhitespace liftContextSource
                boundReport = normalizeWhitespace boundReportSource
                boundObservation = normalizeWhitespace boundObservationSource
                hiddenCompletionExports = normalizedModuleExports completionExports
                hiddenLifecycleExports = normalizedModuleExports lifecycleExports
                hiddenExports = hiddenCompletionExports <> hiddenLifecycleExports
                publicHandoff = normalizedModuleExports handoffExports
                publicTeardown = normalizedModuleExports teardownExports
                users identifier =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
            hiddenCompletionExports
                @?= [ "LifecycleCompletion"
                    , "withAcknowledgedForwardLifecycleCompletionKernel"
                    , "withAcknowledgedBoundReverseLifecycleCompletionKernel"
                    , "withRehydratedAcknowledgedReverseLifecycleCompletionKernel"
                    , "withLifecycleCompletionKernel"
                    ]
            hiddenLifecycleExports
                @?= [ "withForwardLifecycleReportKernel"
                    , "withReverseLifecycleReportKernel"
                    ]
            mapM_
                (\(label, fragment, body) -> assertContains label fragment body)
                [ ( "the sole new type has four indices"
                  , "data LifecycleCompletion proof scope brokerGeneration verb where"
                  , family
                  )
                , ( "all four completion roles are nominal"
                  , "type role LifecycleCompletion nominal nominal nominal nominal"
                  , family
                  )
                , ( "forward completion retains only exact report and acknowledgement bytes"
                  , "ForwardLifecycleCompletion :: ByteString -> ByteString -> LifecycleCompletion () scope brokerGeneration VerbUp"
                  , family
                  )
                , ( "reverse completion additionally retains its exact subtree proof"
                  , "ReverseLifecycleCompletion :: ByteString -> ByteString -> SubtreeSettled scope planId frame verb -> LifecycleCompletion (SubtreeSettled scope planId frame verb) scope brokerGeneration verb"
                  , family
                  )
                , ( "the forward reporter consumes only an exact terminal cursor"
                  , "AuthorizedChildCursor scope specDigest planDigest brokerGeneration parentFrame planId configId frame VerbUp TeardownPhase"
                  , forwardReporter
                  )
                , ( "the forward reporter derives origin and canonical report before its fixed-unit callback"
                  , "renderForwardCompletedLifecycleReport (renderForwardTerminalOrigin terminal)"
                  , forwardReporter
                  )
                , ( "the reverse reporter joins a same-index Entry and SubtreeSettled proof"
                  , "LifecycleEntry scope planId frame brokerGeneration verb -> SubtreeSettled scope planId frame verb"
                  , reverseReporter
                  )
                , ( "reverse report observations derive only from sealed settlement evidence"
                  , "renderTeardownObservations . map (\\(operation, outcome) -> (Text.pack (operationKeyText operation), outcome)) . subtreeSettledTerminalObservations"
                  , normalizeWhitespace lifecycleSource
                  )
                , ( "forward acknowledgement binds the report to the exact offer binding"
                  , "expected = Handoff.renderHandoffBinding (Handoff.handoffOfferBinding offer)"
                  , forwardAcknowledgement
                  )
                , ( "forward completed alone constructs semantic evidence"
                  , "acknowledge report persist $ \\ack -> use (ForwardLifecycleCompletion report ack)"
                  , forwardAcknowledgement
                  )
                , ( "forward refused and failed reports are acknowledged without a constructor"
                  , "refused binding _ _ _ _ = requireBinding expected binding (acknowledge report persist (const (pure (Right ())))) failed = refused"
                  , forwardAcknowledgement
                  )
                , ( "reverse completed reports alone decode observations and invoke the proof verifier"
                  , "teardownObservationsFromWire observations"
                  , reverseAcknowledgement
                  )
                , ( "reverse completion construction follows acknowledgement"
                  , "acknowledge report persist $ \\ack -> use (ReverseLifecycleCompletion report ack settled)"
                  , reverseAcknowledgement
                  )
                , ( "reverse refused and failed reports use only the no-proof Bound validator"
                  , "withVerifiedBoundReverseDescentReportKernel bound binding verb $ acknowledge report persist (const (pure (Right ()))) failed = refused"
                  , reverseAcknowledgement
                  )
                , ( "rehydrated recovery owns the hidden capability internally"
                  , "withRehydratedBoundReverseDescentKernel recoverySigningKernel prepared"
                  , rehydratedAcknowledgement
                  )
                , ( "rehydrated recovery enters the one common Bound acknowledgement path"
                  , "\\bound -> withAcknowledgedBoundReverseLifecycleCompletionKernel bound report persist use"
                  , rehydratedAcknowledgement
                  )
                , ( "the completion fold exposes only its indexed proof to a fixed-unit callback"
                  , "LifecycleCompletion proof scope brokerGeneration verb -> (proof -> IO (Either Text ())) -> IO (Either Text ())"
                  , completionFold
                  )
                , ( "the forward fold strictly forces retained bytes before yielding unit"
                  , "ForwardLifecycleCompletion report acknowledgement -> case report `seq` acknowledgement `seq` () of () -> \\use -> use ()"
                  , completionFold
                  )
                , ( "the reverse fold strictly forces bytes and proof before yielding proof"
                  , "ReverseLifecycleCompletion report acknowledgement proof -> case report `seq` acknowledgement `seq` proof `seq` () of () -> \\use -> use proof"
                  , completionFold
                  )
                , ( "the durable action receives only exact report and acknowledgement bytes"
                  , "(ByteString -> ByteString -> IO (Either Text ()))"
                  , acknowledgementAction
                  )
                , ( "the LiftContext fold receives no caller context or frame coordinates"
                  , "ReverseDescent state scope planId parentFrame childFrame brokerGeneration verb descentId -> (LiftContext -> IO (Either Text ())) -> IO (Either Text ())"
                  , liftContext
                  )
                , ( "the LiftContext is derived from the exact plan-owned descent"
                  , "topologyDescentFrom (topology plan) parent"
                  , liftContext
                  )
                , ( "the derived LiftContext is strict before its fixed-unit callback"
                  , "otherwise -> context `seq` use context"
                  , liftContext
                  )
                , ( "the no-proof validator checks exact binding and closed verb"
                  , "observedBinding /= bindingBytes"
                  , boundReport
                  )
                , ( "the no-proof validator returns only fixed unit"
                  , "IO (Either Text ()) -> IO (Either Text ())"
                  , boundReport
                  )
                ]
            assertFragmentsInOrder
                "reverse report construction validates origin/proof before rendering"
                [ "withChildRecoveryTerminalOrigin entry"
                , "reverseOriginMatches entry settled origin"
                , "renderObservations settled"
                , "renderReverseCompletedLifecycleReport origin observations"
                , "use report"
                ]
                reverseReporter
            assertFragmentsInOrder
                "the reverse origin joins exact plan, frame, and verb duplicates"
                [ "exactFrames 16 raw"
                , "snapshotName == expectedDigest"
                , "digestName == expectedDigest"
                , "frameName == expectedFrame"
                , "teardownName == expectedFrame"
                , "verbName == expectedVerb"
                , "commandName == expectedVerb"
                , "teardownVerbName == expectedVerb"
                , "lifecycleEntryFrameName entry == expectedFrame"
                , "lifecycleEntryVerbName entry == expectedVerb"
                ]
                reverseOrigin
            assertFragmentsInOrder
                "Bound proof validation precedes acknowledgement action, constructor, and callback"
                [ "withVerifiedBoundReverseDescentObservationsKernel bound binding verb rows"
                , "\\settled -> acknowledge report persist"
                , "\\ack -> use (ReverseLifecycleCompletion report ack settled)"
                ]
                reverseAcknowledgement
            assertFragmentsInOrder
                "acknowledgement rendering and durable action precede every evidence continuation"
                [ "renderLifecycleAcknowledgement report"
                , "stored <- persist report ack"
                , "case stored of"
                , "Right () -> ack `seq` use ack"
                ]
                acknowledgementAction
            assertFragmentsInOrder
                "the no-proof Bound check is strict inside the protected entry and calls back after unlock"
                [ "observedBinding /= bindingBytes"
                , "observedVerb /= projectVerbName verb"
                , "checked <- withProtectedEntry store"
                , "validateCurrentLifecycleCursor session cursor"
                , "readProtectedRecord session key"
                , "forceProtectedResult (checkRecord observed)"
                , "case checked of"
                , "Right (Right ()) -> use"
                ]
                boundReport
            assertFragmentsInOrder
                "the proof-producing Bound check is strict inside the protected entry and calls back after unlock"
                [ "observedBinding /= bindingBytes"
                , "observedVerb /= projectVerbName verb"
                , "checked <- withProtectedEntry store"
                , "validateCurrentLifecycleCursor session cursor"
                , "readProtectedRecord session key"
                , "forceProtectedResult (checkRecord observed)"
                , "case checked of"
                , "Right (Right settled) -> use settled"
                ]
                boundObservation
            assertFragmentsInOrder
                "Receiver authenticates, accepts, then enters the owner-supplied terminal action"
                [ "classifyVerified authenticated channel requestId key evidence verified useConfig useRecovery"
                , "sendMessage channel afterGrant AcceptedTag"
                , "runTerminalAction channel afterAccepted requestId active branch"
                ]
                receiverExchange
            assertContains
                "both Receiver branches receive the one-shot sender"
                "(ByteString -> IO (Either ReceiverError ()))"
                receiverSignature
            assertFragmentsInOrder
                "the config branch passes the sender directly with its authenticated evidence"
                [ "\\sendReport -> do"
                , "mkReceivedEdge authenticated verified channel requestId"
                , "useConfig edge admitted sendReport"
                ]
                receiverClassification
            assertFragmentsInOrder
                "the recovery branch passes the same sender directly with its joint descent"
                [ "\\wire sendReport -> do"
                , "mkReceivedRecoveryDescent"
                , "useRecovery descent sendReport"
                ]
                receiverClassification
            assertFragmentsInOrder
                "the terminal sender is masked, one-shot, closes, and requires successful delivery"
                [ "Exception.mask $ \\restore"
                , "newMVar (False, False, False)"
                , "if closed"
                , "if attempted"
                , "sendMessage channel state CompletedTag requestId [report]"
                , "Right _ -> writeIORef active 0"
                , "restore (useTerminal sendReport)"
                , "Exception.uninterruptibleMask_"
                , "pure ((True, attempted, completed), completed)"
                , "Right (Right ()) | delivered -> pure (Right ())"
                , "the terminal action returned without one successful report send"
                ]
                terminalAction
            SourceGuard.countHaskellTokenSequence ["data", "LifecycleCompletion"] completionSource @?= 1
            SourceGuard.countHaskellTokenSequence ["newtype", "LifecycleCompletion"] completionSource @?= 0
            SourceGuard.countHaskellTokenSequence ["type", "LifecycleCompletion"] completionSource @?= 0
            SourceGuard.countHaskellIdentifier "LifecycleCompletion" completionSource @?= 9
            SourceGuard.countHaskellIdentifier "ForwardLifecycleCompletion" completionSource @?= 3
            SourceGuard.countHaskellIdentifier "ReverseLifecycleCompletion" completionSource @?= 3
            SourceGuard.countHaskellIdentifier "withVerifiedBoundReverseDescentObservationsKernel" reverseAcknowledgementSource @?= 1
            SourceGuard.countHaskellIdentifier "withVerifiedBoundReverseDescentReportKernel" reverseAcknowledgementSource @?= 1
            SourceGuard.countHaskellIdentifier "ForwardLifecycleCompletion" forwardAcknowledgementSource @?= 1
            SourceGuard.countHaskellIdentifier "ReverseLifecycleCompletion" reverseAcknowledgementSource @?= 1
            SourceGuard.countHaskellIdentifier "ForwardLifecycleCompletion" completionFoldSource @?= 1
            SourceGuard.countHaskellIdentifier "ReverseLifecycleCompletion" completionFoldSource @?= 1
            SourceGuard.countHaskellIdentifier "ByteString" completionFoldSource @?= 0
            SourceGuard.countHaskellIdentifier "withProtectedEntry" boundReportSource @?= 1
            SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" boundReportSource @?= 0
            SourceGuard.countHaskellIdentifier "withProtectedEntry" boundObservationSource @?= 1
            SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" boundObservationSource @?= 0
            SourceGuard.countHaskellIdentifier "LifecycleCompletion" receiverSource @?= 0
            SourceGuard.countHaskellIdentifier "renderLifecycleAcknowledgement" receiverSource @?= 0
            SourceGuard.countHaskellIdentifier "withProtectedEntry" receiverSource @?= 0
            SourceGuard.countHaskellTokenSequence ["CompletedTag", "[", "\"ok\"", "]"] receiverSource @?= 0
            mapM_
                ( \identifier ->
                    assertBool
                        (identifier <> " is hidden from public facades")
                        (identifier `notElem` publicHandoff && identifier `notElem` publicTeardown)
                )
                hiddenExports
            users "LifecycleCompletion" @?= ["HostBootstrap/Handoff/Completion.hs"]
            users "withForwardLifecycleReportKernel" @?= ["HostBootstrap/Handoff/Lifecycle.hs"]
            users "withReverseLifecycleReportKernel" @?= ["HostBootstrap/Handoff/Lifecycle.hs"]
            users "withAcknowledgedForwardLifecycleCompletionKernel"
                @?= [ "HostBootstrap/Handoff/Completion.hs"
                    , "HostBootstrap/Handoff/Process.hs"
                    ]
            users "withAcknowledgedBoundReverseLifecycleCompletionKernel"
                @?= [ "HostBootstrap/Handoff/Completion.hs"
                    , "HostBootstrap/Handoff/Process.hs"
                    ]
            users "withRehydratedAcknowledgedReverseLifecycleCompletionKernel"
                @?= ["HostBootstrap/Handoff/Completion.hs"]
            users "withLifecycleCompletionKernel" @?= ["HostBootstrap/Handoff/Completion.hs"]
            users "withReverseDescentLiftContextKernel"
                @?= ["HostBootstrap/Teardown/Internal.hs"]
            users "withVerifiedBoundReverseDescentReportKernel"
                @?= [ "HostBootstrap/Handoff/Completion.hs"
                    , "HostBootstrap/Teardown/Internal.hs"
                    ]
            importers "HostBootstrap.Handoff.Completion" @?= ["HostBootstrap/Handoff/Process.hs"]
            importers "HostBootstrap.Handoff.Lifecycle" @?= []
            assertBool
                "Completion owns the lower no-open recovery path"
                (SourceGuard.importsModule "HostBootstrap.Teardown.Internal" completionSource)
            assertBool
                "Completion owns the hidden recovery capability value"
                (SourceGuard.importsModule "HostBootstrap.Handoff.Internal" completionSource)
            assertBool
                "Lifecycle adopts the hidden lifecycle-entry producer"
                (SourceGuard.importsModule "HostBootstrap.Command.LifecycleEntry" lifecycleSource)
            assertBool
                "Lifecycle does not adopt the lower completion owner before forward integration"
                (not (SourceGuard.importsModule "HostBootstrap.Handoff.Completion" lifecycleSource))
            assertBool
                "Receiver constructs neither semantic completion nor reports"
                ( not (SourceGuard.importsModule "HostBootstrap.Handoff.Completion" receiverSource)
                    && not (SourceGuard.importsModule "HostBootstrap.Handoff.Lifecycle" receiverSource)
                )
            mapM_
                ( \moduleName ->
                    assertBool
                        ("Completion imports no upward/process/protocol owner " <> moduleName)
                        (not (SourceGuard.importsModule moduleName completionSource))
                )
                [ "HostBootstrap.Chain"
                , "HostBootstrap.Command.LifecycleEntry"
                , "HostBootstrap.Handoff.Lifecycle"
                , "HostBootstrap.Handoff.Protocol"
                , "HostBootstrap.Handoff.Receiver"
                , "HostBootstrap.Handoff.Relay"
                , "HostBootstrap.Protected"
                , "System.Process"
                , "System.Timeout"
                ]
            mapM_
                ( \moduleName ->
                    assertBool
                        ("Lifecycle imports no process/protocol owner " <> moduleName)
                        (not (SourceGuard.importsModule moduleName lifecycleSource))
                )
                [ "HostBootstrap.Handoff.Protocol"
                , "HostBootstrap.Handoff.Receiver"
                , "HostBootstrap.Handoff.Relay"
                , "HostBootstrap.Protected"
                , "System.Process"
                , "System.Timeout"
                ]
            mapM_
                ( \identifier -> do
                    SourceGuard.countHaskellIdentifier identifier completionSource @?= 0
                    SourceGuard.countHaskellIdentifier identifier lifecycleSource @?= 0
                    SourceGuard.countHaskellIdentifier identifier receiverSource @?= 0
                )
                [ "createProcess"
                , "waitForProcess"
                , "terminateProcess"
                , "getProcessExitCode"
                , "timeout"
                , "signalProcess"
                , "interruptProcessGroupOf"
                , "ExitSuccess"
                , "ExitFailure"
                , "spawn"
                , "reap"
                ]
            SourceGuard.countHaskellIdentifier "LifecycleCompletion" protocolSource @?= 0
            SourceGuard.countHaskellIdentifier "LifecycleCompletion" relaySource @?= 0
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
            length (filter (== "HostBootstrap.Handoff.Completion") private) @?= 1
            length (filter (== "HostBootstrap.Handoff.Lifecycle") private) @?= 1
            assertBool
                "HostBootstrap.Handoff.Completion remains hidden"
                ("HostBootstrap.Handoff.Completion" `notElem` exposed)
            assertBool
                "HostBootstrap.Handoff.Lifecycle remains hidden"
                ("HostBootstrap.Handoff.Lifecycle" `notElem` exposed)
            traverse_
                ( \seam ->
                    assertBool
                        (seam <> " is absent from Cabal")
                        (seam `notElem` map (unwords . words) (lines cabalSource))
                )
                [ "HostBootstrap.Handoff.Completion.Testing"
                , "HostBootstrap.Handoff.Lifecycle.Testing"
                , "HostBootstrap.Handoff.Process.Testing"
                ]
    , testCase "the hidden handoff modules and sealed folds have exact production owners" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            receiverSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
            receiverInternalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver" </> "Internal.hs")
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
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
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.importsModule moduleName source
                        ]
                users identifier =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
            importers "HostBootstrap.Handoff.Internal"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Completion.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Teardown/Internal.hs"
                    ]
            importers "HostBootstrap.Handoff.Protocol"
                @?= [ "HostBootstrap/Handoff/Process.hs"
                    , "HostBootstrap/Handoff/Receiver.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Handoff/Transaction.hs"
                    ]
            importers "HostBootstrap.Handoff.Rooted"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Internal.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
                    , "HostBootstrap/Lifecycle/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Node.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    ]
            importers "HostBootstrap.Handoff.Recovery"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Teardown/Internal.hs"
                    ]
            importers "HostBootstrap.Handoff.Receiver"
                @?= [ "HostBootstrap/Authority/ProjectPlan/Internal.hs"
                    , "HostBootstrap/Command/LifecycleEntry.hs"
                    , "HostBootstrap/ProjectPlan/Child/Internal.hs"
                    ]
            importers "HostBootstrap.Handoff.Receiver.Internal"
                @?= [ "HostBootstrap/Authority/ProjectPlan/Internal.hs"
                    , "HostBootstrap/Handoff/Receiver.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/ProjectPlan/Child/Internal.hs"
                    ]
            importers "HostBootstrap.Handoff.Relay" @?= ["HostBootstrap/Handoff/Process.hs"]
            users "signRecoveryWireKernel"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Relay.hs"]
            users "signRootedPayloadBindingKernel"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Relay.hs"]
            users "signRecoveryChildPackageBindingKernel"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Relay.hs"]
            users "withVerifiedRootedPayloadBinding"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Receiver.hs"]
            users "withVerifiedRecoveryChildPackage"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Receiver.hs"]
            users "recoverySigningKernel"
                @?= [ "HostBootstrap/Handoff/Completion.hs"
                    , "HostBootstrap/Handoff/Internal.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            users "consumeRecoverySigningKernel"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Internal.hs"
                    , "HostBootstrap/Teardown/Internal.hs"
                    ]
            users "withReceivedHandoffEdge"
                @?= ["HostBootstrap/Handoff/Receiver.hs"]
            users "mkReceivedEdge"
                @?= [ "HostBootstrap/Handoff/Receiver.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    ]
            users "mkReceivedRecoveryDescent"
                @?= [ "HostBootstrap/Handoff/Receiver.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    ]
            users "withReceivedRecoveryDescent"
                @?= [ "HostBootstrap/Authority/ProjectPlan/Internal.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/ProjectPlan/Child/Internal.hs"
                    ]
            users "withConfigBrokerLink"
                @?= ["HostBootstrap/Handoff/Relay.hs"]
            users "withRecoveryBrokerLink"
                @?= ["HostBootstrap/Handoff/Relay.hs"]
            users "relayedBrokerLinkKernel"
                @?= ["HostBootstrap/Handoff/Relay.hs"]
            users "offerHandoffEdge"
                @?= [ "HostBootstrap/Handoff/Process.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            users "offerReverseDescentKernel"
                @?= [ "HostBootstrap/Handoff/Process.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            sort (normalizedModuleExports relayExports)
                @?= sort
                    [ "BrokerLink"
                    , "rootBrokerLink"
                    , "withConfigBrokerLink"
                    , "withRecoveryBrokerLink"
                    , "withNestedRecursiveHandoffRuntimeKernel"
                    , "receiveRootedLifecycleResponseThroughLink"
                    , "prepareLifecycleAcknowledgementThroughLink"
                    , "adoptLifecycleAcknowledgementThroughLink"
                    , "offerHandoffEdge"
                    , "offerReverseDescentKernel"
                    , "withReceivedLifecycleAcknowledgementKernel"
                    , "withReceivedRecoveryLifecycleAcknowledgementKernel"
                    , "withRootedOpenedResponseKernel"
                    , "withRootedTerminalReceiptKernel"
                    , "linkSignActivation"
                    , "EdgeAdmission"
                    , "RecoveryAdmission"
                    , "RelayError(..)"
                    , "relayErrorMessage"
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
            assertBool
                "the facade imports only the neutral rooted codec among private handoff owners"
                ( all
                    (\moduleName -> not (SourceGuard.importsModule moduleName handoffSource))
                    [ "HostBootstrap.Handoff.Completion"
                    , "HostBootstrap.Handoff.Protocol"
                    , "HostBootstrap.Handoff.Lifecycle"
                    , "HostBootstrap.Handoff.Receiver"
                    , "HostBootstrap.Handoff.Receiver.Internal"
                    , "HostBootstrap.Handoff.Relay"
                    ]
                    && SourceGuard.importsModule "HostBootstrap.Handoff.Rooted" handoffSource
                    && SourceGuard.countHaskellTokenSequence
                        ["module", "HostBootstrap", ".", "Handoff", ".", "Protocol"]
                        handoffSource
                        == 0
                )
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
                , "HostBootstrap.Handoff.Internal"
                , "HostBootstrap.Handoff.Lifecycle"
                , "HostBootstrap.Handoff.Protocol"
                , "HostBootstrap.Handoff.Receiver"
                , "HostBootstrap.Handoff.Receiver.Internal"
                , "HostBootstrap.Handoff.Relay"
                , "HostBootstrap.Handoff.Rooted"
                ]
    , testCase "received packages and branch-specific relay links remain closed" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            receiverSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
            receiverInternalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver" </> "Internal.hs")
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
            receivedEdge <-
                requiredSourceSection
                    "payload-neutral received edge"
                    "data ReceivedEdge scope"
                    "{- | One exact recovery-kind edge"
                    receiverInternalSource
            recoveryDescent <-
                requiredSourceSection
                    "sealed received recovery descent"
                    "data ReceivedRecoveryDescent"
                    "type role ReceivedRecoveryDescent"
                    receiverInternalSource
            receiverFold <-
                requiredSourceSection
                    "closed receiver fold signature"
                    "withReceivedHandoffEdge ::"
                    "withReceivedHandoffEdge\n    project channel key"
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
                "recovery callback has a fixed unit result"
                "recoveryWireDigest recoveryWireId verb -> (ByteString -> IO (Either ReceiverError ())) -> IO (Either Text ())"
                (normalizeWhitespace receiverFold)
            assertContains
                "the receiver itself has a fixed unit result"
                "IO (Either ReceiverError ())"
                (normalizeWhitespace receiverFold)
            SourceGuard.countHaskellIdentifier "result" recoveryFold @?= 0
            assertContains
                "the internal recovery callback derives four fixed raw views from retained values"
                "ReceivedEdge scope brokerGeneration -> ByteString -> ProjectVerb verb -> ByteString -> ByteString -> ByteString -> IO (Either Text ())"
                (normalizeWhitespace recoveryFold)
            assertContains
                "the internal recovery fold has a fixed unit result"
                "IO (Either Text ())"
                (normalizeWhitespace recoveryFold)
            assertFragmentsInOrder
                "the config bracket re-derives config evidence before deriving its link"
                [ "verifiedConfigPayload (receivedEdgeHandoff edge)"
                , "authenticated `seq` use authenticated (relayedBrokerLinkKernel edge)"
                ]
                (normalizeWhitespace configLink)
            SourceGuard.countHaskellIdentifier "result" configLink @?= 0
            assertFragmentsInOrder
                "the recovery bracket consumes the joint package before deriving its link"
                [ "withReceivedRecoveryDescent descent"
                , "use descent (relayedBrokerLinkKernel edge)"
                ]
                (normalizeWhitespace recoveryLink)
            SourceGuard.countHaskellIdentifier "result" recoveryLink @?= 0
    , testCase "Relay authenticates an opened four-field offer before transmission" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
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
                (normalizeWhitespace offerFlow)
            assertContains
                "the wire protocol keeps exactly four Offer fields"
                "offerFieldsOf offer authentication = [payload, token, binding, authentication]"
                (normalizeWhitespace offerShape)
            let normalizedAuthentication = normalizeWhitespace offerAuthenticationSource
            assertFragmentsInOrder
                "config evidence is the root-scope, installed key, and exact rooted binding"
                [ "rootedResult <- rootedBindingThroughLink link offer"
                , "Right rooted -> case handoffPayloadKind binding of"
                , "NarrowedProjectConfig -> pure (Right (authenticationPrelude <> frameWire rooted))"
                , "authenticationPrelude ="
                , "frameWire (renderAuthenticatedRootScope (linkAuthenticatedRootScope link))"
                , "frameWire (linkKeyDigest link)"
                ]
                normalizedAuthentication
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
                normalizedAuthentication
            assertFragmentsInOrder
                "recovery evidence frames the key, rooted binding, canonical projection, and grant"
                [ "frameWire (linkKeyDigest link)"
                , "frameWire rooted"
                , "frameWire (renderRecoveryProjectionBinding projection)"
                , "frameWire (recoveryWireGrantSignature grant)"
                ]
                normalizedAuthentication
            SourceGuard.countHaskellIdentifier "frameWire" offerAuthenticationSource @?= 6
            SourceGuard.countHaskellIdentifier "withSignedRecoveryThroughLink" offerAuthenticationSource @?= 1
            assertFragmentsInOrder
                "the parent advances only on the exact accepted payload digest"
                [ "[actualDigest]"
                , "actualDigest == expectedDigest"
                , "serveUntilDone (ParentServingAdmittedChild childFrame)"
                , "the child accepted a different payload digest"
                ]
                (normalizeWhitespace parentAcceptance)
    , testCase "the child process owner spawns one sanitized route and leaves nothing running" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            processSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Process.hs")
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
            routeSource <-
                readFile
                    (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Process" </> "Route.hs")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            processExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Process has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Process" processSource)
            let owner = normalizeWhitespace processSource
                relay = normalizeWhitespace relaySource
                route = normalizeWhitespace routeSource
                exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
            normalizedModuleExports processExports
                @?= [ "withForwardLifecycleChildProcess"
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
                [ "withLifecycleProcessRouteLaunchKernel route $ \\tool argv _interactive ->"
                , "case resolveMaybe config tool of"
                , "\"the route's host tool resolves to no absolute path\""
                , "Just exe -> spawned (absExePath exe) (map Text.unpack argv)"
                ]
                owner
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
                [ "signalChildGroup child sigTERM"
                , "lingering <- waitFor terminationGraceMicros child"
                , "Nothing -> signalChildGroup child sigKILL"
                , "Exception.try (waitForProcess child)"
                , "closeQuietly childStdin"
                , "closeQuietly childStdout"
                ]
                owner
            assertContains
                "the whole group is signalled rather than the process alone"
                "Just pid -> do signalled <- Exception.try (signalProcessGroup signal (fromIntegral pid))"
                owner
            assertContains
                "termination runs on every exit from the exchange"
                "Exception.bracket_ (pure ()) (terminateChildGroup child childStdin childStdout) (exchange childStdin childStdout serve)"
                owner
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
                "withLifecycleProcessRouteLaunchKernel route use = case route of LifecycleProcessRoute _ _ _ tool argv interactive -> use tool argv interactive"
                route
            assertBool
                "the process owner and the route stay inside their sprint line budgets"
                ( significantHaskellLineCount processSource < 400
                    && significantHaskellLineCount routeSource < 400
                )
    , testCase "the dedicated child receiver takes its protocol descriptors before any callback runs" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            receiverSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
            protocolSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Protocol.hs")
            transactionSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Transaction.hs")
            cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
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
                    "withIsolatedReceivedHandoffEdge\n    project key"
                    receiverSource
            receiverExports <-
                maybe
                    (assertFailure "HostBootstrap.Handoff.Receiver has no explicit export list")
                    pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Handoff.Receiver" receiverSource)
            let isolation = normalizeWhitespace isolationSource
                entryIsolation = normalizeWhitespace entryIsolationSource
                exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
            normalizedModuleExports receiverExports
                @?= [ "ReceivedEdge"
                    , "ReceivedRecoveryDescent"
                    , "withIsolatedReceivedHandoffEdge"
                    , "withReceivedHandoffEdge"
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
                "bracket openProtocolStdio closeProtocolStdio $ \\(inbound, outbound, savedIn, savedOut, sink) -> bracket_ (isolateGlobalStdio sink) (restoreGlobalStdio savedIn savedOut) (handoffChannel inbound outbound >>= use)"
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
                isolation
            assertContains
                "the callback reads the null device and writes to standard error"
                "isolateGlobalStdio sink = do hFlush stdout hDuplicateTo sink stdin hDuplicateTo stderr stdout"
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
                        (seam `notElem` map (unwords . words) (lines cabalSource))
                )
                [ "HostBootstrap.Handoff.Receiver.Testing"
                , "HostBootstrap.Handoff.Process.Testing"
                ]
            assertBool
                "the standard-I/O isolation stays inside its 400-line budget"
                (significantHaskellLineCount isolationSource <= 400)
    , testCase "Receiver verifies, classifies exhaustively, accepts, and only then enters a branch" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            receiverSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
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
                , "sendMessage channel afterOffer ChallengeTag"
                , "requireInstalledKey key signerKeyDigest"
                , "verifyHandoff key"
                , "classifyVerified authenticated channel requestId key evidence verified"
                , "sendMessage channel afterGrant AcceptedTag"
                , "[TextEncoding.encodeUtf8 acceptedDigest]"
                , "try (runTerminalAction channel afterAccepted requestId active branch)"
                ]
                (normalizeWhitespace exchangeSource)
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
                normalizedClassification
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
                normalizedClassification
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
                (normalizeWhitespace recoveryParser)
    , testCase "Relay owns one root-issued scope prelude and preserves it through every keyless link" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
            receiverInternalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver" </> "Internal.hs")
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
                construction = normalizeWhitespace linkConstruction
                authentication = normalizeWhitespace offerAuthenticationSource
                edge = normalizeWhitespace receivedEdge
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
                construction
            assertFragmentsInOrder
                "a relayed link copies the capsule retained by its authenticated parent edge"
                [ "relayedBrokerLinkKernel edge = BrokerLink"
                , "linkAuthenticatedRootScope = receivedEdgeAuthenticatedRootScope edge"
                ]
                construction
            assertFragmentsInOrder
                "every Offer authentication field starts with capsule then installed-key digest"
                [ "authenticationPrelude ="
                , "frameWire (renderAuthenticatedRootScope (linkAuthenticatedRootScope link))"
                , "frameWire (linkKeyDigest link)"
                , "authenticationPrelude <> frameWire rooted"
                , "frameWire (renderRecoveryProjectionBinding projection)"
                , "frameWire (recoveryWireGrantSignature grant)"
                ]
                authentication
            assertFragmentsInOrder
                "ReceivedEdge retains the same typed capsule beside the verified edge"
                [ "receivedRootScope :: AuthenticatedRootScope scope"
                , "receivedHandoff :: VerifiedHandoff scope brokerGeneration"
                , "receivedEdgeAuthenticatedRootScope ::"
                , "receivedEdgeAuthenticatedRootScope = receivedRootScope"
                , "mkReceivedEdge :: AuthenticatedRootScope scope -> VerifiedHandoff scope brokerGeneration"
                ]
                edge
            SourceGuard.countHaskellIdentifier "signAuthenticatedRootScopeKernel" linkConstruction @?= 1
            SourceGuard.countHaskellIdentifier "ProjectSigningKey" relaySource @?= 0
            SourceGuard.countHaskellIdentifier "RecoverySigningKernel" brokerLink @?= 0
    , testCase "Receiver verifies the leading scope capsule before any binding, challenge, or payload semantics" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            receiverSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
            receiverSignature <-
                requiredSourceSection
                    "closed four-arm scope-first receiver signature"
                    "withReceivedHandoffEdge ::"
                    "withReceivedHandoffEdge\n    project channel key"
                    receiverSource
            outerExchange <-
                requiredSourceSection
                    "scope-first outer exchange"
                    "withReceivedHandoffEdge\n    project channel key"
                    "{- | Continue only after the capsule verifier has fixed the execution scope."
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
            let signature = normalizeWhitespace receiverSignature
                outer = normalizeWhitespace outerExchange
                scoped = normalizeWhitespace scopedExchange
                parser = normalizeWhitespace offerParser
            assertFragmentsInOrder
                "the hidden API accepts installed identity and key and exposes four closed branches"
                [ "InstalledProjectIdentity projectId"
                , "ProjectVerificationKey"
                , "ReceivedEdge (Production projectId) receivedGeneration"
                , "ReceivedRecoveryDescent (Production projectId) receivedGeneration"
                , "forall runId receivedGeneration. ReceivedEdge (Harness projectId runId) receivedGeneration"
                , "forall runId receivedGeneration planDigest parentFrame childFrame recoveryWireDigest recoveryWireId verb. ReceivedRecoveryDescent (Harness projectId runId)"
                ]
                signature
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
                outer
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
                , "classifyVerified authenticated channel requestId key evidence verified"
                ]
                scoped
    , testCase "scope-first transport remains acyclic and leaves Protocol and facade frozen" $
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            (handoffSource, handoffDigest) <-
                readFrozenSource (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            (protocolSource, protocolDigest) <-
                readFrozenSource (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Protocol.hs")
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
            receiverSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
            receiverInternalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver" </> "Internal.hs")
            cabalRows <- handoffPackageRows =<< readFile (packageRoot </> "hostbootstrap-core.cabal")
            let users identifier =
                    sort
                        [ sourcePath sourceRoot path
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
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Receiver.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Lifecycle/FrameExecutor.hs"
                    ]
            users "signAuthenticatedRootScopeKernel"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Relay.hs"]
            users "withAuthenticatedRootScopeFromWire"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Receiver.hs"]
            users "receivedEdgeAuthenticatedRootScope"
                @?= [ "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    ]
            significantHaskellLineCount protocolSource @?= 526
            protocolDigest @?= "04f069429b164e3d6b99ff68b900996c090e73947bc5c874859049ce49a696a4"
            handoffDigest @?= "6bbbd828b453173cf8f4be9cd1989eb0a6ddfc2cc5a9639b29d76558c0121fe5"
            cabalRows @?= frozenHandoffPackageRows
            mapM_
                (\source -> do
                    SourceGuard.countHaskellTokenSequence ["data", "AuthenticatedRootScope"] source @?= 0
                    SourceGuard.countHaskellTokenSequence ["newtype", "AuthenticatedRootScope"] source @?= 0
                )
                [relaySource, receiverSource, receiverInternalSource, protocolSource]
    , testCase "rooted signing stays live at the root, canonical through relays, and shapes both Offer branches" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
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
                construction = normalizeWhitespace linkConstruction
                route = normalizeWhitespace rootedRoute
                served = normalizeWhitespace dispatch
                authenticated = normalizeWhitespace authentication
            assertContains
                "BrokerLink retains an exact-offer rooted-signing route, not a signer"
                "linkRootedBindingRaw :: RequesterPath -> HandoffOffer scope brokerGeneration -> IO (Either RelayError ByteString)"
                broker
            SourceGuard.countHaskellIdentifier "RecoverySigningKernel" brokerLink @?= 0
            assertFragmentsInOrder
                "only the root route reaches the live rooted signer while relayed links forward"
                [ "linkRootedBindingRaw = \\_ -> rootSignRootedBinding broker"
                , "relayedBrokerLinkKernel edge = BrokerLink"
                , "linkRootedBindingRaw = \\downstream -> relayRootedBinding channel request (currentFrame : downstream)"
                ]
                construction
            assertFragmentsInOrder
                "the strict root route derives config or recovery-package signing from the exact offer"
                [ "rootSignRootedBinding broker offer = case handoffPayloadKind (handoffOfferBinding offer) of"
                , "NarrowedProjectConfig -> renderSigned (signRootedPayloadBindingKernel recoverySigningKernel broker offer payload)"
                , "RecoveryAdapterWire -> case Recovery.recoveryChildPackageFromWireKernel payload of"
                , "signRecoveryChildPackageBindingKernel recoverySigningKernel broker offer package"
                , "Right . renderRootedPayloadBinding"
                ]
                route
            assertFragmentsInOrder
                "a keyless route sends one closed three-frame header and the exact offer through the existing tags"
                [ "frameWire rootedSigningDomain"
                , "frameWire rootedSigningVersion"
                , "frameWire (rootedSigningKindName (handoffPayloadKind (handoffOfferBinding offer)))"
                , "renderRequesterEnvelope path (renderRootedSigningHeader offer)"
                , "transmit channel RecoveryRequestTag request [enveloped, offerWireOf offer]"
                , "await channel request RecoveryResponseTag"
                , "Right [rooted] -> pure (Right rooted)"
                ]
                route
            assertFragmentsInOrder
                "each serving parent re-adopts and kind-checks the exact offer before forwarding"
                [ "rootedSigningKind requestHeader"
                , "adoptRelayedOffer (linkRoute link) wire"
                , "handoffPayloadKind (handoffOfferBinding offer) /= kind"
                , "requireServedRequester childFrame (handoffParentFrame (handoffOfferBinding offer)) path"
                , "linkRootedBindingRaw link path offer"
                , "transmit channel RecoveryResponseTag request [response]"
                ]
                served
            assertFragmentsInOrder
                "rooted signing follows exact Offer construction and config emits capsule, key, rooted binding"
                [ "rootedResult <- rootedBindingThroughLink link offer"
                , "Right rooted -> case handoffPayloadKind binding of"
                , "NarrowedProjectConfig -> pure (Right (authenticationPrelude <> frameWire rooted))"
                , "frameWire (renderAuthenticatedRootScope (linkAuthenticatedRootScope link))"
                , "frameWire (linkKeyDigest link)"
                ]
                authenticated
            assertFragmentsInOrder
                "recovery emits capsule, key, rooted binding, projection, then grant"
                [ "authenticationPrelude <> frameWire rooted"
                , "frameWire (renderRecoveryProjectionBinding projection)"
                , "frameWire (recoveryWireGrantSignature grant)"
                ]
                authenticated
            SourceGuard.countHaskellIdentifier "frameWire" authentication @?= 6
            SourceGuard.countHaskellIdentifier "ProjectSigningKey" relaySource @?= 0
    , testCase "Receiver joins rooted config and complete recovery packages before callbacks and refuses adapter-only descent" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            receiverSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
            receiverInternalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver" </> "Internal.hs")
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
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
                    "data ReceivedRecoveryDescent"
                    "type role ReceivedRecoveryDescent"
                    receiverInternalSource
            adapterOnly <-
                requiredSourceSection
                    "the package-valued reverse route"
                    "offerReverseDescentKernel ::"
                    "offerAuthentication ::"
                    relaySource
            let classified = normalizeWhitespace classification
                parsers = normalizeWhitespace evidenceParsers
                retained = normalizeWhitespace carrier
                eliminated = normalizeWhitespace receiverInternalSource
                refused = normalizeWhitespace adapterOnly
            assertFragmentsInOrder
                "config admits one exact rooted frame before deriving config evidence or entering its callback"
                [ "NarrowedProjectConfig -> do"
                , "rootedBytes <- configEvidence evidence"
                , "withVerifiedRootedPayloadBinding verified rootedBytes id"
                , "verifiedConfigPayload verified"
                , "authenticatedConfigDigest admitted"
                , "mkReceivedEdge authenticated verified channel requestId"
                , "useConfig edge admitted sendReport"
                ]
                classified
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
                classified
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
                parsers
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
                retained
            SourceGuard.countHaskellIdentifier "ByteString" carrier @?= 0
            SourceGuard.countHaskellIdentifier "VerifiedRecoveryHandoff" carrier @?= 0
            assertContains
                "the six-argument eliminator derives package, adapter, projection, and grant bytes in legacy positions"
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
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffDigest <- frozenSourceDigest (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            (protocolSource, protocolDigest) <-
                readFrozenSource (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Protocol.hs")
            recoverySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Recovery.hs")
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
            receiverSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver.hs")
            receiverInternalSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Receiver" </> "Internal.hs")
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
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                frozenCarrierRelayLines = 1852 :: Int
                frozenCarrierReceiverLines = 579
                frozenCarrierReceiverInternalLines = 122
                sprintDelta =
                    (frozenCarrierRelayLines - 1733)
                        + (frozenCarrierReceiverLines - 570)
                        + (frozenCarrierReceiverInternalLines - 105)
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
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Rooted.hs"
                    ]
            users "RecoveryChildPackage"
                @?= [ "HostBootstrap/Handoff.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Receiver/Internal.hs"
                    , "HostBootstrap/Handoff/Recovery.hs"
                    ]
            users "signRootedPayloadBindingKernel"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Relay.hs"]
            users "signRecoveryChildPackageBindingKernel"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Relay.hs"]
            users "withVerifiedRootedPayloadBinding"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Receiver.hs"]
            users "withVerifiedRecoveryChildPackage"
                @?= ["HostBootstrap/Handoff.hs", "HostBootstrap/Handoff/Receiver.hs"]
            users "recoveryChildPackageKernel"
                @?= [ "HostBootstrap/Handoff/Recovery.hs"
                    , "HostBootstrap/Teardown/Internal.hs"
                    ]
            assertContains
                "RecoveryAdmission still authenticates only one exact adapter"
                "RecoveryProjectionBindingInput planDigest parentFrame childFrame -> IO (Either Text ByteString)"
                (normalizeWhitespace admission)
            (frozenCarrierRelayLines, frozenCarrierReceiverLines, frozenCarrierReceiverInternalLines)
                @?= (1852, 579, 122)
            (frozenCarrierRelayLines - 1733, frozenCarrierReceiverLines - 570, frozenCarrierReceiverInternalLines - 105)
                @?= (119, 9, 17)
            sprintDelta @?= 145
            assertBool "the three-owner attribution remains within 400 lines" (sprintDelta <= 400)
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
                (normalizeWhitespace offerBound)
            assertFragmentsInOrder
                "the receiver bounds payload before key, binding, or branch interpretation"
                [ "requireOfferPayloadBound payload"
                , "takeHandoffFrame authentication"
                , "requireInstalledKey key offeredKeyDigest"
                , "withHandoffBindingFromWire scope bindingBytes"
                , "maxEmbeddedOfferPayloadBytes = 7 * 1024 * 1024"
                ]
                (normalizeWhitespace receiveBound)
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
                (normalizeWhitespace protocolBound)
            assertBool
                "the embedded Offer package bound is strictly smaller than both standalone and protocol bounds"
                (7 * 1024 * 1024 < (8 * 1024 * 1024 :: Int))
            significantHaskellLineCount protocolSource @?= 526
            protocolDigest @?= "04f069429b164e3d6b99ff68b900996c090e73947bc5c874859049ce49a696a4"
            handoffDigest @?= "6bbbd828b453173cf8f4be9cd1989eb0a6ddfc2cc5a9639b29d76558c0121fe5"
            cabalRows @?= frozenHandoffPackageRows
    , testCase "the token is forced before one live validation/admission/signing sequence" $
        withHandoffSourceRoot $ \_packageRoot sourceRoot -> do
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
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
                normalizedSigner
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
        withHandoffSourceRoot $ \packageRoot sourceRoot -> do
            sources <- readHaskellSources sourceRoot
            handoffSource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff.hs")
            runtimeSource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Runtime.hs")
            relaySource <- readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
            entrySource <-
                readFile (sourceRoot </> "HostBootstrap" </> "Command" </> "LifecycleEntry.hs")
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
                    "{- | Publish, send, and durably receive one exact child lifecycle report."
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
            librarySource <-
                maybe
                    (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                    pure
                    (mainLibraryStanza cabalSource)
            let runtime = normalizeWhitespace runtimeSource
                rootArm = normalizeWhitespace rootArmSource
                nestedArm = normalizeWhitespace nestedArmSource
                eliminator = normalizeWhitespace eliminatorSource
                relayInstaller = normalizeWhitespace relayInstallerSource
                entryInstaller = normalizeWhitespace entryInstallerSource
                publicHandoff = normalizedModuleExports handoffExports
                exposed = fieldModules "exposed-modules:" librarySource
                private = fieldModules "other-modules:" librarySource
                users identifier =
                    sort
                        [ sourcePath sourceRoot path
                        | (path, source) <- sources
                        , SourceGuard.countHaskellIdentifier identifier source > 0
                        ]
                importers moduleName =
                    sort
                        [ sourcePath sourceRoot path
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
                rootArm
            assertFragmentsInOrder
                "every root coordinate is derived from the admitted root environment, not a caller"
                [ "project = rootAuthorityProjectName root"
                , "tag = handoffScopeTag scope"
                , "store = rootAuthorityStoreIdentity root"
                , "generation = brokerEpochWord (rootAuthorityEpoch root)"
                , "keyDigest = TextEncoding.encodeUtf8 (verificationKeyDigest (rootBrokerVerificationKey broker))"
                ]
                rootArm
            assertFragmentsInOrder
                "the nested arm requires the authenticated frame the relayed route names"
                [ "verbName == handoffVerb binding"
                , "brokerRouteCurrentFrame route == Just frame"
                , "not (Text.null frame)"
                , "requireIdentity project tag store generation keyDigest verbName"
                , "pure (NestedRecursiveHandoffRuntime verb project tag store generation keyDigest frame)"
                ]
                nestedArm
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
                eliminator
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
                relayInstaller
            assertFragmentsInOrder
                "only a sealed root entry installs the root arm, and a child entry is refused"
                [ "RootUpLifecycleEntry root verb _ _ _ _ _ _ -> install root verb"
                , "RootDownLifecycleEntry root verb _ _ _ _ _ _ _ -> install root verb"
                , "RootDestroyLifecycleEntry root verb _ _ _ _ _ _ _ -> install root verb"
                , "ChildUpLifecycleEntry{} -> keylessArmRefusal"
                , "ChildRecoveryLifecycleEntry{} -> keylessArmRefusal"
                , "rootRecursiveHandoffRuntimeKernel broker scope (rootBrokerRoute broker) root verb"
                ]
                entryInstaller
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
                @?= [ "HostBootstrap/Command/LifecycleEntry.hs"
                    , "HostBootstrap/Handoff/Runtime.hs"
                    ]
            users "nestedRecursiveHandoffRuntimeKernel"
                @?= [ "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Handoff/Runtime.hs"
                    ]
            users "withRecursiveHandoffRuntimeKernel"
                @?= [ "HostBootstrap/Handoff/Runtime.hs"
                    , "HostBootstrap/Lifecycle/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Node.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    ]
            importers "HostBootstrap.Handoff.Runtime"
                @?= [ "HostBootstrap/Command/LifecycleEntry.hs"
                    , "HostBootstrap/Handoff/Process/Route.hs"
                    , "HostBootstrap/Handoff/Relay.hs"
                    , "HostBootstrap/Lifecycle/Rooted.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Node.hs"
                    , "HostBootstrap/Lifecycle/Rooted/Receipt.hs"
                    ]
            assertBool
                "the installed runtime stays inside its 400-line sprint budget"
                (significantHaskellLineCount runtimeSource <= 400)
    ]

-- ---------------------------------------------------------------------------
-- Fixtures

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

'doesFileExist' follows symbolic links, so it reports 'False' for a /dangling/
one and the path would survive cleanup — which is exactly how a single failed
run used to poison the destination for every later run in the same build tree.
'doesPathExist' asks about the name itself.
-}
removeIfPresent :: FilePath -> IO ()
removeIfPresent path = do
    present <- doesPathExist path
    when present (removePathForcibly path)

dropFirstFrame :: ByteString.ByteString -> ByteString.ByteString
dropFirstFrame = ByteString.drop (ByteString.length (frameWire childPayload))

withHandoffSourceRoot :: (FilePath -> FilePath -> IO result) -> IO result
withHandoffSourceRoot use = do
    cwd <- getCurrentDirectory
    repoRoot <-
        findRepoRoot cwd
            >>= maybe
                (assertFailure ("could not locate repo root from " <> cwd))
                pure
    let packageRoot = repoRoot </> "core" </> "hostbootstrap-core"
    use packageRoot (packageRoot </> "src")

readHaskellSources :: FilePath -> IO [(FilePath, String)]
readHaskellSources directory = do
    entries <- listDirectory directory
    fmap concat . traverse visit $ sort entries
  where
    visit entry = do
        let path = directory </> entry
        nested <- doesDirectoryExist path
        if nested
            then readHaskellSources path
            else
                if takeExtension path == ".hs"
                    then do
                        source <- readFile path
                        pure [(path, source)]
                    else pure []

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

{- | The rows of the package description a handoff sprint owns: its own module
rows in the main library, and that library's dependency set.

§ C: a sprint freezes the bytes of a module, a stanza, or a set of rows it is
responsible for, and may not freeze a whole shared file whose other parts belong
to other phases. A digest over the complete package description makes every
sprint that adds a module anywhere in the package break the evidence of every
handoff sprint that froze it — a coupling no dependency edge justifies and that
numerical order cannot express. These rows prove the same two things about the
same subject: this sprint introduced no handoff module and no dependency.
-}
handoffPackageRows :: String -> IO [String]
handoffPackageRows cabalText = do
    library <-
        maybe
            (assertFailure "hostbootstrap-core.cabal has no main library stanza")
            pure
            (mainLibraryStanza cabalText)
    pure
        ( sort
            [ moduleName
            | field <- ["exposed-modules:", "other-modules:"]
            , moduleName <- fieldModules field library
            , "HostBootstrap.Handoff" `isPrefixOf` moduleName
            ]
            ++ libraryDependencyNames library
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
    , "HostBootstrap.Handoff.Lifecycle"
    , "HostBootstrap.Handoff.Process"
    , "HostBootstrap.Handoff.Process.Route"
    , "HostBootstrap.Handoff.Protocol"
    , "HostBootstrap.Handoff.Receiver"
    , "HostBootstrap.Handoff.Receiver.Internal"
    , "HostBootstrap.Handoff.Recovery"
    , "HostBootstrap.Handoff.Relay"
    , "HostBootstrap.Handoff.Rooted"
    , "HostBootstrap.Handoff.Runtime"
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
    , "hostbootstrap-core:cluster-backend-internal"
    , "hostbootstrap-core:colima-backend-internal"
    , "hostbootstrap-core:effect-internal"
    , "hostbootstrap-core:harness-lifecycle-internal"
    , "memory"
    , "optparse-applicative"
    , "process"
    , "safe-exceptions"
    , "text"
    , "unix"
    ]

mainLibraryStanza :: String -> Maybe String
mainLibraryStanza cabalText =
    case dropWhile ((/= "library") . trim) (lines cabalText) of
        [] -> Nothing
        _library : rest -> Just (unlines (takeWhile isLibraryContinuation rest))
  where
    isLibraryContinuation [] = True
    isLibraryContinuation line@(firstCharacter : _) =
        null (trim line) || isSpace firstCharacter

fieldModules :: String -> String -> [String]
fieldModules field = go . lines
  where
    go [] = []
    go (line : rest)
        | trim line == field =
            let fieldIndent = indentation line
                (continuation, remaining) =
                    span
                        (\next -> null (trim next) || indentation next > fieldIndent)
                        rest
             in moduleTokens continuation <> go remaining
        | otherwise = go rest
    moduleTokens =
        filter ("HostBootstrap." `isPrefixOfText`)
            . map (filter (/= ','))
            . words
            . unlines
    isPrefixOfText prefix value = Text.pack prefix `Text.isPrefixOf` Text.pack value

indentation :: String -> Int
indentation = length . takeWhile isSpace

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

normalizeWhitespace :: String -> String
normalizeWhitespace = unwords . words

significantHaskellLineCount :: String -> Int
significantHaskellLineCount = length . filter (not . all isSpace) . stripComments 0 . lines
  where
    stripComments :: Int -> [String] -> [String]
    stripComments _ [] = []
    stripComments depth (sourceLine : remaining) =
        let (nextDepth, code) = stripLine depth sourceLine
         in code : stripComments nextDepth remaining

    stripLine :: Int -> String -> (Int, String)
    stripLine = go

    go :: Int -> String -> (Int, String)
    go depth [] = (depth, [])
    go 0 ('-' : '-' : _) = (0, [])
    go 0 ('{' : '-' : '#' : remaining) =
        let (nextDepth, code) = go 0 remaining
         in (nextDepth, "{-#" <> code)
    go depth ('{' : '-' : remaining) = go (depth + 1) remaining
    go depth ('-' : '}' : remaining)
        | depth > 0 = go (depth - 1) remaining
    go 0 (character : remaining) =
        let (nextDepth, code) = go 0 remaining
         in (nextDepth, character : code)
    go depth (_ : remaining) = go depth remaining

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

assertFragmentsInOrder :: String -> [String] -> String -> IO ()
assertFragmentsInOrder label fragments source =
    assertBool label (go (map Text.pack fragments) (Text.pack source))
  where
    go [] _ = True
    go (fragment : remaining) input =
        let (_before, fromFragment) = Text.breakOn fragment input
         in not (Text.null fromFragment)
                && go remaining (Text.drop (Text.length fragment) fromFragment)

expectRight :: (Show err) => Either err value -> IO value
expectRight (Right value) = pure value
expectRight (Left failure) = assertFailure ("expected success, got " <> show failure)

expectRightIO :: (Show err) => Either err value -> IO value
expectRightIO = expectRight

expectSignatureRefusal :: (Show value) => Either HandoffError value -> IO ()
expectSignatureRefusal outcome = case outcome of
    Left HandoffSignatureInvalid -> pure ()
    other -> assertFailure ("expected a signature refusal, got " <> show other)

expectBindingRefusal :: (Show value) => Either HandoffError value -> IO ()
expectBindingRefusal outcome = case outcome of
    Left (HandoffBindingMismatch _) -> pure ()
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
