# Dependency rationale

Why the dependencies are the ones they are, and why their feature sets are cut the way they are.
Most of this file is the Rust server; the client section at the end covers `pubspec.yaml` holds that are not self-explanatory.

Neither a `Cargo.toml` nor a `pubspec.yaml` has a doc-comment mechanism and a plain comment in one is capped at two lines, so anything longer lives in this file and the manifest keeps a short note pointing at it.
Library-level decisions taken during the validation pass are in [decisions/0003-library-decisions.md](decisions/0003-library-decisions.md); this file is the running detail for the manifests themselves.

Shared versions live in the workspace `Cargo.toml` so every crate stays in lockstep.

## Auth primitives

`argon2`, `sha2` and `base64` are all long-established audited crates from the RustCrypto and BurntSushi families, not fresh single-maintainer projects.
They cover Argon2id password hashing, SHA-256 token hashing, and URL-safe base64 for the opaque token secrets.

`rand_core`'s `getrandom` feature turns on its OS entropy source (`OsRng`), which both the Argon2 salt and the opaque token secrets draw from.
This is the same `rand_core` that argon2's `password-hash` uses, so the feature simply unifies onto it.

## hmac

HMAC-SHA256 for the LiveKit access tokens, which are HS256 JWTs.
They are only ever signed here, never verified, so none of the JWT verification pitfalls (`alg=none`, algorithm confusion) are in play, and a full JWT library would be carrying parsing code this never runs.
It is the same RustCrypto family as `sha2`, and was already in the tree transitively.

## totp-rs

The RFC 6238 arithmetic for the optional second factor (decision 0048), rather than hand-rolling HOTP truncation over `hmac`.

Default features are empty and only `otpauth` is turned on, for the `otpauth://` provisioning URI an authenticator app scans.
`gen_secret` is deliberately left off: it would pull a second `rand` into the tree, and the secret is minted from the `rand_core` `OsRng` that already backs every other secret here.

It is held at the 5.x line, and that hold is load-bearing rather than staleness.
6.0 moved onto `hmac` 0.13 and `crypto-common` 0.2.x, which cannot co-exist with the `crypto-common` 0.2.0-rc.4 that `crypto_box`'s exact pin requires, for the same pre-release reason recorded under `ed25519-dalek` below: a pre-release satisfies nothing outside its own pre-release line.
Cargo cannot resolve the two at all, so this is a hard conflict rather than a preference.
5.x rides the `hmac`, `sha1` and `sha2` versions already in the tree and adds only `base32` and `constant_time_eq`.
Revisit when `crypto_box` reaches a stable 0.10.

## crypto_box

Anonymous sealed boxes (libsodium `crypto_box_seal`, X25519 plus XSalsa20Poly1305) for the content-free push envelope.
It is a pre-release because the `seal` API this needs has not had a 0.10 stable cut yet.
It is pinned to an exact version rather than a range, so a new pre-release cannot silently change behaviour underfoot.

## reqwest

The push relay HTTP client.
`rustls-tls` rather than the default `native-tls`, so the static musl release binary and the distroless image never need OpenSSL.
Its ring crypto provider needs only a C compiler, not cmake, so it fits the existing Alpine builder unchanged.

`url` is already pulled in transitively by reqwest.
It is named explicitly so the push relay URL's scheme and host can be validated at startup without hand-rolled parsing.

## ed25519-dalek

The server's long-lived identity keypair, behind the trust-on-first-use fingerprint.

Features are cut to `zeroize` only: no `std`, no `rand_core`, no `fast` (precomputed tables).
Nothing here signs anything yet, and deriving the keypair then storing the public half at boot is the only operation this crate performs.

It is held at 2.x rather than the freshly cut 3.0.0.
3.0.0 depends on curve25519-dalek's stable 5.0.0, which cargo cannot resolve alongside `crypto_box`'s pinned 5.0.0-pre.1 in the same tree, because a pre-release satisfies nothing outside its own pre-release line.

