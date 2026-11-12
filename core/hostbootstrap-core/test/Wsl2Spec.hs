{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module Wsl2Spec (tests) where

import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as Text
import Foreign.Ptr (Ptr)
#if !defined(mingw32_HOST_OS)
import Foreign.Ptr (nullPtr)
#endif
import Expect (expectRight)
import HostBootstrap.Ownership.Object (OwnershipFault (..), mkObjectIdentity)
import HostBootstrap.Wsl2.Registration
import Data.Either (isLeft)
import Data.List (isInfixOf, isPrefixOf)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Wsl2
import qualified SourceGuard
#if defined(mingw32_HOST_OS)
import Control.Exception (bracket, finally)
import Control.Monad (unless)
import Foreign.ForeignPtr (newForeignPtr_, withForeignPtr)
import Foreign.Marshal.Array (allocaArray)
import Foreign.Marshal.Utils (with)
import Foreign.Storable (pokeElemOff)
import Foreign.Ptr (castPtr)
import qualified System.Win32.Registry as Registry
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath (takeFileName)
#endif
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "Wsl2Spec"
        [ testGroup "native registration classifier" registrationCases
        , testGroup "native registry observations" nativeRegistrationCases
        , testGroup "lifecycle builders and classifiers" lifecycleCases
        , testGroup "provider realization boundary" providerBoundaryCases
        ]

registrationCases :: [TestTree]
registrationCases =
    [ testCase "an absent registration remains absence" $
        classifyWslRegistration registryName [] @?= Right Nothing
    , testCase "a valid registration retains its GUID and exact install path" $ do
        value <- expectRegistration (classifyWslRegistration registryName [registryEntry])
        identity <- expectRight (mkObjectIdentity (Char8.pack "01234567-89ab-cdef-0123-456789abcdef"))
        wslRegistrationIdentity value @?= identity
        wslRegistrationInstallPath value @?= rawWslInstallPath registryEntry
    , testCase "uppercase GUIDs normalize without changing identity" $ do
        lower <- expectRegistration (classifyWslRegistration registryName [registryEntry])
        upper <- expectRegistration (classifyWslRegistration registryName [registryEntry{rawWslIdentifier = "{01234567-89AB-CDEF-0123-456789ABCDEF}"}])
        upper @?= lower
    , testCase "Unicode names and install locations remain exact" $ do
        let name = "hostbootstrap-\x03bb"
            path = "C:\\Users\\\x00c5\\WSL\\\x1f642"
            entry = registryEntry{rawWslName = name, rawWslInstallPath = path}
        value <- expectRegistration (classifyWslRegistration name [entry])
        wslRegistrationInstallPath value @?= path
    , testCase "an unrelated WSL1 registration cannot become the requested instance" $
        classifyWslRegistration registryName [registryEntry{rawWslName = "unrelated", rawWslVersion = 1}] @?= Right Nothing
    , testCase "duplicate names refuse instead of choosing a registration" $
        assertRegistrationMalformed "multiple WSL registrations match the requested name"
            (classifyWslRegistration registryName [registryEntry, registryEntry{rawWslIdentifier = registryOtherGuid}])
    , testCase "case aliases cannot hide a duplicate name" $
        assertRegistrationMalformed "multiple WSL registrations match the requested name"
            (classifyWslRegistration registryName [registryEntry, registryEntry{rawWslName = "HOSTBOOTSTRAP-FIXTURE"}])
    , testCase "a case-only alias refuses instead of reporting absence" $
        assertRegistrationMalformed "a WSL registration differs in case from the requested name"
            (classifyWslRegistration registryName [registryEntry{rawWslName = "HOSTBOOTSTRAP-FIXTURE"}])
    , testCase "the registration count is bounded before selecting a candidate" $
        assertRegistrationMalformed "the WSL registry exceeds 1024 registrations"
            (classifyWslRegistration registryName (replicate 1025 registryEntry))
    ]
        <> [ testCase ("requested name refuses " <> label) $
                assertRegistrationMalformed "the requested WSL name is not bounded, non-empty text"
                    (classifyWslRegistration wanted [])
           | (label, wanted) <- [("empty", ""), ("NUL", "vm\0"), ("format controls", "vm\x202e"), ("overlong", replicate 257 'a')]
           ]
        <> [ testCase ("registration refuses " <> label) $
                assertRegistrationMalformed reason (classifyWslRegistration registryName [entry])
           | (label, entry, reason) <-
                [ ("missing name", registryEntry{rawWslName = ""}, "a WSL registration has an unreadable name")
                , ("name control", registryEntry{rawWslName = registryName <> "\ESC"}, "a WSL registration has an unreadable name")
                , ("WSL1 version", registryEntry{rawWslVersion = 1}, "the named registration is not a WSL2 distribution")
                , ("unknown version", registryEntry{rawWslVersion = 3}, "the named registration is not a WSL2 distribution")
                , ("unbraced GUID", registryEntry{rawWslIdentifier = "01234567-89ab-cdef-0123-456789abcdef"}, guidFault)
                , ("GUID width", registryEntry{rawWslIdentifier = "{0123}"}, guidFault)
                , ("GUID character", registryEntry{rawWslIdentifier = "{z1234567-89ab-cdef-0123-456789abcdef}"}, guidFault)
                , ("GUID hyphens", registryEntry{rawWslIdentifier = "{0123456789ab-cdef-0123-456789abcdef-}"}, guidFault)
                , ("relative install path", registryEntry{rawWslInstallPath = "relative\\WSL"}, pathFault)
                , ("empty install path", registryEntry{rawWslInstallPath = ""}, pathFault)
                , ("path NUL", registryEntry{rawWslInstallPath = "C:\\WSL\0foreign"}, pathFault)
                , ("path format control", registryEntry{rawWslInstallPath = "C:\\WSL\\\x202e"}, pathFault)
                , ("path surrogate", registryEntry{rawWslInstallPath = "C:\\WSL\\\xd800"}, pathFault)
                , ("overlong path", registryEntry{rawWslInstallPath = "C:\\" <> replicate 2045 'a'}, pathFault)
                , ("parent traversal", registryEntry{rawWslInstallPath = "C:\\WSL\\..\\foreign"}, pathFault)
                ]
           ]
  where
    guidFault = "the WSL registration key is not a canonical GUID"
    pathFault = "the WSL install location is not a bounded absolute Windows path"

registryName :: String
registryName = "hostbootstrap-fixture"

registryOtherGuid :: String
registryOtherGuid = "{11234567-89ab-cdef-0123-456789abcdef}"

registryEntry :: RawWslRegistration
registryEntry = RawWslRegistration "{01234567-89ab-cdef-0123-456789abcdef}" registryName "C:\\hostbootstrap\\fixture" 2

expectRegistration :: Either OwnershipFault (Maybe WslRegistration) -> IO WslRegistration
expectRegistration outcome = do
    value <- expectRight outcome
    maybe (assertFailure "expected one actual registration") pure value

assertRegistrationMalformed :: Text.Text -> Either OwnershipFault value -> IO ()
assertRegistrationMalformed reason outcome = case outcome of
    Left fault -> fault @?= OwnershipMalformed reason
    Right _ -> assertFailure "expected the exact malformed-registration refusal"

nativeRegistrationCases :: [TestTree]
nativeRegistrationCases =
    [ testCase "an empty native key observes no registration" $
        withRegistryFixture $ \pointer _ -> readWslRegistrationKey pointer >>= (@?= Right [])
    , testCase "Unicode values cross the real native registry API" $
        withRegistryFixture $ \pointer _ -> do
            let entry = registryEntry{rawWslName = "hostbootstrap-\x03bb", rawWslInstallPath = "C:\\Users\\\x00c5\\WSL\\\x1f642"}
            writeNativeRegistration pointer entry
            observed <- expectRight =<< readWslRegistrationKey pointer
            observed @?= [entry]
            value <- expectRegistration (classifyWslRegistration (rawWslName entry) observed)
            wslRegistrationInstallPath value @?= rawWslInstallPath entry
    , testCase "duplicate native registrations remain a refusal" $
        withRegistryFixture $ \pointer _ -> do
            writeNativeRegistration pointer registryEntry
            writeNativeRegistration pointer registryEntry{rawWslIdentifier = registryOtherGuid}
            observed <- expectRight =<< readWslRegistrationKey pointer
            length observed @?= 2
            assertRegistrationMalformed "multiple WSL registrations match the requested name"
                (classifyWslRegistration registryName observed)
    , testCase "a missing native value cannot become absence" $
        withRegistryFixture $ \pointer _ -> do
            writeNativeRegistration pointer registryEntry
            removeNativeField pointer "BasePath"
            readWslRegistrationKey pointer
                >>= (@?= Left (OwnershipMalformed "the WSL registration is incomplete"))
    , testCase "a wrongly typed native version is a read refusal" $
        withRegistryFixture $ \pointer _ -> do
            writeNativeRegistration pointer registryEntry
            setNativeText pointer "Version" "two"
            readWslRegistrationKey pointer >>= assertRegistryProbe "read WSL registration version"
    , testCase "invalid native UTF-16 cannot be decoded as an identity" $
        withRegistryFixture $ \pointer _ -> do
            writeNativeRegistration pointer registryEntry
            setNativeTextBytes pointer "BasePath" (ByteString.pack [0, 0xd8, 0, 0])
            readWslRegistrationKey pointer
                >>= (@?= Left (OwnershipMalformed "a WSL registry string is not valid UTF-16"))
    , testCase "an oversized native string refuses within the fixed buffer" $
        withRegistryFixture $ \pointer _ -> do
            writeNativeRegistration pointer registryEntry
            setNativeText pointer "BasePath" ("C:\\" <> replicate 2048 'a')
            readWslRegistrationKey pointer >>= assertRegistryProbe "read WSL registration text"
    , testCase "a handle without read rights refuses without changing ACLs" $
        withRegistryFixture $ \_ path ->
            withWriteOnlyRegistryKey path $ \limited ->
                readWslRegistrationKey limited
                    >>= (@?= Left (OwnershipProbeFailed "enumerate WSL registrations" "the registry key does not permit this observation"))
    , testCase "borrowing a native key does not close the caller's handle" $
        withRegistryFixture $ \pointer _ -> do
            writeNativeRegistration pointer registryEntry
            readWslRegistrationKey pointer >>= (@?= Right [registryEntry])
            readWslRegistrationKey pointer >>= (@?= Right [registryEntry])
    , testCase "the production query uses its fixed native namespace and no CLI" $ do
        source <- providerSource ("Wsl2" </> "Registration.hs")
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "Registry.regOpenKeyEx Registry.hKEY_CURRENT_USER \"Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Lxss\" Registry.kEY_READ")
            source @?= 1
        forMImports source
    ]

