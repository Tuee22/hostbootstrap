# Readiness Witnesses and Legible Failure

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [harness_workflow](harness_workflow.md), [cluster_lifecycle](../engineering/cluster_lifecycle.md), [wsl2](../engineering/wsl2.md), [incus](../engineering/incus.md), [durable_state](durable_state.md), [development plan](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md)

> **Purpose**: Define the one readiness discipline `hostbootstrap-core` provides — the sealed phantom
> `Ready` witness minted only by a retrying `Probe`, the rule that every frame-mutating lifecycle step is
> gated by such a witness, the trivial-guest-command contract that survives the Windows quoting path, and
> the legible-failure contract that keeps a bring-up failure from collapsing to a message-less
> `ExitFailure 1`.

## TL;DR

- A lifecycle step proves a dependency is ready with a **sealed, phantom-tagged `Ready tag` witness**
  (`HostBootstrap.Readiness`). The constructor is hidden; a witness is minted **only** by `awaitReady`,
  which polls a `Probe` to success. A frame-mutating step takes the witness it depends on as an argument,
  so "act before ready" is a **type error**, not a comment.
- A `Probe` is **retrying and total**: `ProbeResult = ProbeReady a | NotReady | Failed String`. A transient
  condition is `NotReady` (retried within a bounded `PollPolicy`); a deterministic error is `Failed msg`
  (stops immediately, carrying its message). The two are never conflated into a bare exit code.
- **Every mutating in-frame step is gated.** A one-shot in-guest step with no witness and no retry is a
  defect: it races the readiness it assumes and hides why it failed.
- **Guest probes stay trivial.** On Windows a probe crosses PowerShell's native-argument quoting on the way
  to `wsl -d <distro> -- bash -lc <cmd>`, so a probe is a single simple command — never a compound
  `set -eu` script with nested `"$(… "…")"` quoting. Retry and branching live in Haskell.
- **Failure is legible.** A bring-up failure surfaces a structured `LifecycleFailure` carrying its cause
  across the subprocess and harness boundary; the report card renders that cause (`displayException`), never
  a bare `ExitFailure 1`.

## The `Ready` Witness

`HostBootstrap.Readiness` exposes a witness type whose constructor is **sealed** — it lives in
`HostBootstrap.Readiness.Internal` and is not re-exported, so production code sees `Ready` as an opaque type
with no visible constructor:

```haskell
data Ready tag          -- constructor MkReady hidden in .Internal; not forgeable in production
awaitReady :: PollPolicy -> String -> Probe a -> HostConfig -> IO (Either PollError (Ready tag))
```

The `tag` is a phantom (an empty marker type such as `DockerDaemon`, `RegistryServing`, or
`DurableShareMounted`); the witness carries no value. Its only role is to **order effects at the type
level**: a step that mutates a frame takes the witness for the dependency it needs as its first argument and
ignores it at the value level, so the compiler refuses a call that has not first obtained the witness.

```haskell
buildProjectImage :: Ready DockerDaemon  -> HostConfig -> SubstrateProvider -> … -> IO ()
pushImageBlob     :: Ready RegistryServing -> HostConfig -> String -> IO ()
```

Because the only production source of a `Ready tag` is `awaitReady`, and `awaitReady` yields one only after
its `Probe` returned `ProbeReady`, "push before the registry serves `/v2/`" or "mint the durable alias
before the share is mounted" are **type errors**, not conventions a reviewer must catch.

## Probes: Retrying and Total

A probe reads the host config and returns a total verdict:

```haskell
type Probe a       = HostConfig -> IO (ProbeResult a)
data ProbeResult a = ProbeReady a | NotReady | Failed String
data PollPolicy    = PollPolicy { ppAttempts :: Int, ppDelay :: Micros }
```

- `ProbeReady a` — the dependency answered; `awaitReady` mints the witness (discarding the payload).
- `NotReady` — a **transient** condition (a mount not yet visible, a socket not yet listening, a rollout
  still progressing). The bounded `PollPolicy` retries after a delay; exhausting the budget is a
  `PollTimeout`.
- `Failed msg` — a **deterministic** error that will not clear (a collision, an unauthenticated refusal).
  Polling stops immediately and surfaces `msg`; the remaining budget is not burned.

The per-attempt decision (`pollStep`) is a pure, unit-tested function; the only effectful seam is the thin
`pollUntilReadyWith` loop. Named policies (`dockerPoll`, `networkPoll`, `reachPoll`, `rolloutPoll`,
`vmBootPoll`, …) pin each budget to the loop it governs; failures render through `PollError` /
`renderPollError` so the reason is a one-line message, not an exit code.

The distinction between `NotReady` and `Failed` is the heart of the discipline: a transient
mount-not-yet-visible **retries**, while a genuine alias collision **stops with its message**. A single
`set -eu` shell test that exits non-zero conflates the two and is exactly what this framework replaces.

## Gating Every Mutating Step

The rule is uniform: **a step that changes a frame's state consumes a `Ready` witness for each dependency
it assumes.** Read-only waiters mint witnesses; mutating steps consume them. The provider bring-up chain is
a type-enforced total order — the VM answers, then the network is up, then the durable share is mounted,
then the alias is minted (§ DD of the [development plan standards](../../DEVELOPMENT_PLAN/development_plan_standards.md)) —
each step taking the prior witness and producing the next.

