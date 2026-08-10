{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module DhallGenSpec (tests) where

import Control.Exception (SomeException, try)
import Control.Monad (void)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import qualified Dhall
import qualified Dhall.Core
import qualified Dhall.Map
import Dhall.Marshal.Decode (Decoder)
import Dhall.Marshal.Encode (Encoder (declared))
import Dhall.Parser (Src)
import qualified Dhall.TypeCheck
import Fixture (withFixtureHarnessAuthority)
import HostBootstrap.Config.Schema (writeProjectConfigFile)
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Dhall.Gen (
    CodecWitness,
    CodecWitnessError (CodecTypeMismatch),
    artifactOf,
    autoCodecWitness,
    codecSchemaText,
    coreArtifacts,
    decodeText,
    deployConfigText,
    mkCodecWitness,
    renderText,
    renderValue,
    requireCodecWitness,
    schemaText,
    schemaUnion,
 )
import HostBootstrap.DocValidator (findRepoRoot)
import System.Directory (doesPathExist, getCurrentDirectory)
import System.FilePath (makeRelative, normalise, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | A relative @Core.dhall@ import, rendered with Dhall's portable '/' separators.
corePath :: FilePath -> IO Text
corePath root = do
    cwd <- getCurrentDirectory
    let rel = makeRelative cwd (root </> "core" </> "hostbootstrap-core" </> "dhall" </> "Core.dhall")
        slashy = map (\c -> if c == '\\' then '/' else c) (normalise rel)
        importPath =
            if "." `T.isPrefixOf` T.pack slashy
                then slashy
                else "./" ++ slashy
    pure (T.pack importPath)

withRoot :: (FilePath -> IO ()) -> IO ()
withRoot k = do
    cwd <- getCurrentDirectory
    mroot <- findRepoRoot cwd
    maybe (assertFailure ("could not locate repo root from " ++ cwd)) k mroot

codec :: forall a. (Dhall.FromDhall a, Dhall.ToDhall a) => CodecWitness a
codec =
    requireCodecWitness "DhallGenSpec" (autoCodecWitness @a)

tests :: TestTree
tests =
    testGroup
        "DhallGenSpec"
        [ testGroup "codec witness" codecCases
        , testGroup "Core.dhall vocabulary coverage" vocabularyCases
        , testGroup "Core.dhall budget helpers" budgetCases
        , testGroup "witness-driven registry" registryCases
        , testGroup "config render round-trip + budget assert" renderCases
        , testGroup "SecretRef round-trip" secretRefCases
        ]

codecCases :: [TestTree]
codecCases =
    [ testCase "a mismatched decoder/encoder pair is rejected before decode or side effects" $
        withSystemTempDirectory "hostbootstrap-codec-mismatch" $ \dir -> do
            sideEffectRan <- newIORef False
            let path = dir </> "must-not-exist.dhall"
                textEncoder = Dhall.inject :: Encoder Text
                mismatchedEncoder = textEncoder{declared = Dhall.Core.Natural}
                admission =
                    mkCodecWitness
                        (Dhall.auto :: Decoder Text)
                        mismatchedEncoder
                invalidCodec =
                    requireCodecWitness "mismatched fixture" admission
            case admission of
                Left CodecTypeMismatch{} -> pure ()
                Left other -> assertFailure ("expected CodecTypeMismatch, got " ++ show other)
                Right _ -> assertFailure "the mismatched fixture unexpectedly constructed CodecWitness"
            result <-
                try
                    ( writeProjectConfigFile invalidCodec path "must not render"
                        >> writeIORef sideEffectRan True
                    ) ::
                    IO (Either SomeException ())
            assertBool "requiring the rejected witness fails" (either (const True) (const False) result)
            doesPathExist path >>= (@?= False)
            readIORef sideEffectRan >>= (@?= False)
    , testCase "a matching pair yields the schema used by rendering and decoding" $ do
        let budgetCodec = codec @V.Budget
            value = V.Budget 4 8 20
            rendered = renderValue budgetCodec value
        decoded <- decodeText budgetCodec (rendered <> " : " <> codecSchemaText budgetCodec)
        decoded @?= value
    ]

{- | Every type-valued field exported by @Core.dhall@, paired with the schema of
its admitted Haskell codec. The inventory test below derives the Core side
automatically, so adding or removing an exported type cannot silently leave
this list stale.
-}
coreTypeCoverage :: [(Text, Text)]
coreTypeCoverage =
    [ ("Resources", codecSchemaText (codec @V.Resources))
    , ("Budget", codecSchemaText (codec @V.Budget))
    , ("PodResources", codecSchemaText (codec @V.PodResources))
    , ("KindNode", codecSchemaText (codec @V.KindNode))
    , ("Mount", codecSchemaText (codec @V.Mount))
    , ("Substrate", codecSchemaText (codec @V.Substrate))
    , ("ClusterProfile", codecSchemaText (codec @V.ClusterProfile))
    , ("ProductionSecretRef", codecSchemaText (codec @V.ProductionSecretRefWire))
    , ("HarnessSecretRef", codecSchemaText (codec @V.HarnessSecretRefWire))
    , ("Weight", codecSchemaText (codec @V.Weight))
    ]

coreTypeExports :: Dhall.Core.Expr Src Void -> Either String [(Text, Dhall.Core.Expr Src Void)]
coreTypeExports expression =
    case Dhall.Core.normalize expression of
        Dhall.Core.RecordLit fields ->
            Right
                [ (name, value)
                | (name, field) <- Dhall.Map.toList fields
                , let value = Dhall.Core.recordFieldValue field
                , isTypeValue value
                ]
        other ->
            Left ("Core.dhall did not normalize to a record: " ++ T.unpack (Dhall.Core.pretty other))
  where
    isTypeValue value =
        case Dhall.TypeCheck.typeOf value of
            Right (Dhall.Core.Const Dhall.Core.Type) -> True
            _ -> False

vocabularyCases :: [TestTree]
vocabularyCases =
    [ testCase "every type exported by Core.dhall has one exhaustive codec entry" $ withRoot $ \root -> do
        cp <- corePath root
        core <- Dhall.inputExpr cp
        exports <- either assertFailure pure (coreTypeExports core)
        sort (map fst exports) @?= sort (map fst coreTypeCoverage)
    , testCase "every admitted vocabulary codec is judgmentally equal to its Core.dhall type" $ withRoot $ \root -> do
        cp <- corePath root
        core <- Dhall.inputExpr cp
        exports <- either assertFailure pure (coreTypeExports core)
        mapM_ (assertCovered exports) coreTypeCoverage
    , testCase "representative vocabulary values round-trip through admitted codecs" $ do
        roundTrip (codec @V.Resources) (V.Resources 4 "8GiB" "20GiB")
        roundTrip (codec @V.Budget) (V.Budget 4 8 20)
        roundTrip (codec @V.PodResources) (V.PodResources 2 1 2 3 4)
        roundTrip (codec @V.KindNode) (V.KindNode 4 8 20)
        roundTrip (codec @V.Mount) (V.Mount "/host" "/guest" True)
        roundTrip (codec @V.Substrate) V.LinuxGpu
        roundTrip (codec @V.ClusterProfile) (V.Test "smoke")
        roundTrip (codec @V.ProductionSecretRefWire) (V.ProductionPrompt "database password")
        roundTrip (codec @V.HarnessSecretRefWire) (V.HarnessTestPlaintext "fixture")
        roundTrip (codec @V.Weight) (V.Weight 3)
    ]
  where
    assertCovered exports (name, schema) = do
        reflected <- Dhall.inputExpr schema
        case lookup name exports of
            Nothing -> assertFailure ("Core.dhall has no type export named " ++ T.unpack name)
            Just coreType ->
                assertBool
                    ( "codec for "
                        ++ T.unpack name
                        ++ " differs from Core.dhall\ncodec: "
                        ++ T.unpack (Dhall.Core.pretty (Dhall.Core.normalize reflected))
                        ++ "\ncore: "
                        ++ T.unpack (Dhall.Core.pretty (Dhall.Core.normalize coreType))
                    )
                    (Dhall.Core.judgmentallyEqual reflected coreType)
    roundTrip :: (Eq a, Show a) => CodecWitness a -> a -> IO ()
    roundTrip admitted value = do
        decoded <- decodeText admitted (renderValue admitted value)
        decoded @?= value

registryCases :: [TestTree]
registryCases =
    [ testCase "an artifact's schema and rendering come from the same witness" $ do
        let budgetCodec = codec @V.Budget
            value = V.Budget 7 11 13
            generated = artifactOf "witnessBudget" budgetCodec value
        schemaText generated @?= codecSchemaText budgetCodec
        renderText generated @?= renderValue budgetCodec value
        decoded <- decodeText budgetCodec (renderText generated <> " : " <> schemaText generated)
        decoded @?= value
    , testCase "schemaUnion lists every in-scope artifact" $ do
        let unionText = schemaUnion coreArtifacts
        mapM_
            (\name -> assertBool ("union names " ++ T.unpack name) (name `T.isInfixOf` unionText))
            ["budget", "podResources", "kindNode"]
        assertBool "union carries reflected Natural fields" ("Natural" `T.isInfixOf` unionText)
    ]

renderCases :: [TestTree]
renderCases =
    [ testCase "render -> decode -> re-render is byte-identical" $ do
        let admitted = codec @V.KindNode
            rendered = renderValue admitted (V.KindNode 4 8 20)
        value <- decodeText admitted rendered
        value @?= V.KindNode 4 8 20
        renderValue admitted value @?= rendered
    , testCase "an in-budget deploy config type-checks (carries the fitsWithin assert)" $ withRoot $ \root -> do
        cp <- corePath root
        let okText = deployConfigText cp (V.Budget 4 8 20) [V.PodResources 2 1 1 1 2]
        _ <- Dhall.inputExpr okText
        pure ()
    , testCase "an over-budget deploy config fails to type-check (the assert fires)" $ withRoot $ \root -> do
        cp <- corePath root
        let badText = deployConfigText cp (V.Budget 2 4 20) [V.PodResources 3 1 2 1 2]
        result <- try (void (Dhall.inputExpr badText)) :: IO (Either SomeException ())
        assertBool "over-budget deploy is rejected" (either (const True) (const False) result)
    ]

secretRefCases :: [TestTree]
secretRefCases =
    [ testCase "production and harness wire alternatives round-trip separately" $ do
        let production = codec @V.ProductionSecretRefWire
            harness = codec @V.HarnessSecretRefWire
        mapM_
            (roundTrip production)
            [ V.ProductionVault (V.VaultRef "secret" "app/db" "password")
            , V.ProductionTransitKey "app-signing-key"
            , V.ProductionPrompt "database password"
            ]
        mapM_
            (roundTrip harness)
            [ V.HarnessVault (V.VaultRef "secret" "app/db" "password")
            , V.HarnessTransitKey "app-signing-key"
            , V.HarnessPrompt "database password"
            , V.HarnessTestPlaintext "hunter2"
            ]
    , testCase "production schema omits and rejects TestPlaintext" $ do
        let production = codec @V.ProductionSecretRefWire
        assertBool "production schema has no plaintext constructor" (not ("TestPlaintext" `T.isInfixOf` codecSchemaText production))
        result <-
            try
                (decodeText production "< TestPlaintext = \"hunter2\" >") ::
                IO (Either SomeException V.ProductionSecretRefWire)
        assertBool "production decode rejects plaintext" (either (const True) (const False) result)
    , testCase "scoped plaintext requires matching rank-2 harness authority" $ do
        withFixtureHarnessAuthority
            $ \_project runAuthority ->
                V.secretRefView
                    ( V.testPlaintextSecret
                        (V.harnessConfigAuthority runAuthority)
                        (V.TestSecret "hunter2")
                    )
                    @?= V.SecretTestPlaintext (V.TestSecret "hunter2")
    , testCase "production wire decodes against Core.dhall's production type" $ withRoot $ \root -> do
        let admitted = codec @V.ProductionSecretRefWire
            value = V.ProductionVault (V.VaultRef "secret" "app/db" "password")
        cp <- corePath root
        decoded <-
            decodeText
                admitted
                (renderValue admitted value <> " : (" <> cp <> ").ProductionSecretRef")
        decoded @?= value
    , testCase "wire conversion preserves scope and pointer values" $ do
        let production = V.productionSecretRef (V.ProductionPrompt "password")
        V.productionSecretRefWire production @?= V.ProductionPrompt "password"
        withFixtureHarnessAuthority
            $ \_project runAuthority -> do
                let authority = V.harnessConfigAuthority runAuthority
                    harness = V.harnessSecretRef authority (V.HarnessTestPlaintext "fixture")
                assertBool
                    "the authority carries a generative run name"
                    ("run-" `T.isPrefixOf` V.harnessRunName runAuthority)
                V.harnessSecretRefWire harness @?= V.HarnessTestPlaintext "fixture"
    ]
  where
    roundTrip admitted value = do
        decoded <- decodeText admitted (renderValue admitted value)
        decoded @?= value

budgetCases :: [TestTree]
budgetCases =
    [ testCase "Budget/fitsWithin accepts an under-budget pod set" $ withRoot $ \root -> do
        cp <- corePath root
        ok <-
            Dhall.input
                Dhall.bool
                ( "let C = "
                    <> cp
                    <> " in C.fitsWithin { cpu = 4, memory = 8, storage = 20 }"
                    <> " [ { replicas = 2, cpuRequest = 1, cpuLimit = 1, memoryRequest = 1, memoryLimit = 2 } ]"
                )
        ok @?= True
    , testCase "Budget/fitsWithin rejects an over-budget pod set" $ withRoot $ \root -> do
        cp <- corePath root
        ok <-
            Dhall.input
                Dhall.bool
                ( "let C = "
                    <> cp
                    <> " in C.fitsWithin { cpu = 2, memory = 4, storage = 20 }"
                    <> " [ { replicas = 3, cpuRequest = 1, cpuLimit = 2, memoryRequest = 1, memoryLimit = 4 } ]"
                )
        ok @?= False
    , testCase "Budget/split divides proportionally by weight (floor)" $ withRoot $ \root -> do
        cp <- corePath root
        parts <-
            Dhall.input
                (Dhall.list Dhall.auto)
                ("let C = " <> cp <> " in C.split { cpu = 10, memory = 20, storage = 40 } [ 1, 1 ]") ::
                IO [V.Budget]
        parts @?= [V.Budget 5 10 20, V.Budget 5 10 20]
    , testCase "Budget/split floors uneven weights and stays within budget" $ withRoot $ \root -> do
        cp <- corePath root
        parts <-
            Dhall.input
                (Dhall.list Dhall.auto)
                ("let C = " <> cp <> " in C.split { cpu = 7, memory = 7, storage = 7 } [ 1, 2 ]") ::
                IO [V.Budget]
        parts @?= [V.Budget 2 2 2, V.Budget 4 4 4]
    ]
