{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The Windows ownership row, the selector between the two rows, and the one
identity encoding they share.

The Windows row is a platform row, so this module compiles on every gate host
(§ JJ). On a native Windows gate host each kernel case drives
"HostBootstrap.Ownership.Windows" against the real @CreateFileW@,
@LockFileEx@, @GetFileInformationByHandleEx@, and @CreateHardLinkW@ in a temporary
directory it created; on every other host the same cases stay and assert the
total refusal the row declares, and the first case asserts that the row's own
declaration agrees with the gate host it is running on. The family is therefore
the same size everywhere, which is what "CoverageManifest" checks.

Two things are proved here on /every/ host, because neither needs a kernel. The
first is that the two rows share one identity encoding: they read different
kernel facts, so if each encoded its own answer the two would agree until one of
them changed and nothing would ever ask them the same question together. The
second is that exactly one row is selected for this host, and that it is the one
whose declaration says it can hold the clauses here.
-}
module OwnershipWindowsSpec (tests, runOwnershipWindowsLockProbe) where

import ConditionalCase (conditionalCase)
import Control.Exception (IOException, bracket, try)
import Data.Char (isLower)
import qualified Data.ByteString as ByteString
import Data.Foldable (traverse_)
import qualified Data.Text as Text
import Data.List (isInfixOf, isSuffixOf, nub, sort)
import Expect (assertOwnershipReleaseOnDeath, expectOccupied, expectOwned, expectProbeFailure, expectRight, runOwnershipLockProbe)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    OwnershipFault (OwnershipOccupied, OwnershipUnsupported),
    mkKernelObjectIdentity,
    objectIdentityBytes,
    objectIdentityText,
 )
import HostBootstrap.Ownership.Posix (posixOwnershipCapabilities, posixOwnershipSupported)
import HostBootstrap.Ownership.Primitive (
    OwnershipCapabilities (OwnershipCapabilities),
    OwnershipPrimitive (
        rowCapabilities,
        rowCloseHandle,
        rowCreateDirectory,
        rowCreateFile,
        rowLinkNoReplace,
        rowObserveIdentity,
        rowOpenExclusive,
        rowReadObject,
        rowRemoveObject,
        rowSyncParent
    ),
    OwnershipRow,
    withOwnershipRow,
 )
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Ownership.Windows (
    windowsOwnershipCapabilities,
    windowsOwnershipRow,
    windowsOwnershipSupported,
    windowsIdentityFilesystem,
 )
