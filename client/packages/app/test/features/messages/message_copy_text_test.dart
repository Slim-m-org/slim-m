// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Copy text copies what a message says: its text, or the words of its voice
/// message once heard. A message with nothing to copy offers no Copy text, so
/// the clipboard is never emptied by it.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart'
    show MessageExtras;
import 'package:slimm_app/src/features/messages/widgets/message_context_menu.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/providers/live_events.dart';

import 'message_row_harness.dart';
import 'voice_player_fakes.dart';

const _heard = api.VoiceTranscript(
  status: api.VoiceTranscriptStatus.ready,
  text: 'meet me at the lighthouse',
);

void main() {
  late List<String> copied;

  setUp(() => copied = []);

  Future<void> openMenu(
    WidgetTester tester, {
    required String content,
    List<api.Attachment> attachments = const [],
  }) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(content: content),
          grouped: false,
          showNewDivider: false,
          knownUsernames: const {},
          actions: noActions,
          editing: false,
          extras: MessageExtras(attachments: attachments),
          callbacks: MessageRowCallbacks(
            onRetry: () {},
            onDiscard: () {},
            onPickReaction: (_) {},
            onReactionTap: (_) {},
            onVote: (_) {},
            onSubmitEdit: (_) {},
            onCancelEdit: () {},
          ),
        ),
        overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      ),
    );
    final region = find.byWidgetPredicate((w) => w is MessageContextMenuRegion);
    await tester.longPressAt(tester.getTopLeft(region) + const Offset(30, 30));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a voice message copies the words it was heard saying', (
    tester,
  ) async {
    await openMenu(
      tester,
      content: '',
      attachments: [voiceMessage('v1', transcript: _heard)],
    );
    await tester.tap(find.text('Copy text'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(copied, ['meet me at the lighthouse']);
  });

  testWidgets('a voice message with no words yet offers no Copy text', (
    tester,
  ) async {
    await openMenu(
      tester,
      content: '',
      attachments: [
        voiceMessage(
          'v1',
          transcript: const api.VoiceTranscript(
            status: api.VoiceTranscriptStatus.pending,
          ),
        ),
      ],
    );
    expect(find.text('Reply'), findsNothing);
    expect(find.text('Save message'), findsOneWidget, reason: 'menu is up');
    expect(find.text('Copy text'), findsNothing);
  });

  testWidgets('a message with text still copies its text', (tester) async {
    await openMenu(tester, content: 'hello there');
    await tester.tap(find.text('Copy text'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(copied, ['hello there']);
  });
}
