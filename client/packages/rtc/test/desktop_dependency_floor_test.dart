// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Guards the flutter_webrtc/livekit_client floor against a downgrade.
///
/// flutter_webrtc 1.4.0 (the version `livekit_client 2.8.1` hard-pins) has a
/// real bug on Linux: opening a microphone whose device name does not
/// round-trip through its platform-channel encoding throws
/// `FormatException: Unexpected extension byte` out of `getUserMedia`, before
/// `MediaDeviceNative`'s own `on PlatformException` catch ever sees it,
/// because a `FormatException` is not a `PlatformException`. Reproduced
/// directly against the real plugin on a real Fedora KDE box holding a
/// SteelSeries Arctis Nova Pro Wireless headset: `getUserMedia({'audio':
/// true})` threw that exact exception in under 10ms, on every call. The
/// owner's reports of the Linux app freezing on join and on enabling the
/// webcam are both a microphone or camera open, so this is the same failure.
///
/// `livekit_client 2.10.0` hard-pins `flutter_webrtc 1.6.0`, past the
/// "sanitize UTF-8 for device strings" fix flutter_webrtc's own changelog
/// records for 1.4.1. Reproduced fixed the same way: the identical probe
/// against 1.6.0/2.10.0 on the same box, with the same real hardware,
/// resolved the call in 6ms instead of throwing.
///
/// This cannot be a behavioural test: the bug only manifests against a real
/// platform channel and a real audio device whose name trips the encoder, and
/// nothing in this repo's test harness has either. What can be pinned is that
/// nobody downgrades past the fix without noticing, which is what this reads
/// out of the resolved lockfile rather than out of pubspec.yaml's own
/// constraint, since a constraint can be satisfied by a version older than
/// intended if something else in the workspace pins lower.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';

void main() {
  test(
    'flutter_webrtc is resolved past the Linux UTF-8 device-string fix',
    () {
      final lock = _resolvedVersion('flutter_webrtc');
      expect(
        lock.compareTo(Version.parse('1.4.1')),
        greaterThanOrEqualTo(0),
        reason: 'flutter_webrtc $lock is older than 1.4.1, which is where '
            '"sanitize UTF-8 for device strings before platform messages" '
            'landed; opening a mic or camera with certain device names will '
            'throw a FormatException on Linux again.',
      );
    },
  );

  test(
    'livekit_client is resolved past the version that hard-pins the old flutter_webrtc',
    () {
      final lock = _resolvedVersion('livekit_client');
      expect(
        lock.compareTo(Version.parse('2.10.0')),
        greaterThanOrEqualTo(0),
        reason: 'livekit_client $lock hard-pins its own flutter_webrtc version '
            '(see its pubspec.yaml comment: "Fix version to avoid version '
            'conflicts between WebRTC-SDK pods"), so bumping this package\'s '
            'own flutter_webrtc constraint alone cannot move the resolved '
            'version; 2.10.0 is the first to pin 1.6.0.',
      );
    },
  );

  test('flutter_webrtc is pinned past the first-share double chooser', () {
    final ref = _forkRef();
    expect(
      _doubleChooserRefs,
      isNot(contains(ref)),
      reason: 'flutter_webrtc $ref opens one xdg-desktop-portal chooser for '
          'libwebrtc\'s own screen list and a second for the capture, so the '
          'first Linux share asks twice. Run scripts/linux-portal-probe/run.sh '
          'before moving the pin.',
    );
  });
}

/// Fork commits whose first share opens two portal choosers.
const _doubleChooserRefs = {'a5d9427e64b50dda1c74ac54e769bbacd0655282'};

String _forkRef() {
  final lines = File('${_workspaceRoot().path}/pubspec.lock').readAsLinesSync();
  final start = lines.indexWhere((l) => l == '  flutter_webrtc:');
  expect(start, greaterThanOrEqualTo(0),
      reason: 'flutter_webrtc is not locked');
  final resolved = RegExp(r'^      resolved-ref: "?([0-9a-f]{40})"?');
  for (var j = start + 1; j < lines.length && j < start + 10; j++) {
    final match = resolved.firstMatch(lines[j]);
    if (match != null) return match.group(1)!;
  }
  fail('flutter_webrtc has no resolved-ref in the lockfile');
}

/// Reads the version pub actually resolved for [package] out of the
/// workspace's committed `pubspec.lock`, not out of any pubspec.yaml's
/// constraint: a constraint states a floor, the lockfile states the answer,
/// and only the answer is what a real build links against.
Version _resolvedVersion(String package) {
  final lockFile = File('${_workspaceRoot().path}/pubspec.lock');
  final lines = lockFile.readAsLinesSync();
  final packageLine = RegExp('^  $package:\$');
  final versionLine = RegExp(r'^    version: "([^"]+)"');
  for (var i = 0; i < lines.length; i++) {
    if (!packageLine.hasMatch(lines[i])) continue;
    for (var j = i + 1; j < lines.length && j < i + 10; j++) {
      final match = versionLine.firstMatch(lines[j]);
      if (match != null) return Version.parse(match.group(1)!);
    }
  }
  fail('$package has no version pinned in ${lockFile.path}');
}

/// Walks upward from the test's own working directory to the workspace root
/// (the `client/` directory carrying the shared `pubspec.lock`), the same
/// technique `schema_coverage_test.dart` uses so this runs the same whether
/// invoked from `client/`, `client/packages/rtc`, or the repo root.
Directory _workspaceRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/pubspec.lock').existsSync() &&
        Directory('${dir.path}/packages/rtc').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    'could not find the client/ workspace root (pubspec.lock beside '
    'packages/rtc) walking up from ${Directory.current.path}',
  );
}
