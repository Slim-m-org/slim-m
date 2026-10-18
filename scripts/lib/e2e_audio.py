# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Measured audio and video for the voice scenarios.

`AudioProbe` installs e2e_audio_js.PROBE before the app boots and reads back
what a listener would hear. The page has to be reloaded once for the probe to
see the app's own AudioContext, which `Client.come_back` already does.
"""
import contextlib
import json
import time

import e2e_audio_levels as lv
import e2e_audio_js

# One sampling window; the in-page sampler runs every 50 ms.
SAMPLE_SECONDS = 0.05


def _wait_for_document(client, probe_present, timeout=60):
    """Wait for the reloaded document to have (or not have) the probe in it."""
    deadline = time.time() + timeout
    want = "true" if probe_present else "false"
    while time.time() < deadline:
        if str(client.ev("!!window.__e2eAudio")).lower() == want:
            return
        time.sleep(0.25)
    raise AssertionError(
        f"{client.name}: the reloaded page "
        f"{'lacks' if probe_present else 'still has'} the audio probe")


def install(client, extra=""):
    """Run the probe at the start of every document this page loads.

    `extra` is more script to run after it (the raw-capture control arm).
    Reloads so the app boots with the probe already in place, and returns the
    script identifier [uninstall] needs. Use [installed] on a browser that
    outlives the scenario.
    """
    client.send("Page.enable")
    added = client.send("Page.addScriptToEvaluateOnNewDocument",
                        {"source": e2e_audio_js.PROBE + extra})
    client.send("Page.reload")
    _wait_for_document(client, True)
    client.enable_semantics()
    return added["result"]["identifier"]


def uninstall(client, identifier):
    """Take the probe out again and reload, so later scenarios run unwrapped."""
    client.send("Page.removeScriptToEvaluateOnNewDocument",
                {"identifier": identifier})
    client.send("Page.reload")
    _wait_for_document(client, False)
    client.enable_semantics()


@contextlib.contextmanager
def installed(client, extra=""):
    """The probe for one scenario; removed afterwards without masking its error."""
    identifier = install(client, extra)
    try:
        yield
    finally:
        try:
            uninstall(client, identifier)
        except Exception as err:
            print(f"  could not remove the probe from {client.name}: {err}")


class AudioProbe:
    def __init__(self, client):
        self.client = client

    def now(self):
        return self.client.ev("window.__e2eAudio.now()")

    def listening(self):
        """Every remote audio element: stream id, mute, volume, gain graph."""
        return json.loads(self.client.ev(
            "JSON.stringify(window.__e2eAudio.listen())") or "[]")

    def senders(self):
        return json.loads(self.client.ev(
            "JSON.stringify(window.__e2eAudio.senders())") or "[]")

    def videos(self):
        return json.loads(self.client.ev(
            "JSON.stringify(window.__e2eAudio.videos())") or "[]")

    def inbound_frames(self):
        """Frames decoded so far by each inbound video, keyed by stats id."""
        stats = json.loads(self.client.ev(
            "JSON.stringify(window.__e2eAudio.inboundVideo())") or "{}")
        return {k: v["frames"] for k, v in stats.items()}

    def getusermedia_calls(self):
        return json.loads(self.client.ev(
            "JSON.stringify(window.__e2eAudio.gum)") or "[]")

    def series(self, stream_id, since):
        """`[(seconds, effective_db, pre_gain_db)]` for one stream since `since` ms."""
        raw = self.client.ev(
            "JSON.stringify(window.__e2eAudio.since(%s, %s))"
            % (json.dumps(stream_id), json.dumps(since)))
        rows = json.loads(raw or "[]")
        lv.refuse_unplayed(rows, self.client.name, stream_id)
        return [(t / 1000.0, lv.rms_to_db(eff), lv.rms_to_db(pre))
                for t, eff, pre, _ in rows]

    def measure(self, stream_id, seconds):
        """Listen for `seconds`, returning the effective-level series."""
        start = self.now()
        time.sleep(seconds)
        return self.series(stream_id, start)

    def stream_of_track(self, track_sid):
        """The stream id of the audio element playing SFU track `track_sid`."""
        for entry in self.listening():
            if entry["element"].endswith(track_sid):
                return entry["stream"]
        return None

    def stream_ids(self):
        return [e["stream"] for e in self.listening()]

    def wait_for_streams(self, count, timeout=45):
        """Wait until `count` remote audio streams are playing, returning them."""
        deadline = time.time() + timeout
        found = []
        while time.time() < deadline:
            found = self.listening()
            if len(found) >= count:
                return found
            time.sleep(0.5)
        raise AssertionError(
            f"{self.client.name}: expected {count} remote audio stream(s), "
            f"found {len(found)}: {found}")


def level_of(samples, which=1):
    """Median level of a series, `which` 1 = effective, 2 = before the gain."""
    values = sorted(s[which] for s in samples)
    if not values:
        raise AssertionError("no samples: the stream produced nothing to measure")
    return values[len(values) // 2]


def speech_level(samples, which=1):
    return lv.percentile([s[which] for s in samples], 95)


def floor_level(samples, which=1):
    return lv.percentile([s[which] for s in samples], 10)


def heard_while_audible(samples):
    """Loudest effective level over windows where the source was audible."""
    leak = lv.loudest_heard_db(samples)
    if leak is None:
        raise AssertionError("the source never became audible to measure against")
    return leak
