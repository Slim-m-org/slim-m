// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-time notice before a member's first join while the Space transcribes
/// every call (decision 0113): it asks once, Cancel does not join, Join records
/// the acknowledgement and then joins, and an acknowledged member sees nothing.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/transcription_notice.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_controller_harness.dart';

const _title = 'Calls in this Space are transcribed';

Widget _harness(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
  ),
);

class _Notice {
  _Notice({required this.mode, required this.acknowledged});

  final String mode;
  bool acknowledged;
  final calls = <String>[];

  http.Client client() {
    final base = voiceApi();
    return MockClient((request) async {
      final path = request.url.path;
      if (path == '/voice/transcription-notice') {
        calls.add('GET');
        return http.Response(
          jsonEncode({'mode': mode, 'acknowledged': acknowledged}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/voice/transcription-notice/ack') {
        calls.add('ACK');
        acknowledged = true;
        return http.Response('', 204);
      }
      return base.send(request).then(http.Response.fromStream);
    });
  }
}

void main() {
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    harness.container.dispose();
  }

  Future<VoiceController> open(
    WidgetTester tester,
    _Notice notice, {
    Size size = const Size(1000, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = harness.controllerWith(FakeSession(), notice.client());
    await tester.pumpWidget(_harness(harness.container));
    await settle(tester);
    return controller;
  }

  for (final (name, size) in [
    ('desktop', const Size(1000, 900)),
    ('phone', const Size(390, 800)),
  ]) {
    group(name, () {
      testWidgets('the first join asks, and Join acknowledges then joins', (
        tester,
      ) async {
        final notice = _Notice(mode: 'always', acknowledged: false);
        final controller = await open(tester, notice, size: size);

        expect(find.text(_title), findsOneWidget);
        expect(controller.state.channelId, isNull);
        expect(notice.calls, ['GET']);

        await tester.tap(find.byKey(transcriptionNoticeJoinKey));
        await settle(tester);
        await settle(tester);

        expect(notice.calls, ['GET', 'ACK']);
        expect(controller.state.channelId, 'channel-1');
        await unmount(tester);
      });

      testWidgets('Cancel does not join and acknowledges nothing', (
        tester,
      ) async {
        final notice = _Notice(mode: 'always', acknowledged: false);
        final controller = await open(tester, notice, size: size);

        await tester.tap(find.byKey(transcriptionNoticeCancelKey));
        await settle(tester);

        expect(find.text(_title), findsNothing);
        expect(notice.calls, ['GET']);
        expect(controller.state.channelId, isNull);
        await unmount(tester);
      });
    });
  }

  testWidgets('an acknowledged member joins with no notice', (tester) async {
    final notice = _Notice(mode: 'always', acknowledged: true);
    final controller = await open(tester, notice);
    await settle(tester);

    expect(find.text(_title), findsNothing);
    expect(notice.calls, ['GET']);
    expect(controller.state.channelId, 'channel-1');
    await unmount(tester);
  });

  testWidgets('on request mode never shows the notice', (tester) async {
    final notice = _Notice(mode: 'on_request', acknowledged: false);
    final controller = await open(tester, notice);
    await settle(tester);

    expect(find.text(_title), findsNothing);
    expect(controller.state.channelId, 'channel-1');
    await unmount(tester);
  });
}
