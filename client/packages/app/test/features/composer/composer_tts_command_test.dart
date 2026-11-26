// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `/tts` (decision 0142): offered only in a call, speaks the line through the
/// server and then posts the same text as an ordinary message, and every
/// refusal stays in the field with an inline reason.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_items.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_query.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_tts_command.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/async_wait.dart';
import '../voice/voice_controller_harness.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart'
    show StagedSend;
import 'composer_harness.dart';

List<String> _labels(String term, {required bool tts}) =>
    autocompleteSuggestions(
      query: AutocompleteQuery(
        kind: AutocompleteKind.command,
        term: term,
        start: 0,
        end: term.length + 1,
      ),
      custom: const [],
      members: const [],
      tts: tts,
    ).map((s) => s.label).toList();

/// Records the text of each send, since the composer clears the field after it.
class _TextSends extends Sends {
  _TextSends(this.field, this.log);

  final TextEditingController field;
  final List<String> log;

  @override
  Future<void> call(StagedSend attachments) {
    log.add('send:${field.text}');
    return super.call(attachments);
  }
}

Future<(TextEditingController, _TextSends, List<String>)> _pump(
  WidgetTester tester, {
  Stream<api.ServerEvent> events = const Stream.empty(),
  required bool inCall,
  required Future<http.Response> Function(http.Request) answer,
}) async {
  final controller = TextEditingController();
  addTearDown(controller.dispose);
  final log = <String>[];
  final sends = _TextSends(controller, log);
  await tester.pumpWidget(
    composerHarness(
      controller: controller,
      sends: sends,
      platform: TargetPlatform.linux,
      apiBuilder: (ref) => testApi((request) async {
        if (request.method == 'POST') {
          log.add('POST ${request.url.path} ${request.body}');
        }
        return answer(request);
      }, session: ref.watch(sessionProvider)),
      extraOverrides: [
        liveEventsProvider.overrideWithValue(events),
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(
            ref,
            VoiceState(
              state: inCall
                  ? VoiceSessionState.connected
                  : VoiceSessionState.idle,
              channelId: inCall ? 'c1' : null,
            ),
          ),
        ),
      ],
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  return (controller, sends, log);
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byWidgetPredicate((w) => w is TextField), text);
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
}

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('reads the line out of a /tts message', () {
    expect(ttsCommandLine('/tts hello there'), 'hello there');
    expect(ttsCommandLine('  /tts   spaced  '), 'spaced');
    expect(ttsCommandLine('/tts'), '');
    expect(ttsCommandLine('/tts\nsecond line'), 'second line');
    expect(ttsCommandLine('/ttsx hello'), isNull);
    expect(ttsCommandLine('say /tts hello'), isNull);
  });

  test('/tts is offered only in a call', () {
    expect(_labels('t', tts: true), contains('/tts'));
    expect(_labels('', tts: true).first, '/tts');
    expect(_labels('t', tts: false), isNot(contains('/tts')));
    expect(_labels('sh', tts: true), isNot(contains('/tts')));
  });

  test('each refusal has its own sentence', () {
    expect(
      ttsFailureMessage(const api.NotConfiguredException('x')),
      'Text to speech is not set up on this server.',
    );
    expect(
      ttsFailureMessage(const api.NotFoundException('x')),
      'This server does not support /tts yet.',
    );
    expect(
      ttsFailureMessage(const api.RateLimitedException('x')),
      contains('Slow down'),
    );
    expect(
      ttsFailureMessage(const api.ForbiddenException('x')),
      contains('cannot speak in this call'),
    );
  });

  testWidgets('a /tts line is spoken first and then posted as plain text', (
    tester,
  ) async {
    final (controller, sends, log) = await _pump(
      tester,
      inCall: true,
      answer: (_) async => _json(202, {'ahead': 0}),
    );
    await _type(tester, '/tts hello everyone');
    await waitUntil(tester, () => sends.count == 1);
    expect(log, [
      'POST /channels/c1/voice/tts {"text":"hello everyone"}',
      'send:hello everyone',
    ]);
    expect(controller.text, isNot(contains('/tts')));
  });

  testWidgets(
    'a refused line stays in the field with its reason and posts nothing',
    (tester) async {
      final (controller, sends, log) = await _pump(
        tester,
        inCall: true,
        answer: (_) async => _json(501, {'error': 'no voice'}),
      );
      await _type(tester, '/tts hello');
      await pumpFrames(tester);
      expect(
        find.text('Text to speech is not set up on this server.'),
        findsOneWidget,
      );
      expect(controller.text, '/tts hello');
      expect(sends.count, 0);
      expect(log, hasLength(1));
    },
  );

  testWidgets('outside the call it asks to join and never reaches the server', (
    tester,
  ) async {
    final (controller, sends, log) = await _pump(
      tester,
      inCall: false,
      answer: (_) async => _json(202, {'ahead': 0}),
    );
    await _type(tester, '/tts hello');
    await pumpFrames(tester);
    expect(
      find.text('Join the call in this channel to use /tts.'),
      findsOneWidget,
    );
    expect(controller.text, '/tts hello');
    expect(sends.count, 0);
    expect(log, isEmpty);
  });

  testWidgets('a bare /tts says what is missing', (tester) async {
    final (controller, sends, log) = await _pump(
      tester,
      inCall: true,
      answer: (_) async => _json(202, {'ahead': 0}),
    );
    await _type(tester, '/tts ');
    await pumpFrames(tester);
    expect(find.text('Type what to say after /tts.'), findsOneWidget);
    expect(controller.text, '/tts ');
    expect(sends.count, 0);
    expect(log, isEmpty);
  });

  testWidgets('a line that failed after it was accepted says so, only here', (
    tester,
  ) async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    await _pump(
      tester,
      inCall: true,
      events: events.stream,
      answer: (_) async => _json(202, {'ahead': 0}),
    );
    events.add(const api.TtsFailed(channelId: 'c2'));
    await pumpFrames(tester);
    expect(find.text("Couldn't speak that line."), findsNothing);
    events.add(const api.TtsFailed(channelId: 'c1'));
    await pumpFrames(tester);
    expect(find.text("Couldn't speak that line."), findsOneWidget);
  });
}
