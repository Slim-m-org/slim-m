# First-run onboarding

A short, skippable setup shown once to a new member of a Space.
It is separate from the sign-in screens in `features/auth`, which only get a person into a Space.
This flow starts after they are in.

## Why

A new member used to land on an empty pane that listed keyboard shortcuts.
Nothing said who they were joining, that a picture could be set, that notifications were off, or where the voice channels were.
The flow answers those four things and gets out of the way.

## When it shows

It shows when all of these hold:

- the account was created less than a day ago
- the local store holds no message written by the account
- setup was not already finished or skipped for this account on this Space

An account older than a day, or one that has already written something, never sees it.
That covers a returning member who signs in on a new device.

## What is remembered

One flag per account and per Space, kept in the device's preferences under `slimm.first_run.done.<space>|<account>`.
It is written the moment the flow is finished or skipped, so a restart mid-flow shows it again and a restart after never does.
A second flag, `slimm.first_run.voice_hint.<space>|<account>`, marks the voice hint as still owed after a finished setup.
Running setup again from Settings ignores the done flag for that run and writes nothing new.

## Steps

Every step has Continue and "Skip setup".
"Skip setup" ends the whole flow, not just the step.
A step is never required to be filled in.

1. Welcome: the Space icon, name and description, and who invited them when that is known.
2. You: picture and display name (the Identity card from Settings), and optional pronouns.
3. Notifications: choose what to be notified for, then allow system notifications where the platform asks.
4. Voice check: pick a microphone and speaker, and watch the level once a call is open. It never blocks.

After the last step, the flow closes on the most active readable text channel, with a one-time hint about the voice channels.

## Surface per width

Width decides, never platform (`desktop-vs-mobile.md`).
Below 600 it is a full-screen stepped page with the actions pinned to the bottom edge at touch size.
At 600 and above it is a centred card, at most 520 wide, over the dimmed shell.
It is a first-run overlay above the routed tree (surface rule 7), so it sits above the shell and nothing underneath takes focus.
A resize across 600 keeps the step and what was typed.

## Copy

Short, plain, no exclamation points, one verb per action (`wording.md`).

- Welcome: "Welcome to {space}", then the description, then "{name} invited you." when known.
- You: "Set up your profile", "Add a picture so people know it is you."
- Notifications: "Choose your notifications", "You can change this any time in Settings."
- Voice check: "Check your voice", "Pick the devices a call uses."
- Buttons: Continue, Back, Skip setup, Finish, Allow notifications.

## Skip and finish

Skip setup on any step writes the done flag and closes the flow without moving the member.
They stay on the empty pane, which then carries brief guidance and a "Run setup" button.
Finish writes the done flag, moves the member to the landing channel and arms the voice hint.
The voice hint is one dismissible line, shown once, and then cleared.

## Landing channel

The text channel with the most messages the member can read, ties broken by rail order.
A voice channel or a DM is never chosen, and the local store only holds channels this member can read.
With no text channel the member stays on the empty pane.

## Accessibility

Every control is reachable by Tab in reading order, and the first field of each step takes focus.
Continue takes focus on each step, so Enter moves on, and Escape does nothing so setup is never skipped by accident.
The step counter and each step title are spoken as a header.
Transitions between steps use the standard fade and collapse to nothing under reduced motion.

## Empty pane guidance

With no channel chosen, the pane says what to do next instead of listing shortcuts.
It names three things: pick a channel, join a voice channel, and set up a profile.
It carries a "Run setup" button, which opens the same flow.
Keycaps stay below it on a layout with a keyboard and are absent on touch.

## Settings

Settings > Troubleshooting has a Setup card with a "Run setup again" row.
It is findable in settings search.
