{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | The hostbootstrap-demo project commands and the four-stream extension
-- demonstration.
--
-- The demo groups its project verbs under nouns (@incus@/@vm@/@harbor@/@web@),
-- distinct from the inherited verb-first core verbs, and exercises the
-- additive extension streams:
--
--   * CLI tree — 'demoCommands' is appended to the core tree via
--     @runHostBootstrapCLI@ (append, never shadow);
--   * schema-gen registry — @demo web schema@ prints @coreArtifacts ++
--     demoArtifacts@ (registry concatenation);
--   * test harness — @demo vm test@ drives @runMatrix@ over 'demoCases' with
--     'demoSeams' (the app supplies only its case matrix).
--
-- The live in-VM / kind / Harbor / web / Playwright work is driven by the verbs
-- and exercised during a real demo run; the verbs here narrate the step they
-- drive so the structure is observable without the infrastructure.
module HostBootstrapDemo.Commands
  ( demoCommands,
    demoArtifacts,
    demoCases,
    demoSeams,
  )
where

import qualified Data.Text as T
import HostBootstrap.Config.Vocab (PodResources (..))
import HostBootstrap.Dhall.Gen (ConfigArtifact, artifactOf, coreArtifacts, schemaUnion)
import HostBootstrap.Harness (Case (..), Seams, defaultSeams, reportCard, runMatrix)
import Options.Applicative

-- | The demo's schema-gen artifacts, appended to @coreArtifacts@ (the registry
-- concatenation stream). A demo web-pod footprint reflected from the vocabulary.
demoArtifacts :: [ConfigArtifact]
demoArtifacts =
  [ artifactOf @PodResources "demoWeb" (PodResources 2 1 1 1 2)
  ]

-- | The demo's harness case matrix (the app supplies only this; the L0 engine
-- drives it). The headline @pristine-bootstrap@ case plus the web/e2e cases.
demoCases :: [Case]
demoCases =
  [ Case "pristine-bootstrap" 1 False,
    Case "web-build" 1 False,
    Case "e2e-tabs" 1 False
  ]

-- | The demo's harness seams. The L0 default (a one-shot container run) is the
-- stub here; a real run supplies kind/Helm + incus-VM seams.
demoSeams :: Seams ()
demoSeams = defaultSeams

-- | The appended demo command tree (noun-first).
demoCommands :: [Mod CommandFields (IO ())]
demoCommands = [incusCmd, vmCmd, harborCmd, webCmd]

-- | A leaf verb that narrates the step it drives (the live work runs in a real
-- demo run).
narrate :: String -> String -> Mod CommandFields (IO ())
narrate name what =
  command name (info (pure (putStrLn (name ++ ": " ++ what))) (progDesc what))

incusCmd :: Mod CommandFields (IO ())
incusCmd =
  command
    "incus"
    ( info
        (hsubparser (narrate "ensure" "drive core `ensure incus` (install-and-verify the host-provider)"))
        (progDesc "incus host-provider verbs")
    )

vmCmd :: Mod CommandFields (IO ())
vmCmd =
  command
    "vm"
    ( info
        (hsubparser (vmUp <> vmBootstrap <> vmTest))
        (progDesc "incus VM lifecycle and the pristine-host bootstrap")
    )
  where
    vmUp = narrate "up" "launch a budget-sized pristine ubuntu/24.04 VM (cordon #1: the VM is the wall)"
    vmBootstrap =
      narrate
        "pristine-bootstrap"
        "apt install pipx -> pipx install hostbootstrap -> hostbootstrap up (build #2 host-native, then build #3 the project container)"
    vmTest =
      command
        "test"
        (info (pure runDemoTests) (progDesc "drive the demo harness over its case matrix (the harness stream)"))
    runDemoTests = runMatrix demoSeams demoCases >>= putStr . reportCard

harborCmd :: Mod CommandFields (IO ())
harborCmd =
  command
    "harbor"
    ( info
        (hsubparser (harborInstall <> harborPush))
        (progDesc "in-VM kind + Harbor registry")
    )
  where
    harborInstall = narrate "install" "core `cluster up` (cordon #2: applied docker update kind-node cap) + Harbor install"
    harborPush = narrate "push" "push the arch-explicit image tag to the in-VM Harbor"

webCmd :: Mod CommandFields (IO ())
webCmd =
  command
    "web"
    ( info
        (hsubparser (webServe <> webBridge <> webSchema))
        (progDesc "the servant webservice + purescript-bridge SPA")
    )
  where
    webServe = narrate "serve" "serve the servant webservice on the incus host (the Playwright baseURL)"
    webBridge = narrate "bridge" "generate the PureScript types from the servant API via purescript-bridge"
    webSchema =
      command
        "schema"
        (info (pure printSchema) (progDesc "print the L0 + demo schema union (the schema-gen extension stream)"))
    printSchema = putStrLn (T.unpack (schemaUnion (coreArtifacts ++ demoArtifacts)))
