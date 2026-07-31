module ForgeRuntimeActivation where

import HostBootstrap.Activation

sampleManifest :: ActivationManifest
sampleManifest =
    ActivationManifest
        { manifestScope = "Production"
        , manifestPlanDigest = "plan-1"
        , manifestSpecDigest = "spec-1"
        , manifestBinaryDigest = "binary-1"
        , manifestFrame = "daemon-3"
        , manifestRevision = "rev-1"
        , manifestConfigDigest = "config-1"
        , manifestSecretDigest = "secret-1"
        , manifestService = "accelerator"
        , manifestRolePlanDigest = "roleplan-1"
        , manifestPermittedEffects = ["durable-write"]
        , manifestSecretChannel = "/var/run/secrets/hostbootstrap/bundle"
        }

-- The activation package exists only as the result of verifying a signed
-- manifest against locally measured identity. Asserting one would let a
-- restart run without proving its bytes or its instance.
forgedActivation :: VerifiedRuntimeRoleActivation s p sp b f r i
forgedActivation =
    VerifiedRuntimeRoleActivation sampleManifest (KubernetesInstance "pod-uid-1" 0)

-- The one-use admission is a durable reservation, not a value a caller names.
forgedAdmission :: LifecycleAdmission s p f r i
forgedAdmission = LifecycleAdmission "admission.plan-1.daemon-3.rev-1.pod-uid-1-0"

-- A grant is a signature the root broker produced.
forgedGrant :: ActivationGrant
forgedGrant = ActivationGrant "not a signature"

-- The signing broker cannot be constructed by a consumer.
forgedBroker :: ActivationBroker s g v
forgedBroker = ActivationBroker
