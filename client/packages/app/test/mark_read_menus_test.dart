// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Mark as read" on a channel or DM row, and "Mark all as read" on a category
/// header and in the space menu: offered only while there is a badge to clear,
/// reached by right-click on a wide window and by long-press on a compact one.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/providers/dms.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/category_header_menu.dart';
import 'package:slimm_app/src/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/widgets/dm_row.dart';
import 'package:slimm_app/src/widgets/mark_read_action.dart';
import 'package:slimm_app/src/widgets/space_menu_button.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Channel _channel(
  String id, {
  String? categoryId,
  int cursor = 0,
  int lastReadSeq = 0,
  bool manuallyUnread = false,
  String kind = 'text',
}) => Channel(
  id: id,
  name: id,
  kind: kind,
  createdAt: 0,
  position: 0,
  categoryId: categoryId,
  cursor: cursor,
  lastReadSeq: lastReadSeq,
  mentionedSeq: 0,
  manuallyUnread: manuallyUnread,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmParticipantId: kind == dmChannelKind ? 'peer' : null,
);

class _FixedOverrides extends ChannelNotificationOverridesController {
  _FixedOverrides(
    super.ref,
    Map<String, api.NotificationPreference> byChannel,
  ) {
    state = ChannelNotificationOverridesState(
      byChannel: byChannel,
      settled: true,
    );
  }
}

class _Harness {
  _Harness({
    int permissions = 0,
    Map<String, api.NotificationPreference> muted = const {},
  }) {
    SharedPreferences.setMockInitialValues({});
    final db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        // Without this the roster watchers pull in the real SyncController and its retry timer.
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
        channelNotificationOverridesProvider.overrideWith(
          (ref) => _FixedOverrides(ref, muted),
        ),
        meProvider.overrideWith(
          (ref) async => api.Me(
            id: 'self',
            username: 'self',
            displayName: 'Self',
            createdAt: 0,
            permissions: permissions,
          ),
        ),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              requests.add(request);
              if (request.url.path == '/read-states/read') {
                final ids =
                    (jsonDecode(request.body)['channel_ids'] as List<dynamic>);
                return http.Response(
                  jsonEncode([
                    for (final id in ids)
                      {
                        'channel_id': id,
                        'last_read_seq': 9,
                        'unread': 0,
                        'manually_unread': false,
                      },
                  ]),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response('{}', 404);
            }),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
  }

  late final MessageStore store;
  late final ProviderContainer container;
  final requests = <http.Request>[];

  List<String> get markedIds {
    final posts = requests.where((r) => r.url.path == '/read-states/read');
    return [
      for (final r in posts)
        ...(jsonDecode(r.body)['channel_ids'] as List<dynamic>).cast<String>(),
    ];
  }

