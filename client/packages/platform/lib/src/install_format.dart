// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How this desktop build was packaged, which decides how it can be updated:
/// a user-owned tarball or AppImage can replace itself, a flatpak must defer
/// to `flatpak update`, and an rpm or deb must defer to the system package
/// manager. See decision 0020.
///
/// The answer is baked into each build artifact at package time via
/// `--dart-define=SLIMM_INSTALL_FORMAT=...`, which is authoritative; runtime
/// environment sniffing is only a fallback and a cross-check for a build that
/// carries no define (a plain `flutter run`, or an artifact whose packaging
/// step forgot to set it).
library;

import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'host_platform.dart';

/// The packaging of a running desktop build.
enum InstallFormat {
  /// A single self-contained AppImage file; can replace itself in place.
  appImage,

  /// A portable extracted tarball; can replace itself if its directory is
  /// user-writable.
  tarball,

  /// A flatpak, sandboxed; cannot self-update, updates via `flatpak update`.
  flatpak,

  /// An rpm package; root-owned, updates via the system package manager.
  rpm,

  /// A deb package; root-owned, updates via the system package manager.
  deb,

  /// A sideloaded Android apk; has no store to hand off to, so the release page
  /// is how it gets a new version.
  apk,

  /// Not a desktop or Android build, or the packaging could not be determined.
  unknown,
}

/// The baked-in format, or empty when none was set at build time.
const String _bakedFormat = String.fromEnvironment('SLIMM_INSTALL_FORMAT');

/// This build's [InstallFormat]. Prefers the baked define; falls back to
/// sniffing the environment when the define is absent.
InstallFormat currentInstallFormat() => installFormatForHost(
      isWeb: kIsWeb,
      isAndroid: isAndroidHost,
      isDesktop: isDesktopHost,
      desktop: () => resolveInstallFormat(
        baked: _bakedFormat,
        env: Platform.environment,
        executablePath: Platform.resolvedExecutable,
        flatpakInfoExists: _flatpakInfoExists(),
      ),
    );

/// The pure decision behind [currentInstallFormat]: which kind of host this is
/// picks the answer, and only a desktop host sniffs its packaging through
/// [desktop]. Takes the host as arguments because `Platform.isAndroid` cannot
/// be faked in a test.
InstallFormat installFormatForHost({
  required bool isWeb,
  required bool isAndroid,
  required bool isDesktop,
  required InstallFormat Function() desktop,
}) {
  if (isWeb) return InstallFormat.unknown;
  if (isAndroid) return InstallFormat.apk;
  if (!isDesktop) return InstallFormat.unknown;
  return desktop();
}

/// The pure decision behind [currentInstallFormat], with every input passed
/// in so it can be tested without a real build's environment. Prefers
/// [baked]; sniffs otherwise.
InstallFormat resolveInstallFormat({
  required String baked,
  required Map<String, String> env,
  required String executablePath,
  required bool flatpakInfoExists,
}) {
  final parsed = _parse(baked);
  if (parsed != InstallFormat.unknown) return parsed;

  if (env.containsKey('APPIMAGE')) return InstallFormat.appImage;
  if (env.containsKey('FLATPAK_ID') || flatpakInfoExists) {
    return InstallFormat.flatpak;
  }
  if (executablePath.startsWith('/usr/') ||
      executablePath.startsWith('/opt/')) {
    // Root-owned; reported as rpm, whose copy says "your package manager".
    return InstallFormat.rpm;
  }
  return InstallFormat.tarball;
}

InstallFormat _parse(String raw) => switch (raw.trim().toLowerCase()) {
      'appimage' => InstallFormat.appImage,
      'tarball' => InstallFormat.tarball,
      'flatpak' => InstallFormat.flatpak,
      'rpm' => InstallFormat.rpm,
      'deb' => InstallFormat.deb,
      _ => InstallFormat.unknown,
    };

bool _flatpakInfoExists() {
  try {
    return File('/.flatpak-info').existsSync();
  } catch (_) {
    return false;
  }
}
