// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The line logged when a camera or share ends: what it was, not what one moment looked like.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/track_stats_summary.dart';

final _t0 = DateTime(2026, 1, 1, 12);

VideoStreamStats _layer({
  String? rid,
  int width = 1920,
  int height = 1080,
  double? fps = 30,
  double? bitrate = 3e6,
  String? reason,
  int? pli,
  int? freezes,
  double? freezeSeconds,
  bool? active = true,
}) =>
    VideoStreamStats(
      id: 'o-${rid ?? 'x'}',
      rid: rid,
      width: width,
      height: height,
      fps: fps,
      bitrateBps: bitrate,
      codec: 'VP8',
      implementation: 'libvpx',
      limitationReason: reason,
      pliCount: pli,
      freezeCount: freezes,
      freezeSeconds: freezeSeconds,
      active: active,
    );

VideoStatsSample _sample(
  List<VideoStreamStats> streams, {
  bool local = true,
  CallStatsSource source = CallStatsSource.screenShare,
}) =>
    VideoStatsSample(
      identity: 'me',
      name: 'me',
      source: source,
      local: local,
      streams: streams,
    );

({TrackStatsSummary summary, List<String> lines}) _tracker() {
  final lines = <String>[];
  return (summary: TrackStatsSummary(onSummary: lines.add), lines: lines);
}

void main() {
  test('adds up seconds per limitation reason across samples', () {
    final t = _tracker();
    final s = t.summary;
    s.observe(_sample([_layer(reason: 'none')]), at: _t0);
    s.observe(_sample([_layer(reason: 'none')]),
        at: _t0.add(const Duration(seconds: 5)));
    s.observe(_sample([_layer(reason: 'bandwidth')]),
        at: _t0.add(const Duration(seconds: 10)));
    s.observe(_sample([_layer(reason: 'cpu')]),
        at: _t0.add(const Duration(seconds: 15)));

    s.endAll();

    expect(t.lines.single, contains('limit none=5s bandwidth=5s cpu=5s'));
    expect(t.lines.single,
        startsWith('[call-stats] summary out screenShare me over 15s'));
  });

  test('the worst reason across layers describes the sample', () {
    final t = _tracker();
    t.summary
      ..observe(
          _sample([
            _layer(rid: 'q', reason: 'none'),
            _layer(rid: 'f', reason: 'cpu')
          ]),
          at: _t0)
      ..observe(
          _sample([
            _layer(rid: 'q', reason: 'none'),
            _layer(rid: 'f', reason: 'cpu')
          ]),
          at: _t0.add(const Duration(seconds: 5)))
      ..endAll();

    expect(t.lines.single, contains('limit cpu=5s'));
  });

  test('a gap with no samples is not credited to a reason', () {
    final t = _tracker();
    t.summary
      ..observe(_sample([_layer(reason: 'none')]), at: _t0)
      ..observe(_sample([_layer(reason: 'cpu')]),
          at: _t0.add(const Duration(minutes: 5)))
      ..endAll();

    expect(t.lines.single, isNot(contains('cpu=')));
  });

  test('reports the mean rate and bitrate of each layer on its own', () {
    final t = _tracker();
    t.summary
      ..observe(
          _sample([
            _layer(rid: 'q', width: 640, height: 360, fps: 10, bitrate: 1e6),
            _layer(rid: 'f', fps: 30, bitrate: 4e6)
          ]),
          at: _t0)
      ..observe(
          _sample([
            _layer(rid: 'q', width: 640, height: 360, fps: 20, bitrate: 3e6),
            _layer(rid: 'f', fps: 20, bitrate: 2e6)
          ]),
          at: _t0.add(const Duration(seconds: 5)))
      ..endAll();

    final line = t.lines.single;
    expect(line, contains('q 640x360 mean 15.0fps 2.00Mbps'));
    expect(line, contains('f 1920x1080 mean 25.0fps 3.00Mbps'));
  });

  test('a layer that is not sending does not drag the mean down', () {
    final t = _tracker();
    t.summary
      ..observe(
          _sample([
            _layer(rid: 'h', fps: 30),
            _layer(rid: 'q', fps: 0, bitrate: 0, active: false)
          ]),
          at: _t0)
      ..endAll();

    expect(t.lines.single, contains('h 1920x1080 mean 30.0fps'));
    expect(t.lines.single, isNot(contains('q ')));
  });

  test('names the encoder, keyframe requests and the first frame', () {
    final t = _tracker();
    t.summary
      ..started('out/me/screenShare', at: _t0)
      ..observe(_sample([_layer(fps: 0, pli: 0)]),
          at: _t0.add(const Duration(seconds: 1)))
      ..observe(_sample([_layer(pli: 3)]),
          at: _t0.add(const Duration(milliseconds: 6200)))
      ..endAll();

    final line = t.lines.single;
    expect(line, contains('libvpx VP8'));
    expect(line, contains('keyframe requests=3'));
    expect(line, contains('first frame 6.2s'));
  });

  test('says so when no frame was ever seen', () {
    final t = _tracker();
    t.summary
      ..observe(_sample([_layer(fps: 0)]), at: _t0)
      ..endAll();

    expect(t.lines.single, endsWith('no frame seen'));
  });

  test('a received track reports its freezes, a sent one does not', () {
    final incoming = _tracker();
    incoming.summary
      ..observe(_sample([_layer(freezes: 2, freezeSeconds: 1.5)], local: false),
          at: _t0)
      ..endAll();
    final outgoing = _tracker();
    outgoing.summary
      ..observe(_sample([_layer()]), at: _t0)
      ..endAll();

    expect(incoming.lines.single,
        startsWith('[call-stats] summary in screenShare me'));
    expect(incoming.lines.single, contains('freezes=2 (1.5s)'));
    expect(outgoing.lines.single, isNot(contains('freezes')));
  });

  test('only the tracks that are gone are reported', () {
    final t = _tracker();
    t.summary
      ..observe(_sample([_layer()], source: CallStatsSource.camera), at: _t0)
      ..observe(_sample([_layer()]), at: _t0)
      ..endExcept({'out/me/camera'});

    expect(t.lines, hasLength(1));
    expect(t.lines.single, contains('screenShare'));

    t.summary.endAll();
    expect(t.lines, hasLength(2));
  });

  test('a track that was never sampled leaves no line, and ends once', () {
    final t = _tracker();
    t.summary
      ..started('out/me/camera', at: _t0)
      ..endAll();
    expect(t.lines, isEmpty);

    t.summary
      ..observe(_sample([_layer()]), at: _t0)
      ..endAll()
      ..endAll();
    expect(t.lines, hasLength(1));
  });
}
