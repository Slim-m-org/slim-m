// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Space settings > Voice: the voice-commands switch waits for call
/// transcripts, and a phrase the server refuses says why under the field.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/call_transcripts_section.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_toggle_row.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 4102444800000,
);

Future<List<String>> _pump(
  WidgetTester tester, {
  required String mode,
  bool on = false,
}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final patches = <String>[];
  Map<String, Object?> settings() => {
    'name': 'slim-m',
    'join_policy': 'invite',
    'call_transcription': mode,
    'call_transcription_available': true,
    'voice_commands': on,
    'voice_command_phrase': 'hey space',
  };
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWith((ref) {
        final client = testApi((request) async {
          if (request.method == 'PATCH') {
            patches.add(request.body);
            if (request.body.contains('voice_command_phrase')) {
              return http.Response(
                jsonEncode({'error': 'the wake phrase must be 2 to 4 words'}),
                400,
                headers: {'content-type': 'application/json'},
              );
            }
            on = true;
          }
          return http.Response(
            jsonEncode(settings()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }, session: api.SessionStore(tokens: _tokens));
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: CallTranscriptsSection()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return patches;
}

final _switch = find.byWidgetPredicate(
  (w) => w is SettingsToggleRow && w.label == voiceCommandsToggleLabel,
);

void main() {
  testWidgets(
    'the switch is off and says why while calls are not transcribed',
    (tester) async {
      final patches = await _pump(tester, mode: 'off');
      expect(find.text('Needs call transcripts turned on.'), findsOneWidget);
      expect(tester.widget<SettingsToggleRow>(_switch).onChanged, isNull);
      expect(patches, isEmpty);
    },
  );

  testWidgets('turning it on sends the switch, then a bad phrase says why', (
    tester,
  ) async {
    final patches = await _pump(tester, mode: 'always');
    expect(find.text('Say "hey space, mark that" in a call.'), findsOneWidget);
    tester.widget<SettingsToggleRow>(_switch).onChanged!(true);
    await tester.pump();
    await tester.pump();
    expect(patches.single, '{"voice_commands":true}');

    await tester.enterText(find.byKey(voicePhraseFieldKey), 'hey');
    await tester.tap(find.byKey(voicePhraseSaveKey));
    await tester.pump();
    await tester.pump();
    expect(patches.last, '{"voice_command_phrase":"hey"}');
    expect(find.textContaining('2 to 4 words'), findsWidgets);
    expect(
      find.textContaining('Could not save the wake phrase'),
      findsOneWidget,
    );
  });
}
