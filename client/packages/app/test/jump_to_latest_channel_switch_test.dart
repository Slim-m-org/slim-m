// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `ChannelScreen` outlives a channel switch (`ConversationPane` builds it
/// with no key, see `channel_read_marker.dart`'s own doc comment), so its
/// `ScrollController` and the "scrolled away" flag both used to carry across
/// one too: scrolling into history in one channel, then opening a different
/// one, opened that other channel already scrolled away from its own newest
/// message and showed the jump-to-latest arrow, with nothing the reader did
/// in the new channel responsible for either.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/features/messages/widgets/jump_to_latest_button.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Enough rows to overflow a 500x800 viewport in both channels, so each has
/// somewhere real to scroll away to.
const _seedCount = 80;

api.Message _message(String channelId, String id, int seq) => api.Message(
  id: id,
  channelId: channelId,
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: seq,
  content: 'message $seq',
  createdAt: seq * 60000,
  editedAt: null,
);

Map<String, dynamic> _meJson() => {
  'id': 'bob',
  'username': 'bob',
  'display_name': 'Bob',
  'created_at': 0,
  'permissions': 0,
};

http.Response _emptyJsonList() => http.Response(
  jsonEncode([]),
  200,
  headers: {'content-type': 'application/json'},
);

/// A bounded pump count, not `pumpAndSettle`: see the read-marker scroll
/// test's own note on why settling never returns in this environment.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class _Harness {
  _Harness({required this.container});

  final ProviderContainer container;
}

Future<_Harness> _mount(WidgetTester tester, {required String initial}) async {
  tester.view.physicalSize = const Size(500, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);

  await store.upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    const api.Channel(id: 'c2', name: 'random', kind: 'text', createdAt: 0),
  ]);
  await store.applyMessages([
    for (var seq = 1; seq <= _seedCount; seq++) _message('c1', 'c1-m$seq', seq),
  ]);
  await store.applyMessages([
    for (var seq = 1; seq <= _seedCount; seq++) _message('c2', 'c2-m$seq', seq),
  ]);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.method == 'PUT' && request.url.path.endsWith('/read')) {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(
                jsonEncode({'last_read_seq': body['seq'], 'unread': 0}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.method == 'GET' && request.url.path == '/me') {
              return http.Response(
                jsonEncode(_meJson()),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return _emptyJsonList();
          }),
        );
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
        home: Scaffold(body: ChannelScreen(channelId: initial)),
      ),
    ),
  );
  await _flush(tester);

  return _Harness(container: container);
}

/// One pump only, deliberately: the arrow must read as hidden on the very
/// first frame the new channel renders, not merely once [_flush] gives the
/// deferred scroll reset time to run and correct it after the fact.
Future<void> _switchTo(
  WidgetTester tester,
  ProviderContainer container,
  String channelId,
) => tester.pumpWidget(
  UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: ChannelScreen(channelId: channelId)),
    ),
  ),
);

ScrollController _transcriptScroll(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!;

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  const jumpButton = Key('jump-to-latest-tap-target');

  testWidgets('opening a different channel after scrolling into one channel\'s '
      'history opens the new channel at its own newest message, with the '
      'jump arrow absent', (tester) async {
    final h = await _mount(tester, initial: 'c1');

    final scroll = _transcriptScroll(tester);
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    // Away, then a step back toward latest: the arrow only reveals itself on that second, "heading back" sample.
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await _flush(tester);
    scroll.jumpTo(scroll.position.maxScrollExtent / 2);
    await _flush(tester);
    expect(find.byKey(jumpButton), findsOneWidget);

    await _switchTo(tester, h.container, 'c2');

    // The widget's own `visible` field, not a key lookup: `AnimatedSwitcher` keeps the outgoing child mounted mid-fade, so a key would still find it.
    expect(
      tester
          .widget<JumpToLatestButton>(find.byType(JumpToLatestButton))
          .visible,
      isFalse,
      reason:
          'nothing was scrolled in the newly opened channel, so it must '
          'not read as scrolled away from its own newest message on the '
          'very first frame it renders, before anything deferred runs',
    );

    await _flush(tester);
    final newScroll = _transcriptScroll(tester);
    expect(
      newScroll.position.pixels,
      closeTo(newScroll.position.minScrollExtent, 1),
      reason:
          'a freshly opened channel must start at its own newest message, '
          'not wherever the previous channel happened to be scrolled to',
    );

    await _unmount(tester);
  });
}
