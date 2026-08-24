{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Backend-neutral, invocation-local dependency commitments.

This Cabal-private leaf stores canonical recovery coordinates only.  In
particular, it imports no provider, cluster, reconciliation, execution, plan,
prepared-gate, receipt-authority, or managed-handle module.  A live reprobe is
kept separately by the execution registry and is selected only after one of
the exact domain openers below accepts this commitment.
-}
module HostBootstrap.Lifecycle.Dependency.Internal (
    RuntimeDependencyPackage,
    mkProviderRuntimeDependencyPackage,
    mkProviderShareRuntimeDependencyPackage,
    mkClusterRuntimeDependencyPackage,
    runtimeDependencyPackageKey,
    runtimeDependencyPackageDomain,
    runtimeDependencyPackageResource,
    runtimeDependencyPackageGeneration,
    runtimeDependencyPackageRoute,
    runtimeDependencyPackageCommitment,
    renderRuntimeDependencyPackage,
    runtimeDependencyPackageWire,
    runtimeDependencyPackageFromWire,
    runtimeDependencyPackageBundleWire,
    runtimeDependencyPackagesFromBundleWire,
    withProviderRuntimeDependencyPackage,
    withProviderRuntimeDependencyCoordinates,
    withCarriedProviderRuntimeDependencyCoordinates,
    withCarriedProviderShareRuntimeDependencyCoordinates,
    withClusterRuntimeDependencyPackage,
    withClusterRuntimeDependencyCoordinates,
    withClusterRuntimeDependencySuccessor,
    runtimeDependencyProbeRequest,
    withRuntimeDependencyProbeRequest,
    renderRuntimeDependencyProbeResponse,
    renderRuntimeDependencyProbeRefusal,
    verifyRuntimeDependencyProbeOutcome,
    verifyRuntimeDependencyProbeResponse,
    runtimeDependencyExposureRequest,
    withRuntimeDependencyExposureRequest,
    renderRuntimeDependencyExposureResponse,
    verifyRuntimeDependencyExposureResponse,
    runtimeDependencyChartRequest,
    withRuntimeDependencyChartRequest,
    renderRuntimeDependencyChartResponse,
    verifyRuntimeDependencyChartResponse,
) where

import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)

{- | One canonical provider- or cluster-recovery commitment.

The constructors are the closed domain tag.  Every other field has identical
meaning in both domains: plan and scope commitments, resource and frame,
backend origin and generation, journal and receipt commitments, bounded
client route, and exclusive expiry tick.
-}
data RuntimeDependencyPackage scope planId
    = ProviderRuntimeDependencyPackage Text Text Text Text Text Word64 Text Text Text Word64
    | ProviderShareRuntimeDependencyPackage Text Text Text Text Text Word64 Text Text Text Word64
    | ClusterRuntimeDependencyPackage Text Text Text Text Text Word64 Text Text Text Word64
    deriving (Eq, Show)

type role RuntimeDependencyPackage nominal nominal

mkProviderRuntimeDependencyPackage ::
    Text -> Text -> Text -> Text -> Text -> Word64 -> Text -> Text -> Text -> Word64 -> Either Text (RuntimeDependencyPackage scope planId)
mkProviderRuntimeDependencyPackage = makePackage "provider" ProviderRuntimeDependencyPackage

mkProviderShareRuntimeDependencyPackage ::
    Text -> Text -> Text -> Text -> Text -> Word64 -> Text -> Text -> Text -> Word64 -> Either Text (RuntimeDependencyPackage scope planId)
mkProviderShareRuntimeDependencyPackage = makePackage "provider-share" ProviderShareRuntimeDependencyPackage

mkClusterRuntimeDependencyPackage ::
    Text -> Text -> Text -> Text -> Text -> Word64 -> Text -> Text -> Text -> Word64 -> Either Text (RuntimeDependencyPackage scope planId)
mkClusterRuntimeDependencyPackage = makePackage "cluster" ClusterRuntimeDependencyPackage

makePackage ::
    Text ->
    (Text -> Text -> Text -> Text -> Text -> Word64 -> Text -> Text -> Text -> Word64 -> RuntimeDependencyPackage scope planId) ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Either Text (RuntimeDependencyPackage scope planId)
