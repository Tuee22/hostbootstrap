"""Single-project and opportunistic warm-store policy tests."""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BASE_DOCKERFILE = REPO_ROOT / "docker" / "basecontainer.Dockerfile"
DEMO_DOCKERFILE = REPO_ROOT / "demo" / "docker" / "Dockerfile"
DEMO_PROJECT = REPO_ROOT / "demo" / "cabal.project"
WARM_PROJECT = REPO_ROOT / "core" / "warm-deps" / "cabal.project"
WARM_CONFIG = REPO_ROOT / "core" / "warm-deps" / "warm-store.config"


def test_consumer_uses_one_host_compatible_project() -> None:
    project = DEMO_PROJECT.read_text(encoding="utf-8")
    dockerfile = DEMO_DOCKERFILE.read_text(encoding="utf-8")

    assert "hostbootstrap-demo.cabal" in project
    assert "../core/hostbootstrap-core/hostbootstrap-core.cabal" in project
    assert "/opt/basecontainer/" not in project
    assert "import:" not in project
    assert "container.cabal.project" not in dockerfile
    assert "RUN cp " not in dockerfile
    assert not (REPO_ROOT / "demo" / "docker" / "container.cabal.project").exists()


def test_warm_store_has_one_project_and_no_freeze_projection() -> None:
    project = WARM_PROJECT.read_text(encoding="utf-8")
    config = WARM_CONFIG.read_text(encoding="utf-8")
    dockerfile = BASE_DOCKERFILE.read_text(encoding="utf-8")

    assert "core/" in project
    assert "daemon/" in project
    assert "import: warm-store.config" in project
    assert "shared: True" in config
    assert "optimization: 2" in config
    assert "with-compiler:" not in config
    assert "index-state:" not in config
    assert "cabal freeze" not in dockerfile
    assert "verify_store.py" not in dockerfile
    assert not (REPO_ROOT / "core" / "warm-deps" / "core.project").exists()
    assert not (REPO_ROOT / "core" / "warm-deps" / "daemon.project").exists()


def test_container_builds_allow_online_cache_misses() -> None:
    base = BASE_DOCKERFILE.read_text(encoding="utf-8")
    demo = DEMO_DOCKERFILE.read_text(encoding="utf-8")

    assert "cabal update" in base
    assert "cabal build all" in base
    assert "--offline" not in base
    assert "--offline" not in demo
    assert "cabal build" in demo


def test_reproducibility_only_artifacts_are_absent() -> None:
    for path in (
        REPO_ROOT / "docker" / "base-inputs.json",
        REPO_ROOT / "docker" / "base-validation.Dockerfile",
        REPO_ROOT / "core" / "warm-deps" / "verify_store.py",
        REPO_ROOT / "templates" / "cabal",
    ):
        assert not path.exists()
