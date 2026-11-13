<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0117 - On Windows, viewers' marks on a shared window reach the sharer's screen

Status: accepted, 2026-11-13 (built; verified on the Windows VM, see "Checked").
Amends [0096](0096-screen-overlay.md), "What it covers", for Windows only.

## Decision

Owner, 2026-11-12: a Windows sharer shared a window and viewers' marks never reached them, because 0096 opens the overlay for whole-screen shares only.

On Windows a window share now opens the same click-through overlay, over the shared window instead of a monitor.
Linux, and every other platform, keep 0096: a window share does not open the overlay there, and the marks show on the sharer's in-app preview.

- The window share's source id is the window handle the capturer uses, so Dart sends it with `show` (`window`) and the runner reads the rectangle itself.
- The rectangle is the window's visible frame (`DWMWA_EXTENDED_FRAME_BOUNDS`, falling back to `GetWindowRect`), which is what the capturer captures, so a mark lands on the same pixels a viewer sees.
- The runner follows the window with `SetWinEventHook` on the window's own thread: `EVENT_OBJECT_LOCATIONCHANGE` for moves and resizes, show, hide and destroy, and the system minimize pair.
  A resize rebuilds the overlay's surface at the new size and repaints; a plain move only repositions it.
  While the window is minimized, hidden or gone the overlay is hidden, and it comes back when the window does.
- Marks stay normalised to the shared thing, so nothing in the viewer, the relay or the fade changes.
  The consent frame's width over height follows the captured frame for a followed window, since the overlay is as large as the window and the captured frame is the window; a resize is announced like a first frame is.
- Changing the share from a window to a screen, or back, moves the overlay without ending consent.
- It is excluded from capture like the screen overlay, so it never lands in the share.
- A game in exclusive fullscreen cannot be shared as a window, so it is unaffected.

## Not done

- The overlay is topmost, so a window that covers the shared one is drawn over by a mark until the mark fades.
  The marks last seconds and the sharer chose to share the window; occlusion tracking was left out.
- Linux and macOS: no window rectangle is reported by the portal or the capturer there.
