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
    serviceDefinition,
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
import HostBootstrap.RoleLifecycle (
    DeclaredEffects,
    RoleEffect,
    declaredEffectList,
 )
import HostBootstrap.Service.Internal (
    FinalizedServiceDefinition (FinalizedServiceDefinition),
    FinalizedServiceRegistry (FinalizedServiceRegistry),
    ServiceHandler,
    ServiceId (ServiceId),
 )
import HostBootstrap.Dhall.Gen (
    CodecWitness,
    autoCodecWitness,
    codecSchemaText,
    requireCodecWitness,
 )

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
data ServiceDefinition cfg =
    forall fields effects.
    ServiceDefinition
        ServiceId
        (forall scope. cfg scope -> Either String (Maybe fields))
        (DeclaredEffects effects)
        (ServiceHandler fields)
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
        run
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
      -- | the effect row this definition declared
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
    project (FinalizedServiceDefinition identity select effects run codec) =
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
                            (declaredEffectList effects)
                            run
                            params
                        )
                    )
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
    project (FinalizedServiceDefinition identity select effects run _) =
        case select cfg of
            Left err -> Left (serviceIdText identity ++ ": " ++ err)
            Right Nothing -> Right Nothing
            Right (Just params) ->
                Right
                    ( Just
                        ( identity
                        , declaredEffectList effects
                        , run (RoleParams params)
                        )
                    )

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
