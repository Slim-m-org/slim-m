// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The custom emoji feature has to be *wired into the screen*, not merely
/// implemented.
///
/// Every other emoji suite passes with the app unable to render a single one:
/// delete the three lines in `channel_screen.dart` that read
/// `customEmojiIndexProvider` and hand it to `MessageRow` and to
/// `ChannelSearchResults`, and `dart analyze`, `dart format` and all of
/// `flutter test` stay green while every `:shortcode:` in the running app
/// silently degrades to the literal text someone typed.
///
/// That is the same class of hole as `Routes.settings` being registered,
/// built, tested and navigated to by nothing for a whole release, which is
/// what `route_reachability_test.dart` exists to catch. This is the render
/// half of it: pump the real [ChannelScreen] over a deployment that holds one
/// emoji, and require the picture to appear. `message_text_emoji_test.dart`
/// covers the tokenizer; nothing here re-tests it, and a passing tokenizer is
/// exactly what makes this hole invisible.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_search_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_search.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
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

/// A 1x1 transparent PNG. Nothing here asserts on pixels; the bytes only have
/// to decode.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
  'hQGAhKmMIQAAAABJRU5ErkJggg==',
);

const _body = 'shipped :tada:';

api.Message _message(String id, int seq) => api.Message(
  id: id,
  channelId: 'c1',
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: seq,
  content: _body,
  createdAt: seq * 1000,
  editedAt: null,
);

http.Response _json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

/// A deployment holding exactly one emoji, `tada`, and one channel whose
/// search answers with the same message the transcript holds.
ProviderContainer _container(MessageStore store) {
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
            final path = request.url.path;
            if (path == '/emoji') {
              return _json([
                {
                  'id': 'e-tada',
                  'name': 'tada',
                  'uploader_id': null,
                  'created_at': 0,
                },
              ]);
            }
            if (path.endsWith('/image')) {
              return http.Response.bytes(
                _png,
                200,
                headers: {'content-type': 'image/png'},
              );
            }
            if (path == '/channels/c1/messages/search') {
              return _json([
                {
                  'id': 'm1',
                  'channel_id': 'c1',
                  'author_id': 'alice',
                  'author_display_name': 'Alice',
                  'seq': 1,
                  'content': _body,
                  'created_at': 1000,
                  'edited_at': null,
                },
              ]);
            }
            if (path == '/me') {
              return _json({
                'id': 'bob',
                'username': 'bob',
                'display_name': 'Bob',
                'created_at': 0,
                'permissions': 0,
              });
            }
            if (request.method == 'PUT' && path == '/channels/c1/read') {
              return _json({'last_read_seq': 1, 'unread': 0});
            }
            return _json(const []);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The compact layout, so the channel header (and everything it pulls in)
/// never builds: the wiring under test does not go through it.
Future<ProviderContainer> _pumpChannel(WidgetTester tester) async {
  tester.view.physicalSize = const Size(500, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await store.upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await store.applyMessages([_message('m1', 1)]);

  final container = _container(store);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: ChannelScreen(channelId: 'c1')),
      ),
    ),
  );
  // A bounded pump rather than pumpAndSettle, which never settles here: the
  // icon buttons' hover machinery schedules a frame on every empty repaint.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  return container;
}

/// Drift cancels its query streams on dispose behind a zero-duration timer,
/// and the framework's own teardown checks for pending timers before it fires.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets('a shortcode in the open channel renders as its image, so the '
      'transcript is really wired to the deployment emoji index', (
    tester,
  ) async {
    await _pumpChannel(tester);

    expect(
      find.descendant(
        of: find.byType(MessageRow),
        matching: find.byType(CustomEmojiImage),
      ),
      findsOneWidget,
      reason:
          'ChannelScreen must hand customEmojiIndexProvider to MessageRow; '
          'without it every :shortcode: in the app renders as plain text and '
          'no other test notices',
    );
    expect(
      tester.widget<CustomEmojiImage>(find.byType(CustomEmojiImage)).emojiId,
      'e-tada',
    );
    expect(
      find.descendant(
        of: find.byType(CustomEmojiImage),
        matching: find.byType(Image),
      ),
      findsOneWidget,
      reason: 'the image bytes must reach the screen, not just the id',
    );
    expect(
      find.textContaining(':tada:'),
      findsNothing,
      reason:
          'a resolved shortcode is replaced by its picture, not shown '
          'alongside it',
    );

    await _unmount(tester);
  });

  testWidgets('a shortcode in a search hit renders as its image too, since '
      'search results are a second render path with its own wiring', (
    tester,
  ) async {
    final container = await _pumpChannel(tester);

    await container.read(channelSearchProvider('c1').notifier).run('shipped');
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.byType(ChannelSearchResults), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ChannelSearchResults),
        matching: find.byType(CustomEmojiImage),
      ),
      findsOneWidget,
      reason:
          'ChannelScreen must hand the same index to ChannelSearchResults; '
          'the transcript being wired says nothing about this path',
    );

    await _unmount(tester);
  });
}
