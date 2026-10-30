{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module LiftSpec (tests, posixShellSupported) where

import ConditionalCase (conditionalCase)
import Control.Exception (AsyncException (UserInterrupt), bracket, finally, throwIO, try)
import Control.Monad (forM_)
import qualified Data.ByteString as BS
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf, nub, sort)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TextIO
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Effect (
  CapturedRun (..),
  EffectStdio (..),
  EffectTarget (SelfTarget, ToolTarget),
  HostCommand (commandArguments, commandStdio, commandTarget),
  renderRunFailure,
  runCaptured,
 )
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Curl, Docker, Incus, Lima, Wsl), mkAbsExe)
import HostBootstrap.Lift
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import Numeric (readOct)
import SourceGuard (haskellImports)
import qualified SourceGuard
import System.Directory (doesPathExist, getCurrentDirectory)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, (</>))
import System.IO (SeekMode (AbsoluteSeek), hClose, hFlush, hSeek, hSetNewlineMode, stderr, universalNewlineMode)
import System.IO.Temp (withSystemTempDirectory, withSystemTempFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "LiftSpec"
    [ testGroup "foldLift across context stacks" foldCases,
      testGroup "foldLeaf places generic commands in the right frame" foldLeafCases,
      testGroup "later composition and network leaves use the same fold" additiveLeafCases,
      testGroup "containerRunArgs" containerCases,
      testGroup "config delivery copies a projection before starting the container" configDeliveryCases,
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
      clPlacement = ProviderGuestContainer,
      clMounts = [sockMount],
      clExtraArgs = ["--network=host"],
      clRemoveAfter = True,
      clConfigDelivery = Nothing
    }

self :: SelfRef
self = mkSelfRef (LocalSelfPath "/proc/self/exe") (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")

sub :: [String]
sub = ["cluster", "up"]

foldCases :: [TestTree]
foldCases =
  [ testCase "Local runs the binary directly" $
      foldLift self localContext sub
        @?= DispatchLocal "/proc/self/exe" ["cluster", "up"],
    testCase "InVM dispatches incus exec with the in-VM binary path" $
      foldLift self (vmContext (inVM vm emptyVMStack)) sub
        @?= DispatchTool Incus ["exec", "demo-vm", "--", "/usr/local/bin/hostbootstrap-demo", "cluster", "up"],
    testCase "InLimaVM dispatches limactl shell with the in-VM binary path" $
      foldLift self (vmContext (inLimaVM limaVM emptyVMStack)) sub
        @?= DispatchTool Lima ["shell", "demo-vm", "--", "sudo", "-H", "/usr/local/bin/hostbootstrap-demo", "cluster", "up"],
    testCase "InWsl2VM dispatches wsl -d with the in-VM binary path" $
      foldLift self (vmContext (inWsl2VM wslVM emptyVMStack)) sub
        @?= DispatchTool Wsl ["-d", "hostbootstrap-demo", "--exec", "/usr/local/bin/hostbootstrap-demo", "cluster", "up"],
    testCase "InContainer dispatches docker run (ENTRYPOINT is the binary, no self token)" $
      foldLift self (inContainer container emptyVMStack) sub
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
      foldLift self (inContainer container (inVM vm emptyVMStack)) sub
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
      foldLift self (inContainer container (inLimaVM limaVM emptyVMStack)) sub
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
    testCase "WSL2 VM-then-container nests: wsl -d distro --exec docker run --rm img sub" $
      foldLift self (inContainer container (inWsl2VM wslVM emptyVMStack)) sub
        @?= DispatchTool
          Wsl
          [ "-d",
            "hostbootstrap-demo",
            "--exec",
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
      foldLeaf (vmContext (inVM vm emptyVMStack)) (RawCmd "bash" ["-lc", "echo hi"])
        @?= DispatchTool Incus ["exec", "demo-vm", "--", "bash", "-lc", "echo hi"],
    testCase "foldLift is the SelfSub special case of foldLeaf" $
      foldLeaf (vmContext (inVM vm emptyVMStack)) (SelfSub self sub)
        @?= foldLift self (vmContext (inVM vm emptyVMStack)) sub,
    testCase "a local self leaf targets this binary's absolute path" $ do
      executable <- getExecutablePath
      let nativeSelf = mkSelfRef (LocalSelfPath executable) (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
          command = foldLeafCommand localContext (SelfSub nativeSelf sub)
      assertBool "the self executable path is absolute" (isAbsolute executable)
      fmap commandTarget command @?= Right (SelfTarget executable)
      fmap commandArguments command @?= Right ["cluster", "up"],
    testCase "a local reachability leaf targets the registered Curl tool" $ do
      let command = foldLeafCommand localContext (reachLeaf "http://localhost:30080/api/budget")
      fmap commandTarget command @?= Right (ToolTarget Curl)
      fmap commandArguments command @?= Right ["-fsS", "-m", "5", "-o", "/dev/null", "http://localhost:30080/api/budget"],
    testCase "a raw leaf in a container is passed as image entrypoint arguments" $
      foldLeaf (inContainer container emptyVMStack) (RawCmd "x" ["y"])
        @?= DispatchTool Docker ["run", "--rm", "-v", "/var/run/docker.sock:/var/run/docker.sock", "--network=host", "demo:local", "x", "y"],
    testCase "a single Incus lifecycle channel retains its non-empty binary" $
      foldLeaf (vmContext (inVM vm emptyVMStack)) (lifecycleProcessLeaf "/usr/local/bin/hostbootstrap-demo" ["--hostbootstrap-lifecycle-child"])
        @?= DispatchTool Incus ["exec", "demo-vm", "--cwd", "/", "-T", "--", "/usr/local/bin/hostbootstrap-demo", "--hostbootstrap-lifecycle-child"],
    testCase "a single Lima lifecycle channel retains its non-empty binary" $
      foldLeaf (vmContext (inLimaVM limaVM emptyVMStack)) (lifecycleProcessLeaf "/usr/local/bin/hostbootstrap-demo" ["--hostbootstrap-lifecycle-child"])
        @?= DispatchTool Lima ["shell", "--workdir", "/", "demo-vm", "--", "sudo", "-n", "-H", "/usr/local/bin/hostbootstrap-demo", "--hostbootstrap-lifecycle-child"],
    testCase "a single WSL lifecycle channel preserves argv through --exec" $
      foldLeaf (vmContext (inWsl2VM wslVM emptyVMStack)) (lifecycleProcessLeaf "/usr/local/bin/hostbootstrap-demo" ["--hostbootstrap-lifecycle-child"])
        @?= DispatchTool Wsl ["-d", "hostbootstrap-demo", "--cd", "/", "--exec", "sudo", "-n", "-H", "/usr/local/bin/hostbootstrap-demo", "--hostbootstrap-lifecycle-child"],
    testCase "an Incus lifecycle crossing inside WSL retains placement at both layers" $
      foldLeaf
        (vmContext (inVM vm (inWsl2VM wslVM emptyVMStack)))
        (lifecycleProcessLeaf "/usr/local/bin/hostbootstrap-demo" ["--hostbootstrap-lifecycle-child"])
        @?= DispatchTool
          Wsl
          [ "-d", "hostbootstrap-demo", "--cd", "/", "--exec", "sudo", "-n", "-H",
            "incus", "exec", "demo-vm", "--cwd", "/", "-T", "--",
            "/usr/local/bin/hostbootstrap-demo", "--hostbootstrap-lifecycle-child"
          ],
    testCase "every lifecycle VM crossing preserves one metacharacter argument" $
      forM_
        [ ( vmContext (inVM vm emptyVMStack), Incus,
            ["exec", "demo-vm", "--cwd", "/", "-T", "--", "/usr/local/bin/hostbootstrap-demo", "--hostbootstrap-lifecycle-child", "a&b;$c"]
          ),
          ( vmContext (inLimaVM limaVM emptyVMStack), Lima,
            ["shell", "--workdir", "/", "demo-vm", "--", "sudo", "-n", "-H", "/usr/local/bin/hostbootstrap-demo", "--hostbootstrap-lifecycle-child", "a&b;$c"]
          ),
          ( vmContext (inWsl2VM wslVM emptyVMStack), Wsl,
            ["-d", "hostbootstrap-demo", "--cd", "/", "--exec", "sudo", "-n", "-H", "/usr/local/bin/hostbootstrap-demo", "--hostbootstrap-lifecycle-child", "a&b;$c"]
          )
        ] $ \(context, tool, arguments) ->
          foldLeaf context (lifecycleProcessLeaf "/usr/local/bin/hostbootstrap-demo" ["--hostbootstrap-lifecycle-child", "a&b;$c"])
            @?= DispatchTool tool arguments,
    testCase "a composed Incus lifecycle channel is noninteractive and rooted before Docker" $
      foldLeaf
        (inContainer container (inVM vm emptyVMStack))
        (lifecycleProcessLeaf "" ["--hostbootstrap-lifecycle-child"])
        @?= DispatchTool
          Incus
          [ "exec",
            "demo-vm",
            "--cwd",
            "/",
            "-T",
            "--",
            "docker",
            "run",
            "--rm",
            "-v",
            "/var/run/docker.sock:/var/run/docker.sock",
            "--network=host",
            "demo:local",
            "--hostbootstrap-lifecycle-child"
          ],
    testCase "a composed Lima lifecycle channel is noninteractive and rooted before Docker" $
      foldLeaf
        (inContainer container (inLimaVM limaVM emptyVMStack))
        (lifecycleProcessLeaf "" ["--hostbootstrap-lifecycle-child"])
        @?= DispatchTool
          Lima
          [ "shell",
            "--workdir",
            "/",
            "demo-vm",
            "--",
            "sudo",
            "-n",
            "-H",
            "docker",
            "run",
            "--rm",
            "-v",
            "/var/run/docker.sock:/var/run/docker.sock",
            "--network=host",
            "demo:local",
            "--hostbootstrap-lifecycle-child"
          ],
    testCase "a composed WSL lifecycle channel is noninteractive and rooted before Docker" $
      foldLeaf
        (inContainer container (inWsl2VM wslVM emptyVMStack))
        (lifecycleProcessLeaf "" ["--hostbootstrap-lifecycle-child"])
        @?= DispatchTool
          Wsl
          [ "-d",
            "hostbootstrap-demo",
            "--cd",
            "/",
            "--exec",
            "sudo",
            "-n",
            "-H",
            "docker",
            "run",
            "--rm",
            "-v",
            "/var/run/docker.sock:/var/run/docker.sock",
            "--network=host",
            "demo:local",
            "--hostbootstrap-lifecycle-child"
          ]
  ]

additiveLeafCases :: [TestTree]
additiveLeafCases =
  [ testCase "reachLeaf locally runs curl directly (no self path)" $
      foldLeaf localContext (reachLeaf "http://localhost:30080/api/budget")
        @?= DispatchLocalRaw "curl" ["-fsS", "-m", "5", "-o", "/dev/null", "http://localhost:30080/api/budget"],
    testCase "reachLeaf in an Incus VM folds to incus exec -- curl …" $
      foldLeaf (vmContext (inVM vm emptyVMStack)) (reachLeaf "http://localhost:30080/api/budget")
        @?= DispatchTool
          Incus
          ["exec", "demo-vm", "--", "curl", "-fsS", "-m", "5", "-o", "/dev/null", "http://localhost:30080/api/budget"],
    testCase "reachLeaf in a Lima VM folds to limactl shell -- curl …" $
      foldLeaf (vmContext (inLimaVM limaVM emptyVMStack)) (reachLeaf "http://localhost:30080/api/budget")
        @?= DispatchTool
          Lima
          ["shell", "demo-vm", "--", "sudo", "-H", "curl", "-fsS", "-m", "5", "-o", "/dev/null", "http://localhost:30080/api/budget"],
    testCase "reachLeaf in a WSL2 VM folds to wsl -d --exec curl …" $
      foldLeaf (vmContext (inWsl2VM wslVM emptyVMStack)) (reachLeaf "http://localhost:30080/api/budget")
        @?= DispatchTool
          Wsl
          ["-d", "hostbootstrap-demo", "--exec", "curl", "-fsS", "-m", "5", "-o", "/dev/null", "http://localhost:30080/api/budget"]
  ]

containerCases :: [TestTree]
containerCases =
  [ testCase "a read-only mount gets :ro and --rm is omitted when clRemoveAfter is False" $
      containerRunArgs
        ContainerLift
          { clImage = "img",
            clPlacement = ProviderGuestContainer,
            clMounts = [V.Mount {V.source = "/host", V.target = "/in", V.readOnly = True}],
            clExtraArgs = [],
            clRemoveAfter = False,
            clConfigDelivery = Nothing
          }
        ["x"]
        @?= ["run", "-v", "/host:/in:ro", "img", "x"]
  ]

-- | A container whose child projection is copied before its entry point starts.
deliveringContainer :: ContainerLift
deliveringContainer =
  container
    { clConfigDelivery =
        Just
          ( ConfigDelivery
              "/usr/local/bin/hostbootstrap-demo.dhall"
              "PAYLOAD-DHALL-TEXT"
          )
    }

configDeliveryCases :: [TestTree]
configDeliveryCases =
  [ testCase "delivery retains the VM prefix and refuses a singular command" $ do
      let prefix = vmContext (inVM vm emptyVMStack)
          context = inContainer deliveringContainer (liftVMStack prefix)
      foldLift self context ["project", "up"]
        @?= DispatchContainerDelivery prefix deliveringContainer ["project", "up"]
      foldLeafCommand context deliveryLeaf
        @?= Left "container config delivery requires the staged command runner",
    testCase "create preserves the image entry point, mounts, extras, and command" $ do
      containerCreateArgs deliveringContainer ["project", "up"] @?= deliveryCreateArgs
      let retained = deliveringContainer {clRemoveAfter = False, clMounts = [V.Mount "/host" "/in" True]}
      containerCreateArgs retained ["project", "up"]
        @?= ["create", "-v", "/host:/in:ro", "--network=host", "demo:local", "project", "up"],
    testCase "the actual workflow copies explicit input and returns only the start result" $ do
      let input = "actual projection é\n"
          result = CapturedRun ExitSuccess "child output\n" "child diagnostic\n"
      (runner, recorded, finished) <- commandRecorder [captured ExitSuccess (" \n" ++ containerId ++ "\t") "create chatter", captured ExitSuccess "copy chatter" "copy diagnostic", pure (Right result)]
      liftLeafWithStdinWith runner (inContainer deliveringContainer emptyVMStack) deliveryLeaf input
        >>= (@?= Right (ExitSuccess, "child output\n", "child diagnostic\n"))
      finished
      commands <- recorded
      assertCommands Docker [deliveryCreateArgs, deliveryCopyArgs, deliveryStartArgs] commands
      withThreeCommands commands $ \createCommand copyCommand startCommand -> do
        map commandInput [createCommand, startCommand] @?= ["", ""]
        assertTarBytes "hostbootstrap-demo.dhall" input (utf8 (commandInput copyCommand))
      assertBool "neither stored nor explicit projection enters argv" $
        all (all (\argument -> not ("PAYLOAD-DHALL-TEXT" `isInfixOf` argument) && not (input `isInfixOf` argument)) . commandArguments) commands,
    testCase "a non-delivering container still uses one docker run with unchanged stdin" $ do
      (runner, recorded, finished) <- commandRecorder [captured ExitSuccess "plain" ""]
      liftLeafWithStdinWith runner (inContainer container emptyVMStack) deliveryLeaf "ordinary stdin\n"
        >>= (@?= Right (ExitSuccess, "plain", ""))
      finished
      commands <- recorded
      assertCommands Docker [["run", "--rm", "-v", "/var/run/docker.sock:/var/run/docker.sock", "--network=host", "demo:local", "project", "up"]] commands
      map commandInput commands @?= ["ordinary stdin\n"],
    testCase "liftStdin carries a terminal delivering container's payload" $
      liftStdin (inContainer deliveringContainer emptyVMStack)
        @?= "PAYLOAD-DHALL-TEXT",
    testCase "liftStdin retains the innermost container payload through every VM nesting" $
      map liftStdin
        [ inContainer deliveringContainer (inVM vm emptyVMStack),
          inContainer deliveringContainer (inLimaVM limaVM emptyVMStack),
          inContainer deliveringContainer (inWsl2VM wslVM emptyVMStack)
        ]
        @?= replicate 3 "PAYLOAD-DHALL-TEXT",
    testCase "liftStdin is empty for a non-delivering container" $
      liftStdin (inContainer container emptyVMStack)
        @?= "",
    testCase "liftStdin is empty for a VM frame (no container)" $
      liftStdin (vmContext (inWsl2VM wslVM emptyVMStack))
        @?= "",
    testCase "the production seam and shell absence stay tied to staged delivery" $ do
      -- Rationale: DEVELOPMENT_PLAN/rationale.md#container-configuration-is-copied-before-its-entry-point-starts
      root <- repositoryRoot
      source <- Text.unpack <$> TextIO.readFile (root </> "core/hostbootstrap-core/src/HostBootstrap/Lift.hs")
      definitions <- either (\err -> assertFailure err >> pure []) pure (SourceGuard.haskellDefinitionNames source)
      assertBool "the old shell writer has no definition" ("configWriteScript" `notElem` definitions)
      let tokens = SourceGuard.haskellTokens source
      forM_ ["sh", "bash", "-c", "--entrypoint"] $ \literal ->
        assertBool ("no container interpreter override: " ++ literal) (show literal `notElem` tokens)
      seam <- either (\err -> assertFailure err >> pure []) pure (SourceGuard.haskellDefinitionTokens "liftLeafWithStdin" source)
      seam @?= SourceGuard.haskellTokens "liftLeafWithStdin cfg = liftLeafWithStdinWith (interpretHostCommand cfg)"
  ]
    ++ archiveCases
    ++ nestedDeliveryCases
    ++ refusedDeliveryCases
    ++ failedDeliveryCases
    ++ exceptionalDeliveryCases

deliveryLeaf :: LiftLeaf
deliveryLeaf = SelfSub self ["project", "up"]

containerId :: String
containerId = replicate 64 'a'

deliveryCreateArgs, deliveryCopyArgs, deliveryStartArgs, deliveryRemoveArgs :: [String]
deliveryCreateArgs = ["create", "--rm", "-v", "/var/run/docker.sock:/var/run/docker.sock", "--network=host", "demo:local", "project", "up"]
deliveryCopyArgs = ["cp", "-", containerId ++ ":/usr/local/bin"]
deliveryStartArgs = ["start", "-a", containerId]
deliveryRemoveArgs = ["rm", "-f", containerId]

captured :: ExitCode -> String -> String -> IO (Either String CapturedRun)
captured status output errors = pure (Right (CapturedRun status output errors))

commandInput :: HostCommand -> String
commandInput = effectStdin . commandStdio

commandRecorder :: [IO (Either String CapturedRun)] -> IO (HostCommand -> IO (Either String CapturedRun), IO [HostCommand], IO ())
commandRecorder actions = do
  pending <- newIORef actions
  recorded <- newIORef []
  let runner command = do
        modifyIORef' recorded (++ [command])
        remaining <- readIORef pending
        case remaining of
          [] -> assertFailure ("unexpected command: " ++ show command) >> pure (Left "unexpected command")
          action : rest -> writeIORef pending rest >> action
      finished = readIORef pending >>= (@?= 0) . length
  pure (runner, readIORef recorded, finished)

assertCommands :: HostTool -> [[String]] -> [HostCommand] -> IO ()
assertCommands target arguments commands = do
  map commandTarget commands @?= replicate (length arguments) (ToolTarget target)
  map commandArguments commands @?= arguments

withThreeCommands :: [HostCommand] -> (HostCommand -> HostCommand -> HostCommand -> IO ()) -> IO ()
withThreeCommands commands use = case commands of
  [createCommand, copyCommand, startCommand] -> use createCommand copyCommand startCommand
  _ -> assertFailure ("expected exactly create/copy/start, got " ++ show commands)

utf8 :: String -> BS.ByteString
utf8 = TE.encodeUtf8 . Text.pack

archiveCases :: [TestTree]
archiveCases =
  [ testCase ("the actual copy carries a byte-correct ustar archive: " ++ label) $ do
      let config = deliveringContainer {clConfigDelivery = Just (ConfigDelivery path "metadata must not be copied")}
      (runner, recorded, finished) <- commandRecorder [captured ExitSuccess containerId "", captured ExitSuccess "" "", captured ExitSuccess "" ""]
      liftLeafWithStdinWith runner (inContainer config emptyVMStack) deliveryLeaf payload >>= (@?= Right (ExitSuccess, "", ""))
      finished
      commands <- recorded
      assertCommands Docker [deliveryCreateArgs, ["cp", "-", containerId ++ ":/config"], deliveryStartArgs] commands
      withThreeCommands commands $ \createCommand copyCommand startCommand -> do
        assertTarBytes name payload (utf8 (commandInput copyCommand))
        map commandInput [createCommand, startCommand] @?= ["", ""]
  | (label, path, name, payload) <-
      [ ("empty", "/config/empty.dhall", "empty.dhall", ""),
        ("512 bytes", "/config/exact.dhall", "exact.dhall", replicate 512 'x'),
        ("513 bytes", "/config/padded.dhall", "padded.dhall", replicate 513 'y'),
        ("Unicode name and payload", "/config/projéct.dhall", "projéct.dhall", "λ é\n\0tail"),
        ("100 UTF-8 name bytes", "/config/" ++ replicate 50 'é', replicate 50 'é', "name boundary")
      ]
  ]

assertTarBytes :: String -> String -> BS.ByteString -> IO ()
assertTarBytes name payload archive = do
  let header = BS.take 512 archive
      nameBytes = utf8 name
      payloadBytes = utf8 payload
      payloadLength = BS.length payloadBytes
      padding = (512 - payloadLength `mod` 512) `mod` 512
      field offset count = BS.take count (BS.drop offset header)
  BS.length archive @?= 512 + payloadLength + padding + 1024
  BS.length header @?= 512
  field 0 100 @?= nameBytes <> BS.replicate (100 - BS.length nameBytes) 0
  tarOctal (field 100 8) >>= (@?= 420)
  tarOctal (field 108 8) >>= (@?= 0)
  tarOctal (field 116 8) >>= (@?= 0)
  tarOctal (field 124 12) >>= (@?= toInteger payloadLength)
  field 156 1 @?= BS.singleton 48
  field 157 100 @?= BS.replicate 100 0
  field 257 8 @?= utf8 "ustar\0" <> utf8 "00"
  checksum <- tarOctal (field 148 8)
  checksum @?= sum (map toInteger (BS.unpack (BS.take 148 header <> BS.replicate 8 32 <> BS.drop 156 header)))
  BS.take payloadLength (BS.drop 512 archive) @?= payloadBytes
  BS.drop (512 + payloadLength) archive @?= BS.replicate (padding + 1024) 0

tarOctal :: BS.ByteString -> IO Integer
tarOctal bytes = case readOct (map (toEnum . fromIntegral) (BS.unpack bytes)) of
  [(number, rest)] | all (`elem` ['\0', ' ']) rest -> pure number
  other -> assertFailure ("invalid ustar octal field: " ++ show other) >> pure 0

nestedDeliveryCases :: [TestTree]
nestedDeliveryCases =
  [ testCase ("all three delivery commands retain the " ++ label ++ " prefix") $ do
      (runner, recorded, finished) <- commandRecorder [captured ExitSuccess containerId "", captured ExitSuccess "" "", captured ExitSuccess "" ""]
      liftLeafWithStdinWith runner (inContainer deliveringContainer (liftVMStack prefix)) deliveryLeaf "nested" >>= (@?= Right (ExitSuccess, "", ""))
      finished
      commands <- recorded
      assertCommands tool (map (arguments ++) [deliveryCreateArgs, deliveryCopyArgs, deliveryStartArgs]) commands
      withThreeCommands commands $ \_ copyCommand _ ->
        assertTarBytes "hostbootstrap-demo.dhall" "nested" (utf8 (commandInput copyCommand))
  | (label, prefix, tool, arguments) <-
      [ ("Incus", vmContext (inVM vm emptyVMStack), Incus, ["exec", "demo-vm", "--", "docker"]),
        ("Lima", vmContext (inLimaVM limaVM emptyVMStack), Lima, ["shell", "demo-vm", "--", "sudo", "-H", "docker"]),
        ("WSL2", vmContext (inWsl2VM wslVM emptyVMStack), Wsl, ["-d", "hostbootstrap-demo", "--exec", "docker"]),
        ("two Incus VMs", vmContext (inVM (IncusVM "nested-vm" "image") (inVM vm emptyVMStack)), Incus, ["exec", "demo-vm", "--", "incus", "exec", "nested-vm", "--", "docker"])
      ]
  ]

refusedDeliveryCases :: [TestTree]
refusedDeliveryCases =
  [ testCase "invalid archive destinations refuse before create" $ do
      forM_ ["relative.dhall", "", "/", "/config/", "/config/.", "/config/..", "/config/nul\0name"] $ \path ->
        refusePath path "container config delivery requires a POSIX-absolute file path"
      refusePath ("/config/" ++ replicate 50 'é' ++ "x") "container config delivery filename exceeds the ustar 100-byte limit",
    -- Malformed layer lists are now refused by LiftContextSpec's checked
    -- reconstruction cases. VMLayerAfterContainer holds the builder type
    -- boundary; no malformed closed context can reach this runtime workflow.
    testCase "malformed create output never guesses a cleanup target" $
      forM_ ["", "short", replicate 64 'A', containerId ++ "\n" ++ containerId, "--name victim"] $ \identifier -> do
        (runner, recorded, finished) <- commandRecorder [captured ExitSuccess identifier ""]
        liftLeafWithStdinWith runner (inContainer deliveringContainer emptyVMStack) deliveryLeaf "input"
          >>= (@?= Left "docker create did not return one full container ID")
        finished
        recorded >>= assertCommands Docker [deliveryCreateArgs]
  ]
  where
    refusePath path expected = do
      let config = deliveringContainer {clConfigDelivery = Just (ConfigDelivery path "metadata")}
      configDeliveryTar path "input" @?= Left expected
      (runner, recorded, finished) <- commandRecorder []
      liftLeafWithStdinWith runner (inContainer config emptyVMStack) deliveryLeaf "input" >>= (@?= Left expected)
      finished
      recorded >>= (@?= [])

failedDeliveryCases :: [TestTree]
failedDeliveryCases =
  [ failureCase "create refusal stops immediately" True [pure (Left "create refused")] (Left "create refused") [deliveryCreateArgs],
    failureCase "create failure returns its own status and streams" True [captured (ExitFailure 2) "create output" "create failed"] (Right (ExitFailure 2, "create output", "create failed")) [deliveryCreateArgs],
    failureCase "copy refusal cleans up without starting" True [created, pure (Left "copy refused"), removed] (Left "copy refused") [deliveryCreateArgs, deliveryCopyArgs, deliveryRemoveArgs],
    failureCase "copy failure preserves its status and cleans up" True [created, captured (ExitFailure 3) "copy out" "copy failed", removed] (Right (ExitFailure 3, "copy out", "copy failed")) [deliveryCreateArgs, deliveryCopyArgs, deliveryRemoveArgs],
    failureCase "start refusal cleans up" True [created, copied, pure (Left "start refused"), removed] (Left "start refused") [deliveryCreateArgs, deliveryCopyArgs, deliveryStartArgs, deliveryRemoveArgs],
    failureCase "attached child failure retains the final result and attempts cleanup" True [created, copied, captured (ExitFailure 7) "child out" "child failed", removed] (Right (ExitFailure 7, "child out", "child failed")) [deliveryCreateArgs, deliveryCopyArgs, deliveryStartArgs, deliveryRemoveArgs],
    failureCase "copy failure skips cleanup when removal is not requested" False [created, pure (Left "copy refused")] (Left "copy refused") [retainedCreate, deliveryCopyArgs],
    failureCase "start failure skips cleanup when removal is not requested" False [created, copied, captured (ExitFailure 7) "child out" "child failed"] (Right (ExitFailure 7, "child out", "child failed")) [retainedCreate, deliveryCopyArgs, deliveryStartArgs],
    failureCase "cleanup refusal appends to the primary refusal" True [created, pure (Left "copy refused"), pure (Left "cleanup refused")] (Left "copy refused\ncontainer cleanup failed: cleanup refused") [deliveryCreateArgs, deliveryCopyArgs, deliveryRemoveArgs],
    failureCase "cleanup failure after an attached failure preserves the child status" True [created, copied, captured (ExitFailure 7) "child out" "child failed", captured (ExitFailure 1) "rm out" "already absent"] (Right (ExitFailure 7, "child out", "child failed\ncontainer cleanup failed: docker rm -f exited ExitFailure 1: rm outalready absent")) [deliveryCreateArgs, deliveryCopyArgs, deliveryStartArgs, deliveryRemoveArgs],
    testCase "failed nested delivery also folds its removal through the VM prefix" $ do
      (runner, recorded, finished) <- commandRecorder [created, pure (Left "copy refused"), removed]
      liftLeafWithStdinWith runner (inContainer deliveringContainer (inWsl2VM wslVM emptyVMStack)) deliveryLeaf "input" >>= (@?= Left "copy refused")
      finished
      recorded >>= assertCommands Wsl (map (["-d", "hostbootstrap-demo", "--exec", "docker"] ++) [deliveryCreateArgs, deliveryCopyArgs, deliveryRemoveArgs])
  ]
  where
    created = captured ExitSuccess containerId ""
    copied = captured ExitSuccess "copy chatter" ""
    removed = captured ExitSuccess "cleanup chatter" ""
    retainedCreate = ["create", "-v", "/var/run/docker.sock:/var/run/docker.sock", "--network=host", "demo:local", "project", "up"]
    failureCase label remove actions expected arguments = testCase label $ do
      (runner, recorded, finished) <- commandRecorder actions
      let config = deliveringContainer {clRemoveAfter = remove}
      liftLeafWithStdinWith runner (inContainer config emptyVMStack) deliveryLeaf "input" >>= (@?= expected)
      finished
      commands <- recorded
      assertCommands Docker arguments commands
      forM_ commands $ \command -> case commandArguments command of
        "cp" : _ -> pure ()
        _ -> commandInput command @?= ""

exceptionalDeliveryCases :: [TestTree]
exceptionalDeliveryCases =
  [ testCase "a copy interruption cleans up and rethrows the original interruption" $ do
      (runner, recorded, finished) <- commandRecorder [created, throwIO UserInterrupt, removed]
      result <- try (liftLeafWithStdinWith runner context deliveryLeaf "input")
      (result :: Either AsyncException (Either String (ExitCode, String, String))) @?= Left UserInterrupt
      finished
      recorded >>= assertCommands Docker [deliveryCreateArgs, deliveryCopyArgs, deliveryRemoveArgs],
    testCase "a synchronous start exception cleans up and remains an exception" $ do
      (runner, recorded, finished) <- commandRecorder [created, copied, ioError (userError "start exception"), removed]
      result <- try (liftLeafWithStdinWith runner context deliveryLeaf "input")
      case (result :: Either IOError (Either String (ExitCode, String, String))) of
        Left failure -> assertBool "original start exception retained" ("start exception" `isInfixOf` show failure)
        Right value -> assertFailure ("expected start exception, got " ++ show value)
      finished
      recorded >>= assertCommands Docker [deliveryCreateArgs, deliveryCopyArgs, deliveryStartArgs, deliveryRemoveArgs],
    testCase "cleanup refusal is reported without replacing an active interruption" $ do
      (runner, recorded, finished) <- commandRecorder [created, throwIO UserInterrupt, pure (Left "cleanup refused")]
      (result, errors) <- captureDeliveryStderr (try (liftLeafWithStdinWith runner context deliveryLeaf "input"))
      (result :: Either AsyncException (Either String (ExitCode, String, String))) @?= Left UserInterrupt
      assertBool "actual cleanup refusal reported" ("container cleanup failed: cleanup refused" `isInfixOf` errors)
      finished
      recorded >>= assertCommands Docker [deliveryCreateArgs, deliveryCopyArgs, deliveryRemoveArgs],
    testCase "an interruption during normal cleanup propagates" $ do
      (runner, recorded, finished) <- commandRecorder [created, captured (ExitFailure 3) "copy out" "copy failed", throwIO UserInterrupt]
      result <- try (liftLeafWithStdinWith runner context deliveryLeaf "input")
      (result :: Either AsyncException (Either String (ExitCode, String, String))) @?= Left UserInterrupt
      finished
      recorded >>= assertCommands Docker [deliveryCreateArgs, deliveryCopyArgs, deliveryRemoveArgs]
  ]
  where
    context = inContainer deliveringContainer emptyVMStack
    created = captured ExitSuccess containerId ""
    copied = captured ExitSuccess "" ""
    removed = captured ExitSuccess "" ""

captureDeliveryStderr :: IO a -> IO (a, String)
captureDeliveryStderr action = withSystemTempFile "hostbootstrap-delivery-stderr" $ \_ output ->
  bracket (hDuplicate stderr) hClose $ \original -> do
    result <- (hDuplicateTo output stderr >> action) `finally` (hFlush stderr >> hDuplicateTo original stderr)
    hSeek output AbsoluteSeek 0
    hSetNewlineMode output universalNewlineMode
    errors <- TextIO.hGetContents output
    Text.length errors `seq` pure (result, Text.unpack errors)

shellQuoteCases :: [TestTree]
shellQuoteCases =
  [ testCase "quotes empty, whitespace, apostrophe, expansion, glob, and newline arguments" $
      shellQuoteArgs ["plain", "", "two words", "it's", "$HOME", "*.txt", "line\nbreak"]
        @?= "'plain' '' 'two words' 'it'\\''s' '$HOME' '*.txt' 'line\nbreak'",
    conditionalCase ["LiftSpec", "shared shell quoting boundary"] posixShellSupported
      "quoted argv round-trips through a POSIX shell without expansion"
      ( runSelf emptyHostConfig "/bin/sh" shellArguments
          >>= ( @?= Right
                  ( ExitSuccess,
                    "<two words>\n<it's>\n<$HOME>\n<*.txt>\n<line\nbreak>\n<>\n",
                    ""
                  )
              )
      )
      (assertSelfUnavailable "/bin/sh" shellArguments)
  ]
  where
    argv = ["two words", "it's", "$HOME", "*.txt", "line\nbreak", ""]
    script = "set -- " ++ shellQuoteArgs argv ++ "; printf '<%s>\\n' \"$@\""
    shellArguments = ["-c", script]

posixShellSupported :: Bool
#ifdef mingw32_HOST_OS
posixShellSupported = False
#else
posixShellSupported = True
#endif

effectCases :: [TestTree]
effectCases =
  [ nativeEffectCase "local raw leaf captures successful stdout through liftLeaf" $
      withNativeProbe $ \cfg _ ->
        liftLeaf cfg localContext (RawCmd "curl" ["--hostbootstrap-lift-probe", "stdout", "effect-ok é\n"])
          >>= (@?= Right (ExitSuccess, "effect-ok é\n", "")),
    nativeEffectCase "local self subcommand captures successful stdout through liftSubcommand" $
      withNativeProbe $ \cfg nativeSelf ->
        liftSubcommand cfg nativeSelf localContext ["--hostbootstrap-lift-probe", "stdout", "self-ok λ\n"]
          >>= (@?= Right (ExitSuccess, "self-ok λ\n", "")),
    nativeEffectCase "with-stdin forwards bytes and its empty input is identical to the ordinary seam" $
      withNativeProbe $ \cfg nativeSelf -> do
        let arguments = ["--hostbootstrap-lift-probe", "stdin"]
            leaf = RawCmd "curl" arguments
            input = "line one\nline two é\n"
        ordinary <- liftLeaf cfg localContext leaf
        emptyInput <- liftLeafWithStdin cfg localContext leaf ""
        payload <- liftLeafWithStdin cfg localContext leaf input
        selfPayload <- liftSubcommandWithStdin cfg nativeSelf localContext arguments input
        ordinary @?= Right (ExitSuccess, "", "")
        emptyInput @?= ordinary
        payload @?= Right (ExitSuccess, input, "")
        selfPayload @?= Right (ExitSuccess, input, ""),
    nativeEffectCase "local exec failure is returned structurally" $
      withSystemTempDirectory "hostbootstrap-lift-missing" $ \directory -> do
        let missing = directory </> "missing-executable.exe"
        assertBool "the missing executable path is absolute" (isAbsolute missing)
        doesPathExist missing >>= (@?= False)
        assertSelfUnavailable missing [],
    testCase "unregistered and absolute local raw executables are refused before launch" $ do
      executable <- getExecutablePath
      forM_ [("no-such-tool", []), (executable, ["--hostbootstrap-lift-probe", "stdout", "must-not-run"])] $ \(name, arguments) -> do
        let leaf = RawCmd name arguments
            refusal = "local executable is not a registered host tool: " ++ name
        foldLeafCommand localContext leaf @?= Left refusal
        liftLeaf emptyHostConfig localContext leaf >>= (@?= Left refusal)
        liftLeafWithStdin emptyHostConfig localContext leaf "must-not-reach-stdin" >>= (@?= Left refusal),
    testCase "outer provider dispatch uses the resolved-tool seam" $
      liftLeaf emptyHostConfig (vmContext (inVM vm emptyVMStack)) (RawCmd "true" [])
        >>= (@?= Left "incus not found on this host")
  ]

nativeEffectCase :: String -> IO () -> TestTree
nativeEffectCase name action =
  conditionalCase ["LiftSpec", "local effect seam"] True name action
    (assertFailure "the native local process row is available on every gate host")

withNativeProbe :: (HostConfig -> SelfRef -> IO ()) -> IO ()
withNativeProbe use = do
  executable <- getExecutablePath
  resolved <- either assertFailure pure (mkAbsExe executable)
  let cfg = emptyHostConfig{hcToolPaths = Map.singleton Curl resolved}
      nativeSelf = mkSelfRef (LocalSelfPath executable) (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
  use cfg nativeSelf

-- Compare the same self launch with the lower native failure, preserving the
-- host's diagnostic without hardcoding its localized operating-system text.
assertSelfUnavailable :: FilePath -> [String] -> IO ()
assertSelfUnavailable executable arguments = do
  expected <- runCaptured executable arguments ""
  case expected of
    Left failure -> runSelf emptyHostConfig executable arguments >>= (@?= Left (renderRunFailure failure))
    Right success -> assertFailure ("expected unavailable executable " ++ executable ++ ", got " ++ show success)

emptyHostConfig :: HostConfig
emptyHostConfig = HostConfig (Substrate LinuxCpu Amd64) Map.empty

dependencyCases :: [TestTree]
dependencyCases =
  [ testCase "VM placement rendering has no parallel lifecycle implementation in Lift" $ do
      -- Rationale: DEVELOPMENT_PLAN/rationale.md#vm-crossings-share-one-placement-renderer
      root <- repositoryRoot
      source <- Text.unpack . TE.decodeUtf8 <$> BS.readFile (root </> "core/hostbootstrap-core/src/HostBootstrap/Lift.hs")
      definitions <- either (\failure -> assertFailure failure >> pure []) pure (SourceGuard.haskellDefinitionNames source)
      assertBool "the former lifecycle-only inner fold has no definition" ("insideLifecycleVM" `notElem` definitions)
      let tokens = SourceGuard.haskellTokens source
      forM_ ["--cwd", "--workdir", "--cd", "-T", "sudo"] $ \literal ->
        assertBool ("Lift carries no placement-rendering literal: " ++ literal) (show literal `notElem` tokens),
    testCase "generic Lift has the exact lower import set and no realization dependency" $ do
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
