"""Host-resource introspection and explicit build-resource budgeting.

The base-image build compiles the warm Cabal store at ``-O2`` with the vanilla
and dynamic ways both enabled. That is RAM-hungry: an unbounded ``cabal build
all`` fans out to ``-j$ncpus`` and many concurrent GHC processes can exhaust host
memory, at which point the GHC RTS dies with SIGSEGV rather than a clean OOM (see
``documents/engineering/base_image.md``).

Rather than guess a fixed ``-j1``, we *measure* the host and derive a budget:

* a hard floor below which the build is refused outright
  (:func:`assert_build_minimums`), and
* a per-build budget (:func:`compute_build_budget`) that yields the docker
  ``--memory`` / ``--cpus`` caps and a memory-sized cabal ``-j`` so the build
  provably fits under the cap instead of OOM-racing.

Introspection is Linux-only and uses the stdlib (``/proc/meminfo`` +
``os.sched_getaffinity``); :func:`detect_host_resources` returns ``None`` off
Linux, where docker already runs inside a resource-bounded VM.
"""

from __future__ import annotations

import math
import os
import platform
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final

_GIB: Final[int] = 1024**3
_MIB: Final[int] = 1024**2

# The supported build machine is **16 GB RAM / 8 CPUs (max)**; the floors and
# budget below are tuned for that reference and fail fast on anything weaker.
#
# Fail-fast floors: below any of these a base build is refused outright. A real
# "16 GB" box reports ~15.3-15.6 GiB MemTotal (firmware/kernel reserve some), so
# the total floor sits at 14 GiB — comfortably passed by a 16 GB machine, cleanly
# failed by a 12 GB one (~11.6 GiB). The available floor guarantees enough free
# RAM to build without thrashing even with a desktop session running.
MIN_CPUS: Final[int] = 8
MIN_MEM_TOTAL_BYTES: Final[int] = 14 * _GIB
MIN_MEM_AVAILABLE_BYTES: Final[int] = 8 * _GIB

# Reserve headroom for the host (and other base build) before sizing the budget:
# the larger of a fixed floor and a fraction of available memory.
HOST_MEM_HEADROOM_BYTES: Final[int] = 2 * _GIB
HOST_MEM_HEADROOM_FRACTION: Final[float] = 0.25

# Empirical peak resident set of one heavy ``-O2`` + dynamic-way GHC compile
# (math-functions, statistics, vector). The knob that turns a memory budget into a
# safe job count: on the 16 GB reference it yields a memory-bound ``-j4`` (the
# binding constraint there is RAM, not the 8 cores), which is the largest fan-out
# that provably fits and avoids the OOM-race that segfaulted the unbounded build.
MEM_PER_GHC_JOB_BYTES: Final[int] = (5 * _GIB) // 2  # 2.5 GiB


class ResourceError(RuntimeError):
    """The host does not meet the minimums required to build the base image."""


@dataclass(frozen=True)
class HostResources:
    """Measured host CPU/memory, in whole CPUs and bytes."""

    cpu_count: int
    mem_total_bytes: int
    mem_available_bytes: int


@dataclass(frozen=True)
class BuildBudget:
    """A per-build resource budget derived from :class:`HostResources`.

    ``docker_*`` are ready-to-use ``docker build`` flag values; ``cabal_jobs`` is
    the package-level fan-out (``cabal build all -j<N>``) sized so the build stays
    within ``docker_memory``.
    """

    docker_cpus: str
    docker_memory: str
    docker_memory_swap: str
    cabal_jobs: int


def _parse_meminfo(text: str) -> dict[str, int]:
    """Parse ``/proc/meminfo`` lines (``MemTotal:  16384 kB``) into bytes."""
    out: dict[str, int] = {}
    for line in text.splitlines():
        key, _, rest = line.partition(":")
        fields = rest.split()
        if not fields:
            continue
        try:
            value = int(fields[0])
        except ValueError:
            continue
        # All numeric /proc/meminfo rows are in kB; bare-number rows are rare and
        # not ones we consume, so treating the unit as kB is safe here.
        out[key.strip()] = value * 1024
    return out


