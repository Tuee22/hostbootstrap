{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Hidden, narrowly scoped authority for retrying cleanup after one failed Up.

The value retains only coordinates already joined by the root authority,
catalog, failed rooted session, and frozen reached-operation set.  Its folds
can select cleanup work from that set; they cannot construct a reverse root,
change Production mode, or mint Destroy authority.
-}
module HostBootstrap.Authority.FailedUp.Internal
    ( FailedUpUnwindAuthority
    , withFailedUpUnwindAuthorityKernel
    , withRootFailedUpUnwindAuthorityKernel
    , withRetriedFailedUpUnwindAuthorityKernel
    , withFailedUpCleanupOperationsKernel
    )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Authority
    ( RootInvocationAuthority
    , VerbUp
    , brokerEpochWord
    , rootAuthorityEpoch
    , rootAuthorityProjectName
    , rootAuthorityVerb
    , projectVerbName
    )
import HostBootstrap.Lifecycle.Rooted
    ( RootedFrameSession
    , withFailedRootedFrameSessionKernel
    )
import HostBootstrap.Lifecycle.RootedPlan
    ( RootedPlanCatalog
    , rootedPlanCatalogRecordIdentityKernel
    , withRootedPlanCatalogRootKernel
    )
import HostBootstrap.ProjectPlan (renderSnapshot, stablePlanSnapshotDigest)
import HostBootstrap.Handoff
    ( eliminateLifecycleReport
    , handoffErrorMessage
    , lifecycleObservationsFromWire
    )

data FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId =
    FailedUpUnwindAuthority Text Text Word64 Text Text [Text] Text Word64 ByteString [Text] [Text]

type role FailedUpUnwindAuthority nominal nominal nominal nominal

withFailedUpUnwindAuthorityKernel ::
    RootInvocationAuthority scope brokerGeneration VerbUp ->
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    RootedFrameSession scope rootPlanId brokerGeneration sessionCatalogId frame sessionId VerbUp ->
    ByteString ->
    ByteString ->
    [Text] ->
    [Text] ->
    (FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId -> result) ->
    Either Text result
withFailedUpUnwindAuthorityKernel root catalog failed report expectedBinding reached unresolved use = do
    validateSets reached unresolved
    verifyFailureReport report expectedBinding reached
    joined <- withFailedRootedFrameSessionKernel failed $ \lineage sessionCatalog frame path token ordinal -> do
        let catalogIdentity = rootedPlanCatalogRecordIdentityKernel catalog
            epoch = brokerEpochWord (rootAuthorityEpoch root)
            project = rootAuthorityProjectName root
        require "the failed session names another catalog" (sessionCatalog == catalogIdentity)
        withRootedPlanCatalogRootKernel catalog $ \_ catalogRoot plan _ _ -> do
            require "the catalog root is not this Up authority" (projectVerbName (rootAuthorityVerb catalogRoot) == projectVerbName (rootAuthorityVerb root))
            require "the catalog root names another project" (rootAuthorityProjectName catalogRoot == project)
            require "the catalog root names another broker generation" (brokerEpochWord (rootAuthorityEpoch catalogRoot) == epoch)
            require "the failed session names another root plan" (lineage == stablePlanSnapshotDigest (renderSnapshot plan))
            Right
                ( use
                    ( FailedUpUnwindAuthority
                        project lineage epoch catalogIdentity frame path token ordinal report reached unresolved
                    )
                )
    joined

withRootFailedUpUnwindAuthorityKernel ::
    RootInvocationAuthority scope brokerGeneration VerbUp ->
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    ByteString ->
    ByteString ->
    Text ->
    [Text] ->
    [Text] ->
    (FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId -> result) ->
    Either Text result
