{- | Representative reconcile authority and typestate values cannot be
relabeled across their nominal generative or phase axes.
-}
module CoerceReconcileEvidenceRoles where

import Data.Coerce (coerce)
import HostBootstrap.Reconcile
    ( LifecyclePlan
    , OperationDescriptor
    , OwnershipReceipt
    , PhaseTransition
    , ReconcileResult
    )

data LifecycleScopeA
data LifecycleScopeB
data LifecyclePlanA
data LifecyclePlanB
data ReceiptScope
data ReceiptPlan
data ReceiptIdentityA
data ReceiptIdentityB
data ReceiptResourceA
data ReceiptResourceB
data DescriptorScope
data DescriptorPlan
data DescriptorIdentity
data DescriptorResource
data DescriptorFromA
data DescriptorFromB
data DescriptorToA
data DescriptorToB
data TransitionScope
data TransitionPlan
data TransitionIdentity
data TransitionResource
data TransitionFromA
data TransitionFromB
data TransitionToA
data TransitionToB
data ResultScope
data ResultPlan
data ResultIdentity
data ResultResource
data ResultPhaseA
data ResultPhaseB

coerceLifecycleScope ::
    LifecyclePlan LifecycleScopeA LifecyclePlanA ->
    LifecyclePlan LifecycleScopeB LifecyclePlanA
coerceLifecycleScope = coerce

coerceLifecyclePlan ::
    LifecyclePlan LifecycleScopeA LifecyclePlanA ->
    LifecyclePlan LifecycleScopeA LifecyclePlanB
coerceLifecyclePlan = coerce

coerceReceiptIdentity ::
    OwnershipReceipt ReceiptScope ReceiptPlan ReceiptIdentityA ReceiptResourceA ->
    OwnershipReceipt ReceiptScope ReceiptPlan ReceiptIdentityB ReceiptResourceA
coerceReceiptIdentity = coerce

coerceReceiptResource ::
    OwnershipReceipt ReceiptScope ReceiptPlan ReceiptIdentityA ReceiptResourceA ->
    OwnershipReceipt ReceiptScope ReceiptPlan ReceiptIdentityA ReceiptResourceB
coerceReceiptResource = coerce

coerceDescriptorFrom ::
    OperationDescriptor
        DescriptorScope
        DescriptorPlan
        DescriptorIdentity
        DescriptorResource
        DescriptorFromA
        DescriptorToA ->
    OperationDescriptor
        DescriptorScope
        DescriptorPlan
        DescriptorIdentity
        DescriptorResource
        DescriptorFromB
        DescriptorToA
coerceDescriptorFrom = coerce

coerceDescriptorTo ::
    OperationDescriptor
        DescriptorScope
        DescriptorPlan
        DescriptorIdentity
        DescriptorResource
        DescriptorFromA
        DescriptorToA ->
    OperationDescriptor
        DescriptorScope
        DescriptorPlan
        DescriptorIdentity
        DescriptorResource
        DescriptorFromA
        DescriptorToB
coerceDescriptorTo = coerce

coerceTransitionFrom ::
    PhaseTransition
        TransitionScope
        TransitionPlan
        TransitionIdentity
        TransitionResource
        TransitionFromA
        TransitionToA ->
    PhaseTransition
        TransitionScope
        TransitionPlan
        TransitionIdentity
        TransitionResource
        TransitionFromB
        TransitionToA
coerceTransitionFrom = coerce

coerceTransitionTo ::
    PhaseTransition
        TransitionScope
        TransitionPlan
        TransitionIdentity
        TransitionResource
        TransitionFromA
        TransitionToA ->
    PhaseTransition
        TransitionScope
        TransitionPlan
        TransitionIdentity
        TransitionResource
        TransitionFromA
        TransitionToB
coerceTransitionTo = coerce

coerceResultPhase ::
    ReconcileResult ResultScope ResultPlan ResultIdentity ResultResource ResultPhaseA ->
    ReconcileResult ResultScope ResultPlan ResultIdentity ResultResource ResultPhaseB
coerceResultPhase = coerce