def detect_host_resources() -> HostResources | None:
    """Measure host CPU/memory on Linux; ``None`` on other platforms.

    CPU count uses the scheduler affinity mask (what docker will actually see);
    memory comes from ``/proc/meminfo``.
    """
    if platform.system() != "Linux":
        return None
    meminfo = Path("/proc/meminfo")
    if not meminfo.is_file():
        return None
    info = _parse_meminfo(meminfo.read_text())
    mem_total = info.get("MemTotal", 0)
    mem_available = info.get("MemAvailable", mem_total)
    # os.sched_getaffinity is Linux-only (typeshed guards it behind
    # `sys.platform == "linux"`); use the same guard so mypy passes under a darwin
    # target too. On Linux it respects the CPU affinity / cgroup mask docker sees;
    # elsewhere we fall back to cpu_count. The else is unreachable at runtime (we
    # already returned None off Linux above) but keeps mypy total and portable.
    if sys.platform == "linux":
        cpu_count = len(os.sched_getaffinity(0))
    else:  # pragma: no cover - non-Linux returns None before reaching here
        cpu_count = os.cpu_count() or 1
    return HostResources(
        cpu_count=cpu_count,
        mem_total_bytes=mem_total,
        mem_available_bytes=mem_available,
    )


def _gib(num_bytes: int) -> str:
    return f"{num_bytes / _GIB:.1f} GiB"


def assert_build_minimums(res: HostResources) -> None:
    """Refuse the build if the host is below the CPU/memory floors."""
    shortfalls: list[str] = []
    if res.cpu_count < MIN_CPUS:
        shortfalls.append(f"CPUs: have {res.cpu_count}, need >= {MIN_CPUS}")
    if res.mem_total_bytes < MIN_MEM_TOTAL_BYTES:
        shortfalls.append(
            f"total memory: have {_gib(res.mem_total_bytes)}, "
            f"need >= {_gib(MIN_MEM_TOTAL_BYTES)}"
        )
    if res.mem_available_bytes < MIN_MEM_AVAILABLE_BYTES:
        shortfalls.append(
            f"available memory: have {_gib(res.mem_available_bytes)}, "
            f"need >= {_gib(MIN_MEM_AVAILABLE_BYTES)}"
        )
    if shortfalls:
        raise ResourceError(
            "insufficient host resources to build the base image; free up "
            "resources or build elsewhere. " + "; ".join(shortfalls)
        )


def compute_build_budget(res: HostResources, *, concurrency: int) -> BuildBudget:
    """Derive a per-build budget, splitting the host across ``concurrency`` builds.

    ``concurrency`` is the number of base builds running at the same time (2 for a
    concurrent cpu+cuda run, 1 for ``--sequential`` or a single ``--flavor``), so
    two simultaneous docker builds never sum past the host.
    """
    concurrency = max(1, concurrency)

    headroom = max(
        int(res.mem_available_bytes * HOST_MEM_HEADROOM_FRACTION),
        HOST_MEM_HEADROOM_BYTES,
    )
    usable = max(res.mem_available_bytes - headroom, MEM_PER_GHC_JOB_BYTES)
    mem_budget = max(usable // concurrency, MEM_PER_GHC_JOB_BYTES)

    cpus_total = max(1, res.cpu_count - 1)
    cpu_budget = max(1, cpus_total // concurrency)

    cabal_jobs = max(1, min(cpu_budget, mem_budget // MEM_PER_GHC_JOB_BYTES))

    mem_str = f"{math.floor(mem_budget / _MIB)}m"
    return BuildBudget(
        docker_cpus=str(cpu_budget),
        docker_memory=mem_str,
        docker_memory_swap=mem_str,
        cabal_jobs=cabal_jobs,
    )
