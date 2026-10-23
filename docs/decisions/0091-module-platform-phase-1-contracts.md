# 0091 - Module platform, phase 1 contracts

Status: accepted (design; implementation in v118)
Date: 2026-10-23
Extends: 0090 (modules as the extension surface), 0021, 0023

## Why this exists

Decision 0090 fixes what the module platform is.
This record fixes the exact shapes phase 1 builds, so slices built in parallel agree.
Everything here is additive: a module that uses none of it behaves as before.

## Manifest additions

All fields are optional.
A manifest that uses any of them declares `"addon_api": 1`.
A host that supports a lower `addon_api` refuses the module with a clear reason, and a host that does not know the field ignores it.

### Capabilities

Three new host capabilities, approved by the admin at install and asked again when a new build adds one, like `schedule`:

- `events` - receive pushed events.
- `data.store` - the structured data store.
- `log.read` - read durable logs with a cursor.

Slots and settings need no capability.
The consent screen shows each in plain words, including which events, which logs and the size cap.

### `subscriptions`

```json
"subscriptions": [{ "event": "voice.session.closed" }, { "event": "message.created" }]
```

At most 8 entries.
Phase 1 events:

| Event | `data` fields |
| --- | --- |
| `message.created` | `message_id`, `channel_id`, `author_id`, `content` (the stored text), `created_at_ms`, `is_bot` |
| `message.deleted` | `message_id`, `channel_id` |
| `reaction.changed` | `message_id`, `channel_id`, `emoji`, `count` |
| `member.joined` | `user_id` |
| `member.left` | `user_id` |
| `voice.session.closed` | `session_id`, `user_id`, `channel_id`, `joined_at_ms`, `left_at_ms`, `alone_ms` |

An event on a channel the module's principal cannot view is not delivered.
Direct message content is never delivered.

### `data`

```json
"data": {
  "max_mb": 8,
  "tables": [{
    "name": "xp",
    "columns": [
      { "name": "user_id", "type": "text", "unique": true },
      { "name": "xp", "type": "int", "index": true }
    ]
  }]
}
```

Column types are `int`, `real`, `text` and `bool`.
Limits: 8 tables, 16 columns each, `max_mb` at most 64 (default 8).
The host adds an integer primary key `_id` to every table.
Table and column names are 1 to 32 lowercase letters, digits or underscores, starting with a letter, and may not be an SQLite keyword (`key`, `index`, `order`, `values` and so on), `rowid`, `oid` or start with `sqlite`.
A newer manifest may add tables and columns and may not remove or retype one in the first version.

### `settings`

```json
"settings": [
  { "key": "xp_per_minute", "type": "int", "label": "XP per minute", "help": "Earned while in a call.", "default": 5, "min": 0, "max": 100 },
  { "key": "api_key", "type": "secret", "label": "API key" }
]
```

Types are `bool`, `int`, `string`, `choice` (with `choices: [{value, label}]`) and `secret`.
At most 32 entries, keys unique, label a few words, help one short sentence.

### `slots`

```json
"slots": [{ "kind": "profile.section", "name": "xp", "title": "Level" }, { "kind": "member.badge", "name": "level" }]
```

Kinds in phase 1 are `profile.section` and `member.badge`.
At most 4 entries.

## Event delivery

The host runs a consumer that subscribes to the hub, filters per module and queues per module.

- The queue holds 256 events per module and drops the oldest first, counting drops in `module_run_stats`.
- Delivery is a normal module run with `command: "@event"` and `input` set to the JSON text `{"event","id","at_ms","data"}`.
  No ABI change: a module that does not handle `@event` returns `{ok:false}` and counts as a failure.
- `id` is minted by the host and stable for the same occurrence: `message:<id>`, `voice-session:<id>`, `member-join:<user>:<ms>`.
- The run's `caller.id` is the module's principal, never the event's author.
- Events and schedules share their own lane of 2 concurrent runs, separate from the 4 slots members' commands use.
- A circuit breaker counts consecutive failed runs (trap, timeout, fuel, `ok:false`).
  At 5 the module is disabled with a stated reason the admin sees, and a success resets the count.
- Push is best-effort and may miss events across a restart.
  Code that must not lose data reads a durable log.

## Durable logs: `log.read`

One host call:

```json
{ "capability": "log.read", "log": "voice.sessions", "after": 0, "limit": 100 }
```

The reply is `{ "ok": true, "rows": [...], "next": 123 }`, where `next` is the cursor to send as `after` next time.
`limit` is at most 200.
Phase 1 has one log, `voice.sessions`, returning only closed sessions in id order:
`{ id, user_id, channel_id, joined_at_ms, left_at_ms, alone_ms }`.

## Voice sessions

