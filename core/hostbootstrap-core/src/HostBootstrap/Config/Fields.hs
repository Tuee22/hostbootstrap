{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Descriptive framework records and sealed service-admission values.

'FrameworkValidation', 'LocalContextView', and 'RuntimeRoleWire' are descriptive
records. Their @FromDhall@ instances and exported selectors allow decoding and
record updates; those values grant no authority.

'RoleParams' and 'ValidatedServiceRequest' retain private constructors and form
the sealed service path. The full project codec and every role codec retain
the same specification digest.
-}
module HostBootstrap.Config.Fields (
    WireKind (..),
    ScopeKind (..),
    KnownScopeKind (..),
    FrameworkValidation,
    frameworkWireKind,
    frameworkScopeKind,
    frameworkSpecDigest,
    frameworkLocalContext,
    LocalContextView,
    localProject,
    localBinary,
    localSourceRoot,
    localContextKind,
    localRoleName,
    localCurrentFrame,
    inspectLocalContext,
    RuntimeRoleWire,
    roleFrameworkValidation,
    roleServiceFields,
    RoleCodec,
    roleCodecName,
    roleCodecScopeKind,
    roleCodecSpecDigest,
    roleCodecSchemaText,
    renderRoleWire,
    decodeRoleWire,
    inspectConfigWireKind,
    FrameworkEnvelopeCodec,
    frameworkEnvelopeCodec,
    decodeFrameworkEnvelopeWithSettings,
    inspectFullConfig,
    RoleParams,
    roleParamsValue,
    ValidatedServiceRequest,
    requestFrameworkValidation,
    requestVerifiedDigest,
    requestRoleParams,
    renderValidatedServiceRequest,
)
where

import Control.Exception (evaluate)
import Control.Exception.Safe (tryAny)
import Data.Text (Text)
import qualified Dhall
import qualified Dhall.Core as DhallCore
import qualified Dhall.Map as DhallMap
import HostBootstrap.Config.Class (
    ProjectCfg (cfgContext),
    ProjectCodec,
    decodeProjectCodecWithSettings,
    projectCodecSpecDigest,
 )
import HostBootstrap.Config.Fields.Internal
import HostBootstrap.Context (BinaryContext)
import HostBootstrap.Dhall.Gen (
    codecSchemaText,
    decodeWithSettings,
    renderValue,
 )

roleCodecName :: RoleCodec scope specDigest fields service -> Text
roleCodecName = internalRoleName

-- | Project the public, read-only pre-routing view from a validated context.
inspectLocalContext :: BinaryContext -> LocalContextView
inspectLocalContext = localContextView

roleCodecScopeKind :: RoleCodec scope specDigest fields service -> ScopeKind
roleCodecScopeKind = internalRoleScopeKind

roleCodecSpecDigest :: RoleCodec scope specDigest fields service -> Text
roleCodecSpecDigest = internalRoleSpecDigest

roleCodecSchemaText :: RoleCodec scope specDigest fields service -> Text
roleCodecSchemaText = codecSchemaText . internalRoleWireCodec

renderRoleWire ::
    RoleCodec scope specDigest fields service ->
    RuntimeRoleWire fields ->
    Text
renderRoleWire = renderValue . internalRoleWireCodec

decodeRoleWire ::
    RoleCodec scope specDigest fields service ->
    Dhall.InputSettings ->
    Text ->
    IO (Either String (RuntimeRoleWire fields))
decodeRoleWire codec settings input = do
    decoded <- tryAny (decodeWithSettings (internalRoleWireCodec codec) settings input)
    pure $ case decoded of
        Left err ->
            Left
                ( "role wire failed schema decoding: "
                    ++ takeWhile (/= '\n') (show err)
                )
        Right wire ->
            let validation = roleFrameworkValidation wire
             in if frameworkWireKind validation /= ServiceRoleWire
                    then Left "role wire declares a non-service wire kind"
                    else
                        if frameworkScopeKind validation /= internalRoleScopeKind codec
                            then Left "role wire scope kind disagrees with its selected codec"
                            else
                                if frameworkSpecDigest validation /= internalRoleSpecDigest codec
                                    then Left "role wire specification digest disagrees with its selected codec"
                                    else Right wire

