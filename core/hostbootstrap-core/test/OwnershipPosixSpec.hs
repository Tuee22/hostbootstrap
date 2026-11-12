{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The POSIX ownership row, against the real kernel.

Every case below drives "HostBootstrap.Ownership.Posix" in a temporary
directory it created, so each one proves the syscall it names rather than the
bookkeeping of something written to stand in for one (§ NN). Nothing here is
faked: the identities compared are @lstat@'s, the publication is @link(2)@, the
exclusion is an @fcntl@ write lock, and the case that proves the kernel releases
that lock does it by letting a real process die.

The row is a platform row, so this module compiles on every gate host (§ JJ). On
a host that cannot hold the row, each case stays and asserts the total refusal
the row declares, and the first case asserts that the row's own declaration
agrees with the gate host it is running on. The family is therefore the same
size everywhere, which is what "CoverageManifest" checks.
-}
module OwnershipPosixSpec (tests, runOwnershipPosixLockProbe, runOwnershipManifestLocaleProbe, foreignManifestOwnerSupported) where

import ConditionalCase (conditionalCase)
import Control.Exception (bracket, try)
#ifndef mingw32_HOST_OS
import Control.Exception (IOException)
#endif
import qualified Data.ByteString as ByteString
import Data.Foldable (for_)
import qualified Expect as OwnershipFixture
import qualified Data.Text as Text
import GHC.IO.Encoding (getFileSystemEncoding)
import System.IO (hPutStrLn, stderr)
import HostBootstrap.DocValidator (findRepoRoot)
import qualified SourceGuard
import SealedExportInventory (pinnedPrivateExportLists)
import qualified HostBootstrap.Ownership.Manifest as Manifest
import HostBootstrap.Ownership.Clause (Bound)
import HostBootstrap.Ownership.Remainder (releaseManifestRemainder)
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Ownership.Tape (RecordSubject (..), recordTape, publishFreshRecord, publishBoundRecord)
import HostBootstrap.Protected (mkRecordKey, openProtectedStore, withProtectedEntry)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Network.Socket as Socket
import Expect (assertOwnershipReleaseOnDeath, expectOccupied, expectOwned, expectProbeFailure, runOwnershipLockProbe)
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    ObjectKind (OwnedDirectory),
    OwnershipFault (OwnershipConflict, OwnershipMalformed, OwnershipOccupied, OwnershipProbeFailed, OwnershipUnsupported),
 )
import HostBootstrap.Ownership.Posix (
    posixOwnershipCapabilities,
    posixOwnershipRow,
    posixOwnershipSupported,
    posixObserveOwnershipManifest,
    posixObserveOwnershipManifestAt,
    posixReleaseManifestEntry,
 )
