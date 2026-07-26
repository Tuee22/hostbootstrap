{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The Dhall-generation substrate: a validated decoder/encoder witness plus a
registry of config artifacts whose schema, decoder, and renderer all consume
that witness.

Each library level registers its own 'ConfigArtifact's; the command tree
concatenates the registry across levels (L0 → L1 → L2), so @context schema@
prints the transitive union of in-scope schemas and @context render@
materializes static example Dhall for inspection (see @development_plan_standards.md § P, Q, T@).
-}
module HostBootstrap.Dhall.Gen (
    CodecWitness,
    CodecWitnessError (..),
    mkCodecWitness,
    autoCodecWitness,
    requireCodecWitness,
    codecSchemaText,
    decodeText,
    decodeFile,
    decodeWithSettings,
    renderValue,
    renderHoistedValue,
    ConfigArtifact,
    artifactName,
    schemaText,
    renderText,
    artifactOf,
    coreArtifacts,
    schemaUnion,
    deployConfigText,
)
where

import Data.Foldable (toList)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Dhall
import qualified Dhall.Core
import Dhall.Marshal.Decode (Decoder (expected))
import Dhall.Marshal.Encode (Encoder (declared, embed))
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Dhall.Hoist (NamedUnion)
import qualified HostBootstrap.Dhall.Hoist as Hoist

-- | Why a decoder/encoder pair could not be admitted as one codec.
data CodecWitnessError
    = DecoderExpectedTypeUnavailable
    | CodecTypeMismatch
        { decoderTypeText :: Text
        , encoderTypeText :: Text
        }
    deriving (Eq, Show)

{- | An admitted Dhall codec. The constructor is intentionally private: callers
can obtain a witness only through 'mkCodecWitness', which compares the
normalized decoder and encoder type expressions.
-}
data CodecWitness a = CodecWitness
    { witnessDecoder :: Decoder a
    , witnessEncoder :: Encoder a
    , witnessSchema :: Text
    }

{- | Validate one decoder/encoder pair. Matching type expressions prove only
that both halves claim the same Dhall type; representative semantic
round-trips remain separate tests.
-}
mkCodecWitness :: Decoder a -> Encoder a -> Either CodecWitnessError (CodecWitness a)
mkCodecWitness decoder encoder =
    case toList (expected decoder) of
        [decoderType]
            | Dhall.Core.judgmentallyEqual normalizedDecoder normalizedEncoder ->
                Right
                    CodecWitness
                        { witnessDecoder = decoder
                        , witnessEncoder = encoder
                        , witnessSchema = Dhall.Core.pretty normalizedDecoder
                        }
            | otherwise ->
                Left
                    CodecTypeMismatch
                        { decoderTypeText = Dhall.Core.pretty normalizedDecoder
                        , encoderTypeText = Dhall.Core.pretty normalizedEncoder
                        }
          where
            normalizedDecoder = Dhall.Core.normalize decoderType
            normalizedEncoder = Dhall.Core.normalize (declared encoder)
        _ -> Left DecoderExpectedTypeUnavailable

-- | Construct a witness from the standard instances for @a@.
autoCodecWitness ::
    forall a.
    (Dhall.FromDhall a, Dhall.ToDhall a) =>
    Either CodecWitnessError (CodecWitness a)
autoCodecWitness =
    mkCodecWitness
        (Dhall.auto :: Decoder a)
        (Dhall.inject :: Encoder a)

-- | Unwrap a statically declared codec or fail at its declaration site.
requireCodecWitness :: String -> Either CodecWitnessError (CodecWitness a) -> CodecWitness a
requireCodecWitness label =
    either (error . ((label <> ": invalid Dhall codec: ") <>) . show) id

-- | Pretty text for the type jointly claimed by the validated decoder/encoder.
codecSchemaText :: CodecWitness a -> Text
codecSchemaText codec =
    codec `seq` witnessSchema codec

-- | Decode Dhall text using the admitted decoder.
decodeText :: CodecWitness a -> Text -> IO a
decodeText codec =
    codec `seq` Dhall.input (witnessDecoder codec)