makePackage domain construct plan scope resource frame origin generation journal receipt route expiry = do
    mapM_
        requireField
        [ ("plan", plan)
        , ("scope", scope)
        , ("resource", resource)
        , ("frame", frame)
        , ("backend origin", origin)
        , ("journal commitment", journal)
        , ("receipt commitment", receipt)
        ]
    require (generation > 0) "runtime dependency generation must be positive"
    require (expiry > 0) "runtime dependency expiry must be positive"
    require (Text.isPrefixOf ("runtime://" <> domain <> "/") route) "runtime dependency route has the wrong domain"
    require (routeBytes <= maximumRouteBytes) "runtime dependency route exceeds its canonical bound"
    pure (construct plan scope resource frame origin generation journal receipt route expiry)
  where
    requireField (label, value) = do
        require (not (Text.null value)) ("runtime dependency " <> label <> " is empty")
        require (encodedLength value <= maximumFieldBytes) ("runtime dependency " <> label <> " exceeds its canonical bound")
    routeBytes = encodedLength route

runtimeDependencyPackageKey :: RuntimeDependencyPackage scope planId -> Text
runtimeDependencyPackageKey package =
    domainOf package <> ":" <> resourceOf package

runtimeDependencyPackageDomain :: RuntimeDependencyPackage scope planId -> Text
runtimeDependencyPackageDomain = domainOf

runtimeDependencyPackageResource :: RuntimeDependencyPackage scope planId -> Text
runtimeDependencyPackageResource = resourceOf

runtimeDependencyPackageGeneration :: RuntimeDependencyPackage scope planId -> Word64
runtimeDependencyPackageGeneration = generationOf

runtimeDependencyPackageRoute :: RuntimeDependencyPackage scope planId -> Text
runtimeDependencyPackageRoute package =
    case package of
        ProviderRuntimeDependencyPackage _ _ _ _ _ _ _ _ route _ -> route
        ProviderShareRuntimeDependencyPackage _ _ _ _ _ _ _ _ route _ -> route
        ClusterRuntimeDependencyPackage _ _ _ _ _ _ _ _ route _ -> route

-- | Exact canonical bytes used to bind the separate live-service entry.
runtimeDependencyPackageCommitment :: RuntimeDependencyPackage scope planId -> Text
runtimeDependencyPackageCommitment = renderRuntimeDependencyPackage

renderRuntimeDependencyPackage :: RuntimeDependencyPackage scope planId -> Text
renderRuntimeDependencyPackage package =
    Text.concat
        ( map
            frameText
            [ "hostbootstrap/runtime-dependency/v1"
            , domainOf package
            , planOf package
            , scopeOf package
            , resourceOf package
            , frameOf package
            , originOf package
            , Text.pack (show (generationOf package))
            , journalOf package
            , receiptOf package
            , runtimeDependencyPackageRoute package
            , Text.pack (show (expiryOf package))
            ]
        )

runtimeDependencyPackageWire :: RuntimeDependencyPackage scope planId -> ByteString.ByteString
runtimeDependencyPackageWire = TextEncoding.encodeUtf8 . renderRuntimeDependencyPackage

runtimeDependencyPackageFromWire :: ByteString.ByteString -> Either Text (RuntimeDependencyPackage scope planId)
runtimeDependencyPackageFromWire raw = do
    require (ByteString.length raw <= maximumPackageBytes) "runtime dependency package exceeds its canonical bound"
    fields <- parseWireFields raw
    package <- case fields of
        [version, domain, plan, scope, resource, frame, origin, generationText, journal, receipt, route, expiryText] -> do
            require (version == "hostbootstrap/runtime-dependency/v1") "runtime dependency package version mismatch"
            generation <- parsePositiveWord generationText
            expiry <- parsePositiveWord expiryText
            case domain of
                "provider" -> mkProviderRuntimeDependencyPackage plan scope resource frame origin generation journal receipt route expiry
                "provider-share" -> mkProviderShareRuntimeDependencyPackage plan scope resource frame origin generation journal receipt route expiry
                "cluster" -> mkClusterRuntimeDependencyPackage plan scope resource frame origin generation journal receipt route expiry
                _ -> Left "runtime dependency package domain is unknown"
        _ -> Left "runtime dependency package field count differs"
    require (runtimeDependencyPackageWire package == raw) "runtime dependency package is not canonical"
    pure package