import HostBootstrap.Ownership.Primitive (
    OwnershipCapabilities (OwnershipCapabilities),
    OwnershipPrimitive (
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
    withOwnershipRow,
    enterOwnedObject,
    recordOwnedOrigin,
    createOwnedDirectory,
    bindOwnedIdentity,
 )
import System.Directory (createDirectory, createFileLink, doesFileExist, doesPathExist, getCurrentDirectory, doesDirectoryExist, renameDirectory, renameFile, removeFile, removeDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
#ifndef mingw32_HOST_OS
import System.IO.Temp (withTempDirectory)
#endif
import System.Info (os)
import System.Posix.Types (Fd (..))
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (HUnitFailure, assertBool, assertFailure, testCase, (@?=))

#ifndef mingw32_HOST_OS
import Control.Exception (bracket_)
import Data.List (find, sortOn)
import Data.Ord (Down (..))
import qualified Data.ByteString.Char8 as ByteString.Char8
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (ExitSuccess))
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import System.Posix.Files (createLink, createNamedPipe, deviceID, fileMode, fileOwner, getFileStatus, setFileMode, setOwnerAndGroup)
import System.IO.Error (isPermissionError)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.User (getEffectiveUserID)
import qualified System.Posix.IO as PosixIO
import qualified System.Posix.IO.ByteString as RawIO
import qualified System.Posix.Files.ByteString as RawFiles
import qualified System.Posix.Directory.ByteString as RawDirectory
import System.Posix.Internals (withFilePath)
#endif

tests :: TestTree
tests =
    testGroup
        "OwnershipPosixSpec"
        [ testGroup "the row's declaration" declarationTests
        , testGroup "identity" identityTests
        , testGroup "parent traversal" parentTraversalTests
        , testGroup "parent settlement" parentSettlementTests
        , testGroup "creation and publication" publicationTests
        , testGroup "the exclusive open" exclusionTests
        , testGroup "removal and durability" removalTests
        , testGroup "manifest walk" manifestWalkTests
        , testGroup "raw manifest bytes" rawManifestTests
        , testGroup "manifest remainder" manifestRemainderTests
        , testGroup "foreign manifest owner" [foreignManifestOwnerTest]
        ]

-- ---------------------------------------------------------------------------
-- The declaration

declarationTests :: [TestTree]
declarationTests =
    [ testCase "the row's own declaration agrees with the gate host" $
        posixOwnershipSupported @?= (os /= "mingw32")
    , testCase "the row holds every clause together or none of them" $
        -- The capabilities are one kernel's, so a host that supplies some of
        -- them and not others is not a state this row reports: it would leave a
        -- clause held by a row that declares it cannot hold the transaction.
        posixOwnershipCapabilities
            @?= OwnershipCapabilities
                posixOwnershipSupported
                posixOwnershipSupported
                posixOwnershipSupported
    , testCase "the occupied assertion refuses other fault constructors" $
        mapM_
            (\fault -> do
                refused <- try (expectOccupied "the occupied assertion" (Left fault :: Either OwnershipFault ()))
                case (refused :: Either HUnitFailure ()) of
                    Left _ -> pure ()
                    Right () -> assertFailure ("the occupied assertion accepted " <> show fault)
            )
            [OwnershipProbeFailed "probe" "reason", OwnershipUnsupported "reason"]
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
        -- @link(2)@ publishes a second name for the same object, which is what
        -- makes clause 3's binding survive publication: the identity the
        -- transaction read is the identity release will re-observe.
        targetIdentity @?= stagedIdentity
    , rowCase "identity" "a symbolic link reads its own identity rather than its target's" $ \root -> do
        let file = root </> "file"
            link = root </> "link"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        createFileLink file link
        fileIdentity <- observeExisting file
        linkIdentity <- observeExisting link
        assertBool
            "a link is a different object, so it does not read as its target"
            (fileIdentity /= linkIdentity)
    , rowCase "identity" "a path through a non-directory is a fault rather than an absence" $ \root -> do
        let file = root </> "file"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        observed <- onRow (\row -> rowObserveIdentity row (file </> "beneath"))
        expectOccupied "observe through a non-directory" observed
    , rowCase "identity" "an inaccessible parent makes identity observation a probe failure" $ \root ->
        permissionCase "identity observation beneath mode 000" $
            withParentMode root 0o000 $ \parent -> do
                observed <- onRow (\row -> rowObserveIdentity row (parent </> "absent"))
                expectProbeFailure "observe through an inaccessible parent" observed
    ]

-- ---------------------------------------------------------------------------
-- Parent traversal

parentTraversalTests :: [TestTree]
parentTraversalTests =
    [ rowCase "parent traversal" "identity lookup refuses a symbolic parent" $ \root ->
        withLinkedParent root $ \linked _outside -> do
            observed <- onRow (\row -> rowObserveIdentity row (linked </> "keep"))
            expectOccupied "observe through a symbolic parent" observed
    , rowCase "parent traversal" "directory creation refuses a symbolic parent" $ \root ->
        withLinkedParent root $ \linked outside -> do
            created <- onRow (\row -> rowCreateDirectory row (linked </> "new-directory"))
            expectOccupied "create through a symbolic parent" created
            doesPathExist (outside </> "new-directory") >>= (@?= False)
    , rowCase "parent traversal" "file creation refuses a symbolic parent" $ \root ->
        withLinkedParent root $ \linked outside -> do
            created <- onRow (\row -> rowCreateFile row (linked </> "new-file") "new payload")
            expectOccupied "create a file through a symbolic parent" created
            doesPathExist (outside </> "new-file") >>= (@?= False)
    , rowCase "parent traversal" "exclusive opening refuses a symbolic parent" $ \root ->
        withLinkedParent root $ \linked _outside -> do
            opened <- onRow $ \row -> do
                outcome <- rowOpenExclusive row (linked </> "keep")
                case outcome of
                    Left fault -> pure (Left fault)
                    Right handle -> do
                        rowCloseHandle row handle >>= expectOwned "close an unexpectedly admitted handle"
                        pure (Right ())
            expectOccupied "open through a symbolic parent" opened
    ]

parentSettlementTests :: [TestTree]
parentSettlementTests =
    [ rowCase "parent settlement" "publication refuses a symbolic source parent" $ \root ->
        withLinkedParent root $ \linked _outside -> do
            let target = root </> "published"
            result <- onRow (\row -> rowLinkNoReplace row (linked </> "keep") target)
            expectOccupied "publish through a symbolic source parent" result
            doesPathExist target >>= (@?= False)
    , rowCase "parent settlement" "publication refuses a symbolic target parent" $ \root ->
        withLinkedParent root $ \linked outside -> do
            let source = root </> "staged"
            ByteString.writeFile source "staged bytes"
            identity <- observeExisting source
            result <- onRow (\row -> rowLinkNoReplace row source (linked </> "published"))
            expectOccupied "publish through a symbolic target parent" result
            doesPathExist (outside </> "published") >>= (@?= False)
            observeExisting source >>= (@?= identity)
            ByteString.readFile source >>= (@?= "staged bytes")
    , rowCase "parent settlement" "file removal refuses a symbolic parent" $ \root ->
        withLinkedParent root $ \linked _outside -> do
            removed <- onRow (\row -> rowRemoveObject row (linked </> "keep"))
            expectOccupied "remove a file through a symbolic parent" removed
    , rowCase "parent settlement" "directory removal refuses a symbolic parent" $ \root ->
        withLinkedParent root $ \linked _outside -> do
            removed <- onRow (\row -> rowRemoveObject row (linked </> "empty"))
            expectOccupied "remove a directory through a symbolic parent" removed
    , rowCase "parent settlement" "parent synchronization refuses a symbolic parent" $ \root ->
        withLinkedParent root $ \linked _outside -> do
            synced <- onRow (\row -> rowSyncParent row (linked </> "keep"))
            expectOccupied "sync a symbolic parent" synced
    , rowCase "parent settlement" "manifest observation refuses a symbolic ancestor of its root" $ \root ->
        withLinkedParent root $ \linked _outside -> do
            observed <- posixObserveOwnershipManifest False (linked </> "tree")
            expectOccupied "observe a manifest through a symbolic root ancestor" observed
    , rowCase "parent settlement" "manifest removal refuses a symbolic ancestor of its root" $ \root ->
        withLinkedParent root $ \linked outside -> do
            let realRoot = outside </> "tree"
            identity <- observeExisting realRoot
            observed <- posixObserveOwnershipManifest False realRoot >>= OwnershipFixture.expectRight
            entry <- case filter ((== "leaf") . Manifest.manifestEntryPath) (Manifest.ownershipManifestEntries observed) of
                [value] -> pure value
                other -> assertFailure ("expected the actual manifest leaf, got " <> show other)
            removed <- posixReleaseManifestEntry (linked </> "tree") identity entry
            expectOccupied "remove a manifest entry through a symbolic root ancestor" removed
    ]

-- The outside namespace is real and remains owned by this temporary fixture.
-- Full immutable observations pin its root/entry identities, modes and bytes.
withLinkedParent :: FilePath -> (FilePath -> FilePath -> IO ()) -> IO ()
withLinkedParent root action = do
    let outside = root </> "outside"
        linked = root </> "linked-parent"
    createDirectory outside
    ByteString.writeFile (outside </> "keep") "outside sentinel"
    createDirectory (outside </> "empty")
    createDirectory (outside </> "tree")
    ByteString.writeFile (outside </> "tree" </> "leaf") "manifest leaf"
    createFileLink outside linked
    before <- posixObserveOwnershipManifest False outside >>= OwnershipFixture.expectRight
    outsideIdentity <- observeExisting outside
    action linked outside
    observeExisting outside >>= (@?= outsideIdentity)
    posixObserveOwnershipManifest False outside >>= (@?= Right before)
    ByteString.readFile (outside </> "keep") >>= (@?= "outside sentinel")

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
    , rowCase "creation and publication" "a file is not created through a symbolic link" $ \root -> do
        let behind = root </> "behind"
            link = root </> "link"
        createFileLink behind link
        onRow (\row -> rowCreateFile row link "payload") >>= expectOccupied "create through a link"
        doesPathExist behind >>= (@?= False)
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
    , rowCase "creation and publication" "a read-only parent makes file creation a probe failure" $ \root ->
        permissionCase "file creation beneath mode 555" $
            withParentMode root 0o555 $ \parent -> do
                created <- onRow (\row -> rowCreateFile row (parent </> "file") "payload")
                expectProbeFailure "create in a read-only parent" created
    , rowCase "creation and publication" "a cross-mount link is a situational probe failure" $ \root ->
        crossMountCase root
    , rowCase "creation and publication" "a missing parent makes file creation a probe failure" $ \root -> do
        created <- onRow (\row -> rowCreateFile row (root </> "missing" </> "file") "payload")
        expectProbeFailure "create beneath a missing parent" created
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
                        contents <- rowReadObject row handle
                        _ <- rowCloseHandle row handle
                        pure contents
        contents @?= Right "the exact payload"
    , rowCase "the exclusive open" "a symbolic link is refused rather than followed" $ \root -> do
        let file = root </> "file"
            link = root </> "link"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        createFileLink file link
        opened <- onRow (\row -> fmap (fmap (const ())) (rowOpenExclusive row link))
        expectOccupied "open a link" opened
    , rowCase "the exclusive open" "a directory is refused rather than opened as a file" $ \root -> do
        let directory = root </> "directory"
        onRow (\row -> rowCreateDirectory row directory) >>= expectOwned "create the directory"
        opened <- onRow (\row -> fmap (fmap (const ())) (rowOpenExclusive row directory))
        expectOccupied "open a directory" opened
    , rowCase "the exclusive open" "a FIFO is refused by the regular-file guard" $ \root -> do
        let fifo = root </> "fifo"
        createFifo fifo
        opened <- onRow (\row -> fmap (fmap (const ())) (rowOpenExclusive row fifo))
        case opened of
            Left (OwnershipOccupied reason) ->
                assertBool "the descriptor reached the regular-file guard" ("is not a regular file" `Text.isInfixOf` reason)
            other -> assertFailure ("expected the regular-file guard, got " <> show other)
    , rowCase "the exclusive open" "the kernel releases the exclusion when the holding process dies" $
        assertOwnershipReleaseOnDeath posixOwnershipRow "--hostbootstrap-ownership-posix-lock-probe"
    ]

