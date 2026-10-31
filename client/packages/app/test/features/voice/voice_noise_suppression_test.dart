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
import 'package:slimm_app/src/features/voice/providers/noise_suppression.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
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
  bool strongestSupported = true,
}) async {
  final session = FakeSession(supportsInputGate: true);
  addTearDown(session.dispose);
  await tester.pumpWidget(
    wrap(
      const VoiceSettingsBody(),
      overrides: [
        strongestSupportedProvider.overrideWithValue(strongestSupported),
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
  (w) =>
      w is SettingsSelectRow<NoiseSuppressionChoice> &&
      w.label == 'Noise suppression',
);

NoiseSuppressionChoice _shown(WidgetTester tester) =>
    tester.widget<SettingsSelectRow<NoiseSuppressionChoice>>(_picker()).value!;

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.tap(_picker());
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

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

  test('Strongest runs rnnoise too, and only where the host can run it', () {
    for (final spaceStrong in [true, false]) {
      expect(
        NoiseSuppressionChoice.strongest.isStrong(spaceStrong: spaceStrong),
        isTrue,
      );
    }
    expect(
      NoiseSuppressionChoice.strongest.isStrongest(supported: true),
      isTrue,
    );
    expect(
      NoiseSuppressionChoice.strongest.isStrongest(supported: false),
      isFalse,
      reason: 'a saved Strongest on an unsupported host is Strong',
    );
    expect(NoiseSuppressionChoice.strong.isStrongest(supported: true), isFalse);
    expect(
      NoiseSuppressionChoice.parse('strongest'),
      NoiseSuppressionChoice.strongest,
    );
    expect(
      NoiseSuppressionChoice.offered(supported: true),
      contains(NoiseSuppressionChoice.strongest),
    );
    expect(
      NoiseSuppressionChoice.offered(supported: false),
      isNot(contains(NoiseSuppressionChoice.strongest)),
    );
  });

  testWidgets('the picker offers Strongest on a supported host', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(_picker());
    await tester.pumpAndSettle();
    expect(find.text('Strongest'), findsOneWidget);
  });

  testWidgets('the picker hides Strongest on an unsupported host', (
    tester,
  ) async {
    await _pump(tester, strongestSupported: false);
    await tester.tap(_picker());
    await tester.pumpAndSettle();
    expect(find.text('Strong'), findsOneWidget);
    expect(find.text('Strongest'), findsNothing);
  });

  testWidgets(
    'picking Strongest says it uses more CPU and reaches the session',
    (tester) async {
      final session = await _pump(tester);
      await _choose(tester, 'Strongest');

      expect(
        find.text('Strongest removes the most noise and uses more CPU.'),
        findsOneWidget,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('slimm.voice.noise_suppression'), 'strongest');
      expect(session.lastStrongNoiseSuppression, isTrue);
      expect(session.lastStrongestNoiseSuppression, isTrue);
    },
  );

  testWidgets('a saved Strongest on an unsupported host runs as Strong', (
    tester,
  ) async {
    final session = await _pump(tester, strongestSupported: false);
    _container(tester)
        .read(voiceControllerProvider.notifier)
        .input
        .setNoiseSuppression(NoiseSuppressionChoice.strongest);
    expect(session.lastStrongNoiseSuppression, isTrue);
    expect(session.lastStrongestNoiseSuppression, isFalse);
  });

  testWidgets('it starts on Space default and says what the Space uses', (
    tester,
  ) async {
    await _pump(tester, spaceStrong: true);
    expect(_picker(), findsOneWidget);
    expect(_shown(tester), NoiseSuppressionChoice.spaceDefault);
    expect(find.text('This Space uses Strong.'), findsOneWidget);
  });

  testWidgets('picking Strong persists it and reaches the session', (
    tester,
  ) async {
    final session = await _pump(tester);
    await _choose(tester, 'Strong');

    expect(_shown(tester), NoiseSuppressionChoice.strong);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('slimm.voice.noise_suppression'), 'strong');
    expect(session.lastStrongNoiseSuppression, isTrue);
  });

  testWidgets('on Space default the session follows the Space once it is '
      'read, and Standard overrides it', (tester) async {
    final session = await _pump(tester, spaceStrong: true);
    final voice = _container(tester).read(voiceControllerProvider.notifier);
    await voice.input.restoreNoiseSuppression();
    expect(session.lastStrongNoiseSuppression, isTrue);

    voice.input.setNoiseSuppression(NoiseSuppressionChoice.standard);
    expect(session.lastStrongNoiseSuppression, isFalse);
  });

  group('the inactive note', () {
    const note = "Strong isn't running on this mic.";

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
      bool strongestActive = false,
    }) async {
      for (var i = 0; i < count; i++) {
        session.inputGateController.add(
          InputGateReading(
            levelDb: -40,
            voice: false,
            strongActive: active,
            strongestActive: strongestActive,
          ),
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

    testWidgets('Strongest is judged on DeepFilterNet and named in the note', (
      tester,
    ) async {
      final session = await join(
        tester,
        choice: NoiseSuppressionChoice.strongest,
      );
      await poll(tester, session, kStrongInactivePolls, active: true);
      expect(find.text("Strongest isn't running on this mic."), findsOneWidget);
      expect(find.text(note), findsNothing);

      await poll(
        tester,
        session,
        kStrongActivePolls,
        active: true,
        strongestActive: true,
      );
      expect(find.text("Strongest isn't running on this mic."), findsNothing);
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
