// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call header's transcript mark (decision 0113): an icon beside the
/// timer while the server transcribes the call, its words on hover.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/features/voice/widgets/call_header_facts.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _markKey = Key('call-transcribed-mark');

Map<String, dynamic> _session({required String moduleId}) => {
  'module_id': moduleId,
  'module_name': 'Transcript',
  'purpose': 'Writes down what is said.',
  'keeps': 'The text, for 30 days.',
  'status': 'on',
  'asked_by': null,
  'mode': 'always',
  'included': ['me'],
  'pending': <String>[],
  'expires_at_ms': DateTime.now().millisecondsSinceEpoch + 60000,
  'full': false,
};

http.Client _api(Map<String, dynamic>? session) {
  final voice = voiceApi();
  return MockClient((request) async {
    if (request.url.path.endsWith('/voice/call-audio')) {
      return http.Response(
        jsonEncode({'session': session, 'startable': <dynamic>[]}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return voice.send(request).then(http.Response.fromStream);
  });
}

Future<void> _pumpLive(
  WidgetTester tester,
  VoiceHarness harness,
  http.Client client,
) async {
  final session = FakeSession();
  final controller = harness.controllerWith(session, client);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Center(child: CallHeaderLine(channelId: 'channel-1')),
        ),
      ),
    ),
  );
  await controller.join('channel-1');
  session.emitState(VoiceSessionState.connected);
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('a transcribed call shows the mark, and hover says why', (
    tester,
  ) async {
    final harness = VoiceHarness();
    try {
      await _pumpLive(tester, harness, _api(_session(moduleId: 'server')));

      final mark = find.byKey(_markKey);
      expect(mark, findsOneWidget);
      expect(find.text('This call is being transcribed'), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(mark));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('This call is being transcribed'), findsOneWidget);
    } finally {
      harness.dispose();
    }
  });

  testWidgets('a module hearing the call is not a transcript mark', (
    tester,
  ) async {
    final harness = VoiceHarness();
    try {
      await _pumpLive(tester, harness, _api(_session(moduleId: 'notes')));

      expect(find.byKey(_markKey), findsNothing);
    } finally {
      harness.dispose();
    }
  });

  testWidgets('no session, no mark', (tester) async {
    final harness = VoiceHarness();
    try {
      await _pumpLive(tester, harness, _api(null));

      expect(find.byKey(_markKey), findsNothing);
    } finally {
      harness.dispose();
    }
  });
}