withRootFailedUpUnwindAuthorityKernel root catalog report expectedBinding frame reached unresolved use = do
    validateSets reached unresolved
    verifyFailureReport report expectedBinding reached
    let catalogIdentity = rootedPlanCatalogRecordIdentityKernel catalog
        epoch = brokerEpochWord (rootAuthorityEpoch root)
        project = rootAuthorityProjectName root
    withRootedPlanCatalogRootKernel catalog $ \_ catalogRoot plan _ _ -> do
        require "the catalog root is not this Up authority" (projectVerbName (rootAuthorityVerb catalogRoot) == projectVerbName (rootAuthorityVerb root))
        require "the catalog root names another project" (rootAuthorityProjectName catalogRoot == project)
        require "the catalog root names another broker generation" (brokerEpochWord (rootAuthorityEpoch catalogRoot) == epoch)
        let lineage = stablePlanSnapshotDigest (renderSnapshot plan)
        Right (use (FailedUpUnwindAuthority project lineage epoch catalogIdentity frame [frame] "root" 0 report reached unresolved))

withRetriedFailedUpUnwindAuthorityKernel ::
    FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId ->
    RootInvocationAuthority scope brokerGeneration VerbUp ->
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    RootedFrameSession scope rootPlanId brokerGeneration sessionCatalogId frame sessionId VerbUp ->
    ByteString ->
    ByteString ->
    [Text] ->
    [Text] ->
    (FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId -> result) ->
    Either Text result
withRetriedFailedUpUnwindAuthorityKernel retained root catalog failed report expectedBinding reached unresolved use = do
    retried <- withFailedUpUnwindAuthorityKernel root catalog failed report expectedBinding reached unresolved $ \candidate -> do
        require "the failed-Up retry changes its cleanup coordinates" (sameAuthority retained candidate)
        Right (use candidate)
    retried

withFailedUpCleanupOperationsKernel ::
    FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId ->
    ([Text] -> result) ->
    result
withFailedUpCleanupOperationsKernel
    (FailedUpUnwindAuthority _ _ _ _ _ _ _ _ _ _ operations)
    use = use operations

sameAuthority ::
    FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId ->
    FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId ->
    Bool
sameAuthority
    (FailedUpUnwindAuthority p l e c f path token ordinal report reached operations)
    (FailedUpUnwindAuthority p' l' e' c' f' path' token' ordinal' report' reached' operations') =
        (p, l, e, c, f, path, token, ordinal, report, reached, operations)
            == (p', l', e', c', f', path', token', ordinal', report', reached', operations')

failedReport :: ByteString -> ByteString -> ByteString -> Text -> Text -> (ByteString, [Text])
failedReport binding _origin observations detail verb
    | verb /= "up" = emptyReport
    | Text.null detail = emptyReport
    | otherwise =
        case lifecycleObservationsFromWire observations of
            Left _ -> emptyReport
            Right rows
                | null rows || not (any (\(_, status, _) -> status == "failed") rows) -> emptyReport
                | otherwise -> (binding, [operation | (operation, _, _) <- rows])

wrong :: ByteString -> ByteString -> ByteString -> Text -> Text -> (ByteString, [Text])
wrong _ _ _ _ _ = emptyReport

emptyReport :: (ByteString, [Text])
emptyReport = (ByteString.empty, [])

validateSets :: [Text] -> [Text] -> Either Text ()
validateSets reached unresolved = do
    require "the reached-operation set contains a duplicate" (nub reached == reached)
    require "an unresolved operation was not reached by the failed Up" (all (`elem` reached) unresolved)
    require "the unresolved-operation set contains a duplicate" (nub unresolved == unresolved)

verifyFailureReport :: ByteString -> ByteString -> [Text] -> Either Text ()
verifyFailureReport report expectedBinding reached = do
    (verifiedBinding, reportedOperations) <-
        either (Left . ("failed-Up unwind authority: " <>) . Text.pack . handoffErrorMessage) Right $
            eliminateLifecycleReport report wrong wrong failedReport wrong wrong wrong
    require "the failed report names another admitted binding" (verifiedBinding == expectedBinding)
    require "the failed report reaches an operation outside the frozen prefix" (all (`elem` reached) reportedOperations)

require :: Text -> Bool -> Either Text ()
require _ True = Right ()
require detail False = Left ("failed-Up unwind authority: " <> detail)
