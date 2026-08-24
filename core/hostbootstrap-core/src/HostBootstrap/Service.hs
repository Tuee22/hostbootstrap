{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Opaque typed service definitions and jointly finalized role codecs.

A definition binds its identity, typed config projection, reflected role-wire
schema, and handler in one value. Finalization hashes the closed registry
manifest into a fresh 'ProjectCodec' specification identity, then stamps every
opaque 'RoleCodec' with that same digest. There is no separately supplied
string selector and no way for package consumers to choose the hidden role
field type.
-}
module HostBootstrap.Service (
    ServiceId,
    serviceId,
    serviceIdText,
    ServiceDefinition,
    ServiceHandler,
    ProgramServiceHandler,
    ServiceResourceBackend (..),
    serviceDefinition,
    serviceProgramDefinition,
    serviceDeclaredEffects,
    ServiceRegistry,
    ServiceRegistryError (..),
    emptyServiceRegistry,
    singletonServiceRegistry,
    serviceRegistry,
    mergeServiceRegistries,
    serviceVariantNames,
    FinalizedServiceRegistry,
    withFinalizedServiceRegistry,
    finalizedServiceVariantNames,
    serviceRoleSchemaFamilies,
    withSelectedServiceRequest,
    selectServiceAction,
    withSelectedServiceProgram,
    withDecodedServiceProgram,
    ServiceActivationRevision,
    serviceActivationRevision,
    serviceActivationRevisionPath,
    ServiceActivationError (..),
    serviceActivationErrorMessage,
    installServiceActivationRevision,
    installRelayedServiceActivationRevision,
    withInstalledServiceActivation,
    ServiceRuntimeError (..),
    serviceRuntimeErrorMessage,
    runInstalledServiceProgram,
)
where

