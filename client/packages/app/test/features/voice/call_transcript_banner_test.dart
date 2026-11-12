// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The in-call banner when the server is the consumer (decision 0113): a
/// banner with Stop when someone asked for it, none when the Space always does.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/widgets/call_audio_banner.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 4102444800000,
);

Map<String, dynamic> _session({required bool always}) => {
  'module_id': 'server',
  'module_name': 'Transcript',
  'purpose': 'Writes down what is said.',
  'keeps': 'The text, for 30 days.',
  'status': 'on',
  'asked_by': always ? null : 'asker',
  'mode': always ? 'always' : 'on_request',
  'included': ['asker', 'me'],
  'pending': <String>[],
  'expires_at_ms': DateTime.now().millisecondsSinceEpoch + 60000,
  'full': false,
};

Future<void> _pump(
  WidgetTester tester, {
  required bool always,
  double width = 1000,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final container = ProviderContainer(
    overrides: [
      liveEventsProvider.overrideWithValue(events.stream),
      apiProvider.overrideWith((ref) {
        final client = testApi((request) async {
          return http.Response(
            jsonEncode({
              'session': _session(always: always),
              'startable': <dynamic>[],
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
  container.read(sessionProvider).set(_tokens);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: CallAudioBanner(channelId: 'c1')),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  for (final width in [1000.0, 390.0]) {
    group('at $width wide', () {
      testWidgets('on request says so and keeps Stop', (tester) async {
        await _pump(tester, always: false, width: width);

        expect(find.text('This call is being transcribed'), findsOneWidget);
        expect(find.byKey(CallAudioBanner.stopKey), findsOneWidget);
      });

      testWidgets('always leaves it to the call header mark', (tester) async {
        await _pump(tester, always: true, width: width);

        expect(find.text('This call is being transcribed'), findsNothing);
        expect(find.byKey(CallAudioBanner.stopKey), findsNothing);
      });
    });
  }
}
