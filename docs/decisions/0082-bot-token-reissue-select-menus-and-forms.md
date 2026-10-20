# 0082 - Bot token re-issue, select menus and forms

Status: accepted, implemented
Date: 2026-10-20

## The ask

Two cards from the 2026-10-18 discovery review.
An administrator who lost a bot's token could only revoke the bot and make another, which orphans its messages, role and username.
Message components were buttons only, so every real input was typed prefix syntax and choosers faked a select with up to 25 buttons.

## Token re-issue

`POST /bots/{botId}/token` revokes the bot's live token and session and mints a new pair in one transaction, and returns the token once, in the same `NewBot` shape `createBot` uses.
It works on a bot whose token was already revoked, which is the lost-token case, and refuses a bot removed from the Space with a 409: a removed bot gets its token back with the member.
It is audited as `bot_token_reissue` in the moderation history, written in the same transaction.
No migration: 0118 already dropped the audit action CHECK.
0028 said the token does not rotate, and that still holds for the bot itself.
This is an administrator's act, not a rotation the bot performs, so a dropped response costs one more click rather than a dead bot.
The Bots screen gets a "Re-issue token" action behind a confirmation, and shows the result in the same one-time reveal with "Copy env block".

## Select menus

A component row holds up to five buttons, or one `select`.
A select has a `custom_id` (unique among the message's ids), an optional placeholder, 1 to 25 options (label, value, optional description) and `min_values` / `max_values`.
Choosing is the existing press route with `values`: `POST /channels/{c}/messages/{m}/interactions` takes `values` for a select and refuses them for a button.
The server checks each value is offered, none twice, within the bounds.
The bot hears `interaction.created` with kind `select` and the `values`; nothing about the choice is stored.
Values ride the event only, so the interaction row still holds no content.

## Forms

A bot answers a press by opening a form: `POST /channels/{c}/interactions/{i}/form` with a title and one to five text fields.
That counts as answering the press, and the presser alone receives `interaction.form`.
The form is kept on the press row (migration 0141, which also widens the `kind` CHECK) so the submission can be checked against it.
A press opens at most one form.
The member submits with `POST /channels/{c}/interactions/{i}/submit`, a new idempotent interaction of kind `form_submit`.
The server fills every field, rejects unknown keys, empty required fields, overlong text and invisible characters, and the bot receives `fields`.
Only the member the form was opened for may submit it, and only while the press is inside its 15 minutes.

## Client

A select that picks one of at most eight options is the anchored menu (desktop-vs-mobile rule 2, a sheet under 600 wide through `ContextMenuRegion`).
A longer list, or a multiple choice, is a `showAppSheet` task with an explicit Choose (rule 4).
The form is a `showAppSheet` (rule 4) opened from the shell by `BotFormGate`, wherever the member is.
The sheet waits for the bot to answer the submission and closes on `interaction.answered`, and says so inline after about five seconds of silence.

## Library

`slimbots` 0.17.0 adds `Select`, `SelectOption`, `Form`, `FormField`, `interaction.values`, `interaction.fields`, `interaction.open_form`, and `@bot.select` and `@bot.form`, which route like `@bot.button`.

## What this does not decide

- Text inputs on a message, or a form opened without a press.
- Persisting a half-filled form across a reload.
- Select menus of users, roles or channels.