runtimeDependencyPackageBundleWire :: [RuntimeDependencyPackage scope planId] -> Either Text ByteString.ByteString
runtimeDependencyPackageBundleWire packages = do
    require (not (null packages)) "runtime dependency package bundle is empty"
    require (length packages <= maximumBundlePackages) "runtime dependency package bundle has too many packages"
    require (distinct (map runtimeDependencyPackageKey packages)) "runtime dependency package bundle contains a duplicate key"
    let wire = wireFields ("hostbootstrap/runtime-dependency-bundle/v1" : map renderRuntimeDependencyPackage packages)
    require (ByteString.length wire <= maximumBundleBytes) "runtime dependency package bundle exceeds its canonical bound"
    pure wire

runtimeDependencyPackagesFromBundleWire :: ByteString.ByteString -> Either Text [RuntimeDependencyPackage scope planId]
runtimeDependencyPackagesFromBundleWire raw = do
    require (ByteString.length raw <= maximumBundleBytes) "runtime dependency package bundle exceeds its canonical bound"
    fields <- parseWireFields raw
    packages <- case fields of
        "hostbootstrap/runtime-dependency-bundle/v1" : packageFields -> do
            require (not (null packageFields)) "runtime dependency package bundle is empty"
            require (length packageFields <= maximumBundlePackages) "runtime dependency package bundle has too many packages"
            traverse (runtimeDependencyPackageFromWire . TextEncoding.encodeUtf8) packageFields
        _ -> Left "runtime dependency package bundle domain mismatch"
    canonical <- runtimeDependencyPackageBundleWire packages
    require (canonical == raw) "runtime dependency package bundle is not canonical"
    pure packages

withProviderRuntimeDependencyPackage ::
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    RuntimeDependencyPackage scope planId ->
    (Text -> result) ->
    Either Text result
withProviderRuntimeDependencyPackage = openPackage "provider"

{- | Check every provider coordinate available to a fixed successor while
keeping the producer's opaque gate/Ready commitments sealed in this owner.
Their integrity is still part of the exact package commitment used to select
the live service.
-}
withProviderRuntimeDependencyCoordinates ::
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    Word64 ->
    RuntimeDependencyPackage scope planId ->
    (Text -> result) ->
    Either Text result
withProviderRuntimeDependencyCoordinates plan scope resource frame origin generation route now package use = do
    require (domainOf package == "provider") "runtime dependency domain mismatch"
    require (planOf package == plan) "runtime dependency plan mismatch"
    require (scopeOf package == scope) "runtime dependency scope mismatch"
    require (resourceOf package == resource) "runtime dependency resource mismatch"
    require (frameOf package == frame) "runtime dependency frame mismatch"
    require (originOf package == origin) "runtime dependency backend origin mismatch"
    require (generationOf package == generation) "runtime dependency generation mismatch"
    require (runtimeDependencyPackageRoute package == route) "runtime dependency route mismatch"
    require (now < expiryOf package) "runtime dependency package is expired"
    pure (use route)

withCarriedProviderRuntimeDependencyCoordinates ::
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    Word64 ->
    RuntimeDependencyPackage scope planId ->
    (Text -> Text -> result) ->
    Either Text result
withCarriedProviderRuntimeDependencyCoordinates scope resource frame generation route now package use = do
    require (domainOf package == "provider") "runtime dependency domain mismatch"
    -- A carried package names the producer's plan, not the successor's
    -- projected plan.  Its exact producer-plan commitment remains sealed in
    -- the authenticated handoff package and selects the paired live service;
    -- successor recovery checks the shared scope and concrete resource
    -- coordinates below rather than equating distinct plan identities.
    require (scopeOf package == scope) "runtime dependency scope mismatch"
    require (resourceOf package == resource) "runtime dependency resource mismatch"
    require (frameOf package == frame) "runtime dependency frame mismatch"
    require (generationOf package == generation) "runtime dependency generation mismatch"
    require (runtimeDependencyPackageRoute package == route) "runtime dependency route mismatch"
    require (now < expiryOf package) "runtime dependency package is expired"
    pure (use (originOf package) route)

withCarriedProviderShareRuntimeDependencyCoordinates ::
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    Word64 ->
    RuntimeDependencyPackage scope planId ->
    (Text -> Text -> result) ->
    Either Text result
withCarriedProviderShareRuntimeDependencyCoordinates scope resource frame generation route now package use = do
    require (domainOf package == "provider-share") "runtime dependency domain mismatch"
    require (scopeOf package == scope) "runtime dependency scope mismatch"
    require (resourceOf package == resource) "runtime dependency resource mismatch"
    require (frameOf package == frame) "runtime dependency frame mismatch"
    require (generationOf package == generation) "runtime dependency generation mismatch"
    require (runtimeDependencyPackageRoute package == route) "runtime dependency route mismatch"
    require (now < expiryOf package) "runtime dependency package is expired"
    pure (use (originOf package) route)

