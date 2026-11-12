{-# LANGUAGE OverloadedStrings #-}

{- | The original WSL installation cap, under the VM's existing protected entry.

This is ordinary metadata. It supplies no registration identity, query root or
VM receipt. The guest transaction separately observes the fixed native registry
and binds its actual GUID before admitting an existing installation.
-}
module HostBootstrap.Substrate.Provider.WslDisk (
    WslDiskAdmission (..),
    encodeWslDiskCap,
    classifyWslDiskCap,
    reconcileWslDiskCap,
) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import Data.ByteString (ByteString)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyBytes
import Data.Int (Int64)
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Cordon.Foundation (ResourceBudget, budgetStorageBytes)
import HostBootstrap.Ownership.Object (OwnerClaim, OwnershipFault (OwnershipMalformed), ownerClaimText)
import HostBootstrap.Ownership.Tape (RecordSubject (RecordSubject), publishAbsentRawRecord, readRawRecordUnder, recordTape)
import HostBootstrap.Protected (
    ProtectedError, ProtectedRecord (protectedRecordBytes), ProtectedSession, mkRecordKey,
 )
import HostBootstrap.Substrate.Provider.Ownership (ProviderOwnershipFault (..))
import HostBootstrap.Substrate.Provider.Report (ProviderSizingObservation (RecordedWslStorage), providerSizingMatches)
import HostBootstrap.Wire.LittleEndian (word64LE)

-- | Only a native absence with no VM origin may begin a new installation.
data WslDiskAdmission = BeginWslInstallation | RequireRecordedWslInstallation
    deriving (Eq, Show)

diskMagic :: ByteString
diskMagic = "hostbootstrap/wsl-disk-cap/v1\0"

-- | Fixed version, exact owner hash, then one canonical unsigned little-endian cap.
encodeWslDiskCap :: OwnerClaim -> ResourceBudget -> ByteString
encodeWslDiskCap owner budget =
    diskMagic <> TextEncoding.encodeUtf8 (ownerClaimText owner)
        <> LazyBytes.toStrict (Builder.toLazyByteString (Builder.word64LE (fromInteger (budgetStorageBytes budget))))

-- | Admit complete, owner-bound, positive signed-range bytes; never native identity.
classifyWslDiskCap :: OwnerClaim -> ByteString -> Either OwnershipFault Integer
classifyWslDiskCap owner raw
    | Bytes.length raw /= Bytes.length prefix + 8 =
        malformed "the WSL disk-cap record has an invalid length"
    | not (diskMagic `Bytes.isPrefixOf` raw) =
        malformed "the WSL disk-cap record has an unknown version"
    | not (prefix `Bytes.isPrefixOf` raw) =
        malformed "the WSL disk-cap record belongs to another owner"
    | cap <= 0 || cap > toInteger (maxBound :: Int64) =
        malformed "the recorded WSL disk cap is not positive signed-range bytes"
    | otherwise = Right cap
  where
    prefix = diskMagic <> TextEncoding.encodeUtf8 (ownerClaimText owner)
    cap = toInteger (word64LE (Bytes.drop (Bytes.length prefix) raw))
    malformed = Left . OwnershipMalformed

-- | Publish before origin/install, or require the exact retained cap without a write.
reconcileWslDiskCap ::
    ProtectedSession session -> WslDiskAdmission -> OwnerClaim -> ResourceBudget ->
    IO (Either ProviderOwnershipFault ProviderSizingObservation)
reconcileWslDiskCap session admission owner declared = runExceptT $ do
    key <- store (pure (mkRecordKey "wsl-installed-storage"))
    let tape = recordTape session (RecordSubject "the original WSL disk cap" "record the original WSL disk cap")
    current <- ExceptT (readRawRecordUnder tape key)
    cap <- case current of
        Nothing -> case admission of
            RequireRecordedWslInstallation ->
                throwE (ProviderOwnershipClause
                    (OwnershipMalformed "the owned WSL installation has no recorded disk cap"))
            BeginWslInstallation -> do
                ExceptT (publishAbsentRawRecord tape key (encodeWslDiskCap owner declared))
                pure (budgetStorageBytes declared)
        Just record -> either (throwE . ProviderOwnershipClause) pure
            (classifyWslDiskCap owner (protectedRecordBytes record))
    let observed = RecordedWslStorage cap
    unless (providerSizingMatches declared observed)
        (throwE (ProviderOwnershipSizing declared observed))
    pure observed

store :: IO (Either ProtectedError value) -> ExceptT ProviderOwnershipFault IO value
store action = ExceptT (fmap (either (Left . ProviderOwnershipStore) Right) action)
