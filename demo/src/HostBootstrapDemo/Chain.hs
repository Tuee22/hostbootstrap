-- | F1 — the demo's deploy chain as a /pure value/ interpreted by a small
-- driver, the in-tree worked instance of "pure representation ⟂ interpreter"
-- (see @documents/architecture/composition_methodology.md@).
--
-- The chain ('demoDeployChain') is an ordinary list of 'Op' values — a label,
-- the 'LiftContext' the step runs in, and the subcommand argv. 'renderPlan' is a
-- pure function of that value (the @--dry-run@ output); 'runDeploy' is the
-- effectful interpreter that lifts each step via 'liftSubcommand'. The same data
-- drives both the plan and the apply, so the deploy is inspectable before it
-- runs (the Plan→Apply pattern).
module HostBootstrapDemo.Chain
  ( Op (..),
    demoDeployChain,
    renderPlan,
    runDeploy,
  )
where

import HostBootstrap.HostConfig (HostConfig, buildHostConfig)
import HostBootstrap.HostTool (toolCommandName)
import HostBootstrap.Incus (IncusVM)
import HostBootstrap.Lift
  ( ContainerLift,
    LiftContext,
    LiftDispatch (DispatchLocal, DispatchTool),
    SelfRef,
    currentSelfRef,
    foldLift,
    inContainer,
    inVM,
    liftSubcommand,
    localContext,
  )
import HostBootstrap.Substrate (detect)
import System.Exit (ExitCode (ExitSuccess), die)

-- | One step of the deploy chain: a human label, the context it runs in (the
-- self-reference lift stack), and the subcommand argv the binary invokes there.
data Op = Op
  { opLabel :: String,
    opContext :: LiftContext,
    opArgv :: [String]
  }

-- | The demo's deploy chain as a pure value: metal → VM → in-container, the same
-- sequence the runbook narrates. Operations that need @helm@/@kind@ lift into the
-- project container (where those tools live); the webservice serves on the VM
-- host (the Playwright @baseURL@); the e2e run lifts a container against it.
demoDeployChain :: IncusVM -> ContainerLift -> [Op]
demoDeployChain vm img =
  [ Op "ensure incus (metal)" localContext ["incus", "ensure"],
    Op "vm up — cordon #1 (the VM is the wall)" localContext ["vm", "up"],
    Op
      "pristine-bootstrap — build #2 (host-native in VM) + ensure docker + build #3 (project container)"
      localContext
      ["vm", "pristine-bootstrap"],
    Op
      "cluster up — cordon #2, lifted in-container (helm/kind on the container $PATH)"
      (inContainer img (inVM vm localContext))
      ["cluster", "up", "hostbootstrap.dhall"],
    Op
      "harbor install — lifted in-container"
      (inContainer img (inVM vm localContext))
      ["harbor", "install"],
    Op
      "web serve — on the VM host (the Playwright baseURL)"
      (inVM vm localContext)
      ["web", "serve"],
    Op
      "e2e — Playwright lifted in-container against the VM-host baseURL"
      (inContainer img (inVM vm localContext))
      ["test", "e2e-tabs"]
  ]

-- | Render the plan: for each step, the label and the exact host argv it folds to
-- (via the pure 'foldLift'). Pure — this is the @--dry-run@ output and a faithful
-- preview of what apply would run.
renderPlan :: SelfRef -> [Op] -> String
renderPlan self ops = unlines (concat (zipWith line [1 :: Int ..] ops))
  where
    line n op =
      [ show n ++ ". " ++ opLabel op,
        "     $ " ++ renderDispatch (foldLift self (opContext op) (opArgv op))
      ]
    renderDispatch (DispatchLocal exe args) = unwords (exe : args)
    renderDispatch (DispatchTool tool args) = unwords (toolCommandName tool : args)

-- | The interpreter: with @--dry-run@ print the pure plan; otherwise lift each
-- step through 'liftSubcommand', failing closed on the first non-zero step.
runDeploy :: IncusVM -> ContainerLift -> Bool -> IO ()
runDeploy vm img dryRun = do
  detected <- detect
  cfg <- either die buildHostConfig detected
  self <- currentSelfRef inVMSelfPath
  let ops = demoDeployChain vm img
  if dryRun
    then putStr (renderPlan self ops)
    else mapM_ (applyOp cfg self) ops
  where
    -- The pipx-installed in-VM binary path the VM bootstrap lays down.
    inVMSelfPath = "/root/.local/bin/hostbootstrap-demo"
    applyOp :: HostConfig -> SelfRef -> Op -> IO ()
    applyOp cfg self op = do
      putStrLn ("deploy: " ++ opLabel op)
      result <- liftSubcommand cfg self (opContext op) (opArgv op)
      case result of
        Right (ExitSuccess, out, _) -> putStr out
        Right (_, _, err) -> die ("deploy: " ++ opLabel op ++ " failed: " ++ err)
        Left err -> die ("deploy: " ++ opLabel op ++ ": " ++ err)