withClusterRuntimeDependencyPackage ::
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    RuntimeDependencyPackage scope planId ->
    (Text -> result) ->
    Either Text result
withClusterRuntimeDependencyPackage = openPackage "cluster"

{- | Check the successor-visible cluster coordinates while the sealed journal
and ready-settlement commitments remain bound by the package commitment used
to select its separate live service.
-}
withClusterRuntimeDependencyCoordinates ::
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    Word64 ->
    RuntimeDependencyPackage scope planId ->
    (Text -> result) ->
    Either Text result
withClusterRuntimeDependencyCoordinates plan scope resource frame origin generation route now package use = do
    require (domainOf package == "cluster") "runtime dependency domain mismatch"
    require (planOf package == plan) "runtime dependency plan mismatch"
    require (scopeOf package == scope) "runtime dependency scope mismatch"
    require (resourceOf package == resource) "runtime dependency resource mismatch"
    require (frameOf package == frame) "runtime dependency frame mismatch"
    require (originOf package == origin) "runtime dependency backend origin mismatch"
    require (generationOf package == generation) "runtime dependency generation mismatch"
    require (runtimeDependencyPackageRoute package == route) "runtime dependency route mismatch"
    require (now < expiryOf package) "runtime dependency package is expired"
    pure (use route)

withClusterRuntimeDependencySuccessor ::
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    Word64 ->
    RuntimeDependencyPackage scope planId ->
    (Text -> result) ->
    Either Text result
withClusterRuntimeDependencySuccessor plan scope resource frame generation route now package =
    withClusterRuntimeDependencyCoordinates
        plan
        scope
        resource
        frame
        (originOf package)
        generation
        route
        now
        package

openPackage ::
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    RuntimeDependencyPackage scope planId ->
    (Text -> result) ->
    Either Text result
openPackage domain plan scope resource frame origin generation journal receipt route now package use = do
    require (domainOf package == domain) "runtime dependency domain mismatch"
    require (planOf package == plan) "runtime dependency plan mismatch"
    require (scopeOf package == scope) "runtime dependency scope mismatch"
    require (resourceOf package == resource) "runtime dependency resource mismatch"
    require (frameOf package == frame) "runtime dependency frame mismatch"
    require (originOf package == origin) "runtime dependency backend origin mismatch"
    require (generationOf package == generation) "runtime dependency generation mismatch"
    require (journalOf package == journal) "runtime dependency journal commitment mismatch"
    require (receiptOf package == receipt) "runtime dependency receipt commitment mismatch"
    require (runtimeDependencyPackageRoute package == route) "runtime dependency route mismatch"
    require (now < expiryOf package) "runtime dependency package is expired"
    pure (use (runtimeDependencyPackageRoute package))

runtimeDependencyProbeRequest :: RuntimeDependencyPackage scope planId -> Text -> Either Text ByteString.ByteString
runtimeDependencyProbeRequest package nonce = do
    requireNonce nonce
    pure (wireFields ["hostbootstrap/runtime-dependency-probe/v1", runtimeDependencyPackageCommitment package, nonce])

withRuntimeDependencyProbeRequest ::
    RuntimeDependencyPackage scope planId ->
    ByteString.ByteString ->
    (Text -> result) ->
    Either Text result
withRuntimeDependencyProbeRequest package raw use = do
    require (ByteString.length raw <= maximumProbeBytes) "runtime dependency probe request exceeds its canonical bound"
    fields <- parseWireFields raw
    case fields of
        [domain, commitment, nonce] -> do
            require (domain == "hostbootstrap/runtime-dependency-probe/v1") "runtime dependency probe request domain mismatch"
            require (commitment == runtimeDependencyPackageCommitment package) "runtime dependency probe request commitment mismatch"
            requireNonce nonce
            require (wireFields fields == raw) "runtime dependency probe request is not canonical"
            pure (use nonce)
        _ -> Left "runtime dependency probe request field count differs"

renderRuntimeDependencyProbeResponse :: RuntimeDependencyPackage scope planId -> Text -> Word64 -> ByteString.ByteString
renderRuntimeDependencyProbeResponse package nonce generation =
    wireFields
        [ "hostbootstrap/runtime-dependency-probe-response/v1"
        , runtimeDependencyPackageCommitment package
        , nonce
        , Text.pack (show generation)
        ]

