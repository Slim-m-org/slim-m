# The flatpak manifest

`top.npcserver.slimm.yaml` packages the slim-m desktop client as a Flatpak.
It is the primary Linux artifact per `docs/ROADMAP.md`'s Phase 9 entry ("Flatpak primary, rpm alongside"), and the last half of a residual that the pre-trim `CLAUDE.md` carried since 2026-07-28: the rpm half shipped that day, this half did not exist until now.

Like the rpm, it repackages the already-built Flutter Linux bundle rather than running `flutter build linux` inside the sandbox.
The sandbox has no network by default and `dart pub get` needs one.
So `release.yml`'s `linux-client` job builds the bundle first, and this manifest's `dir` source points straight at `client/packages/app/build/linux/x64/release/bundle`.

## What is verified, and how

This manifest has been built for real, several times now, with `org.flatpak.Builder` (the sandboxed Flathub build tool, installed with `flatpak install --user flathub org.flatpak.Builder`) against a real `flutter build linux --release` output produced on this machine.
Every pass produced a working `flatpak-builder` export and an installable `.flatpak` bundle, and `flatpak install --user` accepted every one.
The fourth defect below is the first pass that also launched the installed bundle, so the sandbox's own dynamic linker having resolved every plugin library is now confirmed by a real process starting, not only by reading `readelf`/`ldd` output against the unlaunched bundle.
**The app has still never painted a window on this machine**; see the fourth defect's own account below for exactly how far a launch gets and why.
Nothing here proves the window opens, that a call connects, or that any permission below is sufficient rather than merely plausible.

Two real defects were found and fixed by the first two builds, not by reading the manifest:

- **The app's own icon failed flatpak-builder's export-time icon check**, `... is not a valid icon: Format not recognized`.
  `packaging/linux/icons/top.npcserver.slimm.svg` opens with an SPDX/rationale comment before the `<svg>` tag, and gdk-pixbuf's SVG sniffer matches only `<svg` or `<!DOCTYPE svg` in the file's first bytes.
  It does not skip a leading comment to find the real tag.
  The manifest strips it at build time (`sed -n '/<svg/,$p'`) rather than editing the shared asset the rpm and every other icon size also read.
- **Four of the Flutter-built plugin `.so` files carry an absolute build-tree `RUNPATH`**, confirmed directly with `readelf -d`, the same defect the rpm's own README documents and fixes with `patchelf`.
  The Freedesktop SDK does not carry `patchelf` (checked with `find` inside `org.freedesktop.Sdk//25.08`, not assumed from the fact that some other flatpak used it), so the manifest fetches a pinned static release build of it from `NixOS/patchelf` on GitHub as a source used only during the build, never installed into `/app`.

## A third defect, found 2026-08-11: the close-to-tray window shell (PR #533) added a hard dependency this manifest never learned about

`tray_manager` (`client/packages/app/pubspec.yaml`) registers a StatusNotifierItem through `libayatana-appindicator3`, and its own `linux/CMakeLists.txt` links that library directly - not `dlopen`, a real `DT_NEEDED` entry - so a runtime that does not carry it does not fail to show a tray icon, it fails to start the plugin at all.
`org.freedesktop.Platform//25.08` carries none of the indicator stack (confirmed with `find` inside the runtime, the same discipline the patchelf source above already used): no `libayatana-appindicator3`, no `libdbusmenu`, no `libayatana-ido`, no `libayatana-indicator`.

