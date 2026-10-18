<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Windows backlog

See [README.md](README.md) for what "confirmed" and "suspected" mean here and how this differs from `docs/BACKLOG.md` and `docs/OPEN-QUESTIONS.md`.

~~The single fact that reframes every entry below: **there is no Windows client target in this repository.**~~
Fixed 2026-08-12: `client/packages/app/windows/` exists now (scaffolded via `flutter create --platforms=windows --org top.npcserver --project-name slimm_app .`, the same shape `linux/` already has), and `.github/workflows/client-windows-ci.yml` compiles it on every PR touching `client/**`, on `windows-latest`.
It is deliberately **not** a required check yet - see that workflow's own header comment for why, and read the rest of this file before promoting it or before assuming a green compile means the platform is done.
Everything below this point is corrected against that new evidence rather than left as it was; each entry says what changed and what is still genuinely unverified.

## Confirmed

~~**No `windows/` platform directory exists under `client/packages/app`.**~~
Fixed 2026-08-12: scaffolded per the note above.
Two things worth knowing before touching it again.
`flutter create --platforms=windows .` on an already-existing project **overwrites `.metadata`'s platform list** with only the platform just requested, silently dropping `android`, `ios` and `web` from it - caught by reading the diff before committing, not by any gate, since nothing in this repo's CI reads `.metadata` at all.
Restored by hand to keep all four (Linux was never in it to begin with, since `linux/` was hand-built rather than scaffolded through `flutter create`, so there was nothing to restore there).
And the command also wrote a stray `test/widget_test.dart` (the default counter-app smoke test) and IDE project files (`.idea/`, `*.iml`) - the IDE files are already covered by the workspace `.gitignore` and needed no action, but the stray test was deleted; a "no stray boilerplate" scaffold means checking `git status` after running the command, not trusting its own "Wrote N files" summary.

~~**No CI workflow builds, tests, or even type-checks a Windows target.**~~
Fixed 2026-08-12: `.github/workflows/client-windows-ci.yml`, compile-only (`flutter pub get --enforce-lockfile` then `flutter build windows --debug`), non-required, path-gated on `client/**` the same way `client-ci.yml` is.
Debug rather than release, matching the reasoning `client-ci.yml`'s own `linux-compiles` job gives for its Linux build: this job exists to catch a link failure in the native plugin graph, not to produce a shippable artifact, and Windows packaging is not scheduled in `docs/ROADMAP.md`'s Phase 9 for any platform this repository does not already build for.
Whether it is actually green on a real `windows-latest` runner is stated in this file's own status note above rather than assumed here; a stale claim of "compiles clean" would be exactly the shape of stale entry this directory's own README warns against.

**`flutter pub get` already resolves a full native-plugin graph for Windows, with `client/pubspec.lock` completely unchanged by adding the platform.**
Confirmed by running the scaffold and reading the resulting `windows/flutter/generated_plugin_registrant.cc`: it registers real Windows plugin implementations for `audioplayers_windows`, `connectivity_plus`, `firebase_core`, `flutter_secure_storage_windows`, `flutter_webrtc`, `livekit_client`, `screen_retriever_windows`, `sqlite3_flutter_libs`, `tray_manager` and `window_manager` - the whole call, storage, persistence and desktop-shell stack, not a subset.
`client/pubspec.lock` had zero lines changed by `flutter pub get` after the platform was added (checked with `git diff`), meaning every one of those packages' Windows-capable versions was already pinned before this file's own "already load-bearing" `win32` entry was even written.
This is real evidence the dependency *graph* is Windows-capable; it is not evidence the native C++ actually links, which is exactly what `client-windows-ci.yml` exists to answer and this file's own status note states rather than assumes.

