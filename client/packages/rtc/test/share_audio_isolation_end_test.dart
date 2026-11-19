// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ending a share must leave nothing feeding the mix when it goes: WirePlumber
/// pauses every media player still linked into a sink that is removed.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

import 'support/fake_share_audio_graph.dart';

void main() {
  late FakeShareAudioGraph graph;
  late ShareAudioIsolation isolation;

  setUp(() {
    graph = FakeShareAudioGraph();
    isolation = ShareAudioIsolation(
      graph: graph,
      followEvery: const Duration(milliseconds: 20),
    );
  });
  tearDown(() => isolation.end());

  test('the mix is emptied before it goes, so no player feeding it is paused',
      () async {
    await isolation.begin();
    expect(graph.links, isNotEmpty);

    await isolation.end();

    expect(graph.linkedAtDestroy, isEmpty);
    expect(graph.unlinked.toSet(), {(301, 91), (302, 92)});
  });

  test(
      'a link pass still running when the share ends finishes first, '
      'links nothing more, and is undone before the mix goes', () async {
    await isolation.begin();
    graph.holdLink = Completer<void>();
    graph.streams[40] = '1000';
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final from = graph.calls.length;

    final ended = isolation.end();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    graph.holdLink!.complete();
    await ended;

    final during = graph.calls.sublist(from);
    expect(during.first, 'link 401 91');
    expect(during.where((c) => c.startsWith('link ')), ['link 401 91']);
    expect(during, contains('unlink 401 91'));
    expect(during.last, 'destroy');
    expect(graph.linkedAtDestroy, isEmpty);
  });

  group('a sound server that stops answering cannot hold up the end of a share',
      () {
    setUp(() {
      isolation = ShareAudioIsolation(
        graph: graph,
        followEvery: const Duration(milliseconds: 20),
        emptyWithin: const Duration(milliseconds: 50),
      );
    });

    test('while the mix is being emptied', () async {
      await isolation.begin();
      graph.holdDump = Completer<void>();

      await isolation.end().timeout(const Duration(seconds: 1));

      expect(graph.destroys, 1);
      expect(isolation.active, isFalse);
    });

    test('while a link is still being made', () async {
      await isolation.begin();
      graph.holdLink = Completer<void>();
      graph.streams[40] = '1000';
      await Future<void>.delayed(const Duration(milliseconds: 60));

      await isolation.end().timeout(const Duration(seconds: 1));

      expect(graph.destroys, 1);
      expect(isolation.active, isFalse);
    });
  });
}