forMImports :: String -> IO ()
forMImports source =
    mapM_ (\name -> assertBool ("the registration observer imported " <> name)
        (notElem name (SourceGuard.haskellImports source)))
        ["System.Process", "System.Environment", "HostBootstrap.Effect.Interpreter"]

assertRegistryProbe :: Text.Text -> Either OwnershipFault value -> IO ()
assertRegistryProbe operation outcome = case outcome of
    Left (OwnershipProbeFailed actual reason) -> do
        actual @?= operation
        assertBool "the native refusal retains a diagnostic" (not (Text.null reason))
    _ -> assertFailure "expected a native registry read refusal"

withRegistryFixture :: (Ptr () -> String -> IO ()) -> IO ()
#if defined(mingw32_HOST_OS)
withRegistryFixture consume =
    withSystemTempDirectory "hostbootstrap-wsl-registry" $ \directory -> do
        let path = "Software\\HostBootstrapTest-" <> takeFileName directory
            acquire = do
                (key, created) <- Registry.regCreateKeyEx Registry.hKEY_CURRENT_USER path Nothing
                    Registry.rEG_OPTION_NON_VOLATILE Registry.kEY_ALL_ACCESS Nothing
                unless created $ do
                    Registry.regCloseKey key
                    assertFailure "the scratch registry key already existed"
                pure key
            release key = do
                let removeChildren = allocaArray 256 $ \buffer -> do
                        -- regEnumKey decodes its buffer even at ERROR_NO_MORE_ITEMS.
                        pokeElemOff buffer 0 0
                        (name, done) <- Registry.regEnumKey key 0 buffer 256
                        unless (done /= 0) $ do
                            Registry.regDeleteKey key name
                            removeChildren
                removeChildren `finally` Registry.regCloseKey key
                Registry.regDeleteKey Registry.hKEY_CURRENT_USER path
        bracket acquire release $ \key -> withForeignPtr key (\pointer -> consume pointer path)
