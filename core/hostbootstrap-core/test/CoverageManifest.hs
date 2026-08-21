{- | What this gate host did not run, and what it asserted instead.

§ JJ's fifth rule is the one a green total cannot enforce by itself: a case
whose subject is unavailable on this gate host asserts the refusal its row
declares rather than disappearing. A conditional that changes an /expectation/
keeps the evidence; one that removes the case removes it, and a family that
quietly shrank on one host still reports a green total with a number that reads
the same. Nobody compares two totals across two machines.

So the suite declares, per family, how many cases it has — on every gate host,
not on this one — and the driver checks the assembled tree against that
declaration before the run means anything. A case that vanished is a failed
count rather than a smaller one. Each row also names why its subject is
conditional and what the cases assert here, and it does so in the case name, so
the run itself is the report: reading the gate's output tells you which
families exercised a real kernel and which recorded a refusal.

A row belongs here only when a family's /subject/ is something a gate host may
not have: a platform row of the ownership seam, or a contract whose primitives
one outer host does not offer. A case whose subject is available everywhere is
not conditional and is not declared, because a manifest that listed every family
would be a second copy of the suite and would rot rather than guard.
-}
module CoverageManifest (tests) where

import Data.List (intercalate, isPrefixOf)
import HostBootstrap.Ownership.Posix (posixOwnershipSupported)
import HostBootstrap.Ownership.Row (hostOwnershipSupported)
import HostBootstrap.Ownership.Windows (windowsOwnershipSupported)
import HostBootstrap.Wsl2.GlobalWall.Windows (windowsGlobalWallSupported)
import ClusterBackendSpec (clusterOwnershipRowHolds)
import ProviderAliasSpec (localGuestAliasSupported)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Test.Tasty.Runners (TreeFold (foldGroup, foldSingle), foldTestTree, trivialFold)

{- | One family whose subject is a platform row.

'familyCases' is the family's size on /every/ gate host, which is the whole
point: it is a property of the suite, so the check is the same everywhere and a
host that drops a case fails rather than reports a smaller total.
-}
data ConditionalFamily = ConditionalFamily
    { familyPath :: [TestName]
    -- ^ Group path from the root of the assembled suite.
    , familyCases :: Int
    -- ^ Every case in the family, on every gate host.
    , familyRowCases :: Int
    -- ^ How many of those drive the platform row rather than a pure value.
    , familyRowHolds :: Bool
    -- ^ Whether this gate host can hold the row's obligations.
    , familyReason :: String
    -- ^ Why the row cannot be held where it cannot.
    }

