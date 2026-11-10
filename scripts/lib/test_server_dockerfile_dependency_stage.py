# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The server image's dependency stage stubs every target the workspace builds.

The stage compiles the dependency tree from manifests and empty sources, so a
source edit does not recompile it. A target the stage does not stub (a new bench,
a build script, a second workspace member) fails that build on the pull request
that adds it, and the stage must never copy real sources or it stops caching.
"""
import re
import subprocess
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVER = "crates/slimm-server"
# Tracked entries of the crate the image build never reads; anything else must be copied by the release stage.
NOT_BUILD_INPUTS = {"Cargo.toml", "CHANGELOG.md", "migrations.lock.json", "benches", "tests", "examples"}


def stage(dockerfile: str, name: str) -> str:
    """The text of `FROM ... AS <name>` up to the next FROM."""
    found = re.search(rf"^FROM \S+ AS {name}\n(.*?)(?=^FROM |\Z)", dockerfile, re.M | re.S)
    return found.group(1) if found else ""


def code_only(text: str) -> str:
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def targets(manifest: dict, crate_dir: Path) -> list[str]:
    """Source paths, relative to the crate, that cargo needs to exist to load the manifest."""
    found = [manifest.get("lib", {}).get("path", "src/lib.rs")]
    found += [b.get("path", f"src/bin/{b['name']}.rs") for b in manifest.get("bin", [])]
    found += [b.get("path", f"benches/{b['name']}.rs") for b in manifest.get("bench", [])]
    found += [e.get("path", f"examples/{e['name']}.rs") for e in manifest.get("example", [])]
    build = manifest.get("package", {}).get("build")
    if build is None and (crate_dir / "build.rs").exists():
        build = "build.rs"
    if build:
        found.append(build)
    return found


def missing_stubs(dockerfile: str, manifest: dict, crate_dir: Path) -> list[str]:
    deps = code_only(stage(dockerfile, "deps"))
    return [f"{SERVER}/{t}" for t in targets(manifest, crate_dir) if f"{SERVER}/{t}" not in deps]


def uncopied_inputs(dockerfile: str, tracked: list[str]) -> list[str]:
    """Top-level entries of the server crate the release stage neither copies nor excuses."""
    copied = set(re.findall(rf"^COPY {SERVER}/(\S+) ", code_only(stage(dockerfile, "release")), re.M))
    entries = {path.split("/")[0] for path in tracked}
    return sorted(entries - copied - NOT_BUILD_INPUTS)


def workspace_members(root: Path) -> list[str]:
    cargo = tomllib.loads((root / "Cargo.toml").read_text())["workspace"]
    excluded = set(cargo.get("exclude", []))
    members = []
    for pattern in cargo["members"]:
        members += [str(p.relative_to(root)) for p in sorted(root.glob(pattern)) if (p / "Cargo.toml").exists()]
    return [m for m in members if m not in excluded]


class ServerDockerfileDependencyStageTest(unittest.TestCase):
    def setUp(self):
        self.dockerfile = (ROOT / "docker" / "server.Dockerfile").read_text()
        self.manifest = tomllib.loads((ROOT / SERVER / "Cargo.toml").read_text())

    def test_every_target_the_manifest_declares_has_a_stub(self):
        self.assertEqual(missing_stubs(self.dockerfile, self.manifest, ROOT / SERVER), [])

    def test_the_only_workspace_member_is_the_one_the_stage_copies(self):
        self.assertEqual(workspace_members(ROOT), [SERVER], "a new member needs its manifest and stubs in the deps stage")

    def test_the_stage_copies_manifests_and_never_sources(self):
        deps = code_only(stage(self.dockerfile, "deps"))
        copies = re.findall(r"^COPY (.+)$", deps, re.M)
        self.assertIn(f"{SERVER}/Cargo.toml {SERVER}/Cargo.toml", copies)
        for line in copies:
            with self.subTest(copy=line):
                self.assertNotRegex(line, r"^(\.|crates/?)( |$)|^crates/slimm-server( |/src)")

    def test_the_release_stage_copies_every_part_of_the_crate_the_build_reads(self):
        listed = subprocess.run(["git", "ls-files", SERVER], cwd=ROOT, capture_output=True, text=True, check=True)
        tracked = [line.removeprefix(f"{SERVER}/") for line in listed.stdout.splitlines()]
        self.assertEqual(uncopied_inputs(self.dockerfile, tracked), [], "copy it in the release stage or list it in NOT_BUILD_INPUTS")

    def test_the_build_id_is_declared_after_the_dependency_stage(self):
        self.assertNotIn("SLIMM_BUILD_ID", stage(self.dockerfile, "deps"))
        self.assertIn("ARG SLIMM_BUILD_ID", stage(self.dockerfile, "release"))

    def test_the_stub_workspace_crate_is_cleaned_so_the_real_one_is_rebuilt(self):
        deps = code_only(stage(self.dockerfile, "deps"))
        self.assertRegex(deps, r"cargo clean\b.*--package slimm-server")

    def test_the_checks_reject_a_missing_stub_and_a_new_target(self):
        dockerfile = "FROM x AS deps\nRUN touch crates/slimm-server/src/lib.rs\nFROM y AS release\n"
        manifest = {"bin": [{"name": "s", "path": "src/main.rs"}], "bench": [{"name": "hot"}]}
        self.assertEqual(
            missing_stubs(dockerfile, manifest, ROOT / "no-such-crate"),
            [f"{SERVER}/src/main.rs", f"{SERVER}/benches/hot.rs"],
        )
        release = f"FROM x AS release\nCOPY {SERVER}/src {SERVER}/src\n"
        self.assertEqual(uncopied_inputs(release, ["src/a.rs", "assets/x.txt", "tests/t.rs"]), ["assets"])
        self.assertEqual(stage("FROM a AS one\nRUN 1\nFROM b AS two\nRUN 2\n", "one"), "RUN 1\n")


if __name__ == "__main__":
    unittest.main()
