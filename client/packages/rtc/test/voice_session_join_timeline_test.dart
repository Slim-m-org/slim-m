// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A real session files its join, its toggles and the platform's audio
/// events on the call's timeline, so a short call still has a report.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/rtc.dart';

import 'support/session_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> logged;
  late VoiceSession session;

  setUp(() async {
    logged = [];
    session = instantSession(
      mic: CountingMic(),
      audioLog: (line, {level = LogLevel.info}) => logged.add(line),
    );
    addTearDown(session.dispose);
    await session.join(url: 'wss://a.invalid', token: 't');
  });

  String timeline() => session.diagnostics.report(facts: const {});

  test('a join files its steps from the join', () {
    final text = timeline();

    expect(text, contains('+0.0s Joining'));
    expect(text, contains('s Mic open'));
    expect(text, contains('s Connected'));
    expect(logged, contains('[call-join] Connected'));
  });

  test('a platform event is filed and the audio read with its session',
      () async {
    session.audioSessionReader = () async => 'session playback/default';

    session.noteCallSystemEvent('Audio route changed (category change)');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final text = timeline();
    expect(text, contains('s Audio route changed (category change)'));
    expect(
      text,
      contains(
          'Audio check (after an event): mic on | session playback/default'),
    );
  });

  test('deafen and mute toggles are filed', () async {
    await session.setDeafened(true);
    await session.setMicrophoneEnabled(false);

    final text = timeline();
    expect(text, contains('s Deafen on'));
    expect(text, contains('s Mic off'));
  });

  test('a reconnect in the call is filed both ways', () {
    session.health.reconnect.restarting.value = true;
    session.health.reconnect.restarting.value = false;

    final text = timeline();
    expect(text, contains('s Reconnecting'));
    expect(text, contains('s Reconnected'));
  });

  test('leaving files the end on the same call', () async {
    await session.leave();

    expect(timeline(), contains('s Left'));
  });
}
