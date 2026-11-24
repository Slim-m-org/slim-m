// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Marks and notes in a transcribed call: one mark action behind the button and
/// both shortcuts, the header chip for the people the frame reaches, and the
/// after-call list with removal for the author or a message moderator.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/call_audio.dart';
import 'package:slimm_app/src/features/voice/providers/call_mark_actions.dart';
import 'package:slimm_app/src/features/voice/providers/call_mark_chip.dart';
import 'package:slimm_app/src/features/voice/providers/call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/call_transcript_marks.dart';
import 'package:slimm_app/src/features/voice/providers/live_call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_marks_list.dart';
import 'package:slimm_app/src/features/voice/widgets/call_mark_chip.dart';
import 'package:slimm_app/src/features/voice/widgets/call_note_sheet.dart';
import 'package:slimm_app/src/features/voice/widgets/captions_button.dart';
import 'package:slimm_app/src/features/voice/widgets/mark_button.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 4102444800000,
);

api.CallAudioState _running() => const api.CallAudioState(
  moduleId: api.CallAudioState.serverConsumerId,
  moduleName: 'Call transcript',
  purpose: 'Writes down what is said.',
  keeps: 'Each line.',
  isOn: true,
  askedBy: '',
  included: ['me'],
  pending: [],
  expiresAtMs: 4102444800000,
  full: false,
  always: true,
  transcriptId: 't1',
);

class _Audio extends CallAudioController {
  _Audio(this._state);

  final api.CallAudioState? _state;

  @override
  CallAudioModel build(String arg) {
    channelId = arg;
    return CallAudioModel(status: api.CallAudioStatus(session: _state));
  }
}

