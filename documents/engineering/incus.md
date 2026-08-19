# Incus Host Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [ensure reconcilers](ensure_reconcilers.md), [applied cordon](applied_cordon.md), [durable state](../architecture/durable_state.md), [lifecycle state model](../architecture/lifecycle_state_model.md)

> **Purpose**: Describe the active Incus provider path, its total capability probe, and the remaining
> provider-lifecycle limits.

## Current Status

Native Linux CPU uses an Incus VM as its provider frame. The lower-boundary separation assigns pure
`IncusVM` target data and `execVMArgs` to `HostBootstrap.Lift.Context`; `HostBootstrap.Incus` reexports them
and adds Incus-specific lifecycle probes/builders. The project selects an abstract `SubstrateProvider`
whose narrow projections retain the complete `LiftContext` and pure lifecycle plans without exposing
construction or record update. Generic Lift remains below that realization and imports no Incus lifecycle
module. Real Incus mutation enters through the exact prepared provider backend. The demo's adoption of that
route remains work for the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md). For Incus the optional cordon reconcile
is absent. The prepared route:

- on first creation, launch the named VM with `limits.cpu`, `limits.memory`, and `root,size`;
- when the named VM already exists, run only `incus start` without comparing or changing those limits;
- attach the host `.data` share as an Incus disk device;
- wait for VM/network/share readiness;
- stage source/config and build/install the project binary;
- hand off the project subcommand with `incus exec`;
- stop on `project down`, or force-delete the guarded project VM on `project destroy`.

Host-side `incus` is resolved through `HostTool` and retained as a typed absolute executable by the
provider backend. The backend today holds its four clauses through a retained `flock` front end and an
interpreter program, which is why it also resolves an interpreter and a locking executable and admits only
the one `flock` namespace. The vocabulary that replaces it is built and described in the three sections
below — described commands, one total classification of what the provider answers, and one resumption
decision — and the clause-holding itself moves onto the seam's reported face (see
[ownership seam](../architecture/ownership_seam.md)) in the adoption sprints the
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
still carries. Commands inside the guest intentionally use the guest's own tool lookup.

Before that provider value is used, `HostBootstrap.Ensure.Incus` converges the native provider and runs
a total final observation. Its pure `IncusProviderStatus` distinguishes:

- missing client;
- absent, permission-denied, or otherwise unreachable daemon;
- missing KVM/QEMU/OVMF VM capability;
- unavailable image-server egress; and
- fully ready.

Only the final branch can mint the opaque `IncusProviderCapability`. On Linux the reconcile path installs
the client plus ACL support, initializes/restarts the daemon when needed, establishes immediate socket
access, installs QEMU/OVMF, preserves the Incus bridge through `DOCKER-USER`, and re-runs the complete
probe. Apple uses the same final capability observation after converging its Colima-backed Incus provider.

`SubstrateProvider` plus `Lift` is the single provider/dispatch model. Provider lifecycle and readiness
enter through that boundary; there is no parallel public target or reboot/readiness dispatcher.

The common provider discovery transition is separate from the ensure reconciler's installation proof. It
owns the closed host/guest request order, accepts only raw exit status/streams or transport failure from its
executor, privately classifies the complete ready/not-ready/unavailable/conflict/failure vocabulary, and
polls only `NotReady` within an opaque bounded policy. Tool paths, markers, identities, and backend reports
must be exactly one LF-terminated stdout line with empty stderr; malformed arity, extra output, carriage
returns, and unknown tags are failures. The rank-2 capability is descriptive discovery tied to the exact
opaque managed Running provider and backend realization, not VM mutation authority. The alias backend may
derive a guest executor only from that capability.

The Incus ensure capability is deliberately narrow: it proves the final installation/provider observation
made by the ensure reconciler, not permanent readiness, ownership of a VM, or authorization for an unrelated
mutation. A real provider mutation instead consumes the exact prepared call. Opaque nominal
`ManagedProviderHandle` and `ManagedProviderShareHandle` values retain the backend origin without exposing
generic handle/receipt authority. Under one retained `flock`, the backend publishes and recovers the
explicit-absence provider/share origins, binds VM UUID plus owner nonce, and revalidates identity before and
after ready, share, stop, guest execution, and conditional delete. The
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
carries the closure evidence: its static gate and its native Linux/x86_64 KVM/Incus gate both pass. See
[lifecycle state model](../architecture/lifecycle_state_model.md).

## Asking the provider

`HostBootstrap.Substrate.Provider.Command` is the one place a provider effect becomes a value. Each
function returns a described host command — the tool the frame table names, the exact argument vector, the
stdio disposition, and the frame whose process reads it — and none of them can run anything, which is what
makes an argument vector comparable by application rather than only observable by launching it.

Two properties of the set are worth stating because they are easy to lose:

- **one listing answers two questions.** Presence and lifecycle state come back from the same
  `incus list <name> --format csv -c ns`, because a presence answered by one command and a state answered
  by another are two answers that can disagree about the moment they describe;
- **the owner tag rides on the creating command.** `incus launch` carries
  `user.hostbootstrap.owner=<nonce>` itself rather than a configuration write that follows it, so there is
  no interval in which the instance exists without naming the durable record that owns it.

