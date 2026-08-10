{-# LANGUAGE RankNTypes #-}

-- | Canonical project-root admission and scope-bound path projections.
module HostBootstrap.ProjectRoot
    ( CanonicalProjectRoot
    , CanonicalHostPath
    , ProjectRootError (..)
    , withCanonicalProjectRoot
    , canonicalProjectRootPath
    , canonicalDurableHostPath
    , canonicalHostSubPath
    , canonicalHostPathValue
    )
where

import Control.Exception (IOException, try)
import Data.List (isPrefixOf)
import System.Directory (canonicalizePath, doesDirectoryExist, doesPathExist)
import System.FilePath (addTrailingPathSeparator, equalFilePath, isAbsolute, normalise, takeDirectory, takeFileName, (</>))

-- | A root whose constructor and root identity are private to this module.
-- The surrounding admission chooses @scope@; 'withCanonicalProjectRoot' mints
-- only @rootId@.  This lets the config/lifecycle bracket retain its exact scope
-- while still preventing a root identity from escaping its continuation.
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
    | -- | a requested subpath segment could leave the admitted root
      ProjectRootSegmentUnsafe String
    deriving (Eq, Show)

-- | Resolve a configured root against the stable project-home anchor owned by
-- the sibling config. Configs next to a @.build@ executable are owned by the
-- parent project directory; other config locations own their containing
-- directory directly.
withCanonicalProjectRoot ::
    FilePath ->
    FilePath ->
    (forall rootId. CanonicalProjectRoot scope rootId -> IO a) ->
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
canonicalDurableHostPath root = canonicalHostSubPathUnchecked root [".data"]

{- | A host path under the admitted root, named by relative segments.

A run-scoped durable root is not a fixed name — a harness run's is its own
generation — so the segments are supplied rather than baked in. Each is checked
to be a single ordinary component: non-empty, free of path separators and drive
letters, and neither @.@ nor @..@. That is what keeps the returned
'CanonicalHostPath' genuinely under the root it was derived from, which is the
whole point of the type: a segment that could climb out would hand a trusted host
adapter a path the root never admitted.
-}
canonicalHostSubPath ::
    CanonicalProjectRoot scope rootId ->
    [String] ->
    Either ProjectRootError (CanonicalHostPath scope rootId)
canonicalHostSubPath root segments
    | null segments = Left (ProjectRootSegmentUnsafe "<no segments>")
    | otherwise = case filter (not . safeSegment) segments of
        (unsafe : _) -> Left (ProjectRootSegmentUnsafe unsafe)
        [] -> Right (canonicalHostSubPathUnchecked root segments)

safeSegment :: String -> Bool
safeSegment segment =
    not (null segment)
        && segment /= "."
        && segment /= ".."
        && not (any separator segment)
  where
    separator character = character `elem` ("/\\:" :: String)

canonicalHostSubPathUnchecked ::
    CanonicalProjectRoot scope rootId ->
    [String] ->
    CanonicalHostPath scope rootId
canonicalHostSubPathUnchecked root segments =
    CanonicalHostPath (foldl (</>) (canonicalProjectRootPath root) segments)

-- | Render a canonical host path for the small set of trusted adapters that
-- consume it. Construction remains private.
canonicalHostPathValue :: CanonicalHostPath scope rootId -> FilePath
canonicalHostPathValue (CanonicalHostPath path) = path
