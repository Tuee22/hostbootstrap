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
module OwnershipPosixSpec (tests, runOwnershipPosixLockProbe) where

import Control.Concurrent (threadDelay)
import qualified Data.ByteString as ByteString
import HostBootstrap.Ownership.Object
    ( ObjectIdentity
    , OwnershipFault (OwnershipUnsupported)
    )
import HostBootstrap.Ownership.Posix
    ( posixOwnershipCapabilities
    , posixOwnershipRow
    , posixOwnershipSupported
    )
import HostBootstrap.Ownership.Primitive
    ( OwnershipCapabilities (OwnershipCapabilities)
    , OwnershipPrimitive
        ( rowCloseHandle
        , rowCreateDirectory
        , rowCreateFile
        , rowObserveIdentity
        , rowOpenExclusive
        , rowLinkNoReplace
        , rowReadObject
        , rowRemoveObject
        , rowSyncParent
        )
    , withOwnershipRow
    )
import System.Directory (createFileLink, doesFileExist, doesPathExist)
import System.Environment (getExecutablePath)
import System.FilePath ((</>))
import System.Info (os)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (spawnProcess, terminateProcess, waitForProcess)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "OwnershipPosixSpec"
        [ testGroup "the row's declaration" declarationTests
        , testGroup "identity" identityTests
        , testGroup "creation and publication" publicationTests
        , testGroup "the exclusive open" exclusionTests
        , testGroup "removal and durability" removalTests
        ]

-- ---------------------------------------------------------------------------
-- The declaration

declarationTests :: [TestTree]
declarationTests =
    [ testCase "the row's own declaration agrees with the gate host" $
        posixOwnershipSupported @?= (os /= "mingw32")
    , testCase "the row holds every clause together or none of them" $
        -- The four primitives are one kernel's, so a host that supplies some of
        -- them and not others is not a state this row reports: it would leave a
        -- clause held by a row that declares it cannot hold the transaction.
        posixOwnershipCapabilities
            @?= OwnershipCapabilities
                posixOwnershipSupported
                posixOwnershipSupported
                posixOwnershipSupported
                posixOwnershipSupported
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
        -- @link(2)@ publishes a second name for the same object, which is what
        -- makes clause 3's binding survive publication: the identity the
        -- transaction read is the identity release will re-observe.
        targetIdentity @?= stagedIdentity
    , rowCase "a symbolic link reads its own identity rather than its target's" $ \root -> do
        let file = root </> "file"
            link = root </> "link"
        onRow (\row -> rowCreateFile row file "payload") >>= expectRight "create the file"
        createFileLink file link
        fileIdentity <- observeExisting file
        linkIdentity <- observeExisting link
        assertBool
            "a link is a different object, so it does not read as its target"
            (fileIdentity /= linkIdentity)
    , rowCase "a probe that cannot answer is a fault rather than an absence" $ \root -> do
        let file = root </> "file"
        onRow (\row -> rowCreateFile row file "payload") >>= expectRight "create the file"
        observed <- onRow (\row -> rowObserveIdentity row (file </> "beneath"))
        case observed of
            Left _ -> pure ()
            Right answer ->
                assertFailure
                    ("a probe that could not answer must not report an absence: " <> show answer)
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
    , rowCase "a file is not created through a symbolic link" $ \root -> do
        let behind = root </> "behind"
            link = root </> "link"
        createFileLink behind link
        onRow (\row -> rowCreateFile row link "payload") >>= expectOccupied "create through a link"
        doesPathExist behind >>= (@?= False)
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
                        contents <- rowReadObject row handle
                        _ <- rowCloseHandle row handle
                        pure contents
        contents @?= Right "the exact payload"
    , rowCase "a symbolic link is refused rather than followed" $ \root -> do
        let file = root </> "file"
            link = root </> "link"
        onRow (\row -> rowCreateFile row file "payload") >>= expectRight "create the file"
        createFileLink file link
        opened <- onRow (\row -> fmap (fmap (const ())) (rowOpenExclusive row link))
        expectOccupied "open a link" opened
    , rowCase "a directory is refused rather than opened as a file" $ \root -> do
        let directory = root </> "directory"
        onRow (\row -> rowCreateDirectory row directory) >>= expectRight "create the directory"
        opened <- onRow (\row -> fmap (fmap (const ())) (rowOpenExclusive row directory))
        expectOccupied "open a directory" opened
    , rowCase "the kernel releases the exclusion when the holding process dies" $ \root -> do
        let file = root </> "file"
            readyPath = root </> "ready"
        onRow (\row -> rowCreateFile row file "payload") >>= expectRight "create the file"
        self <- getExecutablePath
        -- A real process, holding the row's own exclusive open and then killed.
        -- The probe never closes the handle, and a raw descriptor carries no
        -- finalizer, so the only thing that can release this lock is the
        -- process ending — which is exactly the property clause 1 rests on.
        probe <- spawnProcess self ["--hostbootstrap-ownership-posix-lock-probe", file, readyPath]
        awaitFile readyPath
        contended <- onRow (\row -> fmap (fmap (const ())) (rowOpenExclusive row file))
        expectOccupied "open against a live holder" contended
        terminateProcess probe
        _ <- waitForProcess probe
        released <- awaitExclusiveOpen file
        released @?= Right ()
    ]