-- | Decode a Dhall file using the admitted decoder.
decodeFile :: CodecWitness a -> FilePath -> IO a
decodeFile codec =
    codec `seq` Dhall.inputFile (witnessDecoder codec)

{- | Decode text with explicit import/source settings using the admitted
decoder.
-}
decodeWithSettings :: CodecWitness a -> Dhall.InputSettings -> Text -> IO a
decodeWithSettings codec settings =
    codec `seq` Dhall.inputWithSettings settings (witnessDecoder codec)

-- | Render a value using the admitted encoder.
renderValue :: CodecWitness a -> a -> Text
renderValue codec value =
    codec `seq` Dhall.Core.pretty (embed (witnessEncoder codec) value)

{- | Render a value with repeated vocabulary unions hoisted, using the admitted
encoder rather than independently selecting a @ToDhall@ instance.
-}
renderHoistedValue :: CodecWitness a -> [NamedUnion] -> a -> Text
renderHoistedValue codec unions value =
    codec `seq` Hoist.renderHoistedExpr unions (embed (witnessEncoder codec) value)

{- | A registered config artifact: its name, the reflected Dhall schema its
decoder accepts, and a deterministic rendering of a canonical value.
-}
data ConfigArtifact = ConfigArtifact
    { artifactName :: Text
    , schemaText :: Text
    , renderText :: Text
    }
    deriving (Eq, Show)

{- | Build a 'ConfigArtifact' from a canonical value: the schema is reflected
from the validated codec, and the same codec renders the value.
-}
artifactOf :: Text -> CodecWitness a -> a -> ConfigArtifact
artifactOf name codec value =
    codec `seq`
        ConfigArtifact
            { artifactName = name
            , schemaText = codecSchemaText codec
            , renderText = renderValue codec value
            }

budgetCodec :: CodecWitness V.Budget
budgetCodec = requireCodecWitness "Budget" (autoCodecWitness @V.Budget)

podResourcesCodec :: CodecWitness V.PodResources
podResourcesCodec =
    requireCodecWitness "PodResources" (autoCodecWitness @V.PodResources)

podResourcesListCodec :: CodecWitness [V.PodResources]
podResourcesListCodec =
    requireCodecWitness "List PodResources" (autoCodecWitness @[V.PodResources])

kindNodeCodec :: CodecWitness V.KindNode
kindNodeCodec = requireCodecWitness "KindNode" (autoCodecWitness @V.KindNode)

{- | The L0 (core) artifact registry. Project binaries concatenate their own
artifacts onto this list.
-}
coreArtifacts :: [ConfigArtifact]
coreArtifacts =
    [ artifactOf "budget" budgetCodec (V.Budget 4 8 20)
    , artifactOf "podResources" podResourcesCodec (V.PodResources 1 1 1 1 2)
    , artifactOf "kindNode" kindNodeCodec (V.KindNode 4 8 20)
    ]

-- | Print the transitive union of a registry's schemas, each labelled by name.
schemaUnion :: [ConfigArtifact] -> Text
schemaUnion arts =
    T.intercalate "\n\n" ["-- " <> artifactName a <> "\n" <> schemaText a | a <- arts]

{- | Render a deploy config (a budget plus a concurrent pod set) that carries the
@Core.fitsWithin@ assertion, so an over-budget deploy fails to type-check. The
@coreImport@ is the Dhall import text for @Core.dhall@ (an absolute path in
tests; a bundled path in a deployed binary).
-}
deployConfigText :: Text -> V.Budget -> [V.PodResources] -> Text
deployConfigText coreImport budget pods =
    T.unlines
        [ "let C = " <> coreImport
        , "let budget = " <> renderValue budgetCodec budget
        , "let pods = " <> renderValue podResourcesListCodec pods
        , "in  { budget = budget"
        , "    , pods = pods"
        , "    , _fitsBudget = assert : C.fitsWithin budget pods === True"
        , "    }"
        ]
