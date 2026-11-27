# Building a bot

A bot is a member of your Space with a long-lived credential, not a special kind of client.
That one sentence is most of what you need: everything a bot does, it does through the same REST and WebSocket API a person's client uses, with the same permissions model deciding what it may do.

There is no bot SDK to learn and no bot-specific protocol.
If you can make an HTTP request and open a WebSocket, you can write a bot.

See `docs/decisions/0028-bot-accounts.md` for why it is built this way.

Not sure whether your idea is a bot or a module? See `docs/decisions/0035-module-or-bot.md`.

## Getting a token

Space settings -> Bots, as somebody holding MANAGE_SERVER.
Give it a username - the same rules a person's follows, so the bot is mentionable the same way - and you get a token starting `slimbot_`.

**The token is shown once.** The server keeps only a hash of it, so it cannot be shown again.
If you lose it, use Re-issue token on the bot: the old token stops working at once and the bot keeps its messages and role.

A bot cannot create a bot, even one holding MANAGE_SERVER. Provisioning is a human act, so a single compromised credential cannot mint a second one that would survive revoking the first.

## What your bot may do

Nothing, at first.

A new bot holds exactly what `@everyone` holds in your Space and not one bit more.
To let it do something, give it a role on the roles screen, the same way you would a person.
It needs `SEND_MESSAGES` to talk, `VIEW_CHANNEL` to read a channel, `MANAGE_MESSAGES` to delete somebody else's message, and so on.

Per-channel overwrites apply too, so a bot can be allowed in one channel and not another without touching its roles.

A bot is exempt from nothing. Not slow mode, not message retention, not moderation.

## Authenticating

Exactly like any client:

```
Authorization: Bearer slimbot_...
```

Call `GET /me` first. It returns the bot's own id and its effective base permissions, which is the cheapest way to confirm the token works and to learn the id you will need to avoid answering yourself.
`GET /me` also lists the bot's roles (`roles`, `role_ids`, `role_colors`), the same fields `GET /users/{userId}` gives for anyone.
`GET /members/{userId}` is an alias of `GET /users/{userId}`.
`GET /me/permissions` returns the bitmask plus `names`, the name of every set bit, so a client needs no bit table; add `?channel_id=` to resolve them in one channel (a channel you cannot view reads as zero).

**Send a real `User-Agent`.** A deployment behind a CDN may refuse a default library user-agent before the request ever reaches slim-m, and what you get back is that CDN's 403 rather than anything from the API.
Python's `urllib` is the common case: `Python-urllib/3.x` is blocked by Cloudflare's defaults, and the same call with any named user-agent succeeds.
Name your bot there and the problem does not exist.

## Working over plain HTTP, without a WebSocket

An agent that signs in as a person, or a bot that never opens a socket, can do everything over REST.
Three things differ from a socket client.

**Refreshing.** `POST /auth/refresh` rotates the pair, and the access token it replaces keeps working for 30 seconds, so a request already in flight, or a second process sharing the session, does not fail when one of them refreshes.
Signing out, removing the device, changing the password and a detected refresh-token replay still end it at once.

**Telling a 401 apart.** The body keeps `error: "invalid credentials"` and adds a `code`.
`token_expired` means the access token lapsed, so refresh it.
`token_invalid` means it was never issued or has been revoked, so sign in again.
`bad_credentials` is a sign-in that did not verify.
The two token codes also send `WWW-Authenticate: Bearer error="invalid_token"`.

**Being present.** Presence normally comes from a live socket, and `PUT /presence/activity` is held against one, so a client with none is accepted and forgotten.
Send `PUT /presence/heartbeat` instead:

```
{ "status": "online", "activity": { "type": "playing", "title": "Chess" }, "ttl_seconds": 60 }
```

`status` is `online`, `away` or `dnd` (default `online`), `ttl_seconds` is 1 to 300 (default 60), and `activity` is optional.
While the heartbeat is unexpired you read as that status with that activity to everyone who can see your presence, and a change or the expiry reaches live viewers like a socket connecting or closing.
Send it again before the ttl runs out to stay present, and `DELETE /presence/heartbeat` ends it at once.
A durable `away`, `dnd` or `hidden` choice outranks the status you send, and a socket and a heartbeat together read as present until both are gone.
While a heartbeat is live, `PUT /presence/activity` applies to it too.