#else
withRegistryFixture _consume = do
    readWslRegistrationKey nullPtr
        >>= (@?= Left (OwnershipUnsupported "native WSL registration requires Windows"))
    observeWslRegistration registryName
        >>= (@?= Left (OwnershipUnsupported "native WSL registration requires Windows"))
#endif

writeNativeRegistration :: Ptr () -> RawWslRegistration -> IO ()
#if defined(mingw32_HOST_OS)
writeNativeRegistration pointer entry = do
    parent <- newForeignPtr_ pointer
    bracket
        (Registry.regCreateKeyEx parent (rawWslIdentifier entry) Nothing Registry.rEG_OPTION_NON_VOLATILE Registry.kEY_ALL_ACCESS Nothing)
        (Registry.regCloseKey . fst) $ \(key, created) -> do
            assertBool "the fixture's registration key is fresh" created
            Registry.regSetStringValue key "DistributionName" (rawWslName entry)
            Registry.regSetStringValue key "BasePath" (rawWslInstallPath entry)
            with (rawWslVersion entry) $ \version ->
                Registry.regSetValueEx key "Version" Registry.rEG_DWORD (castPtr version) 4
#else
writeNativeRegistration _pointer _entry = assertFailure "the native registry fixture requires Windows"
#endif

#if defined(mingw32_HOST_OS)
withFixtureRegistration :: Ptr () -> (Ptr () -> IO ()) -> IO ()
withFixtureRegistration pointer consume = do
    parent <- newForeignPtr_ pointer
    bracket (Registry.regOpenKeyEx parent (rawWslIdentifier registryEntry) Registry.kEY_ALL_ACCESS)
        Registry.regCloseKey (\key -> withForeignPtr key consume)