## jiff

The notification schedule (`docs/decisions/0033-notification-schedule.md`) needs a real IANA time zone database to evaluate a per-weekday window correctly across a daylight-saving transition; a fixed UTC offset, which is all quiet hours ever stored, is exactly the bug that decision replaces.

Built with `default-features = false` plus `std`, `tzdb-bundle-always` and `serde`: `tzdb-bundle-always` compiles the whole IANA database into the binary, since the release image (`gcr.io/distroless/static-debian12`) ships no `/usr/share/zoneinfo` for a runtime `TZDIR` lookup to find.
`chrono-tz` was the obvious alternative and was rejected only because this project has no existing `chrono` dependency to piggyback on; see the decision record for the full comparison.

## tikv-jemallocator

The server binary's global allocator, set in `crates/slimm-server/src/main.rs`.
The shipped image and the release binaries are static musl builds, and musl's own allocator is slow under a multi-threaded runtime: measured 2026-10-07 with `scripts/loadtest.py` (100 listeners, 50 senders at 5 messages a second, the marginal server CPU between 10 and 40 messages per sender, three runs each, same commit), musl cost about 260 microseconds of processor time per delivery against 87 for a glibc build.
With jemalloc the musl binary costs about 92, so the shipped image now does the work of the glibc one.
The 2026-10-01 performance audit's 88 microseconds was taken on a glibc dev build, which is how the musl gap went unnoticed.

Two alternatives were measured on the same runs and rejected.
mimalloc idled at 35 to 47 MB against a 30 MB budget, from its per-thread heaps across Tokio's workers.
Keeping musl's allocator keeps the lowest memory (12 MB idle, back to 18 MB after load), but at three times the processor.
jemalloc idles at 17 MB and settles at 39 MB after 1.2 million deliveries, against 18 MB for musl's: about 20 MB more after a heavy burst, for a third of the processor.
Its config is compiled in (`_rjem_malloc_conf`): a background thread and one-second decay, so a burst's freed pages go back within a second or so.
A glibc build without it kept 60 MB after the same burst, and never returned it.

