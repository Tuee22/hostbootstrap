module EscapeVerifiedRuntimeRoleActivationFrame where

import HostBootstrap.Activation
import HostBootstrap.Protected (ProtectedStore)

data CallerActivationScope
data CallerActivationPlan
data CallerActivationSpec
data CallerActivationBinary
data CallerActivationFrame
data CallerActivationRevision
data CallerActivationInstance

selectScope ::
    VerifiedRuntimeRoleActivation
        CallerActivationScope plan spec binary frame revision instanceId ->
    IO ()
selectScope _ = pure ()

selectPlan ::
    VerifiedRuntimeRoleActivation
        scope CallerActivationPlan spec binary frame revision instanceId ->
    IO ()
selectPlan _ = pure ()

selectSpec ::
    VerifiedRuntimeRoleActivation
        scope plan CallerActivationSpec binary frame revision instanceId ->
    IO ()
selectSpec _ = pure ()

selectBinary ::
    VerifiedRuntimeRoleActivation
        scope plan spec CallerActivationBinary frame revision instanceId ->
    IO ()
selectBinary _ = pure ()

selectFrame ::
    VerifiedRuntimeRoleActivation
        scope plan spec binary CallerActivationFrame revision instanceId ->
    IO ()
selectFrame _ = pure ()

selectRevision ::
    VerifiedRuntimeRoleActivation
        scope plan spec binary frame CallerActivationRevision instanceId ->
    IO ()
selectRevision _ = pure ()

selectInstance ::
    VerifiedRuntimeRoleActivation
        scope plan spec binary frame revision CallerActivationInstance ->
    IO ()
selectInstance _ = pure ()

escapeScope ::
    ActivationVerificationKey ->
    ProtectedStore ->
    ActivationManifest ->
    ActivationManifest ->
    ActivationGrant ->
    RuntimeMeasurement ->
    IO (Either ActivationError ())
escapeScope key store expected manifest grant measurement =
    verifyRuntimeRoleActivation key store expected manifest grant measurement selectScope

escapePlan key store expected manifest grant measurement =
    verifyRuntimeRoleActivation key store expected manifest grant measurement selectPlan

escapeSpec key store expected manifest grant measurement =
    verifyRuntimeRoleActivation key store expected manifest grant measurement selectSpec

escapeBinary key store expected manifest grant measurement =
    verifyRuntimeRoleActivation key store expected manifest grant measurement selectBinary

escapeFrame key store expected manifest grant measurement =
    verifyRuntimeRoleActivation key store expected manifest grant measurement selectFrame

escapeRevision key store expected manifest grant measurement =
    verifyRuntimeRoleActivation key store expected manifest grant measurement selectRevision

escapeInstance key store expected manifest grant measurement =
    verifyRuntimeRoleActivation key store expected manifest grant measurement selectInstance
