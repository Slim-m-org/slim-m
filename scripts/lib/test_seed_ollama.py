# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for the shared ollama wire plumbing and conversation fetch.

No network and no real Ollama here, matching CI's bare runner: every test
patches `urllib.request.urlopen` (or the module's own orchestration
functions) with a fake. The pooled `Corpus` built on top of this shared
plumbing has its own coverage in `test_seed_ollama_pools.py`.
"""
import json
import shutil
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_ollama  # noqa: E402


def _fake_response(payload):
    response = Mock()
    response.read.return_value = json.dumps(payload).encode()
    response.__enter__ = Mock(return_value=response)
    response.__exit__ = Mock(return_value=False)
    return response


def _generate_response(inner):
    """What Ollama's own /api/generate answers: `response` is a JSON string."""
    return _fake_response({"response": json.dumps(inner)})


class ReachableTest(unittest.TestCase):
    def test_true_when_the_model_is_in_the_tag_list(self):
        with patch("urllib.request.urlopen",
                    return_value=_fake_response({"models": [{"name": "qwen3:8b"}]})):
            self.assertTrue(seed_ollama._reachable("http://x", "qwen3:8b"))

    def test_false_when_the_model_is_not_pulled(self):
        with patch("urllib.request.urlopen",
                    return_value=_fake_response({"models": [{"name": "other"}]})):
            self.assertFalse(seed_ollama._reachable("http://x", "qwen3:8b"))

    def test_false_when_the_server_is_unreachable(self):
        with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("refused")):
            self.assertFalse(seed_ollama._reachable("http://x", "qwen3:8b"))


class FetchConversationTest(unittest.TestCase):
    def test_parses_the_turns_array(self):
        turns = [{"speaker": "Alan", "text": "hi"}]
        with patch("urllib.request.urlopen",
                    return_value=_generate_response({"turns": turns})):
            got = seed_ollama._fetch_conversation(
                "http://x", "m", ["Alan"], "a topic", 4, 5)
        self.assertEqual(got, turns)

    def test_a_response_with_no_turns_array_raises_for_the_caller_to_handle(self):
        with patch("urllib.request.urlopen",
                    return_value=_generate_response({"nonsense": True})):
            with self.assertRaises(ValueError):
                seed_ollama._fetch_conversation(
                    "http://x", "m", ["Alan"], "a topic", 4, 5)


class LoadOrGenerateConversationsTest(unittest.TestCase):
    def setUp(self):
        self.cache_dir = tempfile.mkdtemp(prefix="seed-ollama-conv-test-")
        self.addCleanup(shutil.rmtree, self.cache_dir, ignore_errors=True)

    def test_an_unreachable_server_returns_nothing_and_never_fetches(self):
        with patch("seed_ollama._reachable", return_value=False), \
             patch("seed_ollama._fetch_conversation") as fake_fetch:
            got = seed_ollama.load_or_generate_conversations(
                "m", "seed-1", [("topic", ["Alan"], 4)], cache_dir=self.cache_dir)
        fake_fetch.assert_not_called()
        self.assertEqual(got, [])

    def test_one_bad_topic_does_not_sink_the_others(self):
        def fake_fetch(base_url, model, participants, topic, turn_count, timeout):
            if topic == "bad":
                raise ValueError("garbage")
            return [{"speaker": participants[0], "text": "hi"}]

        with patch("seed_ollama._reachable", return_value=True), \
             patch("seed_ollama._fetch_conversation", side_effect=fake_fetch):
            got = seed_ollama.load_or_generate_conversations(
                "m", "seed-1",
                [("bad", ["Alan"], 4), ("good", ["Alan"], 4)], cache_dir=self.cache_dir)
        self.assertEqual([c["topic"] for c in got], ["good"])

    def test_a_successful_generation_is_cached_and_reused(self):
        def fake_fetch(base_url, model, participants, topic, turn_count, timeout):
            return [{"speaker": participants[0], "text": "hi"}]

        with patch("seed_ollama._reachable", return_value=True), \
             patch("seed_ollama._fetch_conversation", side_effect=fake_fetch):
            seed_ollama.load_or_generate_conversations(
                "m", "seed-1", [("topic", ["Alan"], 4)], cache_dir=self.cache_dir)
        with patch("seed_ollama._reachable") as fake_reachable, \
             patch("seed_ollama._fetch_conversation") as fake_fetch2:
            got = seed_ollama.load_or_generate_conversations(
                "m", "seed-1", [("topic", ["Alan"], 4)], cache_dir=self.cache_dir)
        fake_reachable.assert_not_called()
        fake_fetch2.assert_not_called()
        self.assertEqual(got[0]["topic"], "topic")

    def test_every_topic_failing_is_not_cached_and_returns_empty(self):
        with patch("seed_ollama._reachable", return_value=True), \
             patch("seed_ollama._fetch_conversation", side_effect=ValueError("nope")):
            got = seed_ollama.load_or_generate_conversations(
                "m", "seed-1", [("topic", ["Alan"], 4)], cache_dir=self.cache_dir)
        self.assertEqual(got, [])
        self.assertEqual(list(Path(self.cache_dir).iterdir()), [])

    def test_a_different_cohort_under_the_same_seed_is_not_a_cache_hit(self):
        def fake_fetch(base_url, model, participants, topic, turn_count, timeout):
            return [{"speaker": participants[0], "text": "hi"}]

        with patch("seed_ollama._reachable", return_value=True), \
             patch("seed_ollama._fetch_conversation", side_effect=fake_fetch) as fetch:
            seed_ollama.load_or_generate_conversations(
                "m", 7, [("topic", ["Alan", "Bea"], 4)], cache_dir=self.cache_dir)
            got = seed_ollama.load_or_generate_conversations(
                "m", 7, [("topic", ["Cy"], 4)], cache_dir=self.cache_dir)
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(got[0]["participants"], ["Cy"])

    def test_a_cache_file_of_the_wrong_shape_is_a_miss(self):
        requests = [("topic", ["Alan"], 4)]
        for payload in ({"a": 1}, [1, 2]):
            path = seed_ollama._cache_path(
                "m", seed_ollama._conversation_cache_seed(7, requests),
                self.cache_dir, kind="conversations")
            Path(path).write_text(json.dumps(payload))
            with patch("seed_ollama._reachable", return_value=False):
                got = seed_ollama.load_or_generate_conversations(
                    "m", 7, requests, cache_dir=self.cache_dir)
            self.assertEqual(got, [], payload)


if __name__ == "__main__":
    unittest.main()