`GET /presence?ids=...` needs at least one id: asking for none is a 400, so an empty list always means nobody you asked about is present.

## Receiving events

Events come over the WebSocket, and getting on it is two steps:

1. `POST /auth/ws-ticket` with your token. It returns a single-use `ticket`.
2. Open `/ws`, then send a hello frame:

```json
{ "type": "hello", "ticket": "...", "protocol": 1 }
```

The server replies with its own `{"type":"hello","protocol":1}`, and after that the connection carries events.

You only receive what your permissions allow - fan-out is authorized per connection, so a channel your bot cannot view never reaches it.

A frame you do not recognise should be ignored, not treated as an error.
New event types are added over time, and a bot that dies on one it has never heard of breaks on somebody else's upgrade.

## Which events carry a `seq`, and what to do after a gap

Message events carry a per-channel `seq`, and `POST /sync` replays a channel from a `seq` you hold, so a bot that was offline can catch up on messages.
That is the only cursor there is for channel traffic.
Most other frames - presence, typing, voice, channel and profile changes, `member.joined` - carry none, and a reconnect does not replay them.
Refetch the state they describe instead.

The moderation events are the case where a hole matters most: `member.timeout`, `member.removed`, `member.restored`, `member.role_changed` and `role.changed`.
They reach every connection, but there is no route a bot can call to read back what it missed, because `GET /roles`, `GET /reports/history` and `GET /members/removed` are each behind their own permission.
So they carry a different, deployment-wide `seq`, and the server's `hello` reply carries the head as `moderation_seq`:

```json
{ "type": "hello", "protocol": 1, "moderation_seq": 1790000123456 }
{ "type": "member.timeout", "user_id": "...", "until": 1790000183456, "seq": 1790000123999 }
```

To keep an audit trail honest, persist the largest moderation `seq` you have seen, and compare it with `moderation_seq` on every reconnect.
If the head is larger, moderation events landed while you were away and your trail has a hole: say so in the log instead of presenting it as complete.
An event with a `seq` at or below the head can still arrive right after the `hello`, so a hole is only confirmed once the head is still ahead of everything you have received.

Two limits to plan around.
The number is a cursor, not a history: nothing can be replayed from it, and it is increasing but not consecutive, so you cannot count how many events were missed.
It is also clock-seeded, so the first reconnect after a server restart always reads as a possible gap, which is the safe direction.

Two shapes to know about:

- `member.role_changed` does not say whether the role was granted or revoked.
  Diff the member's current `role_ids` from `GET /users/{id}`, which any account can read.
- `role.changed` carries only the id, never the name.
  A role nobody holds cannot be resolved without MANAGE_ROLES, so log the id and say why the name is missing.

Timing out your own bot makes its next post return 403, because the timeout removes SEND_MESSAGES before you process the frame that announced it.
Catch the failure per frame rather than letting it end the connection, which would open a gap.

## Voice events

Three frames tell you who is on a voice call, live, without polling `GET /channels/{channelId}/voice/roster`:

```json
{ "type": "voice.participant_joined", "channel_id": "...", "user_id": "..." }
{ "type": "voice.participant_left", "channel_id": "...", "user_id": "..." }
{ "type": "voice.screen_share_changed", "channel_id": "...", "user_id": "...", "is_sharing_screen": true }
```

Authorized exactly like any other channel event: you only see one for a channel you can view, and never for a member who has chosen to appear offline.

**These only fire if the deployment's LiveKit is configured with a webhook pointed at the server** - see `docs/decisions/0032-voice-participant-webhooks.md`. A deployment that has not set that up sends none of the three; poll the roster instead if you need to work on both. `voice.activity` (a bare "something changed, go re-fetch" nudge with no `user_id`) keeps firing either way, so it is still the one signal every deployment gives you.

A "who is on this call right now" snapshot at any time - not just at connect - is still `GET /channels/{channelId}/voice/roster`, whose entries also carry `is_sharing_screen` and `has_video`.

If you are using a bot framework, this is the natural place for it to expose `on_voice_join` / `on_voice_leave` / `on_screen_share` callbacks built on top of these three frames; slim-m itself only guarantees the wire shape above.

## Canvas channels

A channel's `kind` is `text`, `voice` or `canvas`.
Read an unknown kind as `text`.
A canvas channel is a board with chat beside it, and an optional call.

Every channel object carries two computed booleans, the same for every reader:

- `canvas_enabled` - the channel has a board now. True for a canvas channel and a DM, the setting for a voice channel, false for text and threads.
- `voice_enabled` - the channel has a call. True for a voice channel and a DM, the setting for a canvas channel, false for text and threads.

A server that predates canvas channels sends neither. Read their absence as the old rule: voice and DM have a board and a call, text has neither.
`/version` has `canvas_channels: true` on a server that has them.

Create a canvas channel with `POST /channels` and `kind: "canvas"`, and `voice_enabled: true` for a call.
On a voice channel `canvas_enabled` is the board, and leaving it out means on, which is what bots written before this existed get.
Each flag is refused with a 400 on a kind it does not belong to.
`PATCH /channels/{channelId}` takes `canvas_enabled` (voice) and `voice_enabled` (canvas), and the channel manager bar.

Every board route of a channel with no board answers `403` with `{"code": "canvas_off"}`.
Do not retry it: the board is off, and someone who manages channels can turn it on in the channel's settings.

`PATCH /channels/{channelId}` with `{"discard_canvas": true}` removes everything on a voice channel's hidden board, locked objects included.
It needs `MANAGE_CANVAS` in that channel as well, and is refused while the board is on.
Everyone connected receives the usual `canvas.cleared` frame.

### Who has a board open

```json
{ "type": "canvas.viewer.changed", "channel_id": "...", "user_id": "...", "viewing": true }
```

Sent when a member starts or stops being shown as viewing a board: their first connection opens it, their last closes it, or they switch to or from Hidden.
It reaches every connection that can view the channel while its board is open, whether or not that connection has the board open.
Frames are batched, so at most one per member and board every half second.
A Hidden member's arrivals and departures send nothing, and turning a board off sends no frame: read the `channel.updated` that says the canvas is off.
Ignore a frame type you do not know.

`GET /presence/canvas-viewers` answers `{ "channels": [ { "channel_id": "...", "viewers": [ { "user_id": "...", "since": 1764000000000 } ] } ] }`.
It lists the open boards you can view that have anyone shown on them, each viewer ordered by `since`.
You always see your own entry, Hidden or not.
`/version` lists `canvas_viewers` in `capabilities` on a server that has it.

### Exporting a board

`POST /channels/{channelId}/canvas/export` with `{ "id": "<new channel id>", "name": "...", "category_id": "...", "voice_enabled": false, "clear_source": false }` copies a board into a new canvas channel.
It needs `MANAGE_CHANNELS`, the draw bits on the source and, with `clear_source`, `MANAGE_CANVAS` there.
`category_id` absent files the copy under the source's category, and null leaves it uncategorised.
The answer is `{ "channel": ..., "copied": 12, "skipped": 0, "cleared": 0, "spared": 0 }`.
`id` keys the whole request: send the same `id` when you retry and you get the first answer back, never a second copy or a second clear.
A connector that lost an end and a module tile whose module is not installed are left behind and counted in `skipped`; locked objects survive a clear and are counted in `spared`.
A board past the export ceiling answers `409` with `{"code": "canvas_export_too_large"}`, and one already being exported answers `409` with `{"code": "canvas_export_busy"}`: wait and try again.
Exports are limited to a few an hour.
`/version` lists `canvas_export` in `capabilities` on a server that has it.

### Reading a board over plain HTTP

A client with no socket can follow and inspect a board with four reads.
All of them need only `VIEW_CHANNEL`, the same as the viewport read, and answer `403` with `{"code": "canvas_off"}` on a channel with no board.

- `GET /channels/{channelId}/canvas/ops?after_seq=N&wait=25` holds the request open until an op after `N` exists, then answers the usual `{ops, latest_seq, has_more, reset}`.
  `wait` is whole seconds, clamped to 25 so a proxy or the server's own 30 second timeout never cuts it off.
  A page that already has ops, and a `reset`, answer at once; running out of time answers the empty page, so loop with the `latest_seq` you got back.
  A user may park only a few waits at once, and a further one answers `429`.
- `GET /channels/{channelId}/canvas/objects/{objectId}` answers one live object in the viewport's shape, and `404` for an unknown, removed or other-board id.
- `GET /channels/{channelId}/canvas/objects?ids=a,b,c` answers those live objects in the viewport's shape.
  It takes at most 100 ids, leaves unknown or removed ones out, and replaces the rectangle: sending it with `min_x` and friends, `prev_*`, `after_seq` or `cursor_seq` is a `400`.