jemalloc fixes its page size at build time and refuses to start on a kernel whose pages are bigger.
The arm64 image and release binary therefore build with `JEMALLOC_SYS_WITH_LG_PAGE=16` (64K), since 16K page kernels (the Raspberry Pi 5's default) and 64K ones (some arm servers) are both real self-host targets; amd64 pins the native 12 (4K).
The image's builder stage gains `make`, which `tikv-jemalloc-sys` needs to build the bundled jemalloc.

## The release profile

`opt-level = "z"`, LTO, one codegen unit, stripped, and `panic = "abort"`.
The brief treats binary size as a budget for a self-host binary, and `server-ci` enforces it at 20 MiB.

## Dev dependencies

`tower`'s `ServiceExt::oneshot` drives the HTTP round-trip tests in-process without binding a socket.
`tokio-tungstenite` is a real WebSocket client for the two-client fan-out test.

`jsonschema` backs `tests/response_contract.rs`, which validates real responses against `schema/openapi.yaml`.
An OpenAPI 3.1 schema object *is* a JSON Schema 2020-12 schema, so a general JSON Schema validator checks it directly, rather than a hand-written copy of each shape drifting alongside the real one.
`default-features = false` drops the file and http `$ref` resolvers, and the reqwest and aws-lc-rs they drag in: every `$ref` in that document is a local pointer into the one document.

`serde_yaml_ng` is the maintained fork of the archived `serde_yaml`, used only to turn the schema into a `serde_json::Value` the validator can compile.

## Client holds

### `package_info_plus` was held at 9.x, and is not any more

Kept here because the reason is not obvious and the trap can recur.

9.x was held because 10.x moves to `win32` 6, while every other Windows-only package in the tree sat on `win32` 5: `device_info_plus` (which `livekit_client` pulls in), `flutter_secure_storage_windows`, and `win32_registry`.
The non-obvious part is that this was never a Windows-only concern: those libraries type-check on a Linux build even though none of their code ever runs there, so a `win32` major mismatch is a hard build failure on every platform.

`file_picker` 12 and later need `win32` 6, so the whole tree moved rather than the hold being lifted on its own merits.
That is also why `device_info_plus` now carries a `dependency_overrides` entry: `livekit_client` 2.8.1 pins `^12.3.0`, and forcing 13.x is what lets `win32` 6 resolve.
That override was checked rather than assumed - see the pull request that introduced it - but it is the thing to look at first if voice starts misbehaving on a client build.

If a future conflict looks like this again, the wrong move is still to bump the other `win32` packages: they follow `livekit_client`, not preference.

### `audioplayers`, for the notification chimes

The client had no audio-playback dependency at all before the notification-sound slice (Phase 8): `assets/audio/` held seven synthesised WAVs and nothing played them.

Three real candidates, checked rather than assumed.
`just_audio` has no native Linux desktop support at all (would need the separately-maintained `just_audio_mpv`), which fails this project's own bar: Fedora KDE Plasma Wayland is where the client is validated day to day, not a release-only target.
`soundpool` has no Linux plugin either (android, ios, web, macos only, per its own pubspec), same failure for the same reason.
`flutter_soloud` covers Linux, but through a bundled native C++ library compiled via FFI - exactly the shape (a bundled native capturer, not a system library) that this project's own screen-share segfault-on-Wayland trap came from, and a newer, smaller-audience package than the alternative.

`audioplayers` (github.com/bluefireteam, published under `blue-fire.xyz`, a verified pub.dev publisher) is cross-platform including Linux desktop through `audioplayers_linux`, which wraps GStreamer - a system library already present rather than something newly compiled into the app, the same shape flutter_webrtc's own Linux plugin already uses safely in this codebase.
It is also the one of the three that exposes the iOS audio session category directly (`AudioContextIOS`), which is what lets a chime ask for `.ambient` rather than interrupting or ducking whatever else is playing - see `client/packages/app/lib/src/audio/notification_sound.dart`'s own doc comment for why `.ambient` specifically, and why `mixWithOthers` must *not* be set alongside it (`AudioContextIOS`'s own asserts refuse that combination; the category already implies it).
On Android it is configured to request no audio focus at all (`AndroidAudioFocus.none`), so a chime can never be the reason a call's audio pauses or ducks.

A single `AudioPlayer` instance handles every chime (`AudioPlayersSoundPlayer`), stopped and restarted on each `play()` call rather than pooled, since overlap is rare and briefly cutting one chime short for the next is not a defect worth the complexity of a pool.
Playback goes through a `SoundPlayer` seam so a test never touches a real audio device; see `notification_sound_message_test.dart`, `notification_sound_roster_test.dart` and `notification_sound_call_ring_test.dart` for the fakes.
The alone-in-a-call hold music (`hold_music_player.dart`) reuses the same package and the same no-audio-focus configuration.
Its loop is synthesised at play time from `scene_synth.dart`'s bell voice, so it ships no third-party audio and has no licence to record.
It goes to the device's own player and is never published to the room.
`audioplayers` has no output-device selection, so the loop plays on the system default output rather than the speaker chosen in Voice settings.

### No charting package, for the Space analytics screen

The Space usage analytics screen (`docs/decisions/0008-space-analytics.md`) needed three small bar charts: messages by day, active hours, and a memory series.
`fl_chart` and `syncfusion_flutter_charts` were the two real candidates, and both were rejected on the same grounds this project already used for the Voice Canvas and the speaking ring: a small, bespoke drawing is a `CustomPainter`, not a dependency, and this is three bar charts, not a dashboard toolkit.
`fl_chart` alone would have pulled in real weight (its own gesture, tooltip, and legend machinery) for a screen with no gestures, no legend, and one visible series each.
`AnalyticsBarChart` (`client/packages/app/lib/src/widgets/analytics_bar_chart.dart`) is under 100 lines and is reused for all three series rather than growing a chart type per series.

