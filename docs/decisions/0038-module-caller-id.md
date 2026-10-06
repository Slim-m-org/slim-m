# 0038 - A module is told an opaque caller id and nothing else

Status: accepted
Date: 2026-09-28

## The ask

Found by building a live poll as a module.
"One vote per person" cannot be written when the plain `run` request is only `{command, input}`.
The module cannot tell one person tapping twice from two people tapping once.

## What was unclear

[0023](0023-mediated-host-capabilities.md) describes a call context: module, space, invoking user, channel.
That context belongs to the deferred `host_call` path, not to `run`.
No record said so, and "a module knows nothing about who is asking" was an assumption rather than a written rule.

## Decision

The request a module receives gains one additive field: `caller: { "id": "<hex>" }`.

- The id is `HMAC-SHA256(key, "slim-module-caller-v2" NUL module_id NUL user_id)` in lowercase hex, where `key` is derived from the deployment's identity secret and never leaves the server.
  It is stable per person per module, so a module can dedupe against itself.
  It differs between modules, so two modules cannot be joined up to follow one person.
  It is not the user id, and the user id is not recoverable from it.
  It was first shipped unkeyed; see "Amended 2026-09-30" below for why that did not deliver the two lines above.
- Nothing else is added: no display name, no channel, no space, no roles, no permissions.
  A module only runs when the caller holds its permission, so that answer is always yes and carries no information.
- No manifest capability gates it.
  A capability exists to bound power, and an opaque id grants none: it cannot act, read or spend anything.
  Gating it would make every module declare something to receive a value that grants nothing.
- The ABI stays v1.
  The field is additive, a module that ignores it keeps working, and modules are told to ignore unknown fields.

## What this deliberately does not do

- A module still cannot act as the caller.
  That stays [0023](0023-mediated-host-capabilities.md) Phase D territory, behind review, rate limits and permission checks.
- The channel is not sent.
  The generic run route has no channel, and a channel would be a second identifier a module could correlate with.
  If a real module needs it, that is a new record.
- Per-viewer scene state stays unsupported.
  A scene `state` is the same for every viewer, so hidden-information games are out of scope.
  `kv.store`, once enforced, is the place for a module's own secrets.

## Consequences

- The id is keyed by a secret derived from the server identity, so it changes if that identity is ever regenerated.
  Nothing regenerates it today, and a client that pinned the old fingerprint would refuse the deployment long before a module noticed.
- Deleting and recreating an account gives a new user id and so a new caller id.
- Existing modules are unaffected.

## Amended 2026-09-30

The id shipped as a bare `sha256` of the module id and the user id, on the reasoning that somebody who already knew both learned nothing by computing it.
That reasoning looked at the wrong direction.
A module id is public in the registry and every member can list every user id, so a module author hashes the member list once and has the person behind each id it was handed, and the same table links one person across every module.
An audit did exactly that against a running deployment and recovered a member's user id from the id a module echoed.

So the id is keyed now, with a key derived from the identity secret for this one purpose, which is what "opaque" needed all along.
The cost named above was that a key makes ids change on rotation; the identity secret does not rotate, so that cost is theoretical.
The real cost is one-off: every caller id changed once when this deployed, so a module that had stored state against the old ids no longer recognises those people.
No module in the registry declared `kv.store` at the time, and a poll left open across the deploy could be voted on a second time.

## Amended 2026-10-06

A module has no clock and no random source, and the request was a pure function of what the person typed, so `/roll d20` gave the same number to everyone every time.
The caller id cannot fix that: it is stable per person by design.

So the request gains a second additive field, `entropy`: 16 random bytes as 32 lowercase hex characters, fresh for every run.

- It is drawn from the operating system's random source on the server, so it carries nothing about the person, the channel or the deployment.
  It is not stable, so it cannot be used to dedupe or to follow anyone.
- It is for variation only: a module that wants a random number mixes it into its seed.
  A module that wants reproducible output ignores it, and a module built before it existed keeps working.
- The ABI stays v1, for the same reason the caller id did: the field is additive and modules are told to ignore unknown fields.
- Nothing is gated, since a random value grants no power.

A host that replays a run to check it would see a different value and, for a module that uses it, a different answer.
Nothing replays runs today, and a module whose answer must be checkable should keep its state in `input` instead.
