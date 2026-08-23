{- | Every provider effect this project performs, as a described command.

§ KK admits one closed effect vocabulary and one interpreter for it, and this
module is where a host provider's operations enter that vocabulary. Each
function returns a 'HostCommand' value: the tool the frame table names, the
exact argument vector, the stdio disposition, and the frame whose process reads
it. None of them can run anything, which is the property that makes an argument
vector comparable by application rather than only observable by launching it.

The pairing with "HostBootstrap.Substrate.Provider.Report" is the whole design.
This module says what to ask; that one says what an answer means. A driver
composes the two and holds its clauses through the seam
("HostBootstrap.Ownership.Primitive"), so no step of a provider transaction is
a program written in another language and parsed back.

__Objective boundary.__ Every command here is interpreted by a process of the
__outer host__ — the provider's own client, run where the binary is running. A
command whose argument vector /crosses into/ the instance is not rendered here:
§ LL admits one crossing renderer and it is the lift's own fold, which the
[composition-and-network-algebra phase](../../../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
owns. Adding a second one here would be exactly the duplication the rule exists
to prevent.

The destructive delete is likewise not written here. It goes through the frame
table's one guarded delete ("HostBootstrap.Substrate.Frame"), which admits a
name only when it carries the project's guard prefix; this module supplies the
argument vector for a name already admitted, so it cannot render a removal the
guard would have refused.
-}
module HostBootstrap.Substrate.Provider.Command (
    -- * What an instance is declared as
    ProviderSizing (..),

    -- * The configuration keys a clause is held through
    providerOwnerConfigKey,
    providerIdentityConfigKey,

    -- * Observing
    listInstanceCommand,
    readInstanceConfigCommand,
    listShareDevicesCommand,
    readShareDeviceCommand,

    -- * Mutating
    launchInstanceCommand,
    startInstanceCommand,
    stopInstanceCommand,
    deleteInstanceCommand,
    attachShareDeviceCommand,
)
where

import Data.Word (Word64)
import HostBootstrap.Effect.Vocabulary (HostCommand, hostCommand)
import HostBootstrap.HostTool (HostTool (Incus))
import HostBootstrap.Substrate.Frame (FrameNoun (IncusInstance), guardedDeleteArgs)

-- ---------------------------------------------------------------------------
-- What an instance is declared as

{- | The declared size of one provider instance.

Rendered once, here, from the quantities the plan already carries. Written at
each call site instead, the same three numbers would reach the provider under
three spellings, and only one of them would be the one a readback compares
against.
-}
data ProviderSizing = ProviderSizing
    { sizingCpu :: Word64
    , sizingMemory :: String
    , sizingStorage :: String
    }
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- The configuration keys

{- | The key carrying this run's own owner tag.

Written into the instance by the launch itself, so the tag exists from the
moment the instance does. That is what closes the window between clause 2's
durable record and clause 3's identity binding: a launch that succeeded and then
lost its answer leaves an instance that names the record that created it.
-}
providerOwnerConfigKey :: String
providerOwnerConfigKey = "user.hostbootstrap.owner"

{- | The key carrying the instance's stable identity.

The provider's own, not this project's: clause 3 binds what the owning authority
knows about the object, exactly as the kernel face binds @device:inode@.
-}
providerIdentityConfigKey :: String
providerIdentityConfigKey = "volatile.uuid"

-- ---------------------------------------------------------------------------
-- Observing

{- | Ask the provider which instances it names, and in which lifecycle state.

Both columns in one question, because a presence answered by one command and a
state answered by another are two answers that can disagree about the moment
they describe.
-}
listInstanceCommand :: String -> HostCommand
listInstanceCommand instanceName =
    hostCommand Incus ["list", instanceName, "--format", "csv", "-c", "ns"]

-- | Ask the provider for one configuration value of one instance.
readInstanceConfigCommand :: String -> String -> HostCommand
readInstanceConfigCommand instanceName key =
    hostCommand Incus ["config", "get", instanceName, key]

-- | Ask the provider which devices an instance carries.
listShareDevicesCommand :: String -> HostCommand
listShareDevicesCommand instanceName =
    hostCommand Incus ["config", "device", "list", instanceName]

-- | Ask the provider for one property of one device an instance carries.
readShareDeviceCommand :: String -> String -> String -> HostCommand
readShareDeviceCommand instanceName device key =
    hostCommand Incus ["config", "device", "get", instanceName, device, key]

-- ---------------------------------------------------------------------------
-- Mutating

{- | Create the instance, sized as declared and tagged with this run's owner.

The owner tag rides on the creating command rather than on a configuration write
that follows it, so there is no interval in which the instance exists without
naming the record that owns it.
-}
launchInstanceCommand ::
    -- | the instance's own name
    String ->
    -- | the image it is created from
    String ->
    ProviderSizing ->
    -- | this run's owner tag, from its durable origin record
    String ->
    HostCommand
launchInstanceCommand instanceName image sizing ownerTag =
    hostCommand
        Incus
        [ "--quiet"
        , "launch"
        , image
        , instanceName
        , "--vm"
        , "-c"
        , "limits.cpu=" <> show (sizingCpu sizing)
        , "-c"
        , "limits.memory=" <> sizingMemory sizing
        , "-c"
        , providerOwnerConfigKey <> "=" <> ownerTag
        , "-d"
        , "root,size=" <> sizingStorage sizing
        ]

-- | Start an instance the provider already names.
startInstanceCommand :: String -> HostCommand
startInstanceCommand instanceName = hostCommand Incus ["start", instanceName]

{- | Stop an instance the provider already names.

Carries no guard, because stopping is not destructive: an instance stopped by
mistake is an instance that can be started again.
-}
stopInstanceCommand :: String -> HostCommand
stopInstanceCommand instanceName = hostCommand Incus ["stop", instanceName]

{- | Remove an instance, through the frame table's one guarded delete.

The guard prefix is the project's own namespace and the refusal reads in the
provider's own noun, both from the table. This module contributes only the
argument vector for a name the guard has admitted, so an instance outside the
namespace — and the two degenerate inputs that make the guard vacuous — have no
command at all rather than a command that is not run.
-}
deleteInstanceCommand ::
    -- | the project's guard prefix
    String ->
    -- | the instance to remove
    String ->
    Either String HostCommand
deleteInstanceCommand prefix instanceName =
    fmap
        (hostCommand Incus)
        ( guardedDeleteArgs
            IncusInstance
            prefix
            instanceName
            (\admitted -> ["delete", admitted, "--force"])
        )

{- | Attach one host directory to an instance as a disk device.

The device name is the caller's, derived from the share's own binding, so the
same prepared share always addresses the same device and a different binding
never addresses it.
-}
attachShareDeviceCommand ::
    -- | the instance
    String ->
    -- | the device name
    String ->
    -- | the host path
    String ->
    -- | the guest path
    String ->
    HostCommand
attachShareDeviceCommand instanceName device source target =
    hostCommand
        Incus
        [ "config"
        , "device"
        , "add"
        , instanceName
        , device
        , "disk"
        , "source=" <> source
        , "path=" <> target
        ]
