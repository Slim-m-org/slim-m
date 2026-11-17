<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0124 - View server as a role

Status: accepted
Date: 2026-11-17
Extends [0011](0011-per-channel-permissions.md) and [0120](0120-nested-categories.md).

## The ask

The owner configures prod's permissions himself and could not tell what a non-admin sees.
His answer on 2026-11-17: build "View as role" now, server-computed, read-only, audited, structure only, limited to roles below the caller, reached from Roles > a role > "View server as this role" with a "Viewing as X - read-only - Exit" banner.

## Decision: the server answers, the client only draws

- `GET /roles/{roleId}/preview` builds a synthetic role context: `@everyone` plus that one role, never the owner, no member overwrite, no timeout and no join gate.
  It runs the same evaluator `GET /channels` runs and the same category closure `GET /categories` runs (the closure is one shared function), so the answer cannot drift from what a real member holding only that role is listed.
- There is no Dart evaluator.
  Computing it in the client would need every channel's overwrites and a second copy of the precedence rules, two answers to "who can see this".
- The response is structure only: categories with their nesting, and channels with their kind, position, effective bits and `restricted` flag.
  No message content, topic, token, session or websocket subscription.

## Guardrails

- The caller needs MANAGE_ROLES; ADMINISTRATOR implies it.
  MANAGE_ROLES rather than ADMINISTRATOR because a role manager is who edits the roles being checked, and the ladder already bounds what they reach.
- The role must sit strictly below the caller's highest role, the same ladder every role route uses; the Space owner previews any role, and `@everyone` is always below.
  A refusal is a 403 with `code` `role_hierarchy`.
- The answer is trimmed to the channels the caller can view and the categories the caller is listed, so a preview never names anything above the caller.
- Rate limited as an authenticated read, like `GET /roles`.
- Audited as `role.preview` with the role as target, once per caller and role per ten minutes, so reloading does not flood the log.

## Client

- Roles > a role shows "View server as this role" for a role the viewer reaches (and `@everyone`) when they hold Manage roles.
  Beside the name at 600 and wider, under it below 600.
- The shell is swapped for the preview while one is active: a fixed accent banner "Viewing as X - read-only" with Exit, the role's rail (shared `SectionLabel`, `AppListRow`, `ChannelKindIcon` and `CategoryTree`), and in place of messages a summary of what the role can do in the opened channel.
  No composer, menus, unread state or drag.
- At compact width the rail and the summary are one pane at a time with a back action (desktop-vs-mobile, the three widths); above it they sit side by side.
- The preview lives in one in-memory provider.
  Nothing is written to the local store or to any real channel provider, and Exit restores the real shell.
- A failed load shows inline with a retry under the banner; Exit still works.

## Not done

- Previewing a specific member (their member overwrites and timeout) or a combination of roles.
  The route takes one role; a member view would be a separate route.
