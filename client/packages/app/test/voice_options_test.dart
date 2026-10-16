// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Voice pane rows no other suite operates: the speaker picker, the hold
/// music toggle and style, and the Call stats row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/audio/lounge_tracks.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/voice_settings_screen.dart';
import 'package:slimm_app/src/widgets/settings_select_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_settings_screen_harness.dart';

const _speaker1 = AudioDevice(id: 'spk-1', label: 'Built-in speakers');
const _speaker2 = AudioDevice(id: 'spk-2', label: 'Desk speakers');

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('choosing a speaker persists it and reaches the session', (
    tester,
  ) async {
    final session = FakeSession(
      audioOutputDeviceList: const [_speaker1, _speaker2],
    );
    await tester.pumpWidget(
      wrap(
        const VoiceSettingsBody(),
        overrides: [
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
        ],
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byWidgetPredicate(
      (w) => w is SettingsSelectRow<String> && w.label == 'Speaker',
    );
    await _show(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Desk speakers'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('slimm.voice.audio_output_device_id'), 'spk-2');
    expect(session.lastSelectedAudioOutput?.id, 'spk-2');
  });

  testWidgets('Music while alone persists, and Music style picks a track', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: ungatedSession()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Music style'), findsNothing);

    final toggle = find.byWidgetPredicate(
      (w) =>
          w is AppToggle &&
          w.semanticLabel == 'Play hold music while alone in a call',
    );
    await _show(tester, toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('slimm.voice.hold_music_enabled'), isTrue);

    final style = find.byType(SettingsSelectRow<LoungeTrack>);
    await _show(tester, style);
    await tester.tap(style);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('${LoungeTrack.jazz.style} - ${LoungeTrack.jazz.title}').last,
    );
    await tester.pumpAndSettle();
    expect(prefs.getString('slimm.voice.hold_music_track'), 'jazz');
  });

  testWidgets('the Call stats row opens the call stats route', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(
            body: SingleChildScrollView(child: VoiceSettingsBody()),
          ),
        ),
        GoRoute(
          path: Routes.callStats,
          builder: (_, _) => const Scaffold(body: Text('call stats page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        ...ungatedSession(),
      ],
    )..read(preferencesProvider);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: buildTheme(Brightness.light, AppTokens.light),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _show(tester, find.text('Call stats'));
    await tester.tap(find.text('Call stats'));
    await tester.pumpAndSettle();

    expect(find.text('call stats page'), findsOneWidget);
  });
}
