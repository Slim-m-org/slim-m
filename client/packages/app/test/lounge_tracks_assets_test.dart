// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every music style points at a file that ships and that the pubspec
/// declares, so picking one can never play nothing. Reads the disk, so it
/// stays off the dart2js list in `client/chrome-tests.txt`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/lounge_tracks.dart';

void main() {
  test('every style is a bundled, declared asset', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final track in LoungeTrack.values) {
      expect(
        File('assets/${track.asset}').existsSync(),
        isTrue,
        reason: track.asset,
      );
      expect(pubspec, contains('assets/${track.asset}'));
    }
  });
}
