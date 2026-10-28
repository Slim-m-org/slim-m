# 0092 - Server hardening review answers

Status: accepted
Date: 2026-10-26
Extends: 0048 (TOTP two-factor)

## Why this exists

The server hardening review (PR 1571) raised seven questions that needed an owner call.
This record holds the owner's answer to each, with the reasoning.

## Changed

### Peer moderation is refused (question 3)

The owner chose to make equal-rank peers off limits.
A moderator can no longer kick, remove, time out or rename a member whose granted permissions equal their own.
The reasoning is that two people with the same powers should not be able to silence each other.
An administrator is exempt, because their grant contains every bit and nobody ranks above them.
Role management and voice kicks keep the original containment rule.
The refusal is a 403 with the reason `you cannot act on someone of equal rank`.

### Changing the TOTP policy needs the admin's own factor (question 5)

The owner chose to require the acting admin to have a confirmed second factor before they change the TOTP policy.
The reasoning is that an admin who turns the policy on without a factor locks themselves out of every admin route until they enrol.
Bots are exempt, as they are everywhere else the policy is enforced.
A request that leaves the policy at its current value is not affected.
The refusal is a 403 with the reason `turn on two-factor sign-in on your own account before changing the two-factor policy`.

## Accepted as current behaviour

### Forwarded message origin ids (question 1)

A forwarded message keeps the origin channel id and message id, even for a channel the reader cannot see.
The reasoning is that the ids are random UUIDs that grant no access, and hiding them per reader adds a code path for little value.

### Familiar devices (question 2)

The sign-in alert keeps testing the client-supplied device name and client kind.
The reasoning is that the alert is a hint to the account owner, not a gate, and a server-side fingerprint would add tracking for the same hint.

### Moderators in the TOTP policy scope (question 4)

Enforcement of `required_for_elevated` stays on ADMINISTRATOR only, as decision 0048 says.
The reasoning is that moderators cannot reach settings or account recovery, and widening the scope would lock out moderators who have not enrolled.
The settings copy should say "administrators" and not imply moderators.

### Retry-After on 429s (question 6)

The TOTP-locked and ephemeral-budget 429s keep sending no Retry-After header.
The locked response already carries an `until` value, and the client shows its own wait wording.

### A code for the second-factor 403 (question 7)

The second-factor 403 keeps its message as the only signal.
The client matches the message for the refusals above and shows a plain sentence, so no wire code is added for now.
