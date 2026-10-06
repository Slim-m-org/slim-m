// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A second Enter while a module slash command is still running.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/slash_command.dart';

import 'composer_harness.dart';

void main() {
  testWidgets('a second Enter while a /command is in flight runs it once', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final sends = Sends();
    final gate = Completer<void>();
    var runs = 0;
    api.SlimmApi apiBuilder(Ref ref) => api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: ref.watch(sessionProvider),
      httpClient: MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.path == '/modules/dice/commands/roll') {
          runs += 1;
          await gate.future;
          return http.Response(
            jsonEncode({'ok': true, 'output': 'rolled 7'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{}',
          404,
          headers: {'content-type': 'text/plain'},
        );
      }),
    );
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: apiBuilder,
        extraOverrides: [
          slashCommandProvider.overrideWith(
            (ref) async => const [
              api.SlashCommand(
                moduleId: 'dice',
                command: 'roll',
                name: 'roll',
                description: 'Roll',
              ),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '/roll 20');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(runs, 1, reason: 'module command POSTs');
    expect(sends.count, 1, reason: 'messages posted');
  });
}