  Future<void> pump(WidgetTester tester, Widget body, {Size? size}) async {
    if (size != null) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
    }
    addTearDown(container.dispose);
    addTearDown(store.db.close);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(body: SingleChildScrollView(child: body)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

const _phone = Size(390, 844);

Future<void> _rightClick(WidgetTester tester, Finder target) async {
  await tester.tapAt(
    tester.getCenter(target),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

Future<void> _tapAndSettleRequests(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Widget _sections(List<Channel> channels, {bool canManage = false}) =>
    ChannelCategorySections(
      channels: channels,
      categories: const [
        ChannelCategoryRow(id: 'cat', name: 'Projects', position: 0),
      ],
      selectedId: null,
      canManage: canManage,
      onReorder: (_) {},
    );

void main() {
  group('channel row', () {
    testWidgets('an unread channel offers Mark as read in place of Mark as '
        'unread and clears without opening', (tester) async {
      final h = _Harness();
      await h.pump(tester, _sections([_channel('general', cursor: 4)]));

      await _rightClick(tester, find.text('general'));
      expect(find.text('Mark as read'), findsOneWidget);
      expect(find.text('Mark as unread'), findsNothing);

      await _tapAndSettleRequests(tester, find.text('Mark as read'));
      expect(h.markedIds, ['general']);
    });

    testWidgets('a read channel offers Mark as unread only', (tester) async {
      final h = _Harness();
      await h.pump(
        tester,
        _sections([_channel('general', cursor: 4, lastReadSeq: 4)]),
      );

      await _rightClick(tester, find.text('general'));
      expect(find.text('Mark as unread'), findsOneWidget);
      expect(find.text('Mark as read'), findsNothing);
    });

    testWidgets('a hand-marked channel offers Mark as read', (tester) async {
      final h = _Harness();
      await h.pump(
        tester,
        _sections([
          _channel('general', cursor: 4, lastReadSeq: 4, manuallyUnread: true),
        ]),
      );

      await _rightClick(tester, find.text('general'));
      expect(find.text('Mark as read'), findsOneWidget);
    });

    testWidgets('a muted channel with unread messages shows no badge and no '
        'Mark as read', (tester) async {
      final h = _Harness(
        muted: {'general': api.NotificationPreference.nothing},
      );
      await h.pump(tester, _sections([_channel('general', cursor: 4)]));

      await _rightClick(tester, find.text('general'));
      expect(find.text('Mark as read'), findsNothing);
      expect(find.text('Mark as unread'), findsOneWidget);
    });

    testWidgets('on a compact window the long-press sheet offers it too', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(
        tester,
        _sections([_channel('general', cursor: 4)]),
        size: _phone,
      );

      await tester.longPress(find.text('general'));
      await tester.pumpAndSettle();
      expect(find.text('Mark as read'), findsOneWidget);

      await _tapAndSettleRequests(tester, find.text('Mark as read'));
      expect(h.markedIds, ['general']);
    });
  });

  group('DM row', () {
    testWidgets('an unread DM offers Mark as read', (tester) async {
      final h = _Harness();
      await h.pump(
        tester,
        DmRow(
          channel: _channel('dm1', kind: dmChannelKind, cursor: 2),
          selected: false,
        ),
      );

      await _rightClick(tester, find.text('dm1'));
      expect(find.text('Mark as read'), findsOneWidget);
      expect(find.text('Mark as unread'), findsNothing);
    });
  });

  group('category header', () {
    final channels = [
      _channel('a', categoryId: 'cat', cursor: 3),
      _channel('b', categoryId: 'cat', cursor: 2, lastReadSeq: 2),
      _channel('c', categoryId: 'cat', cursor: 5),
      _channel('elsewhere', cursor: 7),
    ];

    testWidgets('a member who cannot manage categories still gets Mark all '
        'as read, over only the unread ones in it', (tester) async {
      final h = _Harness(muted: {'c': api.NotificationPreference.nothing});
      await h.pump(tester, _sections(channels));

      await _rightClick(tester, find.text('Projects'));
      expect(find.text('Rename category...'), findsNothing);
      await _tapAndSettleRequests(tester, find.text('Mark all as read'));

      expect(
        h.requests.where((r) => r.url.path == '/read-states/read'),
        hasLength(1),
      );
      expect(h.markedIds, ['a']);
    });

    testWidgets('a manager gets it above the manage entries', (tester) async {
      final h = _Harness(permissions: Perm.manageChannels);
      await h.pump(tester, _sections(channels, canManage: true));

      await _rightClick(tester, find.text('Projects'));
      expect(find.text('Mark all as read'), findsOneWidget);
      expect(find.text('Rename category...'), findsOneWidget);
    });

    testWidgets('with nothing unread a member has no menu on the header', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(
        tester,
        _sections([
          _channel('b', categoryId: 'cat', cursor: 2, lastReadSeq: 2),
        ]),
      );

      expect(find.byType(CategoryHeaderMenu), findsOneWidget);
      await _rightClick(tester, find.text('Projects'));
      expect(find.text('Mark all as read'), findsNothing);
    });
  });

  group('space menu', () {
    // The entry reads the channels when chosen, so they live in the store, not in an override.
    Future<void> openSpaceMenu(
      WidgetTester tester,
      _Harness h,
      List<Channel> seeded,
    ) async {
      await tester.runAsync(() => _seed(h.store, seeded));
      await h.pump(
        tester,
        const Align(alignment: Alignment.topRight, child: SpaceMenuButton()),
      );
      await tester.tap(find.bySemanticsLabel('Space menu'));
      await tester.pumpAndSettle();
    }

    testWidgets('a plain member marks every unread, audible channel in one '
        'request', (tester) async {
      final h = _Harness(muted: {'quiet': api.NotificationPreference.nothing});
      await openSpaceMenu(tester, h, [
        _channel('a', cursor: 3),
        _channel('b', cursor: 2, lastReadSeq: 2),
        _channel('c', categoryId: 'cat', cursor: 6),
        _channel('quiet', cursor: 6),
      ]);
      expect(find.text('Space settings'), findsNothing);
      await _tapAndSettleRequests(tester, find.text('Mark all as read'));

      expect(
        h.requests.where((r) => r.url.path == '/read-states/read'),
        hasLength(1),
      );
      expect(h.markedIds, ['a', 'c']);
    });

    testWidgets('Direct messages are left out', (tester) async {
      final h = _Harness();
      await openSpaceMenu(tester, h, [
        _channel('a', cursor: 3),
        _channel('dm1', kind: dmChannelKind, cursor: 3),
      ]);
      await _tapAndSettleRequests(tester, find.text('Mark all as read'));
      expect(h.markedIds, ['a']);
    });

    testWidgets('with nothing unread choosing it sends nothing', (
      tester,
    ) async {
      final h = _Harness();
      await openSpaceMenu(tester, h, [
        _channel('b', cursor: 2, lastReadSeq: 2),
      ]);
      await _tapAndSettleRequests(tester, find.text('Mark all as read'));
      expect(
        h.requests.where((r) => r.url.path == '/read-states/read'),
        isEmpty,
      );
    });
  });

  test('markChannelsRead moves the local rows to the answer', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    addTearDown(h.store.db.close);
    await _seed(h.store, [_channel('a', cursor: 9, manuallyUnread: true)]);

    await markChannelsRead(h.container, ['a']);

    final row = (await h.store.allChannels()).single;
    expect(row.lastReadSeq, 9);
    expect(row.manuallyUnread, isFalse);
  });
}

Future<void> _seed(MessageStore store, List<Channel> channels) async {
  await store.upsertChannels([
    for (final c in channels)
      api.Channel(id: c.id, name: c.name, kind: c.kind, createdAt: 0),
  ]);
  for (final c in channels) {
    await store.db.customStatement(
      'UPDATE channels SET cursor = ?, last_read_seq = ?, manually_unread = ? '
      'WHERE id = ?',
      [c.cursor, c.lastReadSeq, if (c.manuallyUnread ?? false) 1 else 0, c.id],
    );
  }
}
