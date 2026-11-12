"""Unit tests for the pure docker command builders."""

from __future__ import annotations

from pathlib import Path

import pytest

from hostbootstrap import docker_ops, process
from hostbootstrap.substrate import Arch


def test_build_command_full() -> None:
    spec = docker_ops.BuildSpec(
        dockerfile=Path("docker/app.Dockerfile"),
        context=Path("/proj"),
        tags=("app:linux-cpu-amd64", "app:latest"),
        build_args={"BASE_IMAGE": "base:tag", "FOO": "bar"},
        target="builder",
        pull=True,
    )
    assert docker_ops.build_command(spec) == (
        "docker",
        "build",
        "--build-arg",
        "BASE_IMAGE=base:tag",
        "--build-arg",
        "FOO=bar",
        "--tag",
        "app:linux-cpu-amd64",
        "--tag",
        "app:latest",
        "--target",
        "builder",
        "--pull",
        "--file",
        "docker/app.Dockerfile",
        "/proj",
    )


def test_build_command_minimal_no_pull_no_target() -> None:
    spec = docker_ops.BuildSpec(
        dockerfile=Path("D"),
        context=Path("."),
        tags=("t",),
        build_args={},
        pull=False,
    )
    cmd = docker_ops.build_command(spec)
    assert "--pull" not in cmd
    assert "--no-cache" not in cmd
    assert "--target" not in cmd
    assert cmd[-3:] == ("--file", "D", ".")


def test_build_command_no_cache() -> None:
    spec = docker_ops.BuildSpec(
        dockerfile=Path("D"),
        context=Path("."),
        tags=("t",),
        build_args={},
        pull=True,
        no_cache=True,
    )
    cmd = docker_ops.build_command(spec)
    assert "--no-cache" in cmd
    assert "--pull" in cmd
    assert cmd.index("--no-cache") > cmd.index("--pull")


def test_build_command_resource_limits() -> None:
    spec = docker_ops.BuildSpec(
        dockerfile=Path("D"),
        context=Path("."),
        tags=("t",),
        build_args={},
        pull=False,
        builder=docker_ops.ClassicBuilder(memory="4096m", memory_swap="4096m", cpus="3"),
    )
    cmd = docker_ops.build_command(spec)
    i = cmd.index("--memory")
    assert cmd[i : i + 2] == ("--memory", "4096m")
    j = cmd.index("--memory-swap")
    assert cmd[j : j + 2] == ("--memory-swap", "4096m")
    # The classic builder has no --cpus; 3 CPUs == a CFS quota of 3 * period.
    assert "--cpus" not in cmd
    p = cmd.index("--cpu-period")
    assert cmd[p : p + 2] == ("--cpu-period", "100000")
    q = cmd.index("--cpu-quota")
    assert cmd[q : q + 2] == ("--cpu-quota", "300000")
    # resource caps precede the dockerfile/context tail.
    assert cmd.index("--memory") < cmd.index("--file")
    assert cmd.index("--cpu-quota") < cmd.index("--file")


def test_build_command_omits_resource_limits_when_unset() -> None:
    spec = docker_ops.BuildSpec(
        dockerfile=Path("D"),
        context=Path("."),
        tags=("t",),
        build_args={},
    )
    cmd = docker_ops.build_command(spec)
    assert "--memory" not in cmd
    assert "--memory-swap" not in cmd
    assert "--cpu-period" not in cmd
    assert "--cpu-quota" not in cmd


