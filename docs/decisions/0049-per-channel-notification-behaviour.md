# 0049 - a per-channel notification override decides the badge too

Status: accepted, 2026-09-30.

## The report

The owner, on the live deployment:

> "channels set to mention only still show badges, not sure if notification rules are working either, double check"

Both halves were real, and they were separate faults.

## What a per-channel override means

The owner settled the product question directly:

> "mention only should show nothing until a mention"

So an override is one rule, read by every surface rather than by push alone:

- **Mentions only.** Nothing at all until a mention: no dot, no count, no lifted
  label, no break-out from a collapsed category, no push, no chime, no desktop
  banner.
  The row looks exactly as it does when fully read.
  A real mention in it shows the mention badge, the same badge any other channel
  would show.
- **Muted.** Nothing at all, a mention included.
  The bell-off glyph on the row is the whole cue, and it is a state, not an alert.
- **Everything, or no override.** Unchanged.

A DM is the one exception, and it is the exception the server already made in
`push::recipients::narrow_for_notification_preference`: under `mentions`, a DM
stays loud, because somebody writing there is addressing this account directly.
Muting a DM still silences it.

The account-wide preference is deliberately not read for badges.
It is worded as which messages are worth waking a device for, and an account set
to `mentions` would otherwise have no unread indication anywhere in the app.

The reader's own hand-mark ("Mark as unread") is the one thing that still shows
through a mute.
It is a note somebody left themselves, not a notification an override was asked
to silence.

## Hiding an indicator is not marking anything read

The rule decides only what is drawn.
Read state underneath - `lastReadSeq`, `cursor`, `mentionedSeq`, the transcript's
own unread divider, what the read marker advances on scroll - is untouched, so a
quiet channel accumulates unread messages and clears them on open exactly as a
loud one does.
Opening a mentions-only channel still lands you at the right place in the
transcript.

This is why the rule lives in one pure function,
`providers/unread_indicator_rules.dart`, called at the point a row is built,
rather than anywhere in `slimm_data`'s read-state layer.
`rail_channel.dart`'s projection key stays deliberately broader than what is
drawn: it only decides whether the rail stream re-emits, and a re-emission that
turns out to draw nothing new is free, while a missed one is a stale rail.

## What was actually broken

1. Every rail surface derived unread straight from `cursor > lastReadSeq` and
   never consulted the override.
   Reproduced on a real stack: `#general` set to mentions only, an ordinary
   message from another account, and the row lit with a dot, a lifted label and
   an accessible name of "general, unread".
2. A muted channel leaked a mention: the bell-off glyph took the trailing slot
   so no diamond drew, but `AppListRow` still lifted the label and still
   announced "mentioned".
3. "Mark as unread" drew nothing at all.
   The server recorded `manually_unread = 1` and the local row held it, but the
   row widgets read only `cursor > lastReadSeq`; only the stream's dedupe key
   ever looked at the flag.
4. `desktop_message_notifier.dart` honoured a mute but not a mentions-only
   override, so the same message that was correctly denied a chime still raised
   a desktop banner. The push path had it right all along; the two foreground
   paths disagreed.
5. Server-side, a thread is its own channel row, so a preference lookup keyed on
   the message's own channel found no override and fell back to the account
   default. Muting a channel left every thread hanging off it loud.

Everything else about the rules already worked: the account default, the channel
override, quiet hours and the schedule allow-lists were all enforced for push,
in both directions, and the existing suites prove it.

## What this does not do

A collapsed category keeps its unread channels visible and its header shows an
unread dot (a diamond for a mention) when anything inside would light a row.
A muted channel does not count.
The owner, 2026-10-18: "unread messages within collapsed categories are not
visible, so if you get a notification for a channel in a collapsed channel you
cant find it since the collapsed category has no response to the unread
message".
This replaces the earlier line that held back any rollup and broke out only
mentioned channels.
No window or taskbar badge either, because the desktop shell has never had one.
Both stay out of scope here rather than being invented alongside a bug fix.
