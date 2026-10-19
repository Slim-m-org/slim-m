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

The fork (Slim-m-org/flutter-webrtc, commit a34a7ed on `fix/linux-portal-once`) installs a GDBus message filter on the shared session bus connection.
Only for the first screen list in the process, and only under Wayland, it drops that list's `CreateSession` call.
`getDesktopSources` answers after the call has been dropped (or after 1.5 s), so the capturer's session, made right after, is never the one dropped.
libwebrtc's binary cannot be rebuilt here, which is why this sits in the plugin.

## Checking it

`scripts/linux-portal-probe/run.sh` builds a small probe app against the pinned fork, runs two shares the way the app starts them in a nested KWin, and counts portal sessions.
Before the fix it reports 3 sessions, after it reports 2, one per share.
`FORK_PATH` points it at a local fork checkout.

The probe cannot see the chooser itself, because portal-kde skips its dialog on a single virtual output.
What it counts is the D-Bus calls that each open one.
