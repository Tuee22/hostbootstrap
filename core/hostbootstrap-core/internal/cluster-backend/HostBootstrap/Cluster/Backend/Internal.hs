module HostBootstrap.Cluster.Backend.Internal (
    StrongClusterBackend,
    mkStrongClusterBackend,
    strongClusterHostConfig,
    strongClusterDriver,
    strongClusterConfigBytes,
    strongClusterConfigDigest,
    strongClusterOwnershipIdentity,
    strongClusterKubeconfigPath,
    strongClusterReadinessVersion,
) where

import Data.ByteString (ByteString)
import Data.IORef (IORef)
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Cluster.Lifecycle (ClusterDriver)
import HostBootstrap.HostConfig (HostConfig)

-- | Hidden capability retaining one exact plan-owned driver discovery.
data StrongClusterBackend
    = StrongClusterBackend
        HostConfig
        ClusterDriver
        ByteString
        Text
        Text
        FilePath
        (IORef Word64)

mkStrongClusterBackend :: HostConfig -> ClusterDriver -> ByteString -> Text -> Text -> FilePath -> IORef Word64 -> StrongClusterBackend
mkStrongClusterBackend = StrongClusterBackend

strongClusterHostConfig :: StrongClusterBackend -> HostConfig
strongClusterHostConfig (StrongClusterBackend cfg _ _ _ _ _ _) = cfg

strongClusterDriver :: StrongClusterBackend -> ClusterDriver
strongClusterDriver (StrongClusterBackend _ driver _ _ _ _ _) = driver

strongClusterConfigBytes :: StrongClusterBackend -> ByteString
strongClusterConfigBytes (StrongClusterBackend _ _ bytes _ _ _ _) = bytes

strongClusterConfigDigest :: StrongClusterBackend -> Text
strongClusterConfigDigest (StrongClusterBackend _ _ _ digest _ _ _) = digest

strongClusterOwnershipIdentity :: StrongClusterBackend -> Text
strongClusterOwnershipIdentity (StrongClusterBackend _ _ _ _ owner _ _) = owner

strongClusterKubeconfigPath :: StrongClusterBackend -> FilePath
strongClusterKubeconfigPath (StrongClusterBackend _ _ _ _ _ path _) = path

strongClusterReadinessVersion :: StrongClusterBackend -> IORef Word64
strongClusterReadinessVersion (StrongClusterBackend _ _ _ _ _ _ version) = version
