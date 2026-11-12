"""Unit tests for rolling base-image resolvers and build specifications."""

from __future__ import annotations

import ast
import re

from pathlib import Path

import httpx
import pytest

from hostbootstrap import base_image, bootstrap, docker_ops, resources
from hostbootstrap.base_image import Flavor
from hostbootstrap.substrate import Arch


def test_base_tag_and_ref() -> None:
    assert base_image.base_tag(Flavor.CPU, Arch.AMD64) == "basecontainer-cpu-amd64"
    assert (
        base_image.base_image_ref(Flavor.CUDA, Arch.ARM64)
        == "docker.io/tuee22/hostbootstrap:basecontainer-cuda-arm64"
    )


def _patch_version_resolvers(monkeypatch: pytest.MonkeyPatch) -> None:
    for name, value in [
        ("resolve_go_version", "1.23.4"),
        ("resolve_purescript_version", "v0.15.0"),
        ("resolve_kind_version", "v0.23.0"),
        ("resolve_kubectl_version", "v1.30.0"),
        ("resolve_helm_version", "v3.15.0"),
        ("resolve_mc_version", "RELEASE.2025-08-13T08-35-41Z"),
        ("resolve_pulumi_version", "v3.120.0"),
    ]:
        monkeypatch.setattr(base_image, name, lambda result=value: result)
    monkeypatch.setattr(base_image, "resolve_node_version", lambda _arch: "v22.0.0")