- **WRONG**
  ```haskell
  -- ungated, one-shot; races the mount and hides the failure
  prepareAlias :: HostConfig -> SubstrateProvider -> HostPathShare -> IO ()
  prepareAlias cfg p share = runInGuest cfg p
      "set -eu; test -d \"$t\"; test -w \"$t\"; \
      \if [ -L \"$a\" ]; then test \"$(readlink \"$a\")\" = \"$t\"; else ln -s \"$t\" \"$a\"; fi"
  ```
  This is wrong because it takes no witness (nothing proves the share is mounted before it writes), it never
  retries a transient not-yet-mounted drvfs, and it collapses every outcome — collision *or* a not-yet-ready
  mount — into one non-zero exit that the harness renders as `ExitFailure 1`.

- **RIGHT**
  ```haskell
  mounted <- awaitDurableShareMounted netReady cfg p share   -- Ready DurableShareMounted, retried
  mintDurableAlias mounted cfg p share                       -- requires the witness; a collision is Failed msg
  ```
  A trivial probe (`test -d`, `test -w`) retries the transient window and mints the witness; the alias step
  cannot run without it, and a real collision surfaces as a message, not an exit code.

## Trivial Guest Probes

A guest probe crosses the host→guest command path unchanged only if it stays simple. On Windows the
invocation is `powershell … & wsl -d <distro> -- bash -lc <script>`, and PowerShell re-quotes each native
argument; a compound script with embedded `"$(readlink "$a")"` and `>&2` does not survive that rewrite
intact. So:

- a probe is **one** simple command — `docker info >/dev/null 2>&1`, `getent hosts <mirror>`, `test -d <p>`,
  `readlink <p>` — with at most single-level quoting and no nested command substitution;
- **retry** is the Haskell `awaitReady` loop, not an inline shell `for`/`while`;
- **branching** (absent / linked-correctly / collision) is a pure Haskell classifier over the probe's
  captured output (for the durable alias, the `AliasState` classifier of § DD), not shell `if/elif/else`.

This is the same reason the in-VM docker-readiness poll is a Haskell loop around a bare
`docker info >/dev/null 2>&1` rather than an inline shell retry.

## Legible Failure

A bring-up failure must state *why*. The failure modes to avoid:

- `System.Exit.die` prints its message to stderr and throws a **message-less** `ExitFailure 1 :: ExitCode`.
  When the harness catches that and renders `show err`, the result is the literal `"ExitFailure 1"` — the
  cause is gone.
- A runner that folds a child's captured output into a `die` string loses it again across the subprocess
  boundary, and a `set -eu` probe that fails silently carries no output at all.

The contract:

- **Structured exception.** Lifecycle failures are a typed `LifecycleFailure` carrying the cause, the peer
  of the harness `SafetyRefusal` round-trip (see [harness_workflow](harness_workflow.md)). It crosses the
  self-reference subprocess boundary and the harness catch, and the report card renders it with
  `displayException`, so a failed variant reads its reason, not `ExitFailure 1`.
- **Stream-then-die.** A runner that captures a child's output **streams it (line-buffered, flushed) and
  then dies with the exit context**, rather than folding it into a stderr the recursive handoff and harness
  teardown unwind. This is the shape the in-VM image-build reporter and the `check-code` runner already use;
  it becomes the default for every capturing runner.

## Current Status

The poll/witness framework is implemented: `HostBootstrap.Readiness` ships the sealed `Ready`, `awaitReady`,
`Probe`/`ProbeResult`, `PollPolicy`, the named policies, and the pure `pollStep`, and several steps already
gate on it (`Ready DockerDaemon` for the project-image build, `Ready RegistryServing`/`Ready MinioReady` for
the push/bucket steps, `Ready VMReady` for the VM-answer wait).

The **universal** gating discipline, the trivial-guest-probe contract for the durable-share/alias step, the
`AliasState` primitive (§ DD), and the `LifecycleFailure`/stream-then-die legible-failure contract **landed
and are validated `Done` (2026-07-23)**. The durable-share alias is now the pure, readiness-gated `AliasState`
primitive; the previously-ungated in-guest steps (`stageSource`/`streamVMConfig`/the install steps) take a
`Ready VMReady` witness; and a bring-up failure surfaces a legible `LifecycleFailure` rendered via
`displayException`. Closed on a live Windows/WSL2 `test run all` reporting **`8/8 passed`** — the alias links
cleanly (`vm up: linked durable alias …`) where it once collapsed `0/8`, and an intermediate `6/8` run's
failures each **named their cause** rather than `ExitFailure 1`. The owning sprints
([phase-9 Sprint 9.8](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md),
[phase-10 Sprint 10.8](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md),
[phase-11 Sprint 11.9](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md)) are `Done`; superseded surfaces
are in [legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).

## See Also

- [harness_workflow](harness_workflow.md) — the test engine whose report card renders `LifecycleFailure`.
- [durable_state](durable_state.md) — the durable-share primitive whose mount/alias steps this gating orders.
- [cluster_lifecycle](../engineering/cluster_lifecycle.md) — cluster bring-up steps gated by node/CNI
  readiness.
- [wsl2](../engineering/wsl2.md), [incus](../engineering/incus.md) — the per-substrate `classify*Readiness`
  verdicts that defer to this discipline.
- [development plan standards § CC/§ DD](../../DEVELOPMENT_PLAN/development_plan_standards.md) — the doctrine
  sections this document is the canonical home for.
