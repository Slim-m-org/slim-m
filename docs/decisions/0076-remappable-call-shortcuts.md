<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0076 - Remappable call shortcuts

Status: accepted
Date: 2026-10-18

## The ask

The owner picked remappable mute, deafen and push-to-talk shortcuts in Voice settings.

## Rule

- Voice settings has a Shortcuts card, desktop hosts only: the push-to-talk toggle and key, a mute chord, a deafen chord, and Reset shortcuts once anything differs from the defaults.
- Mute and deafen are chords (Ctrl+Shift+M and Ctrl+Shift+D by default).
  A chord needs Ctrl, Alt or Cmd, or an F key, so it cannot swallow typing.
  Push to talk stays one key, as before.
- A key something else already uses is refused with the name of what uses it, and capture keeps waiting.
  That covers the other app shortcuts, the server switcher, mute against deafen, and the push-to-talk key against a bare F-key chord.
- Capture is keyboard reachable: Tab to Change, Enter to start, press the chord, Escape cancels.
- Remaps live on this device (`slimm.voice.shortcut_overrides`) and are mirrored into `userShortcutOverrides` in the platform package, so every tooltip, binding and global registration follows without threading a provider.

## Global capture

Unchanged plumbing: the same `GlobalHotkeySource` (portal on Linux, low-level hook on Windows) registers push to talk, mute and now deafen, and re-registers when a chord changes.
Where the OS refuses, the status line under the rows says the shortcuts work only while slim-m is focused.
macOS stays in-window only.
