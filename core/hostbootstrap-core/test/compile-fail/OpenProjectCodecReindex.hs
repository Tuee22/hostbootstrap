module OpenProjectCodecReindex where

-- The public config facade exposes the installed codec abstractly: no caller
-- can name its constructor, read its representation, or relabel its
-- specification index.
import HostBootstrap.Config.Class
    ( ProjectCodec (ProjectCodec)
    , installedCodecSpecDigest
    , reindexProjectCodecKernel
    )
