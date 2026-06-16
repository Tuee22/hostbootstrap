{- | F1 — the demo's deploy chain as a /pure value/ interpreted by a small
driver, the in-tree worked instance of "pure representation ⟂ interpreter"
(see @documents/architecture/composition_methodology.md@).

The chain ('demoDeployChain') is an ordinary list of 'Op' values — a label,
the 'LiftContext' the step runs in, and the subcommand argv. 'renderPlan' is a
pure function of that value (the @--dry-run@ output); 'runDeploy' is the
effectful interpreter that lifts each step via 'liftSubcommand'. The same data
drives both the plan and the apply, so the deploy is inspectable before it
runs (the Plan→Apply pattern).
-}
module HostBootstrapDemo.Chain (
    Op (..),
    demoDeployChain,
    containerRuntimeFrameId,
    renderPlan,
    runDeploy,
    vmRuntimeContainerConfigPath,
)
where

import HostBootstrap.HostConfig (HostConfig, buildHostConfig, hcSubstrate)
import HostBootstrap.HostTool (toolCommandName)
import HostBootstrap.Incus (IncusVM)
import HostBootstrap.Lift (
    ContainerLift,
    LiftContext,
    LiftDispatch (DispatchLocal, DispatchTool),
    SelfRef,
    currentSelfRef,
    foldLift,
    inContainer,
    inLimaVM,
    inVM,
    liftSubcommandWithAuth,
    localContext,
 )
import HostBootstrap.Lima (LimaVM)
import HostBootstrap.Registry (RegistryAuth, discoverHostRegistryAuth)
import HostBootstrap.Substrate (detect, isAppleSilicon)
import System.Exit (ExitCode (ExitSuccess), die)

{- | One step of the deploy chain: a human label, the context it runs in (the
self-reference lift stack), and the subcommand argv the binary invokes there.
-}
data Op = Op
    { opLabel :: String
    , opContext :: LiftContext
    , opArgv :: [String]
    }

{- | The demo's deploy chain as a pure value: a SINGLE explicit lift sequence
(§ W). The only lifted compute step is @test all@ — the whole test workflow
lifted into the project container in the VM (@inContainer img (inVM vm
localContext)@ folds through the selected VM provider, then @docker run --rm
\<image\> test all@). Inside that one lifted context the harness brings up the per-case kind
cluster on the VM's Docker, deploys the chart, and runs e2e. There is NO
separate cluster\/Harbor\/web-serve\/e2e chain alongside it — that would be a
redundant second representation of the same operation (see
@composition_methodology.md@).
-}
demoDeployChain :: LiftContext -> LiftContext -> [Op]
demoDeployChain vmContext liftedTestContext =
    [ Op "ensure VM provider (metal)" localContext ["vm", "ensure"]
    , Op "vm up — cordon #1 (the VM is the wall)" localContext ["vm", "up"]
    , Op
        "pristine-bootstrap — build #2 (host-native) + build #3 (project image), in the VM"
        localContext
        ["vm", "pristine-bootstrap"]
    , Op
        "runtime context — derive the VM project-container config in the VM"
        vmContext
        ["context", "create", "container", vmRuntimeContainerConfigPath, "--source-root", "/workspace/demo"]
    , Op
        "test all — the whole test workflow lifted into the project container in the VM (kind on the VM's Docker)"
        liftedTestContext
        ["test", "all"]
    , Op "vm down — guarded teardown (.data preserved)" localContext ["vm", "down"]
    ]

vmRuntimeContainerConfigPath :: FilePath
vmRuntimeContainerConfigPath = "/tmp/hostbootstrap/demo/.build/hostbootstrap-demo.runtime-container.dhall"

containerRuntimeFrameId :: String
containerRuntimeFrameId = "vm-project-container-2"

{- | Render the plan: for each step, the label and the exact host argv it folds to
(via the pure 'foldLift'). Pure — this is the @--dry-run@ output and a faithful
preview of what apply would run.
-}
renderPlan :: SelfRef -> [Op] -> String
renderPlan self ops = unlines (concat (zipWith line [1 :: Int ..] ops))
  where
    line n op =
        [ show n ++ ". " ++ opLabel op
        , "     $ " ++ renderDispatch (foldLift self (opContext op) (opArgv op))
        ]
    renderDispatch (DispatchLocal exe args) = unwords (exe : args)
    renderDispatch (DispatchTool tool args) = unwords (toolCommandName tool : args)

{- | The interpreter: with @--dry-run@ print the pure plan; otherwise lift each
step through 'liftSubcommand', failing closed on the first non-zero step.
-}
runDeploy :: IncusVM -> LimaVM -> ContainerLift -> Bool -> IO ()
runDeploy incusVM limaVM img dryRun = do
    detected <- detect
    cfg <- either die buildHostConfig detected
    self <- currentSelfRef inVMSelfPath
    -- Discovered on the metal host (the only place it lives) and forwarded only
    -- into the lifted @test all@ container, so its in-container kind/curl pulls
    -- authenticate. It is never in the dry-run plan, never in argv, and never in
    -- Dhall; 'liftSubcommandWithAuth' pipes it over stdin (see
    -- "HostBootstrap.Registry"). 'Nothing' when the host is not logged in, so
    -- pulls degrade to anonymous.
    mAuth <- discoverHostRegistryAuth
    let vmContext =
            if isAppleSilicon (hcSubstrate cfg)
                then inLimaVM limaVM localContext
                else inVM incusVM localContext
        ops = demoDeployChain vmContext (inContainer img vmContext)
    if dryRun
        then putStr (renderPlan self ops)
        else mapM_ (applyOp cfg mAuth self) ops
  where
    -- The in-VM binary path (where the VM bootstrap lays the host-native build
    -- down). Used only by a bare @inVM@ op; the canonical chain's one lifted step
    -- is container-terminal, so this is currently unreferenced.
    inVMSelfPath = "/tmp/hostbootstrap/demo/.build/hostbootstrap-demo"
    applyOp :: HostConfig -> Maybe RegistryAuth -> SelfRef -> Op -> IO ()
    applyOp cfg mAuth self op = do
        putStrLn ("deploy: " ++ opLabel op)
        result <- liftSubcommandWithAuth cfg mAuth self (opContext op) (opArgv op)
        case result of
            Right (ExitSuccess, out, _) -> putStr out
            Right (_, _, err) -> die ("deploy: " ++ opLabel op ++ " failed: " ++ err)
            Left err -> die ("deploy: " ++ opLabel op ++ ": " ++ err)
