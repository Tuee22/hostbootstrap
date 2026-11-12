{- | Primitive snapshot representations shared by the plan kernel.

Canonical admission, encoding, decoding, and descriptive projections remain in
the main library. This Cabal-private unit owns no authority or plan producer.
-}
module HostBootstrap.Lifecycle.Snapshot.Core (
    CanonicalPlanSnapshot (..),
    StablePlanSnapshot (..),
    canonicalPlanSnapshotFormatVersion,
)
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)

-- | The primitive fields retained by one exact canonical plan snapshot.
data CanonicalPlanSnapshot = CanonicalPlanSnapshot
    { internalSnapshotRoot :: FilePath
    , internalSnapshotSpecDigest :: Text
    , internalSnapshotConfigDigest :: Text
    , internalSnapshotBytes :: ByteString
    , internalSnapshotDigest :: Text
    }
    deriving (Eq)

instance Show CanonicalPlanSnapshot where
    show snapshot =
        "CanonicalPlanSnapshot<v"
            <> show canonicalPlanSnapshotFormatVersion
            <> ", "
            <> Text.unpack (internalSnapshotDigest snapshot)
            <> ">"

-- | Pure canonical bytes projected from an exact admitted plan.
newtype StablePlanSnapshot = StablePlanSnapshot CanonicalPlanSnapshot
    deriving (Eq)

instance Show StablePlanSnapshot where
    show (StablePlanSnapshot snapshot) = show snapshot

{- | The current stable wire version. Changing the schema requires a new value;
old bytes must never be reinterpreted under a new schema.
-}
canonicalPlanSnapshotFormatVersion :: Word64
canonicalPlanSnapshotFormatVersion = 8
