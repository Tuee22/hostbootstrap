{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}

-- | Private platform primitives for durable same-directory publication.
-- Protected records and private cluster credentials compose this same protocol.
module HostBootstrap.Protected.Publication (
    syncPublishedFile,
    renamePublishedFile,
    syncPublishedParent,
) where

import Control.Exception (bracket)
#if !defined(mingw32_HOST_OS)
import System.Directory (renameFile)
import System.FilePath (takeDirectory)
import System.Posix.IO (OpenFileFlags (cloexec), OpenMode (ReadOnly, ReadWrite), closeFd, defaultFileFlags, openFd)
import System.Posix.Unistd (fileSynchronise)
#if defined(darwin_HOST_OS)
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.Types (CInt (..))
import System.Posix.Types (Fd (Fd))
#else
import System.Posix.Types (Fd)
#endif
#else
import Data.Bits ((.|.))
import Data.List (isPrefixOf)
import System.Win32.File (MoveFileFlag, closeHandle, createFile, fILE_ATTRIBUTE_NORMAL, fILE_SHARE_READ,
    flushFileBuffers, gENERIC_WRITE, mOVEFILE_REPLACE_EXISTING, moveFileEx, oPEN_EXISTING)
import System.Win32.Info (getFullPathName)
#endif

-- | Reopen the closed temporary, sync its data, and close the native handle.
syncPublishedFile :: FilePath -> IO ()
#if defined(mingw32_HOST_OS)
syncPublishedFile path = do
    nativePath <- windowsPublishedPath path
    bracket
        (createFile nativePath gENERIC_WRITE fILE_SHARE_READ Nothing oPEN_EXISTING fILE_ATTRIBUTE_NORMAL Nothing)
        closeHandle
        flushFileBuffers
#else
syncPublishedFile path =
    bracket (openFd path ReadWrite defaultFileFlags{cloexec = True}) closeFd syncPublishedDescriptor
#endif

-- | Replace in the same directory, without a cross-volume copy fallback.
renamePublishedFile :: FilePath -> FilePath -> IO ()
#if defined(mingw32_HOST_OS)
renamePublishedFile source destination = do
    nativeSource <- windowsPublishedPath source
    nativeDestination <- windowsPublishedPath destination
    moveFileEx nativeSource (Just nativeDestination) (mOVEFILE_REPLACE_EXISTING .|. moveFileWriteThrough)

-- Native Win32 wrappers encode strings without furnishing long paths. Preserve
-- explicit namespaces, and normalize ordinary absolute local/UNC paths before
-- adding their extended prefix, independently of the host's registry policy.
windowsPublishedPath :: FilePath -> IO FilePath
windowsPublishedPath path
    | isPrefixOf "\\\\?\\" path || isPrefixOf "\\\\.\\" path = pure path
    | otherwise = do
        absolute <- getFullPathName path
        pure $
            if isPrefixOf "\\\\" absolute
                then "\\\\?\\UNC\\" <> drop 2 absolute
                else "\\\\?\\" <> absolute

-- Win32 exposes moveFileEx but omits this SDK constant from its public module.
foreign import capi unsafe "windows.h value MOVEFILE_WRITE_THROUGH"
    moveFileWriteThrough :: MoveFileFlag
#else
renamePublishedFile = renameFile
#endif

-- | Sync the POSIX directory after rename. Darwin then requests the drive-wide
-- flush through the published regular file, after the directory's changes,
-- without assuming F_FULLFSYNC accepts directory descriptors.
syncPublishedParent :: FilePath -> IO ()
#if defined(mingw32_HOST_OS)
syncPublishedParent _destination = pure ()
#else
syncPublishedParent destination = do
    bracket (openFd (takeDirectory destination) ReadOnly defaultFileFlags{cloexec = True}) closeFd fileSynchronise
#if defined(darwin_HOST_OS)
    syncPublishedFile destination
#endif
#endif

#if !defined(mingw32_HOST_OS)
-- Darwin's stronger operation includes fsync and asks the drive to flush its
-- cache too. Failure propagates; falling back would weaken the acknowledged
-- publication's guarantee. Other POSIX kernels use their file sync primitive.
syncPublishedDescriptor :: Fd -> IO ()
#if defined(darwin_HOST_OS)
syncPublishedDescriptor (Fd descriptor) =
    throwErrnoIfMinus1_ "fcntl(F_FULLFSYNC)" (c_fcntlFullSync descriptor fullFsyncCommand)

foreign import capi safe "fcntl.h fcntl"
    c_fcntlFullSync :: CInt -> CInt -> IO CInt

foreign import capi unsafe "fcntl.h value F_FULLFSYNC"
    fullFsyncCommand :: CInt
#else
syncPublishedDescriptor = fileSynchronise
#endif
#endif

