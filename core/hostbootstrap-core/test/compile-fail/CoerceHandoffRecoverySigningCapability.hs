module CoerceHandoffRecoverySigningCapability where

import Data.Coerce (coerce)
import HostBootstrap.Handoff
    ( adoptLifecycleAcknowledgementKernel
    , prepareLifecycleAcknowledgementKernel
    , publishLifecycleReportKernel
    , receiveLifecycleAcknowledgementKernel
    , registerRecoverableAdmittedHandoffEdgeKernel
    , signAuthenticatedRootScopeKernel
    , signRecoveryChildPackageBindingKernel
    , signRecoveryWireKernel
    , signRootedLifecycleResponseKernel
    , signRootedPayloadBindingKernel
    )

-- The hidden ordinary-data capability cannot be supplied by representational
-- coercion even when its type is inferred from the sealed public kernel.
signWithoutCapability = signRecoveryWireKernel (coerce ())

signRootedWithoutCapability = signRootedPayloadBindingKernel (coerce ())

signRecoveryPackageWithoutCapability = signRecoveryChildPackageBindingKernel (coerce ())

signRootedLifecycleResponseWithoutCapability = signRootedLifecycleResponseKernel (coerce ())

signAuthenticatedRootScopeWithoutCapability = signAuthenticatedRootScopeKernel (coerce ())

recoverWithoutCapability = registerRecoverableAdmittedHandoffEdgeKernel (coerce ())

publishWithoutCapability = publishLifecycleReportKernel (coerce ())

receiveWithoutCapability = receiveLifecycleAcknowledgementKernel (coerce ())

prepareWithoutCapability = prepareLifecycleAcknowledgementKernel (coerce ())

adoptWithoutCapability = adoptLifecycleAcknowledgementKernel (coerce ())