**The Dart-level desktop-shell code already gates Windows honestly, and needed no changes for this pass - it was written ahead of the platform existing, per decision 0012's own migration order.**
Read directly from source rather than assumed: `close_behavior.dart`'s `DesktopPlatform` enum already has a `windows` member and `currentDesktopPlatform()` already detects it via `isWindowsHost`; `tray_availability.dart`'s `trayAvailabilityCheck` already treats Windows (like macOS) as unconditionally available with no runtime probe, matching decision 0012's stated design ("Windows always has a notification area... neither platform needs a runtime capability probe the way Linux does"); and `composer_clipboard_image_stub.dart`'s own doc comment already says, in these words, "Windows and macOS register no platform-side handler at all... treated as 'not supported' rather than surfaced as a crash," with every call site wrapped in a `MissingPluginException` catch that answers `false`/`null` rather than throwing.
None of this needed building or fixing in this pass; it is recorded here because "gate desktop-shell features honestly rather than stubbing silently" was this pass's own instruction, and the honest answer for these three files is that they already do.

**Voice calls work on Windows.**
Confirmed 2026-09-29 on a win11 libvirt test VM with client v0.87.0: a two-party call with the web client held 5+ minutes, both participants saw each other in the call, the Windows side showed the other participant speaking (audio reached Windows), and LiveKit selected a direct `udp4` host ICE pair without relay.
The earlier "unable to join call on windows" report (backlog seq 121) was environmental, not a client bug: the VM's user-mode network stack (SLIRP, later passt) blocked direct UDP, and the app was not allowed past Windows Defender Firewall for inbound UDP until manually added.
For the next Windows VM tester: use the `passt` backend (not SLIRP), add an inbound firewall rule for just `slimm_app.exe` (`netsh advfirewall firewall add rule name="slim-m" dir=in action=allow program="C:\slimm\slimm_app.exe" enable=yes profile=any protocol=any`), and keep the firewall enabled - do not disable it.
Under `passt` the guest shares the host IP, so host services are reached at `10.0.0.1` (not the host's LAN address).
An A/B test without the firewall rule was cut short, so the rule is the likely (but unproven) fix for the earlier failure.
Not yet checked: video and screen share on Windows, and audio in the Windows-to-host direction.
A real-hardware Windows check is still worthwhile before 1.0.

**No second-instance dedup exists on Windows, and this is a genuine gap this pass left in place rather than one it silently papered over.**
`linux/runner/linux_second_instance_channel.cc` is the only sender for `top.npcserver.slimm/linux_second_instance`, and it is Linux-only by name and by the GTK single-instance mechanism (`G_APPLICATION_NON_UNIQUE`... `activate` re-entry) it wraps; nothing analogous was scaffolded for Windows in this pass, since a stock `flutter create --platforms=windows` carries no such native channel and building one was outside this job's own scope (a compile-only CI job and the symlink fix).
`desktop_window_shell.dart`'s `registerSecondInstanceHandler()` still runs unconditionally on every desktop platform including Windows, but this is safe rather than misleading: it only registers a Dart-side *receiver* for a call nothing on Windows will ever make, so it is inert there rather than broken, the identical "no handler exists, so the call finds nothing" shape `composer_clipboard_image_stub.dart` already documents for its own Windows case above.
The real, user-visible consequence: launching the packaged Windows app a second time while it is already running (or already minimised to the tray, once that ships) will start a second process with its own window, rather than focusing the first one the way `my_application.cc`'s early return already does on Linux.
Left open rather than built here, and named so the next contributor building the Windows tray/close-to-minimise slice of decision 0012 does not assume this already works because the Linux half does.

**The Windows app icon is Flutter's stock template icon, not this project's own mark.**
`windows/runner/resources/app_icon.ico` is exactly what `flutter create` writes for every new project; nothing in this pass replaced it with the lattice mark `packaging/linux/icons/` carries for Linux, since building or converting a Windows `.ico` was outside a compile-only scaffold's scope.
Cosmetic rather than functional - the app compiles and runs with it - but named here rather than left for someone to notice by screenshot, matching this project's own "no stray boilerplate" instruction for the rest of the scaffold.

~~**No Windows packaging exists, and none is documented as planned.**~~
Superseded: `desktop-clients.yml` builds a Windows zip with `install.cmd`, `install.ps1` and a `slim-m.exe` launcher, a per-user install that updates itself; see `packaging/windows/README.md` and decision 0041.
What follows is the original finding, kept as history: `packaging/` held `fedora/`, `linux/` and `rpm/` only.
`docs/ROADMAP.md`'s Phase 9 (release readiness) names "Linux artifacts (Flatpak primary, rpm alongside) and the iOS TestFlight-to-production path" as its packaging deliverable and does not name an MSI, an installer, a winget manifest, or any other Windows artifact anywhere in the document.
This is worth stating plainly rather than assuming it is simply unwritten yet: no phase in the roadmap currently has a Windows packaging deliverable at all.

**The `win32` package family's version is already load-bearing on every platform, including this one, before Windows is even scaffolded.**
`docs/dependencies.md` ("Client holds"): `livekit_client` 2.8.1 pins `device_info_plus` to a version capping the transitive `win32` package at major version 5, while `file_picker` 12 needs `win32` 6, so the whole dependency tree had to move together rather than holding one package back.
Its own text: "this was never a Windows-only concern: those libraries type-check on a Linux build even though none of their code ever runs there, so a `win32` major mismatch is a hard build failure on every platform."
*The rule that follows, stated in the same file and worth repeating here*: if a future `win32`-dependent package conflict recurs, the fix is to follow whatever `livekit_client` pins, not to bump the other `win32` packages on their own merits.
Check `docs/dependencies.md` before touching `file_picker`, `device_info_plus`, `package_info_plus`, or `flutter_secure_storage`.

**`audioplayers_windows` is already resolved in the committed lockfile.**
Confirmed by grepping `client/pubspec.lock`: `audioplayers_windows` is a resolved transitive dependency of `audioplayers`, the package `docs/dependencies.md` documents choosing for the notification-sound slice (the pre-trim `CLAUDE.md`, "The seven sounds finally play: the in-app slice").
This means the dependency graph is already Windows-capable for audio playback in principle; it does not mean playback has ever been exercised on Windows (a Windows zip does build now, via `desktop-clients`).

~~**The bundled notification-sound assets are a git symlink, and CLAUDE.md's own reasoning for why that is safe explicitly excludes Windows.**~~
Fixed 2026-08-12, and a second symlink with the identical trap was found and fixed alongside it.
`client/packages/app/assets/audio/notifications/*.wav` (seven files) and `client/packages/app/assets/icons/tray_icon.png` are checked-in copies now, not symlinks - the second one was the tray icon `decision 0012`'s `tray_manager` integration loads unconditionally on every desktop platform including Windows (`desktop_tray_controller.dart`'s `trayIconAssetPath`), found by checking every asset entry in `pubspec.yaml` for the same `120000` git mode the audio directory had, not by assumption.
A checked-in copy rather than a build-time copy step, because this job's own scope forbids editing `client-ci.yml`/`main-builds.yml`/`release.yml` to add a sync step to their existing jobs, and those jobs' `flutter pub get`/`flutter test`/`flutter build *` steps needed to keep working unchanged on Linux and macOS runners with zero new steps.
Drift between the checked-in copy and `assets/audio/generate.py`'s canonical output is caught by `assets/audio/test_client_bundle.py`, a new module `audio-ci.yml`'s existing `python3 -m unittest discover -s assets/audio` step already picks up with no workflow edit, asserting byte-for-byte equality file by file and that the copy carries no extra or missing file; the icon has no generator to diff against; mutation-tested both ways (a flipped byte, an extra stray file), each caught and each restored by hand to a confirmed byte-identical state.

