{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Portable, plan-indexed reconciliation for a provider-guest durable alias.

This module deliberately supplies no filesystem implementation.  An ordinary
guest-writable namespace cannot make create/delete resistant to another process
with the same privilege, so backend discovery currently reports 'Unsupported'
and never mints 'StrongAliasBackend'.  The preparation and settlement algebra
is usable by a future protected backend without changing its ownership rules.
-}
module HostBootstrap.Substrate.Provider.Alias
  ( GuestAliasSpec,
    mkGuestAliasSpec,
    guestAliasPath,
    guestAliasTarget,
    PreparedGuestAliasCall,
    withPreparedGuestAliasCall,
    AliasCallObservation (..),
    settlePreparedGuestAliasCall,
    StrongAliasBackend,
    discoverStrongAliasBackend,
    runPreparedGuestAliasCall,
    PreparedGuestAliasRelease,
    withPreparedGuestAliasRelease,
    runPreparedGuestAliasRelease,
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Readiness
  ( DurableShareReady,
    Ready,
    dependencyObservationFromReady,
  )
import HostBootstrap.Reconcile
  ( BackendReconcileObservation (..),
    ConflictDetail (..),
    DurableAliasResource,
    DurableShareResource,
    FailureDetail (..),
    ForeignObservation (..),
    Managed,
    Observed,
    OwnershipReceipt,
    PlannedEdge,
    PlannedResource,
    PreparedOperation,
    PreparedPreconditions,
    PriorCommitProof,
    Provisioned,
    ReconcileError (..),
    ReconcileResult,
    RecoveryDisposition (DoNotRetry),
    ResourceHandle,
    Unclassified,
    UnsupportedDetail (..),
    completePreparedUnchanged,
    completeReconcile,
    plannedGuestAliasOperation,
    resourceHandleGeneration,
    resourceHandleKey,
    validateOwnershipReceipt,
    withPreparedSingleDependencyOperation,
  )
import HostBootstrap.Substrate.Provider
  ( SubstrateProvider,
    spProviderKind,
  )

data GuestAliasSpec = GuestAliasSpec FilePath FilePath
  deriving (Eq, Show)

mkGuestAliasSpec :: FilePath -> FilePath -> Either ReconcileError GuestAliasSpec
mkGuestAliasSpec aliasPath target
  | not (guestAbsolute aliasPath) =
      invalid "alias path must be an absolute POSIX guest path"
  | not (guestAbsolute target) =
      invalid "alias target must be an absolute POSIX guest path"
  | '\0' `elem` aliasPath || '\0' `elem` target =
      invalid "alias path and target must not contain NUL"
  | trimGuestPath aliasPath == trimGuestPath target =
      invalid "alias path and target must differ"
  | otherwise = Right (GuestAliasSpec aliasPath target)
  where
    invalid reason =
      Left
        ( Failure
            (FailureDetail "validate provider guest alias" reason DoNotRetry)
        )

guestAliasPath :: GuestAliasSpec -> FilePath
guestAliasPath (GuestAliasSpec aliasPath _) = aliasPath

guestAliasTarget :: GuestAliasSpec -> FilePath
guestAliasTarget (GuestAliasSpec _ target) = target

guestAbsolute :: FilePath -> Bool
guestAbsolute ('/' : _) = True
guestAbsolute _ = False

trimGuestPath :: FilePath -> FilePath
trimGuestPath "/" = "/"
trimGuestPath value = reverse (dropWhile (== '/') (reverse value))

aliasCallDigest :: GuestAliasSpec -> Text
aliasCallDigest spec =
  "guest-alias:"
    <> sized (guestAliasPath spec)
    <> ":"
    <> sized (guestAliasTarget spec)
  where
    sized value = Text.pack (show (length value)) <> ":" <> Text.pack value

data PreparedGuestAliasCall scope planId aliasId shareId operationKey callDigest attempt journalVersion =
  PreparedGuestAliasCall
    GuestAliasSpec
    (ResourceHandle scope planId aliasId DurableAliasResource Unclassified Observed)
    (PreparedOperation scope planId aliasId DurableAliasResource operationKey callDigest attempt journalVersion)
    (PreparedPreconditions scope planId aliasId DurableAliasResource operationKey callDigest attempt journalVersion)

withPreparedGuestAliasCall ::
  PlannedResource scope planId aliasId DurableAliasResource aliasFrame ->
  PlannedEdge
    scope
    planId
    aliasId
    DurableAliasResource
    aliasFrame
    shareId
    DurableShareResource
    shareFrame ->
  ResourceHandle scope planId aliasId DurableAliasResource Unclassified Observed ->
  ResourceHandle scope planId shareId DurableShareResource Managed sharePhase ->
  Ready scope planId shareId DurableShareResource DurableShareReady ->
  GuestAliasSpec ->
  Word64 ->
  Word64 ->
  ( forall operationKey callDigest attempt journalVersion.
    PreparedGuestAliasCall
      scope
      planId
      aliasId
      shareId
      operationKey
      callDigest
      attempt
      journalVersion ->
    result
  ) ->
  Either ReconcileError result
withPreparedGuestAliasCall planned edge aliasHandle shareHandle ready spec attempt journalVersion consume = do
  dependency <- dependencyObservationFromReady shareHandle ready
  descriptor <-
    plannedGuestAliasOperation
      planned
      edge
      aliasHandle
      (aliasCallDigest spec)
  withPreparedSingleDependencyOperation
    descriptor
    dependency
    attempt
    journalVersion
    ( \prepared preconditions ->
        consume
          ( PreparedGuestAliasCall
              spec
              aliasHandle
              prepared
              preconditions
          )
    )

{- | Structured result from the protected backend boundary.  Created/repaired
observations authorize ownership only after settlement against the exact
prepared operation.  A compatible link without prior commit proof is explicitly
foreign.
-}
data AliasCallObservation
  = AliasCallCreated Word64
  | AliasCallRepaired Word64
  | AliasCallAlreadyExact Word64
  | AliasCallForeign Word64 ForeignObservation
  | AliasCallConflict ConflictDetail
  | AliasCallUnsupported UnsupportedDetail
  | AliasCallFailed FailureDetail
  deriving (Eq, Show)

settlePreparedGuestAliasCall ::
  Maybe (PriorCommitProof scope planId aliasId DurableAliasResource) ->
  PreparedGuestAliasCall
    scope
    planId
    aliasId
    shareId
    operationKey
    callDigest
    attempt
    journalVersion ->
  AliasCallObservation ->
  Either
    ReconcileError
    (ReconcileResult scope planId aliasId DurableAliasResource Provisioned)
settlePreparedGuestAliasCall
  priorProof
  (PreparedGuestAliasCall spec handle prepared preconditions)
  observation =
    case observation of
      AliasCallCreated generation ->
        completeReconcile handle prepared preconditions (BackendCreated generation)
      AliasCallRepaired generation ->
        completeReconcile handle prepared preconditions (BackendRepaired generation)
      AliasCallAlreadyExact generation
        | generation /= resourceHandleGeneration handle ->
            Left
              ( Conflict
                  ( ConflictDetail
                      (resourceHandleKey handle)
                      ("generation=" <> showText (resourceHandleGeneration handle))
                      ("generation=" <> showText generation)
                      "reprobe the alias before classifying the exact link"
                  )
              )
        | Just proof <- priorProof ->
            completePreparedUnchanged handle prepared preconditions proof
        | otherwise ->
            completeReconcile
              handle
              prepared
              preconditions
              ( BackendForeign
                  generation
                  ( ForeignObservation
                      (Text.pack (guestAliasPath spec))
                      "correct target observed without matching committed ownership"
                  )
              )
      AliasCallForeign generation foreignState ->
        completeReconcile
          handle
          prepared
          preconditions
          (BackendForeign generation foreignState)
      AliasCallConflict detail -> Left (Conflict detail)
      AliasCallUnsupported detail -> Left (Unsupported detail)
      AliasCallFailed detail -> Left (Failure detail)

showText :: Show value => value -> Text
showText = Text.pack . show

{- | Capability for a backend with protected identity-bound conditional
mutation and deletion.  Its constructor is private and discovery currently
cannot produce one.
-}
data StrongAliasBackend = StrongAliasBackend

discoverStrongAliasBackend ::
  SubstrateProvider ->
  IO (Either ReconcileError StrongAliasBackend)
discoverStrongAliasBackend provider =
  pure
    ( Left
        ( Unsupported
            ( UnsupportedDetail
                "reconcile provider guest durable alias"
                ( "no protected identity-bound alias backend is available for "
                    <> Text.pack (show (spProviderKind provider))
                    <> "; an ordinary guest-writable symlink is not ownership-safe"
                )
            )
        )
    )

runPreparedGuestAliasCall ::
  StrongAliasBackend ->
  PreparedGuestAliasCall
    scope
    planId
    aliasId
    shareId
    operationKey
    callDigest
    attempt
    journalVersion ->
  IO AliasCallObservation
runPreparedGuestAliasCall StrongAliasBackend _ =
  pure
    ( AliasCallUnsupported
        ( UnsupportedDetail
            "reconcile provider guest durable alias"
            "the portable foundation has no protected mutation interpreter"
        )
    )

data PreparedGuestAliasRelease scope planId aliasId phase releaseId =
  PreparedGuestAliasRelease
    GuestAliasSpec
    (ResourceHandle scope planId aliasId DurableAliasResource Managed phase)
    (OwnershipReceipt scope planId aliasId DurableAliasResource)
    Word64

{- | Prepare conditional deletion.  A foreign/unmanaged handle does not type
check here, and the receipt must match the exact managed generation.
-}
withPreparedGuestAliasRelease ::
  GuestAliasSpec ->
  ResourceHandle scope planId aliasId DurableAliasResource Managed phase ->
  OwnershipReceipt scope planId aliasId DurableAliasResource ->
  Word64 ->
  ( forall releaseId.
    PreparedGuestAliasRelease scope planId aliasId phase releaseId ->
    result
  ) ->
  Either ReconcileError result
withPreparedGuestAliasRelease spec handle receipt conditionalVersion consume
  | conditionalVersion == 0 =
      Left
        ( Failure
            (FailureDetail "prepare guest alias release" "conditional version must be positive" DoNotRetry)
        )
  | otherwise = do
      validateOwnershipReceipt handle receipt
      Right
        ( consume
            (PreparedGuestAliasRelease spec handle receipt conditionalVersion)
        )

runPreparedGuestAliasRelease ::
  StrongAliasBackend ->
  PreparedGuestAliasRelease scope planId aliasId phase releaseId ->
  IO (Either ReconcileError ())
runPreparedGuestAliasRelease StrongAliasBackend _ =
  pure
    ( Left
        ( Unsupported
            ( UnsupportedDetail
                "release provider guest durable alias"
                "the portable foundation has no protected conditional-delete interpreter"
            )
        )
    )
