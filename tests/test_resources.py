"""Unit tests for host-resource introspection and build budgeting."""

from __future__ import annotations

from pathlib import Path

import pytest

from hostbootstrap import resources

_GIB = 1024**3


def _patch_proc(monkeypatch: pytest.MonkeyPatch, tmp_path: Path, text: str | None) -> Path:
    real_path = Path
    meminfo = tmp_path / "meminfo"
    if text is not None:
        meminfo.write_text(text, encoding="utf-8")

    def _fake_path(value: str) -> Path:
        if value == "/proc/meminfo":
            return meminfo
        return real_path(value)

    monkeypatch.setattr(resources, "Path", _fake_path)
    return meminfo


def test_detect_non_linux_returns_none(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(resources.platform, "system", lambda: "Darwin")
    assert resources.detect_host_resources() is None


def test_detect_missing_meminfo_returns_none(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(resources.platform, "system", lambda: "Linux")
    _patch_proc(monkeypatch, tmp_path, None)  # file never written -> not is_file()
    assert resources.detect_host_resources() is None


def test_detect_reads_meminfo_and_affinity(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(resources.platform, "system", lambda: "Linux")
    # Pin sys.platform so the Linux affinity branch runs deterministically on any
    # test host (it gates on sys.platform == "linux"; see detect_host_resources).
    monkeypatch.setattr(resources.sys, "platform", "linux")
    # Includes rows that exercise the skip branches: empty value and non-int.
    _patch_proc(
        monkeypatch,
        tmp_path,
        "MemTotal:       16384 kB\n"
        "MemAvailable:    8192 kB\n"
        "EmptyRow:\n"
        "DirectMap: notnum kB\n",
    )
    monkeypatch.setattr(resources.os, "sched_getaffinity", lambda _pid: {0, 1, 2, 3}, raising=False)

    res = resources.detect_host_resources()
    assert res == resources.HostResources(
        cpu_count=4,
        mem_total_bytes=16384 * 1024,
        mem_available_bytes=8192 * 1024,
    )


def test_detect_meminfo_without_available_falls_back_to_total(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(resources.platform, "system", lambda: "Linux")
    monkeypatch.setattr(resources.sys, "platform", "linux")
    _patch_proc(monkeypatch, tmp_path, "MemTotal:       16384 kB\n")
    monkeypatch.setattr(resources.os, "sched_getaffinity", lambda _pid: {0}, raising=False)

    res = resources.detect_host_resources()
    assert res is not None
    assert res.mem_available_bytes == res.mem_total_bytes == 16384 * 1024


def test_assert_build_minimums_passes_above_floor() -> None:
    res = resources.HostResources(
        cpu_count=8, mem_total_bytes=16 * _GIB, mem_available_bytes=12 * _GIB
    )
    resources.assert_build_minimums(res)  # no raise


@pytest.mark.parametrize(
    ("res", "needle"),
    [
        (
            resources.HostResources(
                cpu_count=1, mem_total_bytes=16 * _GIB, mem_available_bytes=12 * _GIB
            ),
            "CPUs",
        ),
        (
            resources.HostResources(
                cpu_count=8, mem_total_bytes=7 * _GIB, mem_available_bytes=6 * _GIB
            ),
            "total memory",
        ),
        (
            resources.HostResources(
                cpu_count=8, mem_total_bytes=16 * _GIB, mem_available_bytes=2 * _GIB
            ),
            "available memory",
        ),
    ],
)
def test_assert_build_minimums_rejects_below_floor(
    res: resources.HostResources, needle: str
) -> None:
    with pytest.raises(resources.ResourceError, match=needle):
        resources.assert_build_minimums(res)


def test_compute_budget_single_build() -> None:
    res = resources.HostResources(
        cpu_count=8, mem_total_bytes=32 * _GIB, mem_available_bytes=16 * _GIB
    )
    budget = resources.compute_build_budget(res, concurrency=1)
    # headroom = max(4 GiB, 2 GiB) = 4 GiB; usable = 12 GiB;
    # jobs = min(7, floor(12 / 2.5)) = 4
    assert budget.docker_cpus == "7"
    assert budget.cabal_jobs == 4
    assert budget.docker_memory == budget.docker_memory_swap == f"{12 * 1024}m"


def test_compute_budget_splits_across_concurrent_builds() -> None:
    res = resources.HostResources(
        cpu_count=8, mem_total_bytes=32 * _GIB, mem_available_bytes=16 * _GIB
    )
    one = resources.compute_build_budget(res, concurrency=1)
    two = resources.compute_build_budget(res, concurrency=2)
    assert two.cabal_jobs < one.cabal_jobs
    assert int(two.docker_cpus) < int(one.docker_cpus)
    assert two.docker_memory == f"{6 * 1024}m"


def test_compute_budget_clamps_to_at_least_one() -> None:
    res = resources.HostResources(
        cpu_count=2, mem_total_bytes=8 * _GIB, mem_available_bytes=4 * _GIB
    )
    # High concurrency + tight memory must never yield 0 cpus/jobs.
    budget = resources.compute_build_budget(res, concurrency=8)
    assert budget.docker_cpus == "1"
    assert budget.cabal_jobs == 1