renderRuntimeDependencyProbeRefusal ::
    RuntimeDependencyPackage scope planId ->
    Text ->
    Text ->
    Either Text ByteString.ByteString
renderRuntimeDependencyProbeRefusal package nonce reason = do
    requireNonce nonce
    require (not (Text.null reason)) "runtime dependency probe refusal reason is empty"
    require (encodedLength reason <= maximumFieldBytes) "runtime dependency probe refusal reason exceeds its bound"
    pure $
        wireFields
            [ "hostbootstrap/runtime-dependency-probe-refused/v1"
            , runtimeDependencyPackageCommitment package
            , nonce
            , reason
            ]

verifyRuntimeDependencyProbeResponse ::
    RuntimeDependencyPackage scope planId ->
    Text ->
    ByteString.ByteString ->
    Either Text Word64
verifyRuntimeDependencyProbeResponse package expectedNonce raw = do
    outcome <- verifyRuntimeDependencyProbeOutcome package expectedNonce raw
    either (Left . ("runtime dependency probe refused: " <>)) Right outcome

runtimeDependencyExposureRequest :: RuntimeDependencyPackage scope planId -> Text -> Either Text ByteString.ByteString
runtimeDependencyExposureRequest package nonce = do
    requireNonce nonce
    pure (wireFields ["hostbootstrap/runtime-dependency-exposure/v1", runtimeDependencyPackageCommitment package, nonce])

withRuntimeDependencyExposureRequest ::
    RuntimeDependencyPackage scope planId ->
    ByteString.ByteString ->
    (Text -> result) ->
    Either Text result
withRuntimeDependencyExposureRequest package raw use = do
    require (ByteString.length raw <= maximumProbeBytes) "runtime dependency exposure request exceeds its canonical bound"
    fields <- parseWireFields raw
    case fields of
        [domain, commitment, nonce] -> do
            require (domain == "hostbootstrap/runtime-dependency-exposure/v1") "runtime dependency exposure request domain mismatch"
            require (commitment == runtimeDependencyPackageCommitment package) "runtime dependency exposure request commitment mismatch"
            requireNonce nonce
            require (wireFields fields == raw) "runtime dependency exposure request is not canonical"
            pure (use nonce)
        _ -> Left "runtime dependency exposure request field count differs"

renderRuntimeDependencyExposureResponse ::
    RuntimeDependencyPackage scope planId ->
    Text ->
    [(Text, Text, Int, Text, Int, Text, Word64, Text)] ->
    Either Text ByteString.ByteString
renderRuntimeDependencyExposureResponse package nonce exposures = do
    requireNonce nonce
    require (not (null exposures)) "runtime dependency exposure response is empty"
    require (distinct (map exposureServiceField exposures)) "runtime dependency exposure response duplicates a service"
    mapM_ validateExposure exposures
    pure (wireFields (["hostbootstrap/runtime-dependency-exposure-response/v1", runtimeDependencyPackageCommitment package, nonce] <> concatMap exposureFields exposures))
  where
    exposureServiceField (service, _, _, _, _, _, _, _) = service
    validateExposure (service, address, hostPort, target, targetPort, relay, generation, operation) = do
        mapM_ requireExposureField [("service", service), ("address", address), ("target", target), ("relay", relay), ("operation", operation)]
        require (address == "127.0.0.1") "runtime dependency exposure address is not loopback"
        require (validPort hostPort && validPort targetPort) "runtime dependency exposure port is invalid"
        require (generation > 0) "runtime dependency exposure generation is not positive"
    requireExposureField (label, value) = do
        require (not (Text.null value)) ("runtime dependency exposure " <> label <> " is empty")
        require (encodedLength value <= maximumFieldBytes) ("runtime dependency exposure " <> label <> " exceeds its bound")
    exposureFields (service, address, hostPort, target, targetPort, relay, generation, operation) =
        [service, address, Text.pack (show hostPort), target, Text.pack (show targetPort), relay, Text.pack (show generation), operation]

verifyRuntimeDependencyExposureResponse ::
    RuntimeDependencyPackage scope planId ->
    Text ->
    ByteString.ByteString ->
    Either Text [(Text, Text, Int, Text, Int, Text, Word64, Text)]
