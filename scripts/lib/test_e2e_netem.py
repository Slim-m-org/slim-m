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
