{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Hidden, narrowly scoped authority for retrying cleanup after one failed Up.

The child producer joins the root authority, catalog, failed rooted session,
and frozen reached-operation set. The root-local producer joins the root frame
to the catalog and records its fixed root path, token, and ordinal. Its folds
can select cleanup work from that set; they cannot construct a reverse root,
change Production mode, or mint Destroy authority.
-}
module HostBootstrap.Authority.FailedUp.Internal (
    FailedUpUnwindAuthority,
    withFailedUpUnwindAuthorityKernel,
    withRootFailedUpUnwindAuthorityKernel,
    failedUpUnwindCatalogIdentity,
    withFailedUpCleanupOperationsKernel,
)
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Authority (
    RootInvocationAuthority,
    VerbUp,
    brokerEpochWord,
    projectVerbName,
    rootAuthorityEpoch,
    rootAuthorityProjectName,
    rootAuthorityVerb,
 )
import HostBootstrap.Handoff (
    eliminateLifecycleReport,
    handoffErrorMessage,
    lifecycleObservationsFromWire,
 )
import HostBootstrap.Lifecycle.Rooted (
    RootedFrameSession,
    withFailedRootedFrameSessionKernel,
 )
import HostBootstrap.Lifecycle.RootedPlan (
    RootedPlanCatalog,
    rootedPlanCatalogRecordIdentityKernel,
    withRootedPlanCatalogRootKernel,
 )
import HostBootstrap.ProjectPlan (renderSnapshot, stablePlanSnapshotDigest)
import HostBootstrap.ProjectPlan.Frame (currentFrameId)

data FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId
    = FailedUpUnwindAuthority Text Text Word64 Text Text [Text] Text Word64 ByteString [Text] [Text]

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
                        project
                        lineage
                        epoch
                        catalogIdentity
                        frame
                        path
                        token
                        ordinal
                        report
                        reached
                        unresolved
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
    withRootedPlanCatalogRootKernel catalog $ \_ catalogRoot plan current _ -> do
        require "the catalog root is not this Up authority" (projectVerbName (rootAuthorityVerb catalogRoot) == projectVerbName (rootAuthorityVerb root))
        require "the catalog root names another project" (rootAuthorityProjectName catalogRoot == project)
        require "the catalog root names another broker generation" (brokerEpochWord (rootAuthorityEpoch catalogRoot) == epoch)
        require "the failed root frame is not the catalog root" (frame == currentFrameId current)
        let lineage = stablePlanSnapshotDigest (renderSnapshot plan)
        Right (use (FailedUpUnwindAuthority project lineage epoch catalogIdentity frame [frame] "root" 0 report reached unresolved))

withFailedUpCleanupOperationsKernel ::
    FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId ->
    ([Text] -> result) ->
    result
withFailedUpCleanupOperationsKernel
    (FailedUpUnwindAuthority _ _ _ _ _ _ _ _ _ _ operations)
    use = use operations

failedUpUnwindCatalogIdentity :: FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId -> Text
failedUpUnwindCatalogIdentity (FailedUpUnwindAuthority _ _ _ catalog _ _ _ _ _ _ _) = catalog

failedReport :: ByteString -> ByteString -> ByteString -> Text -> Text -> Maybe (ByteString, [Text])
failedReport binding _origin observations detail verb
    | verb /= "up" = Nothing
    | Text.null detail = Nothing
    | otherwise =
        case lifecycleObservationsFromWire observations of
            Left _ -> Nothing
            Right rows
                | null rows || not (any (\(_, status, _) -> status == "failed") rows) -> Nothing
                | otherwise -> Just (binding, [operation | (operation, _, _) <- rows, not ("descent/" `Text.isPrefixOf` operation)])

wrong :: ByteString -> ByteString -> ByteString -> Text -> Text -> Maybe (ByteString, [Text])
wrong _ _ _ _ _ = Nothing

validateSets :: [Text] -> [Text] -> Either Text ()
validateSets reached unresolved = do
    require "the reached-operation set contains a duplicate" (nub reached == reached)
    require "an unresolved operation was not reached by the failed Up" (all (`elem` reached) unresolved)
    require "the unresolved-operation set contains a duplicate" (nub unresolved == unresolved)

verifyFailureReport :: ByteString -> ByteString -> [Text] -> Either Text ()
verifyFailureReport report expectedBinding reached = do
    require "the admitted binding is empty" (not (ByteString.null expectedBinding))
    verified <-
        either (Left . ("failed-Up unwind authority: " <>) . Text.pack . handoffErrorMessage) Right $
            eliminateLifecycleReport report wrong wrong failedReport wrong wrong wrong
    (verifiedBinding, reportedOperations) <- maybe (Left "failed-Up unwind authority: the report is not a failed forward report") Right verified
    require "the failed report names another admitted binding" (verifiedBinding == expectedBinding)
    require "the failed report reaches an operation outside the frozen prefix" (all (`elem` reached) reportedOperations)

require :: Text -> Bool -> Either Text ()
require _ True = Right ()
require detail False = Left ("failed-Up unwind authority: " <> detail)
