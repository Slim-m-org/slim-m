// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The audio half of the call stats panel: the last minute of each person, and the words for it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_stats_lines.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/async_wait.dart';
import 'call_stats_harness.dart';
import 'voice_settings_screen_harness.dart';

Future<VoiceController> _joined(
  WidgetTester tester,
  FakeSettingsSession session,
) async {
  await tester.pumpWidget(callStatsScreenFor(session));
  final controller = ProviderScope.containerOf(
    tester.element(find.text('Call stats')),
  ).read(voiceControllerProvider.notifier);
  await controller.join('channel-1');
  await waitUntil(
    tester,
    () => controller.state.state == VoiceSessionState.connected,
  );
  return controller;
}

void main() {
  testWidgets('the audio card shows the last minute of each person', (
    tester,
  ) async {
    final session = FakeSettingsSession()
      ..callStats = CallStatsSampler(targets: () => const []);
    session.health = _HealthWithAnn();
    final controller = await _joined(tester, session);

    expect(find.text('Audio, last minute'), findsOneWidget);
    expect(find.text('Ann, audio'), findsOneWidget);
    expect(find.textContaining('breaking up 0.0%'), findsOneWidget);

    await controller.leave();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the audio card says it is waiting before any numbers', (
    tester,
  ) async {
    final session = FakeSettingsSession();
    final controller = await _joined(tester, session);

    expect(find.text('Waiting for audio numbers.'), findsOneWidget);

    await controller.leave();
    await tester.pumpWidget(const SizedBox());
  });

  group('audio wording', () {
    test('a heard person reads as breaking up, jitter, buffer and loss', () {
      final window = HealthWindow(const Duration(seconds: 60))
        ..add(
          const HealthInterval(
            seconds: 10,
            samples: 1000,
            concealedSamples: 60,
            lostPackets: 1,
            receivedPackets: 99,
            jitterMs: 12,
            bufferMs: 40,
            rttMs: 42,
          ),
        );
      final line = callStatsAudioLine(NamedWindow('Ann', window));

      expect(
        line,
        'breaking up 6.0%  jitter 12 ms  buffer 40 ms  loss 1.0%  round trip 42 ms',
      );
      expect(callStatsAudioTitle(NamedWindow('Ann', window)), 'Ann, audio');
    });

    test('our own audio reads as what we send', () {
      final window = HealthWindow(const Duration(seconds: 60))
        ..add(const HealthInterval(seconds: 10, kbps: 32.4, rttMs: 40));
      final named = NamedWindow('you', window, local: true);

      expect(callStatsAudioTitle(named), 'You, sending audio');
      expect(callStatsAudioLine(named), 'sending 32 kbps  round trip 40 ms');
    });
  });
}

class _HealthWithAnn extends VoiceHealth {
  @override
  List<NamedWindow> recentWindows() => [
    NamedWindow(
      'Ann',
      HealthWindow(const Duration(seconds: 60))
        ..add(const HealthInterval(seconds: 10, samples: 1000)),
    ),
  ];
}
