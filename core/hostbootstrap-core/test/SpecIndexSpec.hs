-- | Boundary guards for the two carriers that retain a specification index.
--
-- The installed project codec and the jointly finalized service registry each
-- keep a nominal @specDigest@ phantom, so a value admitted under a durably
-- recovered index and one finalized in this invocation are distinct types even
-- when their digests are equal.  Relabelling either one therefore needs its
-- hidden constructor, and both hidden owners accept exactly one authority: the
-- digest-equality token minted by 'HostBootstrap.Config.Schema.Internal'.
--
-- Neither kernel has a public facade, so these are exact source and Cabal
-- placement guards.  The behavioural join — reindex on equal digests, refusal
-- on unequal digests, preservation of every retained term — is reached through
-- the recovered finalized specification the next sprint threads into both root
-- @project up@ entries.
module SpecIndexSpec (tests) where

import Data.Char (isSpace)
import Data.List (isPrefixOf, isInfixOf, sort, stripPrefix)
import HostBootstrap.DocValidator (findRepoRoot)
import qualified SourceGuard
import System.Directory (
    doesDirectoryExist,
    getCurrentDirectory,
    listDirectory,
 )
import System.FilePath (
    takeExtension,
    (</>),
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "specification-index carriers"
        [ testCase "the installed project codec keeps one hidden owner and one relabelling authority" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                let ownerPath =
                        sourceRoot </> "HostBootstrap" </> "Config" </> "Class" </> "Internal.hs"
                ownerSource <- readFile ownerPath
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                librarySource <- requiredMainLibraryStanza cabalSource
                sources <- readProductionSources sourceRoot
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                ownerExports <-
                    requiredModuleExports "HostBootstrap.Config.Class.Internal" ownerSource
                let owner = normalizeWhitespace ownerSource
                exportedNames ownerExports
                    @?= ["ProjectCodec", "reindexProjectCodecKernel"]
                assertHiddenModule
                    "HostBootstrap.Config.Class.Internal"
                    cabalSource
                    librarySource
                importersOf "HostBootstrap.Config.Class.Internal" sources
                    @?= [ "HostBootstrap.Config.Class"
                        , "HostBootstrap.ProjectPlan.Construct.Internal"
                        ]
                sort (SourceGuard.haskellImports ownerSource)
                    @?= sort
                        [ "Data.Text"
                        , "Dhall"
                        , "HostBootstrap.Config.Schema.Internal"
                        , "HostBootstrap.Dhall.Hoist"
                        ]
                SourceGuard.countHaskellTokenSequence ["data", "ProjectCodec"] ownerSource @?= 1
                SourceGuard.countHaskellIdentifier "data" ownerSource @?= 1
                SourceGuard.countHaskellIdentifier "newtype" ownerSource @?= 0
                assertContains
                    "the installed codec keeps three nominal authorities"
                    "type role ProjectCodec nominal nominal nominal"
                    owner
                assertContains
                    "the reindex kernel consumes the digest-equality token and relabels one index"
                    ( "reindexProjectCodecKernel :: RecoverySpecReindex targetSpecDigest"
                        <> " -> ProjectCodec scope sourceSpecDigest cfg"
                        <> " -> Either (Text, Text) (ProjectCodec scope targetSpecDigest cfg)"
                    )
                    owner
                assertFragmentsInOrder
                    "equality precedes relabelling, every retained term is preserved, and inequality refuses"
                    [ "reindexProjectCodecKernel token codec | expected == observed = Right ProjectCodec"
                    , "installedCodecLabel = installedCodecLabel codec"
                    , "installedCodecSchema = installedCodecSchema codec"
                    , "installedCodecSpecDigest = installedCodecSpecDigest codec"
                    , "installedCodecDecodeFile = installedCodecDecodeFile codec"
                    , "installedCodecDecodeWithSettings = installedCodecDecodeWithSettings codec"
                    , "installedCodecRender = installedCodecRender codec"
                    , "installedCodecRenderHoisted = installedCodecRenderHoisted codec"
                    , "| otherwise = Left (expected, observed)"
                    , "expected = recoverySpecReindexDigestKernel token"
                    , "observed = installedCodecSpecDigest codec"
                    ]
                    owner
                assertSoleTokenAuthority ownerSource
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "reindexProjectCodecKernel"
                    , "installedCodecLabel"
                    , "installedCodecSchema"
                    , "installedCodecSpecDigest"
                    , "installedCodecDecodeFile"
                    , "installedCodecDecodeWithSettings"
                    , "installedCodecRender"
                    , "installedCodecRenderHoisted"
                    ]
                assertInertOwner ownerSource
        , testCase "the finalized service registry keeps one hidden owner and one relabelling authority" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                let ownerPath =
                        sourceRoot </> "HostBootstrap" </> "Service" </> "Internal.hs"
                ownerSource <- readFile ownerPath
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                librarySource <- requiredMainLibraryStanza cabalSource
                sources <- readProductionSources sourceRoot
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                ownerExports <-
                    requiredModuleExports "HostBootstrap.Service.Internal" ownerSource
                let owner = normalizeWhitespace ownerSource
                exportedNames ownerExports
                    @?= [ "ServiceId"
                        , "ServiceHandler"
                        , "FinalizedServiceDefinition"
                        , "FinalizedServiceRegistry"
                        , "reindexFinalizedServiceRegistryKernel"
                        ]
                assertHiddenModule
                    "HostBootstrap.Service.Internal"
                    cabalSource
                    librarySource
                importersOf "HostBootstrap.Service.Internal" sources
                    @?= [ "HostBootstrap.ProjectPlan.Construct.Internal"
                        , "HostBootstrap.Service"
                        ]
                sort (SourceGuard.haskellImports ownerSource)
                    @?= sort
                        [ "Data.Text"
                        , "HostBootstrap.Config.Fields.Internal"
                        , "HostBootstrap.Config.Schema.Internal"
                        , "HostBootstrap.RoleLifecycle"
                        ]
                SourceGuard.countHaskellTokenSequence
                    ["data", "FinalizedServiceRegistry"]
                    ownerSource
                    @?= 1
                SourceGuard.countHaskellTokenSequence
                    ["data", "FinalizedServiceDefinition"]
                    ownerSource
                    @?= 1
                assertContains
                    "the finalized registry keeps three nominal authorities"
                    "type role FinalizedServiceRegistry nominal nominal nominal"
                    owner
                assertContains
                    "the registry retains the exact digest its finalization stamped"
                    ( "data FinalizedServiceRegistry scope specDigest cfg"
                        <> " = FinalizedServiceRegistry Text"
                        <> " [FinalizedServiceDefinition scope specDigest cfg]"
                    )
                    owner
                assertContains
                    "the reindex kernel consumes the digest-equality token and relabels one index"
                    ( "reindexFinalizedServiceRegistryKernel :: RecoverySpecReindex targetSpecDigest"
                        <> " -> FinalizedServiceRegistry scope sourceSpecDigest cfg"
                        <> " -> Either (Text, Text) (FinalizedServiceRegistry scope targetSpecDigest cfg)"
                    )
                    owner
                assertFragmentsInOrder
                    "the retained digest, then every role codec, is proved equal before any relabelling"
                    [ "reindexFinalizedServiceRegistryKernel token (FinalizedServiceRegistry retained definitions) | expected /= retained = Left (expected, retained)"
                    , "| otherwise = FinalizedServiceRegistry retained <$> traverse relabel definitions"
                    , "expected = recoverySpecReindexDigestKernel token"
                    , "relabel (FinalizedServiceDefinition identity select effects run codec) | expected /= internalRoleSpecDigest codec = Left (expected, internalRoleSpecDigest codec)"
                    , "| otherwise = Right ( FinalizedServiceDefinition identity select effects run RoleCodec"
                    , "internalRoleName = internalRoleName codec"
                    , "internalRoleScopeKind = internalRoleScopeKind codec"
                    , "internalRoleSpecDigest = internalRoleSpecDigest codec"
                    , "internalRoleWireCodec = internalRoleWireCodec codec"
                    ]
                    owner
                assertSoleTokenAuthority ownerSource
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "FinalizedServiceDefinition"
                    , "reindexFinalizedServiceRegistryKernel"
                    ]
                assertInertOwner ownerSource
        , testCase "the digest-equality token is the only relabelling authority" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                let tokenPath =
                        sourceRoot </> "HostBootstrap" </> "Config" </> "Schema" </> "Internal.hs"
                tokenSource <- readFile tokenPath
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                librarySource <- requiredMainLibraryStanza cabalSource
                sources <- readProductionSources sourceRoot
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                let token = normalizeWhitespace tokenSource
                assertHiddenModule
                    "HostBootstrap.Config.Schema.Internal"
                    cabalSource
                    librarySource
                importersOf "HostBootstrap.Config.Schema.Internal" sources
                    @?= [ "HostBootstrap.Config.Class.Internal"
                        , "HostBootstrap.Config.Schema"
                        , "HostBootstrap.ProjectPlan.Construct"
                        , "HostBootstrap.ProjectPlan.Construct.Internal"
                        , "HostBootstrap.Service.Internal"
                        ]
                assertContains
                    "the token is minted only from an exactly equal digest pair"
                    "withRecoverySpecReindexKernel expected observed use | expected == observed = Right (use (RecoverySpecReindex expected)) | otherwise = Left (expected, observed)"
                    token
                assertContains
                    "every carrier reads its target digest from the token itself"
                    "recoverySpecReindexDigestKernel :: RecoverySpecReindex targetSpecDigest -> Text recoverySpecReindexDigestKernel (RecoverySpecReindex expected) = expected"
                    token
                assertContains
                    "the token keeps one nominal target authority"
                    "type role RecoverySpecReindex nominal"
                    token
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "RecoverySpecReindex"
                    , "withRecoverySpecReindexKernel"
                    , "recoverySpecReindexDigestKernel"
                    , "reindexValidatedConfigKernel"
                    , "mintValidatedConfigKernel"
                    ]
        , testCase "the public config and service facades keep their complete export lists" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                classSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Config" </> "Class.hs")
                serviceSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Service.hs")
                classExports <-
                    requiredModuleExports "HostBootstrap.Config.Class" classSource
                serviceExports <-
                    requiredModuleExports "HostBootstrap.Service" serviceSource
                exportedNames classExports
                    @?= [ "ProjectCfg"
                        , "TestCfg"
                        , "InitArgs"
                        , "AssemblyRequest"
                        , "ConfigAssembly"
                        , "ConfigInput"
                        , "configInput"
                        , "configInputPath"
                        , "pureConfigAssembly"
                        , "failConfigAssembly"
                        , "readConfigInput"
                        , "runConfigAssembly"
                        , "ProjectCodec"
                        , "withProjectCodec"
                        , "withMappedProjectCodec"
                        , "withFinalizedProjectCodec"
                        , "projectCodecLabel"
                        , "projectCodecSchemaText"
                        , "projectCodecSpecDigest"
                        , "decodeProjectCodecFile"
                        , "decodeProjectCodecWithSettings"
                        , "renderProjectCodecValue"
                        , "renderProjectCodecHoisted"
                        ]
                exportedNames serviceExports
                    @?= [ "ServiceId"
                        , "serviceId"
                        , "serviceIdText"
                        , "ServiceDefinition"
                        , "ServiceHandler"
                        , "serviceDefinition"
                        , "serviceDeclaredEffects"
                        , "ServiceRegistry"
                        , "ServiceRegistryError"
                        , "emptyServiceRegistry"
                        , "singletonServiceRegistry"
                        , "serviceRegistry"
                        , "mergeServiceRegistries"
                        , "serviceVariantNames"
                        , "FinalizedServiceRegistry"
                        , "withFinalizedServiceRegistry"
                        , "finalizedServiceVariantNames"
                        , "serviceRoleSchemaFamilies"
                        , "withSelectedServiceRequest"
                        , "selectServiceAction"
                        ]
                assertBool
                    "the config facade no longer owns the codec representation"
                    (SourceGuard.countHaskellTokenSequence ["data", "ProjectCodec"] classSource == 0)
                assertBool
                    "the service facade no longer owns the finalized registry representation"
                    ( SourceGuard.countHaskellTokenSequence
                        ["data", "FinalizedServiceRegistry"]
                        serviceSource
                        == 0
                    )
        ]

