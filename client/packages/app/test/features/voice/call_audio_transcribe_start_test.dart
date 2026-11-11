// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In a Space that transcribes on request, the call's start control offers the server transcript (decision 0113) and asks for it on the server's route.
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

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 4102444800000,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('a transcribable call offers Transcribe and posts the ask', (
    tester,
  ) async {
    final posted = <String>[];
    final container = ProviderContainer(
      overrides: [
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        apiProvider.overrideWith((ref) {
          final client = testApi((request) async {
            if (request.method == 'POST') posted.add(request.url.path);
            return _json({
              'session': null,
              'startable': const [],
              'transcribable': true,
            });
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
    expect(find.byTooltip('Transcribe this call'), findsOneWidget);

    await tester.tap(find.byKey(CallAudioStartControl.buttonKey));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Transcribe this call?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('call-audio-ask-transcript')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(posted, contains(endsWith('/channels/c1/voice/transcript')));
  });

  test('a status without the flag reads as not transcribable', () {
    expect(api.CallAudioStatus.fromJson(const {}).transcribable, isFalse);
  });
}
