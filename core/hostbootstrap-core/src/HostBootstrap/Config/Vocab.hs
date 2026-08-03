{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}

{- | Haskell mirrors of the reusable @Core.dhall@ vocabulary record types.

Each mirror has one admitted codec whose normalized decoder/encoder type is
judgmentally compared with the matching type-valued export of @Core.dhall@.
The inventory test derives the complete exported-type list, so a new,
removed, or unowned hand-written type cannot silently pass (see
@development_plan_standards.md § Q, § T@).

@DuplicateRecordFields@ lets the budget/footprint records share field names
(@cpu@/@memory@/@storage@) so they match the @Core.dhall@ field labels exactly.
-}
module HostBootstrap.Config.Vocab (
    Resources (..),
    Budget (..),
    PodResources (..),
    KindNode (..),
    Mount (..),
    Substrate (..),
    ClusterProfile (..),
    Weight (..),
    Production,
    Harness,
    HarnessAuthority,
    HarnessConfigAuthority,
    harnessConfigAuthority,
    harnessRunName,
    TestSecret (..),
    SecretRef,
    vaultSecret,
    transitKeySecret,
    promptSecret,
    testPlaintextSecret,
    SecretRefView (..),
    secretRefView,
    ProductionSecretRefWire (..),
    HarnessSecretRefWire (..),
    productionSecretRef,
    harnessSecretRef,
    productionSecretRefWire,
    harnessSecretRefWire,
    VaultRef (..),
)
where

import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall)
import qualified Dhall
import GHC.Generics (Generic)
import HostBootstrap.Config.Authority.Internal (
    HarnessAuthority,
    HarnessConfigAuthority,
    harnessConfigAuthority,
    harnessConfigRunName,
    harnessRunName,
 )
import Numeric.Natural (Natural)