-- ---------------------------------------------------------------------------
-- Removal and durability

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
    , rowCase "a symbolic link standing at the target is refused rather than removed" $ \root -> do
        let file = root </> "file"
            link = root </> "link"
        onRow (\row -> rowCreateFile row file "payload") >>= expectRight "create the file"
        createFileLink file link
        onRow (\row -> rowRemoveObject row link) >>= expectOccupied "remove a link"
        doesFileExist file >>= (@?= True)
    , rowCase "removing an object that is not there is a fault rather than a silent success" $ \root -> do
        removed <- onRow (\row -> rowRemoveObject row (root </> "absent"))
        case removed of
            Left _ -> pure ()
            Right () -> assertFailure "removing nothing must not report a removal"
    ]

-- ---------------------------------------------------------------------------
-- The re-invocation route

{- | Hold the row's exclusive open on one object, and then block until killed.

The handle is deliberately dropped rather than closed: a raw descriptor has no
finalizer, so nothing in this process can release the lock and the parent's
successful re-open is evidence about the kernel.
-}
runOwnershipPosixLockProbe :: FilePath -> FilePath -> IO ()
runOwnershipPosixLockProbe target readyPath = do
    opened <- onRow (\row -> fmap (fmap (const ())) (rowOpenExclusive row target))
    case opened of
        Left fault -> fail ("the probe could not hold the object: " <> show fault)
        Right () -> do
            writeFile readyPath "held"
            blockForever
  where
    blockForever = threadDelay 60000000 >> blockForever

-- ---------------------------------------------------------------------------
-- Helpers

{- | One case that drives the POSIX row against the kernel.

Where the row can be held the body runs, so the case is evidence about a real
syscall. Elsewhere the case stays and asserts the refusal the row declares.
-}
rowCase :: TestName -> (FilePath -> IO ()) -> TestTree
rowCase name body =
    testCase name $
        withSystemTempDirectory "hostbootstrap-ownership-posix" $ \root ->
            if posixOwnershipSupported
                then body root
                else expectRowRefusal root

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

-- | Run one continuation against the POSIX row's primitives.
onRow :: (forall handle. OwnershipPrimitive handle -> IO result) -> IO result
onRow = withOwnershipRow posixOwnershipRow

observeExisting :: FilePath -> IO ObjectIdentity
observeExisting target = do
    observed <- onRow (\row -> rowObserveIdentity row target)
    case observed of
        Right (Just identity) -> pure identity
        other -> assertFailure ("expected an identity at " <> target <> ", got " <> show other)

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

{- | Wait for the probe to say it holds the object.

Polling rather than a signal, because the fact under test is a kernel lock and
adding a second synchronisation primitive would only give the case another way
to be wrong.
-}
awaitFile :: FilePath -> IO ()
awaitFile path = go (600 :: Int)
  where
    go 0 = assertFailure ("the probe never reported holding " <> path)
    go remaining = do
        present <- doesFileExist path
        if present then pure () else threadDelay 50000 >> go (remaining - 1)

{- | Re-open after the holder has gone.

A short retry, because @waitForProcess@ returns when the process is reaped and
the descriptor teardown that releases the lock is the kernel's own.
-}
awaitExclusiveOpen :: FilePath -> IO (Either OwnershipFault ())
awaitExclusiveOpen target = go (200 :: Int)
  where
    go remaining = do
        opened <-
            onRow $ \row -> do
                attempt <- rowOpenExclusive row target
                case attempt of
                    Left fault -> pure (Left fault)
                    Right handle -> rowCloseHandle row handle
        case opened of
            Right () -> pure (Right ())
            Left fault
                | remaining <= 0 -> pure (Left fault)
                | otherwise -> threadDelay 25000 >> go (remaining - 1)
