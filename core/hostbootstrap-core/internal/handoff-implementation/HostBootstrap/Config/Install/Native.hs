{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}

{- | The platform's atomic no-replace publication primitive.

Publishing a sibling @\<project\>.dhall@ must be create-if-absent: a present
destination is a distinct outcome the caller classifies (identical bytes are an
idempotent replay, different bytes are a conflict), never something the writer
silently overwrites (§ Y's @RefuseExisting@/@KeepExisting@ policies).

A __hard__ link is that primitive on both supported platforms. It publishes the
fully written temporary under its final name in one kernel operation and fails
when the name is taken, so there is no window in which a reader can observe a
partial file and no path by which a concurrent writer's bytes are lost:

* POSIX — @link(2)@, which fails with @EEXIST@ rather than replacing;
* Windows — @CreateHardLinkW@, which likewise fails when the new name exists.

A __symbolic__ link is not a substitute. It publishes a /reference/ to the
temporary rather than the bytes: the destination then reads as a link, which the
sibling-config inspector refuses outright, and unlinking the temporary leaves a
dangling name behind. @rename(2)@ is not a substitute either — it replaces the
destination, which is the outcome this primitive exists to prevent.
-}
module HostBootstrap.Config.Install.Native (
    linkNoReplace,
) where

#if defined(mingw32_HOST_OS)
import Control.Monad (unless)
import Foreign.Ptr (Ptr, nullPtr)
import System.Win32.Types (LPCTSTR, getLastError, withFilePath)
#else
import System.Posix.Files (createLink)
#endif

{- | Publish @existing@ under the new name @destination@ without replacing it.

Throws an 'IOError' when the destination is taken (or the link cannot be made);
callers classify that by re-inspecting the destination rather than by
interpreting the error.
-}
linkNoReplace ::
    -- | the existing file, already written and flushed
    FilePath ->
    -- | the new name to publish it under; must not already exist
    FilePath ->
    IO ()

#if defined(mingw32_HOST_OS)
linkNoReplace existing destination =
    withFilePath destination $ \wideDestination ->
        withFilePath existing $ \wideExisting -> do
            linked <- rawCreateHardLinkW wideDestination wideExisting nullPtr
            unless linked $ do
                -- Read the code before anything else can clobber it, and raise
                -- an ordinary 'IOError' so the caller's existing synchronous
                -- handler classifies this exactly as it does the POSIX EEXIST.
                code <- getLastError
                ioError
                    ( userError
                        ( "CreateHardLinkW "
                            ++ destination
                            ++ " -> "
                            ++ existing
                            ++ " failed with error "
                            ++ show code
                        )
                    )

{- @CreateHardLinkW(lpFileName, lpExistingFileName, lpSecurityAttributes)@: the
NEW name comes first and the existing file second — the same order
"HostBootstrap.Wsl2.GlobalWall.Windows" uses for its own hard link. It returns
false (with @ERROR_ALREADY_EXISTS@) when the new name is taken, which is the
no-replace behaviour this primitive is chosen for. -}
foreign import capi unsafe "windows.h CreateHardLinkW"
    rawCreateHardLinkW :: LPCTSTR -> LPCTSTR -> Ptr () -> IO Bool
#else
linkNoReplace = createLink
#endif
