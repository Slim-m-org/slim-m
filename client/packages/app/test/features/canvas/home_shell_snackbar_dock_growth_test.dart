// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sibling regression to `home_shell_snackbar_dock_test.dart`: that file
/// covers a snackbar shown while the dock is already at its final height.
/// This covers the opposite temporal order - a snackbar already on screen
/// when the dock then appears - which the fixed-margin-at-show-time design
/// cannot clear on its own, since `SnackBar.margin` is read once and never
/// revisited. Reproduced first (the dock mounting under an already-showing
/// snackbar covered the leave-call button exactly as the other order did),
/// then fixed by `_SnackbarDockGrowth` (`app_snackbar.dart`) reshowing the
/// tracked snackbar with a fresh margin whenever the reservation grows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_call_dock.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/widgets/app_snackbar.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_rtc/rtc.dart';

import '../settings/home_shell_harness.dart';
import '../voice/voice_controller_harness.dart' show FixedVoiceController;

void main() {
  testWidgets(
    'a snackbar shown before the call dock appears is reshown clear of it '
    'once the dock mounts',
    (tester) async {
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
          name: 'general',
          kind: 'voice',
          createdAt: 0,
        ),
      ]);
      // The canvas starts closed, so the dock does not exist yet.
      await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');

      const message = 'Overwrite set for that role.';
      showAppSnackbar(tester.element(find.byType(Scaffold).first), message);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(message), findsOneWidget);

      // Now the dock appears while that same snackbar is still up.
      s.container.read(canvasOpenProvider.notifier).state = 'c1';
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byType(CanvasCallDock),
        findsOneWidget,
        reason:
            'the dock must actually be showing a call for this to mean '
            'anything',
      );
      expect(
        find.text(message),
        findsOneWidget,
        reason: 'the reshow must not have dropped the message',
      );
      final dockRect = tester.getRect(find.byType(CanvasCallDock));
      final leaveRect = tester.getRect(
        find.bySemanticsLabel(RegExp(r'^Leave call')),
      );
      final snackRect = tester.getRect(find.text(message));

      expect(
        snackRect.overlaps(dockRect),
        isFalse,
        reason:
            'a dock that appears after the snackbar was already shown '
            'must not leave it stranded on top of the dock',
      );
      expect(
        snackRect.overlaps(leaveRect),
        isFalse,
        reason: 'nor stranded on top of the one control that hangs up',
      );

      await teardown(tester, s.container, s.db);
    },
  );
}
