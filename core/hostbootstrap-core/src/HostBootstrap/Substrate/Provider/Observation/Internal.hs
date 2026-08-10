{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Package-private provider observations and their prepared-call bindings.

Raw observations are deliberately plan-independent: they are the total output
of parsing one provider realization.  They never cross the public library
boundary.  A clause-holding backend wraps one raw observation in the call-result
whose nominal indices are copied from the exact prepared call it executed.
Settlement therefore cannot accept a result obtained for a different prepared
operation, even when both operations describe the same provider generation.
-}
module HostBootstrap.Substrate.Provider.Observation.Internal
  ( ProviderBackendBinding (..),
    ProviderOriginBinding (..),
    providerOriginOwner,
    ManagedProviderHandle (..),
    ManagedProviderShareHandle (..),
    ProviderProvisionObservation (..),
    ProviderProvisionCallResult (..),
    ProviderShareObservation (..),
    ProviderShareCallResult (..),
    ProviderReadyObservation (..),
    ProviderReadyCallResult (..),
    ProviderStopObservation (..),
    ProviderStopCallResult (..),
    ProviderDeleteObservation (..),
    ProviderDeleteCallResult (..),
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Reconcile
  ( ConflictDetail,
    DurableShareResource,
    FailureDetail,
    ForeignObservation,
    Managed,
    OwnershipReceipt,
    ProviderResource,
    ResourceHandle,
    UnsupportedDetail,
  )

{- | Generative identity plus the two descriptive bindings of one backend.

The semantic fingerprint names the stable provider target; the realization
fingerprint additionally binds the exact executable and lock implementation
used for this discovered backend.  They remain separate so durable ownership
does not become machine-path-dependent while each prepared call still seals
the complete realization.
-}
data ProviderBackendBinding backendId = ProviderBackendBinding
  { providerBackendSemanticFingerprint :: Text,
    providerBackendRealizationFingerprint :: Text
  }

type role ProviderBackendBinding nominal

{- | Stable ownership identity retained from the exact prepared provision.

The operation key and call digest deliberately do not live here: they change
for ready, share, stop, and delete calls.  The backend realization identity,
plan digest, resource key, and generation do not.  Keeping this package-private
binding inside every managed provider handle lets later operations derive their
call binding without asking public callers to pair independent authority
values.
-}
data ProviderOriginBinding scope planId backendId providerId = ProviderOriginBinding
  { providerOriginBackendBinding :: ProviderBackendBinding backendId,
    providerOriginPlanDigest :: Text,
    providerOriginResourceKey :: Text,
    providerOriginGeneration :: Word64
  }

type role ProviderOriginBinding nominal nominal nominal nominal

-- | Exact persisted owner binding shared by every operation on one provider.
providerOriginOwner :: ProviderOriginBinding scope planId backendId providerId -> Text
providerOriginOwner origin =
  Text.concat
    [ sized "hostbootstrap/provider-origin/v2",
      sized (providerOriginPlanDigest origin),
      sized (providerOriginResourceKey origin),
      sized (Text.pack (show (providerOriginGeneration origin))),
      sized
        ( providerBackendSemanticFingerprint
            (providerOriginBackendBinding origin)
        )
    ]
  where
    sized value = Text.pack (show (Text.length value)) <> ":" <> value

{- | Package-private representation of public managed provider authority.

The public module exports this type abstractly.  Its constructor stays here so
only the settlement adapter can mint it and the clause-holding backend can
recover the retained origin, generic managed handle, and exact receipt.  In
particular, generic reconciliation and phase verification cannot manufacture a
value accepted by provider operations.
-}
data ManagedProviderHandle scope planId backendId providerId phase =
  ManagedProviderHandle
    (ProviderOriginBinding scope planId backendId providerId)
    (ResourceHandle scope planId providerId ProviderResource Managed phase)
    (OwnershipReceipt scope planId providerId ProviderResource)

type role ManagedProviderHandle nominal nominal nominal nominal nominal

{- | Package-private representation of a provider-derived durable share.

The retained provider origin makes the share unusable with another backend or
provider generation even though the generic reconciliation layer has no such
indices.  The public adapter exports only the abstract type and descriptive
identity projections.
-}
data ManagedProviderShareHandle scope planId backendId providerId shareId phase =
  ManagedProviderShareHandle
    (ProviderOriginBinding scope planId backendId providerId)
    (ResourceHandle scope planId shareId DurableShareResource Managed phase)
    (OwnershipReceipt scope planId shareId DurableShareResource)

type role ManagedProviderShareHandle nominal nominal nominal nominal nominal nominal

data ProviderProvisionObservation
  = ProviderProvisionCreated Word64
  | ProviderProvisionRepaired Word64
  | ProviderProvisionAlreadyOwned Word64
  | ProviderProvisionForeign Word64 ForeignObservation
  | -- | Admission of a plan-local Direct reservation, not ownership of a host.
    ProviderProvisionDirectLocal Word64
  | ProviderProvisionAbsent
  | ProviderProvisionConflict ConflictDetail
  | ProviderProvisionUnsupported UnsupportedDetail
  | ProviderProvisionFailed FailureDetail
  deriving (Eq, Show)

data ProviderProvisionCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion
  = ProviderProvisionCallResult ProviderProvisionObservation

type role ProviderProvisionCallResult nominal nominal nominal nominal nominal nominal nominal nominal

data ProviderShareObservation
  = ProviderShareAttached Word64
  | ProviderShareRepaired Word64
  | ProviderShareAlreadyReady Word64
  | ProviderShareForeign Word64 ForeignObservation
  | ProviderShareDirectLocal Word64
  | ProviderShareAbsent
  | ProviderShareProviderReplaced Word64 ForeignObservation
  | ProviderShareConflict ConflictDetail
  | ProviderShareUnsupported UnsupportedDetail
  | ProviderShareFailed FailureDetail
  deriving (Eq, Show)

data ProviderShareCallResult scope planId backendId providerId shareId operationKey callDigest attempt journalVersion
  = ProviderShareCallResult ProviderShareObservation

type role ProviderShareCallResult nominal nominal nominal nominal nominal nominal nominal nominal nominal

data ProviderReadyObservation
  = ProviderReadyObserved Word64
  | ProviderReadyAlready Word64
  | ProviderReadyNotReady Text
  | ProviderReadyAbsent
  | ProviderReadyReplaced Word64 ForeignObservation
  | ProviderReadyConflict ConflictDetail
  | ProviderReadyUnsupported UnsupportedDetail
  | ProviderReadyFailed FailureDetail
  deriving (Eq, Show)

data ProviderReadyCallResult scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion
  = ProviderReadyCallResult ProviderReadyObservation

type role ProviderReadyCallResult nominal nominal nominal nominal nominal nominal nominal nominal nominal

data ProviderStopObservation
  = ProviderStopped Word64
  | ProviderAlreadyStopped Word64
  | ProviderStopStillRunning Text
  | ProviderStopAbsent
  | ProviderStopReplaced Word64 ForeignObservation
  | ProviderStopConflict ConflictDetail
  | ProviderStopUnsupported UnsupportedDetail
  | ProviderStopFailed FailureDetail
  deriving (Eq, Show)

data ProviderStopCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion
  = ProviderStopCallResult ProviderStopObservation

type role ProviderStopCallResult nominal nominal nominal nominal nominal nominal nominal nominal

data ProviderDeleteObservation
  = ProviderDeleted
  | ProviderAlreadyDeleted
  | ProviderDeleteStillPresent Word64
  | ProviderDeleteReplaced Word64 ForeignObservation
  | ProviderDeleteConflict ConflictDetail
  | ProviderDeleteUnsupported UnsupportedDetail
  | ProviderDeleteFailed FailureDetail
  deriving (Eq, Show)

data ProviderDeleteCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion
  = ProviderDeleteCallResult ProviderDeleteObservation

type role ProviderDeleteCallResult nominal nominal nominal nominal nominal nominal nominal nominal
