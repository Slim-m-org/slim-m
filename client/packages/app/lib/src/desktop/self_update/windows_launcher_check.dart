// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Spots a launcher that predates self-replacement (decision 0041), which no
/// update can fix: it needs one more run of the setup, said once.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'self_update_failure.dart';
import 'windows_layout.dart';

/// The flag only a launcher that can swap itself understands, so its bytes
/// are the cheapest honest proof; running an old launcher with it would start
/// the app instead.
final _selfSwapMarker = ascii.encode('--launcher-selftest');

const _noticeMarker = '.launcher-notice';

/// Whether the launcher file at [launcher] knows how to replace itself.
Future<bool> launcherCanSelfSwap(File launcher) => Isolate.run(() {
  final bytes = launcher.readAsBytesSync();
  final needle = _selfSwapMarker;
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    if (bytes[i] != needle[0]) continue;
    var j = 1;
    while (j < needle.length && bytes[i + j] == needle[j]) {
      j++;
    }
    if (j == needle.length) return true;
  }
  return false;
});

/// The one-time failure to show for an outdated launcher in [layout], or null
/// when it is current, unreadable, or already reported.
Future<SelfUpdateFailure?> outdatedLauncherNotice(
  WindowsInstallLayout layout,
) async {
  final marker = File(layout.path(_noticeMarker));
  try {
    if (marker.existsSync() || !layout.launcher.existsSync()) return null;
    if (await launcherCanSelfSwap(layout.launcher)) return null;
    marker.writeAsStringSync('');
  } on FileSystemException catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'Could not check whether the launcher is current',
      error,
      stack,
    );
    return null;
  }
  return const SelfUpdateFailure(
    SelfUpdateFailureKind.launcherOutdated,
    'slim-m updates itself, but its launcher is from an older setup and '
    'cannot replace itself. Run the latest setup once to fix that.',
  );
}