async def test_build_forces_classic_builder_for_caps_or_explicit_local_resolution(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    seen: list[object] = []

    async def _fake_run_checked(cmd: object, **kwargs: object) -> process.CommandResult:
        seen.append(kwargs.get("env"))
        argv = tuple(str(part) for part in cmd)  # type: ignore[union-attr]
        return process.CommandResult(args=argv, returncode=0, stdout="", stderr="")

    monkeypatch.setattr(docker_ops.process, "run_checked", _fake_run_checked)

    plain = docker_ops.BuildSpec(
        dockerfile=Path("D"), context=Path("."), tags=("t",), build_args={}
    )
    capped = docker_ops.BuildSpec(
        dockerfile=Path("D"),
        context=Path("."),
        tags=("t",),
        build_args={},
        builder=docker_ops.ClassicBuilder(memory="1g", cpus="2"),
    )
    local = docker_ops.BuildSpec(
        dockerfile=Path("D"),
        context=Path("."),
        tags=("t",),
        build_args={},
        builder=docker_ops.ClassicBuilder(),
    )
    await docker_ops.build(plain)
    await docker_ops.build(capped)
    await docker_ops.build(local)

    assert seen[0] is None
    assert seen[1] == {"DOCKER_BUILDKIT": "0"}
    assert seen[2] == {"DOCKER_BUILDKIT": "0"}


def test_push_tag_inspect_commands() -> None:
    assert docker_ops.push_command("r:t") == ("docker", "push", "r:t")
    assert docker_ops.pull_command("r:t") == ("docker", "pull", "r:t")
    assert docker_ops.engine_arch_command() == (
        "docker",
        "info",
        "--format",
        "{{.Architecture}}",
    )
    assert docker_ops.image_repo_digests_command("r:t") == (
        "docker",
        "image",
        "inspect",
        "--format",
        "{{json .RepoDigests}}",
        "r:t",
    )
    assert docker_ops.image_id_command("r:t") == (
        "docker",
        "image",
        "inspect",
        "--format",
        "{{.Id}}",
        "r:t",
    )


@pytest.mark.parametrize(
    ("rendered", "expected"),
    [
        ("amd64\n", Arch.AMD64),
        ("x86_64", Arch.AMD64),
        ("arm64", Arch.ARM64),
        ("AARCH64", Arch.ARM64),
    ],
)
def test_normalize_architecture(rendered: str, expected: Arch) -> None:
    assert docker_ops.normalize_architecture(rendered) == expected


def test_normalize_architecture_rejects_unknown_value() -> None:
    with pytest.raises(RuntimeError, match="unsupported Docker architecture"):
        docker_ops.normalize_architecture("ppc64le")


def test_parse_digest_reference_requires_one_matching_sha256() -> None:
    tag = "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
    expected = f"docker.io/tuee22/hostbootstrap@sha256:{'a' * 64}"
    rendered = '["unrelated/image@sha256:' + "b" * 64 + '","' + expected + '"]'
    assert docker_ops.parse_digest_reference(rendered, tag=tag) == expected

    with pytest.raises(RuntimeError, match="could not parse"):
        docker_ops.parse_digest_reference("not-json", tag=tag)
    with pytest.raises(RuntimeError, match="unexpected"):
        docker_ops.parse_digest_reference('"not-a-list"', tag=tag)
    with pytest.raises(RuntimeError, match="exactly one"):
        docker_ops.parse_digest_reference("[]", tag=tag)
    with pytest.raises(RuntimeError, match="exactly one"):
        docker_ops.parse_digest_reference(
            f'["{expected}","{expected}"]',
            tag=tag,
        )


def test_parse_digest_reference_accepts_docker_hub_registry_elision() -> None:
    tag = "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
    digest = f"sha256:{'c' * 64}"
    rendered = f'["tuee22/hostbootstrap@{digest}"]'

    assert docker_ops.parse_digest_reference(rendered, tag=tag) == (
        f"docker.io/tuee22/hostbootstrap@{digest}"
    )


def test_parse_digest_reference_requires_a_canonical_lowercase_hex_digest() -> None:
    tag = "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
    repository = "docker.io/tuee22/hostbootstrap"
    for digest in ("a" * 63, "g" * 64, "A" * 64, "a" * 65):
        with pytest.raises(RuntimeError, match="exactly one"):
            docker_ops.parse_digest_reference(f'["{repository}@sha256:{digest}"]', tag=tag)


def test_parse_digest_reference_skips_non_string_entries() -> None:
    tag = "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
    expected = f"docker.io/tuee22/hostbootstrap@sha256:{'a' * 64}"
    assert docker_ops.parse_digest_reference(f'[5, "{expected}"]', tag=tag) == expected


def test_parse_digest_reference_normalizes_the_index_registry_alias() -> None:
    tag = "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
    digest = f"sha256:{'e' * 64}"
    rendered = f'["index.docker.io/tuee22/hostbootstrap@{digest}"]'
    assert docker_ops.parse_digest_reference(rendered, tag=tag) == (
        f"docker.io/tuee22/hostbootstrap@{digest}"
    )


def test_parse_digest_reference_keeps_a_registry_port_in_the_repository() -> None:
    tag = "localhost:5000/repo"
    entry = f"localhost:5000/repo@sha256:{'f' * 64}"
    assert docker_ops.parse_digest_reference(f'["{entry}"]', tag=tag) == entry


def test_parse_image_id_requires_full_sha256() -> None:
    image_id = f"sha256:{'d' * 64}"
    assert docker_ops.parse_image_id(f"{image_id}\n", tag="r:t") == image_id
    with pytest.raises(RuntimeError, match="unexpected Docker image ID"):
        docker_ops.parse_image_id("sha256:short", tag="r:t")
    with pytest.raises(RuntimeError, match="unexpected Docker image ID"):
        docker_ops.parse_image_id(f"sha256:{'D' * 64}", tag="r:t")


async def test_async_wrappers_delegate_to_process(
    recorded_commands: list[tuple[tuple[str, ...], Path | None, str]],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    spec = docker_ops.BuildSpec(
        dockerfile=Path("D"),
        context=Path("."),
        tags=("t",),
        build_args={},
    )

    assert (await docker_ops.build(spec)).ok
    assert (await docker_ops.push("t")).ok
    assert (await docker_ops.pull("t")).ok

    assert recorded_commands[0][0][:2] == ("docker", "build")
    assert recorded_commands[1] == (("docker", "push", "t"), None, "checked")
    assert recorded_commands[2] == (("docker", "pull", "t"), None, "checked")


async def test_arch_and_digest_async_wrappers_parse_quiet_output(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    tag = "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
    digest = f"docker.io/tuee22/hostbootstrap@sha256:{'c' * 64}"
    calls: list[tuple[str, ...]] = []

    async def _fake_run_checked(cmd: object, **kwargs: object) -> process.CommandResult:
        argv = tuple(str(part) for part in cmd)  # type: ignore[union-attr]
        calls.append(argv)
        assert kwargs == {"quiet": True}
        if argv[:2] == ("docker", "info"):
            stdout = "aarch64\n"
        elif argv == docker_ops.image_id_command(tag):
            stdout = f"sha256:{'d' * 64}\n"
        else:
            stdout = f'["{digest}"]\n'
        return process.CommandResult(argv, 0, stdout, "")

    monkeypatch.setattr(docker_ops.process, "run_checked", _fake_run_checked)

    assert await docker_ops.engine_arch() is Arch.ARM64
    assert await docker_ops.image_digest_reference(tag) == digest
    assert await docker_ops.image_id(tag) == f"sha256:{'d' * 64}"
    assert calls == [
        docker_ops.engine_arch_command(),
        docker_ops.image_repo_digests_command(tag),
        docker_ops.image_id_command(tag),
    ]