import qualified SourceGuard
import System.Directory (createFileLink, doesFileExist, doesPathExist, getCurrentDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Info (os)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

#ifdef mingw32_HOST_OS
import Control.Exception (bracket_)
import HostBootstrap.HostTool (absExePath, mkAbsExe)
import System.Directory (findExecutable, makeAbsolute)
import System.Environment (getEnv, getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode, readProcessWithExitCode)
#endif

tests :: TestTree
tests =
    testGroup
        "OwnershipWindowsSpec"
        [ testGroup "the row's declaration" declarationTests
        , testGroup "identity" identityTests
        , testGroup "creation and publication" publicationTests
        , testGroup "the exclusive open" exclusionTests
        , testGroup "removal" removalTests
        , testGroup "the shared identity encoding" encodingTests
        , testGroup "the row selector" selectorTests
        , testGroup "the row's shape" shapeTests
        ]

-- ---------------------------------------------------------------------------
-- The declaration

declarationTests :: [TestTree]
declarationTests =
    [ testCase "the row's own declaration agrees with the gate host" $
        windowsOwnershipSupported @?= (os == "mingw32")
    , testCase "the row holds every clause together or none of them" $
        windowsOwnershipCapabilities
            @?= OwnershipCapabilities
                windowsOwnershipSupported
                windowsOwnershipSupported
                windowsOwnershipSupported
    , testCase "only NTFS and ReFS admit stable object identity" $ do
        traverse_ (\filesystem -> windowsIdentityFilesystem filesystem @?= Nothing) ["NTFS", "ReFS"]
        traverse_
            (\filesystem -> windowsIdentityFilesystem filesystem
                @?= Just (OwnershipUnsupported ("stable object identity is unavailable on filesystem " <> filesystem)))
            ["FAT32", "exFAT", "FAT"]

    ]

-- ---------------------------------------------------------------------------
-- Identity

identityTests :: [TestTree]
identityTests =
    [ rowCase "identity" "an object that is not there is an authoritative absence" $ \root -> do
        observed <- onRow (\row -> rowObserveIdentity row (root </> "absent"))
        observed @?= Right Nothing
    , rowCase "identity" "a created directory and a created file have their own identities" $ \root -> do
        let directory = root </> "directory"
            file = root </> "file"
        onRow (\row -> rowCreateDirectory row directory) >>= expectOwned "create the directory"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        directoryIdentity <- observeExisting directory
        fileIdentity <- observeExisting file
        ByteString.length (objectIdentityBytes directoryIdentity) @?= 24
        ByteString.length (objectIdentityBytes fileIdentity) @?= 24
        assertBool
            "two objects the kernel distinguishes have distinct identities"
            (directoryIdentity /= fileIdentity)
    , rowCase "identity" "linking preserves the identity the staged object had" $ \root -> do
        let staged = root </> "staged"
            target = root </> "target"
        onRow (\row -> rowCreateFile row staged "payload") >>= expectOwned "create the staged file"
        stagedIdentity <- observeExisting staged
        onRow (\row -> rowLinkNoReplace row staged target) >>= expectOwned "link"
        targetIdentity <- observeExisting target
        -- A hard link publishes a second name for the same object, which is what
        -- makes clause 3's binding survive publication on this kernel too.
        targetIdentity @?= stagedIdentity
    , rowCase "identity" "a symbolic link reads its own identity" $ \root -> do
        let file = root </> "file"
            link = root </> "link"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        createFileLink file link
        fileIdentity <- observeExisting file
        linkIdentity <- observeExisting link
        assertBool "the link is its own object" (fileIdentity /= linkIdentity)
    , rowCase "identity" "a junction reads its own identity" $ \root -> do
        let target = root </> "target"
            junction = root </> "junction"
        onRow (\row -> rowCreateDirectory row target) >>= expectOwned "create the target"
        createJunction junction target
        targetIdentity <- observeExisting target
        junctionIdentity <- observeExisting junction
        assertBool "the junction is its own object" (targetIdentity /= junctionIdentity)
    , rowCase "identity" "a path through a non-directory is a probe failure" $ \root -> do
        let file = root </> "file"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        observed <- onRow (\row -> rowObserveIdentity row (file </> "beneath"))
        expectProbeFailure "observe through a non-directory" observed
    , rowCase "identity" "denying file-content reads still permits identity observation" $ \root -> do
        let file = root </> "file"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        before <- observeExisting file
        withDeniedRead file $ do
            denied <- try (ByteString.readFile file)
            case (denied :: Either IOException ByteString.ByteString) of
                Left _ -> pure ()
                Right _ -> assertFailure "the fixture must actually deny file-content reads"
            observed <- onRow (\row -> rowObserveIdentity row file)
            observed @?= Right (Just before)
    ]

-- ---------------------------------------------------------------------------
-- Creation and publication

publicationTests :: [TestTree]
publicationTests =
    [ rowCase "creation and publication" "a directory is created once and the second attempt is occupied" $ \root -> do
        let directory = root </> "directory"
        onRow (\row -> rowCreateDirectory row directory) >>= expectOwned "create the directory"
        onRow (\row -> rowCreateDirectory row directory) >>= expectOccupied "the second create"
    , rowCase "creation and publication" "a file is written whole and the second attempt is occupied" $ \root -> do
        let file = root </> "file"
        onRow (\row -> rowCreateFile row file "the exact payload") >>= expectOwned "create the file"
        ByteString.readFile file >>= (@?= "the exact payload")
        onRow (\row -> rowCreateFile row file "a replacement") >>= expectOccupied "the second create"
        ByteString.readFile file >>= (@?= "the exact payload")
    , rowCase "creation and publication" "linking refuses rather than replacing, and leaves the target intact" $ \root -> do
        let staged = root </> "staged"
            target = root </> "target"
        onRow (\row -> rowCreateFile row staged "the staged payload") >>= expectOwned "stage"
        onRow (\row -> rowCreateFile row target "the operator's payload") >>= expectOwned "occupy"
        onRow (\row -> rowLinkNoReplace row staged target) >>= expectOccupied "link"
        ByteString.readFile target >>= (@?= "the operator's payload")
        doesFileExist staged >>= (@?= True)
    , rowCase "creation and publication" "a linked file is the staged bytes, under both names until one is withdrawn" $ \root -> do
        let staged = root </> "staged"
            target = root </> "target"
        onRow (\row -> rowCreateFile row staged "the staged payload") >>= expectOwned "stage"
        onRow (\row -> rowLinkNoReplace row staged target) >>= expectOwned "link"
        ByteString.readFile target >>= (@?= "the staged payload")
        -- The kernel primitive is a link, so the staging name survives it. An
        -- owner that wanted a move withdraws that name itself, which is the
        -- second half of the seam's own file publication.
        doesPathExist staged >>= (@?= True)
        onRow (\row -> rowRemoveObject row staged) >>= expectOwned "withdraw the staging name"
        doesPathExist staged >>= (@?= False)
        ByteString.readFile target >>= (@?= "the staged payload")
    , rowCase "creation and publication" "a missing parent makes file creation a probe failure" $ \root -> do
        created <- onRow (\row -> rowCreateFile row (root </> "missing" </> "file") "payload")
        expectProbeFailure "create beneath a missing parent" created
    , rowCase "creation and publication" "a file is not created through a symbolic link" $ \root -> do
        let behind = root </> "behind"
            link = root </> "link"
        createFileLink behind link
        created <- onRow (\row -> rowCreateFile row link "payload")
        expectOccupied "create through a link" created
        doesPathExist behind >>= (@?= False)
    ]

-- ---------------------------------------------------------------------------
-- The exclusive open

exclusionTests :: [TestTree]
exclusionTests =
    [ rowCase "the exclusive open" "an open handle reads the object's whole bytes" $ \root -> do
        let file = root </> "file"
        onRow (\row -> rowCreateFile row file "the exact payload") >>= expectOwned "create the file"
        contents <-
            onRow $ \row -> do
                opened <- rowOpenExclusive row file
                case opened of
                    Left fault -> pure (Left fault)
                    Right handle -> do
                        read' <- rowReadObject row handle
                        closed <- rowCloseHandle row handle
                        closed @?= Right ()
                        pure read'
        contents @?= Right "the exact payload"
    , rowCase "the exclusive open" "a directory is refused rather than opened as a file" $ \root -> do
        let directory = root </> "directory"
        onRow (\row -> rowCreateDirectory row directory) >>= expectOwned "create the directory"
        opened <- onRow (\row -> fmap (fmap (const ())) (rowOpenExclusive row directory))
        expectOccupied "open a directory" opened
        case opened of
            Left (OwnershipOccupied reason) -> assertBool "the non-regular guard answers" (Text.isInfixOf "is a directory or reparse point" reason)
            _ -> assertFailure "the directory must be occupied"
    , rowCase "the exclusive open" "a symbolic link is refused rather than followed" $ \root -> do
        let file = root </> "file"
            link = root </> "link"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        createFileLink file link
        opened <- onRow (\row -> fmap (fmap (const ())) (rowOpenExclusive row link))
        expectOccupied "open a link" opened
    , rowCase "the exclusive open" "a junction is refused rather than followed" $ \root -> do
        let target = root </> "target"
            junction = root </> "junction"
        onRow (\row -> rowCreateDirectory row target) >>= expectOwned "create the target"
        createJunction junction target
        opened <- onRow (\row -> fmap (fmap (const ())) (rowOpenExclusive row junction))
        expectOccupied "open a junction" opened
    , rowCase "the exclusive open" "a second handle in this process is occupied until close" $ \root -> do
        let file = root </> "file"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        released <- onRow $ \row -> do
            bracket
                (rowOpenExclusive row file)
                (\opened -> case opened of
                    Left _ -> pure ()
                    Right handle -> rowCloseHandle row handle >>= (@?= Right ()))
                (\opened -> case opened of
                    Left fault -> assertFailure ("could not hold the first handle: " <> show fault)
                    Right _ -> do
                        contended <- fmap (fmap (const ())) (rowOpenExclusive row file)
                        expectOccupied "open a second handle" contended)
            fresh <- rowOpenExclusive row file
            case fresh of
                Left fault -> pure (Left fault)
                Right handle -> rowCloseHandle row handle
        released @?= Right ()
    , rowCase "the exclusive open" "the kernel releases the exclusion when the holding process dies" $
        assertOwnershipReleaseOnDeath windowsOwnershipRow "--hostbootstrap-ownership-windows-lock-probe"
    ]

-- ---------------------------------------------------------------------------
-- Removal

removalTests :: [TestTree]
removalTests =
    [ rowCase "removal" "a file is removed, and its parent can be opened and flushed" $ \root -> do
        let file = root </> "file"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        onRow (\row -> rowSyncParent row file) >>= expectOwned "flush the created name's parent"
        onRow (\row -> rowRemoveObject row file) >>= expectOwned "remove the file"
        onRow (\row -> rowSyncParent row file) >>= expectOwned "sync the parent"
        doesPathExist file >>= (@?= False)
    , rowCase "removal" "a directory is removed" $ \root -> do
        let directory = root </> "directory"
        onRow (\row -> rowCreateDirectory row directory) >>= expectOwned "create the directory"
        onRow (\row -> rowRemoveObject row directory) >>= expectOwned "remove the directory"
        doesPathExist directory >>= (@?= False)
    , rowCase "removal" "removing an absent object is a probe failure" $ \root -> do
        removed <- onRow (\row -> rowRemoveObject row (root </> "absent"))
        expectProbeFailure "remove an absent object" removed
    , rowCase "removal" "a symbolic link is refused rather than removed" $ \root -> do
        let file = root </> "file"
            link = root </> "link"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        createFileLink file link
        onRow (\row -> rowRemoveObject row link) >>= expectOccupied "remove a link"
        ByteString.readFile file >>= (@?= "payload")
        doesPathExist link >>= (@?= True)
    , rowCase "removal" "a junction is refused rather than removed" $ \root -> do
        let target = root </> "target"
            junction = root </> "junction"
        onRow (\row -> rowCreateDirectory row target) >>= expectOwned "create the target"
        createJunction junction target
        onRow (\row -> rowRemoveObject row junction) >>= expectOccupied "remove a junction"
        doesPathExist target >>= (@?= True)
        doesPathExist junction >>= (@?= True)
    ]

-- ---------------------------------------------------------------------------
-- The one identity encoding

encodingTests :: [TestTree]
encodingTests =
    [ testCase "an identity is the volume word followed by the full object bytes" $ do
        identity <- expectIdentity (mkKernelObjectIdentity 0x0102030405060708 (ByteString.pack [0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11, 0x28, 0x27, 0x26, 0x25, 0x24, 0x23, 0x22, 0x21]))
        objectIdentityBytes identity
            @?= ByteString.pack
                [ 0x08
                , 0x07
                , 0x06
                , 0x05
                , 0x04
                , 0x03
                , 0x02
                , 0x01
                , 0x18
                , 0x17
                , 0x16
                , 0x15
                , 0x14
                , 0x13
                , 0x12
                , 0x11
                , 0x28
                , 0x27
                , 0x26
                , 0x25
                , 0x24
                , 0x23
                , 0x22
                , 0x21
                ]
        objectIdentityText identity @?= "080706050403020118171615141312112827262524232221"
    , testCase "neither row builds an identity of its own" $
        -- The rows read different kernel facts, so two encodings would agree
        -- until one of them was changed and nothing would ask them the same
        -- question together. There is one producer, and this is the guard that
        -- it stays the only one either row can reach.
        withCoreSourceRoot $ \sourceRoot ->
            traverse_
                ( \row -> do
                    source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> row)
                    SourceGuard.countHaskellIdentifier "mkObjectIdentity" source @?= 0
                    assertBool
                        (row <> " reaches the one kernel-identity producer")
                        (SourceGuard.countHaskellIdentifier "mkKernelObjectIdentity" source >= 2)
                )
                ["Posix.hs", "Windows.hs"]
    ]