{- | Inspect only a role wire's descriptive framework record before selecting
a config decoder. Only a positively decoded service-role declaration selects
that wire kind. Missing or malformed framework records, and synchronous input
failures, leave the full project decoder responsible for its own diagnostic.
Import resolution uses the supplied source/root settings; cancellation still
propagates.
-}
inspectConfigWireKind :: Dhall.InputSettings -> Text -> IO WireKind
inspectConfigWireKind settings input = do
    inspected <- tryAny $ do
        expression <- Dhall.inputExprWithSettings settings input
        evaluate $ case expression of
            DhallCore.RecordLit fields ->
                case DhallMap.lookup "roleFrameworkValidation" fields of
                    Just field ->
                        case Dhall.rawInput Dhall.auto (DhallCore.recordFieldValue field) :: Maybe FrameworkValidation of
                            Just validation
                                | frameworkWireKind validation == ServiceRoleWire -> ServiceRoleWire
                            _ -> FullProjectWire
                    Nothing -> FullProjectWire
            _ -> FullProjectWire
    pure (either (const FullProjectWire) id inspected)

frameworkEnvelopeCodec ::
    (ProjectCfg cfg) =>
    ScopeKind ->
    ProjectCodec scope specDigest cfg ->
    FrameworkEnvelopeCodec scope specDigest cfg
frameworkEnvelopeCodec scopeKind codec =
    FrameworkEnvelopeCodec
        { internalFullProjectCodec = codec
        , internalFullScopeKind = scopeKind
        , internalFullView = localContextView . cfgContext
        }

-- | Decode through the envelope's retained scoped codec with the same settings.
decodeFrameworkEnvelopeWithSettings ::
    FrameworkEnvelopeCodec scope specDigest cfg ->
    Dhall.InputSettings ->
    Text ->
    IO (cfg scope)
decodeFrameworkEnvelopeWithSettings =
    decodeProjectCodecWithSettings . internalFullProjectCodec

inspectFullConfig ::
    FrameworkEnvelopeCodec scope specDigest cfg ->
    cfg scope ->
    FrameworkValidation
inspectFullConfig codec cfg =
    FrameworkValidation
        { frameworkWireKind = FullProjectWire
        , frameworkScopeKind = internalFullScopeKind codec
        , frameworkSpecDigest =
            projectCodecSpecDigest (internalFullProjectCodec codec)
        , frameworkLocalContext = internalFullView codec cfg
        }

roleParamsValue ::
    RoleParams specDigest configId secretDigest fields service ->
    fields
roleParamsValue (RoleParams fields) = fields

requestFrameworkValidation ::
    ValidatedServiceRequest specDigest configId secretDigest fields service ->
    FrameworkValidation
requestFrameworkValidation (ValidatedServiceRequest validation _ _) = validation

requestVerifiedDigest ::
    ValidatedServiceRequest specDigest configId secretDigest fields service ->
    Text
requestVerifiedDigest (ValidatedServiceRequest _ digest _) = digest

requestRoleParams ::
    ValidatedServiceRequest specDigest configId secretDigest fields service ->
    RoleParams specDigest configId secretDigest fields service
requestRoleParams (ValidatedServiceRequest _ _ params) = params

renderValidatedServiceRequest ::
    RoleCodec scope specDigest fields service ->
    ValidatedServiceRequest specDigest configId secretDigest fields service ->
    Text
renderValidatedServiceRequest codec (ValidatedServiceRequest validation _ (RoleParams fields)) =
    renderRoleWire
        codec
        RuntimeRoleWire
            { roleFrameworkValidation = validation
            , roleServiceFields = fields
            }
