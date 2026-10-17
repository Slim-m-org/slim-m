// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Jumping to a message that lives in a voice channel's chat (search, pins,
/// a message link) must land on the chat, not join the call. Sibling of the
/// notification-tap case in `voice_notification_arrival_test.dart`, driven
/// through the same real `ConversationPane` and `VoiceScreen`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/features/messages/widgets/message_jump.dart';
import 'package:slimm_data/data.dart';

import 'home_shell_harness.dart';
import 'voice_controller_harness.dart' show RecordingVoiceController;

void main() {
  testWidgets(
    'jumping to a message in a voice channel does not join the call',
    (tester) async {
      late RecordingVoiceController voice;
      final s = setup(
        httpClient: quietClient(),
        signedIn: true,
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => voice = RecordingVoiceController(ref),
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
      await pumpAtWidth(tester, s.container, 1400);

      final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
      jumpToMessage(
        router,
        s.container.read,
        currentChannelId: null,
        channelId: 'c1',
        messageId: 'm1',
      );
      await tester.pumpAndSettle();

      expect(voice.joins, isEmpty, reason: 'reading a message is not consent');
      expect(
        find.byType(ChannelScreen),
        findsOneWidget,
        reason: 'chat is open',
      );
      expect(find.text('Join muted'), findsOneWidget);

      await teardown(tester, s.container, s.db);
    },
  );
}
