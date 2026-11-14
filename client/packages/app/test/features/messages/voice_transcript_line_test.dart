// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The line under a voice message: transcribing, then the words behind a
/// toggle, updated live by a frame without rereading the message.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/messages/widgets/voice_transcript_line.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_design_system/design_system.dart';

Attachment voiceWith(VoiceTranscript? transcript) => Attachment(
  id: 'a1',
  filename: 'voice-message.ogg',
  contentType: 'audio/ogg',
  size: 4,
  voice: VoiceInfo(
    duration: const Duration(seconds: 5),
    waveform: List.filled(64, 100),
  ),
  transcript: transcript,
);

void main() {
  late StreamController<ServerEvent> events;

  setUp(() => events = StreamController<ServerEvent>.broadcast());
  tearDown(() => events.close());

  Future<void> pump(WidgetTester tester, Attachment attachment) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [liveEventsProvider.overrideWithValue(events.stream)],
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(body: VoiceTranscriptLine(attachment: attachment)),
          ),
        ),
      );

  testWidgets('nothing shows while the Space does not transcribe', (
    tester,
  ) async {
    await pump(tester, voiceWith(null));
    expect(find.text('Transcribing...'), findsNothing);
    expect(find.byKey(const Key('voice-transcript-toggle')), findsNothing);
  });

  testWidgets('a pending transcript says so, and a frame fills it in live', (
    tester,
  ) async {
    await pump(
      tester,
      voiceWith(const VoiceTranscript(status: VoiceTranscriptStatus.pending)),
    );
    expect(find.text('Transcribing...'), findsOneWidget);
    events.add(
      const MessageVoiceTranscript(
        channelId: 'c',
        messageId: 'm',
        attachmentId: 'a1',
        transcript: VoiceTranscript(
          status: VoiceTranscriptStatus.ready,
          text: 'meet me at the lighthouse',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Transcribing...'), findsNothing);
    expect(find.byKey(const Key('voice-transcript-text')), findsNothing);
    await tester.tap(find.byKey(const Key('voice-transcript-toggle')));
    await tester.pump();
    expect(find.text('meet me at the lighthouse'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-transcript-toggle')));
    await tester.pump();
    expect(find.text('meet me at the lighthouse'), findsNothing);
  });

  testWidgets('a frame for another attachment changes nothing here', (
    tester,
  ) async {
    await pump(
      tester,
      voiceWith(const VoiceTranscript(status: VoiceTranscriptStatus.pending)),
    );
    events.add(
      const MessageVoiceTranscript(
        channelId: 'c',
        messageId: 'm',
        attachmentId: 'other',
        transcript: VoiceTranscript(status: VoiceTranscriptStatus.ready),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Transcribing...'), findsOneWidget);
  });

  testWidgets('failed and silent clips have their own plain lines', (
    tester,
  ) async {
    await pump(
      tester,
      voiceWith(const VoiceTranscript(status: VoiceTranscriptStatus.failed)),
    );
    expect(find.text('Could not transcribe this message.'), findsOneWidget);
    await pump(
      tester,
      voiceWith(const VoiceTranscript(status: VoiceTranscriptStatus.ready)),
    );
    await tester.pump();
    expect(find.text('No speech heard'), findsOneWidget);
  });
}
