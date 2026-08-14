module CoerceTeardownFrameRoles where

import Data.Coerce (coerce)
import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan

data ForestFrameA
data ForestFrameB

coerceForest ::
    TeardownForest Scope Plan ForestFrameA VerbDestroy ->
    TeardownForest Scope Plan ForestFrameB VerbDestroy
coerceForest = coerce

data ProgressFrameA
data ProgressFrameB

coerceProgress ::
    TeardownProgress Scope Plan ProgressFrameA VerbDestroy ->
    TeardownProgress Scope Plan ProgressFrameB VerbDestroy
coerceProgress = coerce

data CompletedFrameA
data CompletedFrameB

coerceCompleted ::
    CompletedTeardownForest Scope Plan CompletedFrameA VerbDestroy ->
    CompletedTeardownForest Scope Plan CompletedFrameB VerbDestroy
coerceCompleted = coerce

data AuthorizationFrameA
data AuthorizationFrameB

coerceAuthorization ::
    TeardownAuthorizationPoint Scope Plan AuthorizationFrameA VerbDestroy ->
    TeardownAuthorizationPoint Scope Plan AuthorizationFrameB VerbDestroy
coerceAuthorization = coerce

data PreDescentFrameA
data PreDescentFrameB

coercePreDescent ::
    PreDescentStep Scope Plan PreDescentFrameA VerbDestroy ->
    PreDescentStep Scope Plan PreDescentFrameB VerbDestroy
coercePreDescent = coerce

data ChildrenFrameA
data ChildrenFrameB

coerceChildren ::
    SettledChildren Scope Plan ChildrenFrameA ->
    SettledChildren Scope Plan ChildrenFrameB
coerceChildren = coerce

data WorkFrameA
data WorkFrameB

coerceWork ::
    TeardownWork Scope Plan WorkFrameA VerbDestroy ->
    TeardownWork Scope Plan WorkFrameB VerbDestroy
coerceWork = coerce

data SettledFrameA
data SettledFrameB

coerceSettled ::
    SubtreeSettled Scope Plan SettledFrameA VerbDestroy ->
    SubtreeSettled Scope Plan SettledFrameB VerbDestroy
coerceSettled = coerce