The fix is a `libayatana-appindicator` module built from source, vendored from `flathub/shared-modules` under `packaging/flatpak/shared-modules/` (its own two nested dependencies, `intltool` and the indicator stack's four sub-modules, included) rather than added as a git submodule, since this repository has no other submodule to justify introducing the mechanism for one manifest.
Built clean in the same `org.flatpak.Builder` run as everything else; the installed bundle carries `libayatana-appindicator3.so.1`, `libayatana-indicator3.so.7`, `libayatana-ido3-0.4.so.0` and `libdbusmenu-{glib,gtk3}.so.4` under `/app/lib`, and `readelf -d` against every one of them, chased by hand, resolves entirely to either that same set or a library the runtime already carries (`libgtk-3`, `libglib-2.0`, and so on) - nothing left dangling.
`/app/lib` is on the sandbox's own linker search path unconditionally (`flatpak run --command=sh top.npcserver.slimm -c 'cat /etc/ld.so.conf'` prints a bare `/app/lib` line, no extra `LD_LIBRARY_PATH` needed), which is the mechanism that makes this work at all.
`--talk-name=org.kde.StatusNotifierWatcher` is the matching `finish-args` grant, the same one Vesktop's own manifest (Discord's unofficial Electron flatpak, also `tray_manager`-shaped) uses for the same purpose.

**What this pass could confirm and what it could not, stated precisely rather than rounded up.**
The soname a build links is not fixed by the library, it is fixed by which pkg-config name the build host happens to offer: `tray_manager`'s CMake tries `ayatana-appindicator3-0.1` first and falls back to the older `appindicator3-0.1`.
`release.yml` installs `libayatana-appindicator3-dev` on `ubuntu-latest`, and that Ubuntu package's own file listing (`packages.ubuntu.com`) ships only `ayatana-appindicator3-0.1.pc` - so the real, CI-built tarball links `libayatana-appindicator3.so.1`, which is exactly what this manifest's new module provides.
That reasoning was not left untested: building the identical tarball locally on this Fedora box, where `appindicator3-0.1.pc` exists but `ayatana-appindicator3-0.1.pc` does not, linked the older `libappindicator3.so.1` instead, confirmed with `readelf -d` - concrete, opposite-direction evidence that the naming genuinely tracks the build host rather than being a fixed property of the library, and that this local rebuild is not a faithful stand-in for the CI-built artifact on this one point.
The rpm carries the identical gap for the identical reason (`libtray_manager_plugin.so` sits inside `__requires_exclude`'s `lib.*_plugin\.so` pattern, so rpm's own ELF scan cannot see this either); fixed there too, in the same commit, with the reasoning in `packaging/rpm/README.md`'s own dependency table.

**A `flatpak-builder` operational trap, worth keeping for the next rebuild.** The first attempt at this failed with `Error: renameat(checkout-union-*, idotypebuiltins.c): Invalid cross-device link` partway through the `ayatana-ido` module's build - a real `EXDEV` from the kernel, not a manifest bug. It happened only once C-compiling modules entered the picture; nothing in the manifest before this pass ever built anything, only copied and patched prebuilt files, so nothing had exercised `flatpak-builder`'s own checkout-union merge step until now. The fix was pointing `TMPDIR` and `--state-dir` at the same granted filesystem the `--repo`/build-dir already live under, rather than letting `org.flatpak.Builder`'s own sandbox default them somewhere else. This is specific to running `flatpak-builder` as a Flatpak (`org.flatpak.Builder`), the only way available on this machine; `release.yml`'s CI step installs the native `flatpak-builder` apt package instead, which has no sandbox of its own to default a `TMPDIR` into a different filesystem, so this is unlikely to reproduce there - unconfirmed, since nothing here can run the actual CI job.

## The fourth defect, closed 2026-08-28: media_kit's libmpv gap actually blocked launch, confirmed both ways

The third defect above was found by reading the built plugin's own `NEEDED` entries, not by running the app.
`media_kit_video`'s Linux plugin has the identical shape (`libmpv.so.2` and `libepoxy.so.0`, both real links per `docs/dependencies.md`'s media_kit section) and `org.freedesktop.Platform//25.08` carried neither library the manifest built a module for at the time, so this one was closed by actually building both versions and launching each, rather than reasoning from the plugin's ELF headers alone.

