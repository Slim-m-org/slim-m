# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for parsing a generated conversation defensively.

No network: `seed_ollama.load_or_generate_conversations` is patched out in
`BuildConversationsTest`, and everything else here is pure parsing over
hand-built "model output" dicts, garbage included on purpose.
"""
import random
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_conversation  # noqa: E402


class SafeIntTest(unittest.TestCase):
    def test_a_real_int_passes_through(self):
        self.assertEqual(seed_conversation._safe_int(3), 3)

    def test_a_bool_is_never_mistaken_for_an_index(self):
        self.assertEqual(seed_conversation._safe_int(True), -1)

    def test_a_whole_float_is_coerced(self):
        self.assertEqual(seed_conversation._safe_int(2.0), 2)

    def test_a_fractional_float_falls_back(self):
        self.assertEqual(seed_conversation._safe_int(2.5), -1)

    def test_a_numeric_string_is_parsed(self):
        self.assertEqual(seed_conversation._safe_int(" 4 "), 4)

    def test_garbage_falls_back_to_the_default(self):
        self.assertEqual(seed_conversation._safe_int("not a number"), -1)
        self.assertEqual(seed_conversation._safe_int(None), -1)
        self.assertEqual(seed_conversation._safe_int([1, 2]), -1)


class ResolveSpeakerTest(unittest.TestCase):
    def setUp(self):
        self.participants = ["Alan", "Grace"]
        self.by_lower = {"alan": "Alan", "grace": "Grace"}

    def test_an_exact_case_insensitive_match_wins(self):
        got = seed_conversation._resolve_speaker("ALAN", self.by_lower, self.participants)
        self.assertEqual(got, "Alan")

    def test_a_padded_or_truncated_name_still_resolves(self):
        got = seed_conversation._resolve_speaker(
            "Alan (seed account)", self.by_lower, self.participants)
        self.assertEqual(got, "Alan")

    def test_an_unrecognisable_name_is_none(self):
        got = seed_conversation._resolve_speaker("Nobody", self.by_lower, self.participants)
        self.assertIsNone(got)

    def test_a_blank_or_non_string_name_is_none(self):
        self.assertIsNone(seed_conversation._resolve_speaker("", self.by_lower, self.participants))
        self.assertIsNone(seed_conversation._resolve_speaker(None, self.by_lower, self.participants))


class LooksLikeEmojiTest(unittest.TestCase):
    def test_a_real_emoji_glyph_passes(self):
        self.assertTrue(seed_conversation._looks_like_emoji("🔥"))

    def test_a_word_is_rejected(self):
        self.assertFalse(seed_conversation._looks_like_emoji("thumbsup"))


class ParseReactionsTest(unittest.TestCase):
    def setUp(self):
        self.by_lower = {"alan": "Alan", "grace": "Grace", "linus": "Linus"}
        self.participants = ["Alan", "Grace", "Linus"]

    def test_reactors_named_by_display_name_resolve(self):
        raw = [{"emoji": "🔥", "reactors": ["Grace", "Linus"]}]
        got = seed_conversation._parse_reactions(raw, self.by_lower, self.participants, "Alan")
        self.assertEqual(got, [("🔥", ["Grace", "Linus"])])

    def test_the_speaker_never_reacts_to_their_own_turn(self):
        raw = [{"emoji": "🔥", "reactors": ["Alan", "Grace"]}]
        got = seed_conversation._parse_reactions(raw, self.by_lower, self.participants, "Alan")
        self.assertEqual(got, [("🔥", ["Grace"])])

    def test_a_non_emoji_string_falls_back_to_a_real_emoji(self):
        raw = [{"emoji": "thumbsup", "reactors": ["Grace"]}]
        got = seed_conversation._parse_reactions(raw, self.by_lower, self.participants, "Alan")
        self.assertEqual(got, [(seed_conversation._FALLBACK_EMOJI, ["Grace"])])

    def test_an_entry_with_no_resolvable_reactors_is_dropped(self):
        raw = [{"emoji": "🔥", "reactors": ["Nobody"]}]
        got = seed_conversation._parse_reactions(raw, self.by_lower, self.participants, "Alan")
        self.assertEqual(got, [])

    def test_garbage_shapes_never_raise(self):
        self.assertEqual(
            seed_conversation._parse_reactions("nope", self.by_lower, self.participants, "Alan"), [])
        self.assertEqual(
            seed_conversation._parse_reactions(["nope"], self.by_lower, self.participants, "Alan"), [])
        self.assertEqual(
            seed_conversation._parse_reactions(
                [{"emoji": "🔥", "reactors": "nope"}], self.by_lower, self.participants, "Alan"), [])


def _raw(turns, participants=("Alan", "Grace", "Linus", "Ada"), topic="testing"):
    return {"topic": topic, "participants": list(participants), "turns": turns}


class ParseConversationTest(unittest.TestCase):
    def test_a_well_formed_conversation_parses_cleanly(self):
        raw = _raw([
            {"speaker": "Alan", "text": "hey"},
            {"speaker": "Grace", "text": "hi", "reply_to": 0},
            {"speaker": "Linus", "text": "starting a thread",
             "thread_root": True},
            {"speaker": "Ada", "text": "joining", "in_thread": 2},
        ])
        got = seed_conversation.parse_conversation(raw)
        self.assertEqual(got.topic, "testing")
        self.assertEqual(len(got.turns), 4)
        self.assertEqual(got.turns[1].reply_to, 0)
        self.assertTrue(got.turns[2].thread_root)
        self.assertEqual(got.turns[3].in_thread, 2)

    def test_an_unresolvable_speaker_becomes_a_placeholder_turn_not_a_dropped_index(self):
        raw = _raw([
            {"speaker": "Alan", "text": "hey"},
            {"speaker": "Somebody Else", "text": "??"},
            {"speaker": "Grace", "text": "hi", "reply_to": 0},
            {"speaker": "Linus", "text": "more"},
            {"speaker": "Ada", "text": "even more"},
        ])
        got = seed_conversation.parse_conversation(raw)
        self.assertEqual(len(got.turns), 5)
        self.assertIsNone(got.turns[1].speaker)
        # Index 1's placeholder keeps turn 2's reply_to=0 meaning turn 0.
        self.assertEqual(got.turns[2].reply_to, 0)

    def test_no_participants_raises(self):
        raw = _raw([{"speaker": "Alan", "text": "hi"}], participants=[])
        with self.assertRaises(ValueError):
            seed_conversation.parse_conversation(raw)

    def test_too_few_turns_raises(self):
        raw = _raw([{"speaker": "Alan", "text": "hi"}])
        with self.assertRaises(ValueError):
            seed_conversation.parse_conversation(raw)

    def test_mostly_unresolvable_speakers_raises(self):
        raw = _raw([
            {"speaker": "Nobody", "text": "a"},
            {"speaker": "Nobody Else", "text": "b"},
            {"speaker": "Alan", "text": "c"},
            {"speaker": "Whoever", "text": "d"},
        ])
        with self.assertRaises(ValueError):
            seed_conversation.parse_conversation(raw)

    def test_a_non_list_turns_field_raises(self):
        raw = _raw("not a list")
        with self.assertRaises(ValueError):
            seed_conversation.parse_conversation(raw)

    def test_blank_text_is_treated_as_unusable(self):
        raw = _raw([
            {"speaker": "Alan", "text": ""},
            {"speaker": "Grace", "text": "hi"},
            {"speaker": "Linus", "text": "hey"},
            {"speaker": "Ada", "text": "sup"},
            {"speaker": "Alan", "text": "one more so the floor is cleared"},
        ])
        got = seed_conversation.parse_conversation(raw)
        self.assertIsNone(got.turns[0].speaker)

    def test_a_bogus_reply_to_and_in_thread_still_parse_as_the_given_ints(self):
        """Resolving a bad index to something sane is `seed_replay.py`'s
        job at replay time, not this parser's - it only has to preserve
        what the model actually said."""
        raw = _raw([
            {"speaker": "Alan", "text": "a"},
            {"speaker": "Grace", "text": "b", "reply_to": 999},
            {"speaker": "Linus", "text": "c", "in_thread": -5},
            {"speaker": "Ada", "text": "d"},
        ])
        got = seed_conversation.parse_conversation(raw)
        self.assertEqual(got.turns[1].reply_to, 999)
        self.assertEqual(got.turns[2].in_thread, -5)


class PickRequestsTest(unittest.TestCase):
    def test_turn_counts_sum_to_roughly_the_configured_multiple_of_draws(self):
        # 200 keeps this well above _MIN_CONVERSATION_COUNT's own floor.
        accounts = [{"display_name": n} for n in ("Alan", "Grace", "Linus", "Ada", "Ken")]
        got = seed_conversation._pick_requests(random.Random(1), accounts, 200)
        total_turns = sum(turn_count for _t, _p, turn_count in got)
        target = 200 * seed_conversation.CONVERSATION_TURNS_PER_DRAW
        self.assertGreaterEqual(total_turns, target)
        self.assertLess(total_turns, target + max(seed_conversation._TURN_COUNT_RANGE))

    def test_a_tiny_draw_budget_still_returns_the_minimum_count(self):
        accounts = [{"display_name": n} for n in ("Alan", "Grace", "Linus", "Ada", "Ken")]
        got = seed_conversation._pick_requests(random.Random(1), accounts, 1)
        self.assertGreaterEqual(len(got), seed_conversation._MIN_CONVERSATION_COUNT)

    def test_every_participant_subset_is_drawn_from_the_real_accounts(self):
        names = ("Alan", "Grace", "Linus", "Ada", "Ken")
        accounts = [{"display_name": n} for n in names]
        got = seed_conversation._pick_requests(random.Random(1), accounts, 40)
        for _topic, subset, turn_count in got:
            self.assertLessEqual(set(subset), set(names))
            self.assertGreaterEqual(len(subset), min(4, len(names)))
            low, high = seed_conversation._TURN_COUNT_RANGE
            self.assertTrue(low <= turn_count <= high)

    def test_a_small_account_count_still_works(self):
        accounts = [{"display_name": n} for n in ("Alan", "Grace")]
        got = seed_conversation._pick_requests(random.Random(1), accounts, 20)
        for _topic, subset, _turn_count in got:
            self.assertEqual(set(subset), {"Alan", "Grace"})

    def test_never_exceeds_the_hard_maximum_conversation_count(self):
        accounts = [{"display_name": n} for n in ("Alan", "Grace", "Linus", "Ada")]
        got = seed_conversation._pick_requests(random.Random(1), accounts, 100_000)
        self.assertLessEqual(len(got), seed_conversation._MAX_CONVERSATION_COUNT)


class BuildConversationsTest(unittest.TestCase):
    def test_no_accounts_means_no_conversations_and_no_network_call(self):
        with patch("seed_ollama.load_or_generate_conversations") as fake:
            got = seed_conversation.build_conversations("m", [], 1, total_draws=40)
        fake.assert_not_called()
        self.assertEqual(got, [])

    def test_unusable_raw_conversations_are_dropped_not_raised(self):
        accounts = [{"display_name": n} for n in ("Alan", "Grace", "Linus", "Ada")]
        with patch("seed_ollama.load_or_generate_conversations",
                    return_value=[{"topic": "x", "participants": [], "turns": []}]):
            got = seed_conversation.build_conversations("m", accounts, 1, total_draws=40)
        self.assertEqual(got, [])

    def test_a_usable_raw_conversation_is_parsed_through(self):
        accounts = [{"display_name": n} for n in ("Alan", "Grace", "Linus", "Ada")]
        raw = _raw([
            {"speaker": "Alan", "text": "a"}, {"speaker": "Grace", "text": "b"},
            {"speaker": "Linus", "text": "c"}, {"speaker": "Ada", "text": "d"},
        ])
        with patch("seed_ollama.load_or_generate_conversations", return_value=[raw]):
            got = seed_conversation.build_conversations("m", accounts, 1, total_draws=40)
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0].topic, "testing")

    def test_the_deployment_being_seeded_is_never_the_ollama_base_url(self):
        """The regression this guards: build_conversations must never be
        handed the deployment's own base_url as ollama_base_url, or every
        generation call reaches the wrong server entirely."""
        accounts = [{"display_name": n} for n in ("Alan", "Grace", "Linus", "Ada")]
        with patch("seed_ollama.load_or_generate_conversations",
                    return_value=[]) as fake:
            seed_conversation.build_conversations("m", accounts, 1, total_draws=40)
        called_kwargs = fake.call_args.kwargs
        self.assertNotIn("base_url", called_kwargs)


if __name__ == "__main__":
    unittest.main()