**`Helper.setVolume` (per-participant call volume) is documented as throwing on Windows, and the client already guards against calling it there.**
Confirmed from the pre-trim the pre-trim `CLAUDE.md`'s "Moderating a member" section: Windows and Linux share flutter_webrtc's `common/cpp` native layer, whose track lookup only scans a `remote_streams_` map filled by the Plan B `OnAddStream` callback; LiveKit uses Unified Plan, so that map is always empty and the call throws "Unable to find provided track".
`client/packages/rtc/lib/src/audio_gain.dart`'s `supportsParticipantVolume` is already gated to Android, iOS and macOS only (`lk.lkPlatformIs` checks for those three, confirmed by reading the file), so Windows is already correctly excluded and the slider will not render there once the platform exists.
*The rule to keep*: never add a call path that reaches `Helper.setVolume` without going through this same platform gate.

**Camera background blur has no native per-frame hook on Windows at all, and this is explicitly "absent," not "unwired."**
Confirmed from `docs/research/background-blur-spike.md` (2026-08-01), which grepped the pinned ~~`flutter_webrtc` 1.4.0~~ source tree directly: "Linux and Windows have no native per-frame hook at all in the WebRTC plugin this project depends on: not missing wiring, missing entirely."
Version correction 2026-08-11: `client/pubspec.lock` resolves that package at **1.6.0** now; the finding was re-checked against the newer tree on 2026-08-10 and the native surface had not changed, so only the version number was stale.
The only path that document identifies for Windows is a genuine upstream contribution to `flutter_webrtc`'s shared `common/cpp` layer, or a from-scratch capturer - both well outside this project's own timeline.
The spike's own recommendation, worth carrying forward verbatim: ship blur where a real seam exists (iOS/macOS) and gate the camera toggle off, or clearly label it as unblurred, on platforms without one, rather than silently shipping raw camera everywhere or blocking camera indefinitely on a seam that will not exist uniformly for a long time. See [macos_backlog.md](macos_backlog.md) and [linux_backlog.md](linux_backlog.md) for the same finding on those platforms.

