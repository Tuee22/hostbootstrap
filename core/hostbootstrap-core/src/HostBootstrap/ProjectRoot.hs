{-# LANGUAGE RankNTypes #-}

-- | Canonical project-root admission and scope-bound path projections.
module HostBootstrap.ProjectRoot
    ( CanonicalProjectRoot
    , CanonicalHostPath
    , ProjectRootError (..)
    , withCanonicalProjectRoot
    , canonicalProjectRootPath
    , canonicalDurableHostPath
    , canonicalHostPathValue
    )
where

import Control.Exception (IOException, try)
import Data.List (isPrefixOf)
import System.Directory (canonicalizePath, doesDirectoryExist, doesPathExist)
import System.FilePath (addTrailingPathSeparator, equalFilePath, isAbsolute, normalise, takeDirectory, takeFileName, (</>))

-- | A root whose constructor and scope/root identities are private to this
-- module. Both phantoms are minted by 'withCanonicalProjectRoot'.
newtype CanonicalProjectRoot scope rootId = CanonicalProjectRoot FilePath

-- | An absolute host path derived from one canonical project-root identity.
-- The constructor is private; host adapters consume this type instead of a raw
-- 'FilePath'.
newtype CanonicalHostPath scope rootId = CanonicalHostPath FilePath

data ProjectRootError
    = ProjectRootMissing FilePath
    | ProjectRootNotDirectory FilePath
    | ProjectRootEscapesAnchor FilePath FilePath
    | ProjectRootResolutionFailed FilePath String
    deriving (Eq, Show)

-- | Resolve a configured root against the stable project-home anchor owned by
-- the sibling config. Configs next to a @.build@ executable are owned by the
-- parent project directory; other config locations own their containing
-- directory directly.
withCanonicalProjectRoot ::
    FilePath ->
    FilePath ->
    (forall scope rootId. CanonicalProjectRoot scope rootId -> IO a) ->
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
            anchorResolved <- try (canonicalizePath (normalise anchor)) :: IO (Either IOException FilePath)
            let escaped = case anchorResolved of
                    Right stableAnchor ->
                        not (isAbsolute configuredRoot)
                            && not
                                ( equalFilePath stableAnchor root
                                    || addTrailingPathSeparator stableAnchor `isPrefixOf` addTrailingPathSeparator root
                                )
                    Left _ -> False
            present <- doesPathExist root
            exists <- doesDirectoryExist root
            case anchorResolved of
                Left err -> pure (Left (ProjectRootResolutionFailed anchor (show err)))
                Right stableAnchor
                    | escaped -> pure (Left (ProjectRootEscapesAnchor root stableAnchor))
                    | not present -> pure (Left (ProjectRootMissing root))
                    | not exists -> pure (Left (ProjectRootNotDirectory root))
                    | otherwise -> Right <$> action (CanonicalProjectRoot root)

canonicalProjectRootPath :: CanonicalProjectRoot scope rootId -> FilePath
canonicalProjectRootPath (CanonicalProjectRoot root) = root

-- | The canonical host-side Production durable root.
canonicalDurableHostPath :: CanonicalProjectRoot scope rootId -> CanonicalHostPath scope rootId
canonicalDurableHostPath root = CanonicalHostPath (canonicalProjectRootPath root </> ".data")

-- | Render a canonical host path for the small set of trusted adapters that
-- consume it. Construction remains private.
canonicalHostPathValue :: CanonicalHostPath scope rootId -> FilePath
canonicalHostPathValue (CanonicalHostPath path) = path