- `GET /channels/{channelId}/canvas/summary` answers `{ "count": 12, "bounds": { "min_x": -40, "min_y": 0, "max_x": 900, "max_y": 600 }, "latest_seq": 31 }`.
  `bounds` is the box around every live object and is `null` on an empty board, so a bot can pick empty space without paging the world.

### Changing many objects at once

`POST /channels/{channelId}/canvas/ops/batch` with `{ "ops": [ ... ] }` takes 1 to 200 ops, each exactly what `POST /channels/{channelId}/canvas/ops` takes for `move`, `edit`, `remove` or `reorder`.
Tidying a board into columns is one request, and viewers get the moves one event at a time as if you had sent them singly.
The batch is all or nothing: one refused op rolls everything back, and the error carries that op's zero-based `item_index` and an `item_code` such as `locked` or `not_found`.
Every op needs its own UUIDv7 `id`, distinct within the batch, and retrying a whole batch answers with the stored ops (`fresh: false`) and sends nothing.
A batch is charged by op count against the same budget as the place batch, and a timed-out member can still send a batch of removes.
A `remove` op holds at most 64 ids, in a batch as singly, so removing more is several remove ops in one batch (up to the 200-op cap).

`edit` changes the props of a note, a text box, a connection, a shape or an image.
A shape's and an image's props merge: a key you leave out keeps its value and `null` deletes it.
The app draws a shape from `shape`, `flip_x` and `flip_y`, so a colour or a label you add is stored and sent on, and other clients may use it.
An image's `attachment` cannot be edited; place a new image for a different picture.

### Connections in a place batch

`POST /channels/{channelId}/canvas/objects/batch` takes `kind: "edge"` objects.
An edge resolves in array order against the board as the batch has built it, so each end is an object already on the board or one placed earlier in the same batch.
Put the notes first and the arrows after them: an end that is missing, in another channel or later in the batch is a `400` that names the edge's index.
An edge passes every check a single connection does, so an end that is a stroke is a `400` and an object with 64 connections already is a `409`.
A module tile is still placed on its own.

### Which permission was missing

A canvas `403` for a missing permission carries `"missing": ["manage_canvas"]` next to `error`.
It names `manage_canvas` for moving, editing, removing or clearing someone else's object (or clearing at all), and `use_canvas` for any canvas write by a member without it.
In a batch it sits beside `item_index` and `item_code`.
A channel you cannot view, a timeout and a locked object answer as before, with no `missing`.

### Note text size

A note's props are `text`, `fill`, `color`, `fill_opacity`, `size` (`small`, `medium` or `large`) and an optional `font_size`.
`font_size` is the text size in logical pixels at zoom 1, from 8 to 96, and is checked on place, batch place and edit; anything else is a `400`.
Send `null` in an edit to delete it.
Without `font_size` the app derives the size from the box: `min(w * 18 / 330, h * 18 / 210)`, so the 330x210 card is the box that draws 18 px text and a wide, short note draws small.
Set `font_size` to get a readable size in any box, or size the box like the reference card.
`size` still scales the result, whether the base came from `font_size` or from the box.

## Member join events

```json
{ "type": "member.joined", "user_id": "..." }
```

Fires on every real join: registration, and an existing account spending an invite code.
It does not fire when a removed member is let back in - that is `member.restored` instead, since they are not new.

This is deployment-wide, not gated on `VIEW_CHANNEL`: every connected session receives it, the same as `member.removed` and `member.restored`.
It carries only the id; call `GET /members` (or wait for your own roster cache to catch up) for the display name before you greet them.

This is the event a greeter bot listens for.
Post your welcome message from the handler rather than inferring a join from someone's first message or a presence frame - see `bots/greeter` in [slim-bots](https://github.com/Slim-m-org/slim-bots).

## Member leave events

```json
{ "type": "member.removed", "user_id": "...", "seq": 42 }
{ "type": "member.removed", "user_id": "...", "seq": 43, "deleted": true }
```

A removal can be undone with `member.restored`, so keep what you store for that member and stop acting for them.
`deleted: true` means the account itself was deleted, which cannot be undone.
Delete what your bot stores for them then: the server has already purged their personal data and anonymized what they wrote.

## Sending a message

```
POST /channels/{channelId}/messages
{ "id": "<a uuid you generate>", "content": "pong" }
```

