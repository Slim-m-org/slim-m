<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Linux backlog

See [README.md](README.md) for what "confirmed" and "suspected" mean here and how this differs from `docs/BACKLOG.md` and `docs/OPEN-QUESTIONS.md`.

Unlike Windows and macOS, Linux has a real, scaffolded, built, and CI-tested target: `client/packages/app/linux/` exists, `main-builds.yml`'s `linux-client` job builds a release tarball and an rpm on every merge touching `client/**`, and the owner's own development machine (Fedora 44, KDE Plasma, Wayland) is where most client work in this project is actually exercised day to day (the pre-trim `CLAUDE.md`, "Local development": "Fedora KDE Plasma Wayland is the Linux development and test target (owner decision, 2026-07-26)").
So this file has by far the most confirmed content of the six, and several entries are fixes-that-must-not-regress rather than open problems.

## Confirmed

**A Wayland screen-share window enumeration segfaults the whole process, and the fix is a rule, not just a patch.**
the pre-trim `CLAUDE.md`, "Running the Fedora build, and what it found": `flutter_webrtc`'s `getSources(types: [SourceType.Window])` segfaults on Wayland (SIGSEGV, exit code 139), and a native crash of this kind cannot be caught from Dart at all.
Proved on this project's own hardware, not inferred.
`client/packages/rtc/lib/src/desktop_sources.dart` and `media_capabilities.dart` both carry one-line comments recording this and never request `SourceType.Window`, only `SourceType.Screen` (confirmed by reading both files).
*The rule to keep*: never enumerate windows on Linux from any call site, on any platform-detection branch; only ever request `SourceType.Screen`.
A later contributor "restoring" per-window sharing on Linux without first confirming this bug was fixed upstream would reintroduce a process crash, not a regression a test would catch.

**Screen share requires enumerating a source id first, or capture fails outright with a specific, reproducible error.**
`CLAUDE.md`: `getDisplayMedia` matches its requested `source_id` against a list only populated by a prior `getSources` call; capturing with no id throws `Bad Arguments: source not found!` verbatim, confirmed against the real plugin on this box (one source enumerated, `id="1"`, capture with that id succeeds, capture without one throws the exact string quoted).
`VoiceSession.setScreenShareEnabled` takes a `sourceId` parameter for this reason, and `DesktopSources` (`desktop_sources.dart`) is the seam that lists them.
On a Wayland session specifically, the real source-selection UI is xdg-desktop-portal's own picker, which negotiates independently of whatever id this app passes; `desktop_sources.dart`'s `sourcePickerUseful` is explicitly `false` on Linux for this reason (confirmed by reading the file), so the app deliberately does not show its own picker sheet on Linux, unlike macOS and Windows.

**Screen share on Linux is owner-confirmed working, contradicting an older research finding that predates this project's own testing.**
the pre-trim `CLAUDE.md`'s "Open items that need the owner" section: an earlier research writeup described Linux Wayland screen sharing as blocked by an upstream `flutter_webrtc` bug (issue 1542, the portal path not waiting for the picker response), and "the owner reports getting screen share working in their own testing," which is treated in that same section as making the older finding "probably fine... rather than a Wayland-wide block," confirmed rather than merely hoped, in the Phase 4 spike.
Recorded here as confirmed working per the owner's own real-hardware use, distinct from the enumeration/segfault issue above, which is a different failure mode (crash on window listing) than the one the older research finding described (picker not being awaited).

