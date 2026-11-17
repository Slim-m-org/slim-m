// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The line under a voice message: transcribing, then the words in full,
/// updated live by a frame on the held message without rereading it, and
/// gone at once when the Space turns transcripts off.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/widgets/voice_transcript_line.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/server_info.dart';
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

Message _message(Attachment attachment) => Message(
  id: 'm',
  channelId: 'c',
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: 1,
  content: '',
  createdAt: 0,
  editedAt: null,
  attachments: [attachment],
);

/// The Space's transcript switch, as `/version` reports it.
final _transcriptsOn = StateProvider<bool>((ref) => true);

void main() {
  late StreamController<ServerEvent> events;
  ProviderContainer? container;

  setUp(() {
    events = StreamController<ServerEvent>.broadcast();
    container = null;
  });
  tearDown(() => events.close());

  /// Holds a message carrying [attachment] as a fetch would, then draws its line.
  Future<void> pump(WidgetTester tester, Attachment attachment) async {
    final held = container;
    if (held != null) {
      held.read(messageExtrasProvider.notifier).applyMessages([
        _message(attachment),
      ]);
      await tester.pump();
      return;
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          liveEventsProvider.overrideWithValue(events.stream),
          serverInfoProvider.overrideWith(
            (ref) => Version(
              name: 'slim-m',
              version: '1',
              protocol: 1,
              transcribeVoiceMessages: ref.watch(_transcriptsOn),
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final shown = ref
                    .watch(messageExtrasProvider)['m']
                    ?.attachments
                    .firstOrNull;
                return shown == null
                    ? const SizedBox.shrink()
                    : VoiceTranscriptLine(attachment: shown);
              },
            ),
          ),
        ),
      ),
    );
    container = ProviderScope.containerOf(
      tester.element(find.byWidgetPredicate((w) => w is Consumer)),
    );
    await pump(tester, attachment);
  }

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
    expect(find.text('meet me at the lighthouse'), findsOneWidget);
    expect(find.textContaining('Show'), findsNothing);
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

  testWidgets('a refetched ready transcript outranks a stale pending frame', (
    tester,
  ) async {
    await pump(tester, voiceWith(null));
    events.add(
      const MessageVoiceTranscript(
        channelId: 'c',
        messageId: 'm',
        attachmentId: 'a1',
        transcript: VoiceTranscript(status: VoiceTranscriptStatus.pending),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Transcribing...'), findsOneWidget);
    await pump(
      tester,
      voiceWith(
        const VoiceTranscript(
          status: VoiceTranscriptStatus.ready,
          text: 'meet me at the lighthouse',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('meet me at the lighthouse'), findsOneWidget);
    expect(find.text('Transcribing...'), findsNothing);
  });

  testWidgets('a newer live frame still wins over what the message carries', (
    tester,
  ) async {
    await pump(
      tester,
      voiceWith(
        const VoiceTranscript(
          status: VoiceTranscriptStatus.ready,
          text: 'first pass',
        ),
      ),
    );
    events.add(
      const MessageVoiceTranscript(
        channelId: 'c',
        messageId: 'm',
        attachmentId: 'a1',
        transcript: VoiceTranscript(
          status: VoiceTranscriptStatus.ready,
          text: 'second pass',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('second pass'), findsOneWidget);
  });

  testWidgets('turning transcripts off hides fetched and live ones at once', (
    tester,
  ) async {
    await pump(
      tester,
      voiceWith(
        const VoiceTranscript(
          status: VoiceTranscriptStatus.ready,
          text: 'first pass',
        ),
      ),
    );
    events.add(
      const MessageVoiceTranscript(
        channelId: 'c',
        messageId: 'm',
        attachmentId: 'a1',
        transcript: VoiceTranscript(
          status: VoiceTranscriptStatus.ready,
          text: 'second pass',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('second pass'), findsOneWidget);

    container!.read(_transcriptsOn.notifier).state = false;
    await tester.pump();
    await tester.pump();

    expect(find.text('second pass'), findsNothing);
    expect(find.text('first pass'), findsNothing);

    container!.read(_transcriptsOn.notifier).state = true;
    await tester.pump();
    await tester.pump();

    expect(
      find.text('second pass'),
      findsOneWidget,
      reason: 'the server keeps what it hid, so turning them on shows it again',
    );
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
