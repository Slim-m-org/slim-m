// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call stats panel: an empty state outside a call, live numbers inside
/// one, and wording that matches the sample.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/call_stats_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/call_stats_lines.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_settings_screen_harness.dart';

const _sample = VideoStatsSample(
  identity: 'u2',
  name: 'Bo',
  source: CallStatsSource.screenShare,
  local: false,
  streams: [
    VideoStreamStats(
      id: 'in-1',
      width: 1920,
      height: 1080,
      fps: 59.6,
      bitrateBps: 4200000,
      codec: 'VP8',
      implementation: 'libvpx',
      freezeCount: 2,
      freezeSeconds: 1.5,
      framesDropped: 7,
      jitterMs: 10,
    ),
  ],
  transport: TransportStats(rttMs: 42, localType: 'host', protocol: 'udp'),
);

List<Override> _overrides(FakeSession session) => [
  sessionProvider.overrideWithValue(SessionStore(tokens: tokens)),
  apiProvider.overrideWith((ref) {
    final api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: ref.watch(sessionProvider),
      httpClient: voiceTokenClient(),
    );
    ref.onDispose(api.close);
    return api;
  }),
  voiceControllerProvider.overrideWith(
    (ref) => VoiceController(ref, session: session),
  ),
];

Widget _screen(FakeSession session) => UncontrolledProviderScope(
  container: ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      ..._overrides(session),
    ],
  )..read(preferencesProvider),
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const CallStatsScreen(),
  ),
);

void main() {
  testWidgets('outside a call it says so and starts no sampling', (
    tester,
  ) async {
    var asked = 0;
    final session = FakeSession()
      ..callStats = CallStatsSampler(
        targets: () {
          asked++;
          return const [];
        },
      );
    await tester.pumpWidget(_screen(session));
    await tester.pumpAndSettle();

    expect(find.text('Join a call to see its video stats.'), findsOneWidget);
    expect(session.callStats.running, isFalse);
    expect(asked, 0);
  });

  testWidgets('in a call it shows the sampled numbers', (tester) async {
    final session = FakeSession()
      ..callStats = CallStatsSampler(
        targets: () => [
          CallStatsTarget(
            identity: 'u2',
            name: 'Bo',
            source: CallStatsSource.screenShare,
            local: false,
            fetch: () async => const [
              StatsEntry(
                type: 'inbound-rtp',
                id: 'in-1',
                values: {
                  'kind': 'video',
                  'frameWidth': 1920,
                  'frameHeight': 1080,
                  'framesPerSecond': 59.6,
                  'freezeCount': 2,
                },
              ),
            ],
          ),
        ],
      );
    await tester.pumpWidget(_screen(session));
    await tester.pumpAndSettle();
    final controller = ProviderScope.containerOf(
      tester.element(find.byType(CallStatsScreen)),
    ).read(voiceControllerProvider.notifier);
    await controller.join('channel-1');
    await tester.pumpAndSettle();
    expect(session.callStats.running, isTrue);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(find.text('Bo, screen share'), findsOneWidget);
    expect(find.textContaining('1920x1080 at 60 fps'), findsOneWidget);
    await controller.leave();
    await tester.pumpWidget(const SizedBox());
    expect(session.callStats.running, isFalse);
  });

  testWidgets('the log toggle flips the sampler while in a call', (
    tester,
  ) async {
    final session = FakeSession()
      ..callStats = CallStatsSampler(targets: () => const []);
    await tester.pumpWidget(_screen(session));
    await tester.pumpAndSettle();
    final controller = ProviderScope.containerOf(
      tester.element(find.byType(CallStatsScreen)),
    ).read(voiceControllerProvider.notifier);
    await controller.join('channel-1');
    await tester.pumpAndSettle();
    expect(session.callStats.logging, isFalse);

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();
    expect(session.callStats.logging, isTrue);

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();
    expect(session.callStats.logging, isFalse);

    await controller.leave();
    await tester.pumpWidget(const SizedBox());
  });

  group('wording', () {
    test('titles name who is sending what', () {
      expect(callStatsTitle(_sample), 'Bo, screen share');
    });

    test('a received stream reports size, rate, codec and trouble', () {
      expect(callStatsStreamLines(_sample.streams.single, local: false), [
        '1920x1080 at 60 fps  4.20 Mbps',
        'VP8  libvpx',
        '2 freezes (1.5 s)  7 frames dropped  jitter 10 ms',
      ]);
    });

    test('a sent layer names the reason it is held back', () {
      const layer = VideoStreamStats(
        id: 'out-1',
        rid: 'f',
        width: 1280,
        height: 720,
        fps: 15,
        bitrateBps: 900000,
        targetBitrateBps: 1700000,
        limitationReason: 'bandwidth',
        limitationResolutionChanges: 3,
      );
      expect(callStatsStreamLines(layer, local: true), [
        'layer f  1280x720 at 15 fps  0.90 Mbps of 1.70 Mbps',
        'lowered automatically, the connection cannot carry more  3 size changes',
      ]);
    });

    test('the path line is absent when the report had none', () {
      expect(callStatsTransportLine(null), isNull);
      expect(
        callStatsTransportLine(_sample.transport),
        '42 ms round trip  host udp',
      );
    });
  });
}