-- ---------------------------------------------------------------------------
-- Removal and durability

removalTests :: [TestTree]
removalTests =
    [ rowCase "removal and durability" "a parent directory can be opened and synced after a removal" $ \root -> do
        let file = root </> "file"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        onRow (\row -> rowRemoveObject row file) >>= expectOwned "remove the file"
        onRow (\row -> rowSyncParent row file) >>= expectOwned "sync the parent"
        doesPathExist file >>= (@?= False)
    , rowCase "removal and durability" "a directory is removed" $ \root -> do
        let directory = root </> "directory"
        onRow (\row -> rowCreateDirectory row directory) >>= expectOwned "create the directory"
        onRow (\row -> rowRemoveObject row directory) >>= expectOwned "remove the directory"
        doesPathExist directory >>= (@?= False)
    , rowCase "removal and durability" "a symbolic link standing at the target is refused rather than removed" $ \root -> do
        let file = root </> "file"
            link = root </> "link"
        onRow (\row -> rowCreateFile row file "payload") >>= expectOwned "create the file"
        createFileLink file link
        onRow (\row -> rowRemoveObject row link) >>= expectOccupied "remove a link"
        doesFileExist file >>= (@?= True)
    , rowCase "removal and durability" "removing an object that is not there is a fault rather than a silent success" $ \root -> do
        removed <- onRow (\row -> rowRemoveObject row (root </> "absent"))
        expectProbeFailure "remove an absent object" removed
    ]

-- ---------------------------------------------------------------------------
-- Manifest observations

manifestWalkTests :: [TestTree]
manifestWalkTests =
    [ testCase "the manifest walk has no ambient metadata or link lookup" manifestSourceGuard
    , manifestCase "a held root descriptor observes its tree after pathname replacement" manifestHeldDescriptorCase
    , manifestCase "a link records its target bytes without walking the populated target" $ \root -> do
        let tree = root </> "tree"
            outside = root </> "outside"
        createDirectory tree
        createDirectory outside
        ByteString.writeFile (outside </> "hidden") "not a descendant"
        createFileLink "../outside" (tree </> "link")
        entries <- observedManifestEntries True tree
        map Manifest.manifestEntryPath entries @?= ["link"]
        map Manifest.manifestEntryKind entries @?= [Manifest.ManifestSymbolicLink "../outside"]
    , manifestCase "a group-writable descendant directory is occupied" $ \root -> do
        let path = root </> "directory"
        createDirectory path
        withManifestMode path 0o775 $
            posixObserveOwnershipManifest True root
                >>= (@?= Left (OwnershipOccupied (Text.pack path <> " is group/other writable")))
    , manifestCase "a second hard link prevents exact file admission" $ \root -> do
        let tree = root </> "tree"
            path = tree </> "file"
        createDirectory tree
        ByteString.writeFile path "retained by two names"
        createManifestHardLink path (root </> "retained-link")
        posixObserveOwnershipManifest True tree
            >>= (@?= Left (OwnershipOccupied (Text.pack path <> " is not an exact owned manifest file")))
    , manifestCase "a group-writable manifest root is occupied" $ \root ->
        withManifestMode root 0o775 $
            posixObserveOwnershipManifest True root
                >>= (@?= Left (OwnershipOccupied (Text.pack root <> " is group/other writable")))
    , manifestCase "a group-and-other-writable regular file is occupied" $ \root -> do
        let path = root </> "file"
        ByteString.writeFile path "payload"
        withManifestMode path 0o666 $
            posixObserveOwnershipManifest True root
                >>= (@?= Left (OwnershipOccupied (Text.pack path <> " is not an exact owned manifest file")))
    , manifestCase "a FIFO refuses without opening its blocking stream" $ \root -> do
        let path = root </> "fifo"
        createFifo path
        posixObserveOwnershipManifest True root
            >>= (@?= Left (OwnershipOccupied (Text.pack path <> " has an unsupported manifest object kind")))
    , manifestCase "an immutable file over four MiB refuses its payload bound" $ \root -> do
        let path = root </> "large"
        ByteString.writeFile path (ByteString.replicate (4 * 1024 * 1024 + 1) 120)
        posixObserveOwnershipManifest False root
            >>= (@?= Left (OwnershipUnsupported (Text.pack path <> " exceeds the immutable manifest payload bound")))
    , manifestCase "file directory link and bound socket keep their mutable and immutable kinds" $ \root -> do
        createDirectory (root </> "directory")
        ByteString.writeFile (root </> "file") "payload"
        createFileLink "file" (root </> "link")
        bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
            Socket.bind sock (Socket.SockAddrUnix (root </> "socket"))
            mutable <- observedManifestEntries True root
            immutable <- observedManifestEntries False root
            map manifestPathKind mutable @?= [("directory", 'd'), ("file", 'm'), ("link", 'l'), ("socket", 's')]
            map manifestPathKind immutable @?= [("directory", 'd'), ("file", 'f'), ("link", 'l'), ("socket", 's')]
    ]