**Screen-share audio (2026-08-13) works on Linux, and the condition it works under is a build-time flag this project's own CI now sets.**
`flutter_webrtc`'s `linux/pulse_loopback_capturer.cc` streams the default sink's PulseAudio monitor source into the captured track, and `linux/CMakeLists.txt` gates that whole file on `HAVE_LIBPULSE`, defined only when `pkg_check_modules` finds `libpulse` and `libpulse-simple` on the build host - absent, the same `CreateLoopbackCapturer` factory silently returns `nullptr` and a Linux share simply has no audio track, with no error at any layer (`common/cpp/src/flutter_screen_capture.cc`'s `GetDisplayMedia`: `if (loopback_capturer_ && loopback_capturer_->Start(...))`, false branch continues without audio).
`client/packages/rtc/lib/src/screen_share_audio.dart`'s own doc comment carries the full trace; `libpulse-dev` is added to all three Linux build-dep steps that previously lacked it (`client-ci.yml`'s "linux compiles" job, `main-builds.yml`'s `linux-client`, `release.yml`'s `linux-client`) in the same change that wired the toggle up, so a Linux build produced by this project's own pipeline actually carries the capability the client now offers.
**Confirmed the hard way: the compiled binary now hard-links `libpulse-simple.so.0` at the ELF level, and `client-ci.yml`'s own `linux-desktop-shell-smoke` job caught it on the first run.**
That job downloads the release-built binary and runs it under Xvfb rather than rebuilding, so it is the one CI job that actually executes a binary built with `libpulse-dev` present - and it failed outright: `error while loading shared libraries: libpulse-simple.so.0: cannot open shared object file: No such file or directory`, before the window ever appeared.
This is not a screen-share-specific failure, it is the whole process refusing to start: the dynamic loader resolves every `DT_NEEDED` entry at exec time, so a runtime image missing a library the binary links now fails to launch at all, not merely to publish audio.
On Ubuntu 24.04 (`packages.ubuntu.com/noble/amd64/libpulse0/filelist`, checked directly), `libpulse-simple.so.0` ships inside the same `libpulse0` package as `libpulse.so.0` - the two sonames were merged into one binary package well before this project's target Ubuntu version - so the fix is one package, `libpulse0`, added to the smoke job's runtime-lib install list alongside the other libraries it already names explicitly.
*Not confirmed*: that the rpm and flatpak, which repackage `release.yml`'s already-built bundle rather than rebuilding, correctly declare or already satisfy this - the rpm's existing `Requires: libpulse.so.0()(64bit)` is for the same package, so it likely already covers it by version, but this was not independently re-verified with `elfdeps`/`rpm -qpR` the way the tray-icon dependency work above was, and the flatpak's `org.freedesktop.Platform` runtime was not checked directly either. Worth checking before relying on the packaged (as opposed to the portable tarball, and the smoke-tested Ubuntu runtime) Linux build having this.

**Screen-share audio echo (2026-10-26) is handled by a temporary private mix sink.**
The capturer records the default sink monitor, which holds everything played, so other people in the call were sent back to them as share audio.
While a share with audio runs, `ShareAudioIsolation` (`client/packages/rtc/lib/src/share_audio_isolation.dart`) makes a null sink the default, loops its monitor to the real output, and keeps this process's own playback streams on the real output so they never enter the mix.
Streams an app aimed at a device itself are left alone, so they are not in the shared audio.
Proved on a private PipeWire with two tones: the sink monitor held both before, the mix held only the other app after, and the real output still carried both.
Not tested on the owner's desktop session or with the real libwebrtc playout stream.

**`Helper.setVolume` (per-participant call volume) throws on Linux, and the client already guards against calling it there.**
Confirmed from the pre-trim `CLAUDE.md`'s "Moderating a member" section, quoted in full because the mechanism matters: "Linux and Windows throw. They share `common/cpp`, whose lookup scans only a `remote_streams_` map filled by the Plan B `OnAddStream` callback; LiveKit uses Unified Plan, where that never fires, so the map is always empty and the call returns 'Unable to find provided track'. flutter_webrtc's wrapper does not catch it, unlike every sibling in that file."
`audio_gain.dart`'s `supportsParticipantVolume` already excludes Linux (confirmed by reading the file: only Android, iOS, macOS are allowed), so the slider is correctly absent on this project's own primary desktop dev target.
Worth restating from `CLAUDE.md` directly, since it is easy to miss: "Fedora and the web build are two of the three that cannot do it, so the feature is invisible in both environments this project tests in locally, and real only on a phone" - meaning a contributor working purely on Fedora will never see this control at all, by design, and should not expect to.

**Camera background blur has no native per-frame hook on Linux at all, and this is explicitly "absent," not "unwired."**
Confirmed from `docs/research/background-blur-spike.md`, identical finding and identical citation to the Windows entry: "Linux and Windows have no native per-frame hook at all in the WebRTC plugin this project depends on: not missing wiring, missing entirely."
Grepping `common/cpp`, `linux/` and `elinux/` inside the pinned ~~`flutter_webrtc` 1.4.0~~ source for `VideoFrame`, `VideoProcessor`, `VideoSink`, `addProcessing`/`addProcessor` returns zero matches; the only per-frame native code shared by Linux and Windows is a one-shot screenshot function and a decode-for-display-only renderer, neither of which has a path back into the encode pipeline.
Version correction 2026-08-11: `client/pubspec.lock` resolves `flutter_webrtc` at **1.6.0** now, not the 1.4.0 this paragraph names, and 1.6.0 is the latest release upstream.
The finding itself was re-checked against that newer tree on 2026-08-10 for an unrelated screen-share question and the native surface had not changed, so the conclusion stands; only the version number was stale.
The spike's own recommendation applies here as much as to Windows: gate the camera toggle off, or clearly label it unblurred, on Linux rather than silently shipping a raw camera or blocking camera indefinitely.
See [windows_backlog.md](windows_backlog.md) and [macos_backlog.md](macos_backlog.md) for the same finding on those platforms.