-- ---------------------------------------------------------------------------
-- The selector

selectorTests :: [TestTree]
selectorTests =
    [ testCase "exactly one of the two rows can hold its clauses on this host" $
        [posixOwnershipSupported, windowsOwnershipSupported] @?= [os /= "mingw32", os == "mingw32"]
    , testCase "the selected row is the one that can hold them" $ do
        let selected = withOwnershipRow ownershipRowForHost rowCapabilities
        selected
            @?= if windowsOwnershipSupported
                then windowsOwnershipCapabilities
                else posixOwnershipCapabilities
        selected @?= OwnershipCapabilities True True True
    ]

-- ---------------------------------------------------------------------------
-- The row's shape

shapeTests :: [TestTree]
shapeTests =
    [ testCase "every observation opens without following a reparse point" $
        -- WslGlobalWallHostSpec's real symbolic-link target case reaches the
        -- Win32 row through ownershipRowForHost on Windows. This case holds the
        -- no-follow source shape on every gate host; junction/link cases above
        -- additionally exercise the native row directly.
        withCoreSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Windows.hs")
            traverse_
                ( \shape ->
                    assertBool
                        (shape <> " is what every observation opens with")
                        (shape `isInfixOf` normalize source)
                )
                [ "observationFlags = fILE_ATTRIBUTE_NORMAL .|. fILE_FLAG_BACKUP_SEMANTICS .|. fileFlagOpenReparsePoint"
                , "isNonRegular information = isDirectoryObject information || isReparsePoint information"
                , "parentDirectoryFlags = fILE_FLAG_BACKUP_SEMANTICS .|. fileFlagOpenReparsePoint"
                ]
            SourceGuard.countHaskellIdentifier "observationFlags" source @?= 5
            SourceGuard.countHaskellIdentifier "openObject" source @?= 8
            let calls =
                    [ ("windowsObserveIdentity", "observationFlags")
                    , ("windowsOpenExclusive", "observationFlags")
                    , ("windowsRemoveObject", "observationFlags")
                    , ("confirmMissingIdentity", "parentDirectoryFlags")
                    , ("windowsSyncParent", "parentDirectoryFlags")
                    ]
            traverse_
                (\(name, flags) -> do
                    tokens <- expectRight (SourceGuard.haskellDefinitionTokens name source)
                    let body = unwords tokens
                    SourceGuard.countHaskellIdentifier "openObject" body @?= 1
                    SourceGuard.countHaskellTokenSequence ["oPEN_EXISTING", flags] body @?= 1)
                calls
            creationTokens <- expectRight (SourceGuard.haskellDefinitionTokens "windowsCreateFile" source)
            SourceGuard.countHaskellIdentifier "openObject" (unwords creationTokens) @?= 1
    , testCase "the selector row names and CPP arms stay closed" $
        withCoreSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Row.hs")
            SourceGuard.countHaskellIdentifier "posixOwnershipRow" source @?= 2
            SourceGuard.countHaskellIdentifier "windowsOwnershipRow" source @?= 2
            assertBool "the selector has no third CPP arm" (not (isInfixOf "#elif" source))
            let rowNames =
                    sort (nub
                        [ token
                        | token@(first : _) <- SourceGuard.haskellTokens source
                        , isLower first
                        , token /= "withOwnershipRow"
                        , token == "ownershipRowForHost" || isSuffixOf "OwnershipRow" token
                        ])
            rowNames @?= ["ownershipRowForHost", "posixOwnershipRow", "windowsOwnershipRow"]
    , testCase "identity admits the opened handle filesystem before encoding FILE_ID_INFO" $
        withCoreSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Windows.hs")
            tokens <- expectRight (SourceGuard.haskellDefinitionTokens "identityOf" source)
            traverse_
                (\name -> length (filter (== name) tokens) @?= 1)
                ["rawGetVolumeInformationByHandleW", "windowsIdentityFilesystem",
                    "rawGetFileInformationByHandleEx", "mkKernelObjectIdentity"]
            let queried = dropWhile (/= "rawGetVolumeInformationByHandleW") tokens
                admitted = dropWhile (/= "windowsIdentityFilesystem") queried
                identified = dropWhile (/= "rawGetFileInformationByHandleEx") admitted
            assertBool "the actual handle supplies the filesystem query"
                (isInfixOf ["rawGetVolumeInformationByHandleW", "handle"] tokens)
            assertBool "admission precedes the full identity query" (not (null identified))
            assertBool "the admitted full identity reaches the shared encoder"
                (elem "mkKernelObjectIdentity" identified)
            missing <- expectRight (SourceGuard.haskellDefinitionTokens "confirmMissingIdentity" source)
            assertBool "absence admits the nearest existing parent through the same identity path"
                (isInfixOf ["identityOf", "parent", "handle"] missing)

    ]