### `window_manager`, `tray_manager` and `screen_retriever`, for the desktop window shell

`docs/decisions/0012-desktop-window-shell.md` designs the startup animation, close-to-tray and the frameless title bar; these three are what it recommends and why, restated here since a manifest comment is capped at two lines.

All three are published by `leanflutter.dev`, a verified pub.dev publisher, actively maintained, and none bundles a native capturer the way `flutter_soloud` did for the notification-sound slice - the shape this project's own screen-share segfault-on-Wayland trap came from and now checks for on every new native plugin.
Each wraps system APIs already linked into the app rather than compiling anything new in: GTK/GDK on Linux (`window_manager`), Win32 (both, once Windows is scaffolded), AppKit (both, once macOS is scaffolded), and `libayatana-appindicator3` for the Linux tray icon, which is why the Linux build-dependency lists in `main-builds.yml`, `client-ci.yml` and `release.yml` all gained `libayatana-appindicator3-dev` alongside this change.

`bitsdojo_window` was rejected: it solves the identical frameless/drag/resize problem `window_manager`'s own `setAsFrameless()`/`startDragging()` already solve, and this project already declines to carry two packages doing one job (one `AudioPlayer` instance rather than a pool, one bar-chart `CustomPainter` rather than a charting library, above).
`system_tray` was rejected too: an older, separately-authored `tray_manager` alternative with no reason to prefer it once `tray_manager` already shares a publisher and an idiom family with the window package this pass already chose.

Writing the window and tray plumbing from scratch was considered and rejected, on the inverse of the FFI-versus-system-library reasoning above: these three are not a bundled native capturer needing compiling, they are thin wrappers over real, already-linked system libraries, so reimplementing three platform-specific window backends plus a D-Bus tray protocol buys nothing a maintained package does not already give.
One piece stayed hand-written anyway: the Linux tray-availability probe (`linux/runner/linux_tray_probe_channel.cc`), a single `org.kde.StatusNotifierWatcher` D-Bus property read.
Pulling in a general-purpose Dart D-Bus package for one boolean is heavier than the job needs when GDBus is already linked into the app via GTK/GIO, and this project already has the identical precedent in this same directory: `clipboard_image_channel.cc`, a roughly-90-line hand-written channel bridging one narrow piece of GTK/glib functionality no package covers.

### `archive`, for bulk emoji import

Backlog #137 unzips an admin-picked `.zip` client-side and uploads one custom emoji per image inside it, one `POST /emoji` per file rather than a new server route: see `client/packages/app/lib/src/screens/admin/emoji_bulk_plan.dart`.
`archive` is the standard pure-Dart zip codec (no FFI, no bundled native decoder), already present transitively through `image` (a `livekit_client` dependency), so this adds no new supply-chain surface, only a direct declaration of a package already in the resolved tree.

### `desktop_drop`, for OS drag-and-drop

Dragging a file onto the composer, or a `.zip` onto the emoji import card, reuses the exact same staging/upload paths the existing pickers already call - see `client/packages/app/lib/src/widgets/app_drop_zone.dart`.

`desktop_drop` (MixinNetwork) was picked over `super_drag_and_drop`: this feature only ever needs "which files landed on this widget", not `super_drag_and_drop`'s own virtual-file and clipboard-reading machinery, which this app has no other use for.
Its own `pubspec.yaml` declares plugin implementations for macOS, Linux, Windows, Android and web; there is no iOS entry, so `DropTarget` mounts everywhere but only ever receives events on the platforms that generate them.
Nothing here needs a `dart.library.*` conditional import: the package is a properly federated plugin (a real web implementation registered through the normal plugin registrant, not a `dart:io` shortcut), so `flutter build web --release` links it the same way it already links `file_picker`.
`app_drop_zone.dart` still gates the target on `kIsWeb` plus a desktop `defaultTargetPlatform`, never `Platform.isX`: a platform check here is about input capability, matching `docs/design/desktop-vs-mobile.md`'s own rule that a platform check is for capability, never for shape - OS drag-and-drop is meaningless on a touch screen regardless of which OS is under it.