{- | Every relabelling comparison in a hidden owner reads the token's digest,
and nothing else mints or forges one.
-}
assertSoleTokenAuthority :: String -> IO ()
assertSoleTokenAuthority source = do
    -- exactly the import and the one comparison that reads it
    SourceGuard.countHaskellIdentifier "recoverySpecReindexDigestKernel" source @?= 2
    -- exactly the import and the reindex signature; the owner mints no token
    SourceGuard.countHaskellIdentifier "RecoverySpecReindex" source @?= 2
    mapM_
        (\identifier -> SourceGuard.countHaskellIdentifier identifier source @?= 0)
        [ "withRecoverySpecReindexKernel"
        , "unsafeCoerce"
        , "coerce"
        ]

-- | A hidden owner performs no effect and owns no mutable or durable state.
assertInertOwner :: String -> IO ()
assertInertOwner source =
    mapM_
        (\identifier -> SourceGuard.countHaskellIdentifier identifier source @?= 0)
        [ "IORef"
        , "newIORef"
        , "unsafePerformIO"
        , "readFile"
        , "writeFile"
        , "createProcess"
        , "ProtectedStore"
        , "AcquisitionJournal"
        , "LifecycleCursor"
        , "CommandAuthority"
        ]

assertHiddenModule :: String -> String -> String -> IO ()
assertHiddenModule moduleName cabalSource librarySource = do
    length (filter (== moduleName) (fieldModules "other-modules:" librarySource)) @?= 1
    assertBool
        (moduleName <> " appears in the main library's exposed modules")
        (moduleName `notElem` fieldModules "exposed-modules:" librarySource)
    assertBool
        (moduleName <> " is exposed by another Cabal component")
        (moduleName `notElem` fieldModules "exposed-modules:" cabalSource)

