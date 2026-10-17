// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas call dock and a plain [showAppSnackbar] both anchor to the
/// same [ScaffoldMessenger] at any layout, because `HomeShell` wraps the
/// rail, the conversation pane and the member pane in one shared [Scaffold]
/// (see `home_shell.dart`'s `showsBothPanes` branch, and its single-pane
/// branch below it). A floating [SnackBar] positions itself against that
/// Scaffold's own bottom edge with no built-in awareness of anything else
/// already anchored there - including the call dock a voice call in an open
/// canvas renders at the same bottom-center spot. Reproduced first (a real
/// snackbar covering the real leave-call button, at two widths: one row and
/// the two-row phone stack), then fixed by `DockHeightReporter` measuring
/// the dock and `app_snackbar.dart` reading that reservation back.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_call_dock.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/widgets/app_snackbar.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../home_shell_harness.dart';
import '../voice/voice_controller_harness.dart' show FixedVoiceController;

Future<({ProviderContainer container, SlimmDatabase db})> _pumpCallAndCanvas(
  WidgetTester tester, {
  required double width,
}) async {
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(
          ref,
          const VoiceState(state: VoiceSessionState.connected, channelId: 'c1'),
        ),
      ),
    ],
  );
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'voice', createdAt: 0),
  ]);
  s.container.read(canvasOpenProvider.notifier).state = 'c1';
  await pumpAtWidth(tester, s.container, width, location: '/channels/c1');
  return s;
}

void main() {
  for (final width in [1400.0, 500.0]) {
    testWidgets('a snackbar fired elsewhere in the shell clears the leave-call '
        'button at width $width', (tester) async {
      final s = await _pumpCallAndCanvas(tester, width: width);

      expect(
        find.byType(CanvasCallDock),
        findsOneWidget,
        reason:
            'the dock must actually be showing a call for this to mean anything',
      );
      final dockRect = tester.getRect(find.byType(CanvasCallDock));
      final leaveRect = tester.getRect(
        find.bySemanticsLabel(RegExp(r'^Leave call')),
      );

      const message = 'Overwrite set for that role.';
      showAppSnackbar(tester.element(find.byType(CanvasCallDock)), message);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The visible card's own content, not the whole SnackBar element - that box's invisible bottom margin would pass even unfixed.
      final snackRect = tester.getRect(find.text(message));

      expect(
        snackRect.overlaps(dockRect),
        isFalse,
        reason:
            'a snackbar with nothing to do with the call must not '
            'cover any part of the dock, at any width',
      );
      expect(
        snackRect.overlaps(leaveRect),
        isFalse,
        reason:
            'a snackbar with nothing to do with the call must not cover '
            'the one control that hangs up',
      );

      await teardown(tester, s.container, s.db);
    });
  }
}
