# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import importlib
import os
import unittest
from unittest import mock

import e2e_netem


class Container(unittest.TestCase):
    def tearDown(self):
        importlib.reload(e2e_netem)

    def test_the_default_is_the_stacks_default(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(importlib.reload(e2e_netem).LIVEKIT_CONTAINER, "slimm-e2e-lk")

    def test_it_follows_the_stacks_container_name(self):
        with mock.patch.dict(os.environ, {"E2E_LK_CONTAINER": "slimm-validate-lk"}):
            self.assertEqual(importlib.reload(e2e_netem).LIVEKIT_CONTAINER, "slimm-validate-lk")


class Image(unittest.TestCase):
    def test_the_base_is_pinned_by_digest(self):
        first = e2e_netem.DOCKERFILE.splitlines()[0]
        self.assertRegex(first, r"^FROM alpine:\d+\.\d+@sha256:[0-9a-f]{64}$")

    def test_a_different_recipe_is_a_different_image(self):
        self.assertNotEqual(e2e_netem.image_for("FROM alpine:3.24\n"), e2e_netem.image_for("FROM alpine:3.25\n"))
        self.assertEqual(e2e_netem.IMAGE, e2e_netem.image_for(e2e_netem.DOCKERFILE))
        self.assertNotEqual(e2e_netem.IMAGE, "slimm-netem:local")
