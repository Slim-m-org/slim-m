# Linux: the first screen share showed the portal chooser twice

Owner's report: on Fedora KDE Wayland, the first screen share in a session opens the xdg-desktop-portal chooser two times.

## Cause

Traced with `dbus-monitor` on `org.freedesktop.portal.ScreenCast` against a nested `kwin_wayland --virtual` with xdg-desktop-portal-kde.
The unpatched fork (a5d9427) opens three sessions for two shares, one more than it should.

- `getSources` constructs libwebrtc's `RTCDesktopMediaListImpl` for screens. Its constructor calls `capturer_->Start()`, which on Wayland is a full portal session: CreateSession, SelectSources, Start, so a chooser.
- `RTCDesktopDeviceImpl::GetDesktopMediaList` caches that list for the life of the process. The plugin's `resetDesktopSources` only drops the plugin's own reference, so the list and its session live on and later enumerations open nothing.
- `getDisplayMedia` then creates a capturer for the chosen source, which opens a second session and a second chooser.

So the first share asks twice, and every later share asks once. The list's session is never used for capture.

## Fix

The fork (Slim-m-org/flutter-webrtc, branch `fix/linux-portal-once`) installs a GDBus message filter on the shared session bus connection.
Only for the first screen list in the process, and only under Wayland, it drops that list's `CreateSession` call.
`getDesktopSources` answers after the call has been dropped (or after 1.5 s), so the capturer's session, made right after, is never the one dropped.
The filter disarms and removes itself at the drop, at that answer, and at the start of `getDisplayMedia`, so nothing can be dropped afterwards.
It matches the method call, interface and the portal's object path.
Nothing in the call's arguments tells the list's from the capturer's, since both carry random `webrtc_` tokens, so the timing guard carries the safety.
libwebrtc's unanswered call times out after about 25 s with `Failed to request session: Timeout was reached` in its own log.
It does not retry: a probe run across 35 s and a third share opened no extra session.
A `getDisplayMedia` with no prior `getSources` is not guarded and still opens two sessions.
The proper fix is a libwebrtc change, tracked on the Backlog card for removing the filter.
libwebrtc's binary cannot be rebuilt here, which is why this sits in the plugin.

## Checking it

`scripts/linux-portal-probe/run.sh` builds a small probe app against the pinned fork, runs two shares the way the app starts them in a nested KWin, and counts portal sessions.
Three cases run: the app flow (2 shares, 2 sessions), a share with no enumeration (2 sessions), and 3 shares around a 35 s gap (3 sessions).
Before the fix the app flow reported 3 sessions for 2 shares.
`FORK_PATH` points it at a local fork checkout.

The probe cannot see the chooser itself, because portal-kde skips its dialog on a single virtual output.
What it counts is the D-Bus calls that each open one.
