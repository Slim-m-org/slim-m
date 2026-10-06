# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Optional Ollama-generated content, for less templated seed data.

Off unless `--ollama` is passed; see `seed-data.py`. Two shapes of call, both
batched rather than one round trip per message:

- `load_or_generate_conversations` (this file) asks for a handful of whole,
  structured multi-speaker conversations, one call each, which
  `seed_conversation.py` parses and `seed_replay.py` replays turn by turn.
  This is the fix for a real defect: pooling disconnected one-line strings
  and drawing them at random cannot produce a conversation, because nothing
  any speaker says ever relates to what another speaker just said. A whole
  conversation in one call, given the real participant names, can.
- `load_or_generate` (`seed_ollama_pools.py`) builds a pooled `Corpus` of
  disconnected strings instead, still used for the action kinds a
  conversation replay does not cover (code blocks, polls).

Both are cached to disk keyed by model and seed, so a repeat run with the
same `--seed` is instant and reproducible, and both share the wire-level
mechanics this file owns: `_request` (one `/api/generate` call, JSON-schema
constrained), `_reachable` (a fast pre-flight so an outage fails in seconds
rather than after several full-length timeouts), and the on-disk cache
helpers. Every failure either shape can have (unreachable, missing model, a
malformed response, a slow model past the timeout) is caught here and
answered with an empty or partial result; the canned fallback in
`seed_content.py`/`seed_conversation.py` is always there, per field or per
conversation, so a side feature going missing never breaks a seed run.