**Fontconfig resolves an emoji font ambiguity to the wrong face by default, and the fix is a one-line rule.**
the pre-trim `CLAUDE.md`, "Running the Fedora build, and what it found": Fedora ships both `Noto Emoji` (monochrome) and `Noto Color Emoji`, and fontconfig's default resolution handed back the monochrome one, so every reaction chip rendered as a hollow outline instead of a colour glyph.
Fixed by adding `AppFonts.emoji` to `fontFamilyFallback` on the theme and on `AppText.code`.
Verified by rendering the same string through the real engine three ways, not by reasoning about it.
*The rule to keep*: any place that renders untrusted or user-supplied emoji text needs the emoji font in its fallback chain explicitly; do not assume the system default resolves to the colour face.

**The rpm's `Recommends` line pulled a redundant, unnecessary keyring daemon onto every KDE install, and the fix generalizes to any secret-service consumer.**
`CLAUDE.md`: the packaged rpm named `gnome-keyring` as a `Recommends`, which is not what `libsecret` (which `flutter_secure_storage_linux` uses) actually needs; it needs anything implementing the `org.freedesktop.secrets` D-Bus API, and `kf6-kwallet` (already present on the project's own KDE Plasma target, via `ksecretd`/`org.kde.secretservicecompat.service`) already provides it.
Fixed as a boolean dependency naming both (`gnome-keyring` or `kf6-kwallet`), since Fedora has no virtual "provides" for the capability itself.
*The rule to keep*: when a Linux package needs a secret-service backend, depend on the capability by listing every known provider, never on one desktop environment's specific daemon.

**`libsecret-1-dev` and GTK are real build-time system dependencies for the Linux desktop build, confirmed by the CI job that installs them.**
`main-builds.yml`'s `linux-client` job installs `clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev` before building; this is the authoritative, tested list of system packages a Linux build needs beyond Flutter itself.

**The launcher icon lost its lattice detail below 32px, and the fix is a threshold, not a redraw.**
`CLAUDE.md`: below 32px the icon rendered `icon-master-small.svg`, a lone square with no lattice, so a launcher entry did not read as this app's mark at small sizes; small sizes now draw the same full mark at 78% of the tile rather than 60%.
Recorded here because it is exactly the kind of platform-rendering detail (icon theme, size-dependent asset selection) that only ever surfaces on a real desktop launcher, never in a widget test.

**The Linux window title read the raw binary name (`slimm_app`) rather than the product name, on both native-decoration code paths.**
`docs/BACKLOG.md`: `client/packages/app/linux/runner/my_application.cc` had never been updated to show "slim-m" in either its GNOME header-bar branch or its plain-titlebar branch, while iOS, Android and the web build all already showed the correct name via their own platform-native mechanisms. Fixed in both branches.

**On a database that has never been `ANALYZE`d, SQLite's rtree query planner silently chooses the slower plan, and this is a general finding rather than Linux-specific - recorded here because it was found and measured on this project's own Fedora hardware.**
`docs/research/canvas-spike-server.md`, referenced from the pre-trim `CLAUDE.md`'s "The Phase 5 canvas spike": on an un-analyzed database, which every real slim-m deployment is, the natural join plans as the rtree module's rowid-equality strategy, reading every object and probing the index once per row for zero pruning, 7.1x slower than no index at all - and running `ANALYZE` while investigating makes the planner pick correctly on its own, which is exactly how this would ship broken without a test reading the real query plan. This affects the server, not the client, and is recorded here only because it was Linux-hardware work; the fix (`CROSS JOIN` pinning the plan, asserted by `tests/canvas_index.rs` reading the real SQL) is already shipped and is a server concern, not a per-client-OS one.

~~**`flutter build linux` is not part of the per-PR client-ci gate; it only runs on push to main.**~~
~~Confirmed by reading `client-ci.yml` (analyze, format, `flutter test`, and `flutter build web` only, all on `ubuntu-latest`) against `main-builds.yml`'s `linux-client` job, which is gated on `push: branches: [main]` with no `pull_request` trigger.~~
~~This means a PR that breaks the Linux desktop compile is not caught before merge; it is only caught by the `main-builds.yml` run immediately after landing on `main`.~~
~~*Worth flagging as a process gap, not a code bug*: the Linux build is real and gated, but later than a PR reviewer would likely assume from `client-ci.yml`'s green check alone.~~
**Closed, struck 2026-08-11: `client-ci.yml` carries a "linux compiles" step running `flutter build linux --release` on every pull request, and uploads the resulting bundle as an artifact.**
So a PR that breaks the Linux desktop compile is now caught before merge rather than immediately after, and the process gap this entry named is gone.
Its own apt list is the current authoritative one and has grown past the entry above it: `clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libayatana-appindicator3-dev`, where the gstreamer pair arrived with `audioplayers_linux` and the indicator package with the tray icon.

## Suspected

**GPU-accelerated hardware video decode inside the Flatpak sandbox has never been validated, because the app has never been launched from a Flatpak build.**
`docs/ROADMAP.md`'s Phase 4 deliverable names "also validating GPU hardware video decode inside the Flatpak sandbox" as part of the Linux RTC spike, and the spike's own status entry (Phase 4, 2026-07-28) does not report this sub-clause as separately confirmed, only that the general Linux `flutter_webrtc`/`livekit_client` build and link succeeded on Fedora KDE Wayland.
`packaging/flatpak/top.npcserver.slimm.yaml` exists now (2026-08-05) and has been built and installed for real, but only as far as `readelf`/`ldd` on the installed files; the app itself has never been launched from that bundle, on any display, so GPU-accelerated video decode specifically remains exactly as untested as before, only for a narrower reason now - see `packaging/flatpak/README.md` for precisely what was and was not checked.

**Behaviour on non-KDE, non-Wayland Linux desktops (GNOME, X11, other window managers) is unverified.**
Every confirmed Linux finding in this project - the screen-share segfault, the emoji font, the keyring dependency, the rpm build itself - was found and fixed on the owner's specific Fedora 44 KDE Plasma Wayland machine, the project's stated single Linux development and test target (the pre-trim `CLAUDE.md`, "Local development").
`docs/BACKLOG.md`'s frameless-title-bar entry notes in passing that Linux chrome expectations vary "depending on the desktop environment," and the X11 branch of `desktop_sources.dart`'s own doc comment notes, read from source, that "on X11 this branch was never reachable anyway: enumerating has only ever returned the one merged screen" - a claim about behaviour, not a tested one, since this project's target is Wayland.
This does not mean other desktop environments are known broken; it means nothing here confirms they are known working, and any bug report from a GNOME or X11 user should not be assumed to also reproduce on the tested KDE Wayland target, or vice versa.

~~**A frameless, custom title bar would need to detect and adapt to whichever Linux desktop environment is running, which is unbuilt.**~~
~~`docs/BACKLOG.md`'s "A frameless window with our own title bar" entry, deferred rather than declined, notes this fits Wayland "since client-side decorations are already the norm" there, but does not resolve what a custom bar should look like across the many desktop environments Linux actually spans.~~
**Built 2026-08-10, so this moves out of "suspected" - struck 2026-08-11.**
[decision 0012](../decisions/0012-desktop-window-shell.md) designed it and PR #533 built it: Linux hides the native bar and draws its own controls, closing to a tray rather than quitting.
It did not resolve the cross-desktop question this entry raised so much as pick a side of it - the tray half depends on `StatusNotifierItem`, which KDE (the tested target) supports natively while GNOME needs the AppIndicator extension, and the decision record designs a runtime fallback rather than telling anyone to install it.
So the desktop-environment variation this entry worried about is now a real, shipped dependency rather than a hypothetical, and it reached packaging too: the flatpak had to vendor `libayatana-appindicator3` and its four dependencies because the Freedesktop runtime carries none of that stack (PR #552).
What stays genuinely unverified is the same thing as every other Linux entry here - none of it has been seen running on a non-KDE desktop.
See the same entry noted in [windows_backlog.md](windows_backlog.md) and [macos_backlog.md](macos_backlog.md).

**`tflite_flutter`'s Linux native build path (manual, per the package's own README) is unverified in this environment.**
`docs/research/background-blur-spike.md`, same finding as the Windows and macOS entries: "I did not attempt to build `tflite_flutter`'s desktop path in this environment... Whether it actually links on this project's own Fedora KDE Wayland target is unverified." This is the one desktop-blur uncertainty that is specific to this project's actual dev machine rather than a hypothetical future target, and is the cheapest of the three to eventually check.