The `id` is yours, and it makes the send idempotent within the channel: retrying with the same id returns the message already stored rather than sending twice.
So a retry after a timeout is safe.
Never vary the content between attempts under one id - the server replays what it first stored, whatever the retry carried.

### Quoting a member

A bot that re-posts or quotes a member's words can say whose they are with `repost_of_author_id` (a member's id) on the send.
The server then treats the message like that member's own for blocks: a viewer who blocked them does not see it and gets no push for it.
It is honoured only from a bot, a person's value is ignored, and an id that is not a live member is a 400.
A server that predates the field ignores it, so the message simply shows to everyone.
A post that quotes several members at once, such as a digest, cannot name one and is not covered.

Blocks do not stretch to a bot's own pings.
A message that mentions a member by name, such as the tickets bot's opening message naming the opener and the staff role, still reaches a staff member who blocked the opener; that is deliberate, because answering tickets is a staff duty.

## Answering privately

A refusal, a balance or a validation error does not have to be posted for everyone to read past:

```
POST /channels/{channelId}/ephemeral-messages
{ "in_reply_to_id": "<the message you are answering>", "content": "you need Manage Messages for that" }
```

Only the author of `in_reply_to_id` sees it, marked "Only you can see this", on every device they have open.
You do not name the recipient - it is that message's author, which is why you can answer a member who spoke to you and cannot message anyone else.
The message must be in that channel, from a person rather than a bot, no more than 15 minutes old, and addressed to you: it mentions you, replies to one of your messages, or starts with your registered prefix and one of your registered commands.
Anything else is a 403, so register your commands before relying on this for `!command` messages.
You get three private messages per anchor, and the fourth is a 429.

It is never stored.
It has no `seq`, never appears in a history page, in search or in `sync`, and is gone when the member reloads or dismisses it.
A member who is offline when you send it never sees it, so use it for answers to something they just did, not for anything they must not miss.
Moderators cannot browse it, but the member can report it, and the report carries the text they were shown and your bot.
A member who blocked you still gets a 200 back, so you cannot tell.

It may carry `embeds`, the same shape as on a message, and `attachment_ids`.
An attachment must already be visible to you and to the member, for example a file on a message in that channel, because a private message cannot make a new file fetchable.
Anything else is a 400, and `content` may be empty when either is present.

See `docs/decisions/0037-ephemeral-bot-messages.md`.

## Buttons

A message you send can carry buttons, so a member answers by pressing one rather than retyping a command:

```
POST /channels/{channelId}/messages
{
  "id": "<a uuid you generate>",
  "content": "Hit or stand?",
  "components": [
    { "buttons": [
      { "label": "Hit", "style": "primary", "custom_id": "hit" },
      { "label": "Stand", "style": "secondary", "custom_id": "stand" },
      { "label": "Rules", "style": "link", "url": "https://example.com/rules" }
    ] }
  ]
}
```

Styles are `primary`, `secondary`, `danger` and `link`.
A link button opens its `url` and never reaches you.
Every other button needs a `custom_id` you choose, unique within the message.
The limits are 5 rows, 5 buttons a row, an 80-character label and a 100-character `custom_id`.
Only a bot may send buttons; anyone else gets a 403.

When a member presses one, the bot that sent the message receives:

```json
{ "type": "interaction.created", "interaction_id": "...", "channel_id": "...", "message_id": "...",
  "custom_id": "hit", "user_id": "...", "user_display_name": "...", "created_at": 0 }
```

No other bot and no other member gets it.
Unlike a command advertisement it names who pressed, because you cannot answer a press without knowing.
Answer within 15 minutes, in any of three ways, and the presser's button stops waiting as soon as you do:

- `POST /channels/{channelId}/ephemeral-messages` with `interaction_id` set to the press's id, in place of `in_reply_to_id` (send exactly one of the two).
  Only the presser sees it, and you get three replies per press; the fourth is a 429.
- `PUT /channels/{channelId}/messages/{messageId}/components` to replace the buttons, for example to disable them.
  Pass `interaction_id` to say which press it answers.
  An empty list clears them.
- `POST /channels/{channelId}/interactions/{interactionId}/ack` when the press needs no visible answer.

A member's client shows the button as pending, and shows an error on that message if none of these arrives within about five seconds, so answer quickly and do slow work afterwards.
Presses are rate limited per member.
A press is best effort like typing: if you were offline, it is lost.

