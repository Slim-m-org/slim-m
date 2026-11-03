// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet that asks everyone to turn a module on stays tidy at phone
/// width: the explanation fits one line and the button clears the text.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/widgets/call_audio_start.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/fake_sync.dart';
import '../../ui_snapshot_support.dart' show loadRealFonts;

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 4102444800000,
);

void main() {
  setUpAll(loadRealFonts);
  testWidgets('the explanation is one line and the button clears the text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        apiProvider.overrideWith((ref) {
          final client = testApi((request) async {
            return http.Response(
              jsonEncode({
                'session': null,
                'startable': [
                  {
                    'module_id': 'transcript',
                    'module_name': 'Transcript',
                    'purpose': 'Writes down what is said.',
                    'keeps': 'The text, for 30 days.',
                  },
                ],
              }),
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
          home: const Scaffold(body: CallAudioStartControl(channelId: 'c1')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(CallAudioStartControl.buttonKey));
    await tester.pump(const Duration(milliseconds: 400));

    final caption = tester.getSize(
      find.text('Everyone is asked first. It starts only if all say yes.'),
    );
    expect(caption.height, lessThan(20), reason: 'no orphaned second line');
    final keeps = tester.getRect(find.text('It keeps: The text, for 30 days.'));
    final ask = tester.getRect(
      find.byKey(const ValueKey('call-audio-ask-transcript')),
    );
    expect(ask.top - keeps.bottom, greaterThanOrEqualTo(AppSpacing.s12));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });
}
