# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Reads the timing events and taps of the experience scenario into plain numbers (all in ms)."""
import voice_latency as lat
import voice_quality_dsp as dsp

RATE = 48000
FRAME = RATE // 100
AUDIBLE_DB = -50.0
ONSET_DB = -45.0
QUIET_BEFORE_S = 2.5
RING_WINDOW_MS = 4000.0


def _first(events, name, after, **match):
    for e in events:
        if e["n"] == name and e["t"] >= after and all(e.get(k) == v for k, v in match.items()):
            return e["t"]
    return None


def join_row(events, cold):
    """Click-to-state delays for one join; None where the state never came."""
    click = _first(events, "click", 0)
    out = {"cold": cold}
    for key, name, match in (("in_call_ms", "label", {"on": True}),
                             ("first_packet_ms", "first-packet", {}),
                             ("first_energy_ms", "first-energy", {})):
        at = _first(events, name, click, **match)
        out[key] = None if at is None else round(at - click)
    return out


def _levels(samples):
    return [dsp.rms_db(samples[i:i + FRAME]) for i in range(0, len(samples) - FRAME + 1, FRAME)]


def _ice(events, t_cut):
    seen = {}
    for e in events:
        if e["n"] in ("ice", "conn") and e["t"] >= t_cut:
            seen.setdefault(f"{e['n']}_{e['v']}_ms", round(e["t"] - t_cut))
    return seen


def resumed_after(series, t_back):
    """Times after t_back when packets flowed again, per peer connection.

    A connection's own count before the link came back is its baseline, so a
    rejoin's new connection, counting up from zero, resumes on its first packets.
    """
    base = {}
    for r in series:
        if r["t"] <= t_back:
            base[r.get("pc")] = r["packets"]
    return [r["t"] for r in series
            if r["t"] > t_back and r["packets"] > base.get(r.get("pc"), 0)]


def cut_row(samples, start, events, series, t_cut, t_back):
    """How a listener's call came back after the SFU's egress was dead from t_cut to t_back."""
    levels = _levels(samples)
    stamps = [start + i * 10.0 for i in range(len(levels))]
    heard = [(t, lv) for t, lv in zip(stamps, levels) if lv > AUDIBLE_DB]
    during = sum(1 for t, _ in heard if t_cut + 500 <= t < t_back) / 100.0
    after = [t for t, _ in heard if t >= t_back]
    resumed = resumed_after(series, t_back)
    rejoined = any(e["n"] == "pc-new" and e["t"] >= t_cut for e in events)
    return {"outage_ms": round(t_back - t_cut),
            "audio_during_outage_s": round(during, 2),
            "time_to_audio_ms": round(after[0] - t_back) if after and not rejoined else None,
            "audio_tap_survived": not rejoined,
            "time_to_packets_ms": round(resumed[0] - t_back) if resumed else None,
            "rejoined": rejoined,
            "transport": _ice(events, t_cut)}


def speaking_row(samples, start, events):
    """Delay from each speech onset (after long quiet) to the ring lighting up."""
    levels = _levels(samples)
    quiet = int(QUIET_BEFORE_S * 100)
    onsets = []
    for i in range(quiet, len(levels)):
        if levels[i] > ONSET_DB and all(v < AUDIBLE_DB for v in levels[i - quiet:i]):
            onsets.append(start + i * 10.0)
    ring = [(e["t"], e["on"]) for e in events if e["n"] == "label"]
    delays, missed = [], 0
    for onset in onsets:
        before = [on for t, on in ring if t < onset - 100]
        if before and before[-1]:
            continue
        lit = [t for t, on in ring if on and onset - 100 <= t <= onset + RING_WINDOW_MS]
        if lit:
            delays.append(lit[0] - onset)
        else:
            missed += 1
    return {"onsets": len(onsets), "lit": len(delays), "missed": missed,
            "delay_ms": lat.summary(delays)}