A submitted form arrives as the same frame with `kind` `form_submit`, the answers in `fields` and the press you opened the form on in `origin_interaction_id`.
A press accepts one submission, so you hear each form at most once.

See `docs/decisions/0039-bot-message-buttons.md`.

## Menu entries and call controls

`PUT /bots/ui` registers rows for a message's context menu and buttons for a call, replacing your whole previous set:

```json
{ "message_menu": [{ "id": "translate", "label": "Translate" }],
  "call_controls": [{ "id": "pause", "label": "Pause", "icon": "pause" }] }
```

At most 5 menu entries and 8 call controls.
A label is 32 characters and an id 64 of letters, digits and `-_.`.
An entry may name one `permission` bit; members without it neither see nor can use it.
`icon` is for call controls only: `play`, `pause`, `stop`, `skip_next`, `skip_previous`, `volume`, `volume_off`, `repeat`, `shuffle`, `list`, `settings` or `captions`.
Members see your menu rows under your name and a Bot badge, after the app's own rows, and your controls in a call only while you are on it.

Using one sends you the same `interaction.created` frame as a button, with `kind` set to `message_menu` or `call_control`, `custom_id` set to your entry id and the member's id and name.
A menu entry's frame has the `message_id` it was used on; a call control's has none.
Answer exactly as for a button: an ephemeral reply with `interaction_id`, or an ack.
Only a bot that registers entries ever receives these, but an older library will see the new `kind` field and a `message_id` that is absent for a call control, so read `message_id` with a default.
A call control is refused unless you are on that call, judged by your call heartbeat.

See `docs/decisions/0045-bot-contributed-ui.md`.

## Sharing a watch position

A bot running a watch party in a voice channel can tell the call where it is, so members see a title, a progress bar and the playing state.
It does not move anyone's video; the shared screen share is unchanged.

`PUT /channels/{channelId}/watch-session` states the session: `item_id`, `title`, `playing`, `position_ms`, and optionally `duration_ms` and `controller_user_id`.
Send it on a new title, a play, a pause or a seek, and set `seeked: true` for a seek so viewers resync rather than drift-correct.
The epoch changes on a new `item_id` or `seeked`.

A session belongs to a bot that is on the call.
Every write is refused with 403 unless you have a current call heartbeat in that channel, the same signal a call control uses.
`controller_user_id` must be a user who can view the channel, and it is a display hint only: it grants nothing.

`POST /channels/{channelId}/watch-session/tick` with `playing` and `position_ms` re-samples it.
Send one about every 5 seconds, paused or not.
It is the session's heartbeat: a session `ttl_ms` (30 seconds) without a write reads as ended, and so does one whose bot has left the call.
`DELETE` ends it, and so does leaving the call with `DELETE /channels/{channelId}/voice/heartbeat`.
Another bot may take a channel whose session is past that lifetime or whose owner is off the call; nobody else can end it.

Writes fan out as a `watch.tick` frame on the ephemeral channel, with no `seq`.
The frame names the session with `bot_user_id` and `epoch`, and carries `ended: true` when the session was ended.
The epoch is a millisecond timestamp: it changes on a new `item_id` or `seeked`, and never repeats across an end and a new session, so a viewer drops any tick for a lower epoch.
A late joiner or a reconnecting client reads `GET /channels/{channelId}/watch-session` instead, which also returns `server_time_ms` to work out how old the sample is and `ttl_ms` for how long it stays live.
PUT and tick share one rate class, so do not re-send the session faster than a tick.
The routes are for bots only.

See `docs/decisions/0050-watch-party-sync-authority-and-direct-play.md`.

## Registering your commands

Call this once you are connected, and again every time you reconnect:

```
PUT /bots/commands
{
  "prefix": "!",
  "commands": [
    { "name": "ping", "description": "check if I'm alive" },
    { "name": "roll", "description": "roll dice", "usage": "<sides>" }
  ]
}
```

This is a **bulk overwrite**, not an add: whatever you send replaces your whole prior registration, prefix included.
Send your complete set every time, even the commands that did not change - a command you leave out this time is gone, which is exactly what you want when you retire one.

Registering does not make the server run anything.
It only tells the composer what to offer: typing `/` lists your commands alongside everyone else's, and picking one inserts your own prefix and keyword - `!ping`, not `/ping` - as plain text.
That message arrives at your bot exactly the way `!ping` always has, whether or not you ever call this route.
**If you never register, your bot keeps working exactly as before** - this is additive, not a requirement.

