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
- `HostBootstrap.Ensure.Incus` converges the native provider and mints the opaque `IncusProviderCapability`
  from a total final observation; provider discovery is a separate closed, ordered probe set classified by
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

[The ensure-reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md) owes one gap:

- **The Linux convergence acts unconditionally, and the capability can be minted from a constructed
  status.** `reconcileLinuxIncus` installs the VM packages and restarts the daemon on every reconcile, not
  only when an observation shows them missing. `IncusProviderStatus` exports its ready constructor, so a
  caller can pass a status it built itself to `withIncusProviderCapability` and receive the capability
  without the probe having run.

[The host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owes the rest:

- **Discovery overwrites a ready prefix.** When a probe is not ready, the probes before it that answered
  ready are reported as failures ("an unexpected ready observation lacked its dependent probe") instead of
  keeping their own observations (see [provider discovery](#provider-discovery)).
- **The retained executable is not the one that runs.** Backend admission retains the resolved `incus` path
  in `IncusBackendSpec`, but each provider call resolves the tool again from the discovery `HostConfig`.
- **Admission is wider than the contract.** Memory and storage are admitted as any non-empty alphanumeric
  text and passed to Incus unchanged, rather than as a quantity in Incus's own unit vocabulary (see
  [resource wall](#resource-wall)). The instance name and guard prefix are admitted as any Unicode
  alphanumeric text plus `-`, `_`, and `.`, rather than an ASCII hostname, and the name is measured in
  characters rather than UTF-8 bytes, so a multibyte name within 47 characters can still overflow the
  share socket's pathname (see [provider naming bounds](#provider-naming-bounds)).
- **Every listing row is parsed before the exact row is selected.** `classifyProviderListing` reads each
  row's state first, so a sibling that the daemon's prefix match returns in a state other than `RUNNING` or
  `STOPPED`, or a malformed sibling row, refuses the observation of the exact instance.
- **Only ASCII control characters are refused.** A report line carrying a C0 control or DEL is refused; C1
  controls and Unicode format characters (bidirectional overrides among them) pass.
- **Two revalidations reuse the bound record.** The check immediately before the guarded delete compares
  against the identity the transaction just bound rather than a fresh observation, and the share check
  confirms only that the bound share device is present, without comparing its observed identity with the
  bound one.
- **Two Incus argument vocabularies.** `HostBootstrap.Incus` renders a second Incus argument vocabulary
  beside the prepared route's commands, so the same Incus operation has two renderers (see
  [asking the provider](#asking-the-provider)).

## Provider route

"Frame" on this page carries two of the [glossary](../README.md#glossary) senses. A frame that names a
tool, renders a path, or supplies a guarded delete is the **frame table** sense: the Incus VM is one row of
that table. "Frame handoff" and the installed frame child are the default **topology** sense.

Native Linux CPU uses an Incus VM as its provider frame. The lower-boundary separation assigns pure
`IncusVM` target data and `execVMArgs` to `HostBootstrap.Lift.Context`; `HostBootstrap.Incus` reexports them
and adds Incus-specific lifecycle argument builders. The project selects an abstract `SubstrateProvider`
whose narrow projections retain the complete `LiftContext` and pure lifecycle plans without exposing
construction or record update. Generic Lift remains below that realization and imports no Incus lifecycle
module. Real Incus mutation enters through the exact prepared provider backend. The demo's adoption of that
consumer is owned by the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md). For Incus the optional cordon reconcile
is absent. The prepared route:

- on first creation, launch the named VM with `limits.cpu`, `limits.memory`, and `root,size`;
- when the named VM already exists and this run's durable record owns it (the instance carries the
  record's owner claim and the identity the record bound), start it if it is `STOPPED` and leave it as it
  is if `RUNNING`, without comparing or changing its limits; a same-named VM that no record claims, or that
  carries another claim or none, is refused as a conflict (see
  [where a transaction stands](#where-a-transaction-stands));
- attach the host `.data` share as an Incus disk device;
- wait for VM/network/share readiness;
- stage source/config and build/install the project binary;
- hand off the project subcommand with `incus exec`;
- stop on `project down`, or force-delete the guarded project VM on `project destroy`.

Host-side `incus` is resolved through `HostTool`; backend admission retains the resolved absolute
executable in `IncusBackendSpec`, and each provider call resolves it again from the discovery `HostConfig`
(see [Current Status](#current-status)). It is the **only** executable that backend resolves: the four ownership clauses (see
[ownership invariant](../architecture/ownership_invariant.md#the-four-clauses)) are held through the
ownership seam's reported face — the face whose identity is the one the provider reports rather than one
a local kernel answers for (see [ownership seam](../architecture/ownership_seam.md#the-two-faces)) — every
effect is one of the described commands below, and every decision above them is a total function. The
backend ships no interpreter program and runs under no `flock` front end, so no interpreter and no
locking executable is resolved and no lock namespace is admitted: exclusion is the protected store's
exclusive entry (clause 1). Commands inside the guest intentionally use the guest's own tool lookup.

Before that provider value is used, `HostBootstrap.Ensure.Incus` converges the native provider and runs
a total final observation. Its pure `IncusProviderStatus` distinguishes:

- missing client;
- absent, permission-denied, or otherwise unreachable daemon;
- missing KVM/QEMU/OVMF/virtiofsd VM capability (an executable `virtiofsd` is required, because Incus
  needs it to attach a host directory to a VM);
- unavailable image-server egress; and
- fully ready.

`withIncusProviderCapability` mints the opaque `IncusProviderCapability` only from the fully ready status;
that status is a value a caller can also construct (see [Current Status](#current-status)). On Linux the
reconcile path installs the client plus ACL support, establishes KVM access, installs QEMU/OVMF/virtiofsd,
initializes the daemon when the root daemon probe fails, restarts the daemon, establishes immediate socket
access, preserves the Incus bridge through `DOCKER-USER`, and re-runs the complete probe. The VM-package
install and the daemon restart run on every reconcile. Apple uses the same final capability observation after converging its Colima-backed Incus provider.

`SubstrateProvider` plus `Lift` is the single provider/dispatch model. Provider lifecycle and readiness
enter through that boundary; there is no parallel public target or reboot/readiness dispatcher.

## Provider discovery

The common provider discovery transition is separate from the ensure reconciler's installation proof. It
runs a closed, ordered set of probes — daemon and permissions (both answered by the provider's instance
listing), VM capability (the guest answering `true`), and provisioning egress — and stops at the first
probe that is not ready; the probes after it take that probe's observation, and the ready probes before it
are also reported as failures rather than as their own observations (see
[Current Status](#current-status)). Its executor returns only a raw
exit status and streams, or a transport failure, and a private classifier reads each probe by exit status:

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
The alias backend may derive a guest executor only from that capability.

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
that exact owned VM answers. Two consequences of that shape:

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

`HostBootstrap.Incus` holds a second set of Incus argument builders — launch (sized by
`incusSizingArgs`), start, stop, file push, device list and add, and the guarded delete — that fill the
`SubstrateProvider` value's plan fields. On the Incus route the prepared backend executes none of its
launch, start, stop, device, or delete vectors; the vector the route does execute is the provider's file
transfer (`incus file push`), which source and build-context staging use. The owner tag rides only on
`launchInstanceCommand`, so a change to how an instance is created belongs in
`HostBootstrap.Substrate.Provider.Command`.

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
  Every row is parsed before the exact row is selected, so a sibling in a state other than `RUNNING` or
  `STOPPED` refuses the observation (see [Current Status](#current-status));
- the two lifecycle states a clause-holding transaction can act from are `RUNNING` and `STOPPED`; every
  other state the daemon might name is refused rather than mapped onto whichever of the two is closer;
- a configuration read answers at most one bounded line; no line, or an empty one, is an unset key rather
  than a failure, so an empty owner tag reads as one that was never written and the instance is refused as
  unclaimed;
- an identity is admitted through the ownership seam's own producer, so a value this vocabulary could not
  read is never compared against a bound one;
- a report that is over-long, that carries an ASCII control character (a C0 control or DEL; see
  [Current Status](#current-status) for C1 and format characters), or that lists the exact instance twice
  is a refusal, because each is the daemon contradicting itself. Before that check each line loses one
  trailing carriage return and empty lines are dropped, so a CRLF-terminated report reads as the same
  rows.

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

## Resource wall

The prepared launch (`launchInstanceCommand`) renders the instance's `ProviderSizing`:

```text
limits.cpu=<N>
limits.memory=<memory>
root,size=<storage>
```

`<N>` is the declared CPU count. `<memory>` and `<storage>` are the declaration's quantity text passed
through unchanged (the demo's defaults are `10GiB` and `80GiB`); backend admission (`mkIncusBackendSpec`)
requires only that each is non-empty and alphanumeric, so Incus receives the spelling the configuration
wrote rather than a value the canonical quantity parser normalised. `incusSizingArgs`, which renders
whole `GiB` values from the canonical parser, sizes only the `SubstrateProvider` value's launch plan, which
the Incus route does not execute.

These are real per-VM CPU, memory, and storage walls for a newly created VM. Current reconcile-to-running
does not observe an existing VM's effective limits or resize/refuse it when the declaration changes; it
starts the existing VM unchanged. The in-VM kind cluster computes a local slice, but that does not repair
a stale outer wall. The
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
at most 47 bytes. Admission measures the name in characters and admits non-ASCII alphanumerics, so a
multibyte name within 47 characters can still overflow the budget (see [Current Status](#current-status)).
An Incus installation whose state directory is elsewhere has a different
budget, which admission does not compute.

## Validation

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
