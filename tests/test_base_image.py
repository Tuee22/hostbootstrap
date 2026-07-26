"""Unit tests for rolling base-image resolvers and build specifications."""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest

from hostbootstrap import base_image, resources
from hostbootstrap.base_image import Flavor
from hostbootstrap.substrate import SubstrateName


def test_base_tag_and_ref() -> None:
    assert base_image.base_tag(Flavor.CPU, "amd64") == "basecontainer-cpu-amd64"
    assert (
        base_image.base_image_ref(Flavor.CUDA, "arm64")
        == "docker.io/tuee22/hostbootstrap:basecontainer-cuda-arm64"
    )


@pytest.mark.parametrize(
    ("substrate", "expected"),
    [
        (SubstrateName.APPLE_SILICON, Flavor.CPU),
        (SubstrateName.LINUX_CPU, Flavor.CPU),
        (SubstrateName.LINUX_GPU, Flavor.CUDA),
    ],
)
def test_substrate_to_flavor(substrate: SubstrateName, expected: Flavor) -> None:
    assert base_image.substrate_to_flavor(substrate) == expected


def _patch_version_resolvers(monkeypatch: pytest.MonkeyPatch) -> None:
    for name, value in [
        ("resolve_go_version", "1.23.4"),
        ("resolve_purescript_version", "v0.15.0"),
        ("resolve_kind_version", "v0.23.0"),
        ("resolve_kubectl_version", "v1.30.0"),
        ("resolve_helm_version", "v3.15.0"),
        ("resolve_pulumi_version", "v3.120.0"),
    ]:
        monkeypatch.setattr(base_image, name, lambda result=value: result)
    monkeypatch.setattr(base_image, "resolve_node_version", lambda _arch: "v22.0.0")


def test_compute_build_args_uses_current_resolvers(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_version_resolvers(monkeypatch)

    args = base_image.compute_build_args(
        Flavor.CUDA,
        "amd64",
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
    assert values["CABAL_BUILD_JOBS"] == "1"
    assert values["GHC_RTS_OPTS"] == ""
    assert "HACKAGE_INDEX_STATE" not in values
    assert "GHC_VERSION" not in values


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

    assert base_image.resolve_node_version("arm64") == "v22.0.0"
    assert base_image.resolve_purescript_version() == "v9.9.9"
    assert base_image.resolve_kind_version() == "v9.9.9"
    assert base_image.resolve_kubectl_version() == "v1.30.1"
    assert base_image.resolve_helm_version() == "v9.9.9"
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
        base_image.resolve_node_version("amd64")
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


def test_cuda_arch_detection_and_selection(monkeypatch: pytest.MonkeyPatch) -> None:
    images = [{"architecture": "amd64"}, {"architecture": "arm64"}]
    assert base_image._arch_in_images(images, "arm64")
    assert not base_image._arch_in_images(images, "ppc64le")
    assert not base_image._arch_in_images("not-a-list", "amd64")

    tags = [
        {"name": 5, "images": [{"architecture": "amd64"}]},
        {"name": "12.4.1-cudnn-devel-ubuntu24.04", "images": [{"architecture": "amd64"}]},
        {"name": "12.6.0-cudnn-devel-ubuntu24.04", "images": [{"architecture": "arm64"}]},
        {"name": "not-matching", "images": [{"architecture": "amd64"}]},
    ]
    monkeypatch.setattr(base_image, "_iter_cuda_tags", lambda: tags)
    assert (
        base_image.resolve_cuda_base_image("amd64")
        == "nvidia/cuda:12.4.1-cudnn-devel-ubuntu24.04"
    )
    assert (
        base_image.resolve_cuda_base_image("arm64")
        == "nvidia/cuda:12.6.0-cudnn-devel-ubuntu24.04"
    )


def test_resolve_cuda_raises_without_compatible_tag(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(base_image, "_iter_cuda_tags", lambda: [])
    with pytest.raises(RuntimeError, match="no nvidia/cuda"):
        base_image.resolve_cuda_base_image("amd64")


def test_compute_build_args_cpu_and_cuda_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_version_resolvers(monkeypatch)
    monkeypatch.setattr(base_image, "resolve_cuda_base_image", lambda arch: f"cuda:{arch}")

    cpu = base_image.compute_build_args(Flavor.CPU, "arm64")
    cuda = base_image.compute_build_args(Flavor.CUDA, "arm64")

    assert cpu.base_image == "ubuntu:24.04"
    assert cpu.go_download_url.endswith("linux-arm64.tar.gz")
    assert cpu.node_download_url.endswith("linux-arm64.tar.xz")
    assert cpu.purescript_download_url.endswith("linux-arm64.tar.gz")
    assert cpu.ghcup_download_url.endswith("aarch64-linux-ghcup")
    assert cuda.base_image == "cuda:arm64"


def test_compute_build_args_rejects_unknown_arch() -> None:
    with pytest.raises(RuntimeError, match="unsupported arch"):
        base_image.compute_build_args(Flavor.CPU, "s390x")


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
        "amd64",
        context=Path("/repo"),
        budget=budget,
    )
    assert spec.memory == "6144m"
    assert spec.memory_swap == "6144m"
    assert spec.cpus == "3"
    assert args.cabal_build_jobs == "3"
    assert spec.build_args["CABAL_BUILD_JOBS"] == "3"


def test_build_spec_for_is_native_and_unbounded_without_budget(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_version_resolvers(monkeypatch)
    spec, args = base_image.build_spec_for(
        Flavor.CPU,
        "amd64",
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
    assert spec.memory is None
    assert spec.memory_swap is None
    assert spec.cpus is None

    overridden = base_image.with_base_override(args, "override:base")
    assert overridden.base_image == "override:base"
    assert args.base_image == "ubuntu:24.04"


def test_build_spec_accepts_pre_resolved_args(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_version_resolvers(monkeypatch)
    args = base_image.compute_build_args(Flavor.CPU, "amd64")
    spec, resolved = base_image.build_spec_for(
        Flavor.CPU,
        "amd64",
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
        "arm64",
        context=context,
        pulled_reference=digest,
    )
    assert spec.dockerfile == context / "demo/docker/Dockerfile"
    assert spec.context == context
    assert spec.tags == ("hostbootstrap-base-compatibility:cpu-arm64",)
    assert spec.build_args == {"BASE_IMAGE": digest}
    assert spec.pull is True
    assert spec.no_cache is True