exportedNames :: [String] -> [String]
exportedNames = filter (`notElem` [",", "(", ")", ".."])

importersOf :: String -> [(String, FilePath, String)] -> [String]
importersOf moduleName sources =
    sort
        [ importer
        | (importer, _path, source) <- sources
        , SourceGuard.importsModule moduleName source
        ]

withPackageSourceRoot :: (FilePath -> FilePath -> IO result) -> IO result
withPackageSourceRoot use = do
    cwd <- getCurrentDirectory
    repoRoot <-
        findRepoRoot cwd
            >>= maybe
                (assertFailure ("could not locate repo root from " <> cwd))
                pure
    let packageRoot = repoRoot </> "core" </> "hostbootstrap-core"
    use packageRoot (packageRoot </> "src")

readProductionSources :: FilePath -> IO [(String, FilePath, String)]
readProductionSources sourceRoot = do
    paths <- listHaskellSources sourceRoot
    traverse
        ( \path -> do
            source <- readFile path
            pure (moduleNameFromPath sourceRoot path, path, source)
        )
        paths

readPublicModuleExports :: FilePath -> FilePath -> IO [(String, [String])]
readPublicModuleExports packageRoot sourceRoot = do
    cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
    librarySource <- requiredMainLibraryStanza cabalSource
    sources <- readProductionSources sourceRoot
    let exposed = sort (fieldModules "exposed-modules:" librarySource)
        sourceByModule =
            [ (moduleName, source)
            | (moduleName, _path, source) <- sources
            ]
    traverse
        ( \moduleName -> do
            source <-
                maybe
                    (assertFailure ("source missing for exposed module " <> moduleName))
                    pure
                    (lookup moduleName sourceByModule)
            exports <- requiredModuleExports moduleName source
            pure (moduleName, exports)
        )
        exposed

