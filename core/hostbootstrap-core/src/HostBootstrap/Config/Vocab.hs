{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}

-- | Haskell mirrors of the reusable @Core.dhall@ vocabulary record types.
--
-- These types are the shape the project binary reflects from its decoders into
-- the emitted Dhall schema (@context schema@) and decodes generated configs into
-- (@context render@). 'SecretRef' carries an anti-drift test asserting its
-- reflected Dhall shape equals the matching @Core.dhall@ type; the L0 record
-- types (@Budget@/@PodResources@/@KindNode@) are pinned by a re-snapshottable
-- golden of their reflected shape, and @Mount@ is not yet pinned (see
-- @development_plan_standards.md § Q, § T@).
--
-- @DuplicateRecordFields@ lets the budget/footprint records share field names
-- (@cpu@/@memory@/@storage@) so they match the @Core.dhall@ field labels exactly.
module HostBootstrap.Config.Vocab
  ( Budget (..),
    PodResources (..),
    KindNode (..),
    Mount (..),
    SecretRef (..),
    VaultRef (..),
  )
where

import Data.Text (Text)
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | A numeric resource budget in canonical units (whole CPU cores; memory and
-- storage in caller-consistent whole units). Mirrors @Core.dhall@ @Budget@.
data Budget = Budget
  { cpu :: Natural,
    memory :: Natural,
    storage :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | One Kubernetes-style workload's request/limit footprint, replicated.
-- Mirrors @Core.dhall@ @PodResources@.
data PodResources = PodResources
  { replicas :: Natural,
    cpuRequest :: Natural,
    cpuLimit :: Natural,
    memoryRequest :: Natural,
    memoryLimit :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The cap applied to a kind node container. Mirrors @Core.dhall@ @KindNode@.
data KindNode = KindNode
  { cpus :: Natural,
    memory :: Natural,
    storage :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | A host bind mount. Mirrors @Core.dhall@ @Mount@.
data Mount = Mount
  { source :: Text,
    target :: Text,
    readOnly :: Bool
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The @Vault@ alternative's payload: a KV mount, path, and field naming
-- where the secret *source* lives. Mirrors the @Vault@ record carried by
-- @Core.dhall@ @SecretRef@.
data VaultRef = VaultRef
  { mount :: Text,
    path :: Text,
    field :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | A typed pointer to a secret's source — never the secret material itself.
-- A pure shape with no Vault dependency. Dhall encodes this sum type as a union
-- keyed by constructor name, so it mirrors @Core.dhall@ @SecretRef@ exactly:
-- @Vault@ carries the @{ mount, path, field }@ record, the other three carry
-- 'Text'.
data SecretRef
  = Vault VaultRef
  | TransitKey Text
  | Prompt Text
  | TestPlaintext Text
  deriving (Eq, Show, Generic, FromDhall, ToDhall)