~~**The notification-sound symlink will very likely check out as a broken plain-text file on a native Windows clone, once a Windows target exists.**~~
Closed 2026-08-12 as a structural fix rather than confirmed-then-patched: the symlink is gone (see the confirmed entry above), so there is nothing left for a Windows checkout to materialise wrong.
Proven on Linux by reproducing the trap directly rather than only reasoning about it: `git clone -c core.symlinks=false` of `main` (pre-fix) lands `client/packages/app/assets/audio/notifications` as a 41-byte ASCII text file reading `../../../../../assets/audio/notifications`, exactly the failure this entry predicted; the identical clone of this branch (post-fix) lands seven real WAV files, byte-identical to the canonical source, regardless of the `core.symlinks` setting, since there is no symlink left for that setting to affect.
`notification_sound_bundle_test.dart` (cited in `CLAUDE.md`) still cannot exercise a real Windows checkout by itself, unchanged from what this entry originally said - what changed is that the mechanism it would have needed to catch no longer exists to be caught.

## Suspected

**Screen-share audio works on Windows at the OS level, and the client now offers it (2026-10-18).**
`supportsScreenShareAudio` returns true for Windows; `flutter_webrtc`'s `windows/application_loopback_capturer.cc` captures all system audio except slim-m's own process tree, so there is no call echo.
Verified on the win11 VM with a probe that replays the fork's WASAPI call sequence: another app's tone was captured (peak 2640), slim-m's own audio was not (peak 1), the include-own-process control was (peak 2543), and silence stayed silent.
Needs Windows 10 2004 or newer; on older Windows the activation fails and the share is video only, with no crash (read from the fork source, not run).
*Not yet checked*: the share dialog, the published track and a viewer hearing it, which need the client-windows-ci artifact for the branch, and the VM's own call hop to the host.

**Screen share is entirely unverified on Windows, in either direction.**
`docs/research/reference-echo-messenger.md` and CLAUDE.md's Linux findings establish real, tested behaviour for Fedora Wayland (a segfault on window enumeration, fixed by never requesting `SourceType.Window`) and a working owner-confirmed screen share on Linux in general.
Nothing in this repository, any CI workflow, or any research document exercises `getDisplayMedia`/`desktopCapturer.getSources` on Windows.
`client/packages/rtc/lib/src/desktop_sources.dart`'s own doc comment notes, in passing, that "macOS and Windows have no such native picker of their own, so this app's sheet stays their only one" - meaning the app's own source-selection sheet (not an OS compositor picker) is expected to be the only chooser on Windows, unlike the Wayland case where the portal supplies one.
That is read from source, not observed running, so it is suspected rather than confirmed: whether `flutter_webrtc`'s Windows desktop capturer enumerates and captures correctly at all has never been checked in this project.
Narrowed 2026-08-12, not closed: `windows/` is scaffolded now and `flutter_webrtc`'s Windows plugin registers cleanly in `generated_plugin_registrant.cc` (see the confirmed entry above), so the blocker to *running* the probe this entry names is gone, but nothing in this environment (no Windows machine, and this job's own CI addition is compile-only) has actually run it.
*What would confirm or refute this*: the same enumerate-then-capture probe the pre-trim the pre-trim CLAUDE.md describes doing for Fedora ("enumerating screens returns one source... capture with that id publishes a track"), run on a real Windows machine or a `windows-latest` runner extended to actually launch the built binary - `client-windows-ci.yml` does not do this, matching `linux-compiles`' own split from `linux-desktop-shell-smoke` in `client-ci.yml`, which this file's compile-only job has no Xvfb-equivalent counterpart for yet.

