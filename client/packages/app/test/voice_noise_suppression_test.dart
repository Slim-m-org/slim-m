// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Standard or strong noise suppression in Voice settings: "Space default"
/// follows the Space's choice on `/version`, a member's own pick wins, and
/// the result reaches the session.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/noise_suppression.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/strong_noise_status.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/screens/voice_settings_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_settings_screen_harness.dart';

http.Client _client({required bool spaceStrong}) => MockClient((request) async {
  if (request.url.path == '/version') {
    return http.Response(
      jsonEncode({
        'name': 'slim-m',
        'version': '0.89.0',
        'protocol': 1,
        'strong_noise_suppression': spaceStrong,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  return http.Response(
    jsonEncode({
      'url': 'wss://sfu.example.com',
      'room': 'channel-1',
      'token': 'jwt',
      'expires_at': 0,
      'can_publish': true,
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
});

Future<FakeSession> _pump(
  WidgetTester tester, {
  bool spaceStrong = false,
}) async {
  final session = FakeSession(supportsInputGate: true);
  addTearDown(session.dispose);
  await tester.pumpWidget(
    wrap(
      const VoiceSettingsBody(),
      overrides: [
        sessionProvider.overrideWithValue(SessionStore(tokens: tokens)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: _client(spaceStrong: spaceStrong),
          );
          ref.onDispose(api.close);
          return api;
        }),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: session),
        ),
      ],
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(VoiceSettingsBody)));

Finder _picker() => find.byWidgetPredicate(
  (w) => w is AppSegmentedControl && w.semanticLabel == 'Noise suppression',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a choice resolves against the Space default', () {
    for (final spaceStrong in [true, false]) {
      expect(
        NoiseSuppressionChoice.spaceDefault.isStrong(spaceStrong: spaceStrong),
        spaceStrong,
      );
      expect(
        NoiseSuppressionChoice.standard.isStrong(spaceStrong: spaceStrong),
        isFalse,
      );
      expect(
        NoiseSuppressionChoice.strong.isStrong(spaceStrong: spaceStrong),
        isTrue,
      );
    }
    expect(
      NoiseSuppressionChoice.parse(null),
      NoiseSuppressionChoice.spaceDefault,
    );
    expect(
      NoiseSuppressionChoice.parse('strong'),
      NoiseSuppressionChoice.strong,
    );
  });

  testWidgets('it starts on Space default and says what the Space uses', (
    tester,
  ) async {
    await _pump(tester, spaceStrong: true);
    expect(_picker(), findsOneWidget);
    expect(tester.widget<AppSegmentedControl>(_picker()).selectedIndex, 0);
    expect(find.text('This Space uses Strong.'), findsOneWidget);
  });

  testWidgets('picking Strong persists it and reaches the session', (
    tester,
  ) async {
    final session = await _pump(tester);
    tester.widget<AppSegmentedControl>(_picker()).onSegmentSelected(2);
    await tester.pumpAndSettle();

    expect(tester.widget<AppSegmentedControl>(_picker()).selectedIndex, 2);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('slimm.voice.noise_suppression'), 'strong');
    expect(session.lastStrongNoiseSuppression, isTrue);
  });

  testWidgets('on Space default the session follows the Space once it is '
      'read, and Standard overrides it', (tester) async {
    final session = await _pump(tester, spaceStrong: true);
    final voice = _container(tester).read(voiceControllerProvider.notifier);
    await voice.restoreNoiseSuppression();
    expect(session.lastStrongNoiseSuppression, isTrue);

    voice.setNoiseSuppression(NoiseSuppressionChoice.standard);
    expect(session.lastStrongNoiseSuppression, isFalse);
  });

  group('the inactive note', () {
    const note = 'Strong is off for this mic. It needs a 48 kHz input.';

    Future<FakeSession> join(
      WidgetTester tester, {
      NoiseSuppressionChoice choice = NoiseSuppressionChoice.strong,
      bool spaceStrong = false,
      bool muted = false,
      bool joined = true,
    }) async {
      final session = await _pump(tester, spaceStrong: spaceStrong);
      _container(tester).read(noiseSuppressionProvider.notifier).state = choice;
      final controller = _container(
        tester,
      ).read(voiceControllerProvider.notifier);
      if (joined) await controller.join('channel-1');
      if (muted) await controller.toggleMicrophone();
      await tester.pumpAndSettle();
      return session;
    }

    // Clears the heartbeat timer a connected call keeps running.
    Future<void> hangUp(WidgetTester tester) =>
        _container(tester).read(voiceControllerProvider.notifier).leave();

    Future<void> poll(
      WidgetTester tester,
      FakeSession session,
      int count, {
      required bool active,
    }) async {
      for (var i = 0; i < count; i++) {
        session.inputGateController.add(
          InputGateReading(levelDb: -40, voice: false, strongActive: active),
        );
      }
      await tester.pumpAndSettle();
    }

    testWidgets('shows after sustained inactive readings, hides once active', (
      tester,
    ) async {
      final session = await join(tester);
      await poll(tester, session, kStrongInactivePolls - 1, active: false);
      expect(find.text(note), findsNothing);
      await poll(tester, session, 1, active: false);
      expect(find.text(note), findsOneWidget);

      await poll(tester, session, kStrongActivePolls - 1, active: true);
      expect(find.text(note), findsOneWidget);
      await poll(tester, session, 1, active: true);
      expect(find.text(note), findsNothing);
      await hangUp(tester);
    });

    testWidgets('Space default that resolves to Strong counts', (tester) async {
      final session = await join(
        tester,
        choice: NoiseSuppressionChoice.spaceDefault,
        spaceStrong: true,
      );
      await poll(tester, session, kStrongInactivePolls, active: false);
      expect(find.text(note), findsOneWidget);
      await hangUp(tester);
    });

    testWidgets('never shows on Standard', (tester) async {
      final session = await join(
        tester,
        choice: NoiseSuppressionChoice.standard,
      );
      await poll(tester, session, kStrongInactivePolls, active: false);
      expect(find.text(note), findsNothing);
      await hangUp(tester);
    });

    testWidgets('never shows while muted', (tester) async {
      final session = await join(tester, muted: true);
      await poll(tester, session, kStrongInactivePolls, active: false);
      expect(find.text(note), findsNothing);
      await hangUp(tester);
    });

    testWidgets('never shows out of a call', (tester) async {
      final session = await join(tester, joined: false);
      await poll(tester, session, kStrongInactivePolls, active: false);
      expect(find.text(note), findsNothing);
      await hangUp(tester);
    });
  });
}
