# Incus Host Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [ensure reconcilers](ensure_reconcilers.md), [applied cordon](applied_cordon.md), [durable state](../architecture/durable_state.md), [lifecycle state model](../architecture/lifecycle_state_model.md)

> **Purpose**: Describe the active Incus provider path, its total capability probe, and the remaining
> provider-lifecycle limits.

## TL;DR

- Native Linux CPU runs the project inside an Incus VM, its provider frame. Real Incus mutation enters only
  through the exact prepared provider backend, whose host commands `HostBootstrap.Substrate.Provider.Command`
  renders.
- `HostBootstrap.Ensure.Incus` converges the native provider; its capability gate observes the supplied
  `HostConfig` before minting the opaque `IncusProviderCapability`. Descriptive status values remain
  separate from that admission. Provider discovery is a separate closed, ordered probe set classified by
  exit status.
- The backend holds the four ownership clauses over the provider's reported face: durable origin records
  before creation, the VM's UUID bound under this run's owner claim, and identity checks that bracket the
  name-addressed delete.
- `HostBootstrap.Substrate.Provider.Report` admits the provider's output, and
  `HostBootstrap.Substrate.Provider.Resume` decides a transaction's next step as a total function.
- Launch sizing, the share-socket naming budget, and the guarded delete are the provider's walls. The
  sections below state the contract; [Current Status](#current-status) lists where the code departs from it.

## Current Status

The sections below describe the target contract. The code departs from it in these ways.

[The host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owes these gaps:

- **Two revalidations reuse the bound record.** The check immediately before the guarded delete compares
  against the identity the transaction just bound rather than a fresh observation, and the share check
  confirms only that the bound share device is present, without comparing its observed identity with the
  bound one.

## Provider route

"Frame" on this page carries two of the [glossary](../README.md#glossary) senses. A frame that names a
tool, renders a path, or supplies a guarded delete is the **frame table** sense: the Incus VM is one row of
that table. "Frame handoff" and the installed frame child are the default **topology** sense.

Native Linux CPU uses an Incus VM as its provider frame. The lower-boundary separation assigns pure
`IncusVM` target data and `execVMArgs` to `HostBootstrap.Lift.Context`; `HostBootstrap.Incus` reexports them
and adds only the file-push argument builder. The project selects an abstract `SubstrateProvider`
whose narrow projections retain the complete `LiftContext` and pure lifecycle plans without exposing
construction or record update. Generic Lift remains below that realization and imports no Incus lifecycle
module. Real Incus mutation enters through the exact prepared provider backend. The demo's adoption of that
consumer is owned by the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md). For Incus the optional cordon reconcile
is absent. The prepared route:

- on first creation, launch the named VM with `limits.cpu`, `limits.memory`, and `root,size`;
- when the named VM already exists and this run's durable record owns it (the instance carries the
  record's owner claim and the identity the record bound), start it if it is `STOPPED` and leave it as it
  is if `RUNNING`. Owned provisioning compares canonical CPU, memory and root-disk limits first;
  changed limits conflict without mutation and require destroy-and-reprovision. A same-named VM that no record claims, or that
  carries another claim or none, is refused as a conflict (see
  [where a transaction stands](#where-a-transaction-stands));
- attach the host `.data` share as an Incus disk device;
- wait for VM/network/share readiness;
- stage source/config and build/install the project binary;
- hand off the project subcommand with `incus exec`;
- stop on `project down`, or force-delete the guarded project VM on `project destroy`.

Host-side `incus` is resolved through `HostTool`. Backend construction retains its absolute path
in `IncusBackendSpec`; strong admission refuses a configuration whose resolved client differs.
Every later call uses the captured immutable `HostConfig`, so the realization fingerprint names the
client that runs. This check launches no tool and does not prove executable or directory usability.
It is the **only** executable that backend resolves: the four ownership clauses (see
[ownership invariant](../architecture/ownership_invariant.md#the-four-clauses)) are held through the
ownership seam's reported face — the face whose identity is the one the provider reports rather than one
a local kernel answers for (see [ownership seam](../architecture/ownership_seam.md#the-two-faces)) — every
effect is one of the described commands below, and every decision above them is a total function. The
backend ships no interpreter program and runs under no `flock` front end, so no interpreter and no
locking executable is resolved and no lock namespace is admitted: exclusion is the protected store's
exclusive entry (clause 1). Commands inside the guest intentionally use the guest's own tool lookup.

The guest-VM provider follows the same command boundary. Its share observation sends
`test -d <target>`, then `test -w <target>` only after the directory probe succeeds.
Each is a separate argument vector, so the target is one argument even when it contains spaces
or shell metacharacters. Its provisioning-egress observation sends
`getent hosts archive.ubuntu.com` directly. The first failing command retains the ordinary
provider failure classification. `ProviderBackendSpec` checks both physical provider modules
for interpreter and locking tokens and verifies their path to the described command driver.

Before that provider value is used, `HostBootstrap.Ensure.Incus` converges the native provider and runs
a total final observation. Its pure `IncusProviderStatus` distinguishes:

- missing client;
- absent, permission-denied, or otherwise unreachable daemon;
- missing QEMU/firmware/virtiofsd VM capability (an executable `virtiofsd` is required, because Incus
  needs it to attach a host directory to a VM);
- unavailable image-server egress; and
- fully ready.

The six non-ready constructors of `IncusProviderStatus` are public; the ready constructor is hidden.
`classifyIncusProviderStatus` remains a pure descriptive classifier, and `incusProviderStatusResult`
reads its result as `Either String ()`: ready is `Right ()`, and each non-ready status supplies its
refusal. These descriptive results carry no capability authority.

`withIncusProviderCapability` takes `HostConfig`, runs `probeIncusProviderStatus` itself, checks that
observation through `incusProviderStatusResult`, and only then supplies the opaque capability to its
rank-2 continuation. It observes the resolved tool paths in the supplied configuration at that call;
the capability describes that observation rather than permanent readiness. On Linux the
reconcile path installs the client plus ACL support when absent, refreshes tool resolution, and observes
VM capability and the root daemon before choosing a convergence plan.
`LinuxIncusObservation` retains the resolved absolute Incus executable used by the root daemon probe and
any required initialization.

The VM-capability probe combines executable QEMU, available firmware, and executable `virtiofsd` groups
in Haskell. Each group uses privileged `test` argv, with alternatives within the firmware and virtiofsd
groups. Amd64 uses `qemu-system-x86` and OVMF; Arm64 uses `qemu-system-arm` and AAVMF. The virtiofsd
probe tries Incus's fixed paths and the typed `Virtiofsd` resolver's PATH result, checking that the
resolved file is executable rather than treating resolution alone as capability.

`linuxIncusConvergence` installs the architecture's VM packages only when capability is missing and
initializes through the retained Incus executable only when the root daemon probe fails. It restarts the
daemon once when either action is needed; when both observations succeed, that plan is empty. Tool
resolution is refreshed after convergence, then KVM access and shared group/socket grants are reconciled
before forwarding and the final provider observation. KVM module loading tries `kvm_intel`, `kvm_amd`, then `kvm`,
rechecking the device after every attempt. Bridge forwarding checks for `DOCKER-USER`, then checks each
`incusbr0` rule before inserting a missing one; a missing chain skips those rules. These host operations
use separate argv, without shell programs. Apple uses the same final capability observation after
converging its Colima-backed Incus provider. Live Incus/KVM confirmation belongs to the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).

`SubstrateProvider` plus `Lift` is the single provider/dispatch model. Provider lifecycle and readiness
enter through that boundary; there is no parallel public target or reboot/readiness dispatcher.

## Provider discovery

The common provider discovery transition is separate from the ensure reconciler's installation proof. It
runs three closed probes in order: the provider's listing answers daemon reachability and permission
as one observation, then the guest answers `true`, then provisioning egress is checked. It stops
at the first blocking observation, retains every probe's actual answer, and gives that blocking answer
only to the suffix that never ran. Direct has its distinct canonical-root permission and egress probes.
The bound route must match the selected instance before any probe executes. Its executor returns only
raw exit status and streams, or a transport failure. The total `classifyProviderProbe` and
`providerConflictMarker` functions expose descriptive classification without constructing a
`ProviderProbeRequest` or minting capability authority:

| Raw outcome | Classification |
|---|---|
| exit 0, whatever the streams hold | ready |
| non-zero exit whose output begins "not ready", "starting", "connection refused", or "daemon is not running" | not ready |
| non-zero exit whose output begins "not found", "unsupported", or "no such file" | unavailable |
| transport failure whose text is exactly the one-line provider conflict marker over bounded tokens | conflict |
| anything else | failure |

Only a not-ready probe is retried, within a module-owned bounded policy of 60 attempts one second apart.
The resulting `ProviderCapability` describes what discovery observed; a rank-2 type variable ties it to
the exact opaque managed Running provider and backend realization, and it is not VM mutation authority.
The capability carries no guest executor. The narrower strong alias backend uses its retained lift
context to reach the provider frame; its prepared ownership transaction remains the mutation boundary.

## Capability and ownership

The Incus ensure capability is deliberately narrow: it proves the final installation/provider observation
made by the ensure reconciler, not permanent readiness, ownership of a VM, or authorization for an unrelated
mutation. A real provider mutation instead consumes the exact prepared call. Opaque nominal
`ManagedProviderHandle` and `ManagedProviderShareHandle` values retain the backend origin without exposing
generic handle/receipt authority. Inside one protected-store exclusive entry, the backend publishes the
durable origin record of the provider instance and of each share before creating it — each record states
that nothing stood at the name beforehand (an explicit-absence origin, clause 2) — and recovers those
records on retry. It then binds the VM's own UUID under this run's owner claim, and revalidates identity
before and after ready, stop, and guest execution, around each share, and after the conditional delete; the
check immediately before the delete and the share check compare against the bound record rather than a
fresh observation (see [Current Status](#current-status)). A share is not bound merely
because the forced activation restart reports the VM `RUNNING`: the driver polls
`incus exec <name> -- true` under the canonical VM-boot policy and admits dependent guest work only after
that exact owned VM answers. A prepared stop that observes a replacement returns a conflict naming
the owned generation, replacement generation and canonical hexadecimal stable identity. Its remedy names
the stop and requires operator resolution while leaving the replacement untouched; it produces no
Stopped successor authority. Two consequences of that shape:

- **the re-entry compares what a record says, not its bytes.** Every release and every dependent
  transaction re-establishes clauses 1 through 3 over a record a previous entry already bound, and that
  record carries clause 3's identity as well. The rule on re-entry is:
  1. the record must match in kind and in prior origin;
  2. the identity binding is not a mismatch, because it is the one field a later step of the same
     transaction adds (see
     [ownership invariant](../architecture/ownership_invariant.md#how-the-clauses-are-realized));
- **a same-named replacement is not a release.** Clause 4 compares the identity, so an object standing
  where this run's instance was after the destructive command is somebody else's: it is reported as a
  replacement, left exactly as it was found, and no record is forgotten over it. Incus addresses
  `incus delete` by name, so the identity checks bracket the destructive command rather than being atomic
  with it. The protected store's exclusive entry keeps every other hostbootstrap transaction out of that
  interval, but an instance that another actor (an operator or another tool) deletes and recreates under
  the same name between the last re-observation and the delete is removed. Only a replacement observed
  after the command is preserved and reported.

The
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
records dated gate evidence for its static gate and its native Linux/x86_64 KVM/Incus gate; that evidence
closes nothing while the phase carries open work, and the phase's status is in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md). See
[lifecycle state model](../architecture/lifecycle_state_model.md).

## Asking the provider

`HostBootstrap.Substrate.Provider.Command` is the one place the prepared ownership route's provider
effects become values. Each function returns a described host command — the tool the frame table names,
the exact argument vector, the stdio disposition, and the frame whose process reads it — and none of them
can run anything, which is what makes an argument vector comparable by application rather than only
observable by launching it.

`HostBootstrap.Incus` retains the lower target and crossing renderer plus the file-push builder used
by source and build-context staging. The Incus provider row projects start, stop, device listing,
share attachment and guarded delete from `HostBootstrap.Substrate.Provider.Command`. Its descriptive
launch plan returns a structured refusal requiring the prepared provision call, which supplies the
durable origin and owner claim. There is no second lifecycle argument builder.

Two properties of the set are worth stating because they are easy to lose:

- **one listing answers two questions.** Presence and lifecycle state come back from the same
  `incus list <name> --format csv -c ns`, because a presence answered by one command and a state answered
  by another are two answers that can disagree about the moment they describe;
- **the owner tag rides on the creating command.** `incus launch` carries
  `user.hostbootstrap.owner=<nonce>` itself rather than a configuration write that follows it, so there is
  no interval in which the instance exists without naming the durable record that owns it.

Every command in `HostBootstrap.Substrate.Provider.Command` is interpreted by a process of the outer host.
A vector that crosses *into* the instance is not rendered there: the lift's own fold is the project's
single crossing renderer, and a second one beside it is the duplication that rule exists to prevent. The
destructive delete goes through the frame table's guarded delete described below: the module's row
receives only the name the guard has admitted and renders its argument vector from it.

## Reading what the provider says

A driver that holds ownership clauses over an Incus instance needs two facts about it: whether the daemon
names it at all, and what stable identity the daemon gives it. Both arrive as bytes on a described
command's standard output, and `HostBootstrap.Substrate.Provider.Report` is the one place those bytes
become values. It executes nothing; each classifier is a total function of the interpreter's own outcome,
so the report a driver returns and the decision a caller makes are the same value rather than a rendering
and a parser.

What it admits is deliberately narrow, because a provider is another program's output:

- an instance listing is a set of `name,state` rows, and only the row naming the exact instance is about
  it — the daemon matches a listing argument by prefix, so a sibling name is an absence rather than a hit.
  The exact name is selected before state and arity are read, so a sibling's state or malformed
  arity cannot decide this instance's observation. A nonblank row with no name still refuses;
- the two lifecycle states a clause-holding transaction can act from are `RUNNING` and `STOPPED`; every
  other state the daemon might name is refused rather than mapped onto whichever of the two is closer;
- a configuration read answers at most one bounded line; no line, or an empty one, is an unset key rather
  than a failure, so an empty owner tag reads as one that was never written and the instance is refused as
  unclaimed;
- an identity is admitted through the ownership seam's own producer, so a value this vocabulary could not
  read is never compared against a bound one;
- a report that is over-long, carries a Unicode control or format character, or lists the exact
  instance twice is a refusal. The character rule covers C0, DEL, C1 and formatting characters such as
  bidirectional overrides. Before that check each line loses one
  trailing carriage return and empty lines are dropped, so a CRLF-terminated report reads as the same
  rows.

The global report bounds and character checks apply before name reduction. A report line admits
at most 512 characters; configuration values admit 240 characters for owner tags and device properties.
An identity is checked again by `mkObjectIdentity` against its separate 64-byte ceiling.
The successful configuration result has an unset constructor and a private nonempty branch;
`providerConfigValueText` presents `Nothing` or the admitted nonempty text. An empty line and
no output both mean unset. Clients cannot construct an unchecked value branch.

A provider's diagnostic uses its first nonempty sanitized line, bounded by the same report-line
limit. Control and format characters are removed before exit or noisy-success diagnostics are
constructed; the numeric exit status remains in the rendered refusal.

The join is one function: a listing and an identity read together become the observation the seam's
reported face is held over (see [ownership seam](../architecture/ownership_seam.md)). An instance listed
without an identity, and an identity reported for an instance that is not listed, are each refused there.

## Where a transaction stands

`HostBootstrap.Substrate.Provider.Resume` decides what an ownership transaction does next, and it is a
total function of three values: the durable record the protected store holds, the observation the report
produced, and the claim the instance carries.

That shape is deliberate. The interval between the durable record and the identity binding is the one a
live run cannot be steered into — entering it needs a process to die at an exact instruction — so writing
the decision as a function is what makes every branch of it reachable at all.

Four standings are legitimate, and they are the four prefixes of the one clause order: nothing done; the
origin recorded and the creating command not taken; the instance created under this record's claim and not
yet bound; and the instance owned. Everything else is a conflict reported with both sides — an instance no
record claims, an instance carrying a different claim or none at all, a bound record whose instance has
been replaced, a bound record whose instance is gone, a record another owner wrote, and a record naming an
instance that was there before it.

Conflict messages retain the instance's observed claim after "carries the claim" and the
durable record's expected claim after "this record's". Replacement messages retain both the
bound and observed identities; vanished and prior-instance messages retain the identity
their conflict carries. The resumption suite checks each of the six complete renderings.

The claim comparison is the whole of the crash-window resolution. The instance name is the same by
construction — it is the name the plan declares — so the claim is the only thing that tells an instance
this record created from one an earlier record left behind. One vocabulary answers every verb, because
provision, readiness, and release ask the same question and only act differently on the answer.

## Destructive deletion

`incus delete <name> --force` is prefix-guarded, and the guard is one computation every frame's removal goes
through rather than one written per provider. `HostBootstrap.Substrate.Provider.Command` (and the
`HostBootstrap.Incus` row) supplies only the noun its refusal reads in and a function from the admitted
name to the argument vector; each row receives only the admitted name and renders its vector from it.
That is the rows' convention, which the types do not enforce. An instance outside the project's namespace refuses, and so do the two
degenerate inputs that make the guard vacuous: an empty prefix, which is a prefix of every name, and an empty
instance name.

The pure provider commands name the literal `ToolTarget Incus` and `OuterHost` frame.
The frame table supplies the shared delete guard; it supplies no frame-to-tool lookup.

`incus stop <name> --force` (and `incus restart <name> --force`) is a forced power-off: the VM is killed
without a clean guest shutdown, so guest writes that were not flushed can be lost. It carries no name guard
because it is issued only inside an ownership transaction that has just re-observed the exact owned
instance — its record, its bound identity, and its owner claim — and that re-observes it again after the
stop. `--force` keeps an unresponsive guest agent from holding the lifecycle transaction indefinitely.

## Recursive Lifecycle And Durable State

The root coordinator enters the authenticated child reverse route before stopping or deleting its Incus
provider. Cluster/workload teardown follows the same exact child-first forest as other providers; deleting
the VM is the provider operation after nested settlement, not a substitute for that settlement. See
[cluster lifecycle](cluster_lifecycle.md).

The host durable root is carried into Incus through an owned disk device and exposed to Docker through
`/var/tmp/hostbootstrap-demo-data`. The prepared guest-alias driver runs inside the provider guest, as
the project binary installed there. Inside the exclusive entry of the protected store at
`<target>/.hostbootstrap-alias-authority-v1` in the host-backed share (clause 1, taken by that binary) it
publishes an explicit-absence origin record, keyed by a digest of the alias path and target, whose claim is
the link target; creates a staging symlink beside the alias and binds that link's exact device/inode
identity into the record; then publishes the link at the alias path without replacement. Release
re-observes the bound identity before removing the link. A crash retry resumes from the record, unbound or
bound, rather than adopting an exact-looking pathname. The full protocol is canonical in
[durable state](../architecture/durable_state.md#root-authority-and-alias-target).

The [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) records adoption of that route,
Production durable-root preservation, and same-run Harness destroy/up/readback. See
[ownership invariant](../architecture/ownership_invariant.md) and
[durable state](../architecture/durable_state.md).

Retained provider stop, readiness and delete re-enter the protected provider record without a
forward managed handle or caller-supplied owner or generation. Stop checks the provider's resulting
state. Readiness starts a stopped instance and asks the guest whether it answers, polling only
not-ready observations; a terminal guest failure returns after one probe. All three operations
refuse a same-named replacement before mutation and preserve the retained records on refusal.
Direct and Lima return their declared Unsupported results through this retained boundary.

The backend suite drives these paths through its compiled CLI stand-in and the real protected
store. It checks exact stop/start counts, three probes across two not-ready replies, one probe for
terminal failure, full replacement preservation, and the failure of a stop that still reports a
running instance. The live component confirms the actual Incus substrate separately.

## Resource wall

The prepared launch (`launchInstanceCommand`) renders the instance's `ProviderSizing`:

```text
limits.cpu=<N>
limits.memory=<memory>
root,size=<storage>
```

`<N>` is the declared CPU count. `<memory>` and `<storage>` are the declaration's quantity text passed
through unchanged (the demo's defaults are `10GiB` and `80GiB`); backend admission (`mkIncusBackendSpec`)
requires ASCII digits followed by an exact Incus byte suffix, with the scaled value within the signed
64-bit byte range. It rejects a unit without a number, non-ASCII digits, unknown suffixes and overflow;
the admitted spelling is passed unchanged. The supported suffixes follow the
[Incus byte-unit reference](https://linuxcontainers.org/incus/docs/main/reference/instance_units/) and its
[byte parser](https://github.com/lxc/incus/blob/main/shared/units/units.go), including the bare-byte form.
`incusSizingArgs`, which renders
whole `GiB` values from the canonical parser, sizes only the `SubstrateProvider` value's launch plan, which
the Incus route does not execute.

These are per-VM CPU, memory and storage walls. Provisioning validates a positive canonical budget
before any provider command. For an instance whose exact claim and native identity match its stored
ownership binding, the entered transaction reads `limits.cpu`, `limits.memory` and the root device's
`size`. The native byte parser is shared with backend admission, so every admitted Incus unit retains
its exact meaning, including decimal and binary spellings. Comparison uses canonical quantities rather
than spelling. A fresh ownership/identity check follows those reads.

Equal limits return `ProvisionAlreadyOwned` without launching, starting or publishing another origin
record. A different CPU, memory or disk quantity returns a typed `Conflict` with both canonical sides
and destroy-and-reprovision as the remedy. A missing, malformed, noisy or failed read refuses. The
transaction does not resize the VM, and it preserves the existing exact plan/owner/backend binding.
The static protocol cases supply raw client values; the phase's live component separately confirms real
Incus behavior. The in-VM kind slice does not replace this outer wall. The
[canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md)
supplies the lower result/capacity algebra, while the
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owns the provider-authoritative Incus realization.

## Provider naming bounds

Incus opens one virtio-fs control socket per attached share device at
`<var-path>/devices/<instance>/virtio-fs.<device>.sock`. That is a POSIX unix-domain socket, so the whole
pathname must fit in `sun_path`, which leaves 107 usable bytes. The instance name and the share device
name therefore share one budget: the share device is named from its binding digest inside a fixed
21-character bound (`hb-share-` plus 12 hexadecimal digits), and backend admission refuses an instance
name that would overflow the remainder. Without both bounds a declaration looks valid and its share simply
never attaches.

Admission computes the budget against Incus's default state directory, `/var/lib/incus`, as
`<var-path>`: 107 bytes less the 39 fixed path bytes and the 21-byte device name leaves an instance name of
at most 47 bytes. Admission measures UTF-8 bytes before checking the hostname grammar, so a
multibyte declaration cannot evade the socket bound through a smaller character count. Names use
lowercase ASCII letters, digits and hyphens, start with a letter and do not end in a hyphen. The
destructive-delete guard prefix uses the same grammar and may end in a hyphen.
An Incus installation whose state directory is elsewhere has a different
budget, which admission does not compute.

## Live provider component

The provider-live component admits the same strong backends and prepared calls as the application.
Its confirmed route requires Linux x86_64, a ready Incus provider, read/write permission on the KVM
device and a successful open of that device. These preflights run before its temporary root is
created. A collision or other setup failure before durable intent publication removes that root;
only a failure after successful publication reports the preserved intent and VM inspection remedy.

Initial readiness and provisioned-state recovery convert exceptions to reconciliation failures so
the owned provider still reaches cleanup. The guest preparation callback runs after share settlement
and before alias acquisition. The two restart callbacks run while the alias is held. If both the
body and release fail, the reported failure contains both causes. Invalid step plans travel through
the validated builder as `Either` values.

The live assertions select the exact VM row from a name-and-state listing, recognize protected-record
staging names containing `.rec.tmp-`, and reject every remaining provider record under `<vm>.`,
including share records and staging files. The component's compilation and ordinary unrequested
result establish static coverage; a confirmed KVM/Incus run supplies the live lifecycle evidence
required by the [owning development-plan phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md).

## Validation

During cold boot, only exit 255 with empty stdout and the exact Incus agent-not-running error
joins the existing bounded not-ready poll. Prepared and retained readiness re-observe the bound
instance around each guest probe; retries neither repeat a start nor publish another origin record.
Other exit-255 faults, changed diagnostics and wrong output streams retain their causal failure.

Running-provider dependency registration captures the actual native identity and compares the
complete fresh identity at each owner-serviced request. Same-name replacement refuses with typed
Conflict before dependent mutation. Direct uses its canonical root identity without claiming the host.
Exact provider/share registration retains consumed nonces in its original live service closure.
The static regressions exercise these paths through the real prepared backend and protected store;
the final confirmed gate validates the actual KVM/Incus lifecycle on the realized Linux host.

`EnsureSpec` checks the descriptive refusals and classifier precedence, the configured gate's missing
client refusal without reaching its continuation, and the production flow from probe to admission. The public-only
constructor fixture checks the opaque capability boundary. The opt-in live harness uses the descriptive
eliminator for its read-only Incus preflight; this preflight does not mint a capability or enable the
live lane on its own.

Static coverage of builders and the prepared backend is not a provider closure gate. Closure requires the
native Linux/x86_64 KVM/Incus run declared by the
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md),
including prepared create/recovery, ready, share/readback, stop/restart, bound guest execution, alias
acquisition/release, identity-conditional delete, and the Direct no-mutation/refusal path. A macOS run is
not evidence for that gate.

The gate host needs readable/writable KVM and a working Incus daemon; the static cases pass before the
live component confirms the prepared lifecycle, forced restart, post-restart guest readiness, installed
frame-child execution, conditional alias release, delete, Direct refusal, and residue checks. The phase
document holds the dated run, the exact command, the host and toolchain versions, and the evidence digest.
Recursive teardown and end-to-end demo durability remain later phase concerns. Status and scheduling belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [WSL2](wsl2.md) and [Lima](lima.md) — peer provider values.
- [durable state](../architecture/durable_state.md) — Incus host share and stable alias.
- [applied cordon](applied_cordon.md) — resource parsing and walls.
- [composition methodology](../architecture/composition_methodology.md) — frame handoff.
