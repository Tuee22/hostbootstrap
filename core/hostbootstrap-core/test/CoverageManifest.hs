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
count rather than a smaller one. Each row names the expected branch and why its
subject is conditional. A final case waits for the suite and compares those
expectations with the successfully completed row and refusal callbacks. These
counts establish execution; the callbacks' assertions establish their claims.

A row belongs here only when a family's /subject/ is something a gate host may
not have: a platform row of the ownership seam, or a contract whose primitives
one outer host does not offer. A case whose subject is available everywhere is
not conditional and is not declared, because a manifest that listed every family
would be a second copy of the suite and would rot rather than guard. A formerly
platform-split native effect family also retains its declaration after every
host gains a native subject, so it cannot silently lose those process cases.
-}
module CoverageManifest (tests) where

import ConditionalCase (conditionalAction, readConditionalCompletions)
import Control.Exception (IOException, try)
import Control.Monad (forM_)
import CordonSpec (nativeCapacitySupported, windowsCapacitySupported)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map.Strict as Map
import HostBootstrap.Ownership.Posix (posixOwnershipSupported)
import HostBootstrap.Ownership.Row (hostOwnershipSupported)
import HostBootstrap.Ownership.Windows (windowsOwnershipSupported)
import HostBootstrap.Wsl2.GlobalWall.Windows (windowsGlobalWallSupported)
import HostToolSpec (windowsResolutionSupported)
import LiftSpec (posixShellSupported)
import ProviderAliasSpec (localGuestAliasSupported)
import Test.Tasty (DependencyType (AllFinish), TestName, TestTree, after, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
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

The shipped guest alias ownership transaction requires POSIX symbolic links and
no-replace hard links. Where those primitives are unavailable it refuses to mint
authority, and every case in that family records the refusal rather than
vanishing. The cluster transaction uses the protected store's exclusive entry
and described commands, so it holds on every gate host and is counted normally.
-}
manifest :: [ConditionalFamily]
manifest =
    [ posixFamily ["WslGlobalWallHostSpec", "apply over an absent origin"] 5 5
    , ConditionalFamily
        { familyPath = ["LiftSpec", "shared shell quoting boundary"]
        , familyCases = 2
        , familyRowCases = 1
        , familyRowHolds = posixShellSupported
        , familyReason = "the shell round-trip needs /bin/sh; other hosts assert the same invocation's launch refusal"
        }
    , ConditionalFamily
        { familyPath = ["LiftSpec", "local effect seam"]
        , familyCases = 6
        , familyRowCases = 4
        , familyRowHolds = True
        , familyReason = "the suite executable provides native stdout/stdin subjects on every gate host"
        }
    , ConditionalFamily
        { familyPath = ["HostToolSpec", "Windows resolution"]
        , familyCases = 2
        , familyRowCases = 2
        , familyRowHolds = windowsResolutionSupported
        , familyReason = "System32 host-tool discovery is Windows-only; other hosts answer no Windows executable"
        }
    , ConditionalFamily
        { familyPath = ["CordonSpec", "native capacity"]
        , familyCases = 1
        , familyRowCases = 1
        , familyRowHolds = nativeCapacitySupported
        , familyReason = "native capacity needs a supported host classification; unsupported hosts assert the exact detector refusal"
        }
    , ConditionalFamily
        { familyPath = ["CordonSpec", "Windows capacity"]
        , familyCases = 4
        , familyRowCases = 4
        , familyRowHolds = windowsCapacitySupported
        , familyReason = "Windows capacity uses native Win32 readers; other hosts assert each reader's typed unsupported result"
        }
    , ConditionalFamily
        { familyPath = ["EffectSpec", "bounded POSIX behavior"]
        , familyCases = 5
        , familyRowCases = 5
        , familyRowHolds = posixOwnershipSupported
        , familyReason = "POSIX process-group and native cwd-and-exec probes need POSIX support; Windows asserts the process-probe and native-entry unavailable results"
        }
    , ConditionalFamily
        { familyPath = ["RecursiveLifecycleSpec (real root/VM/container lifecycle)"]
        , familyCases = 8
        , familyRowCases = 6
        , familyRowHolds = posixOwnershipSupported
        , familyReason =
            "local guest execution needs the POSIX row and its canonical path grammar;"
                ++ " the native receiver also refuses a different guest-root snapshot"
        }
    , ConditionalFamily
        { familyPath = ["recovery-interruption"]
        , familyCases = 5
        , familyRowCases = 1
        , familyRowHolds = posixOwnershipSupported
        , familyReason = "recursive destroy recovery uses the declared POSIX guest row; the native receiver refuses a different guest-root snapshot"
        }
    , posixFamily ["WslGlobalWallHostSpec", "apply over a present origin"] 3 3
    , posixFamily ["WslGlobalWallHostSpec", "ownership refusals"] 4 4
    , posixFamily ["WslGlobalWallHostSpec", "crash resume"] 3 3
    , posixFamily ["WslGlobalWallHostSpec", "the durable record codec"] 3 2
    , -- The two ownership rows are not symmetric, and the numbers below say so
      -- rather than hide it: POSIX declares 18 clauses and Windows 11. Seven
      -- clauses the POSIX row asserts have no Windows counterpart --- four are
      -- symbolic-link behaviours, and three are not platform-specific at all
      -- ("a probe that cannot answer is a fault rather than an absence", "the
      -- kernel releases the exclusion when the holding process dies", and
      -- "removing an object that is not there is a fault rather than a silent
      -- success"). Under § JJ a clause whose subject a host lacks asserts the
      -- refusal its row declares; it does not disappear. So this asymmetry is a
      -- coverage deficit in the Windows row, not a property of Windows, and these
      -- counts freeze the deficit at its current size rather than endorsing it ---
      -- a Windows row that loses another clause still fails here. Closing it is
      -- owed work for the phase that owns the ownership seam, and it needs a
      -- Windows gate host to write against.
      ownershipRowFamily ["OwnershipPosixSpec", "identity"] 5 5
    , ownershipRowFamily ["OwnershipPosixSpec", "creation and publication"] 5 5
    , ownershipRowFamily ["OwnershipPosixSpec", "the exclusive open"] 4 4
    , ownershipRowFamily ["OwnershipPosixSpec", "removal and durability"] 4 4
    , ownershipWindowsRowFamily ["OwnershipWindowsSpec", "identity"] 3 3
    , ownershipWindowsRowFamily ["OwnershipWindowsSpec", "creation and publication"] 4 4
    , ownershipWindowsRowFamily ["OwnershipWindowsSpec", "the exclusive open"] 2 2
    , ownershipWindowsRowFamily ["OwnershipWindowsSpec", "removal"] 2 2
    , ConditionalFamily
        { familyPath = ["ProviderAliasSpec", "the shipped guest alias ownership row"]
        , familyCases = 5
        , familyRowCases = 5
        , familyRowHolds = localGuestAliasSupported
        , familyReason =
            "the shipped guest alias row needs POSIX symbolic links and no-replace hard links"
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
        ( map declared manifest
            ++ [ testCase "branch comparisons reject missing, opposite, and excess completions" $ do
                    branchMatches True 2 (2, 0) @?= True
                    branchMatches False 2 (0, 2) @?= True
                    forM_ [(0, 0), (1, 0), (0, 2), (2, 1), (3, 0)] $ \counts ->
                        branchMatches True 2 counts @?= False
                    forM_ [(0, 0), (0, 1), (2, 0), (1, 2), (0, 3)] $ \counts ->
                        branchMatches False 2 counts @?= False
               , testCase "only callbacks returning successfully record their selected branch" $ do
                    let family = ["ConditionalCase callback checks"]
                    conditionalAction family True (pure ()) (assertFailure "wrong branch")
                    conditionalAction family False (assertFailure "wrong branch") (pure ())
                    failed <- try (conditionalAction family True (ioError (userError "callback failed")) (pure ())) :: IO (Either IOException ())
                    either (const (pure ())) (const (assertFailure "the callback exception escaped detection")) failed
                    observed <- readConditionalCompletions
                    Map.lookup family observed @?= Just (1, 1)
               , after AllFinish "$0 !~ /CoverageManifest/" $
                    testCase "every conditional family ran the branch its row declares" $ do
                        observed <- readConditionalCompletions
                        forM_ manifest $ \family -> do
                            let counts = Map.findWithDefault (0, 0) (familyPath family) observed
                            putStrLn (renderPath (familyPath family) ++ ": observed row/refusal completions " ++ show counts)
                            if branchMatches (familyRowHolds family) (familyRowCases family) counts
                                then pure ()
                                else assertFailure (renderPath (familyPath family) ++ " completed row/refusal branches " ++ show counts ++ "; expected " ++ show (expectedBranches (familyRowHolds family) (familyRowCases family)))
               ]
        )
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

{- | The expectation the gate names for one family.

The final manifest case separately reports the observed successful completions
and compares them with this declaration.
-}
report :: ConditionalFamily -> TestName
report family
    | familyRowHolds family =
        renderPath (familyPath family)
            ++ ": "
            ++ show (familyCases family)
            ++ " cases, "
            ++ show (familyRowCases family)
            ++ " expected to exercise the row against this gate host's kernel"
    | otherwise =
        renderPath (familyPath family)
            ++ ": "
            ++ show (familyCases family)
            ++ " cases, "
            ++ show (familyRowCases family)
            ++ " expected to assert the row's declared refusal on this gate host ("
            ++ familyReason family
            ++ ")"

renderPath :: [TestName] -> String
renderPath = intercalate " / "

expectedBranches :: Bool -> Int -> (Int, Int)
expectedBranches True count = (count, 0)
expectedBranches False count = (0, count)

branchMatches :: Bool -> Int -> (Int, Int) -> Bool
branchMatches holds count observed = observed == expectedBranches holds count

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
