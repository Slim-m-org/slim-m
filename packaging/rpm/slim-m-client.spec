# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Fedora package for the slim-m Linux desktop client, built and hosted on COPR.
# Install steps and how to cut a new COPR build: README.md alongside this file.

%global debug_package %{nil}
%global appid     top.npcserver.slimm
%global bundledir %{_libdir}/%{name}

# The hicolor sizes a Linux desktop actually looks in, chosen by counting what
# is installed under /usr/share/icons/hicolor/*/apps on a Fedora KDE box.
%global iconsizes 16 22 24 32 48 64 128 256 512

# The Flutter engine and its plugin .so files are private to this app, not distro
# libraries: rpm must neither advertise them nor try to resolve them elsewhere.
# Matched by shape rather than by name: every Flutter plugin builds to
# `lib<name>_plugin.so`, so a newly added plugin needs no edit here. The
# hand-kept list this replaces went stale the moment audioplayers landed and
# shipped a 0.31.0 rpm that required a library it contained but never advertised.
# System libraries the bundle genuinely needs (gstreamer, gtk, libsecret) are
# deliberately still resolved, so this must not become a by-path exclusion.
%global __provides_exclude_from ^%{bundledir}/.*\\.so$
%global __requires_exclude ^lib(flutter_linux_gtk|webrtc)\\.so|^lib.*_plugin\\.so

Name:           slim-m-client
# Bumped by hand for a COPR rebuild; the release workflow stamps the tag's
# version over this line, so the .rpm on a release always matches its tag.
Version:        0.4.0
Release:        1%{?dist}
Summary:        Desktop client for the slim-m self-hosted messaging platform

License:        LicenseRef-PolyForm-Noncommercial-1.0.0
URL:            https://github.com/Slim-m-org/slim-m
# The portable release tarball. Repackaged rather than built from source: a
# Flutter build needs network for pub, which a COPR/mock buildroot has not.
Source0:        https://github.com/Slim-m-org/slim-m/releases/download/client-v%{version}/slim-m-client-%{version}-linux-amd64.tar.gz
Source1:        top.npcserver.slimm.desktop
# The hicolor icons, from client/packages/design_system/brand. Every Source
# lands in one flat directory, which is why the sizes are in the basenames.
# Declared one by one, rather than globbed, so they travel inside the SRPM that
# the COPR job builds: rpmbuild only carries sources the spec names.
Source2:        top.npcserver.slimm-16.png
Source3:        top.npcserver.slimm-22.png
Source4:        top.npcserver.slimm-24.png
Source5:        top.npcserver.slimm-32.png
Source6:        top.npcserver.slimm-48.png
Source7:        top.npcserver.slimm-64.png
Source8:        top.npcserver.slimm-128.png
Source9:        top.npcserver.slimm-256.png
Source10:       top.npcserver.slimm-512.png
Source11:       top.npcserver.slimm.svg
# The COPR repo, so an rpm installed from a release download can update itself
# without first asking polkit to enable a repo. See the file's own header for
# why its id is not COPR's.
Source12:       slim-m-client.repo
# The polkit rule that pre-approves the client's own `dnf upgrade`. Security
# reasoning and the exact match: README.md alongside this file.
Source13:       49-slim-m-client-update.rules

# The upstream Flutter engine and the bundled libwebrtc are x86_64-only builds.
ExclusiveArch:  x86_64

BuildRequires:  tar
BuildRequires:  gzip
BuildRequires:  desktop-file-utils
BuildRequires:  patchelf

# Only what is dlopen'd, so rpm's ELF scan cannot see it. libwebrtc opens its
# audio and screencast backends by soname, and libepoxy opens GL the same way.
Requires:       libEGL.so.1()(64bit)
Requires:       libGL.so.1()(64bit)
Requires:       libasound.so.2()(64bit)
Requires:       libpulse.so.0()(64bit)
Requires:       libpipewire-0.3.so.0()(64bit)

# media_kit_video's own Linux plugin - the video texture/rendering
# integration, distinct from media_kit's separate dlopen of libmpv to drive
# playback - links libmpv and libepoxy directly (`pkg_check_modules` plus
# `target_link_libraries` in its own linux/CMakeLists.txt; confirmed with
# readelf on the built .so, which lists both as real NEEDED entries). rpm's
# own ELF scan should already pick these up automatically the way it does
# for GTK and GStreamer, but they are named explicitly as a fallback, and
# because a plain mpv-libs install (no -devel) ships only the versioned
# `libmpv.so.2`, never the unversioned name upstream's own install docs quote.
Requires:       libmpv.so.2()(64bit)
Requires:       libepoxy.so.0()(64bit)

