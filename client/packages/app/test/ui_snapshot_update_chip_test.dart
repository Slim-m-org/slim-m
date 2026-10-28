// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The frameless title bar with an update waiting, at a phone width and a
/// desktop width in both themes. The overflow assertion runs everywhere; the
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_platform/platform.dart';

import 'desktop/support/desktop_shell_fixture.dart';
import 'ui_snapshot_support.dart';

const _update = ClientUpdate(
  version: '0.91.0',
  releaseUrl: 'https://example.invalid/release',
  format: InstallFormat.tarball,
);

void main() {
  for (final theme in const [darkAndLight]) {
    for (final viewport in const ['phone-portrait', 'desktop']) {
      testWidgets('update chip at $viewport ($theme) fits its viewport', (
        tester,
      ) async {
        final shell = shellFor(null, active: true, frameless: true);
        await renderSurface(
          tester,
          '/channels/c-general',
          viewport,
          theme,
          'update-chip-$viewport-$theme',
          overrides: [
            desktopWindowShellProvider.overrideWithValue(shell),
            inSessionUpdateProvider.overrideWith((ref) => _update),
          ],
        );
      });
    }
  }
}
