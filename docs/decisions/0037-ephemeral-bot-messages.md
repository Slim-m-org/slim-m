# 0037 - Ephemeral bot messages

Status: accepted, implemented
Date: 2026-09-28

## The ask

The owner, 2026-09-24: "when we @ them it sends a visible only to us message about how to use the bot and its commands".
The help card for that is rendered on the device (decision 0031).
This record is the general primitive that 0031 deliberately left out: a bot answers one member, and nobody else sees it.

It also serves the standing brief for the bots, "these bots need to have safeguards but i dont want to limit their feature sets".
Today a bot that refuses a command has to refuse it in public.

## What it is

`POST /channels/{channelId}/ephemeral-messages`, bot-only, body `{ in_reply_to_id, content }`.
The server publishes one `Event::EphemeralMessage` and stores nothing.
Delivery is the live frame `message.ephemeral`, to the recipient's own sockets only.

## Decisions

### Nothing is stored

An ephemeral message is never a row.
It is not in `messages`, so it cannot appear in a history page, in search, in `/sync`, in pins, in a thread, in a retention sweep or in an export.
There is nothing to purge on account deletion, and nothing to leak.
The cost is that it is gone on reload, on a server restart and while the recipient is offline.
That is how Discord behaves too, and it is the reason the primitive is cheap enough to be safe.

### No seq

It takes no `seq` and does not touch the channel's counter.
The alternative, taking a `seq` and leaving a gap for everyone else, is what the resync logic reads as loss.
`tests/ephemeral_messages.rs` sends a message, a private answer and another message, and asserts the two real messages are seq 1 and 2.
The client keeps ephemeral messages in a list of their own and merges them into the transcript by time, so nothing has to order them against a numbered stream.
Its id is a UUIDv7, used only to dedupe and to dismiss.

### Addressing: a message that was aimed at this bot

The recipient is not a parameter.
It is the author of `in_reply_to_id`, and that message (the anchor) must be all of these:

- live, in this channel, and no more than 15 minutes old (`ephemeral::ANCHOR_WINDOW_MS`);
- authored by a person, not by a bot, not by the caller, and not by a deleted account;
- addressed to the calling bot, meaning at least one of: it mentions the bot (`message_mentions`), it replies to a message the bot wrote, or its text starts with the bot's registered prefix followed by one of its registered command names (decision 0031, compared case-insensitively, whole word).

This is the addressing model 0031's advertisement design leaves us with: the server has no interaction, so the nearest thing to "in response to that member's own command" is the message that carried the command.
The recipient cannot be forged.
A bot cannot cold-message a member, because a member who never addressed it has no anchor.
A bot cannot hold a private channel open by re-anchoring to an old message.
The checks are in `http/ephemeral_anchor.rs`, and every failure is the same 403 (or 404 for an unknown or other-channel message), so the route does not say which of them failed.

Residual gaps, stated plainly:

- A mention is read from `message_mentions`, which also holds the expansion of `@everyone` and `@here`.
  A person who holds `MENTION_EVERYONE` and uses it makes their message an anchor for every bot that can view the channel.
  That is a deliberate, public act by someone with a moderator-grade permission, and it is left in.
- A bot that is addressed once can send three private messages to that one person, so a hostile bot the person did talk to can still phish them there.
  The badge below and the per-anchor budget are the mitigation, and revoking the bot is the control.
- The prefix check reads the message text with the registered prefix and command names, so a bot that parses commands some other way than its registration says will be refused unless the message also mentions it.

### Per-anchor budget

A bot may send at most three private messages per anchor (`ephemeral::MAX_PER_ANCHOR`), and the fourth is a 429.
The count is `Hub::ephemeral_budget`, kept in memory and keyed by (bot, anchor).
An entry expires when the anchor's window closes, and expired entries are swept once the map holds more than 256, so it is bounded by the anchors still in the window.
It is charged only after every other check has passed, so a refused call costs nothing.
A restart forgets it, which at worst gives a bot another three messages on an anchor that is still inside its window.

### Bot badge on the row

The author's name is whatever the bot's display name is, so a bot can call itself "System" or "Admin".
The client draws the `Bot` badge next to the name on every private-answer row.
The server guarantees the author is a bot, which is why the frame carries no flag and the row always shows it.
The badge is fixed-size beside a name that ellipsizes, so a long name cannot push it off the line.

### Button clicks reuse the same fan-out

The follow-on card (buttons on bot messages) will hand the owning bot a click event carrying the clicker.
A private reply to a click is the same primitive with a different anchor: the anchor becomes the interaction, and the recipient is the clicker.
The delivery path, the frame, the client row and the library method do not change.
Only the resolver that turns an anchor into a recipient grows a second case: `ephemeral_anchor.rs` returns an `Anchor` (an id for the budget, the recipient, and an expiry), and an interaction would add a resolver beside `resolve_message`.
That is why the recipient is derived from an anchor in one place rather than accepted from the caller.