verifyRuntimeDependencyExposureResponse package expectedNonce raw = do
    requireNonce expectedNonce
    require (ByteString.length raw <= maximumProbeBytes) "runtime dependency exposure response exceeds its canonical bound"
    fields <- parseWireFields raw
    case fields of
        domain : commitment : nonce : exposureFields -> do
            require (domain == "hostbootstrap/runtime-dependency-exposure-response/v1") "runtime dependency exposure response domain mismatch"
            require (commitment == runtimeDependencyPackageCommitment package) "runtime dependency exposure response commitment mismatch"
            require (nonce == expectedNonce) "runtime dependency exposure response nonce mismatch"
            exposures <- parseExposures exposureFields
            canonical <- renderRuntimeDependencyExposureResponse package nonce exposures
            require (canonical == raw) "runtime dependency exposure response is not canonical"
            pure exposures
        _ -> Left "runtime dependency exposure response field count differs"
  where
    parseExposures [] = Right []
    parseExposures (service : address : hostPortText : target : targetPortText : relay : generationText : operation : rest) = do
        hostPort <- parsePositiveInt hostPortText
        targetPort <- parsePositiveInt targetPortText
        generation <- parsePositiveWord generationText
        ((service, address, hostPort, target, targetPort, relay, generation, operation) :) <$> parseExposures rest
    parseExposures _ = Left "runtime dependency exposure response field count differs"

runtimeDependencyChartRequest ::
    RuntimeDependencyPackage scope planId ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Either Text ByteString.ByteString
runtimeDependencyChartRequest package callDigest artifact release namespace image deployment activationRevision values = do
    mapM_ requireChartCoordinate [callDigest, artifact, release, namespace, image, deployment]
    if Text.null activationRevision then Right () else requireChartCoordinate activationRevision
    require (encodedLength values <= maximumChartValuesBytes) "chart values exceed the runtime dependency chart-values bound"
    let wire = wireFields ["hostbootstrap/runtime-dependency-chart/v2", runtimeDependencyPackageCommitment package, callDigest, artifact, release, namespace, image, deployment, activationRevision, values]
    require (ByteString.length wire <= maximumChartRequestBytes) "runtime dependency chart request exceeds its canonical bound"
    pure wire

withRuntimeDependencyChartRequest ::
    RuntimeDependencyPackage scope planId ->
    ByteString.ByteString ->
    (Text -> Text -> Text -> Text -> Text -> Text -> Text -> Text -> result) ->
    Either Text result
withRuntimeDependencyChartRequest package raw use = do
    require (ByteString.length raw <= maximumChartRequestBytes) "runtime dependency chart request exceeds its canonical bound"
    fields <- parseWireFields raw
    case fields of
        [domain, commitment, callDigest, artifact, release, namespace, image, deployment, activationRevision, values] -> do
            require (domain == "hostbootstrap/runtime-dependency-chart/v2") "runtime dependency chart request domain mismatch"
            require (commitment == runtimeDependencyPackageCommitment package) "runtime dependency chart request commitment mismatch"
            canonical <- runtimeDependencyChartRequest package callDigest artifact release namespace image deployment activationRevision values
            require (canonical == raw) "runtime dependency chart request is not canonical"
            pure (use callDigest artifact release namespace image deployment activationRevision values)
        _ -> Left "runtime dependency chart request field count differs"

requireChartCoordinate :: Text -> Either Text ()
requireChartCoordinate value = do
    require (not (Text.null value)) "chart request contains an empty required field"
    require (encodedLength value <= maximumFieldBytes) "chart request coordinate exceeds the runtime dependency field bound"

renderRuntimeDependencyChartResponse :: RuntimeDependencyPackage scope planId -> Text -> Text -> Either Text ByteString.ByteString
renderRuntimeDependencyChartResponse package callDigest outcome = do
    require (outcome `elem` ["created", "repaired", "unchanged"]) "runtime dependency chart outcome is not closed"
    pure (wireFields ["hostbootstrap/runtime-dependency-chart-response/v1", runtimeDependencyPackageCommitment package, callDigest, outcome])

verifyRuntimeDependencyChartResponse :: RuntimeDependencyPackage scope planId -> Text -> ByteString.ByteString -> Either Text Text
verifyRuntimeDependencyChartResponse package callDigest raw = do
    fields <- parseWireFields raw
    case fields of
        [domain, commitment, observedDigest, outcome] -> do
            require (domain == "hostbootstrap/runtime-dependency-chart-response/v1") "runtime dependency chart response domain mismatch"
            require (commitment == runtimeDependencyPackageCommitment package) "runtime dependency chart response commitment mismatch"
            require (observedDigest == callDigest) "runtime dependency chart response call digest mismatch"
            require (outcome `elem` ["created", "repaired", "unchanged"]) "runtime dependency chart response outcome is not closed"
            require (wireFields fields == raw) "runtime dependency chart response is not canonical"
            pure outcome
        _ -> Left "runtime dependency chart response field count differs"

