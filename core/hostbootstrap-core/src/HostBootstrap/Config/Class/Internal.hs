{-# LANGUAGE RoleAnnotations #-}

{- | Package-private representation and exact specification relabelling for the
installed scope-correct project codec.

'HostBootstrap.Config.Class' re-exports 'ProjectCodec' abstractly together with
every producer and eliminator it owns; the representation stays here so the
nominal specification phantom has exactly one relabelling site.  A codec
admitted under a durably recovered specification index and one finalized in this
invocation are distinct types even when their digests are equal, and the only
authority that can join them is the digest-equality token minted by
'HostBootstrap.Config.Schema.Internal'.
-}
module HostBootstrap.Config.Class.Internal
    ( ProjectCodec (..)
    , reindexProjectCodecKernel
    )
where

import Data.Text (Text)
import qualified Dhall
import HostBootstrap.Config.Schema.Internal
    ( RecoverySpecReindex
    , recoverySpecReindexDigestKernel
    )
import HostBootstrap.Dhall.Hoist (NamedUnion)

{- | An installed, scope-correct wrapper around the lower admitted
'HostBootstrap.Dhall.Gen.CodecWitness'.  The constructor and @specDigest@
identity are hidden.
-}
data ProjectCodec scope specDigest cfg = ProjectCodec
    { installedCodecLabel :: Text
    , installedCodecSchema :: Text
    , installedCodecSpecDigest :: Text
    , installedCodecDecodeFile :: FilePath -> IO (cfg scope)
    , installedCodecDecodeWithSettings ::
        Dhall.InputSettings ->
        Text ->
        IO (cfg scope)
    , installedCodecRender :: cfg scope -> Text
    , installedCodecRenderHoisted :: [NamedUnion] -> cfg scope -> Text
    }

type role ProjectCodec nominal nominal nominal

{- | Change only the specification phantom of an installed codec, and only after
the token's expected digest exactly matches the codec's own retained
specification digest.

The retained label, schema, digest, decoders, and renderers are preserved
unchanged: this relabels an index, it never installs a second codec.  The caller
supplies no digest of its own, so an unequal pair is a refusal rather than a
silently accepted relabelling.
-}
reindexProjectCodecKernel ::
    RecoverySpecReindex targetSpecDigest ->
    ProjectCodec scope sourceSpecDigest cfg ->
    Either (Text, Text) (ProjectCodec scope targetSpecDigest cfg)
reindexProjectCodecKernel token codec
    | expected == observed =
        Right
            ProjectCodec
                { installedCodecLabel = installedCodecLabel codec
                , installedCodecSchema = installedCodecSchema codec
                , installedCodecSpecDigest = installedCodecSpecDigest codec
                , installedCodecDecodeFile = installedCodecDecodeFile codec
                , installedCodecDecodeWithSettings = installedCodecDecodeWithSettings codec
                , installedCodecRender = installedCodecRender codec
                , installedCodecRenderHoisted = installedCodecRenderHoisted codec
                }
    | otherwise = Left (expected, observed)
  where
    expected = recoverySpecReindexDigestKernel token
    observed = installedCodecSpecDigest codec