`load_or_generate_conversations` logs one line before and one after every
conversation it asks for, each carrying its index and the total count, so a
run sitting quietly for two minutes on conversation 12/45 reads as normal
and one sitting quietly for twenty reads as stuck - the actual gap this
closes: an uncached run of a few dozen conversations printed nothing at all
between its start and its finish, which cost one real run being killed on
the (wrong) belief that it had wedged. Generation is deliberately still
sequential, not fanned out over a thread pool the way the seed workers are:
measured on this project's own dev box (a single local GPU, `ollama ps`
showing exactly one loaded model instance), four conversations run
concurrently took the same wall-clock time as the same four run one after
another, because Ollama serialises generation on one model instance
regardless of how many HTTP requests arrive at once - concurrency here
would only load that one instance harder for no throughput gained, and
would also make the per-request timing this progress log reports on
meaningless (a slow request either genuinely slow or just waiting behind
its neighbours look identical).
"""
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

DEFAULT_MODEL = "qwen3:8b"
DEFAULT_BASE_URL = "http://localhost:11434"
CACHE_DIR = os.path.join(os.path.expanduser("~"), ".cache", "slim-m-seed")

_PROBE_TIMEOUT = 5
_REQUEST_TIMEOUT = 120

# Applied to every prompt here and in seed_ollama_pools.py: this can land live.
_SAFETY_NOTE = (
    " Keep it benign: no passwords, API keys, tokens, or anything that "
    "looks like a real credential; no real names, addresses or private "
    "information; nothing abusive or explicit."
)

_CONVERSATION_SCHEMA = {
    "type": "object",
    "properties": {"turns": {"type": "array", "items": {
        "type": "object",
        "properties": {
            "speaker": {"type": "string"},
            "text": {"type": "string"},
            # -1 means "no target"; see seed_conversation.py's own parsing.
            "reply_to": {"type": "integer"},
            "thread_root": {"type": "boolean"},
            "in_thread": {"type": "integer"},
            "reactions": {"type": "array", "items": {
                "type": "object",
                "properties": {
                    "emoji": {"type": "string"},
                    "reactors": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["emoji", "reactors"],
            }},
        },
        "required": ["speaker", "text"],
    }}},
    "required": ["turns"],
}


def _conversation_prompt(participants, topic, turn_count):
    names = ", ".join(participants)
    return (
        "Write a realistic group chat transcript, as JSON, for a small "
        f"friend group's private text channel. The participants, by name, "
        f"are: {names}. Everyone already knows each other well. Write "
        f"{turn_count} turns of natural back-and-forth about: {topic}. "
        "Return an object with a 'turns' array. Each turn has: 'speaker' "
        "(one of the names above, spelled exactly as given), 'text' (3 to "
        "30 words, casual chat style, no markdown formatting, no @ "
        "mentions), 'reply_to' (the 0-based index of an earlier turn this "
        "one is a direct reply to, or -1 if it just continues the "
        "conversation), 'thread_root' (true only on a turn that spins off "
        "a short side conversation other turns later join), 'in_thread' "
        "(the index of the turn with thread_root true that THIS turn "
        "replies inside, or -1 if this turn is not part of a side "
        "conversation), and 'reactions' (0 to 2 entries, each with an "
        "'emoji' and a 'reactors' list of 1 to 3 OTHER participants' "
        "names who reacted with it - never the speaker's own name). Vary "
        "the length and tone of 'text' - some short one-word replies, "
        "some longer ones, the way real friends actually type. Include at "
        "least one turn with thread_root true and at least 3 later turns "
        "whose in_thread points at it, so that side conversation has real "
        "depth. Have people address each other by name sometimes, the way "
        "friends do." + _SAFETY_NOTE)


def _log(message):
    print(f"seed-ollama: {message}", file=sys.stderr)


def _cache_path(model, seed, cache_dir, kind="corpus"):
    safe_model = "".join(c if c.isalnum() else "-" for c in model)
    key = hashlib.sha256(f"{kind}:{model}:{seed}".encode()).hexdigest()[:16]
    return os.path.join(cache_dir, f"{kind}-{safe_model}-{key}.json")


def _request(base_url, model, prompt, schema, timeout):
    body = {"model": model, "prompt": prompt, "stream": False,
            "think": False, "format": schema}
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}/api/generate", data=json.dumps(body).encode(),
        method="POST", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as res:
        payload = json.load(res)
    return json.loads(payload["response"])


def _fetch_conversation(base_url, model, participants, topic, turn_count, timeout):
    """The raw `turns` array for one conversation - not yet validated as
    usable; see `seed_conversation.parse_conversation` for that."""
    prompt = _conversation_prompt(participants, topic, turn_count)
    parsed = _request(base_url, model, prompt, _CONVERSATION_SCHEMA, timeout)
    turns = parsed.get("turns")
    if not isinstance(turns, list):
        raise ValueError("response had no usable 'turns' array")
    return turns


def _reachable(base_url, model):
    """A quick, short-timeout check, so an outage fails fast rather than
    waiting out several full generation timeouts in a row."""
    try:
        req = urllib.request.Request(f"{base_url.rstrip('/')}/api/tags")
        with urllib.request.urlopen(req, timeout=_PROBE_TIMEOUT) as res:
            tags = json.load(res)
    except Exception as exc:  # noqa: BLE001 - unreachable is exactly what this checks for
        _log(f"could not reach {base_url}: {exc}")
        return False
    names = {m.get("name") or m.get("model") for m in tags.get("models", [])}
    if model not in names:
        _log(f"model {model!r} is not pulled on {base_url}")
        return False
    return True


def _conversation_cache_seed(seed, requests):
    """The seed plus a digest of the request list, so a different cohort or
    volume under the same seed is its own cache entry."""
    digest = hashlib.sha256(
        json.dumps([[t, list(p), n] for t, p, n in requests]).encode()
    ).hexdigest()[:12]
    return f"{seed}-{digest}"


def _is_conversation_list(data):
    return isinstance(data, list) and all(isinstance(c, dict) for c in data)


def _load_json_cache(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _save_json_cache(path, data):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
    except OSError as exc:
        _log(f"could not write cache: {exc}")


def load_or_generate_conversations(model, seed, requests, *,
                                    base_url=DEFAULT_BASE_URL,
                                    cache_dir=CACHE_DIR,
                                    timeout=_REQUEST_TIMEOUT):
    """One raw, not-yet-validated conversation per `(topic, participants,
    turn_count)` triple in `requests` - each request names its own turn
    count, since `seed_conversation.py` varies conversation length to hit a
    volume target rather than asking for a uniform size every time.

    Never raises: an unreachable server, a missing model, one bad
    conversation, or every single one failing all answer `[]` (logged to
    stderr), which tells `seed_conversation.py` to fall back to the canned
    corpus instead. A single bad topic does not sink the others - each is
    its own `_request` call, isolated the same way the pooled corpus
    isolates one pool's failure from the rest.
    """
    path = _cache_path(model, _conversation_cache_seed(seed, requests),
                       cache_dir, kind="conversations")
    cached = _load_json_cache(path)
    if cached and _is_conversation_list(cached):
        _log(f"using cached conversations at {path}")
        return cached

    if not _reachable(base_url, model):
        return []

    total = len(requests)
    run_start = time.monotonic()
    raw_list = []
    for index, (topic, participants, turn_count) in enumerate(requests, start=1):
        _log(f"generating conversation {index}/{total} "
             f"({turn_count} turns, {len(participants)} speakers)...")
        call_start = time.monotonic()
        try:
            turns = _fetch_conversation(
                base_url, model, participants, topic, turn_count, timeout)
        except Exception as exc:  # noqa: BLE001 - one bad topic must not sink the rest
            elapsed = time.monotonic() - call_start
            _log(f"conversation {index}/{total} about {topic!r} failed "
                 f"after {elapsed:.0f}s: {exc}")
            continue
        elapsed = time.monotonic() - call_start
        _log(f"conversation {index}/{total} done in {elapsed:.0f}s "
             f"({len(turns)} turns)")
        raw_list.append({"topic": topic, "participants": list(participants),
                          "turns": turns})

    if not raw_list:
        _log("no usable conversation came back from the model; "
             "falling back to canned content")
        return raw_list

    _log(f"generated {len(raw_list)}/{total} conversations in "
         f"{time.monotonic() - run_start:.0f}s total")
    _save_json_cache(path, raw_list)
    return raw_list
