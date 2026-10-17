# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The seven sounds, as contours over the shared timbre.

Each is a list of notes and nothing else: the timbre, envelope and loudness
all come from synth.py, so the only thing that distinguishes one sound from
another is its pitch contour, its note count and how long it rings. That is
the whole point of the family, and it is why these live as data here rather
than as seven scripts that each grew their own DSP.

The pitches are a pentatonic set, so any two sounds landing at once still
agree with each other. Join and leave are the same three notes in opposite
order, which is what makes them read as a pair rather than as two unrelated
events.
"""
from __future__ import annotations

from synth import Note

# A pentatonic ladder in Hz, roughly A4 up. Named so a contour reads as a
# shape rather than as a list of numbers.
A4, C5, D5, E5, G5, A5, C6, D6 = (
    440.0, 523.25, 587.33, 659.25, 783.99, 880.0, 1046.50, 1174.66,
)

# name -> (notes, what it is for). The description rides along because a
# sound file's name is the only documentation most people ever see.
SOUNDS: dict[str, tuple[list[Note], str]] = {
    "direct_message": (
        [Note(0.00, A5, 0.30)],
        "One note. A direct message is the single most personal event, so it "
        "gets the simplest sound in the set.",
    ),
    "mention": (
        [Note(0.00, A5, 0.26), Note(0.11, D6, 0.34)],
        "Two rising notes. A mention is a direct message with an edge, so it "
        "is the direct-message note plus a lift.",
    ),
    "group_message": (
        [Note(0.00, E5, 0.24)],
        "One note, lower and shorter than a direct message. The most frequent "
        "event in the set, so it is the least insistent thing that still "
        "registers.",
    ),
    "call_ring": (
        [
            Note(0.00, C5, 0.34), Note(0.16, G5, 0.40),
            Note(0.62, C5, 0.34), Note(0.78, G5, 0.46),
        ],
        "A repeating two-note figure. The only sound meant to be heard from "
        "another room, so it is the longest and the only one that repeats.",
    ),
    "member_join": (
        [Note(0.00, C5, 0.20), Note(0.09, E5, 0.20), Note(0.18, G5, 0.30)],
        "Three notes ascending. Someone arrived.",
    ),
    "member_leave": (
        [Note(0.00, G5, 0.20), Note(0.09, E5, 0.20), Note(0.18, C5, 0.30)],
        "The same three notes descending. Someone left. Mirrored on purpose "
        "so the pair is learnable without being told.",
    ),
    "error": (
        [Note(0.00, D5, 0.22), Note(0.10, A4, 0.34)],
        "Two notes falling a fourth. The only interval in the set that is not "
        "from the pentatonic ladder, so it is the only one that sounds wrong "
        "on purpose.",
    ),
}

# A system asset for CXProviderConfiguration.ringtoneSound, not one of SOUNDS.
CALLKIT_RINGTONE: tuple[list[Note], str] = (
    [
        Note(0.00, C5, 0.34), Note(0.16, G5, 0.40),
        Note(0.62, C5, 0.34), Note(0.78, G5, 0.46),
        Note(2.30, C5, 0.34), Note(2.46, G5, 0.40),
        Note(2.92, C5, 0.34), Note(3.08, G5, 0.46),
        Note(4.60, C5, 0.34), Note(4.76, G5, 0.40),
        Note(5.22, C5, 0.34), Note(5.38, G5, 0.46),
    ],
    "call_ring's own two-note figure, repeated three times with a real "
    "pause between each. CallKit loops a ringtone file on its own for the "
    "life of the incoming-call screen, so this is a standalone ring cadence "
    "rather than the one-shot in-app chime call_ring already is, and it is "
    "deliberately absent from SOUNDS above: it carries no in-app trigger of "
    "its own and so is exempt from the family's cross-sound loudness "
    "invariants and its exactly-seven count.",
)

# Quieter cues for the person's own actions, kept out of SOUNDS so its invariants stay about the seven.
UI_TARGET_LUFS = -26.0

# name -> (notes, seconds to pad to or 0, what it is for); padding is the ringback's pause.
UI_SOUNDS: dict[str, tuple[list[Note], float, str]] = {
    "message_sent": (
        [Note(0.00, G5, 0.14)],
        0.0,
        "One short note, higher than a received message so the two never read "
        "as each other.",
    ),
    "message_received_in_view": (
        [Note(0.00, E5, 0.12)],
        0.0,
        "The group-message note, shorter: the channel on screen needs a nudge, "
        "not a chime.",
    ),
    "self_join": (
        [Note(0.00, E5, 0.16), Note(0.08, G5, 0.24)],
        0.0,
        "Two rising notes: you are in the call.",
    ),
    "self_leave": (
        [Note(0.00, G5, 0.16), Note(0.08, E5, 0.24)],
        0.0,
        "The same two notes falling: you left the call.",
    ),
    "mute_on": (
        [Note(0.00, D5, 0.14)],
        0.0,
        "One low note: the mic is off.",
    ),
    "mute_off": (
        [Note(0.00, A5, 0.14)],
        0.0,
        "One high note: the mic is on.",
    ),
    "deafen_on": (
        [Note(0.00, E5, 0.12), Note(0.07, A4, 0.20)],
        0.0,
        "Two falling notes: you stopped hearing the call.",
    ),
    "deafen_off": (
        [Note(0.00, A4, 0.12), Note(0.07, E5, 0.20)],
        0.0,
        "Two rising notes: you hear the call again.",
    ),
    "ringback": (
        [Note(0.00, E5, 0.40), Note(0.30, E5, 0.40)],
        2.2,
        "A soft double pulse then a pause, looped while an outgoing call "
        "rings. Calmer than call_ring, which is for the person being called.",
    ),
}
