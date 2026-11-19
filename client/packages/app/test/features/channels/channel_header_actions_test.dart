// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The header's icon actions, wide and compact: named by a tooltip on a
/// pointer and never by one on touch, and spaced evenly whichever of them a
/// channel shows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_header.dart';
import 'package:slimm_app/src/features/channels/widgets/compact_channel_app_bar.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

Channel _channel(String kind) => Channel(
  id: 'c1',
  name: 'general',
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

Future<void> _pump(WidgetTester tester, Size size, Widget child) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore()),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      mockApiOverride(
        (request) async => http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
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
        home: child,
      ),
    ),
  );
  await pumpFrames(tester);
}

Widget _wide({required bool isVoice}) => Scaffold(
  body: ChannelHeader(
    channelId: 'c1',
    name: 'general',
    isVoice: isVoice,
    onToggleTextChat: isVoice ? () {} : null,
  ),
);

Rect _action(WidgetTester tester, String label) =>
    tester.getRect(find.bySemanticsLabel(label));

void main() {
  testWidgets('every wide header action is named on hover', (tester) async {
    await _pump(tester, const Size(1400, 900), _wide(isVoice: false));

    for (final name in [
      'Pinned messages',
      'Threads',
      'Search messages',
      'Toggle member list',
    ]) {
      expect(find.byTooltip(name), findsOneWidget, reason: name);
    }
  });

  testWidgets('the compact bar shows no tooltip on touch', (tester) async {
    await _pump(
      tester,
      const Size(390, 844),
      ProviderScope(
        overrides: [
          channelByIdProvider.overrideWith(
            (ref, id) => Stream.value(_channel('text')),
          ),
        ],
        child: Scaffold(
          appBar: CompactChannelAppBar(channelId: 'c1', onBack: () {}),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Threads'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message != 'Back to channels',
      ),
      findsNothing,
    );
  });

  testWidgets('a text channel spaces Threads and Search like the rest', (
    tester,
  ) async {
    await _pump(tester, const Size(1400, 900), _wide(isVoice: false));

    final pin = _action(tester, 'Pinned messages');
    final threads = _action(tester, 'Threads');
    final search = _action(tester, 'Search messages');
    expect(threads.left - pin.right, AppSpacing.s4);
    expect(search.left - threads.right, AppSpacing.s4);
  });

  testWidgets('a voice channel spaces Pin and the chat toggle like the rest', (
    tester,
  ) async {
    await _pump(tester, const Size(1400, 900), _wide(isVoice: true));

    final pin = _action(tester, 'Pinned messages');
    final chat = _action(tester, 'Toggle text chat');
    expect(chat.left - pin.right, AppSpacing.s4);
  });
}
