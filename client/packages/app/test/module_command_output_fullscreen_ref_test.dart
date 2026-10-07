// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The full-screen board runs through closures that must not hold the inline
/// widget's `ref`: the route outlives it, and a press after it is gone still
/// has to reach the server.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/module_command_output.dart';
import 'package:slimm_app/src/widgets/module_scene_fullscreen.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/module_scene_fixtures.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  testWidgets('full screen board keeps working after its inline host goes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var requests = 0;
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              requests++;
              return http.Response(
                jsonEncode({'ok': true, 'output': sceneJson(requests)}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
    );
    addTearDown(container.dispose);
    final showInline = ValueNotifier(true);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: showInline,
              builder: (_, show, __) => show
                  ? SingleChildScrollView(
                      child: ModuleCommandOutput(
                        result: api.RunModuleCommandResult(
                          ok: true,
                          output: sceneJson(0),
                        ),
                        moduleId: 'mod1',
                        command: 'step',
                        messageId: 'm1',
                        blockIndex: 0,
                      ),
                    )
                  : const Text('run removed'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Open full screen'));
    await tester.pumpAndSettle();
    expect(find.byType(ModuleSceneFullscreen), findsOneWidget);

    showInline.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(ModuleSceneFullscreen), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Step forward').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(requests, 1, reason: 'the press should still reach the server');
  });
}