verifyRuntimeDependencyProbeOutcome ::
    RuntimeDependencyPackage scope planId ->
    Text ->
    ByteString.ByteString ->
    Either Text (Either Text Word64)
verifyRuntimeDependencyProbeOutcome package expectedNonce raw = do
    requireNonce expectedNonce
    require (ByteString.length raw <= maximumProbeBytes) "runtime dependency probe response exceeds its canonical bound"
    fields <- parseWireFields raw
    case fields of
        [domain, commitment, nonce, generationText] -> do
            require (commitment == runtimeDependencyPackageCommitment package) "runtime dependency probe response commitment mismatch"
            require (nonce == expectedNonce) "runtime dependency probe response nonce mismatch"
            case domain of
                "hostbootstrap/runtime-dependency-probe-response/v1" -> do
                    generation <- parsePositiveWord generationText
                    require (renderRuntimeDependencyProbeResponse package nonce generation == raw) "runtime dependency probe response is not canonical"
                    pure (Right generation)
                "hostbootstrap/runtime-dependency-probe-refused/v1" -> do
                    require (not (Text.null generationText)) "runtime dependency probe refusal reason is empty"
                    require (encodedLength generationText <= maximumFieldBytes) "runtime dependency probe refusal reason exceeds its bound"
                    canonical <- renderRuntimeDependencyProbeRefusal package nonce generationText
                    require (canonical == raw) "runtime dependency probe refusal is not canonical"
                    pure (Left generationText)
                _ -> Left "runtime dependency probe response domain mismatch"
        _ -> Left "runtime dependency probe response field count differs"

requireNonce :: Text -> Either Text ()
requireNonce nonce = do
    require (not (Text.null nonce)) "runtime dependency probe nonce is empty"
    require (encodedLength nonce <= 128) "runtime dependency probe nonce exceeds its bound"

wireFields :: [Text] -> ByteString.ByteString
wireFields = ByteString.concat . map wireField
  where
    wireField value =
        let bytes = TextEncoding.encodeUtf8 value
         in ByteStringChar8.pack (show (ByteString.length bytes)) <> ":" <> bytes

