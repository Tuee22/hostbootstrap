{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The Windows ownership row, the selector between the two rows, and the one
identity encoding they share.

The Windows row is a platform row, so this module compiles on every gate host
(§ JJ). On a native Windows gate host each kernel case drives
"HostBootstrap.Ownership.Windows" against the real @CreateFileW@,
@LockFileEx@, @GetFileInformationByHandle@, and @CreateHardLinkW@ in a temporary
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
module OwnershipWindowsSpec (tests) where

import qualified Data.ByteString as ByteString
import HostBootstrap.Ownership.Object
    ( ObjectIdentity
    , OwnershipFault (OwnershipUnsupported)
    , mkKernelObjectIdentity
    , objectIdentityBytes
    , objectIdentityText
    )
import HostBootstrap.Ownership.Posix (posixOwnershipCapabilities, posixOwnershipSupported)
import HostBootstrap.Ownership.Primitive
    ( OwnershipCapabilities (OwnershipCapabilities)
    , OwnershipPrimitive
        ( rowCapabilities
        , rowCloseHandle
        , rowCreateDirectory
        , rowCreateFile
        , rowObserveIdentity
        , rowOpenExclusive
        , rowLinkNoReplace
        , rowReadObject
        , rowRemoveObject
        , rowSyncParent
        )
    , OwnershipRow
    , withOwnershipRow
    )
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Ownership.Windows
    ( windowsOwnershipCapabilities
    , windowsOwnershipRow
    , windowsOwnershipSupported
    )
import Data.Foldable (traverse_)
import Data.List (isInfixOf)
import HostBootstrap.DocValidator (findRepoRoot)
import qualified SourceGuard
import System.Directory (doesFileExist, doesPathExist, getCurrentDirectory)
import System.FilePath ((</>))
import System.Info (os)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
                windowsOwnershipSupported
    ]

-- ---------------------------------------------------------------------------
-- Identity

identityTests :: [TestTree]
identityTests =
    [ rowCase "an object that is not there is an authoritative absence" $ \root -> do
        observed <- onRow (\row -> rowObserveIdentity row (root </> "absent"))
        observed @?= Right Nothing
    , rowCase "a created directory and a created file have their own identities" $ \root -> do
        let directory = root </> "directory"
            file = root </> "file"
        onRow (\row -> rowCreateDirectory row directory) >>= expectRight "create the directory"
        onRow (\row -> rowCreateFile row file "payload") >>= expectRight "create the file"
        directoryIdentity <- observeExisting directory
        fileIdentity <- observeExisting file
        assertBool
            "two objects the kernel distinguishes have distinct identities"
            (directoryIdentity /= fileIdentity)
    , rowCase "linking preserves the identity the staged object had" $ \root -> do
        let staged = root </> "staged"
            target = root </> "target"
        onRow (\row -> rowCreateFile row staged "payload") >>= expectRight "create the staged file"
        stagedIdentity <- observeExisting staged
        onRow (\row -> rowLinkNoReplace row staged target) >>= expectRight "link"
        targetIdentity <- observeExisting target
        -- A hard link publishes a second name for the same object, which is what
        -- makes clause 3's binding survive publication on this kernel too.
        targetIdentity @?= stagedIdentity
    ]

-- ---------------------------------------------------------------------------
-- Creation and publication

publicationTests :: [TestTree]
publicationTests =
    [ rowCase "a directory is created once and the second attempt is occupied" $ \root -> do
        let directory = root </> "directory"
        onRow (\row -> rowCreateDirectory row directory) >>= expectRight "create the directory"
        onRow (\row -> rowCreateDirectory row directory) >>= expectOccupied "the second create"
    , rowCase "a file is written whole and the second attempt is occupied" $ \root -> do
        let file = root </> "file"
        onRow (\row -> rowCreateFile row file "the exact payload") >>= expectRight "create the file"
        ByteString.readFile file >>= (@?= "the exact payload")
        onRow (\row -> rowCreateFile row file "a replacement") >>= expectOccupied "the second create"
        ByteString.readFile file >>= (@?= "the exact payload")
    , rowCase "linking refuses rather than replacing, and leaves the target intact" $ \root -> do
        let staged = root </> "staged"
            target = root </> "target"
        onRow (\row -> rowCreateFile row staged "the staged payload") >>= expectRight "stage"
        onRow (\row -> rowCreateFile row target "the operator's payload") >>= expectRight "occupy"
        onRow (\row -> rowLinkNoReplace row staged target) >>= expectOccupied "link"
        ByteString.readFile target >>= (@?= "the operator's payload")
        doesFileExist staged >>= (@?= True)
    , rowCase "a linked file is the staged bytes, under both names until one is withdrawn" $ \root -> do
        let staged = root </> "staged"
            target = root </> "target"
        onRow (\row -> rowCreateFile row staged "the staged payload") >>= expectRight "stage"
        onRow (\row -> rowLinkNoReplace row staged target) >>= expectRight "link"
        ByteString.readFile target >>= (@?= "the staged payload")
        -- The kernel primitive is a link, so the staging name survives it. An
        -- owner that wanted a move withdraws that name itself, which is the
        -- second half of the seam's own file publication.
        doesPathExist staged >>= (@?= True)
        onRow (\row -> rowRemoveObject row staged) >>= expectRight "withdraw the staging name"
        doesPathExist staged >>= (@?= False)
        ByteString.readFile target >>= (@?= "the staged payload")
    ]

