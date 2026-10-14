// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Owner report: tapping a notification for a voice channel's chat message
/// "automatically adds them to the call which is no good". A tap now routes
/// with `openChat`, and the shell lands on the chat with the call unjoined;
/// picking the channel from the rail still joins directly. Driven through
/// the real `ConversationPane` and `VoiceScreen`, so the route flag reaching
/// the join decision is what is pinned, not a widget in isolation.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/channel_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_rtc/rtc.dart';

import 'home_shell_harness.dart';
import 'voice_controller_harness.dart' show FakeSession;

/// Records every join asked of it and reports that call as connected at
/// once, so the screen settles on the call stage instead of the connecting
/// spinner, whose animation never lets `pumpAndSettle` return.
class _RecordingVoiceController extends VoiceController {
  _RecordingVoiceController(super.ref) : super(session: FakeSession());

  final joins = <String>[];

  @override
  Future<void> join(String channelId) async {
    joins.add(channelId);
    state = VoiceState(
      state: VoiceSessionState.connected,
      channelId: channelId,
    );
  }
}

Future<
  ({
    ProviderContainer container,
    SlimmDatabase db,
    _RecordingVoiceController voice,
  })
>
_arriveAt(WidgetTester tester, double width, String location) async {
  late _RecordingVoiceController voice;
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => voice = _RecordingVoiceController(ref),
      ),
    ],
  );
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c1', name: 'lounge', kind: 'voice', createdAt: 0),
  ]);
  await pumpAtWidth(tester, s.container, width, location: location);
  return (container: s.container, db: s.db, voice: voice);
}

void main() {
  testWidgets(
    'a notification tap lands on the chat with the call unjoined, and Join '
    'is one explicit tap away',
    (tester) async {
      final s = await _arriveAt(
        tester,
        1400,
        Routes.channel('c1', openChat: true),
      );

      expect(
        s.voice.joins,
        isEmpty,
        reason: 'reading a message is not consent to join',
      );
      expect(
        find.byType(ChannelScreen),
        findsOneWidget,
        reason: 'chat docked open',
      );
      expect(find.text('Join muted'), findsOneWidget);
      expect(
        find.text('You left this call.'),
        findsNothing,
        reason: 'never joined, so never left',
      );
      expect(find.text('Rejoin call'), findsNothing);

      await tester.tap(find.text('Join muted'));
      await tester.pumpAndSettle();
      expect(s.voice.joins, ['c1']);

      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets('picking the channel from the rail still joins on arrival', (
    tester,
  ) async {
    final s = await _arriveAt(tester, 1400, Routes.channel('c1'));

    expect(s.voice.joins, ['c1']);
    expect(
      find.byType(ChannelScreen),
      findsNothing,
      reason: 'chat stays closed by default',
    );

    await teardown(tester, s.container, s.db);
  });

  testWidgets(
    'at phone width the chat tab is what opens, over an unjoined call',
    (tester) async {
      final s = await _arriveAt(
        tester,
        400,
        Routes.channel('c1', openChat: true),
      );

      final semantics = tester.ensureSemantics();
      expect(s.voice.joins, isEmpty);
      expect(find.byType(ChannelScreen), findsOneWidget);
      final chatToggle = find.bySemanticsLabel('Toggle text chat');
      expect(
        chatToggle,
        findsOneWidget,
        reason: 'the compact chat view is showing, with its app bar action lit',
      );

      await tester.tap(chatToggle);
      await tester.pumpAndSettle();
      expect(find.text('Join'), findsOneWidget, reason: 'the compact join bar');
      expect(
        s.voice.joins,
        isEmpty,
        reason: 'going back to the call view is not joining it',
      );
      semantics.dispose();

      await teardown(tester, s.container, s.db);
    },
  );
}
