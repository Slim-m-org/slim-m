# slim-m desktop client (portable Linux build)

This is the Flutter bundle exactly as the release pipeline builds it: the app, its plugins, the Flutter engine and the WebRTC library, plus the asset tree under `data/`.
Nothing here needs installing.

```bash
./slim-m
```

`slim-m` is a small launcher that checks the bundle's shared libraries first and names the package to install for any that are missing, then starts `slimm_app`.
Running `./slimm_app` directly works too, but a missing library then shows only the loader's own error.

The runner locates `data/` and `lib/` relative to its own path, so the directory has to stay together, but it can live anywhere and it can be moved.

## Per-user install that updates itself

```bash
./install.sh
```

This copies the bundle to `~/.local/share/slim-m/<version>/`, points `~/.local/share/slim-m/current` at it and links `~/.local/bin/slim-m` to the launcher.
It also installs a desktop entry and icons under `~/.local/share`, and registers slim-m as the handler for `slimm://` links, so an invite link or the Spotify sign-in redirect opens this install.
If the rpm is installed too, the per-user entry takes over those links.
Nothing outside your home directory is touched.

An install laid out this way updates itself.
slim-m downloads the next release, checks its signature and sha256, unpacks it into a new version directory and moves `current` over with a rename.
The previous version stays until the new one has run cleanly once.
If the new version fails to start twice, the launcher moves `current` back and slim-m tells you on the next start.
The launcher is part of each version directory and `~/.local/bin/slim-m` links through `current`, so an update replaces the launcher along with the app with no extra step.
A tarball run from anywhere else, the rpm and the flatpak never replace themselves.

## What it needs from the system

GTK 3, and the usual desktop graphics stack, come from your distribution.
The first four libraries below are opened by name at runtime rather than linked, so a missing one fails only when you reach the feature rather than at startup.
The tarball has no dependency mechanism of its own to declare any of the rest, unlike the rpm below, so the app simply refuses to start if one of those is missing:

| Library | Missing means |
|---|---|
| `libGL.so.1`, `libEGL.so.1` | the window never renders |
| `libpulse.so.0`, `libasound.so.2` | no microphone or speaker in a call |
| `libpipewire-0.3.so.0` | no screen share |
| `libmpv.so.2` (video playback) | linked, so the app will not start without it |
| `libepoxy.so.0` | linked, so the app will not start without it |
| `libsecret-1.so.0` | linked, so the app will not start without it |
| `libgstreamer-1.0.so.0`, `libgstapp-1.0.so.0` (GStreamer, the audio backend) | linked, so the app will not start without it |
| `libayatana-appindicator3.so.1` (the tray icon) | linked, so the app will not start without it |

`libmpv.so.2` is the one a fresh machine most often lacks: install `libmpv2` on Debian and Ubuntu, `mpv-libs` on Fedora, `libmpv2` on openSUSE, or `mpv` on Arch.
It is not bundled because distro builds of mpv and ffmpeg are GPL, which does not combine with this project's licence, and because the set of libraries it pulls in is large and differs per distribution.

Screen share also needs `xdg-desktop-portal` running, and a remembered sign-in needs a Secret Service provider (gnome-keyring, KWallet, KeePassXC).

On Fedora, prefer the packaged build once it is available:

```
sudo dnf copr enable nc1107/slim-m
sudo dnf install slim-m-client
```

That wires all of the above as package dependencies and puts slim-m in the application launcher.
The COPR repository exists; the first package lands with the next tagged client release, so if `dnf install` finds nothing yet, this tarball is the current answer.

### Upgrading, and why a new release can look missing for two days

`sudo dnf upgrade slim-m-client` answering "Nothing to do" the day a release ships does not mean the repository is disabled or the build failed.

dnf caches repository metadata, and the COPR-generated `.repo` file sets no `metadata_expire`, so dnf's default of **48 hours** applies.
Until that lapses, dnf answers from a cache written before the new build existed and reports, correctly for what it knows, that there is nothing to do.

`sudo dnf copr enable nc1107/slim-m` appears to fix it, which is misleading: it rewrites the `.repo` file, and that invalidates the cache as a side effect.
The repository was enabled the whole time.

Ask for fresh metadata instead:

```
sudo dnf upgrade --refresh slim-m-client
```

Or, to stop having to remember the flag, tell dnf to check this one repository more often:

```
sudo dnf config-manager setopt copr:copr.fedorainfracloud.org:nc1107:slim-m.metadata_expire=1h
```

The cost of the shorter window is one small metadata fetch per hour of use, against a release being invisible for up to two days.
