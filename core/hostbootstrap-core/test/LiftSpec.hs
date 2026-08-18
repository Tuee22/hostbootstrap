{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module LiftSpec (tests) where

import Data.List (isInfixOf, isPrefixOf, nub, sort)
import qualified Data.Map.Strict as Map
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Docker, Incus, Lima, Wsl))
import HostBootstrap.Lift
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import SourceGuard (haskellImports)
import System.Directory (getCurrentDirectory)
#ifndef mingw32_HOST_OS
import System.Exit (ExitCode (..))
#endif
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "LiftSpec"
    [ testGroup "foldLift across context stacks" foldCases,
      testGroup "foldLeaf places generic commands in the right frame" foldLeafCases,
      testGroup "later composition and network leaves use the same fold" additiveLeafCases,
      testGroup "containerRunArgs" containerCases,
      testGroup "config delivery streams the projection in-place on stdin" configDeliveryCases,
      testGroup "shared shell quoting boundary" shellQuoteCases,
      testGroup "local effect seam" effectCases,
      testGroup "constructive dependency direction" dependencyCases
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
      clRemoveAfter = True,
      clConfigDelivery = Nothing
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
        @?= DispatchTool Lima ["shell", "demo-vm", "--", "sudo", "-H", "/usr/local/bin/hostbootstrap-demo", "cluster", "up"],
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
            "sudo",
            "-H",
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
  [ testCase "a raw bash -lc leaf folds into the VM frame verbatim" $
      foldLeaf (inVM vm localContext) (RawCmd ["bash", "-lc", "echo hi"])
        @?= DispatchTool Incus ["exec", "demo-vm", "--", "bash", "-lc", "echo hi"],
    testCase "foldLift is the SelfSub special case of foldLeaf" $
      foldLeaf (inVM vm localContext) (SelfSub self sub)
        @?= foldLift self (inVM vm localContext) sub
  ]

additiveLeafCases :: [TestTree]
additiveLeafCases =
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
          ["shell", "demo-vm", "--", "sudo", "-H", "curl", "-fsS", "-m", "5", "-o", "/dev/null", "http://localhost:30080/api/budget"],
    testCase "reachLeaf in a WSL2 VM folds to wsl -d -- curl …" $
      foldLeaf (inWsl2VM wslVM localContext) (reachLeaf "http://localhost:30080/api/budget")
        @?= DispatchTool
          Wsl
          ["-d", "hostbootstrap-demo", "--", "curl", "-fsS", "-m", "5", "-o", "/dev/null", "http://localhost:30080/api/budget"]
  ]

containerCases :: [TestTree]
containerCases =
  [ testCase "a read-only mount gets :ro and --rm is omitted when clRemoveAfter is False" $
      containerRunArgs
        ContainerLift
          { clImage = "img",
            clMounts = [V.Mount {V.source = "/host", V.target = "/in", V.readOnly = True}],
            clExtraArgs = [],
            clRemoveAfter = False,
            clConfigDelivery = Nothing
          }
        ["x"]
        @?= ["run", "-v", "/host:/in:ro", "img", "x"]
  ]

-- | A container that streams its child config in-place on @stdin@.
deliveringContainer :: ContainerLift
deliveringContainer =
  container
    { clConfigDelivery =
        Just
          ( ConfigDelivery
              "/usr/local/bin/hostbootstrap-demo.dhall"
              "/usr/local/bin/hostbootstrap-demo"
              "PAYLOAD-DHALL-TEXT"
          )
    }

configDeliveryCases :: [TestTree]
configDeliveryCases =
  [ testCase "a delivering container overrides the entrypoint to write the sibling then exec" $
      containerRunArgs deliveringContainer ["project", "up"]
        @?= [ "run",
              "--rm",
              "-v",
              "/var/run/docker.sock:/var/run/docker.sock",
              "-i",
              "--entrypoint",
              "sh",
              "--network=host",
              "demo:local",
              "-c",
              "cat > '/usr/local/bin/hostbootstrap-demo.dhall' && exec '/usr/local/bin/hostbootstrap-demo' 'project' 'up'"
            ],
    testCase "the config payload is NOT in the argv (it rides stdin only)" $
      any ("PAYLOAD-DHALL-TEXT" `isInfixOf`) (containerRunArgs deliveringContainer ["project", "up"])
        @?= False,
    testCase "liftStdin carries a terminal delivering container's payload" $
      liftStdin (inContainer deliveringContainer localContext)
        @?= "PAYLOAD-DHALL-TEXT",
    testCase "liftStdin is empty for a non-delivering container" $
      liftStdin (inContainer container localContext)
        @?= "",
    testCase "liftStdin is empty for a VM frame (no container)" $
      liftStdin (inWsl2VM wslVM localContext)
        @?= "",
    testCase "configWriteScript single-quotes the write path and the exec argv" $
      configWriteScript
        (ConfigDelivery "/p/x.dhall" "/b/bin" "IGNORED")
        ["project", "up"]
        @?= "cat > '/p/x.dhall' && exec '/b/bin' 'project' 'up'"
  ]