manifestSourceGuard :: IO ()
manifestSourceGuard = do
    current <- getCurrentDirectory
    root <- findRepoRoot current >>= maybe (assertFailure "could not find repository root") pure
    source <- readFile (root </> "core" </> "hostbootstrap-core" </> "internal" </> "ownership" </> "HostBootstrap" </> "Ownership" </> "Posix.hs")
    clauses <- mapM
        (\name -> either assertFailure pure (SourceGuard.haskellDefinitionClauseTokens name source))
        ["posixObserveOwnershipManifest", "posixObserveOwnershipManifestAt", "manifestEntryStatusAt", "manifestLinkTargetAt"]
    let tokens = concat (concat clauses)
    mapM_
        (\forbidden -> assertBool ("ambient manifest lookup returned: " <> forbidden) (forbidden `notElem` tokens))
        ["getSymbolicLinkStatus", "readSymbolicLink"]
    mapM_
        (\required -> assertBool ("native descriptor observation is present: " <> required) (required `elem` tokens))
        ["posixObserveOwnershipManifestAt", "c_manifestFstatAt", "c_manifestNoFollow", "c_manifestReadlinkAt"]

#ifndef mingw32_HOST_OS
manifestHeldDescriptorCase :: FilePath -> IO ()
manifestHeldDescriptorCase root = do
    let tree = root </> "tree"
        retained = root </> "retained"
        populate label = do
            createDirectory tree
            createDirectory (tree </> "directory")
            ByteString.writeFile (tree </> "directory" </> "child") label
            ByteString.writeFile (tree </> "file") label
    populate "original objects"
    createFileLink "old-target" (tree </> "link")
    bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \originalSocket -> do
        Socket.bind originalSocket (Socket.SockAddrUnix (tree </> "socket"))
        bracket
            (PosixIO.openFd tree PosixIO.ReadOnly PosixIO.defaultFileFlags{PosixIO.cloexec = True, PosixIO.nofollow = True, PosixIO.directory = True})
            PosixIO.closeFd $ \descriptor -> do
                original <- posixObserveOwnershipManifestAt True tree descriptor
                expected <- either (assertFailure . show) pure original
                length (Manifest.ownershipManifestEntries expected) @?= 5
                renameDirectory tree retained
                populate "replacement objects"
                createFileLink "new-target" (tree </> "link")
                bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \replacementSocket -> do
                    Socket.bind replacementSocket (Socket.SockAddrUnix (tree </> "socket"))
                    posixObserveOwnershipManifestAt True tree descriptor >>= (@?= Right expected)
                    replacement <- posixObserveOwnershipManifest True tree
                    assertBool "the different tree at the former pathname is not the descriptor's namespace" (replacement /= Right expected)
#else
manifestHeldDescriptorCase :: FilePath -> IO ()
manifestHeldDescriptorCase _ = assertFailure "a held POSIX directory needs the declared manifest row"
#endif

manifestPathKind :: Manifest.OwnershipManifestEntry -> (ByteString.ByteString, Char)
manifestPathKind entry = (Manifest.manifestEntryPath entry, tag (Manifest.manifestEntryKind entry))
  where
    tag Manifest.ManifestMutableFile = 'm'
    tag (Manifest.ManifestImmutableFile _) = 'f'
    tag Manifest.ManifestDirectory = 'd'
    tag (Manifest.ManifestSymbolicLink _) = 'l'
    tag Manifest.ManifestSocket = 's'

observedManifestEntries :: Bool -> FilePath -> IO [Manifest.OwnershipManifestEntry]
observedManifestEntries mutable root = do
    observed <- posixObserveOwnershipManifest mutable root
    case observed of
        Left fault -> assertFailure ("expected a kernel manifest, got " <> show fault)
        Right value -> pure (Manifest.ownershipManifestEntries value)

manifestCase :: TestName -> (FilePath -> IO ()) -> TestTree
manifestCase name body =
    conditionalCase
        ["OwnershipPosixSpec", "manifest walk"]
        posixOwnershipSupported
        name
        (withSystemTempDirectory "hb-manifest" body)
        (withSystemTempDirectory "hb-manifest" expectManifestRefusal)

expectManifestRefusal :: FilePath -> IO ()
expectManifestRefusal root = do
    let refused = Left (OwnershipUnsupported "the POSIX ownership manifest row is unavailable on this host")
    posixObserveOwnershipManifest True root >>= (@?= refused)
    posixObserveOwnershipManifestAt True root (Fd (-1)) >>= (@?= refused)
    identity <- either (assertFailure . show) pure (OwnershipFixture.kernelIdentityWords 1 2)
    entry <- either (assertFailure . show) pure (Manifest.mutableManifestEntry "entry" identity 0o600)
    posixReleaseManifestEntry root identity entry >>= (@?= refused)


-- The root is created and identity-bound through the real selected kernel row.
-- No test manufactures a Bound token or supplies substitute primitives.
withBoundManifestRoot :: FilePath -> (forall session object. FilePath -> Bound session object -> IO ()) -> IO ()
withBoundManifestRoot fixture use = do
    store <- openProtectedStore (fixture </> "state") >>= OwnershipFixture.expectRight
    key <- OwnershipFixture.expectRight (mkRecordKey "manifest-root")
    held <- withProtectedEntry store $ \session -> do
        let tree = fixture </> "tree"
            tape = recordTape session (RecordSubject "manifest root origin" "manifest root binding")
        result <- enterOwnedObject ownershipRowForHost session tree $ \entered -> do
            recorded <- recordOwnedOrigin ownershipRowForHost entered OwnedDirectory (publishFreshRecord tape key)
                >>= OwnershipFixture.expectRight
            identity <- createOwnedDirectory ownershipRowForHost recorded >>= OwnershipFixture.expectRight
            bound <- bindOwnedIdentity ownershipRowForHost recorded identity (publishBoundRecord tape key)
                >>= OwnershipFixture.expectRight
            use tree bound
            pure (Right ())
        OwnershipFixture.expectRight result
        pure (Right ())
    OwnershipFixture.expectRight held

retainedManifestEntry :: FilePath -> ByteString.ByteString -> IO Manifest.OwnershipManifestEntry
retainedManifestEntry tree path = do
    entries <- observedManifestEntries True tree
    case filter ((== path) . Manifest.manifestEntryPath) entries of
        [entry] -> pure entry
        _ -> assertFailure "the actual retained manifest does not name exactly one entry"

