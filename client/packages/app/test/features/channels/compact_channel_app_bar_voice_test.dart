// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel has a text chat, so on a phone its app bar offers Search
/// and Pinned messages once that chat is open, as the wide header always does.
/// Threads stay a text channel's alone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/channels/widgets/compact_channel_app_bar.dart';
import 'package:slimm_app/src/features/voice/screens/voice_text_pane.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

Channel _channel(String kind) => Channel(
  id: 'c1',
  name: 'Lounge',
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

Future<ProviderContainer> _pump(
  WidgetTester tester,
  String kind, {
  bool chatOpen = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore()),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      channelByIdProvider.overrideWith(
        (ref, id) => Stream.value(_channel(kind)),
      ),
      voiceChatPaneVisibleProvider.overrideWith((ref) => chatOpen),
      mockApiOverride((request) async => http.Response('[]', 200)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          appBar: CompactChannelAppBar(channelId: 'c1', onBack: () {}),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

Finder get _search => find.bySemanticsLabel('Search messages');
Finder get _pins => find.bySemanticsLabel(RegExp('Pinned messages'));
Finder get _threads => find.bySemanticsLabel('Threads');
Finder get _chat => find.bySemanticsLabel('Toggle text chat');

void main() {
  testWidgets('a voice channel showing its call offers the chat toggle only', (
    tester,
  ) async {
    await _pump(tester, 'voice');

    expect(_chat, findsOneWidget);
    expect(_search, findsNothing);
    expect(_pins, findsNothing);
    expect(_threads, findsNothing);
  });

  testWidgets('a voice channel showing its chat can search and read pins', (
    tester,
  ) async {
    await _pump(tester, 'voice', chatOpen: true);

    expect(_chat, findsOneWidget);
    expect(_search, findsOneWidget);
    expect(_pins, findsOneWidget);
    expect(_threads, findsNothing);
  });

  testWidgets('a text channel keeps search, pins and threads', (tester) async {
    await _pump(tester, 'text');

    expect(_search, findsOneWidget);
    expect(_pins, findsOneWidget);
    expect(_threads, findsOneWidget);
    expect(_chat, findsNothing);
  });
}
