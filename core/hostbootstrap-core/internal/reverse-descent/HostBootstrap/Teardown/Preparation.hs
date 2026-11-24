{-# LANGUAGE OverloadedStrings #-}

-- | Pure admission of the scalar facts retained by a prepared reverse descent.
module HostBootstrap.Teardown.Preparation (
    PreparationFacts (..),
    validatePreparation,
    classifyPreparedRecord,
    validateRecoveryOfferScope,
    renderReverseAdapterKernel,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Bits (shiftR)
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)

{- | The one canonical reverse adapter: the child plan digest, the parent and
child frames, the reverse verb's name, the child's exact outstanding operations
in order, and the closed outcome set. The root producer and the child verifier
both render it here, so the two cannot drift.
-}
renderReverseAdapterKernel :: Text -> Text -> Text -> Text -> [Text] -> ByteString
renderReverseAdapterKernel planDigest verbName parent child expected =
    ByteString.concat
        ( [ adapterText "hostbootstrap/reverse-descent-adapter"
          , adapterWord 1
          , adapterText planDigest
          , adapterText parent
          , adapterText child
          , adapterText verbName
          , adapterText "teardown"
          , adapterWord (fromIntegral (length expected))
          ]
            ++ map adapterText expected
            ++ [adapterWord 3, adapterText "released", adapterText "foreign-retained", adapterText "refused"]
        )
  where
    adapterText :: Text -> ByteString
    adapterText = adapterFrame . TextEncoding.encodeUtf8
    adapterWord :: Word64 -> ByteString
    adapterWord = adapterFrame . bigEndian
    -- The same eight-byte big-endian length prefix as the shared wire framing.
    adapterFrame :: ByteString -> ByteString
    adapterFrame payload = bigEndian (fromIntegral (ByteString.length payload)) <> payload
    bigEndian :: Word64 -> ByteString
    bigEndian value = ByteString.pack [fromIntegral (value `shiftR` offset) | offset <- [56, 48, 40, 32, 24, 16, 8, 0 :: Int]]

data PreparationFacts = PreparationFacts
    { preparationVerb :: Text
    , preparationRootVerb :: Text
    , preparationJournalVerb :: Text
    , preparationCursorVerb :: Text
    , preparationCommandVerb :: Text
    , preparationCursorPhase :: Text
    , preparationCommandPhase :: Text
    , preparationProject :: Text
    , preparationRootProject :: Text
    , preparationStore :: Text
    , preparationRootStore :: Text
    , preparationPlanStore :: Text
    , preparationPlanScope :: Text
    , preparationJournalScope :: Text
    , preparationPlanDigest :: Text
    , preparationJournalDigest :: Text
    , preparationCanonicalPlan :: ByteString
    , preparationRootEpoch :: Word64
    , preparationJournalEpoch :: Word64
    , preparationPlanEpoch :: Word64
    , preparationCommandEpoch :: Word64
    , preparationCurrentFrame :: Text
    , preparationProjectFrame :: Text
    , preparationCursorFrame :: Text
    , preparationCommandFrame :: Text
    , preparationChildProjectionFrame :: Text
    , preparationChildProjectionVerb :: Text
    , preparationParent :: Text
    , preparationChild :: Text
    , preparationTopologyFrames :: [Text]
    , preparationTopologyEdges :: [(Text, Text)]
    , preparationCursorMatchesCommand :: Bool
    , preparationCommandMatchesStore :: Bool
    , preparationRun :: Text
    , preparationInvocation :: Text
    , preparationAcquisitionVersion :: Word64
    , preparationCursorVersion :: Word64
    , preparationObservations :: [Text]
    , preparationAdapter :: ByteString
    , preparationChildConfig :: ByteString
    , preparationConfigDigest :: Text
    , preparationActualConfigDigest :: Text
    , preparationPackage :: ByteString
    , preparationRenderedPackage :: ByteString
    , preparationPackageDigest :: Text
    , preparationRecord :: ByteString
    , preparationWireBound :: Word64
    }

-- | Refuse the first invalid fact in the same order as the preparation protocol.
validatePreparation :: PreparationFacts -> Either Text ()
validatePreparation f = do
    require "the verb and lifecycle phase cannot prepare cleanup descent" $
        case preparationVerb f of
            "up" -> preparationCommandPhase f == "execute"
            "down" -> preparationCommandPhase f == "teardown"
            "destroy" -> preparationCommandPhase f == "teardown"
            _ -> False
    require "the root verb differs" (preparationVerb f == preparationRootVerb f)
    require "the journal verb differs" (preparationVerb f == preparationJournalVerb f)
    require "the cursor verb differs" (preparationVerb f == preparationCursorVerb f)
    require "the command verb differs" (preparationVerb f == preparationCommandVerb f)
    require "the cursor and command phases differ" (preparationCursorPhase f == preparationCommandPhase f)
    require "the project identity differs" (preparationProject f == preparationRootProject f)
    require "the protected store differs" (preparationStore f == preparationRootStore f)
    require "the plan store differs" (preparationPlanStore f == preparationStore f)
    require "the plan scope differs" (preparationPlanScope f == preparationJournalScope f)
    require "the plan digest differs" (preparationPlanDigest f == preparationJournalDigest f)
    require "the canonical plan is empty" (not (ByteString.null (preparationCanonicalPlan f)))
    require "the broker generation differs" (preparationRootEpoch f == preparationJournalEpoch f)
    require "the plan broker generation differs" (preparationRootEpoch f == preparationPlanEpoch f)
    require "the command broker generation differs" (preparationRootEpoch f == preparationCommandEpoch f)
    require "the context current frame differs from its project frame" (preparationCurrentFrame f == preparationProjectFrame f)
    require "the cursor frame differs from the root context" (preparationCursorFrame f == preparationCurrentFrame f)
    require "the command frame differs from the root context" (preparationCommandFrame f == preparationCurrentFrame f)
    require "the child projection opening frame differs" (preparationChildProjectionFrame f == preparationChild f)
    require "the child projection verb differs" (preparationChildProjectionVerb f == preparationVerb f)
    require "the parent and child frames are equal" (preparationParent f /= preparationChild f)
    require "the parent frame is outside the plan" (preparationParent f `elem` preparationTopologyFrames f)
    require "the child frame is outside the plan" (preparationChild f `elem` preparationTopologyFrames f)
    require "the descent is not the exact immediate topology edge" $
        [edge | edge@(_, child) <- preparationTopologyEdges f, child == preparationChild f]
            == [(preparationParent f, preparationChild f)]
    require "the cursor and command origins differ" (preparationCursorMatchesCommand f)
    require "the command belongs to a different store" (preparationCommandMatchesStore f)
    require "the acquisition run is empty" (not (Text.null (preparationRun f)))
    require "the command invocation is empty" (not (Text.null (preparationInvocation f)))
    require "the acquisition version is invalid" (preparationAcquisitionVersion f > 0)
    require "the cursor version is invalid" (preparationCursorVersion f > 0)
    require "the child observation order is empty" (not (null (preparationObservations f)))
    require "the child observation order contains duplicates" (length (preparationObservations f) == length (nub (preparationObservations f)))
    require "the recovery adapter is empty" (not (ByteString.null (preparationAdapter f)))
    require "the recovery adapter exceeds the handoff bound" (withinBound (preparationAdapter f))
    require "the catalog child configuration is empty" (not (ByteString.null (preparationChildConfig f)))
    require "the catalog child configuration digest differs" (preparationConfigDigest f == preparationActualConfigDigest f)
    require "the recovery package does not carry the exact catalog child configuration and adapter" (preparationPackage f == preparationRenderedPackage f)
    require "the recovery package exceeds the handoff bound" (withinBound (preparationPackage f))
    require "the recovery package and child configuration digests are conflated" (preparationPackageDigest f /= preparationConfigDigest f)
    require "the prepared record exceeds the handoff bound" (withinBound (preparationRecord f))
  where
    require _ True = Right ()
    require detail False = Left detail
    withinBound bytes = fromIntegral (ByteString.length bytes) <= preparationWireBound f

-- | Classify the protected row after the kernel has decoded any bound form.
classifyPreparedRecord :: ByteString -> Word64 -> ByteString -> Maybe ByteString -> Either Text ()
classifyPreparedRecord expected version actual bound
    | version == 1 && actual == expected = Right ()
    | version >= 2, Just _ <- bound = Right ()
    | otherwise = Left "a conflicting prepared record exists"

-- | Compare the lifecycle scope with the canonical signed handoff spelling.
validateRecoveryOfferScope :: Text -> (Text -> Text) -> Text -> Text -> Either Text ()
validateRecoveryOfferScope productionTag harnessTag stableScope offeredScope =
    if expected == Just offeredScope
        then Right ()
        else Left "the recovery offer scope differs"
  where
    expected
        | stableScope == "production" = Just productionTag
        | Just run <- Text.stripPrefix "harness:" stableScope = Just (harnessTag run)
        | otherwise = Nothing