A command can name a `permission` - one bit from the same set `GET /channels/{channelId}/permissions` returns.
**This only hides the row from someone who lacks it.** The server does not check it before your bot receives the message - anyone who can type in the channel can still send the raw text by hand.
If a command should really be restricted, check the sender's own permissions yourself before acting, the same as you always have.

Caps: at most 50 commands; a prefix is 1-16 characters with no whitespace, and cannot be `/`, `@` or `:` since the composer already uses those; a name is 1-32 characters of letters, digits, `-` and `_`, with no leading punctuation - the prefix supplies that; a description is 1-100 characters; `usage` is at most 80.
A registration that breaks any of these is refused whole - nothing partially applies.

Your commands disappear from discovery the moment your token is revoked or your bot is removed from the Space, with nothing else to do on your end.
They keep showing while you are offline: a live token is what discovery checks, not a live connection, the same way you can still `@mention` someone who is not online.

See `docs/decisions/0031-bot-command-registration.md` for the reasoning, including why this is advertisement rather than Discord's own interaction model.

## Answering yourself

A bot that posts in a channel it also listens to will see its own message arrive as an event.
Check the author against your own id from `GET /me` before answering, or the bot will talk to itself forever.

This is the single most common way a first bot goes wrong.

## When a token is revoked

Revoking closes the bot's WebSocket and makes the next REST call return 401.
It takes effect immediately, not at some expiry.

A 401 is therefore not something to retry: back off on a network error, but treat a 401 as "stop, the credential is gone".
The account itself stays, so everything the bot wrote stays attributed to it.

## When a bot is removed from the Space

Removal and revocation are different operations, aimed at different things.
Revoking a token is "stop trusting this credential"; removing a member is "take this account out of the Space", and it can be undone.

For a human, removing them revokes every session and undoing it does not bring an old one back - they sign in again and get a fresh one.
A bot has no sign-in to retry, so it gets different treatment: removing a bot revokes its token's session immediately (its next REST call 401s, same as a revoke), but restoring it un-revokes that same session, and its original token starts working again with no new credential to fetch.
That only applies to the token the bot still holds. If you revoked the bot's token yourself before it was removed, restoring the membership does not undo your revocation - the token stays dead and the bot needs a new one.

## The templates

[`bots/ping`](https://github.com/Slim-m-org/slim-bots/tree/main/bots/ping) in [slim-bots](https://github.com/Slim-m-org/slim-bots) is a working bot in one file: it answers `!ping` with `pong`.

```bash
pip install websockets
SLIMM_URL=https://your.space SLIMM_BOT_TOKEN=slimbot_... python3 bots/ping/bot.py
```

It does the five things above and nothing else, so it is short enough to read in one sitting.

It refuses to connect over plain `ws://` to anything but a loopback address.
A bot token is long-lived, so putting one on the wire in the clear is the one leak a bot cannot recover from - `http://localhost` is a developer's own machine, and anywhere else needs https.
What it deliberately leaves out, and what a bot doing real work needs:

- **A cursor.** It only sees what arrives while connected. A bot that must not miss anything records the `seq` on each event and calls `/sync` on reconnect to catch up.
- **Backoff.** It reconnects on a flat delay. Use exponential backoff against a real deployment.
- **Scoping.** It answers in any channel it can see. Most bots should be told which channels are theirs.

[slim-bots](https://github.com/Slim-m-org/slim-bots) has templates that do each of those: `bot-reminders` for durable state and a cursor, `bot-roles` for a command-driven flow, `bot-canvas-board` for driving the canvas, `bot-modlog` for watching moderation events.
Each one's readme says what it deliberately leaves out, which is usually the more useful half.

## Where a bot should live

Your own repository, deployed however you like.
A bot is an ordinary program that holds a credential; it does not go in the Space, and slim-m never runs it.

That is the difference between a bot and a **module**.
A module is sandboxed wasm that slim-m runs for you, with no network and no identity of its own - see [`docs/modules/building-modules.md`](../modules/building-modules.md).
Reach for a module when you want to extend the app's own surfaces (a command, a code-block runner, a drawing).
Reach for a bot when you want a program that acts on its own, on its own schedule, from somewhere else.
