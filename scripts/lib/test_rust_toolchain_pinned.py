# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The Rust compiler is a pinned version that CI and the shipped image share.

A floating `stable` let a new release turn clippy red on PRs that touched no
Rust. The server image copies rust-toolchain.toml in with the source, so the
builder image's version has to equal the pin or rustup downloads another
compiler mid-build. Stdlib only, per the other workflow-shape gates here.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXACT = re.compile(r"\d+\.\d+\.\d+")


def channel(text: str):
    found = re.search(r'^channel\s*=\s*"([^"]+)"', text, re.MULTILINE)
    return found.group(1) if found else None


def builder_version(dockerfile: str):
    found = re.search(r"^FROM rust:(\d+\.\d+\.\d+)-alpine@sha256:[0-9a-f]{64} AS builder$",
                      dockerfile, re.MULTILINE)
    return found.group(1) if found else None


class RustToolchainPinnedTest(unittest.TestCase):
    def setUp(self):
        self.pin = channel((ROOT / "rust-toolchain.toml").read_text())
        self.builder = builder_version((ROOT / "docker" / "server.Dockerfile").read_text())

    def test_the_channel_is_an_exact_version_not_a_moving_one(self):
        self.assertRegex(self.pin or "", EXACT, "rust-toolchain.toml channel must be x.y.z")

    def test_the_server_image_builds_with_the_pinned_version(self):
        self.assertEqual(self.builder, self.pin,
                         "docker/server.Dockerfile builder tag must name the toolchain pin")

    def test_the_pin_is_not_older_than_the_declared_msrv(self):
        msrv = re.search(r'^rust-version\s*=\s*"([\d.]+)"', (ROOT / "Cargo.toml").read_text(),
                         re.MULTILINE).group(1)
        as_tuple = lambda v: tuple(int(p) for p in v.split("."))
        self.assertGreaterEqual(as_tuple(self.pin), as_tuple(msrv))

    def test_the_helpers_reject_a_floating_channel_and_an_unpinned_builder(self):
        self.assertEqual(channel('[toolchain]\nchannel = "stable"\n'), "stable")
        self.assertIsNone(re.fullmatch(EXACT, "stable"))
        self.assertIsNone(builder_version("FROM rust:1-alpine@sha256:" + "a" * 64 + " AS builder"))


if __name__ == "__main__":
    unittest.main()
