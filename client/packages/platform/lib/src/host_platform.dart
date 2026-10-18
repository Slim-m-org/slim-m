// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which operating system this build is running on, safe to ask from a
/// browser.
///
/// `dart:io` compiles on Flutter web, but every `Platform` getter is a stub
/// that throws `UnsupportedError`. A bare `Platform.isAndroid` therefore does
/// not answer "no" in a browser, it takes the whole app down before the first
/// frame. Every read short-circuits on [kIsWeb] first, which dart2js folds to
/// a constant, so the `dart:io` stub is never reached in a web build.
///
/// A browser on a phone is deliberately still false here. These answer "can
/// this build reach that OS's native APIs", not "what hardware is this", and
/// Safari on an iPhone has no APNs channel to bridge.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// True only for a native iOS build.
bool get isIOSHost => !kIsWeb && Platform.isIOS;

/// True only for a native Android build.
bool get isAndroidHost => !kIsWeb && Platform.isAndroid;

/// True only for a native Linux desktop build.
bool get isLinuxHost => !kIsWeb && Platform.isLinux;

/// True only for a native macOS build.
bool get isMacOSHost => !kIsWeb && Platform.isMacOS;

/// True only for a native Windows build.
bool get isWindowsHost => !kIsWeb && Platform.isWindows;

/// Any of the three desktop targets, native builds only. A browser on a
/// laptop is deliberately still false: this answers "does this build own a
/// window it can move, resize and hide", and a tab in a browser owns none of
/// that regardless of the hardware underneath it.
bool get isDesktopHost => isLinuxHost || isMacOSHost || isWindowsHost;

/// A short, human-recognisable name for this device, sent as `device_name`
/// on sign-in and registration so the Devices list in settings can tell one
/// session from another.
///
/// This is the synchronous fallback: platform plus host name. A phone's real
/// model needs an async platform call, which [resolveDeviceName] makes before
/// falling back to this. Reads [defaultTargetPlatform] rather than [Platform]
/// so it answers on web, where `dart:io`'s stub would throw.
String get deviceDisplayName => composeDeviceName(
      defaultTargetPlatform,
      host: deviceHostName,
    );

/// Builds the name sent at sign-in. Desktop reads `Platform - host`; a
/// phone reads its [model] and, without one, "iPhone" or "Android phone".
///
/// A host name that says nothing (empty, or the loopback name iOS reports
/// when it hides the device name) is dropped: "iOS (localhost)" on every
/// iPhone is what made the list read as the same device nine times.
String composeDeviceName(
  TargetPlatform platform, {
  String? host,
  String? model,
}) {
  final cleanHost = _usableLabel(host);
  final cleanModel = _usableLabel(model);
  return switch (platform) {
    TargetPlatform.iOS => cleanModel ?? 'iPhone',
    TargetPlatform.android => cleanModel ?? 'Android phone',
    TargetPlatform.macOS => _withHost('Mac', cleanHost),
    TargetPlatform.windows => _withHost('Windows', cleanHost),
    TargetPlatform.linux => _withHost('Linux', cleanHost),
    TargetPlatform.fuchsia => _withHost('Fuchsia', cleanHost),
  };
}

String _withHost(String platform, String? host) =>
    host == null ? platform : '$platform - $host';

const _meaninglessHosts = {'localhost', 'localhost.localdomain', 'unknown'};

String? _usableLabel(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return _meaninglessHosts.contains(trimmed.toLowerCase()) ? null : trimmed;
}

/// This machine's host name, or null on web and on embedders where
/// `Platform.localHostname` is unsupported: a name this build cannot read is
/// worth losing, not worth crashing sign-in over.
String? get deviceHostName {
  if (kIsWeb) return null;
  try {
    final name = Platform.localHostname.trim();
    return name.isEmpty ? null : name;
  } catch (error, stack) {
    AppLog.swallowed(
        LogTag.platform, 'usable label failed, ignored', error, stack);
    return null;
  }
}

/// The coarse client kind sent alongside [deviceDisplayName] at sign-in, for
/// the devices list to name a session by more than its free-text device
/// name. Three buckets rather than five platforms: the desktop targets share
/// one build and one settings surface, so a device list distinguishing
/// "Linux" from "Windows" here would promise a difference nothing else in the
/// app draws.
String get deviceClientKind {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.android => 'android',
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.fuchsia =>
      'desktop',
  };
}
