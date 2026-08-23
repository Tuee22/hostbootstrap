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
    withProviderRuntimeDependencyPackage,
    withProviderRuntimeDependencyCoordinates,
    withCarriedProviderRuntimeDependencyCoordinates,
    withClusterRuntimeDependencyPackage,
    withClusterRuntimeDependencyCoordinates,
    withClusterRuntimeDependencySuccessor,
    runtimeDependencyProbeRequest,
    withRuntimeDependencyProbeRequest,
    renderRuntimeDependencyProbeResponse,
    renderRuntimeDependencyProbeRefusal,
    verifyRuntimeDependencyProbeOutcome,
    verifyRuntimeDependencyProbeResponse,
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
    | ClusterRuntimeDependencyPackage Text Text Text Text Text Word64 Text Text Text Word64
    deriving (Eq, Show)

type role RuntimeDependencyPackage nominal nominal

mkProviderRuntimeDependencyPackage ::
    Text -> Text -> Text -> Text -> Text -> Word64 -> Text -> Text -> Text -> Word64 -> Either Text (RuntimeDependencyPackage scope planId)
mkProviderRuntimeDependencyPackage = makePackage "provider" ProviderRuntimeDependencyPackage

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
                "cluster" -> mkClusterRuntimeDependencyPackage plan scope resource frame origin generation journal receipt route expiry
                _ -> Left "runtime dependency package domain is unknown"
        _ -> Left "runtime dependency package field count differs"
    require (runtimeDependencyPackageWire package == raw) "runtime dependency package is not canonical"
    pure package

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

runtimeDependencyChartRequest ::
    RuntimeDependencyPackage scope planId ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Either Text ByteString.ByteString
runtimeDependencyChartRequest package callDigest artifact release namespace image deployment values = do
    require (all (not . Text.null) [callDigest, artifact, release, namespace, image, deployment]) "chart request contains an empty required field"
    require (encodedLength values <= maximumFieldBytes) "chart values exceed the runtime dependency field bound"
    pure (wireFields ["hostbootstrap/runtime-dependency-chart/v1", runtimeDependencyPackageCommitment package, callDigest, artifact, release, namespace, image, deployment, values])

withRuntimeDependencyChartRequest ::
    RuntimeDependencyPackage scope planId ->
    ByteString.ByteString ->
    (Text -> Text -> Text -> Text -> Text -> Text -> Text -> result) ->
    Either Text result
withRuntimeDependencyChartRequest package raw use = do
    fields <- parseWireFields raw
    case fields of
        [domain, commitment, callDigest, artifact, release, namespace, image, deployment, values] -> do
            require (domain == "hostbootstrap/runtime-dependency-chart/v1") "runtime dependency chart request domain mismatch"
            require (commitment == runtimeDependencyPackageCommitment package) "runtime dependency chart request commitment mismatch"
            require (wireFields fields == raw) "runtime dependency chart request is not canonical"
            pure (use callDigest artifact release namespace image deployment values)
        _ -> Left "runtime dependency chart request field count differs"

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

domainOf :: RuntimeDependencyPackage scope planId -> Text
domainOf package = case package of
    ProviderRuntimeDependencyPackage{} -> "provider"
    ClusterRuntimeDependencyPackage{} -> "cluster"

planOf, scopeOf, resourceOf, frameOf, originOf, journalOf, receiptOf :: RuntimeDependencyPackage scope planId -> Text
planOf package = case package of
    ProviderRuntimeDependencyPackage value _ _ _ _ _ _ _ _ _ -> value
    ClusterRuntimeDependencyPackage value _ _ _ _ _ _ _ _ _ -> value
scopeOf package = case package of
    ProviderRuntimeDependencyPackage _ value _ _ _ _ _ _ _ _ -> value
    ClusterRuntimeDependencyPackage _ value _ _ _ _ _ _ _ _ -> value
resourceOf package = case package of
    ProviderRuntimeDependencyPackage _ _ value _ _ _ _ _ _ _ -> value
    ClusterRuntimeDependencyPackage _ _ value _ _ _ _ _ _ _ -> value
frameOf package = case package of
    ProviderRuntimeDependencyPackage _ _ _ value _ _ _ _ _ _ -> value
    ClusterRuntimeDependencyPackage _ _ _ value _ _ _ _ _ _ -> value
originOf package = case package of
    ProviderRuntimeDependencyPackage _ _ _ _ value _ _ _ _ _ -> value
    ClusterRuntimeDependencyPackage _ _ _ _ value _ _ _ _ _ -> value
journalOf package = case package of
    ProviderRuntimeDependencyPackage _ _ _ _ _ _ value _ _ _ -> value
    ClusterRuntimeDependencyPackage _ _ _ _ _ _ value _ _ _ -> value
receiptOf package = case package of
    ProviderRuntimeDependencyPackage _ _ _ _ _ _ _ value _ _ -> value
    ClusterRuntimeDependencyPackage _ _ _ _ _ _ _ value _ _ -> value

generationOf, expiryOf :: RuntimeDependencyPackage scope planId -> Word64
generationOf package = case package of
    ProviderRuntimeDependencyPackage _ _ _ _ _ value _ _ _ _ -> value
    ClusterRuntimeDependencyPackage _ _ _ _ _ value _ _ _ _ -> value
expiryOf package = case package of
    ProviderRuntimeDependencyPackage _ _ _ _ _ _ _ _ _ value -> value
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

require :: Bool -> Text -> Either Text ()
require True _ = Right ()
require False failure = Left failure
