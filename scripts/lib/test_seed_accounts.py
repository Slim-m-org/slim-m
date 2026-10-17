# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for account reuse: log in rather than re-register.

No network: `e2e_api.Api.call` is patched directly rather than faking
`urllib.request.urlopen`, since what matters here is which endpoints
`register_accounts` reaches for and in what order, not the wire shape
`e2e_api.py`'s own tests already cover.
"""
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_api  # noqa: E402
import seed_accounts  # noqa: E402
import seed_content  # noqa: E402


def _http_error(code):
    return urllib.error.HTTPError("http://x", code, "boom", {}, None)


class RegisterAccountsTest(unittest.TestCase):
    def test_a_fresh_username_is_registered_and_not_marked_reused(self):
        def fake_call(api_self, method, path, body=None, **kwargs):
            assert path == "/auth/register", path
            return {"access_token": "tok", "refresh_token": "r"}

        with patch.object(e2e_api.Api, "call", fake_call):
            accounts = seed_accounts.register_accounts(
                "http://x", 1, "pw", "code", "seed", username_tag="")
        self.assertFalse(accounts[0]["reused"])
        self.assertEqual(accounts[0]["api"].token, "tok")
        self.assertIsNotNone(accounts[0]["api"].relogin)

    def test_an_already_registered_username_logs_in_instead(self):
        calls = []

        def fake_call(self, method, path, body=None, **kwargs):
            calls.append(path)
            if path == "/auth/register":
                raise _http_error(409)
            if path == "/auth/login":
                return {"access_token": "tok2", "refresh_token": "r"}
            raise AssertionError(f"unexpected call to {path}")

        with patch.object(e2e_api.Api, "call", fake_call):
            accounts = seed_accounts.register_accounts(
                "http://x", 1, "pw", "code", "seed", username_tag="")
        self.assertEqual(calls, ["/auth/register", "/auth/login"])
        self.assertTrue(accounts[0]["reused"])
        self.assertEqual(accounts[0]["api"].token, "tok2")

    def test_a_400_from_a_claimed_invite_only_deployment_still_reuses_the_persona(self):
        def fake_call(self, method, path, body=None, **kwargs):
            if path == "/auth/register":
                raise _http_error(400)
            if path == "/auth/login":
                return {"access_token": "tok3", "refresh_token": "r"}
            raise AssertionError(f"unexpected call to {path}")

        with patch.object(e2e_api.Api, "call", fake_call):
            accounts = seed_accounts.register_accounts(
                "http://x", 1, "pw", None, "seed", username_tag="")
        self.assertTrue(accounts[0]["reused"])

    def test_a_400_whose_login_also_fails_keeps_the_invite_hint(self):
        def fake_call(self, method, path, body=None, **kwargs):
            if path == "/auth/register":
                raise _http_error(400)
            raise _http_error(401)

        with patch.object(e2e_api.Api, "call", fake_call):
            with self.assertRaises(seed_accounts.AccountSetupError) as ctx:
                seed_accounts.register_accounts(
                    "http://x", 1, "pw", None, "seed", username_tag="")
        self.assertIn("--invite-code", str(ctx.exception))

    def test_a_conflict_with_the_wrong_password_raises_a_clear_error(self):
        def fake_call(self, method, path, body=None, **kwargs):
            if path == "/auth/register":
                raise _http_error(409)
            if path == "/auth/login":
                raise _http_error(401)
            raise AssertionError(f"unexpected call to {path}")

        with patch.object(e2e_api.Api, "call", fake_call):
            with self.assertRaises(seed_accounts.AccountSetupError):
                seed_accounts.register_accounts(
                    "http://x", 1, "pw", "code", "seed", username_tag="")

    def test_a_non_conflict_failure_is_never_treated_as_reuse(self):
        def fake_call(self, method, path, body=None, **kwargs):
            raise _http_error(500)

        with patch.object(e2e_api.Api, "call", fake_call):
            with self.assertRaises(seed_accounts.AccountSetupError):
                seed_accounts.register_accounts(
                    "http://x", 1, "pw", "code", "seed", username_tag="")

    def test_a_mix_of_fresh_and_existing_accounts_all_resolve(self):
        already_existing, _display = seed_content.persona(0, tag="")
        registered_usernames = {already_existing}

        def fake_call(self, method, path, body=None, **kwargs):
            if path == "/auth/register":
                username = body["username"]
                if username in registered_usernames:
                    raise _http_error(409)
                registered_usernames.add(username)
                return {"access_token": f"tok-{username}", "refresh_token": "r"}
            if path == "/auth/login":
                return {"access_token": "relogged-in", "refresh_token": "r"}
            if path == "/invites":
                return {"code": "minted"}
            raise AssertionError(f"unexpected call to {path}")

        with patch.object(e2e_api.Api, "call", fake_call):
            accounts = seed_accounts.register_accounts(
                "http://x", 3, "pw", "code", "seed", username_tag="")
        self.assertEqual([a["reused"] for a in accounts], [True, False, False])


if __name__ == "__main__":
    unittest.main()
