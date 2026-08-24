{-# LANGUAGE OverloadedStrings #-}

{- | Tests for the Docker Hub credential model ('HostBootstrap.Registry'): the
credential carries only the Docker Hub auth (never the host's other registry
secrets), it never prints its payload, and the ephemeral-forwarding wrapper
never embeds the secret (it travels on @stdin@, not in the script).
-}
module RegistrySpec (tests) where

import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Incus, Lima, Wsl))
import HostBootstrap.Lift (
    ContainerLift (..),
    ContainerPlacement (ProviderGuestContainer),
    IncusVM (..),
    LiftDispatch (..),
    LimaVM (..),
    Wsl2VM (..),
    blobHeadLeaf,
    blobUploadFinishLeaf,
    blobUploadPatchLeaf,
    blobUploadSessionLeaf,
    foldLeaf,
    inContainer,
    inLimaVM,
    inVM,
    inWsl2VM,
    liftSubcommand,
    localContext,
    mkSelfRef,
 )
import HostBootstrap.Registry (
    dockerAuthStdinWrapper,
    dockerHubAuthFromConfig,
    liftSubcommandWithAuth,
    registryAuthEnvVar,
    registryAuthLiftPlan,
    registryConfigPayload,
 )
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- A host config.json logged in to Docker Hub AND a private registry. The Docker
-- Hub secrets are the only ones that should ever be forwarded.
multiRegistryConfig :: BL.ByteString
multiRegistryConfig =
    BL.concat
        [ "{\"auths\":{"
        , "\"https://index.docker.io/v1/\":{\"auth\":\"ZG9ja2VyOnB1bGw=\",\"identitytoken\":\"HUB-IDENTITY-TOKEN\"},"
        , "\"localhost:30002\":{\"auth\":\"cHJpdmF0ZTpzZWNyZXQ=\"}"
        , "}}"
        ]

has :: T.Text -> T.Text -> Bool
has = T.isInfixOf

hasStr :: T.Text -> String -> Bool
hasStr needle haystack = T.isInfixOf needle (T.pack haystack)

present :: BL.ByteString -> Bool
present = maybe False (const True) . dockerHubAuthFromConfig

authContainer :: ContainerLift
authContainer =
    ContainerLift
        { clImage = "demo:local"
        , clPlacement = ProviderGuestContainer
        , clMounts = []
        , clExtraArgs = ["-e", registryAuthEnvVar]
        , clRemoveAfter = True
        , clConfigDelivery = Nothing
        }

authSubcommand :: [String]
authSubcommand = ["project", "up"]

authScript :: String
authScript =
    "export HOSTBOOTSTRAP_REGISTRY_AUTH=\"$(cat)\"; exec "
        ++ "'docker' 'run' '--rm' '-e' 'HOSTBOOTSTRAP_REGISTRY_AUTH' "
        ++ "'demo:local' 'project' 'up'"

