{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE RoleAnnotations #-}

module HostBootstrap.Config.Fields.Internal (
    WireKind (..),
    ScopeKind (..),
    FrameworkValidation (..),
    LocalContextView (..),
    RuntimeRoleWire (..),
    RoleCodec (..),
    RoleParams (..),
    ValidatedServiceRequest (..),
    FrameworkEnvelopeCodec (..),
    localContextView,
)
where

import Data.Text (Text)
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import HostBootstrap.Config.Class (ProjectCodec)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (CodecWitness)

data WireKind
    = FullProjectWire
    | ServiceRoleWire
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

data ScopeKind
    = ProductionScope
    | HarnessScope
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

data LocalContextView = LocalContextView
    { localProject :: Text
    , localBinary :: Text
    , localSourceRoot :: Text
    , localContextKind :: Context.ContextKind
    , localRoleName :: Text
    , localCurrentFrame :: Text
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

data FrameworkValidation = FrameworkValidation
    { frameworkWireKind :: WireKind
    , frameworkScopeKind :: ScopeKind
    , frameworkSpecDigest :: Text
    , frameworkLocalContext :: LocalContextView
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

data RuntimeRoleWire fields = RuntimeRoleWire
    { roleFrameworkValidation :: FrameworkValidation
    , roleServiceFields :: fields
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

data RoleCodec scope specDigest fields service = RoleCodec
    { internalRoleName :: Text
    , internalRoleScopeKind :: ScopeKind
    , internalRoleSpecDigest :: Text
    , internalRoleWireCodec :: CodecWitness (RuntimeRoleWire fields)
    }

type role RoleCodec nominal nominal nominal nominal

newtype RoleParams specDigest configId secretDigest fields service
    = RoleParams fields

type role RoleParams nominal nominal nominal nominal nominal

data ValidatedServiceRequest specDigest configId secretDigest fields service
    = ValidatedServiceRequest
        FrameworkValidation
        Text
        (RoleParams specDigest configId secretDigest fields service)

type role ValidatedServiceRequest nominal nominal nominal nominal nominal

data FrameworkEnvelopeCodec scope specDigest cfg = FrameworkEnvelopeCodec
    { internalFullProjectCodec :: ProjectCodec scope specDigest cfg
    , internalFullScopeKind :: ScopeKind
    , internalFullView :: cfg scope -> LocalContextView
    }

type role FrameworkEnvelopeCodec nominal nominal nominal

localContextView :: Context.BinaryContext -> LocalContextView
localContextView ctx =
    LocalContextView
        { localProject = Context.project ctx
        , localBinary = Context.binary ctx
        , localSourceRoot = Context.sourceRoot ctx
        , localContextKind = Context.contextKind ctx
        , localRoleName = Context.roleName ctx
        , localCurrentFrame = Context.currentFrame ctx
        }
