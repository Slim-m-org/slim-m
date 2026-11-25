// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The running call's transcript pane (decision 0113): a read that fails after
/// lines loaded stays on screen as an error with a retry, above the lines.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/widgets/live_transcript_view.dart';
import 'package:slimm_app/src/features/voice/widgets/transcript_line_row.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/fake_sync.dart';

Map<String, dynamic> _wireLine(int seq) => {
  'seq': seq,
  'speaker_id': 'kiki',
  'at': seq * 1000,
  'text': 'line number $seq',
};

void main() {
  testWidgets('a failed read after lines loaded shows a retry that reads on', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    var failNext = true;
    final container = ProviderContainer(
      overrides: [
        liveEventsProvider.overrideWithValue(events.stream),
        syncControllerProvider.overrideWith(NoopSyncController.new),
        apiProvider.overrideWith((ref) {
          final client = testApi((request) async {
            if (request.url.path != '/voice/transcripts/t1') {
              return http.Response('{}', 200);
            }
            final after = request.url.queryParameters['after_seq'];
            if (after == null) return _page([1, 2], next: 2);
            if (failNext) {
              failNext = false;
              return http.Response('{}', 500);
            }
            return _page([3]);
          });
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
          home: const Scaffold(body: LiveTranscriptView(transcriptId: 't1')),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('line number 2'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Retry'), findsNothing);
    expect(find.byKey(transcriptLineKey(3)), findsOneWidget);
  });
}

http.Response _page(List<int> seqs, {int? next}) => http.Response(
  jsonEncode({
    'id': 't1',
    'channel_id': 'voice-1',
    'started_at': 0,
    'ended_at': null,
    'mode': 'always',
    'lines': [for (final seq in seqs) _wireLine(seq)],
    'next_after_seq': next,
  }),
  200,
  headers: {'content-type': 'application/json'},
);
