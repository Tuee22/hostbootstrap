module SwapActivationManifests (swapManifests) where
import HostBootstrap.Activation
    ( ActivationError, ActivationGrant, ActivationVerificationKey, RuntimeMeasurement
    , SelectedActivationManifest, ReceivedActivationManifest, verifyRuntimeRoleActivation )
import HostBootstrap.Protected (ProtectedStore)
swapManifests ::
    ActivationVerificationKey -> ProtectedStore -> SelectedActivationManifest -> ReceivedActivationManifest ->
    ActivationGrant -> RuntimeMeasurement -> IO (Either ActivationError ())
swapManifests key store selected received grant measurement =
    verifyRuntimeRoleActivation key store received selected grant measurement (\_ -> pure ())
