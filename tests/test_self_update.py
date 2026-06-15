"""Unit tests for the explicit pipx self-update surface."""

from __future__ import annotations

import json
import subprocess

import pytest

from hostbootstrap import self_update


def test_direct_vcs_spec_and_pipx_update_args() -> None:
    assert (
        self_update.direct_vcs_spec()
        == "hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@main"
    )
    assert (
        self_update.direct_vcs_spec("feature")
        == "hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@feature"
    )
    assert self_update.pipx_update_args() == (
        "pipx",
        "install",
        "--force",
        "--pip-args",
        "--force-reinstall",
        "hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@main",
    )
    assert self_update.pipx_update_args(spec="/work/hostbootstrap") == (
        "pipx",
        "install",
        "--force",
        "--pip-args",
        "--force-reinstall",
        "/work/hostbootstrap",
    )


def test_run_update_invokes_pipx(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: list[list[str]] = []

    def _run(cmd: list[str], *, check: bool) -> subprocess.CompletedProcess[str]:
        captured.append(cmd)
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(self_update.subprocess, "run", _run)

    assert self_update.run_update(ref="feature") == (
        "hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@feature"
    )
    assert captured == [list(self_update.pipx_update_args(ref="feature"))]


def test_run_update_wraps_missing_pipx(monkeypatch: pytest.MonkeyPatch) -> None:
    def _run(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        raise FileNotFoundError(2, "missing", "pipx")

    monkeypatch.setattr(self_update.subprocess, "run", _run)
    with pytest.raises(self_update.SelfUpdateError, match="pipx"):
        self_update.run_update()


def test_run_update_wraps_nonzero(monkeypatch: pytest.MonkeyPatch) -> None:
    def _run(cmd: list[str], *, check: bool) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(cmd, 7)

    monkeypatch.setattr(self_update.subprocess, "run", _run)
    with pytest.raises(self_update.SelfUpdateError, match="exit 7"):
        self_update.run_update()


def _direct_url(
    *,
    url: str = self_update.DEFAULT_REPO_URL,
    vcs: str = "git",
    commit_id: str = "a" * 40,
    requested_revision: str | object | None = "main",
) -> str:
    vcs_info: dict[str, object] = {"vcs": vcs, "commit_id": commit_id}
    if requested_revision is not None:
        vcs_info["requested_revision"] = requested_revision
    return json.dumps({"url": url, "vcs_info": vcs_info})


def test_parse_direct_url_git_source() -> None:
    assert self_update.parse_direct_url(_direct_url()) == self_update.InstalledVCS(
        url=self_update.DEFAULT_REPO_URL,
        commit_id="a" * 40,
        requested_revision="main",
    )
    assert self_update.parse_direct_url(None) is None
    assert self_update.parse_direct_url(json.dumps({"url": "/local", "dir_info": {}})) is None
    assert self_update.parse_direct_url(_direct_url(vcs="hg")) is None


@pytest.mark.parametrize(
    "text",
    [
        "[]",
        json.dumps({"url": self_update.DEFAULT_REPO_URL, "vcs_info": []}),
        json.dumps({"url": self_update.DEFAULT_REPO_URL, "vcs_info": {"vcs": "git"}}),
        _direct_url(requested_revision=123),
    ],
)
def test_parse_direct_url_rejects_malformed(text: str) -> None:
    with pytest.raises(self_update.SelfUpdateError):
        self_update.parse_direct_url(text)


def test_installed_vcs_source_reads_distribution(monkeypatch: pytest.MonkeyPatch) -> None:
    class _Distribution:
        def read_text(self, name: str) -> str | None:
            assert name == "direct_url.json"
            return _direct_url(commit_id="b" * 40)

    monkeypatch.setattr(
        self_update.importlib.metadata,
        "distribution",
        lambda _package: _Distribution(),
    )

    assert self_update.installed_vcs_source() == self_update.InstalledVCS(
        url=self_update.DEFAULT_REPO_URL,
        commit_id="b" * 40,
        requested_revision="main",
    )


def test_installed_vcs_source_wraps_missing_distribution(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _missing(_package: str) -> object:
        raise self_update.importlib.metadata.PackageNotFoundError("hostbootstrap")

    monkeypatch.setattr(self_update.importlib.metadata, "distribution", _missing)
    with pytest.raises(self_update.SelfUpdateError, match="not installed"):
        self_update.installed_vcs_source()


def test_parse_ls_remote_skips_peeled_tag_line() -> None:
    assert self_update.parse_ls_remote(
        "d" * 40 + " refs/tags/v1^{}\n" + "c" * 40 + " refs/heads/main\n"
    ) == "c" * 40
    with pytest.raises(self_update.SelfUpdateError, match="remote ref"):
        self_update.parse_ls_remote("")


def test_remote_commit_invokes_git(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: list[list[str]] = []

    def _run(
        cmd: list[str],
        *,
        capture_output: bool,
        text: bool,
        check: bool,
    ) -> subprocess.CompletedProcess[str]:
        assert capture_output is True
        assert text is True
        assert check is False
        captured.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, stdout="e" * 40 + " refs/heads/main\n")

    monkeypatch.setattr(self_update.subprocess, "run", _run)

    assert self_update.remote_commit(ref="main") == "e" * 40
    assert captured == [["git", "ls-remote", self_update.DEFAULT_REPO_URL, "main"]]


def test_remote_commit_wraps_missing_git(monkeypatch: pytest.MonkeyPatch) -> None:
    def _run(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        raise FileNotFoundError(2, "missing", "git")

    monkeypatch.setattr(self_update.subprocess, "run", _run)
    with pytest.raises(self_update.SelfUpdateError, match="git"):
        self_update.remote_commit()


def test_remote_commit_wraps_nonzero(monkeypatch: pytest.MonkeyPatch) -> None:
    def _run(
        cmd: list[str],
        *,
        capture_output: bool,
        text: bool,
        check: bool,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(cmd, 2, stdout="", stderr="offline")

    monkeypatch.setattr(self_update.subprocess, "run", _run)
    with pytest.raises(self_update.SelfUpdateError, match="offline"):
        self_update.remote_commit()


def test_check_status_compares_installed_to_remote(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        self_update,
        "installed_vcs_source",
        lambda: self_update.InstalledVCS(
            url=self_update.DEFAULT_REPO_URL,
            commit_id="f" * 40,
            requested_revision="main",
        ),
    )
    monkeypatch.setattr(self_update, "remote_commit", lambda *, ref: "f" * 40)

    assert self_update.check_status().up_to_date is True


def test_check_status_reports_unknown_for_local_install(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(self_update, "installed_vcs_source", lambda: None)

    with pytest.raises(self_update.SelfUpdateError, match="freshness is unknown"):
        self_update.check_status()


def test_check_status_reports_unknown_for_other_repo(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        self_update,
        "installed_vcs_source",
        lambda: self_update.InstalledVCS(
            url="https://example.invalid/other.git",
            commit_id="f" * 40,
            requested_revision="main",
        ),
    )

    with pytest.raises(self_update.SelfUpdateError, match="canonical"):
        self_update.check_status()
