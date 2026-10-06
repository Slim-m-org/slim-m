# Pointing a tool at slim-m

slim-m accepts a Discord-shaped incoming webhook.
If a tool already has a "Discord webhook" notification target, that target works here too, no plugin or translation layer needed.

See `docs/decisions/0030-incoming-webhooks.md` for why it is built this way, and what it deliberately does not do.

## Minting a URL

Space settings -> Addons -> Webhooks, as somebody holding MANAGE_SERVER.
Pick a channel and give it a label - "sonarr", "uptime-kuma", whatever tells you what is posting - and you get a URL.

**The URL is shown once.** The server keeps only a hash of its token, so it cannot be shown again.
If you lose it, or it leaks, use Rotate on that webhook: you get a new URL, and the old one stops working at once.
Rotating keeps the webhook and what it already posted, so the history stays attributed to it.
Revoke it instead if the tool should stop posting for good.
Mint, rotate and revoke all appear in the moderation audit log.

The URL shape is:

```
https://your-deployment/webhooks/{webhookId}/{token}
```

Paste the whole thing into the tool's "Discord webhook URL" field.

## What it accepts

Only `content`, `username`, and `embeds` are read.
Everything else Discord's own incoming-webhook body defines - `avatar_url`, `tts`, `flags`, `components`, `thread_name`, `poll`, `attachments` - is accepted and silently discarded, never a 400.
That is deliberate: a tool upgrading and adding a field it thinks Discord wants must never turn a working notification into a broken one.

`username` renders as a per-post label next to the always-on `Webhook` badge, so if you point several sources at one webhook - Apprise and Uptime Kuma both do this - you can still tell a disk alert from a certificate alert.
`avatar_url` is dropped; the webhook's own configured picture shows instead.

An `embeds` array renders as slim-m's own embed card: title, description, fields, a color reduced to one of six accent buckets, and an image if the URL passes the same guard link previews use.
An image the guard refuses is dropped; the rest of the embed still posts.

An embed's `timestamp` can be an integer (epoch milliseconds) or the ISO 8601 string Discord's own shape uses, such as `2026-10-04T12:00:00.000Z` or `2026-10-04T14:00:00+02:00`, with any number of fractional digits.
A timestamp that cannot be read is dropped and the rest of the embed still posts, the same as an image the guard refuses.
A `null` for `embeds` or for an embed's `fields` is read as empty.

## What it cannot do

A webhook URL posts text and bounded embeds into exactly one channel, at a rate limit, and nothing else.
It cannot read history, edit or delete anything (including its own posts), upload a file, mention `@everyone` or a role, or mint another webhook or a bot.
Revoking it takes effect immediately.

If a leaked URL is your worry: this list is the whole blast radius.

## Per-tool notes

**Uptime Kuma**: Settings -> Notifications -> add a Discord notification, paste the URL.
Point one webhook per monitor group if you want the channel to double as a status feed rather than a firehose.

**Sonarr / Radarr**: Settings -> Connect -> add a Discord connection, paste the URL.
Both send an embed per event (grab, download, health issue); slim-m renders all of them.

**Grafana**: Alerting -> Contact points -> add a Discord integration, paste the URL.
A firing alert and its resolved follow-up post as two separate messages here, not an edit-in-place - slim-m does not honour edits from a webhook, on purpose, so the two-line record stays in the channel.

**GitHub Actions**: use any of the community "Discord webhook" actions and pass the URL as its `webhook-url` (or equivalent) input.
Keep the URL in a repository secret, not a workflow file - it is a bearer credential like any other.

**Jellyfin's webhook plugin**: add a Discord-notification webhook, paste the URL, pick the events you want.

**Anything else with an Apprise target**: `apprise://` and `discord://` both work against this URL unchanged.
