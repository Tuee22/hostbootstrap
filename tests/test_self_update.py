"""Unit tests for the explicit pipx self-update surface."""

from __future__ import annotations

import json
from collections.abc import Sequence

import pytest

from hostbootstrap import process, self_update


def _ran(
    args: Sequence[str],
    *,
    returncode: int = 0,
    stdout: str = "",
    stderr: str = "",
) -> process.CommandResult:
    return process.CommandResult(tuple(args), returncode, stdout, stderr)


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
        "--pip-args=--force-reinstall",
        "hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@main",
    )
    assert self_update.pipx_update_args(spec="/work/hostbootstrap") == (
        "pipx",
        "install",
        "--force",
        "--pip-args=--force-reinstall",
        "/work/hostbootstrap",
    )


def test_run_update_invokes_pipx(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: list[list[str]] = []

    def _probe(cmd: Sequence[str], *, stdio: process.Stdio) -> process.CommandOutcome:
        assert stdio is process.Stdio.INHERIT
        captured.append(list(cmd))
        return _ran(cmd)

    monkeypatch.setattr(self_update.process, "probe", _probe)

    assert self_update.run_update(ref="feature") == (
        "hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@feature"
    )
    assert captured == [list(self_update.pipx_update_args(ref="feature"))]


def test_run_update_wraps_missing_pipx(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        self_update.process,
        "probe",
        lambda cmd, **_k: process.CommandUnavailable(tuple(cmd), "No such file: pipx"),
    )
    with pytest.raises(self_update.SelfUpdateError, match="pipx"):
        self_update.run_update()


def test_run_update_wraps_nonzero(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(self_update.process, "probe", lambda cmd, **_k: _ran(cmd, returncode=7))
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
    "text, match",
    [
        ("{not json", "is malformed"),
        ("[]", "is malformed"),
        (
            json.dumps({"url": self_update.DEFAULT_REPO_URL, "vcs_info": []}),
            "malformed VCS metadata",
        ),
        (
            json.dumps({"url": self_update.DEFAULT_REPO_URL, "vcs_info": {"vcs": "git"}}),
            "missing git source metadata",
        ),
        (_direct_url(requested_revision=123), "malformed requested revision"),
    ],
)
def test_parse_direct_url_rejects_malformed(text: str, match: str) -> None:
    with pytest.raises(self_update.SelfUpdateError, match=match):
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


def test_parse_ls_remote_prefers_peeled_annotated_tag_commit() -> None:
    # An annotated tag advertises the tag object AND its peeled commit (the
    # `^{}` line); pip records the peeled commit, so parse_ls_remote must return
    # it rather than the tag-object SHA.
    assert (
        self_update.parse_ls_remote(
            "a" * 40 + " refs/tags/v1\n" + "b" * 40 + " refs/tags/v1^{}\n", ref="v1"
        )
        == "b" * 40
    )
    # A branch head (or lightweight tag) advertises no `^{}` line and already
    # names a commit, so fall back to it.
    assert self_update.parse_ls_remote("c" * 40 + " refs/heads/main\n") == "c" * 40
    with pytest.raises(self_update.SelfUpdateError, match="remote ref"):
        self_update.parse_ls_remote("")


def test_remote_commit_invokes_git(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: list[list[str]] = []

    def _probe(cmd: Sequence[str]) -> process.CommandOutcome:
        captured.append(list(cmd))
        return _ran(cmd, stdout="e" * 40 + " refs/heads/main\n")

    monkeypatch.setattr(self_update.process, "probe", _probe)

    assert self_update.remote_commit(ref="main") == "e" * 40
    assert captured == [
        [
            "git",
            "ls-remote",
            self_update.DEFAULT_REPO_URL,
            "refs/heads/main",
            "refs/tags/main",
            "refs/tags/main^{}",
        ]
    ]


def test_remote_commit_wraps_missing_git(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        self_update.process,
        "probe",
        lambda cmd: process.CommandUnavailable(tuple(cmd), "No such file: git"),
    )
    with pytest.raises(self_update.SelfUpdateError, match="git"):
        self_update.remote_commit()


def test_remote_commit_wraps_nonzero(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        self_update.process,
        "probe",
        lambda cmd: _ran(cmd, returncode=2, stderr="offline"),
    )
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
    refs: list[str] = []

    def _remote(*, ref: str) -> str:
        refs.append(ref)
        return "a" * 40

    monkeypatch.setattr(self_update, "remote_commit", _remote)

    status = self_update.check_status()
    assert status.up_to_date is False
    assert status.remote_commit == "a" * 40
    assert status.compared_ref == "main"
    assert refs == ["main"]


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


@pytest.mark.parametrize(
    "installed_ref, explicit_ref, expected",
    [("v1.2", None, "v1.2"), (None, None, "main"), ("v1.2", "feature", "feature")],
)
def test_check_status_selects_the_installed_or_explicit_ref(
    monkeypatch: pytest.MonkeyPatch,
    installed_ref: str | None,
    explicit_ref: str | None,
    expected: str,
) -> None:
    monkeypatch.setattr(
        self_update,
        "installed_vcs_source",
        lambda: self_update.InstalledVCS(self_update.DEFAULT_REPO_URL, "a" * 40, installed_ref),
    )
    refs: list[str] = []

    def _remote(*, ref: str) -> str:
        refs.append(ref)
        return "a" * 40

    monkeypatch.setattr(self_update, "remote_commit", _remote)
    status = self_update.check_status(ref=explicit_ref)
    assert status.up_to_date is True
    assert status.compared_ref == expected
    assert refs == [expected]


def test_parse_ls_remote_selects_exact_branch_before_tag() -> None:
    output = "\n".join(
        (
            "backup refs/heads/backup/main",
            "branch refs/heads/main",
            "tag refs/tags/main",
            "peeled refs/tags/main^{}",
            "malformed",
        )
    )
    assert self_update.parse_ls_remote(output) == "branch"
    assert self_update.parse_ls_remote("lightweight refs/tags/v1", ref="v1") == "lightweight"
    with pytest.raises(self_update.SelfUpdateError, match="remote ref"):
        self_update.parse_ls_remote("backup refs/heads/backup/main")
    with pytest.raises(self_update.SelfUpdateError, match="ambiguously"):
        self_update.parse_ls_remote("a refs/heads/main\nb refs/heads/main")


@pytest.mark.parametrize("operation", [self_update.remote_commit, self_update.run_update])
def test_self_update_renders_timeout(monkeypatch: pytest.MonkeyPatch, operation: object) -> None:
    monkeypatch.setattr(
        process, "probe", lambda cmd, **_kw: process.CommandTimedOut(tuple(cmd), 0.1)
    )
    with pytest.raises(self_update.SelfUpdateError, match="timed out after 0.1s"):
        operation()  # type: ignore[operator]


@pytest.mark.parametrize(
    "stdout, stderr, suffix", [("remote output", "", ": remote output"), ("", "", ".")]
)
def test_remote_failure_selects_stdout_or_empty_detail(
    monkeypatch: pytest.MonkeyPatch, stdout: str, stderr: str, suffix: str
) -> None:
    monkeypatch.setattr(
        process, "probe", lambda cmd: _ran(cmd, returncode=2, stdout=stdout, stderr=stderr)
    )
    with pytest.raises(self_update.SelfUpdateError) as caught:
        self_update.remote_commit()
    assert str(caught.value).endswith(suffix)
