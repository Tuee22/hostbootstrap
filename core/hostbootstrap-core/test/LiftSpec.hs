{-# LANGUAGE OverloadedStrings #-}

module LiftSpec (tests) where

import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.HostTool (HostTool (Docker, Incus))
import HostBootstrap.Incus (IncusVM (..))
import HostBootstrap.Lift
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "LiftSpec"
    [ testGroup "foldLift across context stacks" foldCases,
      testGroup "containerRunArgs" containerCases
    ]

-- Fixtures.
vm :: IncusVM
vm = IncusVM "demo-vm" "images:ubuntu/24.04"

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
          ]
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
