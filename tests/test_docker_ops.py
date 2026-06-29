"""Unit tests for the pure docker command builders."""

from __future__ import annotations

from pathlib import Path

import pytest

from hostbootstrap import docker_ops, process


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
    assert cmd[-2:] == ("D", ".") or cmd[-1] == "."


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
        memory="4096m",
        memory_swap="4096m",
        cpus="3",
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


async def test_build_forces_classic_builder_only_with_resource_caps(
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
        dockerfile=Path("D"), context=Path("."), tags=("t",), build_args={}, memory="1g", cpus="2"
    )
    await docker_ops.build(plain)
    await docker_ops.build(capped)

    assert seen[0] is None
    assert seen[1] == {"DOCKER_BUILDKIT": "0"}


def test_run_command_one_shot_rm_with_mounts() -> None:
    spec = docker_ops.RunSpec(
        image="img",
        command=("echo", "hi"),
        rm=True,
        mounts=(("/h", "/c", False), ("/secret", "/s", True)),
    )
    cmd = docker_ops.run_command(spec)
    assert cmd[:3] == ("docker", "run", "--rm")
    assert "-v" in cmd
    assert "/h:/c" in cmd
    assert "/secret:/s:ro" in cmd
    assert cmd[-3:] == ("img", "echo", "hi")


def test_run_command_detached_service() -> None:
    spec = docker_ops.RunSpec(
        image="img",
        detach=True,
        name="proj",
        env={"K": "V"},
        network="host",
        extra=("-w", "/src"),
    )
    cmd = docker_ops.run_command(spec)
    assert "-d" in cmd
    assert "--restart" not in cmd
    assert ("--name", "proj") == cmd[cmd.index("--name") : cmd.index("--name") + 2]
    assert ("--network", "host") == cmd[cmd.index("--network") : cmd.index("--network") + 2]
    assert "K=V" in cmd
    assert cmd[-3:] == ("-w", "/src", "img")
    assert "--rm" not in cmd


def test_push_tag_inspect_commands() -> None:
    assert docker_ops.push_command("r:t") == ("docker", "push", "r:t")
    assert docker_ops.tag_command("a", "b") == ("docker", "tag", "a", "b")
    assert docker_ops.image_exists_command("x") == ("docker", "image", "inspect", "x")
    assert docker_ops.image_entrypoint_command("x") == (
        "docker",
        "image",
        "inspect",
        "--format",
        "{{json .Config.Entrypoint}}",
        "x",
    )


def test_parse_image_entrypoint() -> None:
    assert docker_ops.parse_image_entrypoint("", tag="img") == ()
    assert docker_ops.parse_image_entrypoint("null\n", tag="img") == ()
    assert docker_ops.parse_image_entrypoint('["/usr/bin/tini","--","proj"]', tag="img") == (
        "/usr/bin/tini",
        "--",
        "proj",
    )
    with pytest.raises(RuntimeError, match="could not parse"):
        docker_ops.parse_image_entrypoint("not-json", tag="img")
    with pytest.raises(RuntimeError, match="unexpected"):
        docker_ops.parse_image_entrypoint('"not-a-list"', tag="img")
    with pytest.raises(RuntimeError, match="unexpected"):
        docker_ops.parse_image_entrypoint("[1]", tag="img")


async def test_async_wrappers_delegate_to_process(
    recorded_commands: list[tuple[str, ...]],
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
    assert await docker_ops.image_exists("t")

    assert recorded_commands[0][:2] == ("docker", "build")
    assert recorded_commands[1] == ("docker", "push", "t")
    assert recorded_commands[2] == ("docker", "image", "inspect", "t")

    async def _fake_run_checked(cmd: object, **kwargs: object) -> process.CommandResult:
        argv = tuple(str(part) for part in cmd)  # type: ignore[union-attr]
        assert kwargs == {"quiet": True}
        return process.CommandResult(
            args=argv,
            returncode=0,
            stdout='["/usr/bin/tini","--","proj"]\n',
            stderr="",
        )

    monkeypatch.setattr(docker_ops.process, "run_checked", _fake_run_checked)
    assert await docker_ops.image_entrypoint("t") == ("/usr/bin/tini", "--", "proj")


async def test_image_exists_false(monkeypatch) -> None:
    async def _missing(cmd: object, **_: object) -> docker_ops.process.CommandResult:
        argv = tuple(str(part) for part in cmd)
        return docker_ops.process.CommandResult(args=argv, returncode=1, stdout="", stderr="")

    monkeypatch.setattr(docker_ops.process, "run", _missing)

    assert not await docker_ops.image_exists("missing")
