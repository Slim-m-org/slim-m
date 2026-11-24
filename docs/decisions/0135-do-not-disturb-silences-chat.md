<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0135 - Do not disturb silences chat as well as calls

Status: accepted (owner, 2026-11-24)
Date: 2026-11-24
Extends: 0033 (notification schedule)

## The question

Do not disturb already stopped rings and voice notices.
Message, mention and `@everyone` pushes, chimes and desktop banners ignored it, so a member who picked the status was still woken by chat.

## Decision

A member on Do not disturb gets no message, mention or `@everyone` push, no chime and no desktop banner.
The server drops them first in `narrow_for_notification_preference`, ahead of the channel override, the account default and the schedule, so no preference can let a message through.
The client's `MessageAlertPolicy.evaluate` applies the same rule to the live chime and banner, so a device that is open stays quiet too.

What stays the same:

- Rings stay blocked, as decided before.
- Security alerts, such as a sign-in from a new device, still get through.
- Unread badges and counts are unchanged: the message is delivered and counted, only the alert is withheld.
- Nobody else sees a difference: presence is not changed by this rule.

## Why

The status is called Do not disturb, and members will rely on it.
Splitting it into "calls only" would need a label that says so, and nobody reads that label before they are woken.
A single rule applied at the server's one recipient choke point, and mirrored in the one client alert policy, is simple to test and to explain.