manifestRemainderTests :: [TestTree]
manifestRemainderTests =
    [ remainderCase "an exact entry removes once and its absence permits a repeat" $ \fixture ->
        withBoundManifestRoot fixture $ \tree bound -> do
            ByteString.writeFile (tree </> "file") "owned bytes"
            entry <- retainedManifestEntry tree "file"
            releaseManifestRemainder bound entry >>= (@?= Right ())
            releaseManifestRemainder bound entry >>= (@?= Right ())
            observedManifestEntries True tree >>= (@?= [])
            doesDirectoryExist tree >>= (@?= True)
    , remainderCase "an absent leaf leaves the retained root unchanged" $ \fixture ->
        withBoundManifestRoot fixture $ \tree bound -> do
            ByteString.writeFile (tree </> "file") "owned bytes"
            entry <- retainedManifestEntry tree "file"
            removeFile (tree </> "file")
            before <- onRow (\row -> rowObserveIdentity row tree)
            releaseManifestRemainder bound entry >>= (@?= Right ())
            onRow (\row -> rowObserveIdentity row tree) >>= (@?= before)
            observedManifestEntries True tree >>= (@?= [])
    , remainderCase "an absent intermediate directory is an absent descendant" $ \fixture ->
        withBoundManifestRoot fixture $ \tree bound -> do
            createDirectory (tree </> "directory")
            ByteString.writeFile (tree </> "directory" </> "file") "owned bytes"
            entry <- retainedManifestEntry tree "directory/file"
            removeFile (tree </> "directory" </> "file")
            removeDirectory (tree </> "directory")
            before <- onRow (\row -> rowObserveIdentity row tree)
            releaseManifestRemainder bound entry >>= (@?= Right ())
            onRow (\row -> rowObserveIdentity row tree) >>= (@?= before)
            observedManifestEntries True tree >>= (@?= [])
    , remainderCase "a replacement entry retains its actual inode and bytes" $ \fixture ->
        withBoundManifestRoot fixture $ \tree bound -> do
            ByteString.writeFile (tree </> "file") "original bytes"
            entry <- retainedManifestEntry tree "file"
            renameFile (tree </> "file") (fixture </> "parked-file")
            ByteString.writeFile (tree </> "file") "replacement bytes"
            replacement <- retainedManifestEntry tree "file"
            assertBool "both live files have distinct identities"
                (Manifest.manifestEntryIdentity entry /= Manifest.manifestEntryIdentity replacement)
            releaseManifestRemainder bound entry >>= expectOccupied "replacement manifest remainder"
            retainedManifestEntry tree "file" >>= (@?= replacement)
            ByteString.readFile (tree </> "file") >>= (@?= "replacement bytes")
            ByteString.readFile (fixture </> "parked-file") >>= (@?= "original bytes")
    , remainderCase "a missing root refuses rather than becoming descendant absence" $ \fixture ->
        withBoundManifestRoot fixture $ \tree bound -> do
            ByteString.writeFile (tree </> "file") "owned bytes"
            entry <- retainedManifestEntry tree "file"
            renameDirectory tree (fixture </> "parked-tree")
            result <- releaseManifestRemainder bound entry
            case result of
                Left (OwnershipConflict _) -> pure ()
                other -> assertFailure ("expected missing-root conflict, got " <> show other)
            doesPathExist tree >>= (@?= False)
            ByteString.readFile (fixture </> "parked-tree" </> "file") >>= (@?= "owned bytes")
    , remainderCase "a replacement root preserves both actual directories" $ \fixture ->
        withBoundManifestRoot fixture $ \tree bound -> do
            ByteString.writeFile (tree </> "file") "owned bytes"
            entry <- retainedManifestEntry tree "file"
            renameDirectory tree (fixture </> "parked-tree")
            createDirectory tree
            ByteString.writeFile (tree </> "file") "foreign bytes"
            before <- observedManifestEntries True tree
            result <- releaseManifestRemainder bound entry
            case result of
                Left (OwnershipConflict _) -> pure ()
                other -> assertFailure ("expected replacement-root conflict, got " <> show other)
            observedManifestEntries True tree >>= (@?= before)
            ByteString.readFile (tree </> "file") >>= (@?= "foreign bytes")
            ByteString.readFile (fixture </> "parked-tree" </> "file") >>= (@?= "owned bytes")
    , remainderCase "a symbolic intermediate parent cannot reach its target" $ \fixture ->
        withBoundManifestRoot fixture $ \tree bound -> do
            createDirectory (tree </> "directory")
            ByteString.writeFile (tree </> "directory" </> "file") "owned bytes"
            entry <- retainedManifestEntry tree "directory/file"
            renameDirectory (tree </> "directory") (fixture </> "parked-directory")
            createFileLink (fixture </> "parked-directory") (tree </> "directory")
            before <- observedManifestEntries True tree
            releaseManifestRemainder bound entry >>= expectOccupied "symbolic remainder parent"
            observedManifestEntries True tree >>= (@?= before)
            ByteString.readFile (fixture </> "parked-directory" </> "file") >>= (@?= "owned bytes")
    , remainderCase "the bound-root producer removes a non-UTF-8 raw entry" remainderRawNameCase
    , remainderCase "an escaped release action refuses after its protected entry exits" $ \fixture -> do
        saved <- newIORef Nothing
        withBoundManifestRoot fixture $ \tree bound -> do
            ByteString.writeFile (tree </> "file") "owned bytes"
            entry <- retainedManifestEntry tree "file"
            writeIORef saved (Just (releaseManifestRemainder bound entry))
        action <- readIORef saved >>= maybe (assertFailure "no retained release action") pure
        action >>= expectProbeFailure "expired remainder release"
        ByteString.readFile (fixture </> "tree" </> "file") >>= (@?= "owned bytes")
    , testCase "the private producer checks both clauses before native effects" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            source <- readFile (packageRoot </> "internal" </> "ownership" </> "HostBootstrap" </> "Ownership" </> "Remainder.hs")
            description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
            exposed <- OwnershipFixture.expectRight (SourceGuard.effectiveMainExposedModules description)
            let remainderModule = "HostBootstrap.Ownership.Remainder"
            assertBool "the composition is not a main-library reexport" (notElem remainderModule exposed)
            private <- maybe (assertFailure "the private ownership library is absent") pure
                (SourceGuard.namedStanza "library ownership-internal" description)
            assertBool "the private ownership library exposes the composition internally"
                (elem remainderModule (SourceGuard.fieldModules "exposed-modules" private))
            expected <- maybe (assertFailure "the private export pin is absent") pure
                (lookup remainderModule pinnedPrivateExportLists)
            SourceGuard.moduleExportTokens remainderModule source @?= Just (SourceGuard.haskellTokens expected)
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "releaseManifestRemainder" source)
            let before = takeWhile (/= "reobserveOwnedIdentity") tokens
            for_ ["clauseRefusal", "ClauseRelease", "ClauseRecord", "rowCapabilities"] $ \name ->
                assertBool ("the actual producer checks " <> name <> " before IO") (elem name before)
            length (filter (== "clauseRefusal") before) @?= 2
            for_ ["reobserveOwnedIdentity", "releasableEvidence", "originRecordKind",
                  "OwnedDirectory", "originRecordOrigin", "OriginAbsent", "posixReleaseManifestEntry"] $ \name ->
                assertBool ("the bound-root release retains " <> name) (elem name tokens)
            SourceGuard.countHaskellIdentifier "recordReportedOrigin" source @?= 0
    ]