Map<String, Object?> _mark(String id, String author, {String? note}) => {
  'id': id,
  'transcript_id': 't1',
  'author_id': author,
  'at': 1000,
  'line_seq': 1,
  'kind': note == null ? 'mark' : 'note',
  'text': note,
  'source': 'manual',
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Rig {
  _Rig(this.container, this.events, this.requests);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final List<String> requests;
}

Future<_Rig> _pump(
  WidgetTester tester,
  Widget child, {
  bool transcribed = true,
  int bits = Perm.viewChannel | Perm.viewTranscripts,
  List<Map<String, Object?>> marks = const [],
  int failPuts = 0,
}) async {
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final requests = <String>[];
  final container = ProviderContainer(
    overrides: [
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      liveEventsProvider.overrideWithValue(events.stream),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      voiceFlagsProvider.overrideWithValue(
        const VoiceFlags(channelId: 'voice-1'),
      ),
      callAudioProvider.overrideWith(
        () => _Audio(transcribed ? _running() : null),
      ),
      channelPermissionsProvider.overrideWith((ref, id) async => bits),
      userProfileProvider.overrideWith((ref, id) async => null),
      callTranscriptProvider.overrideWith(_NoLines.new),
      apiProvider.overrideWith((ref) {
        final client = testApi((request) async {
          requests.add('${request.method} ${request.url.path} ${request.body}');
          if (request.method == 'DELETE') return http.Response('', 204);
          if (request.method == 'PUT' && failPuts > 0) {
            failPuts--;
            return _json({'error': 'down'}, 503);
          }
          if (request.method == 'PUT') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final id = request.url.pathSegments.last;
            return _json(_mark(id, 'me', note: body['text'] as String?), 201);
          }
          return _json({'marks': marks});
        }, session: api.SessionStore(tokens: _tokens));
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return _Rig(container, events, requests);
}

class _NoLines extends CallTranscriptController {
  @override
  CallTranscriptModel build(String arg) {
    transcriptId = arg;
    return const CallTranscriptModel(loaded: true);
  }
}

Widget _dock() => Consumer(
  builder: (context, ref, _) => Column(
    children: [
      if (canUseCaptions(ref, 'voice-1')) const MarkButton(),
      const CallMarkChipView(channelId: 'voice-1'),
    ],
  ),
);

void main() {
  testWidgets('the Mark button marks the moment and the chip says so', (
    tester,
  ) async {
    final rig = await _pump(tester, _dock());

    await tester.tap(find.byKey(markButtonKey));
    await tester.pump();
    await tester.pump();

    expect(rig.requests.single, startsWith('PUT /voice/transcripts/t1/marks/'));
    expect(rig.requests.single, endsWith('{"kind":"mark"}'));
    expect(find.text('Marked'), findsOneWidget);
    await tester.pump(callMarkChipFor);
    expect(find.text('Marked'), findsNothing, reason: 'the chip clears');
  });

  testWidgets('a note retried after a failure is the same mark', (
    tester,
  ) async {
    final rig = await _pump(
      tester,
      Consumer(
        builder: (context, ref, _) => TextButton(
          onPressed: () => unawaited(showCallNoteSheet(context)),
          child: const Text('open'),
        ),
      ),
      failPuts: 1,
    );
    final held = rig.container.listen(
      liveCallTranscriptIdProvider('voice-1'),
      (_, _) {},
    );
    addTearDown(held.close);
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byKey(callNoteFieldKey), 'remember this');
    await tester.pump();

    await tester.tap(find.byKey(callNoteSaveKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(callNoteSaveKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final ids = [for (final r in rig.requests) r.split(' ')[1]];
    expect(ids, hasLength(2));
    expect(ids.first, ids.last, reason: 'a retry is the same mark');
  });

  testWidgets('a note is counted in code points, as the server counts it', (
    tester,
  ) async {
    await _pump(
      tester,
      Consumer(
        builder: (context, ref, _) => TextButton(
          onPressed: () => unawaited(showCallNoteSheet(context)),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    const family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}';
    bool saveDisabled() =>
        tester.widget<AppButton>(find.byKey(callNoteSaveKey)).disabled;

    await tester.enterText(
      find.byKey(callNoteFieldKey),
      '${family * 71}${'a' * 3}',
    );
    await tester.pump();
    expect(saveDisabled(), isFalse, reason: '500 code points, 74 graphemes');

    await tester.enterText(
      find.byKey(callNoteFieldKey),
      '${family * 71}${'a' * 4}',
    );
    await tester.pump();
    expect(saveDisabled(), isTrue, reason: '501 code points, 75 graphemes');
  });

  testWidgets('no button without VIEW_TRANSCRIPTS or a running transcript', (
    tester,
  ) async {
    await _pump(tester, _dock(), bits: Perm.viewChannel);
    expect(find.byKey(markButtonKey), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, _dock(), transcribed: false);
    expect(find.byKey(markButtonKey), findsNothing);
  });

  testWidgets('a shortcut with no transcript running only says so', (
    tester,
  ) async {
    final rig = await _pump(tester, _dock(), transcribed: false);

    final failed = await rig.container.read(callMarkActionsProvider).mark();
    await tester.pump();

    expect(failed, notTranscribedNotice);
    expect(rig.requests, isEmpty);
    expect(find.text(notTranscribedNotice), findsOneWidget);
    await tester.pump(callMarkChipFor);
  });

  testWidgets('someone else\'s mark arrives as a chip and joins the list', (
    tester,
  ) async {
    final rig = await _pump(tester, _dock());
    final sub = rig.container.listen(transcriptMarksProvider('t1'), (_, _) {});
    addTearDown(sub.close);
    await tester.pump();

    rig.events.add(
      api.CallTranscriptMarkChanged(
        channelId: 'voice-1',
        transcriptId: 't1',
        markId: 'm9',
        mark: api.TranscriptMark.fromJson(_mark('m9', 'kiki', note: 'ship')),
      ),
    );
    await tester.pump();
    expect(find.text('Someone saved a note'), findsOneWidget);
    expect(sub.read().marks.map((m) => m.id), ['m9']);

    rig.events.add(
      const api.CallTranscriptMarkChanged(
        channelId: 'voice-1',
        transcriptId: 't1',
        markId: 'm9',
      ),
    );
    await tester.pump();
    expect(sub.read().marks, isEmpty, reason: 'a null mark removes it');
    await tester.pump(callMarkChipFor);
  });

  testWidgets(
    'only the author may remove a mark, and a tap jumps to its line',
    (tester) async {
      final rig = await _pump(
        tester,
        const CallMarksList(channelId: 'voice-1', transcriptId: 't1'),
        marks: [
          _mark('mine', 'me'),
          _mark('theirs', 'kiki', note: 'later'),
        ],
      );
      await tester.pump();

      expect(find.byKey(callMarkDeleteKey('mine')), findsOneWidget);
      expect(find.byKey(callMarkDeleteKey('theirs')), findsNothing);

      await tester.tap(find.byKey(callMarkRowKey('theirs')));
      expect(rig.container.read(transcriptFocusProvider)?.seq, 1);

      await tester.tap(find.byKey(callMarkDeleteKey('mine')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Remove'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(rig.requests.last, 'DELETE /voice/transcripts/t1/marks/mine ');
      expect(find.byKey(callMarkRowKey('mine')), findsNothing);
    },
  );

  testWidgets('a message moderator may remove anyone\'s mark', (tester) async {
    await _pump(
      tester,
      const CallMarksList(channelId: 'voice-1', transcriptId: 't1'),
      bits: Perm.viewChannel | Perm.viewTranscripts | Perm.manageMessages,
      marks: [_mark('theirs', 'kiki')],
    );
    await tester.pump();
    expect(find.byKey(callMarkDeleteKey('theirs')), findsOneWidget);
  });

  test('the chip names the author, or says it was yours', () {
    const mine = CallMarkChip.mark(authorId: 'me', note: false);
    const theirs = CallMarkChip.mark(authorId: 'kiki', note: true);
    expect(callMarkChipText(mine, me: 'me'), 'Marked');
    expect(
      callMarkChipText(theirs, me: 'me', name: 'Kiki'),
      'Kiki saved a note',
    );
    expect(
      callMarkChipText(const CallMarkChip.mark(authorId: 'a', note: false)),
      'Someone marked this',
    );
  });
}