#endif

removeNativeField :: Ptr () -> String -> IO ()
#if defined(mingw32_HOST_OS)
removeNativeField pointer field = withFixtureRegistration pointer $ \child -> do
    key <- newForeignPtr_ child
    Registry.regDeleteValue key field
#else
removeNativeField _pointer _field = assertFailure "the native registry fixture requires Windows"
#endif

setNativeText :: Ptr () -> String -> String -> IO ()
#if defined(mingw32_HOST_OS)
setNativeText pointer field value = withFixtureRegistration pointer $ \child -> do
    key <- newForeignPtr_ child
    Registry.regSetStringValue key field value
#else
setNativeText _pointer _field _value = assertFailure "the native registry fixture requires Windows"
#endif

setNativeTextBytes :: Ptr () -> String -> ByteString.ByteString -> IO ()
#if defined(mingw32_HOST_OS)
setNativeTextBytes pointer field bytes = withFixtureRegistration pointer $ \child -> do
    key <- newForeignPtr_ child
    ByteString.useAsCStringLen bytes $ \(buffer, count) ->
        Registry.regSetValueEx key field Registry.rEG_SZ (castPtr buffer) count
#else
setNativeTextBytes _pointer _field _bytes = assertFailure "the native registry fixture requires Windows"
#endif

withWriteOnlyRegistryKey :: String -> (Ptr () -> IO ()) -> IO ()
#if defined(mingw32_HOST_OS)
withWriteOnlyRegistryKey path consume =
    bracket (Registry.regOpenKeyEx Registry.hKEY_CURRENT_USER path Registry.kEY_SET_VALUE)
        Registry.regCloseKey (\key -> withForeignPtr key consume)
#else
withWriteOnlyRegistryKey _path _consume = assertFailure "the native registry fixture requires Windows"
#endif

lifecycleCases :: [TestTree]
lifecycleCases =
    [ testCase "platform diagnostic classifiers" $ do
        assertBool "detects WSL virtualization startup diagnostic" $
            wslReportsVirtualizationDisabled (ExitSuccess, "WSL2 is unable to start since virtualization is not enabled", "")
        assertBool "detects UTF-16-shaped WSL virtualization startup diagnostic" $
            wslReportsVirtualizationDisabled (ExitSuccess, utf16ish "WSL2 is unable to start since virtualization is not enabled", "")
        assertBool "detects the no-installed-distributions diagnostic" $
            wslReportsNoInstalledDistributions (ExitSuccess, utf16ish "Windows Subsystem for Linux has no installed distributions.", "")
    , testCase "pure lifecycle argv builders" $ do
        bcdeditHypervisorLaunchArgs @?= ["/set", "hypervisorlaunchtype", "auto"]
        wslInstallArgs "hostbootstrap-demo" "80GB"
            @?= ["--install", "-d", "Ubuntu-24.04", "--name", "hostbootstrap-demo", "--no-launch", "--vhd-size", "80GB"]
        wslExecArgs "hostbootstrap-demo" ["hostbootstrap-demo", "project", "up"]
            @?= ["-d", "hostbootstrap-demo", "--exec", "hostbootstrap-demo", "project", "up"]
        wslUnregisterArgs "hostbootstrap-demo-" "hostbootstrap-demo-wsl"
            @?= Right ["--unregister", "hostbootstrap-demo-wsl"]
        assertBool "refuses to unregister unmanaged distro" (isLeft (wslUnregisterArgs "hostbootstrap-demo-" "personal-ubuntu"))
        wslShutdownArgs @?= ["--shutdown"]
    , testCase "quiet WSL name lists strip UTF-16 NUL padding" $ do
        wslListDistros (utf16ish "hostbootstrap-demo-vm\nUbuntu\n") @?= ["hostbootstrap-demo-vm", "Ubuntu"]

    ]

