#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Build, sign and verify the signed desktop update manifest (decision 0041).

The manifest is one JSON document naming, per platform, the release artifact
URL, its sha256 and its size. An ed25519 signature over the exact manifest
bytes travels beside it. The signing key is a PKCS8 PEM held in the
UPDATE_SIGNING_KEY Actions secret; the app embeds only the raw 32-byte public
key (base64), which `pubkey` prints for the owner's one-time setup.

Stdlib only, with openssl (3.x, ed25519 raw signing) as the one external tool,
since python has no ed25519 in its standard library.

  build   --tag T --dir D --repo R [--require a,b] [--defer-if-missing] --out manifest.json
  sign    --manifest M --sig S            (key in $UPDATE_SIGNING_KEY)
  pubkey                                  (key in $UPDATE_SIGNING_KEY)
  verify  --manifest M --sig S --pubkey B64 [--dir D] [--newer-than V]
"""

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SCHEMA = 1
# Raw ed25519 public key -> SPKI DER: openssl only reads the wrapped form.
SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")
PLATFORMS = {
    "linux-x64": re.compile(r"^slim-m-client-.+-linux-amd64\.tar\.gz$"),
    "windows-x64": re.compile(r"^slim-m-client-.+-windows-x64\.zip$"),
    "macos": re.compile(r"^slim-m-client-.+-macos\.zip$"),
    "android-arm64-v8a": re.compile(r"^slim-m-client-android-arm64-v8a\.apk$"),
    "android-armeabi-v7a": re.compile(r"^slim-m-client-android-armeabi-v7a\.apk$"),
    "android-x86_64": re.compile(r"^slim-m-client-android-x86_64\.apk$"),
    # The one fat apk of releases before the per-ABI split.
    "android": re.compile(r"^slim-m-client-android\.apk$"),
}
# Clients that predate the split look up "android"; it keeps working as the arm64-v8a apk.
ANDROID_ALIAS = ("android", "android-arm64-v8a")
DEFAULT_REQUIRE = "windows-x64,macos,linux-x64"
MANIFEST_NAME = "manifest.json"
SIGNATURE_NAME = "manifest.json.sig"


class ManifestError(Exception):
    pass


class MissingPlatforms(ManifestError):
    pass


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def version_tuple(version: str) -> tuple[int, ...]:
    core = version.split("+", 1)[0].split("-", 1)[0]
    if not re.fullmatch(r"\d+\.\d+\.\d+", core):
        raise ManifestError(f"not a plain X.Y.Z version: {version!r}")
    return tuple(int(part) for part in core.split("."))


def build_manifest(tag: str, directory: Path, repo: str, require: list[str]) -> dict:
    if not tag.startswith("client-v"):
        raise ManifestError(f"tag must look like client-vX.Y.Z, got {tag!r}")
    version = tag.removeprefix("client-v")
    version_tuple(version)
    artifacts = {}
    for path in sorted(directory.iterdir()):
        for platform, pattern in PLATFORMS.items():
            if not pattern.match(path.name):
                continue
            if platform in artifacts:
                raise ManifestError(f"two files match {platform}: {path.name}")
            artifacts[platform] = {
                "url": f"https://github.com/{repo}/releases/download/{tag}/{path.name}",
                "sha256": sha256_of(path),
                "size": path.stat().st_size,
            }
    alias, target = ANDROID_ALIAS
    if alias not in artifacts and target in artifacts:
        artifacts[alias] = dict(artifacts[target])
    missing = [name for name in require if name not in artifacts]
    if missing:
        raise MissingPlatforms(f"required platforms missing from {directory}: {', '.join(missing)}")
    return {"schema": SCHEMA, "version": version, "tag": tag, "artifacts": artifacts}


def canonical(manifest: dict) -> bytes:
    return (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode()


def _openssl(*args: str) -> bytes:
    try:
        done = subprocess.run(["openssl", *args], capture_output=True, check=True)
    except FileNotFoundError as err:
        raise ManifestError("openssl is not installed") from err
    except subprocess.CalledProcessError as err:
        raise ManifestError(f"openssl {args[0]} failed: {err.stderr.decode().strip()}") from err
    return done.stdout


def _private_key_file(directory: str) -> str:
    pem = os.environ.get("UPDATE_SIGNING_KEY", "")
    if not pem.strip():
        raise ManifestError("UPDATE_SIGNING_KEY is empty")
    path = Path(directory) / "key.pem"
    path.touch(mode=0o600)
    path.write_text(pem if pem.endswith("\n") else pem + "\n")
    return str(path)


def _temp_file(directory: str, prefix: str, data: bytes) -> str:
    """Write through a descriptor from mkstemp so no caller-influenced path is opened."""
    fd, name = tempfile.mkstemp(prefix=prefix, dir=directory)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
    return name


def sign_bytes(data: bytes) -> bytes:
    with tempfile.TemporaryDirectory() as tmp:
        key = _private_key_file(tmp)
        payload = _temp_file(tmp, "payload-", data)
        return _openssl("pkeyutl", "-sign", "-rawin", "-inkey", key, "-in", payload)


def public_key_b64() -> str:
    with tempfile.TemporaryDirectory() as tmp:
        der = _openssl("pkey", "-in", _private_key_file(tmp), "-pubout", "-outform", "DER")
    return base64.b64encode(der[-32:]).decode()


def verify_signature(data: bytes, signature: bytes, pubkey_b64: str) -> None:
    raw = base64.b64decode(pubkey_b64, validate=True)
    if len(raw) != 32:
        raise ManifestError("public key must be 32 raw bytes, base64 encoded")
    if len(signature) != 64:
        raise ManifestError("signature must be 64 raw bytes")
    with tempfile.TemporaryDirectory() as tmp:
        pub = _temp_file(tmp, "pub-", SPKI_PREFIX + raw)
        payload = _temp_file(tmp, "payload-", data)
        sig = _temp_file(tmp, "sig-", signature)
        args = ["pkeyutl", "-verify", "-rawin", "-pubin", "-keyform", "DER"]
        try:
            _openssl(*args, "-inkey", pub, "-in", payload, "-sigfile", sig)
        except ManifestError as err:
            raise ManifestError("signature does not match the manifest") from err


def listed(directory: Path, name: str) -> Path | None:
    """Return the entry called `name` from a listing of `directory`, never a path built from `name`."""
    entries = {entry.name: entry for entry in directory.iterdir()}
    return entries.get(name)


def artifact_path(directory: Path, name: str) -> Path | None:
    """A manifest is untrusted input until proven otherwise: only a bare filename listed in the directory is used."""
    if not name or name in (".", "..") or any(c in name for c in ("/", "\\", "\0")) or Path(name).is_absolute():
        raise ManifestError(f"unsafe artifact name in manifest: {name!r}")
    return listed(directory, name)


def check_artifacts(manifest: dict, directory: Path) -> None:
    for platform, entry in manifest["artifacts"].items():
        name = entry["url"].rsplit("/", 1)[-1]
        path = artifact_path(directory, name)
        if path is None or not path.is_file():
            raise ManifestError(f"{platform}: {name} not found in {directory}")
        if path.stat().st_size != entry["size"] or sha256_of(path) != entry["sha256"]:
            raise ManifestError(f"{platform}: {name} does not match the manifest")


def existing_dir(path: Path) -> Path:
    """Resolve the directory from its parent's listing so the value used is a listed entry."""
    resolved = path.resolve()
    if resolved.parent == resolved:
        return resolved
    found = listed(resolved.parent, resolved.name)
    if found is None or not found.is_dir():
        raise ManifestError(f"not a directory: {path}")
    return found