### `media_kit`, `media_kit_video` and `media_kit_libs_video`, for inline video playback

A `video/*` attachment used to render as an inert filename chip on every platform.
`video_player`, the Flutter-team package, was the obvious first candidate and is the wrong one for this project: its own platform list stops at Android, iOS, macOS and web, with no Linux or Windows support at all - the identical failure `just_audio` and `soundpool` had for the notification-sound slice above, and the same bar applies: Fedora KDE Plasma Wayland is where this client is validated day to day, not a release-only target.

`media_kit` covers all six shipped platforms, Linux and Windows included, and was checked rather than assumed: `flutter build linux --release` and a real widget test constructing its `Player` both ran clean on this project's own Fedora 44 development machine, against the system `mpv-libs` package already installed there (see below), which is the strongest evidence available short of a manual playback session.

Unlike `audioplayers` and `window_manager` above, this is not a thin wrapper over an already-linked system library on every platform - it is one on Linux specifically, and something else everywhere else. There are two separate paths to `libmpv`, not one, and conflating them is a trap this project's own CI hit directly: `media_kit`'s own Dart FFI layer (`native_library.dart`) resolves `libmpv` at runtime through `dart:ffi`'s `DynamicLibrary.open` to drive playback, exactly the dlopen shape this section originally described - but `media_kit_video`'s own Linux plugin (the video texture/rendering integration) does something different, and does it at build time: its `linux/CMakeLists.txt` runs `pkg_check_modules(mpv IMPORTED_TARGET mpv)` and `pkg_check_modules(epoxy IMPORTED_TARGET epoxy)`, then `target_link_libraries`s the plugin against both. `flutter build linux --release` on a plain GitHub-hosted Ubuntu runner failed on exactly this - `CMake Error ... Target "media_kit_video_plugin" links to: PkgConfig::mpv ... but the target was not found` - which a widget test on this project's own Fedora machine never caught, because that machine already has `mpv-devel` installed for unrelated reasons. Reproduced in a clean `ubuntu:24.04` container to confirm the fix: installing `libmpv-dev` and `libepoxy-dev` makes the CMake error disappear, and `readelf -d` on the resulting `libmedia_kit_video_plugin.so` shows real `NEEDED` entries for `libmpv.so.2` and `libepoxy.so.0` - not dlopen, a genuine link. `.github/actions/linux-build-deps` (the one shared composite action `client-ci.yml`, `main-builds.yml` and `release.yml` all use) now installs both.

That link has a second consequence beyond the build: Flutter's Linux embedder dlopens every registered plugin at process startup, not only when a video is actually opened, so a machine missing `libmpv.so.2` or `libepoxy.so.0` at runtime may fail to launch the app at all - not merely fail to play a video. `client-ci.yml`'s `linux desktop shell smoke` job downloads the compiled bundle and runs it under Xvfb, so it now installs the runtime packages (`libmpv2`, `libepoxy0`) alongside the other runtime libs it already named explicitly for the same reason (see that job's own comment on why the compile job's `-dev` packages do not carry over). On Android, iOS, macOS and Windows, `media_kit_libs_video` bundles a real prebuilt `libmpv` inside the plugin, the same shape `window_manager`'s wrappers use for their own platforms. On Linux, `media_kit_libs_linux` bundles nothing at all - a deliberate upstream choice ("this is how GNU/Linux works," its own README) - so both shared libraries have to already be on the machine, the same way GStreamer already has to be on the machine for `audioplayers_linux`. `packaging/rpm/slim-m-client.spec` now names the exact sonames (`libmpv.so.2` and `libepoxy.so.0`, not the unversioned `libmpv.so` the upstream docs quote, since a plain `mpv-libs` install - no `-devel` - only ships the versioned one, confirmed by installing it and checking) as explicit `Requires`, alongside the ones rpm's own ELF scan should already catch on its own now that they are real links rather than dlopen targets.

