// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The marks list while the call goes on: a live line that no mark points at
/// leaves the list alone, and a line a mark points at fills in its text.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/call_transcript_marks.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_marks_list.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

api.TranscriptLine _line(int seq) =>
    api.TranscriptLine(seq: seq, speakerId: 'kiki', at: seq, text: 'line $seq');

api.TranscriptMark _mark(String id, int lineSeq) => api.TranscriptMark(
  id: id,
  transcriptId: 't1',
  authorId: 'kiki',
  at: lineSeq,
  kind: api.TranscriptMarkKind.mark,
  lineSeq: lineSeq,
);

class _Marks extends TranscriptMarksController {
  @override
  TranscriptMarksModel build(String arg) {
    transcriptId = arg;
    return TranscriptMarksModel(
      marks: [for (var i = 1; i <= 5; i++) _mark('m$i', i * 10)],
      loaded: true,
    );
  }
}

class _Lines extends CallTranscriptController {
  @override
  CallTranscriptModel build(String arg) {
    transcriptId = arg;
    return CallTranscriptModel(
      lines: [for (var i = 1; i <= 40; i++) _line(i)],
      loaded: true,
      ongoing: true,
    );
  }

  void say(int seq) =>
      state = state.copyWith(lines: [...state.lines, _line(seq)]);
}

void main() {
  testWidgets('a live line no mark points at does not rebuild the list', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        transcriptMarksProvider.overrideWith(_Marks.new),
        callTranscriptProvider.overrideWith(_Lines.new),
        channelPermissionsProvider.overrideWith((ref, id) async => 0),
        userProfileProvider.overrideWith((ref, id) async => null),
        sessionProvider.overrideWithValue(api.SessionStore()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: CallMarksList(channelId: 'v1', transcriptId: 't1'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('line 10'), findsOneWidget);

    var rebuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is CallMarksList) rebuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    final lines =
        container.read(callTranscriptProvider('t1').notifier) as _Lines;
    for (var seq = 41; seq <= 50; seq++) {
      lines.say(seq);
      await tester.pump();
    }

    expect(rebuilds, 0);
  });
}
