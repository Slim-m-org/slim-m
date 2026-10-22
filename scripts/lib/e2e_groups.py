# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Which scenarios must share a stack, and how to deal the rest across several.

A scenario that leans on what an earlier one left behind (a message to react
to, a canvas to draw on, a call to leave) belongs to the same group as it and
runs after it on one stack. Groups share nothing with each other, so each can
run on a stack of its own, at the same time as the others.
"""
import json
import os

DURATIONS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "e2e_durations.json")
# What a scenario costs when no run has measured it yet.
UNKNOWN_SECONDS = 30
# The cost of a stack coming up, signing two browsers in and tearing down.
SHARD_OVERHEAD_SECONDS = 60

# (group, name prefixes); the first prefix a scenario starts with decides.
# A prefix naming a whole area ("canvas: ") keeps the area on one stack.
_RULES = [
    ("text", ("messaging: ", "composer: ", "emoji: ", "markdown: ",
              "moderation: ", "permissions: ")),
    ("settings", ("settings: ",)),
    ("admin", ("admin: ", "account: changing your password",
               "account: the push preview", "api: ", "reconcile: ")),
    ("usernames", ("account: usernames",)),
    ("canvas", ("canvas: ",)),
    ("call", ("voice: two clients in one call", "voice: audio actually",
              "voice: health ", "voice: sharing a screen",
              "voice: mute reaches", "voice: muting actually",
              "voice: the canvas dock", "voice: a shared camera tile",
              "voice: leaving", "voice: re-clicking")),
    ("dm-call", ("voice: calling in a dm", "voice: a call nobody answers")),
]


def group_of(name):
    """The group [name] belongs to; a scenario outside every rule is its own."""
    for group, prefixes in _RULES:
        if name.startswith(prefixes):
            return group
    return name


def load_durations(path=DURATIONS_FILE):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def units(names):
    """Names in running order, folded into [(group, [names])] by group.

    A group keeps the position of its first scenario and the order of its own.
    """
    order, members = [], {}
    for name in names:
        group = group_of(name)
        if group not in members:
            members[group] = []
            order.append(group)
        members[group].append(name)
    return [(group, members[group]) for group in order]


def deal(names, shards, durations=None):
    """[names] dealt across at most [shards] stacks, longest groups first.

    Greedy longest-processing-time: each group goes to the stack that is
    emptiest so far, which keeps the slowest stack close to the mean. Each
    stack keeps the global running order of what it was given.
    """
    durations = durations if durations is not None else load_durations()
    position = {name: i for i, name in enumerate(names)}
    weighted = sorted(
        ((sum(durations.get(n, UNKNOWN_SECONDS) for n in members), members)
         for _, members in units(names)),
        key=lambda item: -item[0])
    count = max(1, min(shards, len(weighted)))
    loads = [0.0] * count
    dealt = [[] for _ in range(count)]
    for weight, members in weighted:
        slot = loads.index(min(loads))
        loads[slot] += weight
        dealt[slot].extend(members)
    return [sorted(chunk, key=position.get) for chunk in dealt if chunk]