{- | The families whose subject a gate host may not have.

The ownership seam's POSIX row supplies @lstat@ identity, @O_NOFOLLOW@ opens,
@fcntl@ record locks, and @link(2)@; its declaration-only cases are available
everywhere and are therefore not declared here.

The POSIX row maps the four ownership clauses onto @fcntl@ record locks,
@device:inode@ identity, and link/rename namespace operations; the Windows row
maps them onto @LockFileEx@, @BY_HANDLE_FILE_INFORMATION@, and the Win32
namespace calls. Each is real where its primitives are and a total refusal
where they are not, and every case below stays in the suite either way.

Two ownership /drivers/ are conditional for the same reason and on their own
terms. The cluster backend's transaction runs under a util-linux @flock(2)@ on
an inherited descriptor and hands its driver @\/proc\/self\/fd@ paths; the guest
alias driver opens with @O_NOFOLLOW@, holds a @flock(2)@ across an @exec@, and
publishes by a no-replace hard link. Where an outer host offers neither, both
refuse to mint any authority at all, and every case in those families records
that refusal rather than vanishing. Each is deleted by the phase that replaces
its driver, and its row goes with it.
-}
manifest :: [ConditionalFamily]
manifest =
    [ posixFamily ["WslGlobalWallHostSpec", "apply over an absent origin"] 5 5
    , posixFamily ["WslGlobalWallHostSpec", "apply over a present origin"] 3 3
    , posixFamily ["WslGlobalWallHostSpec", "ownership refusals"] 4 4
    , posixFamily ["WslGlobalWallHostSpec", "crash resume"] 3 3
    , posixFamily ["WslGlobalWallHostSpec", "the durable record codec"] 3 2
    , ownershipRowFamily ["OwnershipPosixSpec", "identity"] 5 5
    , ownershipRowFamily ["OwnershipPosixSpec", "creation and publication"] 5 5
    , ownershipRowFamily ["OwnershipPosixSpec", "the exclusive open"] 4 4
    , ownershipRowFamily ["OwnershipPosixSpec", "removal and durability"] 4 4
    , ownershipWindowsRowFamily ["OwnershipWindowsSpec", "identity"] 3 3
    , ownershipWindowsRowFamily ["OwnershipWindowsSpec", "creation and publication"] 4 4
    , ownershipWindowsRowFamily ["OwnershipWindowsSpec", "the exclusive open"] 2 2
    , ownershipWindowsRowFamily ["OwnershipWindowsSpec", "removal"] 2 2
    , ConditionalFamily
        { familyPath = ["ClusterBackendSpec", "the cluster ownership row"]
        , familyCases = 46
        , familyRowCases = 46
        , familyRowHolds = clusterOwnershipRowHolds
        , familyReason =
            "the cluster ownership transaction needs a util-linux flock(2) namespace,"
                ++ " O_NOFOLLOW opens, and descriptor paths"
        }
    , ConditionalFamily
        { familyPath = ["ProviderAliasSpec", "the local guest alias driver"]
        , familyCases = 13
        , familyRowCases = 13
        , familyRowHolds = localGuestAliasSupported
        , familyReason =
            "the guest alias driver needs O_NOFOLLOW opens, a flock(2) held across an exec,"
                ++ " and no-replace hard links"
        }
    , ConditionalFamily
        { familyPath = ["WslGlobalWallWindowsSpec"]
        , familyCases = 4
        , familyRowCases = 3
        , familyRowHolds = windowsGlobalWallSupported
        , familyReason =
            "the Win32 row needs LockFileEx and BY_HANDLE_FILE_INFORMATION"
        }
    ]
  where
    ownershipRowFamily path cases rowCases =
        ConditionalFamily
            { familyPath = path
            , familyCases = cases
            , familyRowCases = rowCases
            , familyRowHolds = posixOwnershipSupported
            , familyReason =
                "the POSIX ownership row needs lstat identity, O_NOFOLLOW opens,"
                    ++ " fcntl record locks, and link(2)"
            }

    ownershipWindowsRowFamily path cases rowCases =
        ConditionalFamily
            { familyPath = path
            , familyCases = cases
            , familyRowCases = rowCases
            , familyRowHolds = windowsOwnershipSupported
            , familyReason =
                "the Windows ownership row needs GetFileInformationByHandle identity,"
                    ++ " LockFileEx byte-range locks, and CreateHardLinkW"
            }

    posixFamily path cases rowCases =
        ConditionalFamily
            { familyPath = path
            , familyCases = cases
            , familyRowCases = rowCases
            , familyRowHolds = hostOwnershipSupported
            , familyReason =
                "the POSIX row needs fcntl record locks and device:inode identity"
            }

{- | Check the assembled suite against the manifest, and report what ran.

The argument is the suite's own top-level groups, so the paths this compares
are the paths the runner prints. Each row becomes one case whose /name/ carries
the report, which is what makes the gate output the record rather than a
side-channel nobody reads.
-}
tests :: [TestTree] -> TestTree
tests suite =
    testGroup
        "CoverageManifest"
        (map declared manifest)
  where
    paths = concatMap leafPaths suite

    declared family =
        testCase (report family) $ do
            let observed = length (filter (familyPath family `isPrefixOf`) paths)
            if observed == familyCases family
                then pure ()
                else
                    assertFailure
                        ( renderPath (familyPath family)
                            ++ " carries "
                            ++ show observed
                            ++ " cases on this gate host and the manifest declares "
                            ++ show (familyCases family)
                            ++ ": a case whose subject is unavailable asserts the refusal"
                            ++ " its row declares rather than disappearing"
                        )

{- | The line the gate prints for one family.

It names the family, its size, and — where the row cannot be held — how many of
those cases recorded a refusal instead of a syscall, together with the reason.
-}
report :: ConditionalFamily -> TestName
report family
    | familyRowHolds family =
        renderPath (familyPath family)
            ++ ": "
            ++ show (familyCases family)
            ++ " cases, "
            ++ show (familyRowCases family)
            ++ " exercising the row against this gate host's kernel"
    | otherwise =
        renderPath (familyPath family)
            ++ ": "
            ++ show (familyCases family)
            ++ " cases, "
            ++ show (familyRowCases family)
            ++ " asserting the row's declared refusal on this gate host ("
            ++ familyReason family
            ++ ")"

renderPath :: [TestName] -> String
renderPath = intercalate " / "

{- | Every leaf case in a tree, as its path from that tree's root.

Only the structure is folded, so no test is run and no resource is acquired.
-}
leafPaths :: TestTree -> [[TestName]]
leafPaths =
    foldTestTree
        trivialFold
            { foldSingle = \_options name _test -> [[name]]
            , foldGroup = \_options name children -> map (name :) (concat children)
            }
        mempty