**`tflite_flutter`'s Windows native build path is unverified, and the package's own README frames desktop support as meaningfully different from mobile support.**
`docs/research/background-blur-spike.md`'s survey table lists `tflite_flutter` as covering Windows "with manual native build" versus "automatic" on Android/iOS, and the document states directly: "I did not attempt to build `tflite_flutter`'s desktop path in this environment... Whether it actually links on this project's own Fedora KDE Wayland target is unverified," with the same uncertainty extended explicitly to "Windows/macOS CI runners" in the spike's own "what this spike did not settle" section.
This only matters if camera blur is ever attempted on Windows via that specific library; the spike's own recommendation is not to build it there at all given the missing native hook (see the confirmed entry above), so this is recorded for completeness rather than as a near-term blocker.

**A frameless, custom title bar would need Windows-specific chrome, and nothing has been built ~~or spiked~~ for it.**
Half corrected 2026-08-11: it has now been spiked, in [decision 0012](../decisions/0012-desktop-window-shell.md), which designs the whole desktop window shell and was built for Linux in PR #533.
Nothing Windows-specific was built.
~~That record says so about itself in its own words - every Windows statement in it "is a design intent to build against once a platform exists, not a tested fact," since this client still has no `windows/` directory.~~
The premise changed 2026-08-12: `windows/` exists now, so decision 0012's own Windows statements are no longer blocked on a platform to build against - but this entry's own subject, the frameless custom title bar itself (step 6 of that record's migration order), is still genuinely unbuilt, and decision 0012 names it as the last, highest-cost, most-deferred step for a reason unrelated to platform scaffolding.
So the shape is decided and waiting rather than unconsidered.
`docs/BACKLOG.md`'s "A frameless window with our own title bar" entry (deferred, not declined) names the shape directly: "Three platforms want three different things: macOS traffic lights top-left with specific insets, Windows controls top-right, Linux depending on the desktop environment.
A single custom bar that ignores that feels foreign on at least two of them."
Window dragging, double-click-to-maximise, edge snapping, the system menu, and keyboard/screen-reader reachability for window controls would all need reimplementing for Windows specifically if this is ever picked up; none of it exists today, and it is deferred rather than scheduled. See the same entry noted in [macos_backlog.md](macos_backlog.md) and [linux_backlog.md](linux_backlog.md).

**`flutter_secure_storage`'s Windows backend (Credential Locker, via the `win32` package) has never been exercised.**
`client/packages/platform/pubspec.yaml` depends on `flutter_secure_storage: ^10.3.1`, which is the seam `persistent_key_store.dart` uses for the E2EE key-storage groundwork (`CLAUDE.md`'s design-alignment section: "a key-storage interface shaped so a future move to hardware-backed non-extractable keys needs no interface change").
The package's own Windows plugin resolves in the dependency tree (as part of the `win32`-coupled family discussed above, and now confirmed registered by name in `generated_plugin_registrant.cc` as `FlutterSecureStorageWindowsPlugin` - see the confirmed entry above), but no test or build in this repository has ever run its Windows storage backend, so whether it round-trips a stored secret correctly on that platform is unknown rather than assumed working.
Compiling is not exercising: `client-windows-ci.yml` proves the plugin links, nothing more.
