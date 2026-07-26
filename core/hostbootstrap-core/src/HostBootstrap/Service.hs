{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
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
    serviceDefinition,
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
)
where

import Data.List (group, sort)
import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall)
import HostBootstrap.Config.Class (
    ProjectCodec,
    projectCodecSpecDigest,
    withFinalizedProjectCodec,
 )
import HostBootstrap.Config.Fields (
    LocalContextView,
    ScopeKind (..),
    roleCodecSchemaText,
 )
import HostBootstrap.Config.Fields.Internal (
    FrameworkValidation (..),
    RoleParams (..),
    RoleCodec (..),
    RuntimeRoleWire,
    ValidatedServiceRequest (..),
    WireKind (ServiceRoleWire),
 )
import HostBootstrap.Dhall.Gen (
    CodecWitness,
    autoCodecWitness,
    codecSchemaText,
    requireCodecWitness,
 )

-- | A validated service identity. Its constructor is hidden.
newtype ServiceId = ServiceId String
    deriving (Eq, Ord, Show)

serviceId :: String -> Either String ServiceId
serviceId raw
    | null raw = Left "service identity must not be empty"
    | any invalid raw = Left ("service identity is not a stable token: " ++ show raw)
    | otherwise = Right (ServiceId raw)
  where
    invalid c = not (c == '-' || c == '_' || c == '.' || c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z')

serviceIdText :: ServiceId -> String
serviceIdText (ServiceId value) = value

{- | One service's inseparable config projection, role-field codec, and handler.
'Nothing' means this definition is not selected by the effective config.
-}
data ServiceDefinition cfg =
    forall fields.
    ServiceDefinition
        ServiceId
        (cfg -> Either String (Maybe fields))
        (LocalContextView -> fields -> IO ())
        (CodecWitness (RuntimeRoleWire fields))

serviceDefinition ::
    forall fields cfg.
    (FromDhall fields, ToDhall fields) =>
    ServiceId ->
    (cfg -> Either String (Maybe fields)) ->
    (LocalContextView -> fields -> IO ()) ->
    ServiceDefinition cfg
serviceDefinition identity project run =
    ServiceDefinition
        identity
        project
        run
        ( requireCodecWitness
            ("RuntimeRoleWire/" ++ serviceIdText identity)
            (autoCodecWitness @(RuntimeRoleWire fields))
        )

-- | An opaque duplicate-free registry.
newtype ServiceRegistry cfg = ServiceRegistry [ServiceDefinition cfg]

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
    [serviceIdText identity | ServiceDefinition identity _ _ _ <- definitions]

data FinalizedServiceDefinition scope specDigest cfg =
    forall fields service.
    FinalizedServiceDefinition
        ServiceId
        (cfg -> Either String (Maybe fields))
        (LocalContextView -> fields -> IO ())
        (RoleCodec scope specDigest fields service)

newtype FinalizedServiceRegistry scope specDigest cfg
    = FinalizedServiceRegistry [FinalizedServiceDefinition scope specDigest cfg]

{- | Jointly finalize the full project codec and the closed service registry.
The rank-2 continuation prevents callers from selecting or reusing the fresh
@specDigest@ identity.
-}
withFinalizedServiceRegistry ::
    ScopeKind ->
    ProjectCodec scope initialDigest cfgFamily ->
    ServiceRegistry (cfgFamily scope) ->
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
            (FinalizedServiceRegistry (map (finalizeDefinition finalCodec) definitions))
  where
    ServiceRegistry definitions = registry
    finalizeDefinition finalCodec (ServiceDefinition identity project run wireCodec) =
        FinalizedServiceDefinition
            identity
            project
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
finalizedServiceVariantNames (FinalizedServiceRegistry definitions) =
    [serviceIdText identity | FinalizedServiceDefinition identity _ _ _ <- definitions]

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
        | FinalizedServiceDefinition identity _ _ codec <- definitions
        ]
    FinalizedServiceRegistry definitions = registry

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
      IO () ->
      result
    ) ->
    Either String result
withSelectedServiceRequest verifiedDigest contextView cfg (FinalizedServiceRegistry definitions) use = do
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
    project (FinalizedServiceDefinition identity select run codec) =
        case select cfg of
            Left err -> Left (serviceIdText identity ++ ": " ++ err)
            Right Nothing -> Right Nothing
            Right (Just params) ->
                Right
                    ( Just
                        ( identity
                        , mintRequest
                            identity
                            codec
                            run
                            params
                        )
                    )
    mintRequest identity codec run params =
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
            (run contextView params)

{- | Select exactly one typed definition from the config. Projection errors are
returned with the definition identity; zero or multiple matches are explicit
errors. The returned action closes over only the selected role fields.
-}
selectServiceAction ::
    LocalContextView ->
    cfg ->
    FinalizedServiceRegistry scope specDigest cfg ->
    Either String (ServiceId, IO ())
selectServiceAction contextView cfg (FinalizedServiceRegistry definitions) = do
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
                    ++ comma [serviceIdText identity | (identity, _) <- many]
                )
  where
    project (FinalizedServiceDefinition identity select run _) =
        case select cfg of
            Left err -> Left (serviceIdText identity ++ ": " ++ err)
            Right Nothing -> Right Nothing
            Right (Just params) -> Right (Just (identity, run contextView params))

registryManifest :: ServiceRegistry cfg -> Text
registryManifest (ServiceRegistry definitions) =
    T.intercalate
        "\n"
        [ T.pack (serviceIdText identity) <> ":" <> codecSchemaText wireCodec
        | ServiceDefinition identity _ _ wireCodec <- definitions
        ]

duplicateIds :: [ServiceDefinition cfg] -> [ServiceId]
duplicateIds definitions =
    [identity | identity : _ : _ <- group (sort identities)]
  where
    identities = [identity | ServiceDefinition identity _ _ _ <- definitions]

registeredSuffix :: [FinalizedServiceDefinition scope specDigest cfg] -> String
registeredSuffix [] = "; this binary registers no services"
registeredSuffix definitions =
    "; registered: "
        ++ comma [serviceIdText identity | FinalizedServiceDefinition identity _ _ _ <- definitions]

comma :: [String] -> String
comma = foldr join ""
  where
    join value "" = value
    join value rest = value ++ ", " ++ rest
