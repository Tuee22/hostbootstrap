{-# LANGUAGE CPP #-}

{- | The production WSL lane: the current user's @%UserProfile%\\.wslconfig@.

This is the only substrate on which that file exists, so this module is what
decides /where/ the one global wall is — and nothing else. The complete
recovery driver, the durable record codec, and the ownership arithmetic live in
the portable module ('HostBootstrap.Wsl2.GlobalWall.Host'), and the four
clauses beneath them are the ownership row this binary was built for
('HostBootstrap.Ownership.Row'), so there is no platform backend here to keep
in step with anything.

The wall's own state — its exclusive entry and its durable records — lives in a
protected store beside the target, under @%UserProfile%\\.hostbootstrap@. That
directory is ordinary scaffolding; what is owned is @.wslconfig@ itself.

On a host that is not Windows the wall does not exist, so both entry points
answer a total refusal rather than being absent from the package (§ JJ).
-}
module HostBootstrap.Wsl2.GlobalWall.Windows
  ( windowsGlobalWallSupported,
    applyCurrentUserGlobalWall,
    restoreCurrentUserGlobalWall,
  )
where

import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Wsl2.GlobalWall.Host
import System.Environment (lookupEnv)
import System.FilePath ((</>))

-- | Whether this host is the one the per-user WSL wall exists on.
windowsGlobalWallSupported :: Bool
#if defined(mingw32_HOST_OS)
windowsGlobalWallSupported = True
#else
windowsGlobalWallSupported = False
#endif

applyCurrentUserGlobalWall ::
  CurrentUserWallRequest ->
  IO (Either HostWallError AppliedWslConfigFile)
applyCurrentUserGlobalWall request =
  withCurrentUserWall $ \location ->
    applyGlobalWall ownershipRowForHost location request

restoreCurrentUserGlobalWall ::
  CurrentUserWallRequest ->
  IO (Either HostWallError ())
restoreCurrentUserGlobalWall request =
  withCurrentUserWall $ \location ->
    restoreGlobalWall ownershipRowForHost location request

{- | Locate the one wall this user has, or refuse.

No caller input reaches either path: the target is the literal @.wslconfig@
beside the profile the environment names, and the state directory is its fixed
sibling.
-}
withCurrentUserWall ::
  (HostWallLocation -> IO (Either HostWallError result)) ->
  IO (Either HostWallError result)
withCurrentUserWall use
  | not windowsGlobalWallSupported =
      pure (Left (HostWallUnsupported "the WSL global wall requires Windows"))
  | otherwise = do
      profile <- lookupEnv "USERPROFILE"
      case profile of
        Nothing ->
          pure
            ( Left
                ( HostWallUnsupported
                    "USERPROFILE is not set, so this user has no .wslconfig target"
                )
            )
        Just home -> do
          opened <-
            openHostWallLocation
              (home </> ".wslconfig")
              (home </> ".hostbootstrap" </> "global-wall")
          case opened of
            Left err -> pure (Left err)
            Right location -> use location
