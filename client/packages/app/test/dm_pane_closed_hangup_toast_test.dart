// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A hang-up with the DM's call pane closed has no recap card on screen, so the shell toasts it; with the pane open the card says it and the toast stays quiet.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/call_recap.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/dm_call_pane.dart'
    show dmCallOpenProvider;
import 'package:slimm_app/src/widgets/call_recap_card.dart' show CallRecapCard;
import 'package:slimm_data/data.dart';
import 'package:slimm_rtc/rtc.dart';

import 'home_shell_harness.dart';
import 'voice_controller_harness.dart' show FakeSession;

class _HangUpController extends VoiceController {
  _HangUpController(super.ref) : super(session: FakeSession());

  @override
  Future<void> join(String channelId) async {
    state = VoiceState(
      state: VoiceSessionState.connected,
      channelId: channelId,
    );
  }

  @override
  Future<void> leave() async {
    final channelId = state.channelId!;
    final now = DateTime.now();
    state = VoiceState(
      recap: CallRecap(
        channelId: channelId,
        startedAt: now.subtract(const Duration(seconds: 42)),
        endedAt: now,
        others: const [],
        sharedScreen: false,
        usedCamera: false,
      ),
      justLeftChannelId: channelId,
      justLeftAt: now,
    );
  }
}

/// Joins a DM call on a wide window, opens the call pane, then closes it again when [paneOpen] is false, and hangs up.
Future<List<String>> _hangUp(
  WidgetTester tester, {
  required bool paneOpen,
}) async {
  late _HangUpController voice;
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => voice = _HangUpController(ref),
      ),
    ],
  );
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'd1', name: 'alex', kind: 'dm', createdAt: 0),
  ]);
  await pumpAtWidth(tester, s.container, 1400, location: Routes.channel('d1'));
  await voice.join('d1');
  s.container.read(dmCallOpenProvider.notifier).state = 'd1';
  await tester.pumpAndSettle();
  if (!paneOpen) {
    s.container.read(dmCallOpenProvider.notifier).state = null;
    await tester.pumpAndSettle();
  }

  await voice.leave();
  await tester.pumpAndSettle();

  final toasts = s.container.read(toastsProvider).map((t) => t.message);
  final result = toasts.toList();
  await teardown(tester, s.container, s.db);
  return result;
}

void main() {
  testWidgets(
    'wide: hanging up a DM call after closing its pane toasts the recap',
    (tester) async {
      final toasts = await _hangUp(tester, paneOpen: false);

      expect(find.byType(CallRecapCard), findsNothing);
      expect(toasts, ['Call ended - 42 sec.']);
    },
  );

  testWidgets(
    'wide: hanging up with the DM call pane open leaves the recap card to say it',
    (tester) async {
      final toasts = await _hangUp(tester, paneOpen: true);

      expect(toasts, isEmpty);
    },
  );
}
