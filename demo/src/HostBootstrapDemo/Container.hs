{- | The project-container build (build #3): the @docker build@ argv a project
binary runs once it is up, producing the workload image @FROM@ the base (see
@development_plan_standards.md § M, § N@).

This logic used to live in @hostbootstrap-core@. The core is now generic over a
project's config type and never reads a project-specific field (such as the
Dockerfile path), so the build argv — which is inherently project-config-shaped —
lives in the demo, the consumer that owns build #3. The argv builder is pure (so
it is unit-tested); 'buildProjectContainer' is the thin IO seam that runs it
through the resolved Docker tool.
-}
module HostBootstrapDemo.Container (
    projectImageTag,
    dockerBuildArgs,
    buildProjectContainer,
    basePullArgs,
    baseDigestArgs,
    pinnedBaseReference,
    resolvePublishedBase,
)
where

import Data.Char (isSpace)
import Data.List (isPrefixOf)
import qualified Data.Text as T
import qualified HostBootstrap.Context as Context
import HostBootstrap.Ensure (runTool)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Docker))
import HostBootstrapDemo.Config (ProjectConfig (..))
import System.Exit (ExitCode (ExitSuccess))

-- | The local image tag a project's container build produces: @\<project\>:local@.
projectImageTag :: ProjectConfig scope -> String
projectImageTag cfg = T.unpack (Context.project (context cfg)) ++ ":local"

{- | The @docker build@ argv: build the project's Dockerfile @FROM@ the given base
image, tagged @\<project\>:local@, from the build context @.@. Pure.

@--pull@ is load-bearing rather than decorative. § FF: "Local same-named images
do not substitute for that post-publish pull." Without it, a host that once built
the rolling tag locally would build @FROM@ that stale image and never notice —
which is precisely the drift between the repo and Docker Hub the base-image
policy exists to prevent. The flag is on the argv rather than in a wrapper
because both lanes go through here, including the one that renders this argv into
an in-VM shell script where a command substitution would be quoting-fragile.
-}
dockerBuildArgs :: ProjectConfig scope -> String -> [String]
dockerBuildArgs cfg baseImage =
    [ "build"
    , "--pull"
    , "-f"
    , T.unpack (dockerfile cfg)
    , "--build-arg"
    , "BASE_IMAGE=" ++ baseImage
    , "-t"
    , projectImageTag cfg
    , "."
    ]

-- | Run the project-container build through the resolved Docker tool.
buildProjectContainer ::
    HostConfig ->
    ProjectConfig scope ->
    -- | the base image to build @FROM@
    String ->
    IO (Either String (ExitCode, String, String))
buildProjectContainer hostCfg projectCfg baseImage =
    runTool hostCfg Docker (dockerBuildArgs projectCfg baseImage)

-- ---------------------------------------------------------------------------
-- Consuming the published base rather than a stale local one

-- | Pull the published rolling tag. Pure argv.
basePullArgs :: String -> [String]
basePullArgs tag = ["pull", tag]

-- | Ask for an image's repository digests. Pure argv.
baseDigestArgs :: String -> [String]
baseDigestArgs tag =
    ["image", "inspect", "--format", "{{range .RepoDigests}}{{println .}}{{end}}", tag]

{- | Turn a rolling tag and an observed repository digest into the reference a
derived build should actually use.

The repository part of the tag is kept and the tag part replaced by the digest,
so @…\/hostbootstrap:basecontainer-cpu-arm64@ plus @sha256:abc…@ becomes
@…\/hostbootstrap\@sha256:abc…@.

A digest that does not name @sha256:@ is refused rather than concatenated: a
malformed digest that still produced a syntactically valid reference would build
@FROM@ something nobody chose.
-}
pinnedBaseReference :: String -> String -> Either String String
pinnedBaseReference tag digest
    | not ("sha256:" `isPrefixOf` trimmed) =
        Left ("the published base digest is not a sha256 reference: " ++ show digest)
    | otherwise = Right (repositoryOf tag ++ "@" ++ trimmed)
  where
    trimmed = trim digest

{- | The repository part of a reference — everything before the tag separator.

The last @:@ is only a tag separator when it comes after the last @\/@, because a
registry host may carry a port (@localhost:5000\/x@). A reference with no tag is
already just a repository.
-}
repositoryOf :: String -> String
repositoryOf reference = case break (== '/') (reverse reference) of
    (lastSegment, rest) -> case break (== ':') lastSegment of
        (_, []) -> reference
        (_, _ : nameRev) -> reverse (nameRev ++ rest)

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

{- | Resolve the published base to a digest reference, by __pulling it first__.

This is what keeps a derived build off a stale local image. A local image sharing
the rolling tag is not the published base, and § FF says so directly: "Local
same-named images do not substitute for that post-publish pull." So the pull
happens unconditionally, and the digest is read back from the pulled result.

An image with no repository digest is refused. That is exactly the stale-local
case — an image built locally and never pulled or pushed has no repo digest at
all — so the refusal names it rather than silently proceeding on the tag.

The digest is a __within-run handoff__, not a committed pin. § FF is explicit
that a digest "does not make locked inputs, digest-pinned consumers, or
reproducible rebuilds part of the architecture", so nothing here is written to
config or committed: the reference is resolved fresh on every build, and a
rebuild that discovers a newer compatible base simply resolves a newer digest.
-}
resolvePublishedBase ::
    HostConfig ->
    -- | the rolling published tag
    String ->
    IO (Either String String)
resolvePublishedBase hostCfg tag = do
    pulled <- runTool hostCfg Docker (basePullArgs tag)
    case pulled of
        Left failure -> pure (Left ("pulling the published base failed: " ++ failure))
        Right (code, _, err)
            | code /= ExitSuccess ->
                pure (Left ("pulling the published base " ++ tag ++ " failed: " ++ trim err))
            | otherwise -> do
                inspected <- runTool hostCfg Docker (baseDigestArgs tag)
                pure $ case inspected of
                    Left failure -> Left ("inspecting the published base failed: " ++ failure)
                    Right (inspectCode, out, inspectErr)
                        | inspectCode /= ExitSuccess ->
                            Left ("inspecting the published base failed: " ++ trim inspectErr)
                        | otherwise -> case filter (not . null) (map trim (lines out)) of
                            [] ->
                                Left
                                    ( "the base image "
                                        ++ tag
                                        ++ " has no repository digest, so it is a local image rather "
                                        ++ "than the published base; rebuild and push it, then retry"
                                    )
                            (first : _) -> pinnedBaseReference tag (digestOf first)

{- | The digest half of a @repo\@sha256:…@ repository digest.

@docker image inspect@ reports repository digests in that joined form, so the
part after the last @\@@ is the digest.
-}
digestOf :: String -> String
digestOf raw = case break (== '@') (reverse raw) of
    (digestRev, []) -> reverse digestRev
    (digestRev, _) -> reverse digestRev