tests :: TestTree
tests =
    testGroup
        "RegistrySpec"
        [ testGroup
            "dockerHubAuthFromConfig projects out only the Docker Hub auth"
            [ testCase "keeps the index.docker.io entry and its token" $ do
                let payload = fmap registryConfigPayload (dockerHubAuthFromConfig multiRegistryConfig)
                assertBool "payload present" (payload /= Nothing)
                assertBool "carries the Docker Hub registry key" (maybe False (has "index.docker.io") payload)
                assertBool "carries the Docker Hub auth value" (maybe False (has "ZG9ja2VyOnB1bGw=") payload)
                assertBool "carries the Docker Hub identity token" (maybe False (has "HUB-IDENTITY-TOKEN") payload)
            , testCase "drops the host's other registry credentials" $ do
                let payload = fmap registryConfigPayload (dockerHubAuthFromConfig multiRegistryConfig)
                assertBool "drops the private registry host" (maybe False (not . has "localhost:30002") payload)
                assertBool "drops the private registry secret" (maybe False (not . has "cHJpdmF0ZTpzZWNyZXQ=") payload)
            ]
        , testGroup
            "no Docker Hub credential yields Nothing (anonymous fallback)"
            [ testCase "empty object" $ present "{}" @?= False
            , testCase "auths without a Docker Hub entry" $
                present "{\"auths\":{\"localhost:30002\":{\"auth\":\"eA==\"}}}" @?= False
            , testCase "invalid JSON" $ present "not-json" @?= False
            ]
        , testGroup
            "blob delivery leaves have one exact crossing shape"
            [ testCase "upload session" $
                foldLeaf localContext (blobUploadSessionLeaf "http://registry/v2/repo/blobs/uploads/")
                    @?= DispatchLocal
                        "curl"
                        ["-sS", "-m", "15", "-o", "/dev/null", "-D", "-", "-X", "POST", "http://registry/v2/repo/blobs/uploads/"]
            , testCase "upload patch" $
                foldLeaf localContext (blobUploadPatchLeaf "payload" "http://registry/session")
                    @?= DispatchLocal
                        "curl"
                        [ "-sS"
                        , "-m"
                        , "15"
                        , "-o"
                        , "/dev/null"
                        , "-D"
                        , "-"
                        , "-X"
                        , "PATCH"
                        , "-H"
                        , "Content-Type:application/octet-stream"
                        , "-d"
                        , "payload"
                        , "http://registry/session"
                        ]
            , testCase "upload finish" $
                foldLeaf localContext (blobUploadFinishLeaf "http://registry/session?digest=sha256:abc")
                    @?= DispatchLocal
                        "curl"
                        ["-fsS", "-m", "15", "-o", "/dev/null", "-X", "PUT", "http://registry/session?digest=sha256:abc"]
            , testCase "blob head" $
                foldLeaf localContext (blobHeadLeaf "http://registry/v2/repo/blobs/sha256:abc")
                    @?= DispatchLocal
                        "curl"
                        [ "-sS"
                        , "-m"
                        , "10"
                        , "-o"
                        , "/dev/null"
                        , "-I"
                        , "-w"
                        , "%{http_code} %{redirect_url}"
                        , "http://registry/v2/repo/blobs/sha256:abc"
                        ]
            ]
        , testCase "the credential never leaks through Show" $
            case dockerHubAuthFromConfig multiRegistryConfig of
                Nothing -> assertBool "expected a credential" False
                Just auth -> do
                    show auth @?= "RegistryAuth <redacted>"
                    assertBool "shown form omits the identity token" (not (hasStr "HUB-IDENTITY-TOKEN" (show auth)))
        , testGroup
            "the stdin wrapper forwards ephemerally and embeds no secret"
            [ testCase "materialises and scrubs a transient DOCKER_CONFIG" $ do
                let script = dockerAuthStdinWrapper "docker build ."
                assertBool "creates a temp dir" (hasStr "mktemp -d" script)
                assertBool "reads the payload from stdin" (hasStr "cat >" script)
                assertBool "points DOCKER_CONFIG at it" (hasStr "DOCKER_CONFIG=" script)
                assertBool "removes it on exit" (hasStr "trap" script && hasStr "rm -rf" script)
                assertBool "runs the inner command" (hasStr "docker build ." script)
            , testCase "the wrapper script is pure (no secret embedded)" $ do
                let script = dockerAuthStdinWrapper "docker build ."
                assertBool
                    "wrapper carries no auth material"
                    (not (hasStr "HUB-IDENTITY-TOKEN" script) && not (hasStr "ZG9ja2VyOnB1bGw=" script))
            ]
        , testCase "the forwarding env var name is stable" $
            registryAuthEnvVar @?= "HOSTBOOTSTRAP_REGISTRY_AUTH"
        , testGroup
            "registry-aware lift planning"
            [ testCase "Incus carries the exact Docker argv through one VM shell" $
                registryAuthLiftPlan
                    (inContainer authContainer (inVM (IncusVM "incus-vm" "images:ubuntu/24.04") localContext))
                    authSubcommand
                    @?= Just
                        ( Incus
                        , ["exec", "incus-vm", "--", "bash", "-lc", authScript]
                        )
            , testCase "Lima carries the exact Docker argv through its root shell" $
                registryAuthLiftPlan
                    (inContainer authContainer (inLimaVM (LimaVM "lima-vm") localContext))
                    authSubcommand
                    @?= Just
                        ( Lima
                        , ["shell", "lima-vm", "--", "sudo", "-H", "bash", "-lc", authScript]
                        )
            , testCase "WSL2 carries the exact Docker argv through its distro" $
                registryAuthLiftPlan
                    (inContainer authContainer (inWsl2VM (Wsl2VM "wsl-distro") localContext))
                    authSubcommand
                    @?= Just
                        ( Wsl
                        , ["-d", "wsl-distro", "--", "bash", "-lc", authScript]
                        )
            , testCase "the descriptive plan contains no credential payload" $ do
                let plans =
                        [ registryAuthLiftPlan
                            (inContainer authContainer (inVM (IncusVM "incus-vm" "image") localContext))
                            authSubcommand
                        , registryAuthLiftPlan
                            (inContainer authContainer (inLimaVM (LimaVM "lima-vm") localContext))
                            authSubcommand
                        , registryAuthLiftPlan
                            (inContainer authContainer (inWsl2VM (Wsl2VM "wsl-distro") localContext))
                            authSubcommand
                        ]
                    rendered = show plans
                assertBool "plan exposed the Docker Hub auth" (not (hasStr "ZG9ja2VyOnB1bGw=" rendered))
                assertBool "plan exposed the Docker Hub token" (not (hasStr "HUB-IDENTITY-TOKEN" rendered))
            , testCase "an unsupported context has no authenticated plan" $
                registryAuthLiftPlan (inContainer authContainer localContext) authSubcommand
                    @?= Nothing
            , testCase "Nothing and unsupported authenticated contexts use the ordinary lift" $ do
                let cfg =
                        HostConfig
                            { hcSubstrate = Substrate LinuxCpu Amd64
                            , hcToolPaths = Map.empty
                            }
                    self = mkSelfRef "/hostbootstrap-registry-spec-missing" "hostbootstrap"
                    vmOnly = inVM (IncusVM "incus-vm" "image") localContext
                    containerOnly = inContainer authContainer localContext
                ordinaryVm <- liftSubcommand cfg self vmOnly authSubcommand
                anonymousVm <- liftSubcommandWithAuth cfg Nothing self vmOnly authSubcommand
                anonymousVm @?= ordinaryVm
                case dockerHubAuthFromConfig multiRegistryConfig of
                    Nothing -> assertBool "expected a credential" False
                    Just auth -> do
                        ordinaryContainer <- liftSubcommand cfg self containerOnly authSubcommand
                        authenticatedContainer <-
                            liftSubcommandWithAuth cfg (Just auth) self containerOnly authSubcommand
                        authenticatedContainer @?= ordinaryContainer
            ]
        , testCase "registry-aware lifting depends from Registry to lower Lift only" $ do
            cwd <- getCurrentDirectory
            root <- findRepoRoot cwd >>= maybe (fail ("could not locate repository root from " ++ cwd)) pure
            let sourceRoot = root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap"
            liftSource <- readFile (sourceRoot </> "Lift.hs")
            networkSource <- readFile (sourceRoot </> "Network.hs")
            registrySource <- readFile (sourceRoot </> "Registry.hs")
            assertBool
                "Lift must not import the higher Registry module"
                (not (importsModule "HostBootstrap.Registry" liftSource))
            assertBool
                "Registry must build on the lower Lift module"
                (importsModule "HostBootstrap.Lift" registrySource)
            assertBool
                "the registry-aware helper must not be implemented in Lift"
                (not (hasStr "liftSubcommandWithAuth" liftSource))
            assertBool
                "the registry-aware helper must be implemented in Registry"
                (hasStr "liftSubcommandWithAuth" registrySource)
            assertBool
                "Network must project local endpoints from the cluster backend authority"
                ( importsModule "HostBootstrap.Cluster.Backend" networkSource
                    && hasStr "resolvedExposureHostPort" networkSource
                    && hasStr "resolvedExposureRelayIdentity" networkSource
                )
            assertBool
                "Network must expose no raw local endpoint or host-port constructor"
                ( not (hasStr "loopbackExposure ::" networkSource)
                    && not (hasStr "hostLocalEndpoint ::" networkSource)
                    && not (hasStr "vmLocalEndpoint ::" networkSource)
                    && not (hasStr "30500" networkSource)
                )
            assertBool
                "reachLeaf remains an additive helper in generic Lift"
                (hasStr "reachLeaf :: String -> LiftLeaf" liftSource)
        ]

importsModule :: String -> String -> Bool
importsModule imported = any imports . lines
  where
    imports line =
        case words line of
            "import" : terms -> imported `elem` terms
            _ -> False
