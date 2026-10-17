// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The abuse defence `docs/decisions/0027-module-scene-sound.md` describes:
/// [ModuleCommandOutput] never plays a `notes` op on first paint, and the
/// [moduleSoundSettingsProvider] switch is what actually gates whether the
/// viewer's own action is allowed to make sound at all.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/audio/scene_sound_player.dart';
import 'package:slimm_app/src/features/modules/providers/module_sound_settings.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/modules/widgets/module_command_output.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _FakeModuleSoundPlayer implements ModuleSoundPlayer {
  final played = <List<SceneNote>>[];

  @override
  Future<void> playNotes(List<SceneNote> notes) async => played.add(notes);

  @override
  Future<void> dispose() async {}
}

String _scene(String state) => jsonEncode({
  r'$slim': 'scene/1',
  'width': 10,
  'height': 10,
  'ops': [
    {
      'op': 'notes',
      'notes': [
        {'f': 440.0, 't': 0.0, 'd': 0.1},
      ],
    },
  ],
  'state': state,
  'controls': ['step'],
  'live': true,
});

Future<_FakeModuleSoundPlayer> _pump(
  WidgetTester tester, {
  required bool soundEnabled,
}) async {
  SharedPreferences.setMockInitialValues({moduleSoundEnabledKey: soundEnabled});
  final player = _FakeModuleSoundPlayer();
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      moduleSoundPlayerProvider.overrideWithValue(player),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.method == 'POST' &&
                request.url.path.contains('/modules/mod1/commands/step')) {
              return http.Response(
                jsonEncode({'ok': true, 'output': _scene('s1')}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('', 404);
          }),
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  // Mirrors HomeShell's own forced watch: without it, ModuleCommandOutput's lazy read inside onNotes would race the tap below against this controller's own load.
  container.read(moduleSoundSettingsProvider);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ModuleCommandOutput(
            result: api.RunModuleCommandResult(ok: true, output: _scene('s0')),
            moduleId: 'mod1',
            command: 'step',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return player;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'never plays on first paint, even with a notes op already present',
    (tester) async {
      final player = await _pump(tester, soundEnabled: true);
      expect(player.played, isEmpty);
    },
  );

  testWidgets('plays for the viewer\'s own action when the setting is on', (
    tester,
  ) async {
    final player = await _pump(tester, soundEnabled: true);
    await tester.tap(find.byIcon(AppIcons.forward));
    await tester.pumpAndSettle();
    expect(player.played, hasLength(1));
    expect(player.played.single.single.frequency, 440.0);
  });

  testWidgets(
    'never plays when the setting is off, even for the viewer\'s own action',
    (tester) async {
      final player = await _pump(tester, soundEnabled: false);
      await tester.tap(find.byIcon(AppIcons.forward));
      await tester.pumpAndSettle();
      expect(player.played, isEmpty);
    },
  );
}