The Flatpak manifest (`packaging/flatpak/top.npcserver.slimm.yaml`) shipped this gap for a while: `org.freedesktop.Platform` carries no `libmpv`, and nothing built or vendored one the way `libayatana-appindicator3` already gets a module for the tray icon, so Flatpak installs of the client could not even launch. Closed by inspecting the runtime directly rather than assuming: `org.freedesktop.Platform//25.08` already carries `libepoxy.so.0` and the ffmpeg libraries (`libavcodec`/`libavformat`/`libavutil`/`libswscale`/`libswresample`) mpv links against, so neither is vendored. `libmpv` is genuinely absent, so a `libass` module and a `libplacebo`/`mpv` module pair now build it from source: `-Dcplayer=false -Dlibmpv=true` builds only the shared library mpv exposes to `media_kit_video`, not the CLI player. mpv has linked libplacebo unconditionally since 0.37, even for its plain GL output, not only its optional `vo_gpu_next` - avoiding that module by pinning mpv below 0.37 was rejected as a worse trade, since it means shipping a video-playback dependency more than two years stale for a shipping blocker fix. Both mpv and libplacebo build with Vulkan disabled (GL only), since `media_kit_video` only ever drives mpv's plain GL output and Vulkan support would add a second GPU API surface, and its own dependencies (`shaderc`, `glslang`), for no use. Built with `org.flatpak.Builder`, installed, and launched for real, twice, to isolate the fix from everything else on the build machine: the manifest without these modules reproduces the exact reported bug (`slim-m: error while loading shared libraries: libmpv.so.2: cannot open shared object file`), and the manifest with them gets straight past it, with `ldd` inside the installed sandbox confirming `libmpv.so.2`, `libepoxy.so.0`, `libass.so.9` and `libplacebo.so.360` all resolve. That run still didn't reach a window: it stopped on a separate, already-documented, unrelated defect in `packaging/flatpak/README.md` - a `GLIBC_2.43` symbol version the LiveKit Rust plugin picked up from being built on this machine's own newer glibc, not from anything media_kit touches - so a video attachment actually playing is still unconfirmed on this host. The rpm and the plain release tarball were already unaffected, since both rely on the distribution's own `mpv-libs`/`libepoxy` packages rather than the Flatpak sandbox's runtime.

The portable Linux tarball does not bundle `libmpv.so.2`, and this was decided rather than overlooked: a fresh Ubuntu 24.04 does not start `slimm_app` until `libmpv2` is installed, but Debian and Ubuntu build `libmpv2` under GPL-2+ (its `debian/copyright` lists `GPL-2+` alongside LGPL-2.1+) and it depends on roughly fifty packages including ffmpeg, which are GPL in the same builds. Shipping those next to a PolyForm Noncommercial client is not licence-clean, and an LGPL-only mpv/ffmpeg build would mean compiling and maintaining our own copies for every distribution. Instead the tarball ships a `slim-m` launcher (`packaging/linux/slim-m`) that runs `ldd` over the binary and every plugin, and prints the distro-specific package to install (`libmpv2` on Debian/Ubuntu and openSUSE, `mpv-libs` on Fedora, `mpv` on Arch) before exiting. Checked on the four test VMs against the released 0.87.0 tarball: Ubuntu 24.04 without `libmpv2` prints the message and, once installed, opens the window; openSUSE Tumbleweed and Arch report `libmpv.so.2` as their only missing library, and Fedora already has everything. `libjvm.so` shows as unresolved on every distribution because `libdartjni.so` links it, and is ignored since the app does not use the JVM bridge on Linux.

