{-# LANGUAGE OverloadedStrings #-}

{- | The described provider commands, compared as values.

Every case here is an equality between a rendered command and the vector it is
supposed to be. That is only possible because the renderers cannot run anything:
a function that both built and launched an argument vector could be observed
only by launching it, and what a launch proves is that /something/ ran (§ NN).

The guarded delete's three refusals are exercised through the same table every
frame's removal goes through, so this suite proves the provider reaches the
guard rather than restating what the guard decides.
-}
module ProviderCommandSpec (tests) where

import Data.List (isInfixOf)
import HostBootstrap.Effect.Vocabulary (
    EffectFrame (OuterHost),
    EffectStdio (CaptureStreams),
    EffectTarget (ToolTarget),
    HostCommand (commandArguments, commandFrame, commandStdio, commandTarget),
 )
import HostBootstrap.HostTool (HostTool (Incus))
import HostBootstrap.Substrate.Provider.Command
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "described provider commands"
        [ testGroup "observing" observationTests
        , testGroup "mutating" mutationTests
        , testGroup "the guarded delete" deleteTests
        , testGroup "the shape every command has" shapeTests
        ]

-- ---------------------------------------------------------------------------
-- Observing

observationTests :: [TestTree]
observationTests =
    [ testCase "one listing answers presence and lifecycle state together" $
        commandArguments (listInstanceCommand "demo-vm")
            @?= ["list", "demo-vm", "--format", "csv", "-c", "ns"]
    , testCase "one configuration value is read by key" $
        commandArguments (readInstanceConfigCommand "demo-vm" providerIdentityConfigKey)
            @?= ["config", "get", "demo-vm", "volatile.uuid"]
    , testCase "the owner tag is read through the same reader" $
        commandArguments (readInstanceConfigCommand "demo-vm" providerOwnerConfigKey)
            @?= ["config", "get", "demo-vm", "user.hostbootstrap.owner"]
    , testCase "an instance's devices are listed" $
        commandArguments (listShareDevicesCommand "demo-vm")
            @?= ["config", "device", "list", "demo-vm"]
    , testCase "one device property is read by key" $
        commandArguments (readShareDeviceCommand "demo-vm" "hb-share-0123456789ab" "source")
            @?= ["config", "device", "get", "demo-vm", "hb-share-0123456789ab", "source"]
    ]

-- ---------------------------------------------------------------------------
-- Mutating

mutationTests :: [TestTree]
mutationTests =
    [ testCase "the launch carries the declared sizing and this run's owner tag" $
        commandArguments (launchInstanceCommand "demo-vm" "images:debian/13" sizing "9f3c")
            @?= [ "--quiet"
                , "launch"
                , "images:debian/13"
                , "demo-vm"
                , "--vm"
                , "-c"
                , "limits.cpu=6"
                , "-c"
                , "limits.memory=10GiB"
                , "-c"
                , "user.hostbootstrap.owner=9f3c"
                , "-d"
                , "root,size=80GiB"
                ]
    , testCase "the owner tag rides on the creating command" $
        -- Written afterwards it would leave an interval in which the instance
        -- exists and names no record, which is the window clause 2 exists for.
        assertBool
            "the launch itself names the owner key"
            ( any
                ((providerOwnerConfigKey <> "=") `isInfixOf`)
                (commandArguments (launchInstanceCommand "demo-vm" "img" sizing "9f3c"))
            )
    , testCase "start and stop name only the instance" $ do
        commandArguments (startInstanceCommand "demo-vm") @?= ["start", "demo-vm"]
        commandArguments (stopInstanceCommand "demo-vm") @?= ["stop", "demo-vm"]
    , testCase "share activation restarts exactly the owned instance" $
        commandArguments (restartInstanceCommand "demo-vm") @?= ["restart", "demo-vm", "--force"]
    , testCase "a share is attached as a disk device with both paths" $
        commandArguments
            (attachShareDeviceCommand "demo-vm" "hb-share-0123456789ab" "/host/.data" "/guest/.data")
            @?= [ "config"
                , "device"
                , "add"
                , "demo-vm"
                , "hb-share-0123456789ab"
                , "disk"
                , "source=/host/.data"
                , "path=/guest/.data"
                ]
    ]

-- ---------------------------------------------------------------------------
-- The guarded delete

deleteTests :: [TestTree]
deleteTests =
    [ testCase "a name carrying the guard prefix has an argument vector" $
        fmap commandArguments (deleteInstanceCommand "demo-" "demo-vm")
            @?= Right ["delete", "demo-vm", "--force"]
    , testCase "a name outside the project's namespace has no command at all" $
        assertRefused "not carrying the guard prefix" (deleteInstanceCommand "demo-" "someone-else")
    , testCase "an empty guard prefix has no command at all" $
        -- It is a prefix of every name, so the guard would admit anything.
        assertRefused "empty guard prefix" (deleteInstanceCommand "" "demo-vm")
    , testCase "an empty instance name has no command at all" $
        assertRefused "with no name" (deleteInstanceCommand "demo-" "")
    , testCase "the refusal reads in the provider's own noun" $
        assertRefused "incus VM" (deleteInstanceCommand "demo-" "someone-else")
    ]

-- ---------------------------------------------------------------------------
-- The shape every command has

shapeTests :: [TestTree]
shapeTests =
    [ testCase "every command names the frame table's tool for this frame" $
        mapM_ (\command -> commandTarget command @?= ToolTarget Incus) everyCommand
    , testCase "every command is interpreted by a process of the outer host" $
        -- A vector that crossed into the instance would be a second crossing
        -- renderer, and § LL admits one.
        mapM_ (\command -> commandFrame command @?= OuterHost) everyCommand
    , testCase "every command carries the described stdio disposition" $
        mapM_ (\command -> commandStdio command @?= CaptureStreams "") everyCommand
    , testCase "no command is empty" $
        mapM_
            (\command -> assertBool "a command names a verb" (not (null (commandArguments command))))
            everyCommand
    ]

-- ---------------------------------------------------------------------------
-- Helpers

sizing :: ProviderSizing
sizing = ProviderSizing 6 "10GiB" "80GiB"

{- | Every command this module renders, so a shape assertion is total over them
rather than over whichever ones a case remembered.
-}
everyCommand :: [HostCommand]
everyCommand =
    [ listInstanceCommand "demo-vm"
    , readInstanceConfigCommand "demo-vm" providerIdentityConfigKey
    , listShareDevicesCommand "demo-vm"
    , readShareDeviceCommand "demo-vm" "hb-share-0123456789ab" "source"
    , launchInstanceCommand "demo-vm" "images:debian/13" sizing "9f3c"
    , startInstanceCommand "demo-vm"
    , stopInstanceCommand "demo-vm"
    , restartInstanceCommand "demo-vm"
    , attachShareDeviceCommand "demo-vm" "hb-share-0123456789ab" "/host/.data" "/guest/.data"
    ]
        <> either (const []) pure (deleteInstanceCommand "demo-" "demo-vm")

assertRefused :: String -> Either String HostCommand -> IO ()
assertRefused expected outcome = case outcome of
    Left reason ->
        assertBool ("the refusal says why: " <> reason) (expected `isInfixOf` reason)
    Right command ->
        assertFailure
            ("expected no command at all, got " <> show (commandArguments command))
