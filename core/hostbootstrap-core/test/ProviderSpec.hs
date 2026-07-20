{-# LANGUAGE OverloadedStrings #-}

{- | The one pure lift per substrate ('HostBootstrap.Substrate.Provider'). These
tests lock the launch/teardown/transfer effect lists byte-for-byte: Lima and
Incus must reproduce the exact argv the former hand-branched code emitted (so
the unification is behavior-preserving on the validated substrates), and WSL2
must additionally write the global @.wslconfig@ ceiling with @swap@ and apply it
with @wsl --shutdown@ before install (the honest WSL2 wall).
-}
module ProviderSpec (tests) where

import HostBootstrap.Context (ProviderKind (..), ResourceEnvelope (..))
import HostBootstrap.HostTool (HostTool (Incus, Lima, Wsl))
import HostBootstrap.Incus (IncusVM (..))
import HostBootstrap.Lift (LiftLayer (..))
import HostBootstrap.Lima (LimaVM (..))
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import HostBootstrap.Substrate.Provider
import HostBootstrap.Wsl2 (Wsl2VM (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

handles :: VMHandles
handles =
    VMHandles
        { vmhIncus = IncusVM "demo-vm" "images:ubuntu/24.04"
        , vmhLima = LimaVM "demo-vm"
        , vmhWsl2 = Wsl2VM "demo-vm"
        , vmhGuardPrefix = "demo"
        , vmhWslConfigPath = "C:\\Users\\me\\.wslconfig"
        }

{- | Handles whose VM names do not carry the guard prefix, to prove a destroy is
refused outside the managed namespace.
-}
unguardedHandles :: VMHandles
unguardedHandles = handles{vmhWsl2 = Wsl2VM "someone-elses-distro"}

env :: ResourceEnvelope
env = ResourceEnvelope{cpu = 6, memory = "10GiB", storage = "80GiB"}

sel :: Substrate -> SubstrateProvider
sel sub = either (error . ("selectSubstrateProvider failed: " ++)) id (selectSubstrateProvider sub handles)

apple, linux, windows :: SubstrateProvider
apple = sel (Substrate AppleSilicon Arm64)
linux = sel (Substrate LinuxCpu Amd64)
windows = sel (Substrate WindowsCpu Amd64)

appleShare, linuxShare, windowsShare :: HostPathShare
appleShare = spShare apple "/Users/me/demo/.data"
linuxShare = spShare linux "/srv/demo/.data"
windowsShare = spShare windows "C:\\repo\\demo\\.data"

tests :: TestTree
tests =
    testGroup
        "ProviderSpec"
        [ testGroup "identity / provider kind / lift layer" identityCases
        , testGroup "launch effect lists (byte-for-byte)" launchCases
        , testGroup "host-path shares" shareCases
        , testGroup "teardown (stop / guarded destroy)" teardownCases
        , testGroup "exists / wait probes" probeCases
        , testGroup "pure interpreters" interpreterCases
        ]

identityCases :: [TestTree]
identityCases =
    [ testCase "apple selects Lima" $ do
        spVmId apple @?= "demo-vm"
        spProviderKind apple @?= LimaVMProvider
        spLiftLayer apple @?= ViaLimaVM (LimaVM "demo-vm")
    , testCase "linux selects Incus" $ do
        spProviderKind linux @?= IncusVMProvider
        spLiftLayer linux @?= ViaVM (IncusVM "demo-vm" "images:ubuntu/24.04")
    , testCase "windows selects WSL2" $ do
        spProviderKind windows @?= Wsl2VMProvider
        spLiftLayer windows @?= ViaWsl2VM (Wsl2VM "demo-vm")
    ]

launchCases :: [TestTree]
launchCases =
    [ testCase "lima launch reproduces the sized startVMArgs argv" $
        spLaunch apple env (Just appleShare)
            @?= Right
                [ RunHostTool
                    Lima
                    [ "start"
                    , "-y"
                    , "--timeout"
                    , "15m"
                    , "--name=demo-vm"
                    , "--containerd"
                    , "none"
                    , "--cpus"
                    , "6"
                    , "--memory"
                    , "10"
                    , "--disk"
                    , "80"
                    , "--vm-type"
                    , "vz"
                    , "--mount-only"
                    , "/Users/me/demo/.data:w"
                    , "template:ubuntu-24.04"
                    ]
                ]
    , testCase "incus launch reproduces the sized createVMArgs argv" $
        spLaunch linux env (Just linuxShare)
            @?= Right
                [ RunHostTool
                    Incus
                    [ "launch"
                    , "images:ubuntu/24.04"
                    , "demo-vm"
                    , "--vm"
                    , "-c"
                    , "limits.cpu=6"
                    , "-c"
                    , "limits.memory=10GiB"
                    , "-d"
                    , "root,size=80GiB"
                    ]
                ]
    , testCase "wsl2 launch merges the .wslconfig ceiling (+swap), shuts down, then installs with the VHDX cap" $
        spLaunch windows env (Just windowsShare)
            @?= Right
                [ MergeWslConfig
                    "C:\\Users\\me\\.wslconfig"
                    ["[general]", "instanceIdleTimeout=-1", "[wsl2]", "processors=6", "memory=10GB", "swap=10GB", "vmIdleTimeout=-1"]
                , RunHostTool Wsl ["--shutdown"]
                , RunHostTool
                    Wsl
                    ["--install", "-d", "Ubuntu-24.04", "--name", "demo-vm", "--no-launch", "--vhd-size", "80GB"]
                ]
    , testCase "lima/incus do not write any host file at launch; wsl2 merges .wslconfig" $ do
        fmap (any isWrite) (spLaunch apple env (Just appleShare)) @?= Right False
        fmap (any isWrite) (spLaunch linux env (Just linuxShare)) @?= Right False
        fmap (any isWrite) (spLaunch windows env (Just windowsShare)) @?= Right True
    , testCase "an omitted optional share preserves the former Lima launch argv" $
        spLaunch apple env Nothing
            @?= Right
                [ RunHostTool
                    Lima
                    [ "start"
                    , "-y"
                    , "--timeout"
                    , "15m"
                    , "--name=demo-vm"
                    , "--containerd"
                    , "none"
                    , "--cpus"
                    , "6"
                    , "--memory"
                    , "10"
                    , "--disk"
                    , "80"
                    , "--vm-type"
                    , "vz"
                    , "template:ubuntu-24.04"
                    ]
                ]
    , testCase "only wsl2 needs an explicit reconcile-to-running effect set to empty" $ do
        spStartExisting windows @?= []
        spStartExisting apple @?= [RunHostTool Lima ["start", "demo-vm"]]
        spStartExisting linux @?= [RunHostTool Incus ["start", "demo-vm"]]
    ]
  where
    -- the WSL2 wall is a merge into the user's .wslconfig (never a clobber), so a
    -- .wslconfig merge counts as a host-file write here.
    isWrite (WriteHostFile _ _) = True
    isWrite (MergeWslConfig _ _) = True
    isWrite _ = False

shareCases :: [TestTree]
shareCases =
    [ testCase "Lima exposes the same absolute path with no post-create effect" $ do
        hpsHostPath appleShare @?= "/Users/me/demo/.data"
        hpsGuestPath appleShare @?= "/Users/me/demo/.data"
        hpsReconcile appleShare @?= Nothing
        shareReconcileEffects appleShare "anything" @?= []
    , testCase "Incus plans one idempotent post-create disk device" $ do
        hpsHostPath linuxShare @?= "/srv/demo/.data"
        hpsGuestPath linuxShare @?= "/srv/demo/.data"
        hpsReconcile linuxShare
            @?= Just
                ShareReconcile
                    { srProbe = ExistsProbe Incus ["config", "device", "list", "demo-vm"] LinesMember
                    , srMember = "durable-data"
                    , srWhenMissing =
                        [ RunHostTool
                            Incus
                            [ "config"
                            , "device"
                            , "add"
                            , "demo-vm"
                            , "durable-data"
                            , "disk"
                            , "source=/srv/demo/.data"
                            , "path=/srv/demo/.data"
                            ]
                        ]
                    }
    , testCase "Incus adds a missing share but leaves an existing device untouched" $ do
        shareReconcileEffects linuxShare "root\neth0\n"
            @?= [ RunHostTool
                    Incus
                    [ "config"
                    , "device"
                    , "add"
                    , "demo-vm"
                    , "durable-data"
                    , "disk"
                    , "source=/srv/demo/.data"
                    , "path=/srv/demo/.data"
                    ]
                ]
        shareReconcileEffects linuxShare "root\ndurable-data\neth0\n" @?= []
    , testCase "WSL2 projects the host directory through DrvFs with no host effect" $ do
        hpsHostPath windowsShare @?= "C:\\repo\\demo\\.data"
        hpsGuestPath windowsShare @?= "/mnt/c/repo/demo/.data"
        hpsReconcile windowsShare @?= Nothing
        shareReconcileEffects windowsShare "anything" @?= []
    ]

teardownCases :: [TestTree]
teardownCases =
    [ testCase "stop is the stop/terminate argv per substrate (wsl2 also restores .wslconfig)" $ do
        spStop apple @?= [RunHostTool Lima ["stop", "demo-vm"]]
        spStop linux @?= [RunHostTool Incus ["stop", "demo-vm"]]
        spStop windows
            @?= [ RunHostTool Wsl ["--terminate", "demo-vm"]
                , RestoreHostFile "C:\\Users\\me\\.wslconfig"
                ]
    , testCase "guarded destroy emits the delete argv (and wsl2 restores .wslconfig)" $ do
        spDestroy apple @?= Right [RunHostTool Lima ["delete", "demo-vm", "--force"]]
        spDestroy linux @?= Right [RunHostTool Incus ["delete", "demo-vm", "--force"]]
        spDestroy windows
            @?= Right
                [ RunHostTool Wsl ["--unregister", "demo-vm"]
                , RestoreHostFile "C:\\Users\\me\\.wslconfig"
                ]
    , testCase "destroy refuses a VM name outside the guard prefix" $
        case selectSubstrateProvider (Substrate WindowsCpu Amd64) unguardedHandles of
            Left err -> assertBool ("expected a provider, got: " ++ err) False
            Right sp -> assertBool "expected a guard refusal" (isLeft (spDestroy sp))
    ]
  where
    isLeft (Left _) = True
    isLeft _ = False

probeCases :: [TestTree]
probeCases =
    [ testCase "exists probes are the list argv + membership parse" $ do
        spExists apple @?= ExistsProbe Lima ["list", "-q"] LinesMember
        spExists linux @?= ExistsProbe Incus ["list", "--format", "csv", "-c", "n"] LinesMember
        spExists windows @?= ExistsProbe Wsl ["--list", "--quiet"] WslQuietMember
    , testCase "wait probes run a trivial true in the VM" $ do
        spWait apple @?= WaitProbe Lima ["shell", "demo-vm", "--", "sudo", "-H", "true"]
        spWait linux @?= WaitProbe Incus ["exec", "demo-vm", "--", "true"]
        spWait windows @?= WaitProbe Wsl ["-d", "demo-vm", "--", "true"]
    , testCase "reconcile-cordon: Nothing for Lima/Incus, a running-probe + guarded shutdown for WSL2" $ do
        spReconcileCordon apple @?= Nothing
        spReconcileCordon linux @?= Nothing
        spReconcileCordon windows
            @?= Just
                ( ExistsProbe Wsl ["--list", "--verbose"] WslRunningMember
                , [RunHostTool Wsl ["--shutdown"]]
                )
    ]

interpreterCases :: [TestTree]
interpreterCases =
    [ testCase "membersOf LinesMember splits on lines" $
        membersOf LinesMember "demo-vm\nother\n" @?= ["demo-vm", "other"]
    , testCase "membersOf WslQuietMember strips NULs and splits on whitespace" $
        assertBool "demo-vm is a member" $
            "demo-vm" `elem` membersOf WslQuietMember "Ubuntu-24.04\0\r\ndemo-vm\0\r\n"
    , testCase "membersOf WslRunningMember returns only the Running distros (skips header + Stopped)" $
        membersOf WslRunningMember "  NAME  STATE  VERSION\n* demo-vm  Running  2\nother  Stopped  2\n"
            @?= ["demo-vm"]
    , testCase "stageFileEffects copies to the guest via limactl on Lima (removed after)" $
        stageFileEffects (LimaFileTransfer (LimaVM "demo-vm")) "src.tgz" "/tmp/x.tgz"
            @?= StagedFile [RunHostTool Lima ["copy", "src.tgz", "demo-vm:/tmp/x.tgz"]] "/tmp/x.tgz" True
    , testCase "stageFileEffects pushes to a temp on Incus (removed after)" $
        stageFileEffects (IncusFileTransfer (IncusVM "demo-vm" "images:ubuntu/24.04")) "src.tgz" "/tmp/x.tgz"
            @?= StagedFile [RunHostTool Incus ["file", "push", "src.tgz", "demo-vm/tmp/x.tgz"]] "/tmp/x.tgz" True
    , testCase "stageFileEffects reads in place via /mnt on WSL2 (no host effect)" $
        stageFileEffects (Wsl2MountTransfer (Wsl2VM "demo-vm")) "C:\\repo\\src.tgz" "/tmp/x.tgz"
            @?= StagedFile [] "/mnt/c/repo/src.tgz" False
    , testCase "vmShellArgs folds a single VM layer to its exec argv" $ do
        vmShellArgs (ViaWsl2VM (Wsl2VM "d")) ["bash", "-lc", "echo hi"]
            @?= Just (Wsl, ["-d", "d", "--", "bash", "-lc", "echo hi"])
        vmShellArgs (ViaLimaVM (LimaVM "d")) ["true"]
            @?= Just (Lima, ["shell", "d", "--", "sudo", "-H", "true"])
    , testCase "windowsPathToWslMount rewrites a drive path to its /mnt mount" $
        windowsPathToWslMount "C:\\Users\\Matt\\f.tgz" @?= "/mnt/c/Users/Matt/f.tgz"
    ]
