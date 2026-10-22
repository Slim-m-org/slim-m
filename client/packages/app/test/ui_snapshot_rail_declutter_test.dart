// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel rail as a phone and a desktop window draw it, both themes, so a
/// change to row or header chrome is looked at rather than only measured.
library;

import 'package:flutter_test/flutter_test.dart';

import 'ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in const ['desktop', 'phone-portrait']) {
    for (final theme in const [darkAndLight]) {
      testWidgets('rail chrome at $viewport ($theme)', (tester) async {
        await renderSurface(
          tester,
          viewport == 'desktop' ? '/channels/c-general' : '/channels',
          viewport,
          theme,
          'rail-declutter-$viewport-$theme',
        );
      });
    }
  }
}
