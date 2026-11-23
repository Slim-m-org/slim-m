// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mark frame that lands while the marks are being read is not undone by the
/// older answer: a deleted mark stays gone and a new one stays.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/call_transcript_marks.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/fake_sync.dart';

Map<String, Object?> _wire(String id, int at) => {
  'id': id,
  'transcript_id': 't1',
  'author_id': 'kiki',
  'at': at,
  'line_seq': 1,
  'kind': 'mark',
  'source': 'manual',
};

api.TranscriptMark _mark(String id, int at) => api.TranscriptMark(
  id: id,
  transcriptId: 't1',
  authorId: 'kiki',
  at: at,
  kind: api.TranscriptMarkKind.mark,
);

void main() {
  test('frames that land during a read survive its older answer', () async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final gate = Completer<void>();
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        syncControllerProvider.overrideWith(NoopSyncController.new),
        liveEventsProvider.overrideWithValue(events.stream),
        apiProvider.overrideWith((ref) {
          final client = testApi((request) async {
            if (++reads == 2) await gate.future;
            return http.Response(
              jsonEncode({
                'marks': [_wire('a', 1000), _wire('b', 2000)],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          });
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(transcriptMarksProvider('t1'), (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    expect(sub.read().marks.map((m) => m.id), ['a', 'b']);

    final read = container.read(transcriptMarksProvider('t1').notifier).load();
    await pumpEventQueue();
    events
      ..add(
        const api.CallTranscriptMarkChanged(
          channelId: 'v1',
          transcriptId: 't1',
          markId: 'b',
        ),
      )
      ..add(
        api.CallTranscriptMarkChanged(
          channelId: 'v1',
          transcriptId: 't1',
          markId: 'c',
          mark: _mark('c', 3000),
        ),
      );
    await pumpEventQueue();
    gate.complete();
    await read;

    expect(sub.read().marks.map((m) => m.id), ['a', 'c']);
  });
}
