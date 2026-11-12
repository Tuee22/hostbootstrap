module SwapBuildPaths (swapPaths) where
import HostBootstrap.Build
    ( BuildVerificationKey, BuildProjectName, BuildSpecDigest, BuildConfigDigest, CoordinatorDigest, BuildSourceRoot, BuilderPath, BuildChannel, BuildError, verifyBuildInvocation )
swapPaths ::
    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> BuildConfigDigest -> CoordinatorDigest ->
    BuildSourceRoot -> BuilderPath -> BuildChannel -> IO (Either BuildError ())
swapPaths key project spec config coordinator sourceRoot builder channel =
    verifyBuildInvocation key project spec config coordinator builder sourceRoot channel (\_ _ -> pure ())