### Who may send

Only a bot.
It needs `VIEW_CHANNEL` and `SEND_MESSAGES` in the channel, the same as a public reply, so a bot muted in a channel is muted there privately too.
The recipient must still hold `VIEW_CHANNEL`.
Every refusal that depends on another account's state is the same 403, so the route is not an oracle for who can see a channel.
It is metered as an ordinary write (`Class::Write`), and by the per-anchor budget above.

### Who receives it

`http::ws::ephemeral_frames::authorize` decides per connection.
It delivers only when the connection's user is the recipient, still holds `VIEW_CHANNEL`, and has not blocked the bot.
A store error withholds: the message has no catch-up path, so failing closed loses nothing that could be recovered.
Other administrators receive nothing, including accounts with `ADMINISTRATOR`, and the bot's own sockets receive nothing.
A recipient who blocked the bot still gets a 200 on the bot's side, so a bot cannot learn who blocked it.

It rides the ephemeral hub class.
The message goes on the same broadcast channel every subscriber reads and is withheld per subscriber, like a read-state marker.
A subscriber that lags past the channel capacity skips forward, so a private answer can be lost under a canvas storm.
That is acceptable for a message that is already lossy, and it is preferable to putting it on the durable channel, where a lag would close every connection over a message that could not have been recovered anyway.

### Moderation

Moderators cannot browse ephemeral messages, because nothing stores them.
The controls that bound a bot are still the ones that exist: revoke its token, remove it from the space, or take its permissions away.
A member can block the bot to stop receiving them.

A recipient can also report one.
`POST /reports` takes `subject_kind: ephemeral_message` with the private message's id, the channel, the bot's id and the text the client showed.
That report goes through the ordinary queue, and a moderator sees the text and the bot where they would see a message report's snapshot and author.
Nothing new is stored beyond a `reports.snapshot_author_id` column that holds the bot, because a stored message is what a report's author is normally joined from.

The server cannot check the text, so it is the reporter's word, and the queue card says so.
What it does check is that the reporter can view the channel and that the named author is a bot.
A member could therefore file a report that misquotes a bot.
That costs a moderator a look and no more, since a report changes nothing until a moderator acts on it, and the same member could as easily misdescribe a real message in the reason.
Keeping a short in-memory copy on the server to verify against was rejected: it would hold every private message for as long as the window is open, which is the exposure this record set out to avoid.
An old client reads the new kind as a user report, so it would show the bot's message id as a user with no name.

### Files and embeds

An ephemeral message may carry embeds and attachments, in the same request shape as `sendMessage`.
Embeds are built by the same code, so the caps and the image handling are the same, and the row renders them with the transcript's own embed widget.
Attachments ride by id and are never uploaded here.
Each id must already be fetchable by the bot and by the recipient, meaning uploaded by them or attached to a message in a channel they can view.
Anything else is one 400 that does not say which side failed.
The reason is that nothing here can make a file fetchable: the fetch route reads message links, an unattached upload is swept after a day, and storing a link for a private message would make it a stored message.
So a bot can privately re-show a file that is already in the channel, and cannot privately send a new one.
A message may be only an embed or only files, with empty text, and the bot needs `ATTACH_FILES` to send any.
A refused call spends none of the per-anchor budget.

### Client

The client keeps them in memory, per channel, and draws each one in the transcript.
Each is a normal row from the bot, with the same avatar, name, time, text, embeds and files.
It carries a subtle tint, a line reading "Only you can see this", and Dismiss and Report actions.
The `Bot` badge is always drawn, because the server guarantees the author is a bot.
A row is placed by its server `created_at`, after the last stored message at or before that time, so a reply to a command lands right under it.
It never joins a stored message's group, and a continuation marker never runs into it.
A reader at the bottom sees a new one arrive like any new message.
Screen readers announce "Only you can see this" and then the content.
This replaces the tray above the composer, which stacked up to three cards that never expired.
There is no cap now, because the per-anchor budget above already bounds what a bot can send.
The rows are never written to the local store.
They survive leaving and re-entering the channel and are cleared at sign-out.

## Library

`slimbots` gets `ctx.reply_ephemeral(text)` on a command context and `bot.send_ephemeral(channel_id, in_reply_to_id, text)` on the client.
The canvas-board refusal is the first user.

## What this record does not decide

- Buttons and interactions.
  This record fixes only the private-reply half of them.
- Whether ephemeral messages should ever persist across a reload.
- Buttons on an ephemeral message.
