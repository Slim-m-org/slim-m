// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Windows YouTube capture is closed on the UI thread that made it, never
/// left for the raster thread's texture callback to tear down.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_test_support/source_gates.dart';

String _code(String name) =>
    stripComments(File('windows/runner/$name').readAsStringSync());

void main() {
  test('destroying the player closes its capture before dropping it', () {
    final code = _code('youtube_player_win.cpp');
    final release = code.substring(code.indexOf('void ReleaseCapture()'));
    expect(
      release.indexOf('capture->Close()'),
      lessThan(release.indexOf('std::atomic_store')),
    );
    final destroy = code.substring(code.indexOf('void Destroy()'));
    expect(destroy, contains('ReleaseCapture()'));
  });

  test('a closed capture stops resizing', () {
    final code = _code('youtube_player_capture.cpp');
    final resize = code.substring(code.indexOf('void Resize('));
    expect(resize.indexOf('closed_'), lessThan(resize.indexOf('Start(')));
  });
}
