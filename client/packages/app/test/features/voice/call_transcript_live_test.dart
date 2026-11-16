// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Live transcript lines (decision 0113, amended 2026-11-16): the next line is
/// appended with no read, a repeat or another call's line is ignored, a gap or
/// a reconnect reads what was missed, and lines that land mid-read wait for it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/call_transcript.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/fake_sync.dart';

api.TranscriptLine _line(int seq) => api.TranscriptLine(
  seq: seq,
  speakerId: 'kiki',
  at: seq * 1000,
  endAt: seq * 1000 + 500,
  language: 'en',
  text: 'line $seq',
);

Map<String, dynamic> _wire(api.TranscriptLine line) => {
  'seq': line.seq,
  'speaker_id': line.speakerId,
  'at': line.at,
  'end_at': line.endAt,
  'language': line.language,
  'text': line.text,
};

class _Rig {
  _Rig(this.container, this.events, this.stored);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;

  /// What the server holds; the route pages through it by `after_seq`.
  final List<api.TranscriptLine> stored;
  final reads = <int?>[];

  /// While set, a read waits for it before answering.
  Completer<void>? gate;

  CallTranscriptModel get model => container.read(callTranscriptProvider('t1'));
  List<int> get seqs => [for (final line in model.lines) line.seq];
  NoopSyncController get sync =>
      container.read(syncControllerProvider.notifier) as NoopSyncController;

  void push(api.TranscriptLine line, {String transcriptId = 't1'}) =>
      events.add(
        api.CallTranscriptLineAdded(
          channelId: 'voice-1',
          transcriptId: transcriptId,
          line: line,
        ),
      );

  void store(Iterable<int> seqs) => stored.addAll(seqs.map(_line));
}

Future<_Rig> _open(Iterable<int> held, {int pageSize = 50}) async {
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  late final _Rig rig;
  final container = ProviderContainer(
    overrides: [
      liveEventsProvider.overrideWithValue(events.stream),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      apiProvider.overrideWith((ref) {
        final client = testApi((request) async {
          final after = int.tryParse(
            request.url.queryParameters['after_seq'] ?? '',
          );
          rig.reads.add(after);
          await rig.gate?.future;
          final rest = rig.stored.where((l) => l.seq > (after ?? 0)).toList();
          final page = rest.take(pageSize).toList();
          return http.Response(
            jsonEncode({
              'id': 't1',
              'channel_id': 'voice-1',
              'started_at': 0,
              'ended_at': null,
              'mode': 'always',
              'lines': [for (final line in page) _wire(line)],
              'next_after_seq': rest.length > pageSize ? page.last.seq : null,
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
  rig = _Rig(container, events, [for (final seq in held) _line(seq)]);
  container.listen(callTranscriptProvider('t1'), (_, _) {});
  container.read(syncControllerProvider.notifier);
  await pumpEventQueue();
  return rig;
}

void main() {
  test('the next line is appended with no read and keeps its timing', () async {
    final rig = await _open([1, 2]);
    expect(rig.seqs, [1, 2]);
    expect(rig.reads, [null]);

    rig.push(_line(3));
    await pumpEventQueue();

    expect(rig.seqs, [1, 2, 3]);
    expect(rig.reads, [null], reason: 'no read for a line that follows on');
    final added = rig.model.lines.last;
    expect((added.endAt, added.language), (3500, 'en'));
  });

  test('a repeat and another call\'s line are both ignored', () async {
    final rig = await _open([1, 2]);

    rig.push(_line(2));
    rig.push(_line(3), transcriptId: 't2');
    await pumpEventQueue();

    expect(rig.seqs, [1, 2]);
    expect(rig.reads, [null]);
  });

  test('a gap reads the missing lines after the last one held', () async {
    final rig = await _open([1, 2]);
    rig.store([3, 4, 5]);

    rig.push(_line(5));
    await pumpEventQueue();

    expect(rig.reads, [null, 2]);
    expect(rig.seqs, [1, 2, 3, 4, 5]);
  });

  test(
    'lines that land during a read are applied after it, in order',
    () async {
      final rig = await _open([1, 2]);
      rig.gate = Completer<void>();
      rig.events.add(
        const api.CallTranscriptChanged(
          channelId: 'voice-1',
          transcriptId: 't1',
          ended: false,
        ),
      );
      await pumpEventQueue();
      expect(rig.model.busy, isTrue);

      rig.store([3, 4]);
      rig.push(_line(4));
      rig.push(_line(3));
      rig.gate!.complete();
      await pumpEventQueue();

      expect(rig.seqs, [1, 2, 3, 4]);
      expect(rig.reads, [null, 2]);
    },
  );

  test('a reconnect reads the lines sent while the socket was down', () async {
    final rig = await _open([1, 2]);
    rig.sync.report(SyncStatus.offline);
    rig.store([3, 4]);

    rig.sync.report(SyncStatus.live);
    await pumpEventQueue();

    expect(rig.reads, [null, 2]);
    expect(rig.seqs, [1, 2, 3, 4]);
  });

  test('a line past pages not read yet waits for paging to reach it', () async {
    final rig = await _open([1, 2, 3], pageSize: 2);
    expect(rig.seqs, [1, 2]);
    expect(rig.model.hasMore, isTrue);

    rig.push(_line(4));
    await pumpEventQueue();

    expect(rig.seqs, [1, 2]);
    expect(rig.reads, [null]);
  });
}