Table `voice_sessions` (migration 0147): `id INTEGER PRIMARY KEY AUTOINCREMENT`, `user_id`, `channel_id`, `sid`, `joined_at` and `left_at` (milliseconds), `alone_ms`.
It is written beside the existing record call in the voice webhook handler, opened on a join and closed on a leave.
An open session is also closed on a room finishing, on the stale-heartbeat sweep and on startup, so a missed leave caps the duration.
Closed sessions are kept 90 days.
Account deletion removes a member's sessions.
Only a module with an approved `log.read` can read them, and the consent line says it can see when members are in calls.

## `data.store` host call

```json
{ "capability": "data.store", "op": "query", "table": "xp",
  "where": [{ "col": "xp", "op": "gt", "val": 100 }],
  "order": [{ "col": "xp", "dir": "desc" }], "limit": 10, "offset": 0 }
```

Operations:

- `insert` with `values`, or with `rows` for up to 50 rows.
- `upsert` with `values` and `on` (the unique columns), and optionally `add`.
- `update` and `delete` with `where`, and `update` with `values`, `add`, or both.
- `get` (first match) and `query` (rows).
- `count`, `sum` with `col`, and `increment` with `col`, `by`, `where`.

`where` is a list ANDed together with ops `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `like`.
Replies are `{ok:true, rows, changed, count}` or `{ok:false, error}`.
`count` and `sum` return their number in `count`, and `insert` returns `rows: [{_id}]`.
`upsert` takes a single unique column in `on`.
`add` is a map of `{column: number}` over `int` or `real` columns, and a column cannot be in both `values` and `add`.
An `upsert` with `add` is one atomic statement: a new row gets the added amounts, and an existing one gets `column = column + n`.
The other `values` columns of that upsert still update to the new value, and the reply returns the resulting row in `rows`.
An `update` with `add` runs `column = column + n` in the same statement as any `values`, so concurrent callers never lose an update.
`rows` on `insert` cannot be combined with `values`, every row must set the same columns, and the reply is `rows: [{_id}, ...]` in order.
All rows are validated first and written in one statement, so one bad row writes none.
A multi-row `insert` or an `add` is still one call of the run's budget.
A non-numeric or unknown `add` column, an `add` amount above 2^53, an empty or oversized `rows`, and `add` or `rows` on any other op are refused.
Limits: 64 calls per run (shared with `kv.store`, inside the 128 host calls of any kind a run may make), 200 rows per query, 4 KB per text value, and the file cap from `max_mb`.
The file is `<modules_dir>/<module id>.db`, where `modules_dir` is `SLIMM_MODULES_DIR` and defaults beside the main database.
Statements are built by the host, parameterised, and run on a connection that has `max_page_count` set.

## Settings

Values live in `module_settings` (migration 0149).
They are sent to the module on every run as `settings: {key: value}` in the wire request, with secrets left out.
A secret reaches a module only through `net.fetch`: a header value may be `{"secret": "<key>"}` and the host substitutes it for an approved host.
Routes, both behind `MANAGE_SERVER`:

- `GET /space/dock/modules/{id}/settings` returns the schema with current values, and for a secret only `{set: true|false}`.
- `PUT /space/dock/modules/{id}/settings` takes `{values: {key: value}}`, where `null` clears a value, and validates each against the schema.

## Slots: `slot/1`

The host asks a module for slot content by running it with `command: "@slot"` and `input` set to `{"slot","name","user_ids","viewer_id"}`, and `caller.id` is the viewer's.
The module returns `{"$slim":"slot/1","items":{"<user_id>":{ "nodes":[...], "fallback":"..." }}}`.
Responses are cached 30 seconds per module, slot, viewer and member, an empty answer included.
Routes, for any signed-in member:

- `GET /space/dock/slots/profile/{user_id}` returns `{sections:[{module_id, name, title, nodes, fallback}]}`.
- `GET /space/dock/slots/badges?ids=a,b,c` returns `{badges:{user_id:[{module_id, name, nodes, fallback}]}}`, with at most 100 ids.

Node vocabulary, closed and versioned:

| `type` | Fields |
| --- | --- |
| `text` | `text` (at most 120 characters), `tone` (`normal`, `muted`, `accent`) |
| `icon` | `name`, from the closed list the bot UI already uses |
| `badge` | `text` (at most 24), `icon`, `tone` |
| `progress` | `value`, `max`, `label` |
| `row` | `children` |
| `stack` | `children` |

At most 40 nodes and depth 4 per item.
A client that does not know a `type` skips that node, and shows `fallback` if every node was skipped.
Fields are only added, never repurposed.
There are no actions in phase 1.

## Order of work

1. Contracts: this record, the manifest parser, the capability and consent changes, the client wire models.
2. Voice sessions, the data store and settings values, in parallel.
3. The event consumer, the lane and the breaker.
4. The slot routes, then the client renderer, mounting and settings form.
5. The XP module in the add-ons repository as the end-to-end proof.