remainderCase :: TestName -> (FilePath -> IO ()) -> TestTree
remainderCase name body =
    conditionalCase ["OwnershipPosixSpec", "manifest remainder"] posixOwnershipSupported name
        (withSystemTempDirectory "hb-remainder" body)
        (withSystemTempDirectory "hb-remainder" expectManifestRefusal)

#ifndef mingw32_HOST_OS
remainderRawNameCase :: FilePath -> IO ()
remainderRawNameCase fixture =
    withBoundManifestRoot fixture $ \tree bound -> do
        withRawRoot tree $ \rawRoot ->
            writeRawFile (rawRoot <> "/" <> ByteString.singleton 255) "raw bytes"
        entry <- retainedManifestEntry tree (ByteString.singleton 255)
        releaseManifestRemainder bound entry >>= (@?= Right ())
        observedManifestEntries True tree >>= (@?= [])
#else
remainderRawNameCase :: FilePath -> IO ()
remainderRawNameCase _ = assertFailure "raw remainder release needs the declared POSIX row"
#endif

rawManifestTests :: [TestTree]
rawManifestTests =
    [ testCase "a non-UTF-8 path round trips as the same manifest bytes" $ do
        identity <- either (assertFailure . show) pure (OwnershipFixture.kernelIdentityWords 1 2)
        entry <- either (assertFailure . show) pure (Manifest.mutableManifestEntry (ByteString.singleton 255) identity 0o600)
        value <- either (assertFailure . show) pure (Manifest.mkOwnershipManifest [entry])
        let rendered = Manifest.renderOwnershipManifest value
        Manifest.parseOwnershipManifest rendered @?= Right value
        map Manifest.manifestEntryPath (Manifest.ownershipManifestEntries value) @?= [ByteString.singleton 255]
        assertBool "the path byte is hex ff, without UTF-8 replacement" ("m ff " `ByteString.isInfixOf` rendered)
    , testCase "relative path grammar is POSIX bytes on every gate host" $ do
        identity <- either (assertFailure . show) pure (OwnershipFixture.kernelIdentityWords 1 2)
        mapM_
            (\path -> Manifest.mutableManifestEntry path identity 0o600
                @?= Left (OwnershipMalformed "an ownership manifest path is not canonical and relative"))
            ["", "/", "/x", "../x", "x/../y", "./x", "x/", "x//y", "x\0y", "x\ry", "x\ny"]
        mapM_
            (\path -> do
                entry <- either (assertFailure . show) pure (Manifest.mutableManifestEntry path identity 0o600)
                Manifest.manifestEntryPath entry @?= path)
            ["profile/colima.yaml", ByteString.singleton 255, "directory/" <> ByteString.singleton 255, "C:\\relative"]
    , rawManifestCase "one raw tree renders identically under ASCII and UTF-8 child filesystem locales" rawManifestLocaleCase
    , rawManifestCase "raw-name cleanup removes exact files directories links and sockets" rawManifestRemovalCase
    , rawManifestCase "raw-name cleanup preserves a replacement target identity" rawManifestTargetReplacementCase
    , rawManifestCase "raw-name cleanup preserves a replacement root identity" rawManifestRootReplacementCase
    , rawManifestCase "raw-name cleanup refuses a symbolic parent component" rawManifestSymbolicParentCase
    ]

rawManifestCase :: TestName -> (FilePath -> IO ()) -> TestTree
rawManifestCase name body =
    conditionalCase ["OwnershipPosixSpec", "raw manifest bytes"] posixOwnershipSupported name
        (withSystemTempDirectory "hb-raw" body)
        (withSystemTempDirectory "hb-raw" expectManifestRefusal)

runOwnershipManifestLocaleProbe :: FilePath -> IO ()
runOwnershipManifestLocaleProbe root = do
    observed <- posixObserveOwnershipManifest False root
    case observed of
        Left fault -> ioError (userError (show fault))
        Right value -> do
            encoding <- getFileSystemEncoding
            hPutStrLn stderr ("filesystem-encoding: " <> show encoding)
            ByteString.putStr (Manifest.renderOwnershipManifest value)

#ifndef mingw32_HOST_OS
withRawRoot :: FilePath -> (ByteString.ByteString -> IO value) -> IO value
withRawRoot root action = withFilePath root $ \native -> ByteString.packCString native >>= action

writeRawFile :: ByteString.ByteString -> ByteString.ByteString -> IO ()
writeRawFile path bytes =
    bracket
        (RawIO.openFd path PosixIO.ReadWrite PosixIO.defaultFileFlags{PosixIO.creat = Just 0o600, PosixIO.exclusive = True, PosixIO.cloexec = True, PosixIO.nofollow = True})
        PosixIO.closeFd (\fd -> writeAll fd bytes)
  where
    writeAll fd remaining
        | ByteString.null remaining = pure ()
        | otherwise = do
            count <- RawIO.fdWrite fd remaining
            assertBool "raw fixture writes make progress" (count > 0)
            writeAll fd (ByteString.drop (fromIntegral count) remaining)

populateRawManifest :: FilePath -> IO ()
populateRawManifest root = withRawRoot root $ \rawRoot -> do
    writeRawFile (rawRoot <> "/" <> ByteString.singleton 255) "payload"
    RawDirectory.createDirectory (rawRoot <> "/" <> ByteString.singleton 254) 0o700
    writeRawFile (rawRoot <> "/" <> ByteString.pack [254, 47, 255]) "nested payload"
    RawFiles.createSymbolicLink (ByteString.pack [99, 97, 102, 195, 169]) (rawRoot <> "/link")

