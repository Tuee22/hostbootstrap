{-# LANGUAGE RankNTypes #-}

{- | Opaque common-envelope and structural role-wire types.

The full project codec and every role codec retain the same specification
digest. A role wire contains only the mandatory read-only framework view plus
that service's parameter record; plan/build/deploy fields cannot enter
'RoleParams'. Constructors remain internal so package consumers cannot select a
field row or pair codecs from different finalizations.
-}
module HostBootstrap.Config.Fields (
    WireKind (..),
    ScopeKind (..),
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
    FrameworkEnvelopeCodec,
    frameworkEnvelopeCodec,
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

import Data.Text (Text)
import qualified Dhall
import Control.Exception.Safe (tryAny)
import HostBootstrap.Config.Class (
    ProjectCfg (cfgContext),
    ProjectCodec,
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
