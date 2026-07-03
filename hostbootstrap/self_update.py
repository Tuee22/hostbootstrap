"""Self-update support for the pipx-installed Python bootstrapper."""

from __future__ import annotations

import importlib.metadata
import json
import subprocess
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Final, cast

PACKAGE_NAME: Final[str] = "hostbootstrap"
DEFAULT_REPO_URL: Final[str] = "https://github.com/Tuee22/hostbootstrap.git"
DEFAULT_REF: Final[str] = "main"


class SelfUpdateError(RuntimeError):
    """Raised when an explicit self-update or freshness check cannot complete."""


@dataclass(frozen=True)
class InstalledVCS:
    url: str
    commit_id: str
    requested_revision: str | None


@dataclass(frozen=True)
class CheckStatus:
    installed_commit: str
    remote_commit: str
    requested_revision: str | None

    @property
    def up_to_date(self) -> bool:
        return self.installed_commit == self.remote_commit


def direct_vcs_spec(ref: str = DEFAULT_REF) -> str:
    return f"{PACKAGE_NAME} @ git+{DEFAULT_REPO_URL}@{ref}"


def pipx_update_args(*, ref: str = DEFAULT_REF, spec: str | None = None) -> tuple[str, ...]:
    install_spec = spec if spec is not None else direct_vcs_spec(ref)
    return (
        "pipx",
        "install",
        "--force",
        # The value must be glued onto the flag with `=`. pipx parses its CLI with
        # argparse, which refuses to consume a following token that looks like an
        # option (a leading `-`) as an option's value, so the split
        # `--pip-args`, `--force-reinstall` form fails with "expected one argument".
        "--pip-args=--force-reinstall",
        install_spec,
    )


def run_update(*, ref: str = DEFAULT_REF, spec: str | None = None) -> str:
    install_spec = spec if spec is not None else direct_vcs_spec(ref)
    argv = pipx_update_args(ref=ref, spec=spec)
    try:
        completed = subprocess.run(list(argv), check=False)
    except FileNotFoundError as exc:
        raise SelfUpdateError("`pipx` not found in PATH; install pipx and retry.") from exc
    if completed.returncode != 0:
        raise SelfUpdateError(f"`pipx install --force` failed (exit {completed.returncode}).")
    return install_spec


def parse_direct_url(text: str | None) -> InstalledVCS | None:
    if text is None:
        return None
    data_object: object = json.loads(text)
    if not isinstance(data_object, dict):
        raise SelfUpdateError("installed direct_url.json is malformed.")
    data = cast(Mapping[str, object], data_object)
    vcs_object = data.get("vcs_info")
    if vcs_object is None:
        return None
    if not isinstance(vcs_object, dict):
        raise SelfUpdateError("installed direct_url.json has malformed VCS metadata.")
    vcs_info = cast(Mapping[str, object], vcs_object)
    vcs = vcs_info.get("vcs")
    commit_id = vcs_info.get("commit_id")
    requested_revision = vcs_info.get("requested_revision")
    url = data.get("url")
    if vcs != "git":
        return None
    if not isinstance(url, str) or not isinstance(commit_id, str):
        raise SelfUpdateError("installed direct_url.json is missing git source metadata.")
    if requested_revision is not None and not isinstance(requested_revision, str):
        raise SelfUpdateError("installed direct_url.json has a malformed requested revision.")
    return InstalledVCS(url=url, commit_id=commit_id, requested_revision=requested_revision)


def installed_vcs_source(package: str = PACKAGE_NAME) -> InstalledVCS | None:
    try:
        distribution = importlib.metadata.distribution(package)
    except importlib.metadata.PackageNotFoundError as exc:
        raise SelfUpdateError(f"{package!r} is not installed as a Python distribution.") from exc
    return parse_direct_url(distribution.read_text("direct_url.json"))


def parse_ls_remote(stdout: str) -> str:
    entries = [parts for line in stdout.splitlines() if len(parts := line.split()) >= 2]
    # Prefer the peeled commit of an annotated tag (the ``<ref>^{}`` line) — that is
    # the commit pip records in direct_url.json. A branch head or lightweight tag
    # advertises no ``^{}`` line and already names a commit, so fall back to it.
    for sha, name in ((parts[0], parts[1]) for parts in entries):
        if name.endswith("^{}"):
            return sha
    for parts in entries:
        return parts[0]
    raise SelfUpdateError("remote ref did not resolve to a git commit.")


def remote_commit(*, repo_url: str = DEFAULT_REPO_URL, ref: str = DEFAULT_REF) -> str:
    try:
        completed = subprocess.run(
            # Request the ref and its peeled form so an annotated tag also emits its
            # ``<ref>^{}`` commit line; parse_ls_remote prefers that peeled commit.
            ["git", "ls-remote", repo_url, ref, f"{ref}^{{}}"],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        raise SelfUpdateError("`git` not found in PATH; install git and retry.") from exc
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        suffix = f": {detail}" if detail else "."
        raise SelfUpdateError(f"`git ls-remote` failed (exit {completed.returncode}){suffix}")
    return parse_ls_remote(completed.stdout)


def check_status(*, ref: str = DEFAULT_REF) -> CheckStatus:
    installed = installed_vcs_source()
    if installed is None:
        raise SelfUpdateError(
            "installed hostbootstrap has no direct VCS metadata; freshness is unknown."
        )
    if installed.url.lower() != DEFAULT_REPO_URL.lower():
        raise SelfUpdateError(
            "installed hostbootstrap came from "
            f"{installed.url!r}, not the canonical {DEFAULT_REPO_URL!r}; freshness is unknown."
        )
    return CheckStatus(
        installed_commit=installed.commit_id,
        remote_commit=remote_commit(ref=ref),
        requested_revision=installed.requested_revision,
    )
