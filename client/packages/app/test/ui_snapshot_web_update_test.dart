// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web-update pill over the real shell, at a phone and a desktop width in
/// both themes. The overflow assertion runs everywhere; the PNGs are written
/// only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/web_update/web_update_watch.dart';

import 'ui_snapshot_support.dart';

List<Override> _newerBuildLive() => [
  runningWebBuildProvider.overrideWithValue('aaa'),
  webUpdateSupportedProvider.overrideWithValue(true),
  webBuildFetcherProvider.overrideWithValue(() async => 'bbb'),
];

void main() {
  for (final theme in const [darkAndLight]) {
    for (final viewport in const ['phone-portrait', 'desktop']) {
      testWidgets('web update pill at $viewport ($theme) fits its viewport', (
        tester,
      ) async {
        await renderSurface(
          tester,
          '/channels/c-general',
          viewport,
          theme,
          'web-update-pill-$viewport-$theme',
          overrides: _newerBuildLive(),
        );
      });
    }
  }
}