-- ---------------------------------------------------------------------------
-- The exclusive open

exclusionTests :: [TestTree]
exclusionTests =
    [ rowCase "an open handle reads the object's whole bytes" $ \root -> do
        let file = root </> "file"
        onRow (\row -> rowCreateFile row file "the exact payload") >>= expectRight "create the file"
        contents <-
            onRow $ \row -> do
                opened <- rowOpenExclusive row file
                case opened of
                    Left fault -> pure (Left fault)
                    Right handle -> do
                        read' <- rowReadObject row handle
                        _ <- rowCloseHandle row handle
                        pure read'
        contents @?= Right "the exact payload"
    , rowCase "a directory is refused rather than opened as a file" $ \root -> do
        let directory = root </> "directory"
        onRow (\row -> rowCreateDirectory row directory) >>= expectRight "create the directory"
        opened <- onRow (\row -> fmap (fmap (const ())) (rowOpenExclusive row directory))
        expectOccupied "open a directory" opened
    ]

-- ---------------------------------------------------------------------------
-- Removal

removalTests :: [TestTree]
removalTests =
    [ rowCase "a file is removed, and the parent's own change is made durable" $ \root -> do
        let file = root </> "file"
        onRow (\row -> rowCreateFile row file "payload") >>= expectRight "create the file"
        onRow (\row -> rowRemoveObject row file) >>= expectRight "remove the file"
        onRow (\row -> rowSyncParent row file) >>= expectRight "sync the parent"
        doesPathExist file >>= (@?= False)
    , rowCase "a directory is removed" $ \root -> do
        let directory = root </> "directory"
        onRow (\row -> rowCreateDirectory row directory) >>= expectRight "create the directory"
        onRow (\row -> rowRemoveObject row directory) >>= expectRight "remove the directory"
        doesPathExist directory >>= (@?= False)
    ]

-- ---------------------------------------------------------------------------
-- The one identity encoding

encodingTests :: [TestTree]
encodingTests =
    [ testCase "an identity is the volume word first, then the object word, little-endian" $ do
        identity <- expectIdentity (mkKernelObjectIdentity 0x0102030405060708 0x1112131415161718)
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
                ]
        objectIdentityText identity @?= "08070605040302011817161514131211"
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
                        ("mkKernelObjectIdentity" `isInfixOf` source)
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
        selected @?= OwnershipCapabilities True True True True
    ]

-- ---------------------------------------------------------------------------
-- The row's shape

shapeTests :: [TestTree]
shapeTests =
    [ testCase "every observation opens without following a reparse point" $
        -- The live refusal of a reparse point at a target needs a Windows kernel
        -- and a link this suite may create there, which the host-portability
        -- acceptance phase confirms. What holds on every gate host is that the
        -- row asks the kernel not to follow one and treats it as non-regular
        -- when it sees one, and both are properties of this source.
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
                ]
    , testCase "the row selector names two rows and no third" $
        withCoreSourceRoot $ \sourceRoot -> do
            source <- readFile (sourceRoot </> "HostBootstrap" </> "Ownership" </> "Row.hs")
            SourceGuard.countHaskellIdentifier "posixOwnershipRow" source @?= 2
            SourceGuard.countHaskellIdentifier "windowsOwnershipRow" source @?= 2
    ]

-- ---------------------------------------------------------------------------
-- Helpers

{- | One case that drives the Windows row against the kernel.

Where the row can be held the body runs, so the case is evidence about a real
Win32 call. Elsewhere the case stays and asserts the refusal the row declares.
-}
rowCase :: TestName -> (FilePath -> IO ()) -> TestTree
rowCase name body =
    testCase name $
        withSystemTempDirectory "hostbootstrap-ownership-windows" $ \root ->
            if windowsOwnershipSupported
                then body root
                else expectRowRefusal root

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

expectRight :: String -> Either OwnershipFault value -> IO ()
expectRight label outcome = case outcome of
    Right _ -> pure ()
    Left fault -> assertFailure ("could not " <> label <> ": " <> show fault)

expectOccupied :: (Show value) => String -> Either OwnershipFault value -> IO ()
expectOccupied label outcome = case outcome of
    Left _ -> pure ()
    Right value -> assertFailure (label <> " must be refused, got " <> show value)

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
    use (repoRoot </> "core" </> "hostbootstrap-core" </> "src")
