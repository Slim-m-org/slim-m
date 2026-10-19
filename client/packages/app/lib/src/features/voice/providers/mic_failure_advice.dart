// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What to tell someone whose microphone will not work, and where to send
/// them to fix it, per platform.
library;

import 'package:flutter/foundation.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:url_launcher/url_launcher.dart';

class MicAdvice {
  const MicAdvice(this.message, {this.settings});

  final String message;

  /// The OS page that fixes it, where a link can open one.
  final Uri? settings;
}

/// The error for a refused mic toggle; null when `MicFailureBanner` already explains it.
String? micRefusalError(String verb, MicFailureReason? reason) =>
    reason != null && micAdviceFor(reason) != null
    ? null
    : 'Could not $verb the microphone.';

final Uri _windowsMicSettings = Uri.parse('ms-settings:privacy-microphone');
final Uri _macMicSettings = Uri.parse(
  'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
);
final Uri _iosAppSettings = Uri.parse('app-settings:');

/// Null when the cause is not worth a message of its own.
MicAdvice? micAdviceFor(
  MicFailureReason reason, {
  TargetPlatform? platform,
  bool? web,
}) {
  final onWeb = web ?? kIsWeb;
  return switch (reason) {
    MicFailureReason.permissionDenied => _blocked(
      onWeb ? null : platform ?? defaultTargetPlatform,
    ),
    MicFailureReason.busy => const MicAdvice(
      'Another app is using the microphone. Close it and try again.',
    ),
    MicFailureReason.notFound => const MicAdvice(
      'No microphone found. Connect one and try again.',
    ),
    MicFailureReason.silent => const MicAdvice(
      'The microphone is sending no sound. Check it is not muted in your system sound settings.',
    ),
    MicFailureReason.unknown => null,
  };
}

MicAdvice _blocked(TargetPlatform? platform) => switch (platform) {
  null => const MicAdvice(
    'The browser is blocking the microphone. Allow it from the lock icon in the address bar.',
  ),
  TargetPlatform.windows => MicAdvice(
    'Windows is blocking the microphone. Allow apps to use it in Privacy settings.',
    settings: _windowsMicSettings,
  ),
  TargetPlatform.macOS => MicAdvice(
    'macOS is blocking the microphone. Allow slim-m in System Settings > Privacy & Security > Microphone.',
    settings: _macMicSettings,
  ),
  TargetPlatform.iOS => MicAdvice(
    'Microphone access is off. Allow it for slim-m in Settings.',
    settings: _iosAppSettings,
  ),
  TargetPlatform.android => const MicAdvice(
    'Microphone access is off. Allow it for slim-m in Settings > Apps > Permissions.',
  ),
  _ => const MicAdvice(
    'The system is blocking the microphone. Check your sound settings and any sandbox permissions.',
  ),
};

/// Opens an OS settings page; false when the platform refused.
typedef SettingsLauncher = Future<bool> Function(Uri uri);

Future<bool> openMicSettings(Uri uri, {SettingsLauncher? launcher}) async {
  try {
    return await (launcher ?? launchSettingsPage)(uri);
  } on Object {
    return false;
  }
}

Future<bool> launchSettingsPage(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);
