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

import BuildAuthoritySpec (buildPosixFilesSupported, buildUnpairedNameSupported)
import CLISpec (readOnlyRecordsSupported)
import ColimaSpec (colimaLiveAvailable, contextNamespaceSupported, directoryReleaseSupported)
import ConditionalCase (conditionalAction, readConditionalCompletions)
import Control.Exception (IOException, try)
import Control.Monad (forM_)
import CordonSpec (nativeCapacitySupported, windowsCapacitySupported)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map.Strict as Map
import HandoffSpec (siblingConfigSymlinksSupported, windowsChildGroupObservationSupported)
import HostBootstrap.Ownership.Posix (posixOwnershipSupported)
import OwnershipPosixSpec (foreignManifestOwnerSupported)
import HostBootstrap.Ownership.Row (hostOwnershipSupported)
import HostBootstrap.Ownership.Windows (windowsOwnershipSupported)
import HostBootstrap.Wsl2.GlobalWall.Windows (windowsGlobalWallSupported)
import HostToolSpec (windowsResolutionSupported)
import LiftSpec (posixShellSupported)
import ProjectPlanSpec (surrogateDirectorySupported)
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
maps them onto @LockFileEx@, @FILE_ID_INFO@, and the Win32
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
    [ ConditionalFamily
        { familyPath = ["CLISpec", "operator refusal precedes lifecycle work"]
        , familyCases = 3
        , familyRowCases = 3
        , familyRowHolds = readOnlyRecordsSupported
        , familyReason = "the effective principal or filesystem does not enforce a read-only records directory"
        }
    , ConditionalFamily
        { familyPath = ["ColimaSpec"]
        , familyCases = 300
        , familyRowCases = 31
        , familyRowHolds = posixOwnershipSupported
        , familyReason = "the direct-Colima native transaction and resolver fixtures require POSIX ownership primitives; a dedicated case asserts the Windows refusal"
        }
    , ConditionalFamily
        { familyPath = ["ColimaSpec", "direct-Colima live lane"]
        , familyCases = 1
        , familyRowCases = 1
        , familyRowHolds = colimaLiveAvailable
        , familyReason = "the opt-in lane requires a requested native Apple Silicon host with Colima installed"
        }
    , hostWallFamily ["WslGlobalWallHostSpec", "apply over an absent origin"] 5 5
    , ConditionalFamily
        { familyPath = ["ColimaSpec", "native fixture resolution result"]
        , familyCases = 2
        , familyRowCases = 2
        , familyRowHolds = posixOwnershipSupported
        , familyReason =
            "the native fixture walker needs POSIX file identities, owner/mode policy and symbolic links;"
                ++ " Windows asserts its actual apple-silicon-required result rather than manufacturing a ready toolchain"
        }
    , ConditionalFamily
        { familyPath = ["ColimaSpec", "native fixture backed owned settlement"]
        , familyCases = 13
        , familyRowCases = 13
        , familyRowHolds = posixOwnershipSupported
        , familyReason =
            "the static join takes the actual opaque ready result of the POSIX native fixture walker;"
                ++ " Windows checks the actual native unsupported result without manufacturing ready authority"
        }
    , ConditionalFamily
        { familyPath = ["ColimaSpec", "native resolver install policy"]
        , familyCases = 2
        , familyRowCases = 2
        , familyRowHolds = posixOwnershipSupported
        , familyReason = "installation dispatch consumes actual opaque ready/missing results from the native fixture walker; unavailable rows assert the real native refusal"
        }
    , ConditionalFamily
        { familyPath = ["ColimaSpec", "native Released namespace recovery"]
        , familyCases = 16
        , familyRowCases = 16
        , familyRowHolds = contextNamespaceSupported
        , familyReason = "actual retained namespace and parent-origin settlement uses the native manifest/release row; every unavailable branch asserts the real row refusal"
        }
    , ConditionalFamily
        { familyPath = ["ColimaSpec", "native context namespace recovery"]
        , familyCases = 8
        , familyRowCases = 8
        , familyRowHolds = contextNamespaceSupported
        , familyReason = "the actual namespace manifest and release rows execute against kernel temporaries; unavailable hosts assert their real manifest or release refusal"
        }
    , ConditionalFamily
        { familyPath = ["ColimaSpec", "native directory release recovery"]
        , familyCases = 4
        , familyRowCases = 4
        , familyRowHolds = directoryReleaseSupported
        , familyReason = "the actual selected ownership row must hold both release and durable-record clauses; otherwise every case asserts its actual declared refusal"
        }
    , ConditionalFamily
        { familyPath = ["HandoffSpec", "sibling config symlinks"]
        , familyCases = 2
        , familyRowCases = 2
        , familyRowHolds = siblingConfigSymlinksSupported
        , familyReason =
            "actual symlink creation on the running binary's filesystem may refuse permission or support;"
                ++ " both cases assert that exact creation observation while control and cleanup failures fail"
        }
    , ConditionalFamily
        { familyPath = ["BuildAuthoritySpec", "POSIX native source files"]
        , familyCases = 3
        , familyRowCases = 3
        , familyRowHolds = buildPosixFilesSupported
        , familyReason =
            "raw-byte fixture names and FIFO creation need native POSIX filesystem primitives;"
                ++ " other hosts observe the existing POSIX row's typed unsupported result"
        }
    , ConditionalFamily
        { familyPath = ["BuildAuthoritySpec", "Windows unpaired source names"]
        , familyCases = 1
        , familyRowCases = 1
        , familyRowHolds = buildUnpairedNameSupported
        , familyReason =
            "the actual shared native UTF-16 filename probe may refuse InvalidArgument;"
                ++ " control, enumeration and cleanup failures remain test failures"
        }
    , ConditionalFamily
        { familyPath = ["indexed project-plan foundation", "canonical filesystem root encoding"]
        , familyCases = 1
        , familyRowCases = 1
        , familyRowHolds = surrogateDirectorySupported
        , familyReason =
            "the actual createDirectory probe may refuse a lone-surrogate filename;"
                ++ " DEVELOPMENT_PLAN/rationale.md#a-root-encoder-is-tested-through-a-real-filesystem-root"
        }
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
        { familyPath = ["HandoffSpec", "native Windows child groups"]
        , familyCases = 5
        , familyRowCases = 5
        , familyRowHolds = windowsChildGroupObservationSupported
        , familyReason =
            "native Windows kernel process-handle observations need Windows;"
                ++ " other hosts assert the test-owned unsupported observation and local transaction/platform boundaries"
        }
    , ConditionalFamily
        { familyPath = ["EffectSpec", "scoped POSIX child groups"]
        , familyCases = 2
        , familyRowCases = 2
        , familyRowHolds = posixOwnershipSupported
        , familyReason =
            "captured POSIX process-group observations need native POSIX signal primitives;"
                ++ " Windows asserts the existing unavailable POSIX observation result"
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
    , hostWallFamily ["WslGlobalWallHostSpec", "apply over a present origin"] 4 4
    , hostWallFamily ["WslGlobalWallHostSpec", "ownership refusals"] 17 16
    , hostWallFamily ["WslGlobalWallHostSpec", "crash resume"] 19 19
    , hostWallFamily ["WslGlobalWallHostSpec", "the durable record codec"] 11 2
    , -- Both rows keep their complete declared families on every gate host.
      -- POSIX adds FIFO, mode-bit and cross-mount checks; Windows adds native
      -- junction and ACL checks. Each unavailable row asserts its own refusal.
      ownershipRowFamily ["OwnershipPosixSpec", "identity"] 6 6
    , ownershipRowFamily ["OwnershipPosixSpec", "creation and publication"] 8 8
    , ownershipRowFamily ["OwnershipPosixSpec", "the exclusive open"] 5 5
    , ownershipRowFamily ["OwnershipPosixSpec", "removal and durability"] 4 4
    , ownershipRowFamily ["OwnershipPosixSpec", "manifest walk"] 10 9
    , ownershipRowFamily ["OwnershipPosixSpec", "raw manifest bytes"] 7 5
    , ownershipRowFamily ["OwnershipPosixSpec", "manifest remainder"] 10 9
    , ownershipRowFamily ["OwnershipPosixSpec", "parent traversal"] 4 4
    , ownershipRowFamily ["OwnershipPosixSpec", "parent settlement"] 7 7
    , ownershipRowFamily ["ColimaSpec", "namespace admission"] 3 1
    , ownershipRowFamily ["ColimaSpec", "context parents"] 8 7
    , ConditionalFamily
        { familyPath = ["OwnershipPosixSpec", "foreign manifest owner"]
        , familyCases = 1
        , familyRowCases = 1
        , familyRowHolds = foreignManifestOwnerSupported
        , familyReason = "the foreign-owner fixture needs a POSIX effective user that can change a file's owner"
        }
    , ownershipWindowsRowFamily ["OwnershipWindowsSpec", "identity"] 7 7
    , ownershipWindowsRowFamily ["OwnershipWindowsSpec", "creation and publication"] 6 6
    , ownershipWindowsRowFamily ["OwnershipWindowsSpec", "the exclusive open"] 6 6
    , ownershipWindowsRowFamily ["OwnershipWindowsSpec", "removal"] 5 5
    , ConditionalFamily
        { familyPath = ["ProviderAliasSpec", "the shipped guest alias ownership row"]
        , familyCases = 21
        , familyRowCases = 21
        , familyRowHolds = localGuestAliasSupported
        , familyReason =
            "the shipped guest alias row needs POSIX symbolic-link ownership and no-replace publication"
        }
    , ConditionalFamily
        { familyPath = ["ProviderBackendSpec", "prepared guest alias acquisition"]
        , familyCases = 6
        , familyRowCases = 6
        , familyRowHolds = localGuestAliasSupported
        , familyReason = "the prepared alias acquisition uses the same POSIX symbolic-link ownership row as the shipped guest alias"
        }
    , ConditionalFamily
        { familyPath = ["ProviderBackendSpec", "prepared guest alias release"]
        , familyCases = 4
        , familyRowCases = 4
        , familyRowHolds = localGuestAliasSupported
        , familyReason = "the prepared alias release uses the same POSIX symbolic-link ownership row as the shipped guest alias"
        }
    , ConditionalFamily
        { familyPath = ["ProviderBackendSpec", "node guest alias route"]
        , familyCases = 4
        , familyRowCases = 4
        , familyRowHolds = localGuestAliasSupported
        , familyReason = "the node guest alias route uses the shipped POSIX symbolic-link ownership row"
        }
    , ConditionalFamily
        { familyPath = ["WslGlobalWallWindowsSpec"]
        , familyCases = 7
        , familyRowCases = 6
        , familyRowHolds = windowsGlobalWallSupported
        , familyReason =
            "the Windows entry points require profile admission and the native LockFileEx/FILE_ID_INFO row"
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

    hostWallFamily path cases rowCases =
        ConditionalFamily
            { familyPath = path
            , familyCases = cases
            , familyRowCases = rowCases
            , familyRowHolds = hostOwnershipSupported
            , familyReason =
                "the running host's ownership row supplies stable identities, exclusive opens, no-replace links and parent sync"
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
