{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The host's stable-kernel-identity backend for the harness data root
(clause 3 of @development_plan_standards.md § EE@).

Both realizations read the identity of the object the path currently names
without following a symbolic link, so a path swapped for a link elsewhere reads
as a /different/ object rather than as the target's identity:

* POSIX — @lstat@'s @(st_dev, st_ino)@ pair, the same binding the provider
  guest-alias and WSL host-wall backends use;
* Windows — the volume serial number plus file index from
  @GetFileInformationByHandle@ on a handle opened with
  @FILE_FLAG_BACKUP_SEMANTICS@ (required to open a directory at all) and
  @FILE_FLAG_OPEN_REPARSE_POINT@ (so a reparse point is not followed).

Both encode the volume word first, little-endian, matching the encoding the
other ownership backends already use.  An authoritative absence is
@Right Nothing@; anything else is a typed failure, never a false absence
(§ CC) — so a host whose error mapping does not report absence distinctly
produces a refusal rather than a spurious "nothing there".
-}
module HostBootstrap.Harness.DataRoot.Native (
    nativeDataRootIdentityBackend,
) where

import Control.Exception.Safe (try)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Harness.DataRoot (
    DataRootError (DataRootFailure),
    DataRootIdentity,
    DataRootIdentityBackend (DataRootIdentityBackend),
    mkDataRootIdentity,
 )
import System.IO.Error (isDoesNotExistError)

#if defined(mingw32_HOST_OS)
import Control.Exception.Safe (bracket)
import Data.Bits ((.|.))
import System.Win32.File (
    BY_HANDLE_FILE_INFORMATION (bhfiFileIndex, bhfiVolumeSerialNumber),
    closeHandle,
    createFile,
    fILE_FLAG_BACKUP_SEMANTICS,
    fILE_FLAG_OPEN_REPARSE_POINT,
    fILE_SHARE_DELETE,
    fILE_SHARE_READ,
    fILE_SHARE_WRITE,
    gENERIC_READ,
    getFileInformationByHandle,
    oPEN_EXISTING,
 )
#else
import System.Posix.Files (deviceID, fileID, getSymbolicLinkStatus)
#endif

-- | The identity backend for the host this binary was built for.
nativeDataRootIdentityBackend :: DataRootIdentityBackend
nativeDataRootIdentityBackend = DataRootIdentityBackend observe

observe :: FilePath -> IO (Either DataRootError (Maybe DataRootIdentity))
observe path = do
    outcome <- try (readObjectIdentity path)
    case outcome of
        Left failure
            | isDoesNotExistError failure -> pure (Right Nothing)
            | otherwise -> pure (Left (probeFailure path failure))
        Right (volume, index) ->
            pure (fmap Just (mkDataRootIdentity (encodeIdentity volume index)))

probeFailure :: FilePath -> IOError -> DataRootError
probeFailure path failure =
    DataRootFailure
        ("observe the identity of " <> asText path)
        (asText (show failure))

asText :: String -> Text
asText = Text.pack

-- | Volume word first, little-endian, as the peer ownership backends encode it.
encodeIdentity :: Word64 -> Word64 -> ByteString.ByteString
encodeIdentity volume index =
    LazyByteString.toStrict
        ( Builder.toLazyByteString
            (Builder.word64LE volume <> Builder.word64LE index)
        )

-- | @(volume, index)@ for the object the path names, not following a link.
readObjectIdentity :: FilePath -> IO (Word64, Word64)

#if defined(mingw32_HOST_OS)
readObjectIdentity path =
    bracket open closeHandle $ \handle -> do
        information <- getFileInformationByHandle handle
        pure
            ( fromIntegral (bhfiVolumeSerialNumber information)
            , bhfiFileIndex information
            )
  where
    open =
        createFile
            path
            gENERIC_READ
            (fILE_SHARE_READ .|. fILE_SHARE_WRITE .|. fILE_SHARE_DELETE)
            Nothing
            oPEN_EXISTING
            (fILE_FLAG_BACKUP_SEMANTICS .|. fILE_FLAG_OPEN_REPARSE_POINT)
            Nothing
#else
readObjectIdentity path = do
    status <- getSymbolicLinkStatus path
    pure (fromIntegral (deviceID status), fromIntegral (fileID status))
#endif
