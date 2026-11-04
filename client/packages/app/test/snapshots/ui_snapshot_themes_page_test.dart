// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Themes page under Appearance at the phone and desktop widths.
library;

import 'package:flutter_test/flutter_test.dart';

import '../ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in phoneAndDesktop) {
    testWidgets('themes page at $viewport ($darkAndLight)', (tester) async {
      await renderSurface(
        tester,
        '/settings/themes',
        viewport,
        darkAndLight,
        'settings-themes-$viewport-$darkAndLight',
      );
    });
  }
}
