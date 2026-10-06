# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for the shared REST client's request shape.

No network here: `urllib.request.urlopen` is patched out, and every test
inspects the `Request` object that would have been sent rather than any
real response. What matters is what leaves the process, not what a server
does with it.
"""
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_api  # noqa: E402


def _fake_response(payload=b"{}"):
    response = Mock()
    response.read.return_value = payload
    response.__enter__ = Mock(return_value=response)
    response.__exit__ = Mock(return_value=False)
    return response


class UserAgentTest(unittest.TestCase):
    """Cloudflare answers a default urllib UA with a 403; see CLAUDE.md."""

    def test_every_call_carries_a_non_default_user_agent(self):
        api = e2e_api.Api("https://example.invalid")
        with patch("urllib.request.urlopen", return_value=_fake_response()) as mock_open:
            api.call("GET", "/version")
        request = mock_open.call_args[0][0]
        self.assertEqual(request.get_header("User-agent"), e2e_api.USER_AGENT)
        self.assertNotIn("python-urllib", request.get_header("User-agent").lower())

    def test_the_user_agent_survives_alongside_an_auth_header(self):
        api = e2e_api.Api("https://example.invalid", token="secret-token")
        with patch("urllib.request.urlopen", return_value=_fake_response()) as mock_open:
            api.call("GET", "/me")
        request = mock_open.call_args[0][0]
        self.assertEqual(request.get_header("User-agent"), e2e_api.USER_AGENT)
        self.assertEqual(request.get_header("Authorization"), "Bearer secret-token")

    def test_an_unauthenticated_version_probe_still_carries_it(self):
        # version() builds a second, tokenless Api rather than reusing self.
        api = e2e_api.Api("https://example.invalid", token="secret-token")
        with patch("urllib.request.urlopen", return_value=_fake_response()) as mock_open:
            api.version()
        request = mock_open.call_args[0][0]
        self.assertEqual(request.get_header("User-agent"), e2e_api.USER_AGENT)
        self.assertIsNone(request.get_header("Authorization"))


class ListShapeTest(unittest.TestCase):
    """The server sends bare arrays; a wrapped body is a wire break and must fail."""

    LISTS = (
        ("messages", ("c1",), "messages"),
        ("members", (), "members"),
        ("pins", ("c1",), "messages"),
        ("reports", (), "reports"),
        ("blocks", (), "blocked"),
        ("roles", (), "roles"),
    )

    def _api_returning(self, body):
        api = e2e_api.Api("https://example.invalid")
        api.call = Mock(return_value=body)
        return api

    def test_a_bare_array_is_returned_as_is(self):
        for method, args, _key in self.LISTS:
            with self.subTest(method=method):
                api = self._api_returning([{"id": "x"}])
                self.assertEqual(getattr(api, method)(*args), [{"id": "x"}])

    def test_a_wrapped_body_fails_the_run(self):
        for method, args, key in self.LISTS:
            with self.subTest(method=method):
                api = self._api_returning({key: [{"id": "x"}]})
                with self.assertRaises(AssertionError):
                    getattr(api, method)(*args)

    def test_canvas_objects_and_slots_stay_wrapped(self):
        api = self._api_returning({"objects": [1], "slots": [2]})
        self.assertEqual(api.canvas_objects("c1"), [1])
        self.assertEqual(api.canvas_media_slots("c1"), [2])


class WaitUntilTest(unittest.TestCase):
    def test_returns_the_first_value_that_satisfies(self):
        reads = iter([0, 1, 2, 3])
        with patch("e2e_api.time.sleep"):
            got = e2e_api.wait_until(lambda: next(reads), lambda n: n >= 2, "never")
        self.assertEqual(got, 2)

    def test_raises_the_given_message_when_the_deadline_passes(self):
        clock = iter([0.0, 0.0, 10.0, 20.0, 30.0])
        with patch("e2e_api.time.time", side_effect=lambda: next(clock)), \
                patch("e2e_api.time.sleep"):
            with self.assertRaises(AssertionError) as caught:
                e2e_api.wait_until(lambda: 0, lambda n: n > 0, "the server never emptied", timeout=15)
        self.assertEqual(str(caught.exception), "the server never emptied")


if __name__ == "__main__":
    unittest.main()