import Control.Exception.Safe (tryAny)
import qualified Crypto.Hash as Hash
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (group, sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TextEncoding
import Dhall (FromDhall, ToDhall)
import qualified Dhall
import HostBootstrap.Activation (
    ActivationBroker,
    ActivationError,
    ActivationGrant,
    ActivationManifest (..),
    ActivationVerificationKey,
    MeasuredInstance,
    RuntimeMeasurement (..),
    VerifiedRuntimeRoleActivation,
    activationConfigDigest,
    activationErrorMessage,
    activationGrantSignature,
    activationManifestFromWire,
    activationSecretDigestFromBytes,
    activationService,
    activationSpecDigest,
    activationVerificationKeyBytes,
    adoptRelayedActivationGrant,
    renderActivationManifest,
    signActivationManifest,
    verifyRuntimeRoleActivation,
 )
import HostBootstrap.Config.Class (
    ProjectCodec,
    projectCodecSpecDigest,
    withFinalizedProjectCodec,
 )
import HostBootstrap.Config.Fields (
    LocalContextView,
    ScopeKind (..),
    decodeRoleWire,
    roleCodecSchemaText,
 )
import HostBootstrap.Config.Fields.Internal (
    FrameworkValidation (..),
    RoleCodec (..),
    RoleParams (..),
    RuntimeRoleWire (..),
    ValidatedServiceRequest (..),
    WireKind (ServiceRoleWire),
 )
import HostBootstrap.Config.Schema.Internal (withRecoverySpecReindexKernel)
import HostBootstrap.Dhall.Gen (
    CodecWitness,
    autoCodecWitness,
    codecSchemaText,
    requireCodecWitness,
 )
import HostBootstrap.Protected (
    ProtectedStore,
    protectedErrorMessage,
    withProtectedEntry,
 )
import HostBootstrap.RoleLifecycle (
    DeclaredEffects,
    RoleAdmissionOutcome (..),
    RoleEffect,
    RoleEngine (..),
    RoleExitReport,
    RoleServeOutcome (..),
    authorizeServiceEffects,
    declaredEffectList,
    readyRoleHandleNames,
    resumeRuntimeRolePlanOpenForRequest,
    roleLifecycleErrorMessage,
    runRoleLifecycle,
    verifyRolePlanDraft,
    withRoleLifecycleAdmission,
    withRuntimeRolePlanForRequest,
 )
import HostBootstrap.Service.Internal (
    FinalizedServiceDefinition (FinalizedServiceDefinition),
    FinalizedServiceRegistry (FinalizedServiceRegistry),
    ProgramServiceHandler,
    ServiceAction (LegacyServiceAction, ProgramServiceAction),
    ServiceHandler,
    ServiceId (ServiceId),
    ServiceResourceBackend (..),
    reindexFinalizedServiceRegistryKernel,
 )
import HostBootstrap.Service.Program (
    ServiceBackend,
    ServiceProgram,
    interpretServiceProgramWithReady,
    readyServiceHandles,
    serviceProgramErrorMessage,
 )
import System.Directory (
    createDirectory,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    renameDirectory,
    renameFile,
 )
import System.FilePath (isAbsolute, takeFileName, (</>))
import System.IO (BufferMode (NoBuffering), IOMode (WriteMode), hFlush, hSetBuffering, withBinaryFile)

serviceId :: String -> Either String ServiceId
serviceId raw
    | null raw = Left "service identity must not be empty"
    | any invalid raw = Left ("service identity is not a stable token: " ++ show raw)
    | otherwise = Right (ServiceId raw)
  where
    invalid c = not (c == '-' || c == '_' || c == '.' || c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z')

serviceIdText :: ServiceId -> String
serviceIdText (ServiceId value) = value

{- | One service's inseparable scope-polymorphic config projection, role-field
codec, and handler. 'Nothing' means this definition is not selected by the
effective config.

The registry is indexed by the whole project config /family/, not by one
already-selected scope. A definition therefore has to project the same role
from every @cfg scope@. Finalization instantiates that projection only after its
caller has selected the Production or exact Harness codec.
-}
data ServiceDefinition cfg
    = forall fields effects.
        ServiceDefinition
        ServiceId
        (forall scope. cfg scope -> Either String (Maybe fields))
        (DeclaredEffects effects)
        (ServiceAction fields effects)
        (CodecWitness (RuntimeRoleWire fields))

{- | Define one service, including __the effect row it declares__.

The row is part of the definition rather than a separate table because the
registry is what fixes what a handler may do: 'authorizeServiceEffects' admits a
declared row only when the signed placement permits every member, and it carries
the /declared/ row forward rather than the ceiling. A role that declares no
exclusive effect therefore does not inherit its ceiling's lease requirement.

The row is a 'DeclaredEffects' — the term-level twin of the type-level list — so
what the definition declares and what the type says cannot disagree.
-}
serviceDefinition ::
    forall fields effects cfg.
    (FromDhall fields, ToDhall fields) =>
    ServiceId ->
    (forall scope. cfg scope -> Either String (Maybe fields)) ->
    DeclaredEffects effects ->
    ServiceHandler fields ->
    ServiceDefinition cfg
serviceDefinition identity project effects run =
    ServiceDefinition
        identity
        project
        effects
        (LegacyServiceAction run)
        ( requireCodecWitness
            ("RuntimeRoleWire/" ++ serviceIdText identity)
            (autoCodecWitness @(RuntimeRoleWire fields))
        )

{- | Define a service whose handler is a closed effect-indexed program.

The backend is stored in the same existential package as the handler and its
declared row.  Finalization and selection therefore cannot pair a program with
another payload family's interpreter.
-}
serviceProgramDefinition ::
    forall fields effects payload cfg.
    (FromDhall fields, ToDhall fields) =>
    ServiceId ->
    (forall scope. cfg scope -> Either String (Maybe fields)) ->
    DeclaredEffects effects ->
    ServiceResourceBackend ->
    ServiceBackend payload ->
    ProgramServiceHandler payload effects fields ->
    ServiceDefinition cfg
serviceProgramDefinition identity project effects resources backend run =
    ServiceDefinition
        identity
        project
        effects
        (ProgramServiceAction resources backend run)
        ( requireCodecWitness
            ("RuntimeRoleWire/" ++ serviceIdText identity)
            (autoCodecWitness @(RuntimeRoleWire fields))
        )

{- | The effect row a definition declares, as the term-level list.

This is what a caller compares against a signed ceiling. It reads the row off the
type rather than off a second source, so there is no way for the two to drift.
-}
serviceDeclaredEffects :: ServiceDefinition cfg -> [RoleEffect]
serviceDeclaredEffects (ServiceDefinition _ _ effects _ _) = declaredEffectList effects

-- | An opaque duplicate-free registry.
newtype ServiceRegistry cfg = ServiceRegistry [ServiceDefinition cfg]

type role ServiceRegistry nominal

data ServiceRegistryError
    = DuplicateServiceIds [ServiceId]
    deriving (Eq, Show)

emptyServiceRegistry :: ServiceRegistry cfg
emptyServiceRegistry = ServiceRegistry []

singletonServiceRegistry :: ServiceDefinition cfg -> ServiceRegistry cfg
singletonServiceRegistry definition = ServiceRegistry [definition]

serviceRegistry :: [ServiceDefinition cfg] -> Either ServiceRegistryError (ServiceRegistry cfg)
serviceRegistry definitions =
    case duplicateIds definitions of
        [] -> Right (ServiceRegistry definitions)
        found -> Left (DuplicateServiceIds found)

mergeServiceRegistries ::
    ServiceRegistry cfg ->
    ServiceRegistry cfg ->
    Either ServiceRegistryError (ServiceRegistry cfg)
mergeServiceRegistries (ServiceRegistry left) (ServiceRegistry right) =
    serviceRegistry (left ++ right)

serviceVariantNames :: ServiceRegistry cfg -> [String]
serviceVariantNames (ServiceRegistry definitions) =
    [serviceIdText identity | ServiceDefinition identity _ _ _ _ <- definitions]

{- | Jointly finalize the full project codec and the closed service registry.
The rank-2 continuation prevents callers from selecting or reusing the fresh
@specDigest@ identity.
-}
withFinalizedServiceRegistry ::
    ScopeKind ->
    ProjectCodec scope initialDigest cfgFamily ->
    ServiceRegistry cfgFamily ->
    ( forall specDigest.
      ProjectCodec scope specDigest cfgFamily ->
      FinalizedServiceRegistry scope specDigest (cfgFamily scope) ->
      result
    ) ->
    result
withFinalizedServiceRegistry scopeKind codec registry use =
    withFinalizedProjectCodec codec (registryManifest registry) $ \finalCodec ->
        use
            finalCodec
            ( FinalizedServiceRegistry
                (projectCodecSpecDigest finalCodec)
                (map (finalizeDefinition finalCodec) definitions)
            )
  where
    ServiceRegistry definitions = registry
    finalizeDefinition finalCodec (ServiceDefinition identity project effects run wireCodec) =
        FinalizedServiceDefinition
            identity
            project
            effects
            run
            RoleCodec
                { internalRoleName = T.pack (serviceIdText identity)
                , internalRoleScopeKind = scopeKind
                , internalRoleSpecDigest = projectCodecSpecDigest finalCodec
                , internalRoleWireCodec = wireCodec
                }

finalizedServiceVariantNames ::
    FinalizedServiceRegistry scope specDigest cfg ->
    [String]
finalizedServiceVariantNames (FinalizedServiceRegistry _ definitions) =
    [serviceIdText identity | FinalizedServiceDefinition identity _ _ _ _ <- definitions]

{- | Render the role-wire schema registry as distinct descriptive Production
and Harness families. Empty registries have a structured explicit result.
-}
serviceRoleSchemaFamilies ::
    FinalizedServiceRegistry scope specDigest cfg ->
    Text
serviceRoleSchemaFamilies registry =
    T.intercalate
        "\n\n"
        [ renderFamily "Production"
        , renderFamily "Harness"
        ]
  where
    renderFamily family =
        T.unlines
            ( ("service schema family " <> family <> ":")
                : case schemas of
                    [] -> ["  services = []", "  schemas = []"]
                    _ ->
                        concatMap
                            ( \(name, schema) ->
                                [ "  - service: " <> name
                                , "    wire: ServiceRoleWire"
                                , "    schema: " <> T.replace "\n" "\n      " schema
                                ]
                            )
                            schemas
            )
    schemas =
        [ (T.pack (serviceIdText identity), roleCodecSchemaText codec)
        | FinalizedServiceDefinition identity _ _ _ codec <- definitions
        ]
    FinalizedServiceRegistry _ definitions = registry

{- | Structurally project exactly one selected role into an opaque request.
The caller supplies the digest of the already-verified local config/secret
bundle; fresh @configId@ and @secretDigest@ identities are minted only inside
the rank-2 continuation. The wire contains the safe framework view and the
selected service fields, never the full project config.
-}
withSelectedServiceRequest ::
    Text ->
    LocalContextView ->
    cfg ->
    FinalizedServiceRegistry scope specDigest cfg ->
    ( forall configId secretDigest fields service.
      ServiceId ->
      RoleCodec scope specDigest fields service ->
      ValidatedServiceRequest
        specDigest
        configId
        secretDigest
        fields
        service ->
      -- \| the effect row this definition declared
      [RoleEffect] ->
      IO () ->
      result
    ) ->
    Either String result
withSelectedServiceRequest verifiedDigest contextView cfg (FinalizedServiceRegistry _ definitions) use = do
    matches <- traverse project definitions
    case [match | Just match <- matches] of
        [] ->
            Left
                ( "effective project config selects no registered service"
                    ++ registeredSuffix definitions
                )
        [match] -> Right (snd match)
        many ->
            Left
                ( "effective project config selects multiple services: "
                    ++ comma (map (serviceIdText . fst) many)
                )
  where
    project (FinalizedServiceDefinition identity select effects action codec) =
        case select cfg of
            Left err -> Left (serviceIdText identity ++ ": " ++ err)
            Right Nothing -> Right Nothing
            Right (Just params) -> case action of
                LegacyServiceAction run ->
                    Right
                        ( Just
                            ( identity
                            , mintRequest
                                identity
                                codec
                                (declaredEffectList effects)
                                run
                                params
                            )
                        )
                ProgramServiceAction{} ->
                    Left (serviceIdText identity ++ ": the service requires the verified program runtime")
    mintRequest identity codec declared run params =
        use
            identity
            codec
            ( ValidatedServiceRequest
                FrameworkValidation
                    { frameworkWireKind = ServiceRoleWire
                    , frameworkScopeKind = internalRoleScopeKind codec
                    , frameworkSpecDigest = internalRoleSpecDigest codec
                    , frameworkLocalContext = contextView
                    }
                verifiedDigest
                (RoleParams params)
            )
            declared
            -- The handler runs on the *same* bundle the request carries, not on
            -- a second projection of the config beside it.
            (run (RoleParams params))

{- | Select exactly one typed definition from the config. Projection errors are
returned with the definition identity; zero or multiple matches are explicit
errors. The returned action closes over only the selected role's own
'RoleParams' bundle — it takes no framework view, because a handler that needs a
framework datum declares it as a role field instead.
-}
selectServiceAction ::
    cfg ->
    FinalizedServiceRegistry scope specDigest cfg ->
    Either String (ServiceId, [RoleEffect], IO ())
selectServiceAction cfg (FinalizedServiceRegistry _ definitions) = do
    matches <- traverse project definitions
    case [match | Just match <- matches] of
        [] ->
            Left
                ( "effective project config selects no registered service"
                    ++ registeredSuffix definitions
                )
        [match] -> Right match
        many ->
            Left
                ( "effective project config selects multiple services: "
                    ++ comma [serviceIdText identity | (identity, _, _) <- many]
                )
  where
    project (FinalizedServiceDefinition identity select effects action _) =
        case select cfg of
            Left err -> Left (serviceIdText identity ++ ": " ++ err)
            Right Nothing -> Right Nothing
            Right (Just params) -> case action of
                LegacyServiceAction run ->
                    Right
                        ( Just
                            ( identity
                            , declaredEffectList effects
                            , run (RoleParams params)
                            )
                        )
                ProgramServiceAction{} ->
                    Left (serviceIdText identity ++ ": the service requires the verified program runtime")

{- | Select one program definition and mint its request, backend, and program
as one existential package.

The program is built from the very 'RoleParams' stored in the request.  The
callback receives the typed declared row rather than a re-parsed list, so the
later placement authorization and interpreter share its exact @effects@ index.
-}
withSelectedServiceProgram ::
    Text ->
    LocalContextView ->
    cfg ->
    FinalizedServiceRegistry scope specDigest cfg ->
    ( forall configId secretDigest fields service effects payload.
      ServiceId ->
      RoleCodec scope specDigest fields service ->
      ValidatedServiceRequest specDigest configId secretDigest fields service ->
      DeclaredEffects effects ->
      ServiceResourceBackend ->
      ServiceBackend payload ->
      ServiceProgram payload service effects () ->
      result
    ) ->
    Either String result
withSelectedServiceProgram verifiedDigest contextView cfg (FinalizedServiceRegistry _ definitions) use = do
    matches <- traverse project definitions
    case [match | Just match <- matches] of
        [] -> Left ("effective project config selects no registered service" ++ registeredSuffix definitions)
        [match] -> Right (snd match)
        many -> Left ("effective project config selects multiple services: " ++ comma (map (serviceIdText . fst) many))
  where
    project (FinalizedServiceDefinition identity select effects action codec) =
        case select cfg of
            Left err -> Left (serviceIdText identity ++ ": " ++ err)
            Right Nothing -> Right Nothing
            Right (Just params) -> case action of
                LegacyServiceAction{} ->
                    Left (serviceIdText identity ++ ": legacy IO handlers are not admitted by the verified program runtime")
                ProgramServiceAction resources backend run ->
                    Right
                        ( Just
                            ( identity
                            , use
                                identity
                                codec
                                ( ValidatedServiceRequest
                                    FrameworkValidation
                                        { frameworkWireKind = ServiceRoleWire
                                        , frameworkScopeKind = internalRoleScopeKind codec
                                        , frameworkSpecDigest = internalRoleSpecDigest codec
                                        , frameworkLocalContext = contextView
                                        }
                                    verifiedDigest
                                    (RoleParams params)
                                )
                                effects
                                resources
                                backend
                                (run (RoleParams params))
                            )
                        )

{- | Decode one activation-selected narrowed role wire and build its program.

Unlike 'withSelectedServiceProgram', this runtime entry never receives the full
project configuration.  The signed activation has already selected the service
identity and measured the exact wire bytes; this function selects that one
finalized codec, validates the wire's sealed framework envelope, and hands the
handler the same decoded 'RoleParams' retained by the request.
-}
withDecodedServiceProgram ::
    Text ->
    Text ->
    Dhall.InputSettings ->
    ByteString ->
    FinalizedServiceRegistry scope specDigest cfg ->
    ( forall configId secretDigest fields service effects payload.
      ServiceId ->
      RoleCodec scope specDigest fields service ->
      ValidatedServiceRequest specDigest configId secretDigest fields service ->
      DeclaredEffects effects ->
      ServiceResourceBackend ->
      ServiceBackend payload ->
      ServiceProgram payload service effects () ->
      result
    ) ->
    IO (Either String result)
withDecodedServiceProgram selectedName verifiedDigest settings wireBytes (FinalizedServiceRegistry _ definitions) use =
    case [definition | definition@(FinalizedServiceDefinition identity _ _ _ _) <- definitions, T.pack (serviceIdText identity) == selectedName] of
        [] -> pure (Left ("activation selects unknown service " ++ T.unpack selectedName ++ registeredSuffix definitions))
        [FinalizedServiceDefinition identity _ effects action codec] ->
            case action of
                LegacyServiceAction{} ->
                    pure (Left (serviceIdText identity ++ ": legacy IO handlers are not admitted by the verified program runtime"))
                ProgramServiceAction resources backend run ->
                    case TextEncoding.decodeUtf8' wireBytes of
                        Left _ -> pure (Left (serviceIdText identity ++ ": role wire is not UTF-8"))
                        Right wireText -> do
                            decoded <- decodeRoleWire codec settings wireText
                            pure $ do
                                RuntimeRoleWire validation fields <- decoded
                                let params = RoleParams fields
                                Right
                                    ( use
                                        identity
                                        codec
                                        (ValidatedServiceRequest validation verifiedDigest params)
                                        effects
                                        resources
                                        backend
                                        (run params)
                                    )
        _ -> pure (Left ("activation service identity is duplicated: " ++ T.unpack selectedName))

-- ---------------------------------------------------------------------------
-- Immutable installed activation revisions

{- | One digest-addressed activation revision directory.

The constructor is private.  Installation derives the directory identity from
the canonical manifest bytes, and runtime opening recomputes it before reading
any member, so a caller cannot relabel a mutable directory as another revision.
-}
newtype ServiceActivationRevision = ServiceActivationRevision FilePath
    deriving (Eq, Show)

serviceActivationRevisionPath :: ServiceActivationRevision -> FilePath
serviceActivationRevisionPath (ServiceActivationRevision path) = path

serviceActivationRevision :: FilePath -> Either ServiceActivationError ServiceActivationRevision
serviceActivationRevision path
    | not (isAbsolute path) = Left (ServiceActivationInvalid "the activation revision path is not absolute")
    | length revisionName /= 64 || any (not . isLowerHex) revisionName =
        Left (ServiceActivationInvalid "the activation revision directory is not a canonical SHA-256 digest")
    | otherwise = Right (ServiceActivationRevision path)
  where
    revisionName = takeFileName path
    isLowerHex character = character >= '0' && character <= '9' || character >= 'a' && character <= 'f'

data ServiceActivationError
    = ServiceActivationInvalid Text
    | ServiceActivationIO Text
    | ServiceActivationConflict FilePath
    | ServiceActivationVerification ActivationError
    deriving (Show)

serviceActivationErrorMessage :: ServiceActivationError -> String
serviceActivationErrorMessage failure = case failure of
    ServiceActivationInvalid detail -> "service activation: " <> T.unpack detail
    ServiceActivationIO detail -> "service activation: " <> T.unpack detail
    ServiceActivationConflict path -> "service activation: immutable revision conflicts at " <> path
    ServiceActivationVerification detail -> activationErrorMessage detail

{- | Sign and publish one immutable, digest-addressed runtime revision.

The directory contains two independently read manifest copies (the selected
controller projection and the received signed wire), the signature, pinned
verification key, non-secret role wire, and private bundle.  A retry verifies
every exact byte.  A partial staging directory is completed only when every
already-present member agrees; contradictory bytes are never overwritten.
-}
installServiceActivationRevision ::
    ActivationBroker scope brokerGeneration verb ->
    ActivationVerificationKey ->
    FilePath ->
    ActivationManifest ->
    ByteString ->
    ByteString ->
    IO (Either ServiceActivationError ServiceActivationRevision)
installServiceActivationRevision broker verification root manifest roleWire secretBundle = do
    signed <- signActivationManifest broker manifest
    case signed of
        Left failure -> pure (Left (ServiceActivationVerification failure))
        Right grant -> installRelayedServiceActivationRevision verification grant root manifest roleWire secretBundle

{- | Install a revision from the exact grant returned through an admitted
root relay. The independently provisioned verification key remains a separate
input; adopting signature bytes does not confer signing authority.
-}
installRelayedServiceActivationRevision ::
    ActivationVerificationKey ->
    ActivationGrant ->
    FilePath ->
    ActivationManifest ->
    ByteString ->
    ByteString ->
    IO (Either ServiceActivationError ServiceActivationRevision)
installRelayedServiceActivationRevision verification grant root manifest roleWire secretBundle
    | not (isAbsolute root) = pure (Left (ServiceActivationInvalid "the activation root is not absolute"))
    | manifestConfigDigest manifest /= sha256Hex roleWire =
        pure (Left (ServiceActivationInvalid "the manifest config digest does not name the role-wire bytes"))
    | manifestSecretDigest manifest /= activationSecretDigestFromBytes secretBundle =
        pure (Left (ServiceActivationInvalid "the manifest secret digest does not name the private bundle bytes"))
    | otherwise = do
        let manifestWire = renderActivationManifest manifest
            revision = T.unpack (sha256Hex manifestWire)
            target = root </> revision
            staging = root </> ("installing-" <> revision)
            members =
                [ ("expected.manifest", manifestWire)
                , ("received.manifest", manifestWire)
                , ("activation.sig", activationGrantSignature grant)
                , ("activation.pub", activationVerificationKeyBytes verification)
                , ("role.dhall", roleWire)
                , ("secret.bundle", secretBundle)
                ]
        created <- tryAny (createDirectoryIfMissing True root >> createDirectory staging)
        case created of
            Right () -> publish target staging members
            Left _ -> do
                targetExists <- doesDirectoryExist target
                if targetExists
                    then verifyRevision target members
                    else do
                        stagingExists <- doesDirectoryExist staging
                        if stagingExists
                            then publish target staging members
                            else pure (Left (ServiceActivationIO "cannot create the immutable revision staging directory"))
  where
    publish target staging members = do
        exact <- traverse (writeExact staging) members
        case sequence exact of
            Left failure -> pure (Left failure)
            Right _ -> do
                renamed <- tryAny (renameDirectory staging target)
                case renamed of
                    Right () -> pure (Right (ServiceActivationRevision target))
                    Left _ -> do
                        targetExists <- doesDirectoryExist target
                        if targetExists then verifyRevision target members else pure (Left (ServiceActivationIO "cannot publish the immutable revision directory"))

    verifyRevision target members = do
        exact <- traverse (readExact target) members
        pure $ case sequence exact of
            Left _ -> Left (ServiceActivationConflict target)
            Right _ -> Right (ServiceActivationRevision target)

    writeExact directory (name, bytes) = do
        let path = directory </> name
            temporary = directory </> (name <> ".installing")
        present <- doesFileExist path
        if present
            then readExact directory (name, bytes)
            else do
                temporaryPresent <- doesFileExist temporary
                prepared <-
                    if temporaryPresent
                        then readPathExact directory temporary bytes
                        else do
                            written <-
                                tryAny $
                                    withBinaryFile temporary WriteMode $ \handle -> do
                                        hSetBuffering handle NoBuffering
                                        ByteString.hPut handle bytes
                                        hFlush handle
                            pure $ either (const (Left (ServiceActivationIO ("cannot prepare " <> T.pack name)))) (const (Right ())) written
                case prepared of
                    Left failure -> pure (Left failure)
                    Right () -> do
                        published <- tryAny (renameFile temporary path)
                        case published of
                            Right () -> readExact directory (name, bytes)
                            Left _ -> do
                                raced <- doesFileExist path
                                if raced then readExact directory (name, bytes) else pure (Left (ServiceActivationIO ("cannot publish " <> T.pack name)))

    readExact directory (name, expected) = do
        readPathExact directory (directory </> name) expected

    readPathExact directory path expected = do
        readBack <- tryAny (ByteString.readFile path)
        pure $ case readBack of
            Right actual | actual == expected -> Right ()
            _ -> Left (ServiceActivationConflict directory)

{- | Reopen and verify one installed revision against measured process reality.

The role wire and private bundle are read internally from the revision selected
by its digest-derived path.  Their hashes replace no caller claim: the supplied
measurement contributes only the independently measured binary and concrete
platform instance.
-}
withInstalledServiceActivation ::
    ProtectedStore ->
    ActivationVerificationKey ->
    ServiceActivationRevision ->
    Text ->
    MeasuredInstance ->
    ( forall scope planDigest specDigest binaryDigest frame revision instanceId.
      VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
      ByteString ->
      ByteString ->
      IO result
    ) ->
    IO (Either ServiceActivationError result)
withInstalledServiceActivation store independentlyInstalledKey (ServiceActivationRevision directory) binaryDigest instanceIdentity use = do
    loaded <- tryAny $ do
        expectedWire <- ByteString.readFile (directory </> "expected.manifest")
        receivedWire <- ByteString.readFile (directory </> "received.manifest")
        signature <- ByteString.readFile (directory </> "activation.sig")
        publicKey <- ByteString.readFile (directory </> "activation.pub")
        roleWire <- ByteString.readFile (directory </> "role.dhall")
        secretBundle <- ByteString.readFile (directory </> "secret.bundle")
        pure (expectedWire, receivedWire, signature, publicKey, roleWire, secretBundle)
    case loaded of
        Left failure -> pure (Left (ServiceActivationIO (T.pack (show failure))))
        Right (expectedWire, receivedWire, signature, publicKey, roleWire, secretBundle) ->
            case (activationManifestFromWire expectedWire, activationManifestFromWire receivedWire) of
                (Right expected, Right received)
                    | publicKey /= activationVerificationKeyBytes independentlyInstalledKey ->
                        pure (Left (ServiceActivationInvalid "the revision's verification key is not the independently installed Activation key"))
                    | otherwise -> do
                        let expectedDirectory = takeFileName directory
                            actualDirectory = T.unpack (sha256Hex expectedWire)
                        if expectedDirectory /= actualDirectory
                            then pure (Left (ServiceActivationConflict directory))
                            else do
                                verified <-
                                    verifyRuntimeRoleActivation
                                        independentlyInstalledKey
                                        store
                                        expected
                                        received
                                        (adoptRelayedActivationGrant signature)
                                        RuntimeMeasurement
                                            { measuredBinaryDigest = binaryDigest
                                            , measuredConfigDigest = sha256Hex roleWire
                                            , measuredSecretDigest = activationSecretDigestFromBytes secretBundle
                                            , measuredInstance = instanceIdentity
                                            }
                                        (\activation -> use activation roleWire secretBundle)
                                pure (either (Left . ServiceActivationVerification) Right verified)
                (Left failure, _) -> pure (Left (ServiceActivationVerification failure))
                (_, Left failure) -> pure (Left (ServiceActivationVerification failure))

data ServiceRuntimeError
    = ServiceRuntimeActivation ServiceActivationError
    | ServiceRuntimeRegistry Text
    | ServiceRuntimeRole Text
    | ServiceRuntimeStore Text
    deriving (Show)

serviceRuntimeErrorMessage :: ServiceRuntimeError -> String
serviceRuntimeErrorMessage failure = case failure of
    ServiceRuntimeActivation detail -> serviceActivationErrorMessage detail
    ServiceRuntimeRegistry detail -> "service runtime: " <> T.unpack detail
    ServiceRuntimeRole detail -> "service runtime: " <> T.unpack detail
    ServiceRuntimeStore detail -> "service runtime: " <> T.unpack detail

{- | Verify an installed activation and drive its selected program through the
one-use role lifecycle.  The finalized registry is reindexed only after its
retained digest equals the signed specification, and plan opening consumes the
decoded request itself so program and placement share their service/config
indices.
-}
runInstalledServiceProgram ::
    ProtectedStore ->
    ActivationVerificationKey ->
    ServiceActivationRevision ->
    Text ->
    MeasuredInstance ->
    Dhall.InputSettings ->
    FinalizedServiceRegistry registryScope registrySpecDigest cfg ->
    IO (Either ServiceRuntimeError RoleExitReport)
runInstalledServiceProgram store verification revision binaryDigest instanceIdentity settings registry = do
    activated <-
        withInstalledServiceActivation store verification revision binaryDigest instanceIdentity $ \activation roleWire _secretBundle ->
            runActivation activation roleWire
    case activated of
        Left failure -> pure (Left (ServiceRuntimeActivation failure))
        Right result -> pure result
  where
    runActivation activation roleWire =
        case registry of
            FinalizedServiceRegistry retainedDigest _ ->
                case withRecoverySpecReindexKernel
                    (activationSpecDigest activation)
                    retainedDigest
                    (\token -> reindexFinalizedServiceRegistryKernel token registry) of
                    Left (expected, observed) -> registryMismatch expected observed
                    Right (Left (expected, observed)) -> registryMismatch expected observed
                    Right (Right activationRegistry) -> do
                        selected <-
                            withDecodedServiceProgram
                                (activationService activation)
                                (activationConfigDigest activation)
                                settings
                                roleWire
                                activationRegistry
                                ( \identity _codec request declared resources backend program ->
                                    runSelected activation identity request declared resources backend program
                                )
                        case selected of
                            Left failure -> pure (Left (ServiceRuntimeRegistry (T.pack failure)))
                            Right run -> run

    registryMismatch expected observed =
        pure
            ( Left
                ( ServiceRuntimeRegistry
                    ("activation specification " <> expected <> " does not match finalized registry " <> observed)
                )
            )

    runSelected activation identity request declared resources backend program =
        case verifyRolePlanDraft activation (serviceRolePlanDraft resources) $ \verifiedDraft ->
            runAdmitted verifiedDraft of
            Left failure -> pure (Left (ServiceRuntimeRole (T.pack (roleLifecycleErrorMessage failure))))
            Right run -> run
      where
        runAdmitted verifiedDraft = do
            entered <-
                withProtectedEntry store $ \session -> do
                    admission <- withRoleLifecycleAdmission session activation verifiedDraft
                    case admission of
                        RoleAdmissionReserved reservation -> do
                            opened <-
                                withRuntimeRolePlanForRequest
                                    session
                                    activation
                                    verifiedDraft
                                    reservation
                                    (T.pack (serviceIdText identity))
                                    request
                                    (\plan _binding placement cursor -> pure (runPlan plan placement cursor))
                            pure $ case opened of
                                Left failure -> Right (Left (ServiceRuntimeRole (T.pack (roleLifecycleErrorMessage failure))))
                                Right run -> Right (Right run)
                        RoleAdmissionOpenUnknown key ->
                            do
                                reopened <-
                                    resumeRuntimeRolePlanOpenForRequest
                                        session
                                        activation
                                        verifiedDraft
                                        (T.pack (serviceIdText identity))
                                        request
                                        (\plan _binding placement cursor -> pure (runPlan plan placement cursor))
                                pure $ case reopened of
                                    Left failure -> Right (Left (ServiceRuntimeRole ("cannot reopen " <> key <> ": " <> T.pack (roleLifecycleErrorMessage failure))))
                                    Right run -> Right (Right run)
                        RoleAdmissionRecoveryRequired key detail ->
                            pure (Right (Left (ServiceRuntimeRole ("predecessor recovery is required at " <> key <> ": " <> detail))))
                        RoleAdmissionRefused detail -> pure (Right (Left (ServiceRuntimeRole detail)))
                        RoleAdmissionUnknown detail ->
                            pure (Right (Left (ServiceRuntimeRole ("lifecycle admission status is unknown: " <> detail))))
            case entered of
                Left failure -> pure (Left (ServiceRuntimeStore (protectedErrorMessage failure)))
                Right (Left failure) -> pure (Left failure)
                Right (Right run) -> Right <$> run

        runPlan plan placement cursor = do
            let engine =
                    RoleEngine
                        { enginePrereq = servicePrerequisite resources
                        , engineAcquire = serviceAcquireResource resources
                        , engineProbe = serviceProbeResource resources
                        , engineServe = \ready ->
                            case authorizeServiceEffects placement declared of
                                Left failure -> pure (ServeFailed (T.pack (roleLifecycleErrorMessage failure)))
                                Right authorization -> do
                                    served <-
                                        interpretServiceProgramWithReady
                                            authorization
                                            (readyServiceHandles (readyRoleHandleNames ready))
                                            backend
                                            program
                                    pure $ case served of
                                        Left failure -> ServeFailed (T.pack (serviceProgramErrorMessage failure))
                                        Right () -> ServeCompleted
                        , engineRelease = serviceReleaseResource resources
                        }
            runRoleLifecycle store plan placement cursor engine

sha256Hex :: ByteString -> Text
sha256Hex bytes = T.pack (show (Hash.hash bytes :: Hash.Digest Hash.SHA256))

registryManifest :: ServiceRegistry cfg -> Text
registryManifest (ServiceRegistry definitions) =
    T.intercalate
        "\n"
        [ T.pack (serviceIdText identity) <> ":" <> codecSchemaText wireCodec
        | ServiceDefinition identity _ _ _ wireCodec <- definitions
        ]

duplicateIds :: [ServiceDefinition cfg] -> [ServiceId]
duplicateIds definitions =
    [identity | identity : _ : _ <- group (sort identities)]
  where
    identities = [identity | ServiceDefinition identity _ _ _ _ <- definitions]

registeredSuffix :: [FinalizedServiceDefinition scope specDigest cfg] -> String
registeredSuffix [] = "; this binary registers no services"
registeredSuffix definitions =
    "; registered: "
        ++ comma [serviceIdText identity | FinalizedServiceDefinition identity _ _ _ _ <- definitions]

comma :: [String] -> String
comma = foldr join ""
  where
    join value "" = value
    join value rest = value ++ ", " ++ rest