`libepoxy` and the ffmpeg libraries mpv links against (`libavcodec`, `libavformat`, `libavutil`, `libswscale`, `libswresample`) are confirmed present in the runtime by inspection (`flatpak run --command=sh org.freedesktop.Platform//25.08`), so neither is vendored.
`libmpv` is genuinely absent, so a `libass` module and a `libplacebo`/`mpv` module pair were added, all three pinned by git tag and commit the same way the `libayatana-appindicator` module above is.
mpv has linked libplacebo unconditionally since 0.37 (checked directly against mpv's own `meson.build` at several tags, not assumed from a changelog line), so building a current mpv means building libplacebo too; both build with Vulkan disabled, since `media_kit_video` only ever drives mpv's plain GL output.

Built with `org.flatpak.Builder`, installed with `flatpak install --user`, and launched twice on this machine to isolate the fix from everything else running on it: once with the manifest as it stood before this pass (no `libass`/`libplacebo`/`mpv` modules), and once with them added, both from the identical Flutter bundle.
The first run reproduced the exact reported bug verbatim - `slim-m: error while loading shared libraries: libmpv.so.2: cannot open shared object file: No such file or directory` - proving the failure mode was real and not merely plausible from reading `readelf` output.
The second run got straight past it: no complaint about `libmpv.so.2`, `libepoxy.so.0`, `libass.so.9` or `libplacebo.so.360`, all four of which `ldd` inside the installed sandbox (`flatpak run --command=sh top.npcserver.slimm`) confirms resolve, the former two against `/app/lib` and the latter two against the runtime.
Getting to that comparison required a private, unshipped workaround for the third defect above: this machine has only the older `appindicator3-0.1.pc`, not `ayatana-appindicator3-0.1.pc`, so its local rebuild links `libappindicator3.so.1` rather than the `libayatana-appindicator3.so.1` the manifest's module provides, exactly the gap the third defect's own account already predicted rather than something this pass introduced.
A `LD_LIBRARY_PATH` override pointing at a private symlink (`libappindicator3.so.1 -> /app/lib/libayatana-appindicator3.so.1`), passed only via `flatpak run`'s own commandline flags and never written into the manifest, got both launches past that point so the libmpv comparison could run at all.

Neither run reached a window: both stopped at the glibc mismatch below, which is unrelated to media_kit and was already known.
That is a weaker result than "the app opened and played a video," and is reported as such rather than rounded up; see the "not verified" list below for exactly what remains open.

## What is not verified, and the one real problem found doing this on this machine

**The app has been launched, but never past the glibc mismatch below, so it has still never painted a window.**
No screenshot, no confirmation the GTK window paints, no confirmation a call connects, no confirmation the webcam or screen-share permissions below are the right shape rather than merely a documented pattern from another WebRTC flatpak app (Element's `im.riot.Riot.yaml`, fetched and read for this), and no confirmation a video attachment actually plays even though the fourth defect above confirms libmpv itself now loads.

**A real, reproducible glibc mismatch was found, and it is very likely specific to building on this machine rather than to the manifest.**
Inside the installed bundle, `ldd /app/slim-m/lib/liblivekit_client_plugin.so` reports `GLIBC_2.43' not found`.
`org.freedesktop.Platform//25.08`'s own `libm.so.6` tops out at `GLIBC_2.42` (checked with `objdump -T` inside `org.freedesktop.Sdk//25.08`), while this machine's own glibc, which built the bundle, is 2.43.
A newer symbol version than the runtime ships leaked into the LiveKit plugin's link.
`release.yml`'s `linux-client` job builds on GitHub's `ubuntu-latest`, which as of this writing is Ubuntu 24.04 LTS at glibc 2.39, comfortably under the runtime's 2.42 ceiling, so this specific failure most likely does not reproduce there.
It is recorded rather than silently worked around because "most likely" is not "confirmed," and because it names a real, general risk: if a future CI runner image ever ships a newer glibc than whatever `runtime-version` this manifest is pinned to, the same failure would recur, silently, for whichever plugin happens to pull in the newest symbol.
Nothing here fixes that risk structurally.
The mitigation is watching the first real release build's job log for exactly this `ldd`/`GLIBC_` shape if voice ever fails to load from a shipped Flatpak.
This is no longer only a theoretical risk found by reading `ldd` output: the fourth defect's own launch attempts hit it live, at process start, both times.

**Not attempted**, each for a stated reason: Flathub submission (out of scope per the task this manifest was built under; a real submission also wants an AppStream `metainfo.xml`, which nothing here writes); a 32-bit or aarch64 build (the rpm's own `ExclusiveArch: x86_64` reasoning applies identically, since the bundle `linux-client` builds is x86_64 only); and confirming the `--talk-name=org.freedesktop.secrets` and `--filesystem=xdg-run/pipewire-0` grants are sufficient rather than merely necessary, which needs a running app on a session with a Secret Service provider and a compositor, not a build sandbox.

## `release.yml`'s CI build had never once succeeded, through every release up to `client-v0.61.0`

Every tagged client release from the manifest's introduction through `client-v0.61.0` was checked directly (`gh release view` per tag): not one carries a `.flatpak` asset.
The `build flatpak` step's own `conclusion` reports `success` on every one of those runs regardless, because `continue-on-error: true` makes the field lie about a step that actually failed.
The real failure, read from `client-v0.61.0`'s own run logs: `flatpak-builder` strips debuginfo out of every module it builds and shells out to `eu-strip` to do it, and the step only ever installed `flatpak flatpak-builder`, never the `elfutils` package that provides `eu-strip` (and `eu-elfcompress`, which the same step warns about but does not hard-fail on).
It failed on `libdbusmenu`, a module that predates the mpv work in #964 by a wide margin, so this was never a video-plumbing regression; it was broken from the manifest's very first CI run and stayed that way because nothing was watching the artifact list, only the green checkmark the API reported.
The fix is one line: install `elfutils` alongside `flatpak flatpak-builder` in the same `apt-get install`.
Confirmed locally (below) that `org.flatpak.Builder`, the sandboxed stand-in used on this machine, does not need it, because a Flathub-published `flatpak-builder` build carries its own bundled `eu-strip`; the Ubuntu apt package used in CI does not, which is exactly why this only ever broke there.

## Why `release.yml`'s flatpak step is still `continue-on-error: true`

The rpm has shipped from dozens of real release runs; this manifest, even once the `eu-strip` fix lands, has none.
A release job that fails outright on a format with this little of a track record is worse than the warn-and-skip this repository already uses for an absent packaging input, so the same shape is extended to a present-but-possibly-broken one: `steps.pkg.outputs.flatpak` still gates whether the step runs at all, and `continue-on-error: true` means a failure inside it cannot take down the portable tarball or the rpm the same job already produces.
The checksums step already tolerates a missing `.flatpak` (`shopt -s nullglob`), so this costs nothing on the success path.
What changed is that a broken build can no longer hide behind that green checkmark: a `verify flatpak bundle was produced` step immediately after it checks `dist/*.flatpak` for real and fails, by name, with an `::error::` annotation, whenever the build step did not actually produce one.
That step is `continue-on-error: true` too, for the same non-blocking reason, but a named, annotated failure sitting right next to a real one is a different thing from the build step's own `conclusion` field silently reporting a lie - the six-release blind spot was never `continue-on-error` itself, it was that nothing else was checking what it was quietly letting through.
Once a few real releases have produced a working bundle, revisit whether `continue-on-error` should come off entirely.
The rpm needed no such guard once it had a track record.

## A fifth defect, found and fixed 2026-08-30: the manifest never actually built in CI at all, on any flatpak-builder version this old

The `eu-strip` fix above was necessary but not sufficient. `flatpak-ci.yml`'s first real run (a new PR-time workflow that builds this manifest before merge rather than only at `client-v*` tag time) failed the `ayatana-ido` -> `libayatana-indicator` step with `Package 'libayatana-ido3-0.4' not found`, even though the module order is correct (`intltool` -> `libdbusmenu` -> `ayatana-ido` -> `libayatana-indicator`) and `ayatana-ido` is pinned well above the version `libayatana-indicator`'s CMake requires.

The real cause, confirmed against the actual CI job log rather than reasoned from the manifest alone: `ayatana-ido`'s CMake step installed to `/app/lib64/pkgconfig/libayatana-ido3-0.4.pc`, not `/app/lib/pkgconfig`, so `libayatana-indicator`'s own `pkg_check_modules` call genuinely cannot find it.
That is CMake's own `GNUInstallDirs` module choosing `lib64` for `CMAKE_INSTALL_LIBDIR` on any 64-bit Linux system that lacks `/etc/debian_version` - which the `org.freedesktop.Sdk//25.08` sandbox does, since it is not a Debian derivative.
`/app/lib` is the one path the runtime's linker searches unconditionally (established by the fourth defect above), so this would have broken the installed bundle even if the build had somehow limped past the immediate CMake configure error.

Why this was never caught locally: `flatpak-builder` itself has carried an unconditional `-DCMAKE_INSTALL_LIBDIR:PATH='lib'` default for `cmake`/`cmake-ninja` modules since a July 2024 fix ([flatpak/flatpak-builder@745d6b7](https://github.com/flatpak/flatpak-builder/commit/745d6b7b2ffb5993f5e64bd29b86ac88ad611290), correcting an earlier, buggier absolute-path version of the same default), which exists precisely to paper over this `GNUInstallDirs` behavior.
`org.flatpak.Builder`, the Flathub-published sandboxed tool this README's own local verification runs use, tracks current flatpak-builder and already carries that default, so every local pass here built correctly without ever needing to set `CMAKE_INSTALL_LIBDIR` explicitly.
Ubuntu 24.04's apt package is `flatpak-builder 1.4.2-1build2` (read directly from the failing job's own `apt-get install` log), and `flatpak-builder`'s source at the `1.4.2` tag only passes `-DCMAKE_INSTALL_LIBDIR` when a module's manifest sets `build-options.libdir` explicitly - checked directly against `src/builder-module.c` and `src/builder-options.c` at that tag, not assumed - so on that version, an unset `libdir` means CMake never gets told, and falls through to its own `lib64` default inside the non-Debian sandbox.
This is the same shape as the `libayatana-appindicator3` vs `libayatana-ido3-0.4` soname drift the third defect documents above: a build result that depends on which host tool built it, not on the manifest text alone, except this time the divergence is in the orchestrator (`flatpak-builder`'s own version) rather than in the build host's `pkg-config` listing.

The fix is `"build-options": {"libdir": "lib"}` added to all three `cmake-ninja` modules in the chain - `libayatana-appindicator`, `ayatana-ido`, and `libayatana-indicator` - in `shared-modules/libayatana-appindicator/libayatana-appindicator-gtk3.json`.
It is set per module rather than once at the top of that file or the top-level manifest, because `flatpak-builder`'s own option resolution (`get_all_options` in `builder-options.c`) only checks a module's own `build-options` plus the single global one from the top-level app manifest, not an intermediate parent module's - so setting it once on the outer `libayatana-appindicator` module would not have reached its own nested `ayatana-ido`/`libayatana-indicator` sub-modules.
It is also not set globally on the top-level manifest, because the same `libdir` build-option means something different to `autotools`/`meson` (`--libdir=<value>`, used as-is) than it does to `cmake` (`-DCMAKE_INSTALL_LIBDIR=<value>`, relative to the prefix by convention): a single manifest-wide `libdir: lib` would have fixed the three `cmake-ninja` modules above while breaking `libdbusmenu` (autotools), `libplacebo` and `mpv` (meson), which currently work correctly only because they fall back to their own buildsystem's `<prefix>/lib` default when `libdir` is unset.
Confirmed, not guessed, that `libdbusmenu` and `libass` (both `autotools`) do not need this fix: both installed their `.pc` files to `/app/lib/pkgconfig` correctly in the CI runs below, with no `libdir` override.
`libplacebo` and `mpv` (both `meson`) turned out to need the identical fix, discovered on the very next run after the first fix landed: with the appindicator chain corrected, the build got further and failed again, this time with `libplacebo`'s own `.pc` installing to `/app/lib64/pkgconfig` and `mpv`'s `meson.build` then failing to find it.
That one is not a `flatpak-builder`-version story the way the `cmake-ninja` case is - `flatpak-builder` 1.4.2 never sets an explicit `--libdir` for `autotools`/`meson` modules at all, with or without the July 2024 fix, so `libass` and `libplacebo` were always going to fall back to whatever their own buildsystem defaults to; `meson`'s own default library directory detection carries the same non-Debian-defaults-to-`lib64` logic CMake's `GNUInstallDirs` does, `autotools`' plain default does not.
So the fourth defect's own local, `org.flatpak.Builder`-verified account of `libplacebo`/`mpv` working was accurate for that tool and that host, and still does not hold for `ubuntu-latest`'s `flatpak-builder` - a second, independent instance of a build result depending on which tool built it, layered on top of the first.
Fixed the same way: `"build-options": {"libdir": "lib"}` (YAML `build-options: {libdir: lib}` in the top-level manifest, since these two are top-level modules rather than nested inside a shared JSON file) added to both `libplacebo` and `mpv` directly.

This was diagnosed and fixed entirely from two real CI failures in sequence, per the standard the rest of this document holds itself to - not reasoned from the manifest text or reproduced locally, since the local tool that already carries safe defaults for at least the `cmake-ninja` case would not have reproduced the first failure, and this repository has no local copy of `flatpak-builder` 1.4.2 to have reproduced the second.
See `docs/ci.md`'s `flatpak-ci` section for the runs that caught each half of this and the run that confirms the full fix.

## A sixth defect, found and fixed 2026-08-30: icon export validation depends on a gdk-pixbuf loader the build host, not the sandbox, provides

With every module building and installing correctly (the fifth defect's fix in place), the same run got all the way to `flatpak-builder`'s export step and failed there instead: `.../export/share/icons/hicolor/scalable/apps/top.npcserver.slimm.svg is not a valid icon: Format not recognized`.

This looks exactly like the first defect this document opens with (gdk-pixbuf's SVG sniffer rejecting a leading comment), but it is not that defect recurring: the manifest's `sed -n '/<svg/,$p'` fix is still in the build log doing its job, and the resulting file, checked directly (well-formed XML, root element `{http://www.w3.org/2000/svg}svg`, loads at 512x512), is a valid SVG by every measure that matters.
The difference is where the check runs. `flatpak build-export` (called by `flatpak-builder` at the very end, not inside the build sandbox) validates every icon it exports through gdk-pixbuf running **on the CI runner itself**, and `ubuntu-latest` carries no gdk-pixbuf image loaders at all by default - not broken, just absent, so a perfectly valid SVG reports the same generic "Format not recognized" a genuinely corrupt one would.
`librsvg2-common` provides the loader (`libpixbufloader-svg.so`), confirmed directly against Ubuntu's own package-contents search for noble/amd64, not assumed.
Fixed by adding it to the `apt-get install` line in both `flatpak-ci.yml` and `release.yml`'s `build flatpak` steps - `release.yml`'s own flatpak build had never gotten far enough to hit this on any release through this fix, since the fourth and fifth defects were still blocking it.

## The pattern across all three real defects here: the build host leaks into the result

The soname drift (third defect), the CMake/meson libdir default (fifth defect), and this icon-export loader are the same shape three times over, not three unrelated bugs: each one is a place where `flatpak-builder` hands part of the job to whatever the **host** happens to provide - a `pkg-config` name, a buildsystem's own platform-detection default, a gdk-pixbuf loader - rather than something pinned by the manifest or carried inside the `org.freedesktop` sandbox.
The sandbox is real and does isolate the actual compiled output from the host in the ways it advertises; what it does not isolate is every tool `flatpak-builder` itself shells out to on the host's own account, and export-time validation is one of those.

The practical consequence: a build of this manifest on any machine is only as trustworthy as how closely that machine's host tooling matches the one that will actually ship it.
A local Fedora build proved the manifest could produce a working bundle at all, and still missed two of these three (the appindicator soname the other direction, and both the libdir default and the icon loader, since the local machine's own tooling happened to paper over or not trigger either).
That is the whole reason `flatpak-ci` builds on `ubuntu-latest` specifically, matching `release.yml`'s own `linux-client` runner rather than any other environment: it is the one host whose quirks are the ones that will actually reach a shipped release, so it is the only build result worth calling authoritative for this manifest.

## Permissions, briefly

The manifest's own inline comments carry the reasoning for each non-obvious `finish-args` entry.
The short version: `--device=all` is for the webcam (`flutter_webrtc`'s Linux capturer uses V4L2 directly, not the Camera portal, the same reason Element's own manifest grants it), `--talk-name=org.freedesktop.secrets` is for `flutter_secure_storage`'s libsecret backend (not portal-mediated), `--filesystem=xdg-run/pipewire-0` pairs with the ScreenCast portal for screen share (again matching Element's own grant for the same feature shape), and `--talk-name=org.kde.StatusNotifierWatcher` is `tray_manager`'s tray icon registering itself with whichever desktop's watcher implements that name, the same grant Vesktop's own manifest uses for the same plugin family.

## Reproducing this

```bash
flatpak install --user flathub org.flatpak.Builder
cd client/packages/app && flutter clean && dart pub get && flutter build linux --release && cd -
mkdir -p ~/.cache/slim-m-flatpak/tmp
flatpak run --user --env=TMPDIR=$HOME/.cache/slim-m-flatpak/tmp \
  --filesystem="$HOME/.cache/slim-m-flatpak" --filesystem="$PWD" --share=network \
  org.flatpak.Builder --user --install-deps-from=flathub --force-clean \
  --state-dir=$HOME/.cache/slim-m-flatpak/state --repo=$HOME/.cache/slim-m-flatpak/repo \
  $HOME/.cache/slim-m-flatpak/build-dir packaging/flatpak/top.npcserver.slimm.yaml
flatpak build-bundle $HOME/.cache/slim-m-flatpak/repo \
  $HOME/.cache/slim-m-flatpak/slim-m-client.flatpak top.npcserver.slimm
flatpak install --user $HOME/.cache/slim-m-flatpak/slim-m-client.flatpak
flatpak run top.npcserver.slimm   # launches; see the fourth defect above for how far
```

`~/.cache`, not `/tmp`: this box's own `/tmp` is a 16 GiB tmpfs shared with every other agent session on it, and this build's own sources and build tree run to several hundred MB.
`TMPDIR` and `--state-dir` under the same tree as `--repo` and the build dir is load-bearing once a module actually compiles something (see the `EXDEV` finding above) - keeping everything under one path is what avoids it, not the specific choice of `~/.cache` over `/tmp`.

`flutter clean` before `flutter build linux` is not optional if a previous `build/` was removed by hand rather than through `flutter clean`.
The CMake configuration under `linux/flutter/ephemeral` survives a bare `rm -rf build/` and then fails with `file INSTALL cannot find .../build/native_assets/linux`, since that directory no longer exists but the stale generated install script still expects it.
