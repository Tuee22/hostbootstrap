{-# LANGUAGE OverloadedStrings #-}

module LiftSpec (tests) where

import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.HostTool (HostTool (Docker, Incus, Lima, Wsl))
import HostBootstrap.Incus (IncusVM (..))
import HostBootstrap.Lima (LimaVM (..))
import HostBootstrap.Lift
import HostBootstrap.Wsl2 (Wsl2VM (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "LiftSpec"
    [ testGroup "foldLift across context stacks" foldCases,
      testGroup "foldLeaf places any command in the right frame" foldLeafCases,
      testGroup "containerRunArgs" containerCases
    ]

-- Fixtures.
vm :: IncusVM
vm = IncusVM "demo-vm" "images:ubuntu/24.04"

limaVM :: LimaVM
limaVM = LimaVM "demo-vm"

wslVM :: Wsl2VM
wslVM = Wsl2VM "hostbootstrap-demo"

sockMount :: V.Mount
sockMount = V.Mount {V.source = "/var/run/docker.sock", V.target = "/var/run/docker.sock", V.readOnly = False}

container :: ContainerLift
container =
  ContainerLift
    { clImage = "demo:local",
      clMounts = [sockMount],
      clExtraArgs = ["--network=host"],
      clRemoveAfter = True
    }

self :: SelfRef
self = mkSelfRef "/proc/self/exe" "/usr/local/bin/hostbootstrap-demo"

sub :: [String]
sub = ["cluster", "up"]

foldCases :: [TestTree]
foldCases =
  [ testCase "Local runs the binary directly" $
      foldLift self localContext sub
        @?= DispatchLocal "/proc/self/exe" ["cluster", "up"],
    testCase "InVM dispatches incus exec with the in-VM binary path" $
      foldLift self (inVM vm localContext) sub
        @?= DispatchTool Incus ["exec", "demo-vm", "--", "/usr/local/bin/hostbootstrap-demo", "cluster", "up"],
    testCase "InLimaVM dispatches limactl shell with the in-VM binary path" $
      foldLift self (inLimaVM limaVM localContext) sub
        @?= DispatchTool Lima ["shell", "demo-vm", "--", "/usr/local/bin/hostbootstrap-demo", "cluster", "up"],
    testCase "InWsl2VM dispatches wsl -d with the in-VM binary path" $
      foldLift self (inWsl2VM wslVM localContext) sub
        @?= DispatchTool Wsl ["-d", "hostbootstrap-demo", "--", "/usr/local/bin/hostbootstrap-demo", "cluster", "up"],
    testCase "InContainer dispatches docker run (ENTRYPOINT is the binary, no self token)" $
      foldLift self (inContainer container localContext) sub
        @?= DispatchTool
          Docker
          [ "run",
            "--rm",
            "-v",
            "/var/run/docker.sock:/var/run/docker.sock",
            "--network=host",
            "demo:local",
            "cluster",
            "up"
          ],
    testCase "VM-then-container nests: incus exec -- docker run --rm img sub" $
      foldLift self (inContainer container (inVM vm localContext)) sub
        @?= DispatchTool
          Incus
          [ "exec",
            "demo-vm",
            "--",
            "docker",
            "run",
            "--rm",
            "-v",
            "/var/run/docker.sock:/var/run/docker.sock",
            "--network=host",
            "demo:local",
            "cluster",
            "up"
          ],
    testCase "Lima VM-then-container nests: limactl shell -- docker run --rm img sub" $
      foldLift self (inContainer container (inLimaVM limaVM localContext)) sub
        @?= DispatchTool
          Lima
          [ "shell",
            "demo-vm",
            "--",
            "docker",
            "run",
            "--rm",
            "-v",
            "/var/run/docker.sock:/var/run/docker.sock",
            "--network=host",
            "demo:local",
            "cluster",
            "up"
          ],
    testCase "WSL2 VM-then-container nests: wsl -d distro -- docker run --rm img sub" $
      foldLift self (inContainer container (inWsl2VM wslVM localContext)) sub
        @?= DispatchTool
          Wsl
          [ "-d",
            "hostbootstrap-demo",
            "--",
            "docker",
            "run",
            "--rm",
            "-v",
            "/var/run/docker.sock:/var/run/docker.sock",
            "--network=host",
            "demo:local",
            "cluster",
            "up"
          ]
  ]

foldLeafCases :: [TestTree]
foldLeafCases =
  [ testCase "reachLeaf locally runs curl directly (no self path)" $
      foldLeaf localContext (reachLeaf "http://localhost:30080/api/budget")
        @?= DispatchLocal "curl" ["-fsS", "-m", "5", "-o", "/dev/null", "http://localhost:30080/api/budget"],
    testCase "reachLeaf in an Incus VM folds to incus exec -- curl …" $
      foldLeaf (inVM vm localContext) (reachLeaf "http://localhost:30080/api/budget")
        @?= DispatchTool
          Incus
          ["exec", "demo-vm", "--", "curl", "-fsS", "-m", "5", "-o", "/dev/null", "http://localhost:30080/api/budget"],
    testCase "reachLeaf in a Lima VM folds to limactl shell -- curl …" $
      foldLeaf (inLimaVM limaVM localContext) (reachLeaf "http://localhost:30080/api/budget")
        @?= DispatchTool
          Lima
          ["shell", "demo-vm", "--", "curl", "-fsS", "-m", "5", "-o", "/dev/null", "http://localhost:30080/api/budget"],
    testCase "reachLeaf in a WSL2 VM folds to wsl -d -- curl …" $
      foldLeaf (inWsl2VM wslVM localContext) (reachLeaf "http://localhost:30080/api/budget")
        @?= DispatchTool
          Wsl
          ["-d", "hostbootstrap-demo", "--", "curl", "-fsS", "-m", "5", "-o", "/dev/null", "http://localhost:30080/api/budget"],
    testCase "a raw bash -lc leaf folds into the VM frame verbatim" $
      foldLeaf (inVM vm localContext) (RawCmd ["bash", "-lc", "echo hi"])
        @?= DispatchTool Incus ["exec", "demo-vm", "--", "bash", "-lc", "echo hi"],
    testCase "foldLift is the SelfSub special case of foldLeaf" $
      foldLeaf (inVM vm localContext) (SelfSub self sub)
        @?= foldLift self (inVM vm localContext) sub
  ]

containerCases :: [TestTree]
containerCases =
  [ testCase "a read-only mount gets :ro and --rm is omitted when clRemoveAfter is False" $
      containerRunArgs
        ContainerLift
          { clImage = "img",
            clMounts = [V.Mount {V.source = "/host", V.target = "/in", V.readOnly = True}],
            clExtraArgs = [],
            clRemoveAfter = False
          }
        ["x"]
        @?= ["run", "-v", "/host:/in:ro", "img", "x"]
  ]