The web backend is different again: `media_kit` embeds a plain HTML `<video>` element there rather than `libmpv`, and that element cannot carry the app's own bearer-token header the way a native network request can - see `attachment_video_source.dart`'s own doc comment for how each platform actually gets authenticated bytes to the player.

### `qr_flutter`, for the TOTP enrolment QR

The enrolment secret has to be scannable, or every member types 32 base32 characters by hand (decision 0048 keeps the text as well, because on a desktop the text is the normal path).

Chosen because it is the smallest thing that does the job: pure Dart painting over `qr`, no platform channel, no camera, no native build on any of the six targets, and BSD-3-Clause like most of this tree.
It only *draws* a code; nothing here reads one, so none of the camera-permission and platform-plugin weight of a scanner package comes with it.

### `local_auth`, for the biometric app lock

The owner's own ask ("Face ID login or finger print for devices without faceid") is really an app-lock feature, not a login: the server has no notion of a face or a fingerprint, so this can only ever gate access to a session slim-m already holds. `local_auth` is the Flutter team's own package for exactly that gate.

Constrained to `^3.0.1`, resolving to `3.0.2` at the time this landed; `3.x` was chosen over `2.x` for its simpler `authenticate`/`isDeviceSupported`/`LocalAuthException` surface.

Its own platform list is android, ios, macos and windows - there is no Linux implementation and no web implementation at all, so `supportsBiometricLock` in `biometric_auth_channel.dart` is what the settings toggle checks before the control is ever shown, matching the project's own "no dead control" rule for a platform gap like this (see `install_format.dart`'s treatment of desktop packaging for the same pattern).

