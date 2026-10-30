{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}

-- | Native Windows capacity reads, with an explicit refusal on other hosts.
module HostBootstrap.Cluster.Cordon.WindowsCapacity (
    WindowsCapacityError (..),
    readWindowsLogicalProcessors,
    readWindowsTotalMemory,
    readWindowsSystemDriveFreeSpace,
    renderWindowsCapacityError,
) where

#if defined(mingw32_HOST_OS)
import Control.Exception (IOException, displayException, try)
import Control.Monad (when)
import Data.Word (Word64)
import Foreign.Marshal.Alloc (allocaBytesAligned)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekByteOff, pokeByteOff)
import System.FilePath (takeDrive)
import System.Win32.Info (getSystemInfo, getWindowsDirectory, siNumberOfProcessors)
import System.Win32.Types (BOOL, DWORD, LPCTSTR, failIfFalse_, withFilePath)
#endif

data WindowsCapacityError
    = WindowsCapacityUnsupported
    | WindowsCapacityApiFailure String String
    | WindowsCapacityNonPositive String Integer
    deriving (Eq, Show)

renderWindowsCapacityError :: WindowsCapacityError -> String
renderWindowsCapacityError failure = case failure of
    WindowsCapacityUnsupported -> "native Windows capacity is unavailable on this host"
    WindowsCapacityApiFailure operation detail -> operation ++ ": " ++ detail
    WindowsCapacityNonPositive operation value ->
        operation ++ " returned a non-positive capacity: " ++ show value

readWindowsLogicalProcessors :: IO (Either WindowsCapacityError Integer)
readWindowsTotalMemory :: IO (Either WindowsCapacityError Integer)
readWindowsSystemDriveFreeSpace :: IO (Either WindowsCapacityError Integer)

#if defined(mingw32_HOST_OS)
readWindowsLogicalProcessors =
    readPositive "GetSystemInfo" (toInteger . siNumberOfProcessors <$> getSystemInfo)

readWindowsTotalMemory =
    readPositive "GlobalMemoryStatusEx" $
        -- MEMORYSTATUSEX has two DWORDs followed by seven DWORDLONGs: 64 bytes.
        -- dwLength must be initialized; ullTotalPhys starts at byte 8.
        allocaBytesAligned 64 8 $ \buffer -> do
            pokeByteOff buffer 0 (64 :: DWORD)
            failIfFalse_ "GlobalMemoryStatusEx" (rawGlobalMemoryStatusEx buffer)
            toInteger <$> (peekByteOff buffer 8 :: IO Word64)

readWindowsSystemDriveFreeSpace =
    readPositive "GetDiskFreeSpaceExW" $ do
        systemVolume <- takeDrive <$> getWindowsDirectory
        when (null systemVolume) $
            ioError (userError "the native Windows directory has no system volume")
        withFilePath systemVolume $ \wideVolume ->
            allocaBytesAligned 8 8 $ \available ->
                allocaBytesAligned 8 8 $ \total ->
                    allocaBytesAligned 8 8 $ \free -> do
                        failIfFalse_ "GetDiskFreeSpaceExW" $
                            rawGetDiskFreeSpaceExW wideVolume available total free
                        -- The caller's available bytes respect any disk quota.
                        toInteger <$> (peekByteOff available 0 :: IO Word64)

readPositive :: String -> IO Integer -> IO (Either WindowsCapacityError Integer)
readPositive operation action = do
    result <- try action
    pure $ case result of
        Left failure -> Left (WindowsCapacityApiFailure operation (displayException (failure :: IOException)))
        Right value
            | value > 0 -> Right value
            | otherwise -> Left (WindowsCapacityNonPositive operation value)

-- Win32's public wrappers omit these two APIs. Keep the native boundary narrow
-- and use the SDK declarations and Win32's public BOOL/string representations.
foreign import capi unsafe "windows.h GlobalMemoryStatusEx"
    rawGlobalMemoryStatusEx :: Ptr () -> IO BOOL

foreign import capi unsafe "windows.h GetDiskFreeSpaceExW"
    rawGetDiskFreeSpaceExW :: LPCTSTR -> Ptr () -> Ptr () -> Ptr () -> IO BOOL
#else
readWindowsLogicalProcessors = pure (Left WindowsCapacityUnsupported)
readWindowsTotalMemory = pure (Left WindowsCapacityUnsupported)
readWindowsSystemDriveFreeSpace = pure (Left WindowsCapacityUnsupported)
#endif