-- ---------------------------------------------------------------------------
-- Helpers

{- | One case that drives the Windows row against the kernel.

Where the row can be held the body runs, so the case is evidence about a real
Win32 call. Elsewhere the case stays and asserts the refusal the row declares.
-}
rowCase :: TestName -> TestName -> (FilePath -> IO ()) -> TestTree
rowCase family name body =
    conditionalCase
        ["OwnershipWindowsSpec", family]
        windowsOwnershipSupported
        name
        (withSystemTempDirectory "hostbootstrap-ownership-windows" body)
        (withSystemTempDirectory "hostbootstrap-ownership-windows" expectRowRefusal)

{- | The disposition the Windows row owes a caller on a host that is not Windows.

Every primitive that could begin a clause is asked, because a row that refused
only some of them would be a row that half exists.
-}
expectRowRefusal :: FilePath -> IO ()
expectRowRefusal root = do
    let target = root </> "object"
    onRow (\row -> rowObserveIdentity row target) >>= expectUnsupported "observe an identity"
    onRow (\row -> fmap (fmap (const ())) (rowOpenExclusive row target))
        >>= expectUnsupported "open one object exclusively"
    onRow (\row -> rowCreateDirectory row target) >>= expectUnsupported "create a directory"
    onRow (\row -> rowCreateFile row target "payload") >>= expectUnsupported "create a file"
    onRow (\row -> rowLinkNoReplace row target target)
        >>= expectUnsupported "link without replacing"
    onRow (\row -> rowRemoveObject row target) >>= expectUnsupported "remove an object"
    onRow (\row -> rowSyncParent row target) >>= expectUnsupported "sync a parent directory"

