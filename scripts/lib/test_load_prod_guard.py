# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The load tools have no override flag, so the production check they share
with the seed guard has to refuse the live host and nothing else by accident."""
import importlib.util
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

LIB = Path(__file__).resolve().parent
SCRIPTS = LIB.parent
sys.path.insert(0, str(LIB))
sys.path.insert(0, str(SCRIPTS))

import load_accounts  # noqa: E402
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

    def run_main(self, module, *argv):
        with patch.object(module.asyncio, "run") as run, \
             patch.object(module, "run", return_value=None), \
             patch.object(loadtest, "find_server_pid", return_value=1):
            try:
                return module.main(["--base-url", *argv]), run
            except SystemExit as exc:
                return exc, run

    def test_both_tools_refuse_the_live_host(self):
        for name, module in self.tools():
            caught, run = self.run_main(module, "https://slim.npc-server.top")
            self.assertIsInstance(caught, SystemExit, name)
            self.assertIn("refusing", str(caught))
            run.assert_not_called()

    def test_both_tools_refuse_any_host_that_is_not_this_machine(self):
        for url in ("https://some-other-community.example", "http://192.168.1.5:8080",
                    "http://example.com/?x=npc-server.top", "http://localhost.evil.test"):
            for name, module in self.tools():
                caught, run = self.run_main(module, url)
                self.assertIsInstance(caught, SystemExit, f"{name} {url}")
                self.assertIn("refusing", str(caught))
                run.assert_not_called()

    def test_a_loopback_address_runs_even_with_the_domain_in_its_query(self):
        for url in ("http://127.0.0.1:8080", "http://localhost:8080/", "http://[::1]:8080",
                    "http://127.0.0.1:8080/?x=npc-server.top"):
            for name, module in self.tools():
                code, run = self.run_main(module, url, "--server-pid", "1")
                self.assertEqual(code, 0, f"{name} {url}")
                run.assert_called_once()


class CacheDefaultsTest(unittest.TestCase):
    def test_both_load_tools_write_tokens_and_results_there_unless_told_otherwise(self):
        for module, result in ((loadtest, "loadtest-result.json"),
                               (_load_reconnect_storm(), "reconnect-storm-result.json")):
            args = module.parse_args([])
            self.assertEqual(args.cache_dir, load_accounts.default_cache_dir())
            self.assertEqual(args.out, os.path.join(load_accounts.default_cache_dir(), result))
            chosen = module.parse_args(["--cache-dir", "/elsewhere"])
            self.assertEqual(chosen.out, os.path.join("/elsewhere", result))
            explicit = module.parse_args(["--out", "mine.json"])
            self.assertEqual(explicit.out, "mine.json")


class WsUrlTest(unittest.TestCase):
    def test_the_socket_address_follows_the_scheme_and_keeps_a_path_prefix(self):
        self.assertEqual(loadtest.ws_url_for("http://127.0.0.1:8080"), "ws://127.0.0.1:8080/ws")
        self.assertEqual(loadtest.ws_url_for("https://localhost:8443/prefix/"),
                         "wss://localhost:8443/prefix/ws")

    def test_something_that_is_not_http_is_refused(self):
        for url in ("ftp://127.0.0.1", "127.0.0.1:8080"):
            with self.assertRaises(SystemExit):
                loadtest.ws_url_for(url)


if __name__ == "__main__":
    unittest.main()
