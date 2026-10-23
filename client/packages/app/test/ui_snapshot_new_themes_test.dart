// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The soft dark and forest themes on the channel view, the appearance pane
/// and a call, at desktop and phone width. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';

import 'features/voice/voice_snapshot_fixtures.dart'
    show SnapshotVoiceController, connectedCallState;
import 'ui_snapshot_support.dart';

const _themes = ['soft', 'forest'];

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in phoneAndDesktop) {
    testWidgets('channel at $viewport (new themes)', (tester) async {
      await renderSurfaceThemes(
        tester,
        '/channels/c-general',
        viewport,
        _themes,
        (t) => 'theme-channel-$viewport-$t',
      );
    });

    testWidgets('settings appearance at $viewport (new themes)', (
      tester,
    ) async {
      await renderSurfaceThemes(
        tester,
        '/settings',
        viewport,
        _themes,
        (t) => 'theme-appearance-$viewport-$t',
        overrides: [
          voiceControllerProvider.overrideWith(
            (ref) => SnapshotVoiceController(ref, const VoiceState()),
          ),
        ],
        afterSettle: (tester) async {
          await tester.tap(find.text('Appearance').first);
          await tester.pump();
        },
      );
    });

    testWidgets('call at $viewport (new themes)', (tester) async {
      await renderSurfaceThemes(
        tester,
        '/channels/c-main',
        viewport,
        _themes,
        (t) => 'theme-call-$viewport-$t',
        overrides: [
          voiceControllerProvider.overrideWith(
            (ref) => SnapshotVoiceController(ref, connectedCallState),
          ),
        ],
      );
    });
  }
}