License is BSD-3-Clause (the `flutter/packages` monorepo's own license), already on `deny.toml`'s allowlist, so no exception was needed.

### `flutter_timezone`, for the notification schedule's own device zone

The notification schedule (`docs/decisions/0033-notification-schedule.md`) needs the device's own IANA time zone name (`"America/New_York"`, not a raw UTC offset) so the server can evaluate the schedule correctly across a daylight-saving transition.

Flutter has no built-in way to ask the platform for this: `DateTime.now().timeZoneName` gives an abbreviation (`"PDT"`), not an IANA identifier, and there is no cross-platform API for the real one.
`flutter_timezone` (`tjarvstrand/flutter_timezone`, a maintained fork of the archived `flutter_native_timezone`, verified publisher on pub.dev) is a thin platform-channel wrapper reading the native zone: `TimeZone.getDefault().getID()` on Android, `NSTimeZone.local.identifier` on iOS/macOS, and the Linux/Windows equivalents.
Its own platform list covers Android, iOS, macOS, Windows, Linux and web, matching every platform this client ships to.

License is Apache-2.0, already on `deny.toml`'s allowlist.

### `share_plus` and `gal`, for sharing and saving an opened image

The image viewer's Share and Save controls (`fullscreen_image_actions.dart`, `image_export.dart`) need two system integrations: the OS share sheet, and the phone's photo library.
They are two packages because no single one does both, and each is only ever called on the platforms that have the thing it wraps.

`share_plus` (fluttercommunity.dev, verified publisher, BSD-3-Clause) wraps `UIActivityViewController` on iOS and `ACTION_SEND` on Android.
It also lists Linux, Windows and web, but there it degrades to a mailto or Web Share fallback rather than a real share sheet, so the viewer only shows the Share control on iOS and Android and never on a desktop window.
`super_clipboard` and `flutter_sharing_intent` were not looked at further: the first is a clipboard library and the second is about receiving shares.

`gal` (midoridesign.studio, MIT) writes bytes to the photo library on Android (SDK 21+), iOS 11+, macOS and Windows, using the platform's own media APIs with no bundled native library.
It has no Linux implementation, and this client does not call it off a phone anyway.
`image_gallery_saver` was rejected as unmaintained, and `saver_gallery` as a smaller fork doing the same job.
`file_picker` (already a dependency) cannot stand in for it: on iOS its `saveFile` is a Files export, not the photo library, and on Android it is the create-document flow.

Everywhere without a phone photo library, Save keeps using `file_picker`'s `saveFile`: a native Save as dialog on desktop and a download on web.
That is one existing dependency covering three platforms, so the two new packages only cover the two.

Permissions: iOS gets `NSPhotoLibraryAddUsageDescription` (write only, so no read prompt), and `hygiene.yml`'s purpose-string check now requires it.
Android gets `WRITE_EXTERNAL_STORAGE` capped at `maxSdkVersion="29"`, which `gal` documents as the only case needing it; Android 10 and later need none.
A refused permission surfaces as an `AppErrorState` naming Settings, never a silent no-op.
Neither iOS nor Android behavior has been run on a real device yet.

### `dbus`, for reading what a local player is playing

Rich presence (`docs/decisions/0044-rich-presence.md`) reads the current track from any MPRIS player on Linux, which means talking to the session bus.
`dbus` is the pure-Dart D-Bus client (`canonical/dbus.dart`), already in the tree as a transitive dependency at 0.7.14 and now a direct one of `slimm_platform`.
It is imported only through `now_playing.dart`'s conditional import, so a web build never compiles it, and only a Linux build ever opens a bus connection, and only while the person has switched sharing on.

License is BSD-3-Clause, already on `deny.toml`'s allowlist.

### `flutter_webrtc`, pinned to a fork for the Wayland screen picker

`flutter_webrtc` resolves from `github.com/Slim-m-org/flutter-webrtc` at a commit SHA, through `dependency_overrides` in `client/pubspec.yaml`.
The fork is upstream v1.6.0 plus two commits.
The first adds a `resetDesktopSources` method, so a share on Linux/Wayland can open the portal picker again.
The second opens the camera off the platform thread on Linux and Windows, where that thread also paints the window and takes input: a 4K webcam took about 3.8 s to open and froze the whole app for that long.
It also fixes the plugin's Linux and Windows task runners, which ran each task while holding their queue lock and hung if a task enqueued another.
It is an override rather than a dependency of `slimm_rtc` because `livekit_client` 2.10.0 requires `flutter_webrtc` from pub.dev, and pub refuses two sources for one package.
`scripts/check-dart-licenses.py` reads the fork's LICENSE (MIT) from the pub cache's checkout, so it is classified like a hosted package.
Rebase steps are in `docs/research/linux-wayland-share-switch-2026-09-29/README.md`.

### `photo_manager`, for the phone composer's photo strip

The composer on a phone shows a strip of recent photos where the keyboard sits (`composer_photo_strip.dart`), instead of sending the user out to a system picker.
`file_picker` (already a dependency) cannot do this: it only opens the OS picker and returns the chosen file, and has no way to list the library or draw thumbnails in our own UI.
`photo_manager` (fluttercandies, Apache-2.0) is the maintained plugin that lists assets, renders thumbnails and reports the permission state, including the limited grant on iOS 14+ and Android 14+.
Its platform list is Android, iOS, macOS and OpenHarmony; it has no Linux, Windows or web implementation, so `photo_library_native.dart` is only reached through a `dart.library.io` conditional import and only builds a library on iOS and Android.
Everywhere else `photoLibraryProvider` is null and the Photos menu entry opens the system picker as before.

Permissions: iOS reuses the existing `NSPhotoLibraryUsageDescription` (checked by `hygiene.yml`'s purpose-string step), whose text already says the app opens the photo library to attach an image.
Android declares `READ_MEDIA_IMAGES` (API 33+) and `READ_MEDIA_VISUAL_USER_SELECTED` (API 34+, the partial grant); the plugin supplies `READ_EXTERNAL_STORAGE` up to API 32.
A denied grant shows an inline panel with a button into the system picker, and a limited grant shows the allowed photos with an "Allow more" button that reopens the OS selection UI.
`image_picker` was not considered: it, too, only opens the OS picker.