providerBoundaryCases :: [TestTree]
providerBoundaryCases =
    [ testCase "Wsl2 consumes the lower target/renderer and delegates prerequisite helpers" $ do
        source <- providerSource "Wsl2.hs"
        -- Three lower modules, and only three: the prerequisite helpers this
        -- module delegates to, the frame's own target and renderer, and the shared
        -- frame table this row's destructive delete goes through (§ LL). All three
        -- are below the realization, which is what this guard is for.
        hostBootstrapImports source
            @?= [ "HostBootstrap.Ensure.Wsl2"
                , "HostBootstrap.Lift.Context"
                , "HostBootstrap.Substrate.Frame"
                ]
        fmap withoutCommas (SourceGuard.moduleImportTokens "HostBootstrap.Lift.Context" source)
            @?= Just ["Wsl2VM", "(", "..", ")", "wslExecArgs"]
        fmap withoutCommas (SourceGuard.moduleImportTokens "HostBootstrap.Substrate.Frame" source)
            @?= Just ["FrameNoun", "(", "Wsl2Distribution", ")", "guardedDeleteArgs"]
        fmap withoutCommas (SourceGuard.moduleImportTokens "HostBootstrap.Ensure.Wsl2" source)
            @?= Just prerequisiteHelpers
        exports <-
            maybe
                (fail "HostBootstrap.Wsl2 must have an explicit export list")
                pure
                (SourceGuard.moduleExportTokens "HostBootstrap.Wsl2" source)
        assertBool "Wsl2VM (..) is not reexported" (["Wsl2VM", "(", "..", ")"] `isInfixOf` exports)
        assertBool "wslExecArgs is not reexported" ("wslExecArgs" `elem` exports)
        mapM_ (\helper -> assertBool (helper ++ " is not reexported") (helper `elem` exports)) prerequisiteHelpers
        SourceGuard.countHaskellTokenSequence ["data", "Wsl2VM"] source @?= 0
        SourceGuard.countHaskellTokenSequence ["newtype", "Wsl2VM"] source @?= 0
        SourceGuard.countHaskellTokenSequence ["wslExecArgs", "::"] source @?= 0
        mapM_ (\helper -> SourceGuard.countHaskellTokenSequence [helper, "::"] source @?= 0) prerequisiteHelpers
        assertNoParallelLift source
    ]

prerequisiteHelpers :: [String]
prerequisiteHelpers =
    [ "bcdeditHypervisorLaunchArgs"
    , "normalizeWslText"
    , "wslReportsNoInstalledDistributions"
    , "wslReportsVirtualizationDisabled"
    ]

providerSource :: FilePath -> IO String
providerSource sourceFile = do
    cwd <- getCurrentDirectory
    root <- findRepoRoot cwd >>= maybe (fail ("could not locate repository root from " ++ cwd)) pure
    readFile (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> sourceFile)

hostBootstrapImports :: String -> [String]
hostBootstrapImports = filter ("HostBootstrap." `isPrefixOf`) . SourceGuard.haskellImports

withoutCommas :: [String] -> [String]
withoutCommas = filter (/= ",")

assertNoParallelLift :: String -> IO ()
assertNoParallelLift source =
    mapM_
        ( \identifier ->
            SourceGuard.countHaskellIdentifier identifier source
                @?= 0
        )
        ["foldLift", "foldLeaf", "LiftContext", "DispatchLocal", "DispatchTool", "SubstrateProvider"]

utf16ish :: String -> String
utf16ish =
    concatMap (\c -> [c, '\0'])
