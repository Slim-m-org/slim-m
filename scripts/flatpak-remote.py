#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Turn the release's flatpak-builder repo into a GPG-signed flatpak remote.

`build SRC_REPO SITE BASE_URL` copies the app and its locale refs into a
fresh archive repo at SITE/repo, signing every commit and the summary with
FLATPAK_GPG_KEY, writes the .flatpakrepo, .flatpakref and public key beside
it, then adds the result as a remote in a throwaway installation and lists
it, so a bad key fails here rather than on a user's machine.
Without FLATPAK_GPG_KEY it refuses: an unsigned remote is never published.
See docs/decisions/0025-update-strategy.md, phase 3.
"""
import argparse
import base64
import os
import subprocess
import sys
import tempfile
from pathlib import Path

APP_ID = "top.npcserver.slimm"
REMOTE_NAME = "slim-m"
TITLE = "slim-m"
FLATHUB_REPO = "https://dl.flathub.org/repo/flathub.flatpakrepo"
PUBLIC_KEY_FILE = "slim-m.gpg"
SITE_SIZE_LIMIT = 900 * 1024 * 1024


class RemoteError(Exception):
    pass


def refs_to_publish(branches: list[str], app_id: str = APP_ID) -> list[str]:
    """The app ref and its Locale extension; never Debug, never anything else."""
    keep = []
    for ref in branches:
        parts = ref.split("/")
        if len(parts) != 4:
            continue
        kind, ref_id = parts[0], parts[1]
        if (kind, ref_id) in (("app", app_id), ("runtime", f"{app_id}.Locale")):
            keep.append(ref)
    apps = [r for r in keep if r.startswith("app/")]
    if len(apps) != 1:
        raise RemoteError(f"expected exactly one app/{app_id} ref, found {apps or 'none'}")
    return sorted(keep)


def app_branch(refs: list[str]) -> str:
    return next(r for r in refs if r.startswith("app/")).split("/")[3]


def repo_url(base_url: str) -> str:
    if not base_url.startswith("https://"):
        raise RemoteError(f"the remote must be served over https, got {base_url!r}")
    return base_url.rstrip("/") + "/repo/"


def flatpakrepo_text(url: str, key_b64: str) -> str:
    return "\n".join([
        "[Flatpak Repo]",
        f"Title={TITLE}",
        f"Url={url}",
        "Homepage=https://github.com/Slim-m-org/slim-m",
        f"GPGKey={key_b64}",
        "",
    ])


def flatpakref_text(url: str, key_b64: str, branch: str) -> str:
    return "\n".join([
        "[Flatpak Ref]",
        f"Name={APP_ID}",
        f"Branch={branch}",
        f"Title={TITLE}",
        f"Url={url}",
        f"SuggestRemoteName={REMOTE_NAME}",
        f"RuntimeRepo={FLATHUB_REPO}",
        "IsRuntime=false",
        f"GPGKey={key_b64}",
        "",
    ])


def parse_branches(output: str) -> list[str]:
    return [line.split()[0] for line in output.splitlines() if line.strip()]


def _run(*args: str, env: dict | None = None) -> str:
    result = subprocess.run(args, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise RemoteError(f"{args[0]} {args[1]} failed: {result.stderr.strip()}")
    return result.stdout


def _import_key(key: str, home: Path) -> str:
    home.mkdir(mode=0o700)
    env = {**os.environ, "GNUPGHOME": str(home)}
    subprocess.run(["gpg", "--batch", "--import"], input=key, text=True,
                   capture_output=True, env=env, check=True)
    listing = _run("gpg", "--batch", "--with-colons", "--list-secret-keys", env=env)
    fingerprints = [line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:")]
    if not fingerprints:
        raise RemoteError("FLATPAK_GPG_KEY holds no secret key")
    return fingerprints[0]


def _export_public(fingerprint: str, home: Path) -> bytes:
    env = {**os.environ, "GNUPGHOME": str(home)}
    result = subprocess.run(["gpg", "--batch", "--export", fingerprint],
                            capture_output=True, env=env, check=True)
    if not result.stdout:
        raise RemoteError("could not export the public key")
    return result.stdout


def _self_check(site: Path, branch: str, scratch: Path) -> None:
    env = {**os.environ, "FLATPAK_USER_DIR": str(scratch / "installation"),
           "HOME": str(scratch / "home")}
    (scratch / "home").mkdir()
    _run("flatpak", "--user", "remote-add", f"--gpg-import={site / PUBLIC_KEY_FILE}",
         "check", (site / "repo").as_uri(), env=env)
    listed = _run("flatpak", "--user", "remote-ls", "--columns=application,branch", "check", env=env)
    if f"{APP_ID}\t{branch}" not in listed.splitlines():
        raise RemoteError(f"the signed remote does not list {APP_ID}//{branch}: {listed!r}")


def _site_size(site: Path) -> int:
    return sum(p.stat().st_size for p in site.rglob("*") if p.is_file())


def build(src_repo: Path, site: Path, base_url: str) -> None:
    key = os.environ.get("FLATPAK_GPG_KEY", "")
    if not key.strip():
        raise RemoteError("FLATPAK_GPG_KEY is not set; refusing to publish an unsigned remote")
    url = repo_url(base_url)
    refs = refs_to_publish(parse_branches(_run("flatpak", "repo", "--branches", str(src_repo))))
    branch = app_branch(refs)
    repo = site / "repo"
    with tempfile.TemporaryDirectory() as tmp:
        scratch = Path(tmp)
        home = scratch / "gnupg"
        fingerprint = _import_key(key, home)
        sign = [f"--gpg-sign={fingerprint}", f"--gpg-homedir={home}"]
        _run("ostree", "init", "--mode=archive", f"--repo={repo}")
        for ref in refs:
            _run("flatpak", "build-commit-from", f"--src-repo={src_repo}", *sign,
                 "--no-update-summary", str(repo), ref)
        _run("flatpak", "build-update-repo", *sign, "--generate-static-deltas",
             f"--title={TITLE}", str(repo))
        public = _export_public(fingerprint, home)
        (site / PUBLIC_KEY_FILE).write_bytes(public)
        key_b64 = base64.b64encode(public).decode()
        (site / f"{REMOTE_NAME}.flatpakrepo").write_text(flatpakrepo_text(url, key_b64))
        (site / f"{APP_ID}.flatpakref").write_text(flatpakref_text(url, key_b64, branch))
        (site / ".nojekyll").write_text("")
        _self_check(site, branch, scratch)
    size = _site_size(site)
    if size > SITE_SIZE_LIMIT:
        raise RemoteError(f"the site is {size} bytes, over GitHub Pages' limit")
    print(f"signed remote for {', '.join(refs)} at {url} ({size} bytes)")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build")
    b.add_argument("src_repo", type=Path)
    b.add_argument("site", type=Path)
    b.add_argument("base_url")
    args = parser.parse_args(argv)
    try:
        args.site.mkdir(parents=True, exist_ok=True)
        if any(args.site.iterdir()):
            raise RemoteError(f"{args.site} must be empty")
        build(args.src_repo, args.site, args.base_url)
    except (RemoteError, subprocess.CalledProcessError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
