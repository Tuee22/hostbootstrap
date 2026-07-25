{-# LANGUAGE RankNTypes #-}

-- | Canonical project-root admission and scope-bound path projections.
module HostBootstrap.ProjectRoot
    ( CanonicalProjectRoot
    , ProjectRootError (..)
    , withCanonicalProjectRoot
    , canonicalProjectRootPath
    , durableRootPath
    )
where

import Control.Exception (IOException, try)
import System.Directory (canonicalizePath, doesDirectoryExist)
import System.FilePath (isAbsolute, normalise, takeDirectory, takeFileName, (</>))

-- | A root whose constructor and phantom identity are private to this module.
newtype CanonicalProjectRoot rootId = CanonicalProjectRoot FilePath

data ProjectRootError
    = ProjectRootMissing FilePath
    | ProjectRootResolutionFailed FilePath String
    deriving (Eq, Show)

-- | Resolve a configured root against the stable project-home anchor owned by
-- the sibling config. Configs next to a @.build@ executable are owned by the
-- parent project directory; other config locations own their containing
-- directory directly.
withCanonicalProjectRoot ::
    FilePath ->
    FilePath ->
    (forall rootId. CanonicalProjectRoot rootId -> IO a) ->
    IO (Either ProjectRootError a)
withCanonicalProjectRoot configPath configuredRoot action = do
    let configDir = takeDirectory configPath
        anchor
            | takeFileName configDir == ".build" = takeDirectory configDir
            | otherwise = configDir
        candidate
            | isAbsolute configuredRoot = configuredRoot
            | otherwise = anchor </> configuredRoot
    resolved <- try (canonicalizePath (normalise candidate)) :: IO (Either IOException FilePath)
    case resolved of
        Left err -> pure (Left (ProjectRootResolutionFailed candidate (show err)))
        Right root -> do
            exists <- doesDirectoryExist root
            if exists
                then Right <$> action (CanonicalProjectRoot root)
                else pure (Left (ProjectRootMissing root))

canonicalProjectRootPath :: CanonicalProjectRoot rootId -> FilePath
canonicalProjectRootPath (CanonicalProjectRoot root) = root

durableRootPath :: CanonicalProjectRoot rootId -> FilePath
durableRootPath root = canonicalProjectRootPath root </> ".data"
