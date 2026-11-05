// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On a phone in a voice channel call the canvas is reachable from the header,
/// and the dock does not add a second, spilled-row copy of it.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_open_button.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_rtc/rtc.dart';

import '../settings/home_shell_harness.dart';
import 'voice_controller_harness.dart' show FixedVoiceController;

void main() {
  testWidgets(
    '390 wide on an iPhone: the header carries the canvas entry and it opens',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final s = setup(
        httpClient: quietClient(),
        signedIn: true,
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => FixedVoiceController(
              ref,
              const VoiceState(
                state: VoiceSessionState.connected,
                channelId: 'c1',
              ),
            ),
          ),
        ],
      );
      await MessageStore(s.db).upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'lounge',
          kind: 'voice',
          createdAt: 0,
        ),
      ]);
      await pumpAtWidth(
        tester,
        s.container,
        390,
        height: 844,
        location: '/channels/c1',
      );

      expect(find.byKey(canvasOpenButtonKey), findsOneWidget);
      expect(
        find.bySemanticsLabel('Open canvas'),
        findsOneWidget,
        reason: 'one entry, not the header plus a spilled dock row',
      );
      await tester.tap(find.byKey(canvasOpenButtonKey));
      await tester.pump();
      expect(s.container.read(canvasOpenProvider), 'c1');
      debugDefaultTargetPlatformOverride = null;
      await teardown(tester, s.container, s.db);
    },
  );
}
