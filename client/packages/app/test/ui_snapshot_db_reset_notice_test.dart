// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "local data was reset" callout above the real shell, at a phone and a
/// desktop width in both themes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/auth/providers/database_key_store.dart';
import 'package:slimm_data/data.dart';

import 'ui_snapshot_support.dart';

void main() {
  for (final theme in const [darkAndLight]) {
    for (final viewport in phoneAndDesktop) {
      testWidgets('database reset notice at $viewport ($theme) fits', (
        tester,
      ) async {
        await renderSurface(
          tester,
          '/channels/c-general',
          viewport,
          theme,
          'database-reset-notice-$viewport-$theme',
          overrides: [
            databaseResetProvider.overrideWith(
              (ref) => DatabaseResetReason.keyMissing,
            ),
          ],
        );
      });
    }
  }
}