rawManifestLocaleCase :: FilePath -> IO ()
rawManifestLocaleCase root = do
    populateRawManifest root
    self <- getExecutablePath
    inherited <- getEnvironment
    let observe locale = do
            let child = (proc self ["--hostbootstrap-ownership-manifest-locale-probe", root])
                    {env = Just (("LC_ALL", locale) : filter ((`notElem` ["LC_ALL", "GHC_CHARENC"]) . fst) inherited)}
            (exit, output, errors) <- readCreateProcessWithExitCode child ""
            exit @?= ExitSuccess
            value <- either (assertFailure . show) pure (Manifest.parseOwnershipManifest (ByteString.Char8.pack output))
            pure (value, errors)
        findUtf8 [] = assertFailure "this gate host offers no UTF-8 filesystem locale"
        findUtf8 (locale : remaining) = do
            (value, report) <- observe locale
            if report == "filesystem-encoding: UTF-8\n"
                then pure (locale, value)
                else findUtf8 remaining
    (utf8Locale, utf8) <- findUtf8 ["C.UTF-8", "en_US.UTF-8", "UTF-8"]
    (ascii, asciiReport) <- observe "C"
    assertBool "the C child really uses an ASCII filesystem encoding"
        (asciiReport `elem` ["filesystem-encoding: ASCII\n", "filesystem-encoding: US-ASCII\n", "filesystem-encoding: ANSI_X3.4-1968\n"])
    putStrLn ("ownership-manifest: filesystem encodings " <> utf8Locale <> "=UTF-8, C=ASCII")
    Manifest.renderOwnershipManifest utf8 @?= Manifest.renderOwnershipManifest ascii
    let entries = Manifest.ownershipManifestEntries utf8
    assertBool "the actual byte-ff file survives" (ByteString.singleton 255 `elem` map Manifest.manifestEntryPath entries)
    case find ((== "link") . Manifest.manifestEntryPath) entries of
        Just entry -> Manifest.manifestEntryKind entry @?= Manifest.ManifestSymbolicLink (ByteString.pack [99, 97, 102, 195, 169])
        Nothing -> assertFailure "the raw link observation is absent"

rawManifestRemovalCase :: FilePath -> IO ()
rawManifestRemovalCase root = do
    populateRawManifest root
    bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
        Socket.bind sock (Socket.SockAddrUnix (root </> "socket"))
        identity <- observeExisting root
        entries <- observedManifestEntries True root
        length entries @?= 5
        mapM_ (\entry -> posixReleaseManifestEntry root identity entry >>= (@?= Right ()))
            (sortOn (Down . ByteString.count 47 . Manifest.manifestEntryPath) entries)
        observedManifestEntries True root >>= (@?= [])

rawManifestTargetReplacementCase :: FilePath -> IO ()
rawManifestTargetReplacementCase root = withRawRoot root $ \rawRoot -> do
    let path = rawRoot <> "/" <> ByteString.singleton 255
    writeRawFile path "original"
    identity <- observeExisting root
    entries <- observedManifestEntries True root
    original <- case entries of
        [entry] -> pure entry
        other -> assertFailure ("expected one raw entry, got " <> show other)
    RawFiles.rename path (rawRoot <> "/retained")
    writeRawFile path "replacement"
    before <- posixObserveOwnershipManifest False root >>= either (assertFailure . show) pure
    posixReleaseManifestEntry root identity original
        >>= (@?= Left (OwnershipOccupied (Text.pack (root </> "\\xff") <> " changed before manifest removal")))
    posixObserveOwnershipManifest False root >>= (@?= Right before)
    current <- observedManifestEntries True root
    length current @?= 2
    replacement <- maybe (assertFailure "replacement is absent") pure (find ((== ByteString.singleton 255) . Manifest.manifestEntryPath) current)
    assertBool "the live retained original prevents inode reuse" (Manifest.manifestEntryIdentity replacement /= Manifest.manifestEntryIdentity original)

rawManifestRootReplacementCase :: FilePath -> IO ()
rawManifestRootReplacementCase root = do
    let tree = root </> "tree"
        retained = root </> "retained"
    createDirectory tree
    withRawRoot tree $ \raw -> writeRawFile (raw <> "/" <> ByteString.singleton 255) "original"
    identity <- observeExisting tree
    [original] <- observedManifestEntries True tree
    renameDirectory tree retained
    createDirectory tree
    withRawRoot tree $ \raw -> writeRawFile (raw <> "/" <> ByteString.singleton 255) "replacement"
    replacementRoot <- observeExisting tree
    before <- posixObserveOwnershipManifest False tree >>= either (assertFailure . show) pure
    posixReleaseManifestEntry tree identity original
        >>= (@?= Left (OwnershipOccupied (Text.pack (tree </> "\\xff") <> " changed before manifest removal")))
    observeExisting tree >>= (@?= replacementRoot)
    observeExisting retained >>= (@?= identity)
    posixObserveOwnershipManifest False tree >>= (@?= Right before)
    originalEntries <- observedManifestEntries True retained
    replacementEntries <- observedManifestEntries True tree
    length originalEntries @?= 1
    length replacementEntries @?= 1
    assertBool "the replacement root is distinct and retained" (replacementEntries /= originalEntries)

rawManifestSymbolicParentCase :: FilePath -> IO ()
rawManifestSymbolicParentCase root = do
    let tree = root </> "tree"
        directory = tree </> "directory"
        retained = root </> "retained"
    createDirectory tree
    createDirectory directory
    ByteString.writeFile (directory </> "file") "original"
    identity <- observeExisting tree
    entries <- observedManifestEntries True tree
    entry <- maybe (assertFailure "nested entry is absent") pure (find ((== "directory/file") . Manifest.manifestEntryPath) entries)
    renameDirectory directory retained
    createFileLink retained directory
    refused <- posixReleaseManifestEntry tree identity entry
    expectOccupied "remove through a symbolic parent" refused
    ByteString.readFile (retained </> "file") >>= (@?= "original")
#else
rawManifestLocaleCase, rawManifestRemovalCase, rawManifestTargetReplacementCase, rawManifestRootReplacementCase, rawManifestSymbolicParentCase :: FilePath -> IO ()
rawManifestLocaleCase _ = assertFailure "raw manifest observations need the declared POSIX row"
rawManifestRemovalCase _ = assertFailure "raw manifest removal needs the declared POSIX row"
rawManifestTargetReplacementCase _ = assertFailure "raw manifest replacement needs the declared POSIX row"
rawManifestRootReplacementCase _ = assertFailure "raw manifest root replacement needs the declared POSIX row"
rawManifestSymbolicParentCase _ = assertFailure "raw manifest traversal needs the declared POSIX row"
#endif

