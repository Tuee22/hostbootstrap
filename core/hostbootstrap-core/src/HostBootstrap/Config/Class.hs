{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

{- | The single typeclass coupling @hostbootstrap-core@ to a project's config
type — and the @InitArgs@ record that the project's @init@ builder interprets.

The core is generic over a project's scope-indexed @<project>.dhall@ shape: it
never names a concrete config record and never pattern-matches a project cfg's
fields. It reaches only the universal read-only 'Context.BinaryContext'
projection. Everything else core does with a config goes through the admitted
scope-correct 'ProjectCodec' — never a field accessor.

A project (the demo) supplies the @ProjectCfg@ instance for its own config
family, plus the single restricted assembler that turns a closed
'AssemblyRequest' into a scoped config — the **only** place project-config
defaults live (core ships none).
-}
module HostBootstrap.Config.Class (
    ProjectCfg (..),
    TestCfg (..),
    InitArgs (..),
    AssemblyRequest (..),
    ConfigAssembly,
    ConfigInput,
    configInput,
    configInputPath,
    pureConfigAssembly,
    failConfigAssembly,
    readConfigInput,
    runConfigAssembly,
    ProjectCodec,
    withProjectCodec,
    withMappedProjectCodec,
    withFinalizedProjectCodec,
    projectCodecLabel,
    projectCodecSchemaText,
    projectCodecSpecDigest,
    decodeProjectCodecFile,
    decodeProjectCodecWithSettings,
    renderProjectCodecValue,
    renderProjectCodecHoisted,
)
where

import Control.Monad (ap)
import Data.Bits (xor)
import Data.Kind (Type)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import qualified Data.ByteString as BS
import qualified Dhall
import qualified HostBootstrap.Context as Context
import HostBootstrap.Config.Class.Internal (
    ProjectCodec (
        ProjectCodec,
        installedCodecDecodeFile,
        installedCodecDecodeWithSettings,
        installedCodecLabel,
        installedCodecRender,
        installedCodecRenderHoisted,
        installedCodecSchema,
        installedCodecSpecDigest
    ),
 )
import HostBootstrap.Config.Vocab (
    Harness,
    HarnessAuthority,
    HarnessConfigAuthority,
    Production,
 )
import HostBootstrap.Dhall.Gen (
    CodecWitness,
    codecSchemaText,
    decodeFile,
    decodeWithSettings,
    renderHoistedValue,
    renderValue,
 )
import HostBootstrap.Dhall.Hoist (NamedUnion)
import HostBootstrap.Harness (CaseId, TestMatrix, TestMatrixError, VariantDraft, emptyTestMatrix)
import Numeric.Natural (Natural)
import Data.Word (Word64, Word8)
import Numeric (showHex)
import System.IO.Error (tryIOError)

{- | A project's scope-indexed config family, coupled to the core **only**
through its admitted codec and the universal binary context it embeds. A
secrets-strict project puts 'HostBootstrap.Config.Vocab.SecretRef scope' in its
own fields; a secret-free project may use @scope@ only as a phantom index.

Core decodes/encodes @cfg scope@ via the installed Production or Harness
'ProjectCodec' and otherwise touches it solely through 'cfgContext', so the
core has no knowledge of project fields and cannot change a config's scope.
-}
class ProjectCfg (cfg :: Type -> Type) where
    {- | Install the production wire codec and its scope-preserving admission
    under a fresh specification identity.
    -}
    withProductionProjectCodec ::
        forall projectId result.
        ( forall specDigest.
          ProjectCodec (Production projectId) specDigest cfg ->
          result
        ) ->
        result

    {- | Install the harness wire codec for one exact run. A secrets-strict
    instance closes over the matching authority when converting untrusted wire
    into @cfg (Harness projectId runId)@.
    -}
    withHarnessProjectCodec ::
        forall projectId runId result.
        HarnessConfigAuthority projectId runId ->
        ( forall specDigest.
          ProjectCodec (Harness projectId runId) specDigest cfg ->
          result
        ) ->
        result

    {- | The one required accessor: the universal runtime context inside the config
    (validated against the derived project identity before command dispatch).
    -}
    cfgContext :: cfg scope -> Context.BinaryContext

{- | A project's typed test-config projection. The associated payload remains
pure data inside an opaque validated 'TestMatrix'; project-config generation is
kept in 'HostBootstrap.CLI.ProjectSpec', outside the draft.
-}
class TestCfg tcfg where
    type TestVariant tcfg
    projectTestMatrix :: [CaseId] -> tcfg -> Either TestMatrixError (TestMatrix (TestVariant tcfg))

{- | The explicit bare-core exception: it has no project cases or variants.
Real project entrypoints reject an empty 'TestSuite' before dispatch.
-}
instance TestCfg () where
    type TestVariant () = ()
    projectTestMatrix _ _ = Right emptyTestMatrix

{- | The two disjoint ways to assemble a project config. Production receives
only parsed init inputs. Harness assembly receives one generative run authority,
the decoded project-owned test config, and one already-validated pure variant
draft. The result scope is fixed by the constructor.
-}
data AssemblyRequest projectId tcfg variant scope where
    ProductionAssembly ::
        InitArgs ->
        AssemblyRequest projectId tcfg variant (Production projectId)
    HarnessAssembly ::
        HarnessAuthority projectId runId ->
        FilePath ->
        tcfg ->
        VariantDraft variant ->
        AssemblyRequest projectId tcfg variant (Harness projectId runId)

-- | One project-declared, read-only assembly input.
newtype ConfigInput = ConfigInput FilePath
    deriving (Eq, Show)

-- | Declare a path an assembler may read.
configInput :: FilePath -> ConfigInput
configInput = ConfigInput

-- | The declared path represented by an assembly input.
configInputPath :: ConfigInput -> FilePath
configInputPath (ConfigInput path) = path

{- | A restricted config-assembly program. It can return/fail and read only a
path declared on the installed project spec. It has no general 'IO', backend,
process, write, or lifecycle operation.
-}
data ConfigAssembly scope a where
    AssemblyPure :: a -> ConfigAssembly scope a
    AssemblyFail :: String -> ConfigAssembly scope a
    AssemblyRead :: ConfigInput -> (Text -> ConfigAssembly scope a) -> ConfigAssembly scope a

instance Functor (ConfigAssembly scope) where
    fmap f assembly = assembly >>= pure . f

instance Applicative (ConfigAssembly scope) where
    pure = AssemblyPure
    (<*>) = ap

instance Monad (ConfigAssembly scope) where
    AssemblyPure value >>= next = next value
    AssemblyFail err >>= _ = AssemblyFail err
    AssemblyRead input next >>= after =
        AssemblyRead input (\value -> next value >>= after)

-- | Lift a pure config into restricted assembly.
pureConfigAssembly :: a -> ConfigAssembly scope a
pureConfigAssembly = AssemblyPure

-- | Stop restricted assembly with a project-owned diagnostic.
failConfigAssembly :: String -> ConfigAssembly scope a
failConfigAssembly = AssemblyFail

-- | Read one declared text input during assembly.
readConfigInput :: ConfigInput -> ConfigAssembly scope Text
readConfigInput input = AssemblyRead input AssemblyPure

{- | Interpret restricted assembly. Undeclared paths fail before a read; read
errors are returned as data. There is intentionally no interpreter hook for
arbitrary project IO.
-}
runConfigAssembly ::
    [ConfigInput] ->
    ConfigAssembly scope a ->
    IO (Either String a)
runConfigAssembly allowed = go
  where
    go (AssemblyPure value) = pure (Right value)
    go (AssemblyFail err) = pure (Left err)
    go (AssemblyRead input next)
        | input `notElem` allowed =
            pure
                ( Left
                    ( "config assembly attempted an undeclared read: "
                        ++ configInputPath input
                    )
                )
        | otherwise = do
            result <- tryIOError (TIO.readFile (configInputPath input))
            case result of
                Left err ->
                    pure
                        ( Left
                            ( "config assembly could not read "
                                ++ configInputPath input
                                ++ ": "
                                ++ show err
                            )
                        )
                Right value -> go (next value)

{- | Install a codec under a fresh specification identity. The rank-2 digest
index cannot be selected or reused by the caller.
-}
withProjectCodec ::
    Text ->
    CodecWitness (cfg scope) ->
    (forall specDigest. ProjectCodec scope specDigest cfg -> result) ->
    result
withProjectCodec label codec use =
    let schema = codecSchemaText codec
        digest = canonicalSpecDigest (label <> "\n" <> schema)
     in
    use
        ProjectCodec
            { installedCodecLabel = label
            , installedCodecSchema = schema
            , installedCodecSpecDigest = digest
            , installedCodecDecodeFile = decodeFile codec
            , installedCodecDecodeWithSettings = decodeWithSettings codec
            , installedCodecRender = renderValue codec
            , installedCodecRenderHoisted = renderHoistedValue codec
            }

{- | Install a scoped config codec through an untrusted wire type. Rendering
projects to wire; decoding first admits the wire through its lower witness and
then performs the scope/authority-aware conversion. This is the secrets-strict
path: the scoped config itself needs no public 'Dhall.FromDhall' instance.
-}
withMappedProjectCodec ::
    Text ->
    CodecWitness wire ->
    (cfg scope -> wire) ->
    (wire -> Either String (cfg scope)) ->
    (forall specDigest. ProjectCodec scope specDigest cfg -> result) ->
    result
withMappedProjectCodec label wireCodec toWire fromWire use =
    let schema = codecSchemaText wireCodec
        digest = canonicalSpecDigest (label <> "\n" <> schema)
     in
    use
        ProjectCodec
            { installedCodecLabel = label
            , installedCodecSchema = schema
            , installedCodecSpecDigest = digest
            , installedCodecDecodeFile =
                \path -> decodeFile wireCodec path >>= admit
            , installedCodecDecodeWithSettings =
                \settings input ->
                    decodeWithSettings wireCodec settings input >>= admit
            , installedCodecRender = renderValue wireCodec . toWire
            , installedCodecRenderHoisted =
                \unions -> renderHoistedValue wireCodec unions . toWire
            }
  where
    admit wire =
        case fromWire wire of
            Left err -> ioError (userError err)
            Right value -> pure value

{- | Re-index an installed full-config codec under a fresh final specification
identity after hashing the closed extension manifest (role codecs, service
identities, and their schemas). The caller cannot choose the phantom identity;
the runtime digest is retained on the returned codec.
-}
withFinalizedProjectCodec ::
    ProjectCodec scope initialDigest cfg ->
    Text ->
    (forall specDigest. ProjectCodec scope specDigest cfg -> result) ->
    result
withFinalizedProjectCodec codec extensionManifest use =
    use
        ProjectCodec
            { installedCodecLabel = installedCodecLabel codec
            , installedCodecSchema = installedCodecSchema codec
            , installedCodecSpecDigest =
                canonicalSpecDigest
                    ( installedCodecLabel codec
                        <> "\n"
                        <> installedCodecSchema codec
                        <> "\n"
                        <> extensionManifest
                    )
            , installedCodecDecodeFile = installedCodecDecodeFile codec
            , installedCodecDecodeWithSettings = installedCodecDecodeWithSettings codec
            , installedCodecRender = installedCodecRender codec
            , installedCodecRenderHoisted = installedCodecRenderHoisted codec
            }

-- | Descriptive installed-project label; it carries no construction authority.
projectCodecLabel :: ProjectCodec scope specDigest cfg -> Text
projectCodecLabel = installedCodecLabel

-- | Reflected schema accepted by this installed scoped codec.
projectCodecSchemaText :: ProjectCodec scope specDigest cfg -> Text
projectCodecSchemaText = installedCodecSchema

-- | Canonical digest of the jointly finalized full/role specification.
projectCodecSpecDigest :: ProjectCodec scope specDigest cfg -> Text
projectCodecSpecDigest = installedCodecSpecDigest

-- | Decode one project config file through the installed scoped codec.
decodeProjectCodecFile ::
    ProjectCodec scope specDigest cfg ->
    FilePath ->
    IO (cfg scope)
decodeProjectCodecFile = installedCodecDecodeFile

-- | Decode project config text with explicit Dhall input settings.
decodeProjectCodecWithSettings ::
    ProjectCodec scope specDigest cfg ->
    Dhall.InputSettings ->
    Text ->
    IO (cfg scope)
decodeProjectCodecWithSettings = installedCodecDecodeWithSettings

-- | Render a project config through its installed scoped codec.
renderProjectCodecValue ::
    ProjectCodec scope specDigest cfg ->
    cfg scope ->
    Text
renderProjectCodecValue = installedCodecRender

-- | Render a project config with the selected vocabulary unions hoisted.
renderProjectCodecHoisted ::
    ProjectCodec scope specDigest cfg ->
    [NamedUnion] ->
    cfg scope ->
    Text
renderProjectCodecHoisted = installedCodecRenderHoisted

canonicalSpecDigest :: Text -> Text
canonicalSpecDigest input =
    T.pack (replicate (16 - length rendered) '0' ++ rendered)
  where
    rendered = showHex digest ""
    digest = BS.foldl' step fnvOffset (TE.encodeUtf8 input)
    step :: Word64 -> Word8 -> Word64
    step acc byte = (acc `xor` fromIntegral byte) * fnvPrime
    fnvOffset = 14695981039346656037 :: Word64
    fnvPrime = 1099511628211 :: Word64

{- | The raw, parsed @init@ flags shared by @project init@, @service init@, and
the test harness' config generation. The role/context selectors are required
to shape the
context; the project-tunable knobs are **generic optionals** (core supplies no
value for any of them), so a project's @init@ builder fills the omitted ones
with the project's own defaults. The 'force' / 'ifMissing' switches drive the
idempotent write behaviour.
-}
data InitArgs = InitArgs
    { role :: Context.ContextKind
    -- ^ the primary role the generated config declares
    , alsoRoles :: [Context.ContextKind]
    -- ^ additional roles unioned into the context's authority (multi-role)
    , output :: Maybe FilePath
    -- ^ where to write the generated config (default: the executable sibling)
    , sourceRoot :: Maybe FilePath
    -- ^ the source root recorded in the generated context (default: cwd)
    , mCpu :: Maybe Natural
    -- ^ CPU budget (project default when omitted)
    , memory :: Maybe Text
    -- ^ memory budget (project default when omitted)
    , storage :: Maybe Text
    -- ^ storage budget (project default when omitted)
    , dockerfile :: Maybe Text
    -- ^ Dockerfile path recorded in the config (project default when omitted)
    , haReplicas :: Maybe Natural
    -- ^ HA replica count (project default when omitted)
    , force :: Bool
    -- ^ overwrite an existing OUTPUT
    , ifMissing :: Bool
    -- ^ no-op when OUTPUT already exists (idempotent ensure)
    }
    deriving (Eq, Show)
