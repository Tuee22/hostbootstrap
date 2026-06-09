{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The Dhall-generation substrate: a registry of config artifacts whose schema
-- is reflected from the Haskell decoder type (so it cannot drift) plus a
-- deterministic renderer.
--
-- Each library level registers its own 'ConfigArtifact's; the command tree
-- concatenates the registry across levels (L0 → L1 → L2), so @config schema@
-- prints the transitive union of in-scope schemas and @config render@
-- materializes concrete Dhall (see @development_plan_standards.md § P, Q, T@).
-- The schema is reflected via @ToDhall@ — `declared` is the exact Dhall type the
-- matching @FromDhall@ decoder accepts — and the render is the @ToDhall@ embedding
-- of a concrete value, so a render → decode → re-render round-trip is byte-stable.
module HostBootstrap.Dhall.Gen
  ( ConfigArtifact (..),
    artifactOf,
    reflectedSchema,
    renderValue,
    coreArtifacts,
    schemaUnion,
    deployConfigText,
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Dhall
import qualified Dhall.Core
import Dhall.Marshal.Encode (Encoder (declared, embed))
import qualified HostBootstrap.Config.Vocab as V

-- | A registered config artifact: its name, the reflected Dhall schema its
-- decoder accepts, and a deterministic rendering of a canonical value.
data ConfigArtifact = ConfigArtifact
  { artifactName :: Text,
    schemaText :: Text,
    renderText :: Text
  }
  deriving (Eq, Show)

-- | The Dhall type a @ToDhall@ type injects to — the exact type its @FromDhall@
-- decoder accepts — as pretty Dhall text.
reflectedSchema :: forall a. (Dhall.ToDhall a) => Text
reflectedSchema = Dhall.Core.pretty (declared (Dhall.inject :: Encoder a))

-- | Render a concrete value to pretty Dhall text via its @ToDhall@ embedding.
renderValue :: forall a. (Dhall.ToDhall a) => a -> Text
renderValue value = Dhall.Core.pretty (embed (Dhall.inject :: Encoder a) value)

-- | Build a 'ConfigArtifact' from a canonical value: the schema is reflected
-- from the type, the render is the value's embedding.
artifactOf :: forall a. (Dhall.ToDhall a) => Text -> a -> ConfigArtifact
artifactOf name value =
  ConfigArtifact
    { artifactName = name,
      schemaText = reflectedSchema @a,
      renderText = renderValue value
    }

-- | The L0 (core) artifact registry. Project binaries concatenate their own
-- artifacts onto this list.
coreArtifacts :: [ConfigArtifact]
coreArtifacts =
  [ artifactOf @V.Budget "budget" (V.Budget 4 8 20),
    artifactOf @V.PodResources "podResources" (V.PodResources 1 1 1 1 2),
    artifactOf @V.KindNode "kindNode" (V.KindNode 4 8 20)
  ]

-- | Print the transitive union of a registry's schemas, each labelled by name.
schemaUnion :: [ConfigArtifact] -> Text
schemaUnion arts =
  T.intercalate "\n\n" ["-- " <> artifactName a <> "\n" <> schemaText a | a <- arts]

-- | Render a deploy config (a budget plus a concurrent pod set) that carries the
-- @Core.fitsWithin@ assertion, so an over-budget deploy fails to type-check. The
-- @coreImport@ is the Dhall import text for @Core.dhall@ (an absolute path in
-- tests; a bundled path in a deployed binary).
deployConfigText :: Text -> V.Budget -> [V.PodResources] -> Text
deployConfigText coreImport budget pods =
  T.unlines
    [ "let C = " <> coreImport,
      "let budget = " <> renderValue budget,
      "let pods = " <> renderValue pods,
      "in  { budget = budget",
      "    , pods = pods",
      "    , _fitsBudget = assert : C.fitsWithin budget pods === True",
      "    }"
    ]
