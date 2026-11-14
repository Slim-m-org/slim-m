// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space's call transcript settings (decision 0113): the mode and the
/// retention window on the Voice pane, each patching only its own field, and
/// the mode disabled with the reason when the server has no listener.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/space_voice_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_toggle_row.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<List<Map<String, dynamic>>> _open(
  WidgetTester tester, {
  bool available = true,
  String mode = 'off',
  int? retentionDays = 30,
  bool voiceAvailable = true,
  Size size = const Size(1000, 1400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final patches = <Map<String, dynamic>>[];
  final client = MockClient((request) async {
    switch (request.url.path) {
      case '/space/settings':
        if (request.method == 'PATCH') {
          patches.add(jsonDecode(request.body) as Map<String, dynamic>);
        }
        return _json({
          'join_policy': 'invite',
          'call_transcription': mode,
          'call_transcript_retention_days': retentionDays,
          'call_transcription_available': available,
          'transcribe_voice_messages': false,
          'transcribe_voice_messages_available': voiceAvailable,
        });
      case '/space/screen-share':
        return _json({'max_height': 2160});
    }
    return _json({'enabled': false});
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: client,
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: SpaceVoiceScreen()),
      ),
    ),
  );
  await _frames(tester);
  return patches;
}

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await _frames(tester);
}

final _voiceSwitch = find.byWidgetPredicate(
  (w) => w is SettingsToggleRow && w.label == 'Transcribe voice messages',
);

void main() {
  for (final (name, size) in [
    ('desktop', const Size(1000, 1400)),
    ('phone', const Size(390, 1600)),
  ]) {
    group(name, () {
      testWidgets('the three modes show and Always patches only the mode', (
        tester,
      ) async {
        final patches = await _open(tester, size: size);

        expect(find.text('Call transcripts'), findsOneWidget);
        for (final label in ['Off', 'When someone asks', 'Always']) {
          expect(find.text(label), findsOneWidget);
        }

        await _tap(tester, 'Always');
        expect(patches, [
          {'call_transcription': 'always'},
        ]);
      });

      testWidgets('retention patches days, and Forever patches null', (
        tester,
      ) async {
        final patches = await _open(tester, size: size, retentionDays: 7);

        await _tap(tester, '90 days');
        await _tap(tester, 'Forever');

        expect(patches, [
          {'call_transcript_retention_days': 90},
          {'call_transcript_retention_days': null},
        ]);
      });
    });
  }

  testWidgets('shortening retention asks first, and Cancel changes nothing', (
    tester,
  ) async {
    final patches = await _open(tester, retentionDays: 90);

    await _tap(tester, '7 days');
    expect(find.text('Delete transcripts older than 7 days?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _frames(tester);

    expect(patches, isEmpty);
  });

  testWidgets('without a listener the modes are disabled with the reason', (
    tester,
  ) async {
    final patches = await _open(tester, available: false);

    expect(
      find.text('Needs the call listener, which this server is not running.'),
      findsOneWidget,
    );
    await _tap(tester, 'Always');
    expect(patches, isEmpty);
  });

  testWidgets('the voice message switch patches only its own field', (
    tester,
  ) async {
    final patches = await _open(tester);

    expect(find.text('Voice messages'), findsOneWidget);
    tester.widget<SettingsToggleRow>(_voiceSwitch).onChanged!(true);
    await _frames(tester);
    expect(patches, [
      {'transcribe_voice_messages': true},
    ]);
  });

  testWidgets('without a listener the voice message switch says why', (
    tester,
  ) async {
    final patches = await _open(tester, voiceAvailable: false);

    expect(
      find.text('Needs the call listener, which this server is not running.'),
      findsOneWidget,
    );
    expect(tester.widget<SettingsToggleRow>(_voiceSwitch).onChanged, isNull);
    expect(patches, isEmpty);
  });
}
