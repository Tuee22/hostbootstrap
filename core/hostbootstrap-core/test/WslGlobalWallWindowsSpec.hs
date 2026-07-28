{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module WslGlobalWallWindowsSpec (tests) where

import qualified Data.ByteString as ByteString
import HostBootstrap.Wsl2.GlobalWall.Windows
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (
    assertFailure,
    testCase,
    (@?=),
 )

#if defined(mingw32_HOST_OS)
import Test.Tasty.HUnit (assertBool)
import Control.Concurrent (rtsSupportsBoundThreads, runInBoundThread, yield)
import Control.Exception (bracket)
import Control.Monad (replicateM_)
import Data.ByteString (ByteString)
import Data.List (isSuffixOf)
import Data.Word (Word8, Word32)
import Foreign.C.String (peekCWString, withCWString)
import Foreign.C.Types (CInt (..), CSize (..), CWchar)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

foreign import ccall safe "hb_wsl_create_stage"
  cCreateStage ::
    Ptr CWchar ->
    Ptr Word8 ->
    CSize ->
    Ptr (Ptr ()) ->
    Ptr Word8 ->
    IO Word32

foreign import ccall safe "hb_wsl_link_armed_stage"
  cLinkArmedStage ::
    Ptr () ->
    Ptr CWchar ->
    Ptr CWchar ->
    IO Word32

foreign import ccall safe "hb_wsl_open_exclusive"
  cOpenExclusive ::
    Ptr CWchar ->
    Ptr (Ptr ()) ->
    Ptr Word8 ->
    Ptr (Ptr Word8) ->
    Ptr CSize ->
    Ptr CInt ->
    IO Word32

foreign import ccall safe "hb_wsl_probe_identity"
  cProbeIdentity ::
    Ptr CWchar ->
    Ptr Word8 ->
    Ptr CInt ->
    IO Word32

foreign import ccall safe "hb_wsl_get_target_path"
  cGetTargetPath :: Ptr (Ptr CWchar) -> IO Word32

foreign import ccall safe "hb_wsl_mutex_acquire"
  cMutexAcquire :: Ptr (Ptr ()) -> Ptr CInt -> IO Word32

foreign import ccall safe "hb_wsl_mutex_release"
  cMutexRelease :: Ptr () -> IO Word32

foreign import ccall safe "hb_wsl_rename_handle_noreplace"
  cRenameHandleNoReplace :: Ptr () -> Ptr CWchar -> IO Word32

foreign import ccall safe "hb_wsl_delete_handle"
  cDeleteHandle :: Ptr () -> IO Word32

foreign import ccall safe "hb_wsl_close_handle"
  cCloseHandle :: Ptr () -> IO Word32

foreign import ccall unsafe "hb_wsl_free"
  cFree :: Ptr value -> IO ()
#endif

managedBody :: [ByteString.ByteString]
managedBody =
    [ "[general]"
    , "instanceIdleTimeout=21600000"
    , "[wsl2]"
    , "processors=4"
    , "memory=8GB"
    , "swap=8GB"
    , "vmIdleTimeout=21600000"
    ]

tests :: TestTree
tests =
    testGroup
        "WslGlobalWallWindowsSpec"
#if defined(mingw32_HOST_OS)
    [ testCase "armed hard-link handoff preserves FILE_ID and raw bytes after close" $
        withSystemTempDirectory "hostbootstrap-wall-native" $ \directory -> do
          let armed = directory </> "armed"
              bound = directory </> "bound"
              moved = directory </> "moved"
              alias = directory </> "alias"
              occupied = directory </> "occupied"
              payload = ByteString.pack [0, 255, 13, 10, 1, 2, 3]
          (armedHandle, armedIdentity) <- createArmed armed payload
          linkStatus <- linkPath armedHandle armed bound
          linkStatus @?= 0
          doesFileExist armed >>= assertBool "armed link exists before close"
          doesFileExist bound >>= assertBool "bound link exists before close"
          cCloseHandle armedHandle >>= (@?= 0)
          doesFileExist armed >>= (@?= False)
          doesFileExist bound >>= (@?= True)

          (boundHandle, boundIdentity, boundBytes) <- openPresent bound
          ByteString.length boundIdentity @?= 24
          boundIdentity @?= armedIdentity
          boundBytes @?= payload
          renameStatus <-
            withCWString moved (cRenameHandleNoReplace boundHandle)
          renameStatus @?= 0
          cCloseHandle boundHandle >>= (@?= 0)
          doesFileExist bound >>= (@?= False)
          doesFileExist moved >>= (@?= True)

          (movedHandle, movedIdentity, movedBytes) <- openPresent moved
          movedIdentity @?= armedIdentity
          movedBytes @?= payload
          linkPath movedHandle moved alias >>= (@?= 0)
          cCloseHandle movedHandle >>= (@?= 0)

          (exclusiveHandle, _, _) <- openPresent moved
          secondStatus <- openStatus alias
          secondStatus @?= 32
          probeIdentity alias >>= (@?= Just armedIdentity)
          cCloseHandle exclusiveHandle >>= (@?= 0)

          ByteString.writeFile occupied "foreign"
          (renameHandle, _, _) <- openPresent moved
          noReplaceStatus <-
            withCWString occupied (cRenameHandleNoReplace renameHandle)
          assertBool "no-replace rename refuses an occupied target" (noReplaceStatus /= 0)
          cCloseHandle renameHandle >>= (@?= 0)
          ByteString.readFile occupied >>= (@?= "foreign")

          bracket
            (openPresent moved)
            (\(handle, _, _) -> cCloseHandle handle >>= (@?= 0))
            (\(handle, _, _) -> cDeleteHandle handle >>= (@?= 0))
          doesFileExist moved >>= (@?= False)
          doesFileExist alias >>= (@?= True)
          bracket
            (openPresent alias)
            (\(handle, _, _) -> cCloseHandle handle >>= (@?= 0))
            (\(handle, _, _) -> cDeleteHandle handle >>= (@?= 0))
          doesFileExist alias >>= (@?= False),
      testCase "production API is Windows-only and accepts no target path" $ do
        windowsGlobalWallSupported @?= True
        case
            mkCurrentUserWallRequest
              "owner"
              "spec"
              "reservation"
              "receipt"
              managedBody
          of
            Left err -> assertFailure ("unexpected request error: " ++ show err)
            Right _ -> pure (),
      testCase "invalid managed input has a structured configuration error" $
        case
            mkCurrentUserWallRequest
              "owner"
              "spec"
              "reservation"
              "receipt"
              (managedBody ++ ["processors=8"])
          of
            Left (WindowsWallConfigurationFailure _) -> pure ()
            result ->
              assertFailure
                ("expected structured configuration failure, got " ++ show result),
      testCase "named mutex bracket runs on a bound OS thread" $ do
        assertBool
          "the Windows test executable is linked with the threaded RTS"
          rtsSupportsBoundThreads
        runInBoundThread $
          bracket
            acquireNativeMutex
            (\mutex -> cMutexRelease mutex >>= (@?= 0))
            (\_ -> replicateM_ 256 yield),
      testCase "Known Folder target resolution owns its COM lifetime" $ do
        target <- runInBoundThread getNativeTarget
        assertBool
          ("expected an extended .wslconfig path, got " ++ target)
          ("\\.wslconfig" `isSuffixOf` target)
    ]
#else
    [ testCase "off-Windows adapter is total Unsupported" $ do
        windowsGlobalWallSupported @?= False
        case
            mkCurrentUserWallRequest
              "owner"
              "spec"
              "reservation"
              "receipt"
              managedBody
          of
            Left err -> assertFailure ("unexpected request error: " ++ show err)
            Right request -> do
              result <- applyCurrentUserGlobalWall request
              case result of
                Left (WindowsWallUnsupported _) -> pure ()
                _ -> assertFailure ("expected Unsupported, got " ++ show result),
      testCase "invalid managed input has a structured configuration error" $
        case
            mkCurrentUserWallRequest
              "owner"
              "spec"
              "reservation"
              "receipt"
              (managedBody ++ ["processors=8"])
          of
            Left (WindowsWallConfigurationFailure _) -> pure ()
            result ->
              assertFailure
                ("expected structured configuration failure, got " ++ show result)
    ]
#endif

#if defined(mingw32_HOST_OS)
createArmed :: FilePath -> ByteString -> IO (Ptr (), ByteString)
createArmed path bytes =
  withCWString path $ \widePath ->
    ByteString.useAsCStringLen bytes $ \(bytesPointer, bytesLength) ->
      alloca $ \handlePointer ->
        allocaBytes 24 $ \identityPointer -> do
          status <-
            cCreateStage
              widePath
              (castPtr bytesPointer)
              (fromIntegral bytesLength)
              handlePointer
              identityPointer
          status @?= 0
          handle <- peek handlePointer
          identity <-
            ByteString.packCStringLen (castPtr identityPointer, 24)
          pure (handle, identity)

linkPath :: Ptr () -> FilePath -> FilePath -> IO Word32
linkPath handle source destination =
  withCWString source $ \sourcePath ->
    withCWString destination $ \destinationPath ->
      cLinkArmedStage handle sourcePath destinationPath

openPresent :: FilePath -> IO (Ptr (), ByteString, ByteString)
openPresent path =
  withCWString path $ \widePath ->
    alloca $ \handlePointer ->
      allocaBytes 24 $ \identityPointer ->
        alloca $ \bytesPointer ->
          alloca $ \lengthPointer ->
            alloca $ \presentPointer -> do
              status <-
                cOpenExclusive
                  widePath
                  handlePointer
                  identityPointer
                  bytesPointer
                  lengthPointer
                  presentPointer
              status @?= 0
              CInt present <- peek presentPointer
              present @?= 1
              handle <- peek handlePointer
              identity <-
                ByteString.packCStringLen (castPtr identityPointer, 24)
              nativeBytes <- peek bytesPointer
              CSize lengthValue <- peek lengthPointer
              bytes <-
                if lengthValue == 0
                  then pure ByteString.empty
                  else
                    ByteString.packCStringLen
                      (castPtr nativeBytes, fromIntegral lengthValue)
              if nativeBytes == nullPtr
                then pure ()
                else cFree nativeBytes
              pure (handle, identity, bytes)

openStatus :: FilePath -> IO Word32
openStatus path =
  withCWString path $ \widePath ->
    alloca $ \handlePointer ->
      allocaBytes 24 $ \identityPointer ->
        alloca $ \bytesPointer ->
          alloca $ \lengthPointer ->
            alloca $ \presentPointer ->
              cOpenExclusive
                widePath
                handlePointer
                identityPointer
                bytesPointer
                lengthPointer
                presentPointer

probeIdentity :: FilePath -> IO (Maybe ByteString)
probeIdentity path =
  withCWString path $ \widePath ->
    allocaBytes 24 $ \identityPointer ->
      alloca $ \presentPointer -> do
        status <- cProbeIdentity widePath identityPointer presentPointer
        status @?= 0
        CInt present <- peek presentPointer
        if present == 0
          then pure Nothing
          else
            Just
              <$> ByteString.packCStringLen
                (castPtr identityPointer, 24)

acquireNativeMutex :: IO (Ptr ())
acquireNativeMutex =
  alloca $ \mutexPointer ->
    alloca $ \abandonedPointer -> do
      status <- cMutexAcquire mutexPointer abandonedPointer
      status @?= 0
      peek mutexPointer

getNativeTarget :: IO FilePath
getNativeTarget =
  alloca $ \pathPointer -> do
    status <- cGetTargetPath pathPointer
    status @?= 0
    path <- peek pathPointer
    assertBool "native target path is non-null" (path /= nullPtr)
    bracket (pure path) cFree peekCWString
#endif
