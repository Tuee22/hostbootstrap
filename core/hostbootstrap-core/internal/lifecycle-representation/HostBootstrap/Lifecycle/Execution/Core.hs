{-# LANGUAGE RoleAnnotations #-}

{- | Shared package-private execution-state representation.

The main library specializes the gate and dependency payload to its own types
and owns registry, service and gate policy. This module retains the actual
references without importing descriptor, gate or dependency representations.
-}
module HostBootstrap.Lifecycle.Execution.Core (
    CarriedResource,
    mintTransferredCarriedResource,
    mintSettledCarriedResource,
    carriedResourceKey,
    carriedResourceGeneration,
    carriedResourceObservationVersion,
    carriedResourceOwnershipOperation,
    carriedResourceSettlement,
    ResourceCarrierCore,
    newResourceCarrierCore,
    resourceCarrierCoreRefs,
    pushCarriedResource,
    readCarriedResources,
    StepRuntimeCore,
    newStepRuntimeCore,
    stepRuntimeCoreRefs,
) where

import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Word (Word64)

{- | One managed resource identity, erased of the generative indices that made
it unforgeable.

"HostBootstrap.Reconcile" retains local managed identities with their settlement
and reopens handles under fresh skolems. "HostBootstrap.Handoff.Process" seeds
authenticated transferred ownership without the parent frame's settlement;
"HostBootstrap.Chain" publishes local settlements before acknowledging outcomes.
A generative handle is never serialised (§ EE), so dependent nodes reopen the
retained evidence inside one interpretation.
-}
data CarriedResource = CarriedResource Text Word64 Word64 Text (Maybe (Text, Maybe ByteString, ByteString))
    deriving (Eq, Show)

{- | Reconstitute authenticated ownership evidence transferred from another
lifecycle frame without claiming that this frame owns its settlement.
-}
mintTransferredCarriedResource :: Text -> Word64 -> Word64 -> Text -> CarriedResource
mintTransferredCarriedResource key generation version operation =
    CarriedResource key generation version operation Nothing

{- | Retain the exact frame and canonical resource member that Chain must
publish before acknowledging the matching operation outcome.
-}
mintSettledCarriedResource :: Text -> Word64 -> Word64 -> Text -> Text -> Maybe ByteString -> ByteString -> CarriedResource
mintSettledCarriedResource key generation version frame operation expected bytes =
    CarriedResource key generation version operation (Just (frame, expected, bytes))

carriedResourceKey :: CarriedResource -> Text
carriedResourceKey (CarriedResource key _ _ _ _) = key

carriedResourceGeneration :: CarriedResource -> Word64
carriedResourceGeneration (CarriedResource _ generation _ _ _) = generation

carriedResourceObservationVersion :: CarriedResource -> Word64
carriedResourceObservationVersion (CarriedResource _ _ version _ _) = version

carriedResourceOwnershipOperation :: CarriedResource -> Text
carriedResourceOwnershipOperation (CarriedResource _ _ _ operation _) = operation

carriedResourceSettlement :: CarriedResource -> Maybe (Text, Maybe ByteString, ByteString)
carriedResourceSettlement (CarriedResource _ _ _ _ settlement) = settlement

{- | The references shared by one exact plan interpretation.

The dependency payload is supplied by the main library. All parameters are
nominal so neither a carrier's scope, plan nor payload identity can be relabelled.
-}
newtype ResourceCarrierCore scope planId dependencyPayload
    = ResourceCarrierCore
        ( IORef [CarriedResource]
        , IORef [dependencyPayload]
        , IORef [(Text, Text, ByteString -> IO (Either Text ByteString))]
        , IORef (Maybe (ByteString -> IO (Either Text ByteString)))
        )

type role ResourceCarrierCore nominal nominal nominal

newResourceCarrierCore :: IO (ResourceCarrierCore scope planId dependencyPayload)
newResourceCarrierCore = do
    carried <- newIORef []
    packages <- newIORef []
    services <- newIORef []
    activation <- newIORef Nothing
    pure (ResourceCarrierCore (carried, packages, services, activation))

-- | Borrow the actual references for main's registry and service algorithms.
resourceCarrierCoreRefs ::
    ResourceCarrierCore scope planId dependencyPayload ->
    ( IORef [CarriedResource]
    , IORef [dependencyPayload]
    , IORef [(Text, Text, ByteString -> IO (Either Text ByteString))]
    , IORef (Maybe (ByteString -> IO (Either Text ByteString)))
    )
resourceCarrierCoreRefs (ResourceCarrierCore refs) = refs

{- | Carry one managed resource, replacing any earlier entry under the same
operation key. A node that re-runs mints a fresh handle for the same key, and
dependency traversal must observe that newest retained identity.
-}
pushCarriedResource :: ResourceCarrierCore scope planId dependencyPayload -> CarriedResource -> IO ()
pushCarriedResource (ResourceCarrierCore (entries, _, _, _)) entry =
    atomicModifyIORef'
        entries
        ( \carried ->
            ( filter ((/= carriedResourceKey entry) . carriedResourceKey) carried ++ [entry]
            , ()
            )
        )

readCarriedResources :: ResourceCarrierCore scope planId dependencyPayload -> IO [CarriedResource]
readCarriedResources (ResourceCarrierCore (entries, _, _, _)) = readIORef entries

{- | One node's gate references and its interpretation's shared carrier.

The gate and dependency payload are supplied by main. This representation
contains no operation-key projection or gate-matching policy.
-}
data StepRuntimeCore scope planId gate dependencyPayload
    = StepRuntimeCore
        (IORef (Maybe gate))
        (IORef [gate])
        (IORef [gate])
        (ResourceCarrierCore scope planId dependencyPayload)

type role StepRuntimeCore nominal nominal nominal nominal

-- | Allocate empty own, available and taken gate references over the actual carrier.
newStepRuntimeCore ::
    ResourceCarrierCore scope planId dependencyPayload ->
    IO (StepRuntimeCore scope planId gate dependencyPayload)
newStepRuntimeCore carrier = do
    own <- newIORef Nothing
    available <- newIORef []
    taken <- newIORef []
    pure (StepRuntimeCore own available taken carrier)

-- | Borrow the actual gate references and carrier for main's runtime algorithms.
stepRuntimeCoreRefs ::
    StepRuntimeCore scope planId gate dependencyPayload ->
    ( IORef (Maybe gate)
    , IORef [gate]
    , IORef [gate]
    , ResourceCarrierCore scope planId dependencyPayload
    )
stepRuntimeCoreRefs (StepRuntimeCore own available taken carrier) =
    (own, available, taken, carrier)
