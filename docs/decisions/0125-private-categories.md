<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0125 - A category is made private with a switch, and says who can see it

Status: accepted
Date: 2026-11-17
Extends [0064](0064-category-permissions.md) and [0120](0120-nested-categories.md).

## The ask

The owner configures his own server's permissions and could not make an Admin category admin-only from its permissions grid.
The grid's X on the `@everyone` column deleted that row, which made the category public instead of private, and the column stayed on screen.
His answer on 2026-11-17: a "Private category" switch at the top of the category permissions sheet, a "Who can see this" summary (administrators always, plus "Add role or member"), a warning when sub-categories or channels keep their own permissions, the grid kept below as Advanced, and no X on `@everyone`.

## Decision

- The switch reads private when `@everyone` is denied View channels, whatever other rows exist; a mixed state shows the switch on and lists what is there.
- On writes only `@everyone`'s View deny, keeping its other bits.
  A caller without Administrator, whom no role of theirs with an Allow View row keeps in, also gets an Allow View row for themselves, so they do not hide the channels from their own view; an administrator sees them anyway and gets no row.
  Writing that member row goes beyond the owner's "@everyone denied View" ask; it is the implementer's choice, pending owner review.
- Off lifts that deny and, for the same caller, the View allow on their own row (a row left all-zero is removed, here and in every synced child); every other row stays.
- "Who can see this" reads "Everyone" when public.
  When private it lists "Administrators - Always" and every role or member with an Allow View row, each with a remove that clears only its View allow (a row left all-zero is removed).
  "Add role or member" uses the grid's own picker and writes an Allow View row.
- Under it, the sub-categories and channels a save here does not reach are counted: unsynced sub-categories, and every unsynced channel beneath, including those in an unsynced sub-category, since "Sync all" re-syncs that sub-category too.
  "Sync all" syncs the sub-categories first and then the channels, through the existing sync routes; each can also be opened on its own sheet.
- The full grid sits under an "Advanced" disclosure.
- The grid's `@everyone` column, in channels and categories alike, has no remove; an info mark explains that it applies to everyone and that denying View there makes it private.
- A channel's existing Private switch gets the same "Who can see this" summary; the switch and the summary share one implementation (`view_access.dart`, `who_can_see.dart`).

No server change: every write is an existing overwrite or sync route.
Sync state is read per sub-category and channel with the existing `GET .../overwrites`, which is a handful of requests on an admin sheet.

## Rejected

- Keeping the X on `@everyone` and relabelling it "Reset": a reset there is rarely wanted and is still one cell cycle away.
- A server route that returns a category's whole sub-tree sync state: worth it only if the per-item reads prove slow.