shellQuoteCases :: [TestTree]
shellQuoteCases =
  [ testCase "quotes empty, whitespace, apostrophe, expansion, glob, and newline arguments" $
      shellQuoteArgs ["plain", "", "two words", "it's", "$HOME", "*.txt", "line\nbreak"]
        @?= "'plain' '' 'two words' 'it'\\''s' '$HOME' '*.txt' 'line\nbreak'"
#ifndef mingw32_HOST_OS
  , testCase "quoted argv round-trips through a POSIX shell without expansion" $ do
      let argv = ["two words", "it's", "$HOME", "*.txt", "line\nbreak", ""]
          script = "set -- " ++ shellQuoteArgs argv ++ "; printf '<%s>\\n' \"$@\""
      runSelf emptyHostConfig "/bin/sh" ["-c", script]
        >>= ( @?= Right
                ( ExitSuccess
                , "<two words>\n<it's>\n<$HOME>\n<*.txt>\n<line\nbreak>\n<>\n"
                , ""
                )
            )
#endif
  ]

effectCases :: [TestTree]
#ifdef mingw32_HOST_OS
effectCases =
  [ testCase "outer provider dispatch still uses the resolved-tool seam" $ do
      liftLeaf emptyHostConfig (inVM vm localContext) (RawCmd ["true"])
        >>= (@?= Left "incus not found on this host")
  ]
#else
effectCases =
  [ testCase "local raw leaf captures successful stdout through liftLeaf" $ do
      liftLeaf emptyHostConfig localContext (RawCmd ["/bin/sh", "-c", "printf effect-ok"])
        >>= (@?= Right (ExitSuccess, "effect-ok", ""))
  , testCase "local self subcommand captures successful stdout through liftSubcommand" $ do
      let shellSelf = mkSelfRef "/bin/sh" "/bin/sh"
      liftSubcommand emptyHostConfig shellSelf localContext ["-c", "printf self-ok"]
        >>= (@?= Right (ExitSuccess, "self-ok", ""))
  , testCase "with-stdin forwards bytes and its empty input is identical to the ordinary seam" $ do
      let leaf = RawCmd ["/bin/cat"]
      ordinary <- liftLeaf emptyHostConfig localContext leaf
      emptyInput <- liftLeafWithStdin emptyHostConfig localContext leaf ""
      payload <- liftLeafWithStdin emptyHostConfig localContext leaf "line one\nline two\n"
      emptyInput @?= ordinary
      payload @?= Right (ExitSuccess, "line one\nline two\n", "")
  , testCase "local exec failure is returned structurally" $ do
      result <- runSelf emptyHostConfig "/hostbootstrap/definitely/missing/executable" []
      case result of
        Left message -> assertBool message ("could not exec /hostbootstrap/definitely/missing/executable" `isInfixOf` message)
        Right success -> assertBool ("expected exec failure, got " ++ show success) False
  , testCase "outer provider dispatch uses the resolved-tool seam" $ do
      liftLeaf emptyHostConfig (inVM vm localContext) (RawCmd ["true"])
        >>= (@?= Left "incus not found on this host")
  ]
#endif

emptyHostConfig :: HostConfig
emptyHostConfig = HostConfig (Substrate LinuxCpu Amd64) Map.empty

dependencyCases :: [TestTree]
dependencyCases =
  [ testCase "generic Lift has the exact lower import set and no realization dependency" $ do
      root <- repositoryRoot
      source <- readFile (root </> "core/hostbootstrap-core/src/HostBootstrap/Lift.hs")
      let imports = hostBootstrapImports source
          allowed =
            [ "HostBootstrap.Config.Vocab",
              "HostBootstrap.Effect.Interpreter",
              "HostBootstrap.Effect.Quote",
              "HostBootstrap.Effect.Run",
              "HostBootstrap.Effect.Vocabulary",
              "HostBootstrap.HostConfig",
              "HostBootstrap.HostTool",
              "HostBootstrap.Lift.Context"
            ]
      imports @?= allowed
      mapM_
        ( \forbiddenPrefix ->
            assertBool
              ("forbidden generic Lift import prefix: " ++ forbiddenPrefix)
              (not (any (forbiddenPrefix `isPrefixOf`) imports))
        )
        [ "HostBootstrap.Incus",
          "HostBootstrap.Lima",
          "HostBootstrap.Wsl2",
          "HostBootstrap.Registry",
          "HostBootstrap.Substrate.Provider",
          "HostBootstrap.Cluster"
        ]
  , testCase "import scanner covers source pragmas, qualifiers, packages, comments, and line breaks" $
      hostBootstrapImports
        ( unlines
            [ "import {-# SOURCE #-} safe qualified"
            , "  HostBootstrap.Alpha as Alpha"
            , "import -- an import may continue after a line comment"
            , "  qualified"
            , "  \"hostbootstrap-core\""
            , "  HostBootstrap.Beta"
            , "import qualified Data.Map.Strict as Map"
            , "{- outer import HostBootstrap.Commented {- import HostBootstrap.Nested -} still commented -}"
            , "literal = \"import HostBootstrap.StringLiteral\""
            ]
        )
        @?= ["HostBootstrap.Alpha", "HostBootstrap.Beta"]
  ]

repositoryRoot :: IO FilePath
repositoryRoot = do
  cwd <- getCurrentDirectory
  found <- findRepoRoot cwd
  maybe (fail ("could not locate repository root from " ++ cwd)) pure found

hostBootstrapImports :: String -> [String]
hostBootstrapImports = sort . nub . filter ("HostBootstrap." `isPrefixOf`) . haskellImports
