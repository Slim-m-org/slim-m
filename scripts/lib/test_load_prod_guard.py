# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The load tools have no override flag, so the production check they share
with the seed guard has to refuse the live host and nothing else by accident."""
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

LIB = Path(__file__).resolve().parent
SCRIPTS = LIB.parent
sys.path.insert(0, str(LIB))
sys.path.insert(0, str(SCRIPTS))

import loadtest  # noqa: E402
import seed_guard  # noqa: E402


def _load_reconnect_storm():
    spec = importlib.util.spec_from_file_location(
        "reconnect_storm", SCRIPTS / "reconnect-storm.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class IsKnownProductionTest(unittest.TestCase):
    def test_the_live_host_and_any_subdomain_of_its_domain_count(self):
        for url in ("https://slim.npc-server.top", "https://other.npc-server.top/app",
                    "https://npc-server.top"):
            self.assertTrue(seed_guard.is_known_production(url), url)

    def test_the_live_host_by_its_lan_address_counts_too(self):
        for url in ("http://10.0.0.100:8095", "http://10.0.0.100", "ws://10.0.0.100:7880"):
            self.assertTrue(seed_guard.is_known_production(url), url)

    def test_another_lan_address_does_not_count(self):
        for url in ("http://10.0.0.101:8095", "http://192.168.1.100", "http://127.0.0.1:8095"):
            self.assertFalse(seed_guard.is_known_production(url), url)

    def test_a_path_or_query_naming_the_domain_does_not_count(self):
        for url in ("http://example.com/?x=npc-server.top", "http://127.0.0.1:8080",
                    "http://notnpc-server.top"):
            self.assertFalse(seed_guard.is_known_production(url), url)


class LoadToolsRefuseProductionTest(unittest.TestCase):
    def tools(self):
        return [("loadtest", loadtest), ("reconnect-storm", _load_reconnect_storm())]

    def test_both_tools_refuse_the_live_host(self):
        for name, module in self.tools():
            with patch.object(module.asyncio, "run") as run, \
                 patch.object(module, "run", new=lambda args: None), \
                 patch.object(loadtest, "find_server_pid", return_value=1):
                with self.assertRaises(SystemExit, msg=name) as caught:
                    module.main(["--base-url", "https://slim.npc-server.top"])
            self.assertIn("refusing", str(caught.exception))
            run.assert_not_called()

    def test_a_query_naming_the_domain_on_another_host_is_not_refused(self):
        for name, module in self.tools():
            with patch.object(module.asyncio, "run") as run, \
                 patch.object(module, "run", new=lambda args: None), \
                 patch.object(loadtest, "find_server_pid", return_value=1):
                self.assertEqual(
                    module.main(["--base-url", "http://example.com/?x=npc-server.top",
                                 "--server-pid", "1"]), 0, name)
            run.assert_called_once()


if __name__ == "__main__":
    unittest.main()
