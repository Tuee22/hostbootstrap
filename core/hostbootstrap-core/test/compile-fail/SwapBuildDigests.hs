module SwapBuildDigests (swapDigests) where
import HostBootstrap.Build
    ( BuildChannel, BuildError, BuildVerificationKey, BuildProjectName, BuildSpecDigest, BuildConfigDigest, CoordinatorDigest, BuildSourceRoot, BuilderPath
    , verifyBuildInvocation )
swapDigests ::
    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> BuildConfigDigest ->
    CoordinatorDigest -> BuildSourceRoot -> BuilderPath -> BuildChannel -> IO (Either BuildError ())
swapDigests key project spec config coordinator sourceRoot builder channel =
    verifyBuildInvocation key project config spec coordinator sourceRoot builder channel (\_ _ -> pure ())
