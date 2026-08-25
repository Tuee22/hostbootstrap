# Shared Host Resource Protocol

**Status**: Draft
**Supersedes**: N/A
**Referenced by**: [Documentation index](../README.md)

> **Purpose**: Record how hostbootstrap would participate in the shared host claim ledger installed on a
> development machine, and the exact seam it would attach to.
> **Read this if**: you are deciding whether a toolchain install or a base-image build may proceed on a
> machine shared with another project.

**Not adopted.** No hostbootstrap code reads or writes the ledger, no command depends on it, and no phase
owns the work. The ledger is host configuration owned by the machine's operator; its authority is the
installed root and the `spec-version` that root carries, never a copy of a document in any repository,
including this one. This file records only what hostbootstrap would do, so no dependency on another project
is created by writing it.

## Current Status

Draft record of an adoption boundary. It establishes no implementation status, no conformance claim, and no
change to current library relationships, which remain governed by the
[library hierarchy](../architecture/library_hierarchy.md).

## The problem here

Existing resource handling is project-local by design and says so: direct Linux GPU outer work is uncapped,
bare-Linux storage has no runtime quota or image-garbage-collection wall, existing VM sizing is not uniformly
reconciled, and the WSL2 ceiling is one per-user utility-VM wall rather than a per-distribution one. The
base-image builder divides the host budget across the builds it starts itself and accounts for nothing else
running on the machine.

Native compilation and base-image builds are among the heaviest operations this project performs, and two of
them started from two repositories will contend for the same memory with no shared object naming that
contention.

## What hostbootstrap would claim

`Transient` claims for toolchain installation, native compilation, and base-image builds. `Transient` is the
honest kind for this work: it is foreground and supervised, and when the process dies the operating system
has genuinely reclaimed what was charged, so hostbootstrap may release its own stale claim on its next run
without an operator.

Charges come from the budget the builder already computes, extended to cover the whole invocation rather than
only its own sibling builds.

Anything that outlives the invoking command — a VM, an Incus or Lima instance, a registered WSL2
distribution, a retained image store — is `Persistent` if it is ever claimed at all, and is out of scope for a
first adoption.

## Where it would attach

At the pre-binary minimum-assertion step in the Python bootstrapper, before the toolchain is installed and
before the native build starts.

This placement is the reason the ledger is specified as a file format rather than a package. The Haskell
binary does not exist yet at that point in the run — producing it is the work being claimed — so a shared
Haskell library could never govern it. A reader of the record format is a small amount of Python, and the
heaviest operations in this repository become claimable on the first day rather than never.

The primitive is also already present here. The Windows global wall opens an exclusive per-user store outside
any repository, using the portable file-lock primitive that is `flock`/`fcntl` on POSIX and `LockFileEx` on
Windows, with a worked-out ownership and compare-and-swap argument. A ledger participant is that same
primitive pointed at a shared root, not a new mechanism.

## What is not changed

- The root coordinator remains the sole interpreter of project desired state, and the protected store remains
  the sole authority for mode, plan snapshot, operation journal, ownership binding, and recovery.
- No new long-lived process is introduced. A claim is a record plus, for `Transient` work, a lock the running
  process already holds; nothing needs to survive it.
- No enforcement changes. The uncapped and unreconciled cases listed above stay uncapped and unreconciled; a
  claim declares demand, it does not bound it.

## Open before adoption

- No phase owns the adapter, the record reader, or the pre-binary placement.
- A claim inside a guest — an Incus or Lima instance, a WSL2 distribution — coordinates nothing unless the
  host root is mounted into it at the same path. A guest-local file with the same name is a different object.
  Work executed inside a guest is honestly out of scope until that is settled.
- The five substrates and four providers are closed enumerations here. The ledger's families are deliberately
  not that enumeration, and the adapter must not couple them, or hardware this project does not support could
  not be accounted for.