-- | Run one continuation against the Windows row's primitives.
onRow :: (forall handle. OwnershipPrimitive handle -> IO result) -> IO result
onRow = withOwnershipRow (windowsOwnershipRow :: OwnershipRow)

observeExisting :: FilePath -> IO ObjectIdentity
observeExisting target = do
    observed <- onRow (\row -> rowObserveIdentity row target)
    case observed of
        Right (Just identity) -> pure identity
        other -> assertFailure ("expected an identity at " <> target <> ", got " <> show other)

expectIdentity :: Either OwnershipFault ObjectIdentity -> IO ObjectIdentity
expectIdentity = either (\fault -> assertFailure ("expected an identity: " <> show fault)) pure

expectUnsupported :: (Show value) => String -> Either OwnershipFault value -> IO ()
expectUnsupported label outcome = case outcome of
    Left (OwnershipUnsupported _) -> pure ()
    other ->
        assertFailure
            ("the row must refuse to " <> label <> " on this host, got " <> show other)

normalize :: String -> String
normalize = unwords . words

withCoreSourceRoot :: (FilePath -> IO result) -> IO result
withCoreSourceRoot use = do
    cwd <- getCurrentDirectory
    repoRoot <-
        findRepoRoot cwd
            >>= maybe (assertFailure ("could not locate repo root from " <> cwd)) pure
    use (repoRoot </> "core" </> "hostbootstrap-core" </> "internal" </> "ownership")

