// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice transcript frame lands on the held message itself, whether or not
/// a row is on screen, and only ever moves it further along.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/providers/live_events.dart';

api.Message _voice(api.VoiceTranscript? transcript) => api.Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: 1,
  content: '',
  createdAt: 0,
  editedAt: null,
  attachments: [
    api.Attachment(
      id: 'a1',
      filename: 'voice-message.ogg',
      contentType: 'audio/ogg',
      size: 4,
      transcript: transcript,
    ),
  ],
);

const _pending = api.VoiceTranscript(status: api.VoiceTranscriptStatus.pending);
const _ready = api.VoiceTranscript(
  status: api.VoiceTranscriptStatus.ready,
  text: 'meet me at the lighthouse',
);

api.MessageVoiceTranscript _frame(api.VoiceTranscript transcript) =>
    api.MessageVoiceTranscript(
      channelId: 'c1',
      messageId: 'm1',
      attachmentId: 'a1',
      transcript: transcript,
    );

void main() {
  late StreamController<api.ServerEvent> events;
  late ProviderContainer container;
  late MessageExtrasController extras;

  setUp(() {
    events = StreamController<api.ServerEvent>.broadcast();
    container = ProviderContainer(
      overrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    extras = container.read(messageExtrasProvider.notifier);
  });
  tearDown(() async {
    container.dispose();
    await events.close();
  });

  api.VoiceTranscript? held() =>
      extras.extrasFor('m1').attachments.single.transcript;

  test('a frame fills in a held message with no row on screen', () async {
    extras.applyMessages([_voice(_pending)]);
    events.add(_frame(_ready));
    await Future<void>.delayed(Duration.zero);

    expect(held()?.status, api.VoiceTranscriptStatus.ready);
    expect(held()?.text, 'meet me at the lighthouse');
  });

  test('a late pending frame does not undo a ready one', () async {
    extras.applyMessages([_voice(_ready)]);
    events.add(_frame(_pending));
    await Future<void>.delayed(Duration.zero);

    expect(held()?.status, api.VoiceTranscriptStatus.ready);
  });

  test('a page fetched before the frame landed keeps the frame', () async {
    extras.applyMessages([_voice(_pending)]);
    events.add(_frame(_ready));
    await Future<void>.delayed(Duration.zero);
    extras.applyMessages([_voice(_pending)]);

    expect(held()?.status, api.VoiceTranscriptStatus.ready);
  });

  test('a frame for a message not held is dropped', () async {
    events.add(_frame(_ready));
    await Future<void>.delayed(Duration.zero);

    expect(extras.extrasFor('m1').attachments, isEmpty);
  });
}
