<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0070 - Settings that follow the Space

Status: accepted
Date: 2026-10-18

## The ask

The owner asked: "settings should be space scoped, so I can have different settings in space A but when i switch to space B it changes to space B settings".

[0068](0068-multiple-servers-in-one-app.md) had listed theme, density and the other restorable preferences as global.
This record replaces that line.

## Rule

A setting is Space-scoped when it is about how one community looks, sounds or behaves for this person.
A setting is device-wide when it describes the machine: hardware, bandwidth and memory, the window, the OS.
A setting the server already stores per account (notification preferences, schedule, channel overrides, blocks) is Space-scoped by nature and unchanged.
A setting already keyed by a server-issued id (drafts, filed reports, first-run hints, participant volumes) is already per Space and unchanged.

## How it is stored

`preferencesProvider` hands each account's container a `SpaceScopedPreferences` view of the one shared preferences file.
A key in `spaceScopedKeys` is stored as `slimm.space.<origin>.<key>`, where the origin is the one the switcher identifies the account by.
Every other key is stored as before.
No setting controller changed: they all read and write through the same provider.

Each account already has its own container, so a switch shows that Space's values with nothing to reload.
Device-wide values are re-read on activation, so a change made in one Space is seen in the next.

## Migration

There is no copy step.
A Space with no value of its own reads the old device-level key, so every Space that exists when this ships starts with the values the person had.
The first change in a Space writes that Space's own key and leaves the others alone.
A Space added later starts from the same old values, which is the closest thing to "what I had" a new Space can inherit.

## Classification

| Setting | Key | Scope | Why |
| --- | --- | --- | --- |
| Theme | `slimm.appearance.theme` | Space | appearance |
| Time format | `slimm.appearance.time_format` | Space | appearance |
| Message density | `slimm.appearance.message_density` | Space | message preference |
| Group spacing | `slimm.appearance.group_spacing` | Space | message preference |
| Continuation marker | `slimm.appearance.continuation_marker` | Space | message preference |
| Interface sounds | `slimm.notifications.ui_sounds_enabled` | Space | sounds |
| Haptics | `slimm.notifications.haptics_enabled` | Space | sounds and feedback |
| Message sounds | `slimm.notifications.message_sounds_enabled` | Space | sounds |
| Desktop notification text | `slimm.notifications.desktop_message_text` | Space | notifications |
| Module sounds | `slimm.modules.sound_enabled` | Space | modules belong to one server |
| Media auto-download | `slimm.performance.media_autodownload` | Space | what a community's messages show |
| GIF autoplay | `slimm.performance.gif_autoplay` | Space | what a community's messages show |
| Link previews | `slimm.performance.link_previews` | Space | what a community's messages show |
| Mention on reply | `slimm.composer.reply_mention` | Space | message preference |
| Share listening, game, Spotify | `slimm.presence.share_*` | Space | what each community may see |
| Join and leave sounds | `slimm.voice.join_leave_sounds_enabled` | Space | sounds |
| Hold music and track | `slimm.voice.hold_music_*` | Space | sounds |
| Call ring sound | `slimm.voice.call_ring_sound_enabled` | Space | sounds |
| Microphone and speaker choice | `slimm.voice.audio_*_device_id` | Device | hardware |
| Camera on join, camera quality | `slimm.voice.camera_*` | Device | hardware |
| Noise suppression, sensitivity, input threshold, even out loud sounds | `slimm.voice.*` | Device | the microphone |
| Push to talk | `slimm.voice.push_to_talk_*` | Device | the keyboard |
| Remapped call shortcuts | `slimm.voice.shortcut_overrides` | Device | the keyboard |
| Screen share quality, audio, receive quality, pause video | `slimm.voice.*` | Device | bandwidth and the machine |
| Participant volumes | `slimm.voice.participant_*volumes` | Device | already keyed by server-issued user ids |
| UI scale | `slimm.appearance.ui_scale` | Device | the display |
| Motion, high contrast | `slimm.appearance.motion`, `.high_contrast` | Device | accessibility needs follow the person's eyes and OS, not the community |
| Image cache limit, preview quality, message page size | `slimm.performance.*` | Device | memory and bandwidth |
| Splash on and duration | `slimm.performance.desktop_splash_*` | Device | startup of the app |
| Start on login, automatic updates, update dismissed | various | Device | the install |
| App lock | `slimm.security.app_lock` | Device | the machine |
| Window geometry, rail width, collapsed categories | various | Device | the window |
| Recent emoji, canvas camera memory | various | Device | convenience memory |
| What's new seen, first launch flag, first-run hints | various | Device | the install |
| Notification preferences, schedule, channel overrides, blocks | server | Space | stored per account on the server, unchanged |

A key not in `spaceScopedKeys` is device-wide.
`space_scoped_preferences_test.dart` fails on a `slimm.*` key that is in neither list, so a new setting has to be classified.

## Unsure, for the owner

- UI scale, motion and high contrast are device-wide here because they follow the display and the person, not the community.
  Say so if you want a different scale or contrast per Space.
- Haptics is Space-scoped with the sounds, though it describes the phone.
- Media auto-download and GIF autoplay are Space-scoped as message display; the image cache, preview quality and page size stay device-wide as memory and bandwidth.
- The first Space started from the old values and a Space added later inherits them too, rather than starting from the app defaults.
