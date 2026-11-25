// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A share with audio follows new streams by their announcement, not by
/// reading the whole graph every second on the thread that draws the call.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

import 'support/fake_share_audio_graph.dart';

void main() {
  late FakeShareAudioGraph graph;

  setUp(() => graph = FakeShareAudioGraph());

  ShareAudioIsolation isolation({Duration? followEvery}) => ShareAudioIsolation(
        graph: graph,
        followEvery: followEvery ?? const Duration(minutes: 5),
        settleAfterStart: const [Duration(milliseconds: 10)],
      );

  int dumps() => graph.calls.where((c) => c == 'dump').length;

  test('the graph is not read on a one second timer', () {
    expect(ShareAudioIsolation(graph: graph).followEvery,
        greaterThanOrEqualTo(const Duration(seconds: 5)));
  });

  test('a stream announced after the start is linked without any poll',
      () async {
    final mix = isolation();
    await mix.begin();
    addTearDown(mix.end);
    graph.streams[50] = '777';

    graph.startsController.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(graph.links.where((l) => l.$1 ~/ 10 == 50), hasLength(2));
  });

  test('a quiet graph is not read again between announcements', () async {
    final mix = isolation();
    await mix.begin();
    addTearDown(mix.end);
    final before = dumps();

    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(dumps(), before);
  });

  test('an announcement after the share ended links nothing', () async {
    final mix = isolation();
    await mix.begin();
    graph.streams[50] = '777';
    await mix.end();

    graph.startsController.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(graph.links, isEmpty);
  });
}