parseWireFields :: ByteString.ByteString -> Either Text [Text]
parseWireFields raw
    | ByteString.null raw = Right []
    | otherwise = do
        let (sizeBytes, rest) = ByteStringChar8.break (== ':') raw
        require (not (ByteString.null rest)) "runtime dependency probe frame lacks a delimiter"
        size <- case ByteStringChar8.readInteger sizeBytes of
            Just (value, trailing)
                | ByteString.null trailing && value >= 0 && value <= 1048576 -> Right (fromInteger value)
            _ -> Left "runtime dependency probe frame length is not canonical"
        let body = ByteString.drop 1 rest
            (field, trailing) = ByteString.splitAt size body
        require (ByteString.length field == size) "runtime dependency probe frame is truncated"
        decoded <- either (const (Left "runtime dependency probe field is not UTF-8")) Right (TextEncoding.decodeUtf8' field)
        (decoded :) <$> parseWireFields trailing

parsePositiveWord :: Text -> Either Text Word64
parsePositiveWord value =
    case ByteStringChar8.readInteger (TextEncoding.encodeUtf8 value) of
        Just (parsed, trailing)
            | ByteString.null trailing
                && parsed > 0
                && parsed <= fromIntegral (maxBound :: Word64)
                && Text.pack (show parsed) == value ->
                Right (fromInteger parsed)
        _ -> Left "runtime dependency probe generation is not canonical"

parsePositiveInt :: Text -> Either Text Int
parsePositiveInt value = do
    parsed <- parsePositiveWord value
    require (parsed <= fromIntegral (maxBound :: Int)) "runtime dependency exposure port exceeds Int"
    pure (fromIntegral parsed)

domainOf :: RuntimeDependencyPackage scope planId -> Text
domainOf package = case package of
    ProviderRuntimeDependencyPackage{} -> "provider"
    ProviderShareRuntimeDependencyPackage{} -> "provider-share"
    ClusterRuntimeDependencyPackage{} -> "cluster"

planOf, scopeOf, resourceOf, frameOf, originOf, journalOf, receiptOf :: RuntimeDependencyPackage scope planId -> Text
planOf package = case package of
    ProviderRuntimeDependencyPackage value _ _ _ _ _ _ _ _ _ -> value
    ProviderShareRuntimeDependencyPackage value _ _ _ _ _ _ _ _ _ -> value
    ClusterRuntimeDependencyPackage value _ _ _ _ _ _ _ _ _ -> value
scopeOf package = case package of
    ProviderRuntimeDependencyPackage _ value _ _ _ _ _ _ _ _ -> value
    ProviderShareRuntimeDependencyPackage _ value _ _ _ _ _ _ _ _ -> value
    ClusterRuntimeDependencyPackage _ value _ _ _ _ _ _ _ _ -> value
resourceOf package = case package of
    ProviderRuntimeDependencyPackage _ _ value _ _ _ _ _ _ _ -> value
    ProviderShareRuntimeDependencyPackage _ _ value _ _ _ _ _ _ _ -> value
    ClusterRuntimeDependencyPackage _ _ value _ _ _ _ _ _ _ -> value
frameOf package = case package of
    ProviderRuntimeDependencyPackage _ _ _ value _ _ _ _ _ _ -> value
    ProviderShareRuntimeDependencyPackage _ _ _ value _ _ _ _ _ _ -> value
    ClusterRuntimeDependencyPackage _ _ _ value _ _ _ _ _ _ -> value
originOf package = case package of
    ProviderRuntimeDependencyPackage _ _ _ _ value _ _ _ _ _ -> value
    ProviderShareRuntimeDependencyPackage _ _ _ _ value _ _ _ _ _ -> value
    ClusterRuntimeDependencyPackage _ _ _ _ value _ _ _ _ _ -> value
journalOf package = case package of
    ProviderRuntimeDependencyPackage _ _ _ _ _ _ value _ _ _ -> value
    ProviderShareRuntimeDependencyPackage _ _ _ _ _ _ value _ _ _ -> value
    ClusterRuntimeDependencyPackage _ _ _ _ _ _ value _ _ _ -> value
receiptOf package = case package of
    ProviderRuntimeDependencyPackage _ _ _ _ _ _ _ value _ _ -> value
    ProviderShareRuntimeDependencyPackage _ _ _ _ _ _ _ value _ _ -> value
    ClusterRuntimeDependencyPackage _ _ _ _ _ _ _ value _ _ -> value

generationOf, expiryOf :: RuntimeDependencyPackage scope planId -> Word64
generationOf package = case package of
    ProviderRuntimeDependencyPackage _ _ _ _ _ value _ _ _ _ -> value
    ProviderShareRuntimeDependencyPackage _ _ _ _ _ value _ _ _ _ -> value
    ClusterRuntimeDependencyPackage _ _ _ _ _ value _ _ _ _ -> value
expiryOf package = case package of
    ProviderRuntimeDependencyPackage _ _ _ _ _ _ _ _ _ value -> value
    ProviderShareRuntimeDependencyPackage _ _ _ _ _ _ _ _ _ value -> value
    ClusterRuntimeDependencyPackage _ _ _ _ _ _ _ _ _ value -> value

frameText :: Text -> Text
frameText value = Text.pack (show (encodedLength value)) <> ":" <> value

encodedLength :: Text -> Int
encodedLength = ByteString.length . TextEncoding.encodeUtf8

maximumFieldBytes, maximumRouteBytes :: Int
maximumFieldBytes = 4096
maximumRouteBytes = 512

maximumPackageBytes, maximumProbeBytes :: Int
maximumPackageBytes = 64 * 1024
maximumProbeBytes = 128 * 1024

maximumBundleBytes, maximumBundlePackages :: Int
maximumBundleBytes = 512 * 1024
maximumBundlePackages = 16

maximumChartValuesBytes, maximumChartRequestBytes :: Int
maximumChartValuesBytes = 64 * 1024
maximumChartRequestBytes = 256 * 1024

validPort :: Int -> Bool
validPort port = port > 0 && port < 65536

distinct :: (Eq value) => [value] -> Bool
distinct values = length values == length (unique values)
  where
    unique [] = []
    unique (value : rest) = value : unique (filter (/= value) rest)

require :: Bool -> Text -> Either Text ()
require True _ = Right ()
require False failure = Left failure