requiredMainLibraryStanza :: String -> IO String
requiredMainLibraryStanza cabalSource =
    maybe
        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
        pure
        (mainLibraryStanza cabalSource)

requiredModuleExports :: String -> String -> IO [String]
requiredModuleExports moduleName source =
    maybe
        (assertFailure (moduleName <> " has no lexically visible explicit export list"))
        pure
        (SourceGuard.moduleExportTokens moduleName source)

modulesExporting :: String -> [(String, [String])] -> [String]
modulesExporting exported =
    sort
        . map fst
        . filter (elem exported . snd)

listHaskellSources :: FilePath -> IO [FilePath]
listHaskellSources directory = do
    entries <- sort <$> listDirectory directory
    fmap concat $
        traverse
            ( \entry -> do
                let path = directory </> entry
                isDirectory <- doesDirectoryExist path
                if isDirectory
                    then listHaskellSources path
                    else pure [path | takeExtension path == ".hs"]
            )
            entries

moduleNameFromPath :: FilePath -> FilePath -> String
moduleNameFromPath = SourceGuard.repoRelativeModuleName

mainLibraryStanza :: String -> Maybe String
mainLibraryStanza source =
    case dropWhile ((/= "library") . trim) (lines source) of
        [] -> Nothing
        _library : rest -> Just (unlines (takeWhile isLibraryContinuation rest))
  where
    isLibraryContinuation [] = True
    isLibraryContinuation line@(firstCharacter : _) =
        null (trim line) || isSpace firstCharacter

fieldModules :: String -> String -> [String]
fieldModules field = go . lines
  where
    go [] = []
    go (line : rest)
        | Just inline <- stripPrefix field (trim line) =
            let fieldIndent = indentation line
                (continuation, remaining) =
                    span
                        (\next -> null (trim next) || indentation next > fieldIndent)
                        rest
             in moduleTokens (inline : continuation) <> go remaining
        | otherwise = go rest

    moduleTokens =
        filter ("HostBootstrap." `isPrefixOf`)
            . map (filter (/= ','))
            . words
            . unlines

indentation :: String -> Int
indentation = length . takeWhile isSpace

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

normalizeWhitespace :: String -> String
normalizeWhitespace = unwords . words

assertContains :: String -> String -> String -> IO ()
assertContains label expected source =
    assertBool
        (label <> " is missing source shape: " <> show expected)
        (expected `isInfixOf` source)

assertFragmentsInOrder :: String -> [String] -> String -> IO ()
assertFragmentsInOrder label fragments source = go source fragments
  where
    go _ [] = pure ()
    go remainingSource (fragment : remaining) =
        case dropThrough fragment remainingSource of
            Nothing ->
                assertFailure
                    (label <> " is missing or misorders source shape: " <> show fragment)
            Just after -> go after remaining

dropThrough :: String -> String -> Maybe String
dropThrough needle = go
  where
    go [] = Nothing
    go remaining@(_character : rest)
        | needle `isPrefixOf` remaining = Just (drop (length needle) remaining)
        | otherwise = go rest
