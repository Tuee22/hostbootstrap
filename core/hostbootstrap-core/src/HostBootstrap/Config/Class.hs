{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The single typeclass coupling @hostbootstrap-core@ to a project's config
-- type — and the @InitArgs@ record that the project's @init@ builder interprets.
--
-- The core is generic over a project's @<project>.dhall@ shape: it never names a
-- concrete config record and never pattern-matches a project cfg's fields. It
-- only ever needs to (1) reach the universal 'Context.BinaryContext' embedded in
-- any project config, and (2) project a child config carrying a derived context
-- (the @context-init@ boundary crossing). Those two operations are the whole of
-- 'ProjectCfg'; everything else core does with a config goes through
-- @FromDhall@/@ToDhall@ (decode the sibling config, render a child config) — never
-- a field accessor.
--
-- A project (the demo) supplies the @ProjectCfg@ instance for its own config
-- type, plus the @init@ builders that turn parsed CLI flags ('InitArgs') into a
-- concrete config — the **only** place defaults live (core ships none).
module HostBootstrap.Config.Class
  ( ProjectCfg (..),
    InitArgs (..),
    projectCfgSchemaText,
  )
where

import Data.Text (Text)
import qualified Dhall
import qualified Dhall.Core
import Dhall.Marshal.Encode (declared)
import qualified HostBootstrap.Context as Context
import Numeric.Natural (Natural)

-- | A project's config type, coupled to the core **only** through the universal
-- binary context it embeds. Core decodes/encodes the config via @FromDhall@ /
-- @ToDhall@ and otherwise touches it solely through these two methods, so the
-- core has no knowledge of the project's actual fields.
class (Dhall.FromDhall cfg, Dhall.ToDhall cfg) => ProjectCfg cfg where
  -- | The one required accessor: the universal runtime context inside the config
  -- (validated against the derived project identity before command dispatch).
  cfgContext :: cfg -> Context.BinaryContext

  -- | Project a child config (lift): replace the embedded context with a
  -- derived one, keeping every other project field. Used by the @context-init@
  -- boundary crossing to mint a narrower child @<project>.dhall@.
  cfgWithContext :: Context.BinaryContext -> cfg -> cfg

-- | The raw, parsed @init@ flags shared by @project init@, @service init@, and
-- the test harness' config generation. The role/context selectors are required
-- to shape the
-- context; the project-tunable knobs are **generic optionals** (core supplies no
-- value for any of them), so a project's @init@ builder fills the omitted ones
-- with the project's own defaults. The 'force' / 'ifMissing' switches drive the
-- idempotent write behaviour.
data InitArgs = InitArgs
  { -- | the primary role the generated config declares
    role :: Context.ContextKind,
    -- | additional roles unioned into the context's authority (multi-role)
    alsoRoles :: [Context.ContextKind],
    -- | where to write the generated config (default: the executable sibling)
    output :: Maybe FilePath,
    -- | the source root recorded in the generated context (default: cwd)
    sourceRoot :: Maybe FilePath,
    -- | CPU budget (project default when omitted)
    mCpu :: Maybe Natural,
    -- | memory budget (project default when omitted)
    memory :: Maybe Text,
    -- | storage budget (project default when omitted)
    storage :: Maybe Text,
    -- | Dockerfile path recorded in the config (project default when omitted)
    dockerfile :: Maybe Text,
    -- | HA replica count (project default when omitted)
    haReplicas :: Maybe Natural,
    -- | overwrite an existing OUTPUT
    force :: Bool,
    -- | no-op when OUTPUT already exists (idempotent ensure)
    ifMissing :: Bool
  }
  deriving (Eq, Show)

-- | The project config's Dhall schema, reflected **generically** from the
-- config's @ToDhall@ encoder so it cannot drift from the decoder. Core never
-- names the concrete config type: the schema is the encoder's declared type,
-- pretty-printed. The caller supplies the project config type via
-- @TypeApplications@ (e.g. @projectCfgSchemaText \@cfg@).
projectCfgSchemaText :: forall cfg. (Dhall.ToDhall cfg) => Text
projectCfgSchemaText = Dhall.Core.pretty (declared (Dhall.inject :: Dhall.Encoder cfg))
