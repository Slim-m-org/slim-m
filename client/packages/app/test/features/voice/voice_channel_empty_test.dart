// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel with no call to show: a centred empty state with the
/// channel's name, who can join, and Join beside Join muted.
library;

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
        (ref, channelId) async => const api.VoiceCallHistory(
          retentionDays: 0,
          canvasObjectCount: 0,
          calls: [],
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
