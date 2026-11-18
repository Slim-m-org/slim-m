// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel with no call to show: a centred empty state with the
/// channel's name, who can join, and Join muted first with Join beside it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/voice/providers/voice_call_history.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/voice_channel_idle.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/call_header_fixture.dart';

Future<void> _pump(
  WidgetTester tester, {
  required VoidCallback onJoin,
  required Channel channel,
  VoidCallback? onJoinWithMic,
  VoidCallback? onRetry,
  String? error,
  Future<api.VoiceCallHistory>? history,
  double width = 1100,
  double? paneWidth,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore()),
      ...callPeople(const [], const {}),
      channelByIdProvider.overrideWith((ref, id) => Stream.value(channel)),
      voiceCallHistoryProvider.overrideWith(
        (ref, channelId) =>
            history ??
            Future.value(
              const api.VoiceCallHistory(
                retentionDays: 0,
                canvasObjectCount: 0,
                calls: [],
              ),
            ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: paneWidth,
              child: VoiceChannelIdle(
                channelId: 'voice-1',
                onJoin: onJoin,
                onJoinWithMic: onJoinWithMic,
                onRetry: onRetry,
                errorMessage: error,
                onOpenCanvas: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Channel lounge({bool restricted = false, bool joinMuted = false}) => Channel(
  id: 'voice-1',
  name: 'lounge',
  kind: 'voice',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: joinMuted,
  isPersonalSpace: false,
  restricted: restricted,
);

AppButtonVariant _variantOf(WidgetTester tester, String label) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, label)).variant;

void main() {
  for (final width in [390.0, 1100.0]) {
    testWidgets('at $width an empty channel is a centred empty state', (
      tester,
    ) async {
      var muted = 0;
      var withMic = 0;
      await _pump(
        tester,
        onJoin: () => muted++,
        onJoinWithMic: () => withMic++,
        channel: lounge(),
        width: width,
        paneWidth: width,
      );
      expect(find.text('lounge'), findsOneWidget);
      expect(find.text('Anyone in this space can join'), findsOneWidget);
      final name = tester.getCenter(find.text('lounge'));
      expect(name.dx, closeTo(width / 2, 1));
      expect(name.dy, closeTo(1100 / 2, 160), reason: 'vertically centred');
      await tester.tap(find.text('Join'));
      await tester.tap(find.text('Join muted'));
      expect((withMic, muted), (1, 1));
    });
  }

  testWidgets('Join muted is the primary action, Join the secondary one', (
    tester,
  ) async {
    await _pump(tester, onJoin: () {}, onJoinWithMic: () {}, channel: lounge());
    expect(_variantOf(tester, 'Join muted'), AppButtonVariant.primary);
    expect(_variantOf(tester, 'Join'), AppButtonVariant.secondary);
    final muted = tester.getCenter(find.text('Join muted'));
    final plain = tester.getCenter(find.text('Join'));
    expect(muted.dx, lessThan(plain.dx), reason: 'the default reads first');
  });

  testWidgets('Join is there while the call history is still loading', (
    tester,
  ) async {
    var muted = 0;
    await _pump(
      tester,
      onJoin: () => muted++,
      onJoinWithMic: () {},
      channel: lounge(),
      history: Completer<api.VoiceCallHistory>().future,
    );
    expect(find.text('lounge'), findsOneWidget);
    await tester.tap(find.text('Join muted'));
    expect(muted, 1);
  });

  testWidgets('Try again repeats the join that failed', (tester) async {
    var muted = 0;
    var retried = 0;
    await _pump(
      tester,
      onJoin: () => muted++,
      onJoinWithMic: () {},
      onRetry: () => retried++,
      error: 'Could not join the call.',
      channel: lounge(),
    );
    expect(find.text('Could not join the call.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect((retried, muted), (1, 0));
  });

  testWidgets('a private channel says who can join', (tester) async {
    await _pump(
      tester,
      onJoin: () {},
      onJoinWithMic: () {},
      channel: lounge(restricted: true),
    );
    expect(
      find.text('Private: only people with access can join'),
      findsOneWidget,
    );
  });

  testWidgets('a channel that joins muted offers only Join muted', (
    tester,
  ) async {
    await _pump(
      tester,
      onJoin: () {},
      onJoinWithMic: () {},
      channel: lounge(joinMuted: true),
    );
    expect(find.text('Join muted'), findsOneWidget);
    expect(find.text('Join'), findsNothing);
  });
}
