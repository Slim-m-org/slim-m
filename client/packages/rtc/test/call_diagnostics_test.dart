// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The text a person pastes into a bug report about a call.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

const _facts = {'App': 'slim-m 1.2.3', 'Platform': 'windows'};

const _minute = '[voice-health] last 60s | Ann: conceal=0.5% events=1';
const _summary = '[voice-health] call summary over 120s conceal p50=0.1%';

VideoStatsSample _video({TransportStats? transport, double fps = 30}) =>
    VideoStatsSample(
      identity: 'me',
      name: 'me',
      source: CallStatsSource.camera,
      local: true,
      streams: [VideoStreamStats(id: 'o', width: 1280, height: 720, fps: fps)],
      transport: transport,
    );

void main() {
  late DateTime now;
  late CallDiagnostics diag;

  setUp(() {
    now = DateTime(2026, 1, 1, 12);
    diag = CallDiagnostics(clock: () => now);
  });

  test('before any call it says none is active and none ran', () {
    final text = diag.report(facts: _facts);

    expect(
        text, contains('No call is active, and none has run in this session.'));
    expect(text, contains('App: slim-m 1.2.3'));
    expect(text, contains('Platform: windows'));
    expect(text, contains('No once-a-minute audio line yet.'));
    expect(text, contains('No video was sampled.'));
    expect(diag.active, isFalse);
  });

  test('in a call it says how long and carries the latest lines', () {
    diag.begin();
    now = now.add(const Duration(seconds: 90));
    diag
      ..noteHealthLine('[voice-health] last 60s | old')
      ..noteHealthLine(_minute)
      ..noteStats(_video());

    final text = diag.report(facts: _facts);

    expect(diag.active, isTrue);
    expect(text, contains('In a call for 90s.'));
    expect(text, contains(_minute));
    expect(text, isNot(contains('| old')));
    expect(text, contains('[call-stats] out camera me'));
  });

  test('after the call it says none is active and keeps the last call', () {
    diag.begin();
    diag.noteHealthLine(_summary);
    now = now.add(const Duration(seconds: 45));
    diag.end();
    now = now.add(const Duration(hours: 1));

    final text = diag.report(facts: _facts);

    expect(diag.active, isFalse);
    expect(text,
        contains('No call is active. Showing the last call, which ran 45s.'));
    expect(text, contains(_summary));
  });

  test('a new call clears the last one, a reconnect does not', () {
    diag
      ..begin()
      ..noteHealthLine(_minute)
      ..noteHealthLine(_summary)
      ..noteStats(_video())
      ..noteTrackSummary('summary one')
      ..begin();
    final reconnected = diag.report(facts: _facts);
    expect(reconnected, contains(_minute));
    expect(reconnected, contains(_summary));

    diag
      ..end()
      ..begin();
    final fresh = diag.report(facts: _facts);
    expect(fresh, isNot(contains(_minute)));
    expect(fresh, isNot(contains(_summary)));
    expect(fresh, isNot(contains('[call-stats]')));
    expect(fresh, isNot(contains('summary one')));
  });

  test('a health line of another kind is ignored', () {
    diag.begin();
    diag.noteHealthLine('Audio from Ann was 9% concealed');

    expect(diag.report(facts: _facts), isNot(contains('9% concealed')));
  });

  test('names the network path, from video or from audio alone', () {
    diag.begin();
    diag.noteTransport(
      const TransportStats(
        rttMs: 42,
        availableOutgoingBps: 3e6,
        localType: 'relay',
        remoteType: 'host',
        protocol: 'udp',
      ),
    );

    final text = diag.report(facts: _facts);

    expect(
        text,
        contains(
            'Network path: relay to host over udp (relayed) rtt=42ms available=3.00Mbps'));
  });

  test('a later sample without a path keeps the one already known', () {
    diag.begin();
    diag.noteTransport(
        const TransportStats(localType: 'host', protocol: 'udp'));
    diag.noteStats(_video());

    expect(diag.report(facts: _facts),
        contains('Network path: host to ? over udp'));
  });

  test('the join timings and share summaries are included', () {
    diag.begin();
    diag.noteTrackSummary('[call-stats] summary out screenShare me over 60s');

    final text = diag.report(
      facts: _facts,
      joinLine: 'Join timings in ms from the click: click=0 connected=900',
    );

    expect(text,
        contains('Join timings in ms from the click: click=0 connected=900'));
    expect(text, contains('[call-stats] summary out screenShare me over 60s'));
  });

  test('keeps only the newest share summaries', () {
    diag.begin();
    for (var i = 0; i < kDiagnosticsSummaryCap + 3; i++) {
      diag.noteTrackSummary('summary $i');
    }

    final text = diag.report(facts: _facts);

    expect(text, isNot(contains('summary 0\n')));
    expect(text, contains('summary ${kDiagnosticsSummaryCap + 2}'));
  });

  test('holds no token or address', () {
    diag.begin();
    diag.noteStats(_video(
        transport: const TransportStats(localType: 'srflx', protocol: 'udp')));
    diag.noteHealthLine(_minute);

    final text = diag.report(facts: _facts);

    expect(text, isNot(matches(RegExp(r'\d+\.\d+\.\d+\.\d+'))));
    expect(text.toLowerCase(), isNot(contains('token')));
    expect(text, isNot(contains('wss://')));
  });
}