# Services rather than libraries, and each backs one feature rather than the app:
# no portal means no screen share, no secret service means no remembered sign-in.
Recommends:     xdg-desktop-portal
# kf6-kwallet's ksecretd serves the same org.freedesktop.secrets libsecret wants.
Recommends:     (gnome-keyring or kf6-kwallet)

%description
The slim-m desktop client: text channels, voice, screen share and direct
messages against a slim-m home server, either one you run yourself or one
you were invited to. One deployment is one community.

This package repackages the official Linux release rather than building from
source. The Flutter engine, the WebRTC library and the app's plugins ship
inside it, the way upstream builds them; GTK, audio, graphics and the secret
service come from the system.

%prep
%setup -q -n %{name}-%{version}

%build
# Nothing to build - the bundle is prebuilt.

%install
install -d %{buildroot}%{bundledir}
cp -a slimm_app data lib %{buildroot}%{bundledir}/

# Flutter links its plugins against absolute paths inside the build tree, which
# check-rpaths rejects. Every one of them only ever needs its own directory.
for so in %{buildroot}%{bundledir}/lib/*.so; do
    patchelf --set-rpath '$ORIGIN' "${so}"
done

# Flutter writes its shared objects 0644; a shared library is expected to carry
# the executable bit, and rpm's own scanners key off it.
chmod 0755 %{buildroot}%{bundledir}/lib/*.so

# The runner resolves data/ and lib/ against /proc/self/exe, which reports the
# link target rather than the link, so a symlink works where a PATH shim does not.
install -d %{buildroot}%{_bindir}
ln -s ../%{_lib}/%{name}/slimm_app %{buildroot}%{_bindir}/slim-m

desktop-file-install --dir=%{buildroot}%{_datadir}/applications %{SOURCE1}

# Installed under the name the .desktop's Icon= line asks for. A mismatch here
# shows as a generic placeholder in the launcher and nothing warns about it.
for px in %{iconsizes}; do
    install -Dpm0644 %{_sourcedir}/%{appid}-${px}.png \
        %{buildroot}%{_datadir}/icons/hicolor/${px}x${px}/apps/%{appid}.png
done
# Scalable covers the sizes above plus every HiDPI scale of them, and is the
# most populated apps directory in hicolor on a real desktop.
install -Dpm0644 %{SOURCE11} \
    %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/%{appid}.svg

install -Dpm0644 %{SOURCE12} %{buildroot}%{_sysconfdir}/yum.repos.d/%{name}.repo

install -Dpm0644 %{SOURCE13} \
    %{buildroot}%{_datadir}/polkit-1/rules.d/49-%{name}-update.rules

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/%{appid}.desktop
# The runner is useless without these two, and a bundle that lost them would
# otherwise package cleanly and fail at launch on the user's machine.
test -x %{buildroot}%{bundledir}/slimm_app
test -f %{buildroot}%{bundledir}/data/icudtl.dat
# The %%files globs below would pass on a partial set, and a missing size falls
# back to a scaled neighbour silently, so assert every one landed.
for px in %{iconsizes}; do
    test -f %{buildroot}%{_datadir}/icons/hicolor/${px}x${px}/apps/%{appid}.png
done
test -f %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/%{appid}.svg
# The updater matches on the repo id, so a renamed section is a silent
# regression: it would fall back to prompting for polkit on every update.
grep -qx '\[slim-m\]' %{buildroot}%{_sysconfdir}/yum.repos.d/%{name}.repo
test -f %{buildroot}%{_datadir}/polkit-1/rules.d/49-%{name}-update.rules

%files
%license LICENSE
%doc README.md
%{_bindir}/slim-m
%{bundledir}/
%{_datadir}/applications/%{appid}.desktop
# No gtk-update-icon-cache scriptlet: Fedora's filesystem package carries a file
# trigger on this directory that rebuilds the cache for us.
%{_datadir}/icons/hicolor/*/apps/%{appid}.png
%{_datadir}/icons/hicolor/scalable/apps/%{appid}.svg
%config(noreplace) %{_sysconfdir}/yum.repos.d/%{name}.repo
%{_datadir}/polkit-1/rules.d/49-%{name}-update.rules

%changelog
* Mon Jul 27 2026 NC1107 <nickpconn@gmail.com> - 0.4.0-1
- Initial COPR packaging (repackage of the official Linux release tarball).