-- | The same real-handle probe mechanics, applied to the native Windows row.
runOwnershipWindowsLockProbe :: FilePath -> FilePath -> IO ()
runOwnershipWindowsLockProbe = runOwnershipLockProbe windowsOwnershipRow

#ifdef mingw32_HOST_OS
-- The two paths enter this constant PowerShell command through environment data.
createJunction :: FilePath -> FilePath -> IO ()
createJunction path target = do
    powershell <- resolveFixtureExecutable "powershell.exe"
    inherited <- getEnvironment
    let names = ["HOSTBOOTSTRAP_JUNCTION_PATH", "HOSTBOOTSTRAP_JUNCTION_TARGET"]
        supplied = [("HOSTBOOTSTRAP_JUNCTION_PATH", path), ("HOSTBOOTSTRAP_JUNCTION_TARGET", target)]
        environment = supplied ++ filter (\(name, _) -> not (elem name names)) inherited
        command = "New-Item -ItemType Junction -Path $env:HOSTBOOTSTRAP_JUNCTION_PATH -Value $env:HOSTBOOTSTRAP_JUNCTION_TARGET | Out-Null"
    (status, output, errors) <- readCreateProcessWithExitCode
        ((proc powershell ["-NoProfile", "-NonInteractive", "-Command", command]){env = Just environment}) ""
    assertBool ("create a real junction: " <> output <> errors) (status == ExitSuccess)

-- Remove the fixture's explicit deny even if an assertion fails.
withDeniedRead :: FilePath -> IO () -> IO ()
withDeniedRead path action = do
    icacls <- resolveFixtureExecutable "icacls.exe"
    user <- getEnv "USERNAME"
    let acl arguments = do
            (status, output, errors) <- readProcessWithExitCode icacls (path : arguments) ""
            assertBool ("set the fixture ACL: " <> output <> errors) (status == ExitSuccess)
    bracket_ (acl ["/deny", user <> ":(RD)"]) (acl ["/remove:d", user]) action

-- Resolve an actual host executable, then validate its absolute-path contract.
resolveFixtureExecutable :: FilePath -> IO FilePath
resolveFixtureExecutable name = do
    discovered <- findExecutable name
    case discovered of
        Nothing -> assertFailure ("missing native fixture executable: " <> name)
        Just path -> do
            absolute <- makeAbsolute path
            absExePath <$> expectRight (mkAbsExe absolute)

#else
createJunction :: FilePath -> FilePath -> IO ()
createJunction _ _ = assertFailure "junction creation requires the declared Windows row"

withDeniedRead :: FilePath -> IO () -> IO ()
withDeniedRead _ _ = assertFailure "ACL changes require the declared Windows row"
#endif
