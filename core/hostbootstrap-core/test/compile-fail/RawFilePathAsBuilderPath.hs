module RawFilePathAsBuilderPath (verify) where
import HostBootstrap.Build (BuildChannel, BuildError, BuildVerificationKey, BuildProjectName, BuildSpecDigest, BuildConfigDigest, CoordinatorDigest, BuildSourceRoot, verifyBuildInvocation)
verify ::
    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> BuildConfigDigest -> CoordinatorDigest -> BuildSourceRoot -> FilePath ->
    BuildChannel -> IO (Either BuildError ())
verify key project spec config coordinator sourceRoot builder channel =
    verifyBuildInvocation key project spec config coordinator sourceRoot builder channel (\_ _ -> pure ())