def test_compute_build_args_uses_current_resolvers(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_version_resolvers(monkeypatch)

    args = base_image.compute_build_args(
        Flavor.CUDA,
        Arch.AMD64,
        base_image_override="custom:base",
    )
    values = args.as_build_args()

    assert values["BASE_IMAGE"] == "custom:base"
    assert values["IMAGE_FLAVOR"] == "cuda"
    assert values["TARGETARCH"] == "amd64"
    assert values["HASKELL_STYLE_TOOLS_DIR"] == "/opt/hostbootstrap/haskell-style/bin"
    assert values["GO_DOWNLOAD_URL"] == "https://go.dev/dl/go1.23.4.linux-amd64.tar.gz"
    assert values["NODE_DOWNLOAD_URL"].endswith("node-v22.0.0-linux-x64.tar.xz")
    assert values["PURESCRIPT_DOWNLOAD_URL"].endswith("/v0.15.0/linux64.tar.gz")
    assert values["GHCUP_DOWNLOAD_URL"].endswith("/x86_64-linux-ghcup")
    assert values["AWS_DOWNLOAD_URL"].endswith("awscli-exe-linux-x86_64.zip")
    # dl.min.io answers 410 Gone for every community release since the
    # open-source client was archived; the binary comes from the project's own
    # GitHub releases, by tag, per architecture.
    assert values["MC_VERSION"] == "RELEASE.2025-08-13T08-35-41Z"
    assert values["MC_DOWNLOAD_URL"] == (
        "https://github.com/minio/mc/releases/download/RELEASE.2025-08-13T08-35-41Z/"
        "mc.linux-amd64.RELEASE.2025-08-13T08-35-41Z"
    )
    assert values["CABAL_BUILD_JOBS"] == "1"
    assert values["GHC_RTS_OPTS"] == ""
    assert "HACKAGE_INDEX_STATE" not in values
    # The compiler is pinned rather than discovered: it is the warm Cabal
    # store's ABI key, so a base whose GHC drifts from the one consumers select
    # ships a store none of them can read.
    assert values["GHC_VERSION"] == bootstrap.GHC_VERSION


def test_http_helpers(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_get(url: str, **kwargs: object) -> httpx.Response:
        assert kwargs["timeout"] == base_image._HTTP_TIMEOUT
        assert kwargs["follow_redirects"] is True
        request = httpx.Request("GET", url)
        if url.endswith("/json"):
            return httpx.Response(200, json={"ok": True}, request=request)
        return httpx.Response(200, content=b"stable\n", request=request)

    monkeypatch.setattr(httpx, "get", _fake_get)

    assert base_image._http_get_json("https://example.invalid/json") == {"ok": True}
    assert base_image._http_get_text("https://example.invalid/text") == "stable\n"


def test_release_resolvers_parse_current_payloads(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_json(url: str) -> object:
        if "nodejs.org" in url:
            return [
                {"version": "v26.0.0", "files": ["linux-arm64"], "lts": False},
                {"version": "v21.0.0", "files": ["linux-x64"], "lts": "Hydrogen"},
                {"version": "v22.0.0", "files": ["linux-arm64"], "lts": "Iron"},
            ]
        if "go.dev" in url:
            return [
                {"version": "go0.0.1", "stable": False},
                {"version": "go1.23.4", "stable": True},
            ]
        return {"tag_name": "v9.9.9"}

    monkeypatch.setattr(base_image, "_http_get_json", _fake_json)
    monkeypatch.setattr(base_image, "_http_get_text", lambda _url: "v1.30.1\n")

    assert base_image.resolve_node_version(Arch.ARM64) == "v22.0.0"
    assert base_image.resolve_purescript_version() == "v9.9.9"
    assert base_image.resolve_kind_version() == "v9.9.9"
    assert base_image.resolve_kubectl_version() == "v1.30.1"
    assert base_image.resolve_helm_version() == "v9.9.9"
    assert base_image.resolve_mc_version() == "v9.9.9"
    assert base_image.resolve_pulumi_version() == "v9.9.9"
    assert base_image.resolve_go_version() == "1.23.4"


def test_go_resolver_accepts_version_without_prefix(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        base_image,
        "_http_get_json",
        lambda _url: [{"version": "1.24.0", "stable": True}],
    )
    assert base_image.resolve_go_version() == "1.24.0"


def test_resolvers_raise_when_no_release_matches(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(base_image, "_http_get_json", lambda _url: [])
    with pytest.raises(RuntimeError, match="no node LTS release"):
        base_image.resolve_node_version(Arch.AMD64)
    with pytest.raises(RuntimeError, match="no stable go"):
        base_image.resolve_go_version()


def test_json_narrowers_reject_bad_types() -> None:
    with pytest.raises(RuntimeError, match="JSON object"):
        base_image._as_dict([1, 2])
    with pytest.raises(RuntimeError, match="JSON array"):
        base_image._as_list({"a": 1})
    with pytest.raises(RuntimeError, match="string"):
        base_image._str_field({"k": 5}, "k")
    assert base_image._str_field({"k": "v"}, "k") == "v"


def test_iter_cuda_tags_paginates(monkeypatch: pytest.MonkeyPatch) -> None:
    first = {
        "results": [{"name": "12.0.0-cudnn-devel-ubuntu24.04"}],
        "next": "https://example.invalid/page/2",
    }
    second = {
        "results": [{"name": "12.1.0-cudnn-devel-ubuntu24.04"}],
        "next": None,
    }
    seen: list[str] = []

    def _fake_json(url: str) -> object:
        seen.append(url)
        return second if url.endswith("/2") else first

    monkeypatch.setattr(base_image, "_http_get_json", _fake_json)
    assert [tag["name"] for tag in base_image._iter_cuda_tags()] == [
        "12.0.0-cudnn-devel-ubuntu24.04",
        "12.1.0-cudnn-devel-ubuntu24.04",
    ]
    assert len(seen) == 2


def test_cuda_tags_without_a_result_list_contribute_no_tags(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(base_image, "_http_get_json", lambda _url: {"results": None})
    assert base_image._iter_cuda_tags() == []


def test_cuda_arch_detection_and_selection(monkeypatch: pytest.MonkeyPatch) -> None:
    images = [{"architecture": "amd64"}, {"architecture": "arm64"}]
    assert base_image._arch_in_images(images, Arch.ARM64)
    assert not base_image._arch_in_images([{"architecture": "amd64"}], Arch.ARM64)
    assert not base_image._arch_in_images("not-a-list", Arch.AMD64)

    tags = [
        {"name": 5, "images": [{"architecture": "amd64"}]},
        {"name": "12.4.1-cudnn-devel-ubuntu24.04", "images": [{"architecture": "amd64"}]},
        {"name": "12.6.0-cudnn-devel-ubuntu24.04", "images": [{"architecture": "arm64"}]},
        {"name": "not-matching", "images": [{"architecture": "amd64"}]},
    ]
    monkeypatch.setattr(base_image, "_iter_cuda_tags", lambda: tags)
    assert (
        base_image.resolve_cuda_base_image(Arch.AMD64)
        == "nvidia/cuda:12.4.1-cudnn-devel-ubuntu24.04"
    )
    assert (
        base_image.resolve_cuda_base_image(Arch.ARM64)
        == "nvidia/cuda:12.6.0-cudnn-devel-ubuntu24.04"
    )


def test_resolve_cuda_picks_the_newest_numeric_version_not_the_first_or_lexical(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    amd64 = [{"architecture": "amd64"}]
    tags = [
        {"name": "11.8.0-cudnn-devel-ubuntu24.04", "images": amd64},
        {"name": "12.9.1-cudnn-devel-ubuntu24.04", "images": amd64},
        {"name": "12.10.0-cudnn-devel-ubuntu24.04", "images": amd64},
        {"name": "12.9.0-cudnn-devel-ubuntu24.04", "images": amd64},
    ]
    monkeypatch.setattr(base_image, "_iter_cuda_tags", lambda: tags)
    # "12.9.x" sorts after "12.10.x" lexically and the older tag is listed first:
    # only a descending numeric sort selects 12.10.0.
    assert (
        base_image.resolve_cuda_base_image(Arch.AMD64)
        == "nvidia/cuda:12.10.0-cudnn-devel-ubuntu24.04"
    )


def test_resolve_cuda_raises_without_compatible_tag(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(base_image, "_iter_cuda_tags", lambda: [])
    with pytest.raises(RuntimeError, match="no nvidia/cuda"):
        base_image.resolve_cuda_base_image(Arch.AMD64)


def test_compute_build_args_cpu_and_cuda_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_version_resolvers(monkeypatch)
    monkeypatch.setattr(base_image, "resolve_cuda_base_image", lambda arch: f"cuda:{arch}")

    cpu = base_image.compute_build_args(Flavor.CPU, Arch.ARM64)
    cuda = base_image.compute_build_args(Flavor.CUDA, Arch.ARM64)

    assert cpu.base_image == "ubuntu:24.04"
    assert cpu.go_download_url.endswith("linux-arm64.tar.gz")
    assert cpu.node_download_url.endswith("linux-arm64.tar.xz")
    assert cpu.purescript_download_url.endswith("linux-arm64.tar.gz")
    assert cpu.ghcup_download_url.endswith("aarch64-linux-ghcup")
    assert cuda.base_image == "cuda:arm64"


def test_build_spec_for_applies_budget(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_version_resolvers(monkeypatch)
    budget = resources.BuildBudget(
        docker_cpus="3",
        docker_memory="6144m",
        docker_memory_swap="6144m",
        cabal_jobs=3,
    )
    spec, args = base_image.build_spec_for(
        Flavor.CPU,
        Arch.AMD64,
        context=Path("/repo"),
        budget=budget,
    )
    assert spec.builder == docker_ops.ClassicBuilder(memory="6144m", memory_swap="6144m", cpus="3")
    assert args.cabal_build_jobs == "3"
    assert spec.build_args["CABAL_BUILD_JOBS"] == "3"


def test_build_spec_for_is_native_and_unbounded_without_budget(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_version_resolvers(monkeypatch)
    spec, args = base_image.build_spec_for(
        Flavor.CPU,
        Arch.AMD64,
        context=Path("/repo"),
        extra_tags=("extra:tag",),
        no_cache=True,
    )
    assert spec.dockerfile == Path("/repo/docker/basecontainer.Dockerfile")
    assert spec.tags == (
        "docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64",
        "extra:tag",
    )
    assert spec.no_cache is True
    assert spec.builder == docker_ops.BuildKitBuilder()

    overridden = base_image.with_base_override(args, "override:base")
    assert overridden.base_image == "override:base"
    assert args.base_image == "ubuntu:24.04"


def test_build_spec_accepts_pre_resolved_args(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_version_resolvers(monkeypatch)
    args = base_image.compute_build_args(Flavor.CPU, Arch.AMD64)
    spec, resolved = base_image.build_spec_for(
        Flavor.CPU,
        Arch.AMD64,
        context=Path("/repo"),
        dockerfile=Path("/custom/Dockerfile"),
        args=args,
    )
    assert resolved is args
    assert spec.dockerfile == Path("/custom/Dockerfile")


def test_compatibility_smoke_uses_real_consumer() -> None:
    context = Path("/repo")
    digest = f"docker.io/tuee22/hostbootstrap@sha256:{'d' * 64}"
    spec = base_image.compatibility_smoke_spec(
        Flavor.CPU,
        Arch.ARM64,
        context=context,
        base_reference=digest,
        pull=True,
    )
    assert spec.dockerfile == context / "docker/compatibility-smoke.Dockerfile"
    assert spec.context == context
    assert spec.tags == ("hostbootstrap-base-compatibility:cpu-arm64",)
    assert spec.build_args == {"BASE_IMAGE": digest}
    assert spec.pull is True
    assert spec.no_cache is True
    assert spec.builder == docker_ops.BuildKitBuilder()


def test_compatibility_smoke_can_validate_local_base_before_publish() -> None:
    context = Path("/repo")
    image_id = f"sha256:{'a' * 64}"
    spec = base_image.compatibility_smoke_spec(
        Flavor.CPU,
        Arch.AMD64,
        context=context,
        base_reference=image_id,
        pull=False,
    )
    assert spec.build_args == {"BASE_IMAGE": image_id}
    assert spec.pull is False
    assert spec.no_cache is True
    assert spec.builder == docker_ops.ClassicBuilder()


def test_compatibility_smoke_consumer_needs_only_the_base_image() -> None:
    """The smoke's consumer must be buildable by the command this module emits.

    The demo's Dockerfile needs the ``hostbootstrap-builder`` named build context,
    the ``hostbootstrap-build-config`` secret and a ``check-code`` step presenting
    three more build secrets, so the smoke's own consumer asks for none of them.
    """
    dockerfile = Path(__file__).resolve().parent.parent / "docker/compatibility-smoke.Dockerfile"
    body = dockerfile.read_text(encoding="utf-8")
    declared = {
        line.split()[1].split("=")[0] for line in body.splitlines() if line.startswith("ARG ")
    }
    assert declared == {"BASE_IMAGE"}
    assert "--mount=type=secret" not in body
    assert "--from=" not in body


def test_compatibility_smoke_asks_a_consumer_question_past_the_store() -> None:
    """Toolchain and store are separate steps, and the consumer reaches past the store."""
    repo = Path(__file__).resolve().parent.parent
    body = (repo / "docker/compatibility-smoke.Dockerfile").read_text(encoding="utf-8")
    runs = re.split(r"^RUN ", body, flags=re.MULTILINE)[1:]
    toolchain = [run for run in runs if "ghc --version" in run]
    store = [run for run in runs if "package.db/*.conf" in run]
    assert len(toolchain) == 1 and len(store) == 1 and toolchain != store
    assert "'optimization: 2'" in body and "'packages: .'" in body
    depends = body.split("'  build-depends:'")[1].split("> /tmp/compatibility-smoke")[0]
    consumer = set(re.findall(r"'\s{4,6},?\s*([a-z][a-z0-9-]*)'", depends))
    manifests = "".join(
        manifest.read_text(encoding="utf-8")
        for manifest in (repo / "core" / "warm-deps").rglob("*.cabal")
    )
    absent = {name for name in consumer if name and name not in manifests}
    assert absent, "the consumer must depend on a package absent from both warm-deps manifests"


def _cabal_build_depends(path: Path) -> set[str]:
    """Every package name any ``build-depends`` field of one Cabal file lists."""
    lines = path.read_text(encoding="utf-8").splitlines()
    names: set[str] = set()
    index = 0
    while index < len(lines):
        field = re.match(r"^(\s*)build-depends:(.*)$", lines[index])
        index += 1
        if field is None:
            continue
        indent, body = len(field.group(1)), field.group(2)
        while index < len(lines) and (
            not lines[index].strip() or len(lines[index]) - len(lines[index].lstrip()) > indent
        ):
            body += " " + lines[index]
            index += 1
        for part in body.split(","):
            name = re.match(r"\s*([A-Za-z][A-Za-z0-9-]*)", part)
            if name:
                names.add(name.group(1))
    return names


def test_core_warm_manifest_lists_every_direct_non_boot_dependency() -> None:
    """The core closure is warm by listing, not by a transitive path."""
    repo = Path(__file__).resolve().parent.parent
    # GHC boot packages, `Win32` (Windows-only) and the package's own libraries.
    exempt = {"bytestring", "file-io", "Win32", "hostbootstrap-core"}
    direct = _cabal_build_depends(repo / "core/hostbootstrap-core/hostbootstrap-core.cabal")
    listed = _cabal_build_depends(repo / "core/warm-deps/core/basecontainer-core-deps.cabal")
    assert sorted(direct - exempt - listed) == []


def test_base_dockerfile_probes_fail_the_build_and_name_its_input_classes() -> None:
    """No probe pipes into ``grep``; the toolchain is reachable by any uid."""
    repo = Path(__file__).resolve().parent.parent
    body = (repo / "docker/basecontainer.Dockerfile").read_text(encoding="utf-8")
    code = [line for line in body.splitlines() if not line.lstrip().startswith("#")]
    assert [line for line in code if re.search(r"\|\s*grep\b", line)] == []
    assert "/root/.ghcup" not in body
    assert "GHCUP_INSTALL_BASE_PREFIX=/opt/ghcup" in body
    header = body.split("ARG BASE_IMAGE")[0]
    assert "GHC_VERSION" in header and "LLVM_MAJOR" in header
    smoke = (repo / "docker/compatibility-smoke.Dockerfile").read_text(encoding="utf-8")
    for tool in ("ghc", "cabal"):
        assert (
            f"setpriv --reuid=65534 --regid=65534 --clear-groups -- {tool} --numeric-version"
            in smoke
        )


def test_base_style_sample_check_reads_the_committed_contract() -> None:
    """Both style tools find the committed options before the sample check runs."""
    lines = (
        (Path(__file__).resolve().parent.parent / "docker/basecontainer.Dockerfile")
        .read_text(encoding="utf-8")
        .splitlines()
    )
    check = next(i for i, line in enumerate(lines) if "fourmolu --mode check" in line)
    for name in ("fourmolu.yaml", ".hlint.yaml"):
        copy = f"COPY {name} /opt/basecontainer/haskell-deps/{name}"
        assert copy in lines
        assert lines.index(copy) < check


def test_dockerignore_excludes_build_state_at_every_depth() -> None:
    """Docker ignore patterns are context-root-anchored, unlike ``.gitignore``."""
    entries = {
        line.strip()
        for line in (Path(__file__).resolve().parent.parent / ".dockerignore")
        .read_text(encoding="utf-8")
        .splitlines()
        if line.strip() and not line.startswith("#")
    }
    anchored = {
        "**/dist-newstyle/",
        "**/.data/",
        "**/.build/",
        "**/.hostbootstrap/",
        "**/.test_data/",
        "**/cabal.project.freeze",
    }
    assert anchored <= entries
    # No root-only spelling of an anchored entry remains beside its `**/` form.
    assert {entry.removeprefix("**/") for entry in anchored}.isdisjoint(entries)


_DEMO_ALLOWED_ASSIGNMENTS = frozenset({"_FORMATTER_ROOTS", "_LINTER_ROOTS"})
_DEMO_ALLOWED_FUNCTIONS = frozenset({"_quality_gates"})


def _demo_path_constants(source: str, *, allow_cli: bool) -> list[str]:
    """String constants that spell a ``demo`` path segment, outside the cli allow-list."""
    tree = ast.parse(source)
    allowed: set[int] = set()
    if allow_cli:
        for node in ast.walk(tree):
            targets: list[ast.expr] = []
            if isinstance(node, ast.Assign):
                targets = list(node.targets)
            elif isinstance(node, ast.AnnAssign):
                targets = [node.target]
            names = {target.id for target in targets if isinstance(target, ast.Name)}
            owned = bool(names & _DEMO_ALLOWED_ASSIGNMENTS) or (
                isinstance(node, ast.FunctionDef) and node.name in _DEMO_ALLOWED_FUNCTIONS
            )
            if owned:
                allowed.update(id(child) for child in ast.walk(node))
    return [
        node.value
        for node in ast.walk(tree)
        if isinstance(node, ast.Constant)
        and isinstance(node.value, str)
        and id(node) not in allowed
        and (
            node.value == "demo"
            or node.value.startswith(("demo/", "demo\\"))
            or "/demo/" in node.value
        )
    ]


def test_python_owns_no_demo_path() -> None:
    """The bootstrapper never reaches into the demo.

    Building the demo means holding build authority, and that authority has one
    home in the Haskell coordinator. A ``demo`` path segment appearing in any
    string constant under ``hostbootstrap/`` is the shape of the defect this
    replaced: the Python side reaching for a consumer whose build it cannot
    authorize. The check parses each module, so ``Path("demo") / "docker"`` and
    ``("demo", "docker")`` spell the segment and fail it, while the ``cli.py``
    quality-gate roots are the one named allow-list.
    """
    package = Path(__file__).resolve().parent.parent / "hostbootstrap"
    offenders = {
        module.name: found
        for module in sorted(package.glob("*.py"))
        if (
            found := _demo_path_constants(
                module.read_text(encoding="utf-8"), allow_cli=module.name == "cli.py"
            )
        )
    }
    assert offenders == {}


def test_demo_path_check_refuses_a_segment_spelling() -> None:
    for source in (
        'target = context / "demo" / "docker" / "Dockerfile"',
        'roots = ("demo", "docker")',
        'path = "demo/docker/Dockerfile"',
        'path = "build/demo/Dockerfile"',
    ):
        assert _demo_path_constants(source, allow_cli=False) != []
    allowed = '_FORMATTER_ROOTS = (("demo", "src"),)'
    assert _demo_path_constants(allowed, allow_cli=True) == []
    assert _demo_path_constants(allowed, allow_cli=False) == ["demo"]


def test_one_ghc_version_governs_host_image_and_guest() -> None:
    """The family pin has three spellings; two of them cannot import the first.

    ``hostbootstrap.bootstrap.GHC_VERSION`` is the source: the host bootstrapper
    installs it, ``base_image`` passes it to the image build, and both are
    Python. The core workspace names it in Cabal syntax and the VM guest
    bootstrap names it in a Haskell literal, so neither can read the constant.
    A silent disagreement between them is exactly what left the published base
    on a compiler ``core/cabal.project`` could not select, so the agreement is
    asserted rather than assumed.
    """
    repo_root = Path(__file__).resolve().parent.parent
    version = bootstrap.GHC_VERSION

    core_project = (repo_root / "core" / "cabal.project").read_text(encoding="utf-8")
    assert f"with-compiler: ghc-{version}" in core_project

    guest_pin = (repo_root / "demo" / "src" / "HostBootstrapDemo" / "Commands.hs").read_text(
        encoding="utf-8"
    )
    assert f'PinnedToolchain "{version}"' in guest_pin
