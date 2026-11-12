module RawFilePathAsBuildSourceRoot (verify) where
import HostBootstrap.Build (BuildChannel, BuildError, BuildVerificationKey, BuildProjectName, BuildSpecDigest, BuildConfigDigest, CoordinatorDigest, BuilderPath, verifyBuildInvocation)
verify ::
    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> BuildConfigDigest -> CoordinatorDigest -> FilePath -> BuilderPath ->
    BuildChannel -> IO (Either BuildError ())
verify key project spec config coordinator sourceRoot builder channel =
    verifyBuildInvocation key project spec config coordinator sourceRoot builder channel (\_ _ -> pure ())
