{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}

-- | Docker Hub registry credentials as an /effect-only/, non-serialisable
-- capability — never represented in Dhall, never persisted, never logged.
--
-- The composition model (see @development_plan_standards.md § U@) says every
-- project binary at every level has global knowledge of where it sits in the
-- lift chain. Pulling an image from Docker Hub from inside a nested context (a
-- VM @docker build@, a container's @kind@/@docker run@) hits Docker Hub's
-- unauthenticated rate limit. The fix is to /forward/ the host's Docker Hub
-- login down the lift so the nested pull authenticates — but credentials are a
-- security boundary, so this module models them so that leaking them is
-- /unrepresentable/:
--
--   * 'RegistryAuth' is opaque (its constructor is not exported), its 'Show' is
--     redacted, and it has no @FromDhall@/@ToDhall@ instance — it cannot appear
--     in a @\<project\>.dhall@, a log line, or a config artifact.
--   * It is discovered at run time from the host's own Docker config
--     ('discoverHostRegistryAuth'); it is never written into 'HostConfig', the
--     binary context, or any generated file.
--   * It is forwarded only over ephemeral channels: piped on @stdin@ into a
--     transient @DOCKER_CONFIG@ that is removed when the command exits
--     ('dockerAuthStdinWrapper'), or carried into a container through an
--     environment variable ('registryAuthEnvVar') that the in-container binary
--     consumes once into a transient @DOCKER_CONFIG@ ('withForwardedRegistryAuth')
--     and never persists.
--
-- The payload is the minimal @config.json@ holding /only/ the Docker Hub auth
-- entries (never the host's other registry credentials). When the host is not
-- logged in, discovery yields 'Nothing' and every caller degrades to the
-- previous anonymous-pull behaviour — the pristine-host story is unchanged.
module HostBootstrap.Registry
  ( -- * The opaque credential
    RegistryAuth,
    registryConfigPayload,

    -- * Discovery (host-only)
    discoverHostRegistryAuth,
    dockerHubAuthFromConfig,

    -- * Ephemeral forwarding
    registryAuthEnvVar,
    dockerAuthStdinWrapper,
    withForwardedRegistryAuth,
  )
where

import Control.Exception (SomeException)
import Control.Exception.Safe (bracket, try)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory
  ( doesFileExist,
    getHomeDirectory,
    removePathForcibly,
  )
#ifndef mingw32_HOST_OS
import System.Directory (getTemporaryDirectory)
#endif
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
#ifndef mingw32_HOST_OS
import System.Posix.Temp (mkdtemp)
#endif

-- | An opaque Docker Hub credential: a minimal @config.json@ carrying only the
-- Docker Hub auth entries. The constructor is intentionally /not/ exported, there
-- is no @FromDhall@/@ToDhall@ instance, and 'Show' is redacted, so the secret
-- cannot leak into Dhall, logs, or generated artifacts.
newtype RegistryAuth = RegistryAuth Text

-- | Redacted: a 'RegistryAuth' never prints its payload (so it is safe in any
-- @show@-based log or error path).
instance Show RegistryAuth where
  show _ = "RegistryAuth <redacted>"

-- | The minimal @config.json@ payload (Docker Hub auths only) this credential
-- forwards. The only accessor; used by the ephemeral-forwarding seams below.
registryConfigPayload :: RegistryAuth -> Text
registryConfigPayload (RegistryAuth payload) = payload

-- | The environment variable a parent uses to forward the credential into a
-- container. It carries the minimal @config.json@ for the duration of the
-- container only; 'withForwardedRegistryAuth' consumes it into a transient
-- @DOCKER_CONFIG@ and it is never persisted.
registryAuthEnvVar :: String
registryAuthEnvVar = "HOSTBOOTSTRAP_REGISTRY_AUTH"

-- | Docker Hub registry keys in a @config.json@ @auths@ map. Matching on
-- @docker.io@ keeps the host's /other/ registry credentials (private registries,
-- a local Harbor) out of the forwarded payload.
isDockerHubKey :: K.Key -> Bool
isDockerHubKey k = "docker.io" `isInfixOf` K.toString k

-- | Parse a Docker @config.json@ and project out a minimal config holding only
-- the Docker Hub auth entries. Pure, so the projection is unit-tested. Yields
-- 'Nothing' when the bytes do not parse, carry no @auths@, or carry no Docker Hub
-- entry (e.g. the host is logged in only to other registries, or uses a
-- credential store with no inline token).
dockerHubAuthFromConfig :: BL.ByteString -> Maybe RegistryAuth
dockerHubAuthFromConfig raw = do
  value <- A.decode raw
  object <- asObject value
  auths <- KM.lookup "auths" object >>= asObject
  let hub = KM.filterWithKey (\k _ -> isDockerHubKey k) auths
  if KM.null hub
    then Nothing
    else
      Just . RegistryAuth . TE.decodeUtf8 . BL.toStrict $
        A.encode (A.Object (KM.singleton "auths" (A.Object hub)))
  where
    asObject (A.Object o) = Just o
    asObject _ = Nothing

-- | Discover the host's Docker Hub credential, if the host is logged in. Reads
-- @$DOCKER_CONFIG/config.json@ (or @~\/.docker\/config.json@) — the host is where
-- the credential legitimately lives. Any failure (no file, no Docker Hub entry,
-- unreadable) yields 'Nothing', and callers fall back to anonymous pulls. This is
-- the only place the credential is read, and only ever on the host.
discoverHostRegistryAuth :: IO (Maybe RegistryAuth)
discoverHostRegistryAuth = do
  path <- dockerConfigPath
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      readResult <- try (BL.readFile path) :: IO (Either SomeException BL.ByteString)
      pure $ case readResult of
        Left _ -> Nothing
        Right bytes -> dockerHubAuthFromConfig bytes

-- | The host Docker config path: @$DOCKER_CONFIG/config.json@ when set, else
-- @~\/.docker\/config.json@.
dockerConfigPath :: IO FilePath
dockerConfigPath = do
  override <- lookupEnv "DOCKER_CONFIG"
  case override of
    Just dir | not (null dir) -> pure (dir </> "config.json")
    _ -> do
      home <- getHomeDirectory
      pure (home </> ".docker" </> "config.json")

-- | Wrap a POSIX-@sh@ command so it pulls with a forwarded credential read from
-- @stdin@: materialise a throwaway @DOCKER_CONFIG@ from the piped payload, run the
-- inner command with it, and remove it on exit (even on failure, via @trap@).
-- Pure — the secret is /not/ in the returned string; the caller pipes it on
-- @stdin@. With an empty @stdin@ (no host login) the config is empty and Docker
-- pulls anonymously, so this wrapper is safe to apply unconditionally.
--
-- This is the VM-boundary forwarding seam: a raw in-VM @docker build@/@docker
-- pull@ is wrapped here and the host pipes 'registryConfigPayload' to it.
dockerAuthStdinWrapper :: String -> String
dockerAuthStdinWrapper inner =
  "__hbcfg=$(mktemp -d); trap 'rm -rf \"$__hbcfg\"' EXIT; "
    ++ "cat > \"$__hbcfg/config.json\"; export DOCKER_CONFIG=\"$__hbcfg\"; "
    ++ inner

-- | Run an action with the forwarded Docker Hub credential active for any Docker
-- pulls the action triggers. Reads 'registryAuthEnvVar' (set by a parent that
-- forwarded the credential into this container); when present it writes the
-- minimal @config.json@ into a transient @mkdtemp@ directory, points
-- @DOCKER_CONFIG@ at it for the duration, and removes it afterwards (via
-- 'bracket', so the credential never outlives the action). When the variable is
-- absent (the normal host case, or no host login) it is a no-op and pulls remain
-- anonymous.
--
-- This is the in-container side of forwarding: the in-container binary calls this
-- once at startup so its nested @kind@/@docker@ pulls authenticate without the
-- credential ever being written to a persisted file.
withForwardedRegistryAuth :: IO a -> IO a
withForwardedRegistryAuth action = do
  forwarded <- lookupEnv registryAuthEnvVar
  case forwarded of
    Just payload | not (null payload) -> withEphemeralDockerConfig (T.pack payload) action
    _ -> action

-- | Materialise a throwaway @DOCKER_CONFIG@ directory from the payload, point the
-- process at it, run the action, then scrub the directory and restore the
-- environment — whatever happens.
withEphemeralDockerConfig :: Text -> IO a -> IO a
withEphemeralDockerConfig payload action =
  bracket acquire release (const action)
  where
    acquire = do
#ifdef mingw32_HOST_OS
      dir <- fail "withForwardedRegistryAuth requires POSIX temporary-directory permissions; Windows registry forwarding is not supported yet"
#else
      base <- getTemporaryDirectory
      dir <- mkdtemp (base </> "hb-registry-")
#endif
      writeFile (dir </> "config.json") (T.unpack payload)
      previous <- lookupEnv "DOCKER_CONFIG"
      setEnv "DOCKER_CONFIG" dir
      -- Drop the forwarded secret from the environment so it is not re-exported
      -- to grandchildren or visible for longer than the pull needs it.
      unsetEnv registryAuthEnvVar
      pure (dir, previous)
    release (dir, previous) = do
      maybe (unsetEnv "DOCKER_CONFIG") (setEnv "DOCKER_CONFIG") previous
      removePathForcibly dir