-- | Text-quantity resource envelope exported by @Core.dhall@.
data Resources = Resources
    { cpu :: Natural
    , memory :: Text
    , storage :: Text
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

{- | A numeric resource budget in canonical units (whole CPU cores; memory and
storage in caller-consistent whole units). Mirrors @Core.dhall@ @Budget@.
-}
data Budget = Budget
    { cpu :: Natural
    , memory :: Natural
    , storage :: Natural
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

{- | One Kubernetes-style workload's request/limit footprint, replicated.
Mirrors @Core.dhall@ @PodResources@.
-}
data PodResources = PodResources
    { replicas :: Natural
    , cpuRequest :: Natural
    , cpuLimit :: Natural
    , memoryRequest :: Natural
    , memoryLimit :: Natural
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The cap applied to a kind node container. Mirrors @Core.dhall@ @KindNode@.
data KindNode = KindNode
    { cpus :: Natural
    , memory :: Natural
    , storage :: Natural
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | A host bind mount. Mirrors @Core.dhall@ @Mount@.
data Mount = Mount
    { source :: Text
    , target :: Text
    , readOnly :: Bool
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The historical substrate vocabulary exported by @Core.dhall@.
data Substrate
    = AppleSilicon
    | LinuxCpu
    | LinuxGpu
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Production or named test cluster profile.
data ClusterProfile
    = Production
    | Test Text
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | A proportional budget weight (transparent @Natural@ in Dhall).
newtype Weight = Weight Natural
    deriving stock (Eq, Show, Generic)
    deriving newtype (FromDhall, ToDhall)

{- | The @Vault@ alternative's payload: a KV mount, path, and field naming
where the secret *source* lives. Mirrors the @Vault@ record carried by
@Core.dhall@ @SecretRef@.
-}
data VaultRef = VaultRef
    { mount :: Text
    , path :: Text
    , field :: Text
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Production config scope for one installed project identity.
data Production projectId

-- | Harness config scope for one installed project and one generative run.
data Harness projectId runId

-- | Explicit fixture material. It can enter a scoped secret only with authority.
newtype TestSecret = TestSecret Text
    deriving stock (Eq, Show)

{- | A scope-indexed secret reference. Constructors are hidden: pointer smart
constructors work at any scope, while plaintext construction requires the
matching 'HarnessConfigAuthority'.
-}
data SecretRef scope where
    ScopedVault :: VaultRef -> SecretRef scope
    ScopedTransitKey :: Text -> SecretRef scope
    ScopedPrompt :: Text -> SecretRef scope
    ScopedTestPlaintext :: Text -> TestSecret -> SecretRef (Harness projectId runId)

instance Eq (SecretRef scope) where
    left == right = secretRefView left == secretRefView right

instance Show (SecretRef scope) where
    showsPrec precedence = showsPrec precedence . secretRefView

vaultSecret :: VaultRef -> SecretRef scope
vaultSecret = ScopedVault

transitKeySecret :: Text -> SecretRef scope
transitKeySecret = ScopedTransitKey

promptSecret :: Text -> SecretRef scope
promptSecret = ScopedPrompt

testPlaintextSecret ::
    HarnessConfigAuthority projectId runId ->
    TestSecret ->
    SecretRef (Harness projectId runId)
testPlaintextSecret authority = ScopedTestPlaintext (harnessConfigRunName authority)

-- | Scope-erased, display-only view. It carries no constructor authority.
data SecretRefView
    = SecretVault VaultRef
    | SecretTransitKey Text
    | SecretPrompt Text
    | SecretTestPlaintext TestSecret
    deriving (Eq, Show)

secretRefView :: SecretRef scope -> SecretRefView
secretRefView (ScopedVault value) = SecretVault value
secretRefView (ScopedTransitKey value) = SecretTransitKey value
secretRefView (ScopedPrompt value) = SecretPrompt value
secretRefView (ScopedTestPlaintext _ value) = SecretTestPlaintext value

-- | Untrusted production wire. Its reflected union has no plaintext alternative.
data ProductionSecretRefWire
    = ProductionVault VaultRef
    | ProductionTransitKey Text
    | ProductionPrompt Text
    deriving stock (Eq, Show, Generic)

-- | Untrusted harness wire. Plaintext is not scoped until authority converts it.
data HarnessSecretRefWire
    = HarnessVault VaultRef
    | HarnessTransitKey Text
    | HarnessPrompt Text
    | HarnessTestPlaintext Text
    deriving stock (Eq, Show, Generic)

productionWireOptions :: Dhall.InterpretOptions
productionWireOptions =
    Dhall.defaultInterpretOptions
        { Dhall.constructorModifier = T.drop 10
        }

harnessWireOptions :: Dhall.InterpretOptions
harnessWireOptions =
    Dhall.defaultInterpretOptions
        { Dhall.constructorModifier = T.drop 7
        }

instance FromDhall ProductionSecretRefWire where
    autoWith _ = Dhall.genericAutoWith productionWireOptions

instance ToDhall ProductionSecretRefWire where
    injectWith _ = Dhall.genericToDhallWith productionWireOptions

instance FromDhall HarnessSecretRefWire where
    autoWith _ = Dhall.genericAutoWith harnessWireOptions

instance ToDhall HarnessSecretRefWire where
    injectWith _ = Dhall.genericToDhallWith harnessWireOptions

productionSecretRef :: ProductionSecretRefWire -> SecretRef (Production projectId)
productionSecretRef wire =
    case wire of
        ProductionVault value -> ScopedVault value
        ProductionTransitKey value -> ScopedTransitKey value
        ProductionPrompt value -> ScopedPrompt value

harnessSecretRef ::
    HarnessConfigAuthority projectId runId ->
    HarnessSecretRefWire ->
    SecretRef (Harness projectId runId)
harnessSecretRef authority wire =
    case wire of
        HarnessVault value -> ScopedVault value
        HarnessTransitKey value -> ScopedTransitKey value
        HarnessPrompt value -> ScopedPrompt value
        HarnessTestPlaintext value -> testPlaintextSecret authority (TestSecret value)

productionSecretRefWire ::
    SecretRef (Production projectId) ->
    ProductionSecretRefWire
productionSecretRefWire (ScopedVault value) = ProductionVault value
productionSecretRefWire (ScopedTransitKey value) = ProductionTransitKey value
productionSecretRefWire (ScopedPrompt value) = ProductionPrompt value

harnessSecretRefWire ::
    SecretRef (Harness projectId runId) ->
    HarnessSecretRefWire
harnessSecretRefWire (ScopedVault value) = HarnessVault value
harnessSecretRefWire (ScopedTransitKey value) = HarnessTransitKey value
harnessSecretRefWire (ScopedPrompt value) = HarnessPrompt value
harnessSecretRefWire (ScopedTestPlaintext _ (TestSecret value)) = HarnessTestPlaintext value