Every command in the module is interpreted by a process of the outer host. A vector that crosses *into*
the instance is not rendered here: the lift's own fold is the project's single crossing renderer, and a
second one beside it is the duplication that rule exists to prevent. The destructive delete goes through
the frame table's guarded delete described below, so this module supplies only the argument vector for a
name the guard has already admitted.

## Reading what the provider says

A driver that holds ownership clauses over an Incus instance needs two facts about it: whether the daemon
names it at all, and what stable identity the daemon gives it. Both arrive as bytes on a described
command's standard output, and `HostBootstrap.Substrate.Provider.Report` is the one place those bytes
become values. It executes nothing; each classifier is a total function of the interpreter's own outcome,
so the report a driver returns and the decision a caller makes are the same value rather than a rendering
and a parser.

What it admits is deliberately narrow, because a provider is another program's output:

- an instance listing is a set of `name,state` rows, and only the row naming the exact instance is about
  it — the daemon matches a listing argument by prefix, so a sibling name is an absence rather than a hit;
- the two lifecycle states a clause-holding transaction can act from are `RUNNING` and `STOPPED`; every
  other state the daemon might name is refused rather than mapped onto whichever of the two is closer;
- a configuration read answers at most one bounded line, and no line at all is an unset key rather than a
  failure — which is how an owner tag that was never written is told apart from one that is empty;
- an identity is admitted through the ownership seam's own producer, so a value this vocabulary could not
  read is never compared against a bound one;
- a report that is over-long, that carries a control character, or that lists the exact instance twice is
  a refusal, because each is the daemon contradicting itself.

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
through rather than one written per provider. This module supplies only the noun its refusal reads in and
the argument vector for a name the guard has already admitted, so it cannot render a destructive command for
a name the guard would have refused. An instance outside the project's namespace refuses, and so do the two
degenerate inputs that make the guard vacuous: an empty prefix, which is a prefix of every name, and an empty
instance name. `incus stop` carries no guard because it is not destructive.

## Lifecycle caveat

The current root teardown does not recursively enter the Incus child and invoke the lifecycle verb before
stopping/deleting the VM. It runs the verb's reverse projection: current-frame cluster cleanup, then the
reverse the demo declared on its own `deploy-vm` node.
Deleting the VM removes nested compute incidentally. See
[cluster lifecycle](cluster_lifecycle.md).

The host durable root is carried into Incus through a disk device and exposed to Docker through
`/var/tmp/hostbootstrap-demo-data`; it is not merely guest-root-disk state. The destroy/up/readback
guarantee remains unvalidated. The demo guest alias is still created and removed by pathname, so it holds
no receipt at that legacy demo call site. The common clause-holding backend itself is implemented above
Incus/Lima/WSL2: under the retained guest lock it publishes an explicit-absence origin record inside the
host-backed durable target with a fresh 256-bit nonce, flushes and reads it back, publishes the alias by a
no-replace hard link from a nonce staging symlink, binds the symlink's exact device/inode, and releases only
after re-observing that identity. Crash retries recover the prepared or managed record rather than adopting
an exact-looking pathname. The [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns
replacing the legacy demo call site with this prepared route; see
[ownership invariant](../architecture/ownership_invariant.md) and
[durable state](../architecture/durable_state.md).

## Resource wall

`incusSizingArgs` applies:

```text
limits.cpu=<N>
limits.memory=<GiB>GiB
root,size=<GiB>GiB
```

These are real per-VM CPU, memory, and storage walls for a newly created VM. Current reconcile-to-running
does not observe an existing VM's effective limits or resize/refuse it when the declaration changes; it
starts the existing VM unchanged. The in-VM kind cluster computes a local slice, but that does not repair
a stale outer wall. The
[canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md)
supplies the lower result/capacity algebra, while the
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owns the provider-authoritative Incus realization.

## Validation

Static coverage of builders and the prepared backend is not a provider closure gate. Closure requires the
native Linux/x86_64 KVM/Incus run declared by the
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md),
including prepared create/recovery, ready, share/readback, stop/restart, bound guest execution, alias
acquisition/release, identity-conditional delete, and the Direct no-mutation/refusal path. A macOS run is
not evidence for that gate.

That run passed on 2026-08-10 on Ubuntu 24.04.4 LTS x86_64 with Incus 6.0.0, GHC 9.12.4, and Cabal 3.16.1.0;
the phase document holds the exact command, confirmed observations, and residue checks. Recursive teardown
and end-to-end demo durability remain later phase concerns. Status and scheduling belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

### Provider naming bounds

Incus opens one virtio-fs control socket per attached share device at
`<var-path>/devices/<instance>/virtio-fs.<device>.sock`. That is a POSIX unix-domain socket, so the whole
pathname must fit in `sun_path`. The instance name and the share device name therefore share one budget:
the share device is named from its binding digest inside a fixed bound, and backend admission refuses an
instance name that would overflow the remainder. Without both bounds a declaration looks valid and its
share simply never attaches.

## Related

- [WSL2](wsl2.md) and [Lima](lima.md) — peer provider values.
- [durable state](../architecture/durable_state.md) — Incus host share and stable alias.
- [applied cordon](applied_cordon.md) — resource parsing and walls.
- [composition methodology](../architecture/composition_methodology.md) — frame handoff.
