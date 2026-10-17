// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock's real, composed height - `DockHeightReporter`'s own measured
/// value, the one `app_snackbar.dart` reads to clear the leave-call button -
/// before and after the owner's "the dock can be made way more compact"
/// report: 70dp to 52dp at desktop-1400 (one row), 131dp to 115dp at
/// phone-390 (two rows). Both numbers were read off this exact fixture on
/// `main` before the compaction, not estimated. At phone-390 the dock then
/// became 176dp of three stacked rows, and the owner's 2026-10-02 report of
/// "dock ui on mobile a mess in canvas" made it two one-row cards, 124dp.
///
/// Split out of `home_shell_snackbar_dock_test.dart`, which already builds
/// the identical call-plus-canvas fixture for a different assertion (a
/// snackbar clearing the dock), rather than duplicating it a third time.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/providers/dock_reservation.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_rtc/rtc.dart';

import 'home_shell_harness.dart';
import 'voice_controller_harness.dart' show FixedVoiceController;

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
  testWidgets(
    'the one-row dock (desktop-1400) measures well under its old 70dp',
    (tester) async {
      final s = await _pumpCallAndCanvas(tester, width: 1400);

      expect(s.container.read(bottomDockReservationProvider), 52);

      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'the phone dock (phone-390) is two one-row cards, 124dp, down from 176dp',
    (tester) async {
      final s = await _pumpCallAndCanvas(tester, width: 390);

      expect(s.container.read(bottomDockReservationProvider), 124);

      await teardown(tester, s.container, s.db);
    },
  );
}
