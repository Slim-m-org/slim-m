// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real message card around word-guess and minesweeper at a desktop and a
/// phone width. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter_test/flutter_test.dart';

import 'app_surface_card_support.dart';
import 'module_scene_fixtures.dart';
import 'ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  for (final (label, window) in const [('desktop', 792.0), ('phone', 390.0)]) {
    for (final game in const ['word-guess', 'minesweeper']) {
      testWidgets('$game card at $label width', (tester) async {
        await pumpAppCard(
          tester,
          scene: shippedScenes[game]!,
          windowWidth: window,
          boundary: snapshotBoundary,
          title: game,
        );
        await writeSnapshot(tester, 'app-card-$game-$label');
      });
    }
  }
}
