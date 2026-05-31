"""Provision and invoke a native ``dhall-to-json`` binary.

hostbootstrap installs as pure Python (``pip install git+…``) and parses each
project's ``hostbootstrap.dhall`` by shelling out to the official, statically
linked ``dhall-json`` release binary. We do **not** depend on the ``dhall`` PyPI
wheel: it ships no CPython 3.12 wheel, so it would compile from a Rust sdist on
the user's host.

hostbootstrap **always** uses its own pinned binary and never a ``dhall-to-json``
found on ``PATH`` — so the host toolchain cannot affect how a config is parsed.

Resolution order (``ensure``):

1. a previously downloaded binary cached under ``~/.cache/hostbootstrap/`` for
   the pinned version;
2. otherwise download the pinned release asset for the host platform into that
   cache and verify it against a pinned SHA-256.

Dhall's own type-checker enforces the schema's union/illegal-state guarantees
while rendering to JSON, so by the time we ``json.loads`` the output the shape
is already valid; :mod:`hostbootstrap.spec` only runs the residual cross-field
checks Dhall cannot express.
"""

from __future__ import annotations

import hashlib
import importlib.resources
import io
import json
import os
import platform
import subprocess
import tarfile
from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path
from typing import Final

import httpx

_RELEASE_TAG: Final[str] = "1.42.2"
_DHALL_JSON_VERSION: Final[str] = "1.7.12"
_EXE: Final[str] = "dhall-to-json"


class DhallToolError(RuntimeError):
    """Raised when ``dhall-to-json`` cannot be provisioned or fails to run."""


@dataclass(frozen=True)
class _Asset:
    filename: str
    sha256: str


# Pinned `dhall-json` release assets (github.com/dhall-lang/dhall-haskell), keyed
# by (system, normalized-arch). SHA-256s verified at pin time; bump together with
# `_RELEASE_TAG` / `_DHALL_JSON_VERSION`.
_ASSETS: Final[dict[tuple[str, str], _Asset]] = {
    ("Darwin", "arm64"): _Asset(
        f"dhall-json-{_DHALL_JSON_VERSION}-aarch64-darwin.tar.bz2",
        "761048afa225dc9978b9fb742cc9d4feee104f2656aefe37b6a6f157862b77dd",
    ),
    ("Darwin", "amd64"): _Asset(
        f"dhall-json-{_DHALL_JSON_VERSION}-x86_64-darwin.tar.bz2",
        "f6b0bc2f120e5ade2c4c789555237cb4a0b4611fb2455f2a16a3bde4a441e589",
    ),
    ("Linux", "amd64"): _Asset(
        f"dhall-json-{_DHALL_JSON_VERSION}-x86_64-linux.tar.bz2",
        "acbada5e29ecc9b6a723c3f390beb76b9db26df81546d1f472415a2f387bc457",
    ),
}

_ARCH_ALIASES: Final[dict[str, str]] = {
    "x86_64": "amd64",
    "amd64": "amd64",
    "aarch64": "arm64",
    "arm64": "arm64",
}

_HTTP_TIMEOUT: Final[httpx.Timeout] = httpx.Timeout(120.0)


def _platform_key() -> tuple[str, str]:
    system = platform.system()
    raw_arch = platform.machine().lower()
    arch = _ARCH_ALIASES.get(raw_arch, raw_arch)
    return system, arch


def _cache_dir() -> Path:
    root = os.environ.get("XDG_CACHE_HOME")
    base = Path(root) if root else Path.home() / ".cache"
    return base / "hostbootstrap" / "dhall-json" / _DHALL_JSON_VERSION


def _download_and_extract(asset: _Asset, dest: Path) -> None:
    url = (
        "https://github.com/dhall-lang/dhall-haskell/releases/download/"
        f"{_RELEASE_TAG}/{asset.filename}"
    )
    try:
        response = httpx.get(url, timeout=_HTTP_TIMEOUT, follow_redirects=True)
        response.raise_for_status()
    except httpx.HTTPError as exc:
        raise DhallToolError(f"could not download {url}: {exc}") from exc

    payload = response.content
    digest = hashlib.sha256(payload).hexdigest()
    if digest != asset.sha256:
        raise DhallToolError(
            f"checksum mismatch for {asset.filename}: " f"expected {asset.sha256}, got {digest}"
        )

    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:bz2") as tar:
        member = next(
            (m for m in tar.getmembers() if m.isfile() and m.name.endswith(f"bin/{_EXE}")),
            None,
        )
        if member is None:
            raise DhallToolError(f"{asset.filename} does not contain bin/{_EXE}")
        extracted = tar.extractfile(member)
        if extracted is None:
            raise DhallToolError(f"could not read bin/{_EXE} from {asset.filename}")
        binary = extracted.read()

    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(".partial")
    tmp.write_bytes(binary)
    tmp.chmod(0o755)
    tmp.replace(dest)


def ensure() -> Path:
    """Return a path to hostbootstrap's own pinned ``dhall-to-json``.

    Always resolves to the cached/downloaded pinned binary; a ``dhall-to-json``
    on ``PATH`` is deliberately ignored so the host toolchain cannot influence
    config parsing.
    """
    target = _cache_dir() / _EXE
    if target.is_file() and os.access(target, os.X_OK):
        return target

    key = _platform_key()
    asset = _ASSETS.get(key)
    if asset is None:
        system, arch = key
        raise DhallToolError(
            f"no prebuilt dhall-to-json for {system}/{arch}; hostbootstrap cannot "
            "provision one for this platform (build `dhall-json` from source for it)."
        )
    _download_and_extract(asset, target)
    return target


def _package_path(stack: ExitStack) -> Path:
    """Return an on-disk path to the schema ``package.dhall`` shipped in the wheel.

    ``as_file`` materializes the resource (extracting a zipped wheel to a temp
    file, or returning the real file for a normal/editable install) for the
    lifetime of *stack* — required because the ``env:`` import resolves to a
    filesystem path, not in-memory bytes.
    """
    resource = importlib.resources.files("hostbootstrap").joinpath("dhall/package.dhall")
    return stack.enter_context(importlib.resources.as_file(resource))


def to_json(dhall_path: Path) -> object:
    """Render *dhall_path* to a JSON value (type-checked by ``dhall-to-json``).

    The schema is injected as ``H`` so a project's ``hostbootstrap.dhall`` needs
    no import line — it opens straight at ``H.config { … }``. We wrap the file
    body in ``let H = env:HOSTBOOTSTRAP_PACKAGE in ( … )`` and feed it on stdin
    (cwd = the project dir, so any relative imports still resolve). The prelude is
    kept on one line so body line numbers are preserved in dhall diagnostics, and
    an explicit ``let H = …`` in the project file harmlessly shadows the binding.
    """
    binary = ensure()
    body = dhall_path.read_text(encoding="utf-8")
    wrapped = f"let H = env:HOSTBOOTSTRAP_PACKAGE in ( {body} )"
    with ExitStack() as stack:
        package_path = _package_path(stack)
        env = dict(os.environ)
        env.setdefault("HOSTBOOTSTRAP_PACKAGE", str(package_path))
        try:
            result = subprocess.run(
                [str(binary)],
                input=wrapped,
                capture_output=True,
                text=True,
                check=False,
                env=env,
                cwd=str(dhall_path.parent),
            )
        except OSError as exc:
            raise DhallToolError(f"could not exec {binary}: {exc}") from exc
    if result.returncode != 0:
        raise DhallToolError(result.stderr.strip() or "dhall-to-json failed")
    data: object = json.loads(result.stdout)
    return data