-- The cached capability comes from an actual owner change in a private fixture.
-- Effective UID alone cannot establish that a confined root process has it.
{-# NOINLINE foreignManifestOwnerSupported #-}
foreignManifestOwnerSupported :: Bool
#ifndef mingw32_HOST_OS
foreignManifestOwnerSupported = unsafePerformIO $
    withSystemTempDirectory "hb-manifest-owner" $ \root -> do
        uid <- getEffectiveUserID
        let path = root </> "probe"
            foreignUid = if uid == 0 then 1 else 0
        ByteString.writeFile path "ownership capability"
        attempted <- try (setOwnerAndGroup path foreignUid (-1))
        case (attempted :: Either IOException ()) of
            Right () -> pure True
            Left failure
                | isPermissionError failure -> pure False
                | otherwise -> ioError failure
#else
foreignManifestOwnerSupported = False
#endif

foreignManifestOwnerTest :: TestTree
foreignManifestOwnerTest =
    conditionalCase
        ["OwnershipPosixSpec", "foreign manifest owner"]
        foreignManifestOwnerSupported
        "a foreign-owned manifest descendant is occupied when this host can arrange its owner"
        (withSystemTempDirectory "hb-manifest" foreignManifestOwnerCase)
        (withSystemTempDirectory "hb-manifest" foreignManifestOwnerRefusal)

#ifndef mingw32_HOST_OS
foreignManifestOwnerCase :: FilePath -> IO ()
foreignManifestOwnerCase root = do
    uid <- getEffectiveUserID
    let path = root </> "foreign"
        foreignUid = if uid == 0 then 1 else 0
    ByteString.writeFile path "foreign owned"
    setOwnerAndGroup path foreignUid (-1)
    getFileStatus path >>= ((@?= foreignUid) . fileOwner)
    posixObserveOwnershipManifest True root
        >>= (@?= Left (OwnershipOccupied (Text.pack path <> " has a foreign owner")))
    putStrLn "ownership-manifest: foreign-owner refusal exercised"

foreignManifestOwnerRefusal :: FilePath -> IO ()
foreignManifestOwnerRefusal root = do
    uid <- getEffectiveUserID
    let path = root </> "own-file"
        foreignUid = if uid == 0 then 1 else 0
    ByteString.writeFile path "retains the current owner"
    attempted <- try (setOwnerAndGroup path foreignUid (-1))
    case (attempted :: Either IOException ()) of
        Left failure -> assertBool "the real owner change is denied" (isPermissionError failure)
        Right () -> assertFailure "foreign-owner availability failed to describe this host"
    putStrLn "ownership-manifest: foreign-owner subject unavailable; owner change denied"

withManifestMode :: FilePath -> Int -> IO () -> IO ()
withManifestMode path mode action = do
    status <- getFileStatus path
    bracket_ (setFileMode path (fromIntegral mode)) (setFileMode path (fileMode status)) action

createManifestHardLink :: FilePath -> FilePath -> IO ()
createManifestHardLink = createLink
#else
foreignManifestOwnerCase :: FilePath -> IO ()
foreignManifestOwnerCase _ = assertFailure "a foreign owner needs the declared POSIX manifest row"

foreignManifestOwnerRefusal :: FilePath -> IO ()
foreignManifestOwnerRefusal = expectManifestRefusal

withManifestMode :: FilePath -> Int -> IO () -> IO ()
withManifestMode _ _ _ = assertFailure "manifest modes need the declared POSIX manifest row"

createManifestHardLink :: FilePath -> FilePath -> IO ()
createManifestHardLink _ _ = assertFailure "manifest hard links need the declared POSIX manifest row"
#endif

-- ---------------------------------------------------------------------------
-- The re-invocation route

{- | Hold the row's exclusive open on one object, and then block until killed.

The handle is deliberately dropped rather than closed: a raw descriptor has no
finalizer, so nothing in this process can release the lock and the parent's
successful re-open is evidence about the kernel.
-}
runOwnershipPosixLockProbe :: FilePath -> FilePath -> IO ()
runOwnershipPosixLockProbe = runOwnershipLockProbe posixOwnershipRow

-- ---------------------------------------------------------------------------
-- Helpers

{- | One case that drives the POSIX row against the kernel.

Where the row can be held the body runs, so the case is evidence about a real
syscall. Elsewhere the case stays and asserts the refusal the row declares.
-}
rowCase :: TestName -> TestName -> (FilePath -> IO ()) -> TestTree
rowCase family name body =
    conditionalCase
        ["OwnershipPosixSpec", family]
        posixOwnershipSupported
        name
        (withSystemTempDirectory "hostbootstrap-ownership-posix" body)
        (withSystemTempDirectory "hostbootstrap-ownership-posix" expectRowRefusal)

{- | The disposition the POSIX row owes a caller on a host that is not POSIX.

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


#ifndef mingw32_HOST_OS
createFifo :: FilePath -> IO ()
createFifo path = createNamedPipe path 0o600

permissionCase :: String -> IO () -> IO ()
permissionCase label action = do
    uid <- getEffectiveUserID
    if uid == 0
        then putStrLn ("SKIP " <> label <> ": root bypasses mode-based access checks")
        else action

withParentMode :: FilePath -> Int -> (FilePath -> IO ()) -> IO ()
withParentMode root mode action = do
    let parent = root </> "restricted"
    onRow (\row -> rowCreateDirectory row parent) >>= expectOwned "create the parent"
    bracket_ (setFileMode parent (fromIntegral mode)) (setFileMode parent 0o700) (action parent)

crossMountCase :: FilePath -> IO ()
crossMountCase root = do
    available <- doesDirectoryExist "/dev/shm"
    if not available
        then putStrLn "SKIP cross-mount publication: /dev/shm is unavailable"
        else do
            local <- getFileStatus root
            remote <- getFileStatus "/dev/shm"
            if deviceID local == deviceID remote
                then putStrLn "SKIP cross-mount publication: /dev/shm shares the temporary directory's mount"
                else withTempDirectory "/dev/shm" "hostbootstrap-link" $ \other -> do
                    let staged = root </> "staged"
                        target = other </> "target"
                    onRow (\row -> rowCreateFile row staged "payload") >>= expectOwned "stage the cross-mount file"
                    linked <- onRow (\row -> rowLinkNoReplace row staged target)
                    expectProbeFailure "publish across mounts" linked
                    doesPathExist target >>= (@?= False)
                    ByteString.readFile staged >>= (@?= "payload")
#else
createFifo :: FilePath -> IO ()
createFifo _ = assertFailure "FIFO creation requires the declared POSIX row"

permissionCase :: String -> IO () -> IO ()
permissionCase _ _ = assertFailure "mode checks require the declared POSIX row"

withParentMode :: FilePath -> Int -> (FilePath -> IO ()) -> IO ()
withParentMode _ _ _ = assertFailure "mode changes require the declared POSIX row"

crossMountCase :: FilePath -> IO ()
crossMountCase _ = assertFailure "cross-mount linking requires the declared POSIX row"
#endif

-- | Run one continuation against the POSIX row's primitives.
onRow :: (forall handle. OwnershipPrimitive handle -> IO result) -> IO result
onRow = withOwnershipRow posixOwnershipRow

observeExisting :: FilePath -> IO ObjectIdentity
observeExisting target = do
    observed <- onRow (\row -> rowObserveIdentity row target)
    case observed of
        Right (Just identity) -> pure identity
        other -> assertFailure ("expected an identity at " <> target <> ", got " <> show other)

expectUnsupported :: (Show value) => String -> Either OwnershipFault value -> IO ()
expectUnsupported label outcome = case outcome of
    Left (OwnershipUnsupported _) -> pure ()
    other ->
        assertFailure
            ("the row must refuse to " <> label <> " on this host, got " <> show other)