def existing_file(path: Path) -> Path:
    parent = existing_dir(path.parent)
    found = listed(parent, path.name)
    if found is None or not found.is_file():
        raise ManifestError(f"not a regular file: {path}")
    return found


def output_file(path: Path, expected: str) -> Path:
    """Each command writes one fixed file in the working directory; the argument must name exactly that file."""
    if str(path) not in (expected, f"./{expected}"):
        raise ManifestError(f"cannot write to {path}: this command writes {expected} in the working directory")
    target = Path.cwd() / expected
    if target.exists() and not target.is_file():
        raise ManifestError(f"cannot write to {expected}")
    return target


def verify(manifest_path: Path, sig_path: Path, pubkey: str, directory, newer_than) -> dict:
    data = existing_file(manifest_path).read_bytes()
    encoded = existing_file(sig_path).read_text().strip()
    verify_signature(data, base64.b64decode(encoded, validate=True), pubkey)
    manifest = json.loads(data)
    if manifest.get("schema") != SCHEMA:
        raise ManifestError(f"unsupported manifest schema {manifest.get('schema')!r}")
    if newer_than and version_tuple(manifest["version"]) <= version_tuple(newer_than):
        raise ManifestError(f"manifest {manifest['version']} is not newer than {newer_than}")
    if directory:
        check_artifacts(manifest, existing_dir(directory))
    return manifest


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    build = sub.add_parser("build")
    build.add_argument("--tag", required=True)
    build.add_argument("--dir", type=Path, required=True)
    build.add_argument("--repo", required=True)
    build.add_argument("--require", default=DEFAULT_REQUIRE)
    build.add_argument("--out", type=Path, required=True)
    build.add_argument("--defer-if-missing", action="store_true")
    sign = sub.add_parser("sign")
    sign.add_argument("--manifest", type=Path, required=True)
    sign.add_argument("--sig", type=Path, required=True)
    sub.add_parser("pubkey")
    check = sub.add_parser("verify")
    check.add_argument("--manifest", type=Path, required=True)
    check.add_argument("--sig", type=Path, required=True)
    check.add_argument("--pubkey", required=True)
    check.add_argument("--dir", type=Path)
    check.add_argument("--newer-than")
    args = parser.parse_args(argv)
    try:
        if args.cmd == "build":
            require = [name for name in args.require.split(",") if name]
            try:
                manifest = build_manifest(args.tag, existing_dir(args.dir), args.repo, require)
            except MissingPlatforms as err:
                if not args.defer_if_missing:
                    raise
                print(f"deferred: {err}")
                return 0
            output_file(args.out, MANIFEST_NAME).write_bytes(canonical(manifest))
        elif args.cmd == "sign":
            signature = sign_bytes(existing_file(args.manifest).read_bytes())
            output_file(args.sig, SIGNATURE_NAME).write_text(base64.b64encode(signature).decode() + "\n")
        elif args.cmd == "pubkey":
            print(public_key_b64())
        else:
            manifest = verify(args.manifest, args.sig, args.pubkey, args.dir, args.newer_than)
            print(f"ok: {manifest['version']} ({', '.join(sorted(manifest['artifacts']))})")
    except (ManifestError, ValueError, KeyError, OSError) as err:
        print(f"error: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
