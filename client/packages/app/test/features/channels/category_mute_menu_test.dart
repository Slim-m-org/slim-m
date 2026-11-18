// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A category header's notification entries: Mark all as read and Mute
/// category for every member, grouped above the manage entries.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _projects = ChannelCategoryRow(id: 'cat', name: 'Projects', position: 0);
const _drafts = ChannelCategoryRow(
  id: 'sub',
  name: 'Drafts',
  position: 0,
  parentId: 'cat',
);

Channel _channel(String id, String categoryId, {int cursor = 0}) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: 0,
  categoryId: categoryId,
  cursor: cursor,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

class _Harness {
  _Harness({Set<String> muted = const {}}) : _muted = {...muted};

  final Set<String> _muted;
  final writes = <String>[];
  final markedRead = <String>[];
  late final MessageStore store;
  late final ProviderContainer container;

  Future<void> pump(
    WidgetTester tester,
    List<Channel> channels, {
    bool canManage = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    store = MessageStore(SlimmDatabase(NativeDatabase.memory()));
    await tester.runAsync(
      () => store.replaceCategories(const [
        api.ChannelCategory(
          id: 'cat',
          name: 'Projects',
          position: 0,
          createdAt: 0,
        ),
        api.ChannelCategory(
          id: 'sub',
          name: 'Drafts',
          position: 0,
          createdAt: 0,
          parentId: 'cat',
        ),
      ]),
    );
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
        mockApiOverride(_answer),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(store.db.close);
    // Built on the test clock, so a tap that awaits the store needs no real turn as well.
    container.read(storeProvider);
    await tester.runAsync(
      () => container
          .read(channelNotificationOverridesProvider.notifier)
          .refresh(),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChannelCategorySections(
                channels: channels,
                categories: const [_projects, _drafts],
                selectedId: null,
                canManage: canManage,
                onReorder: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await waitUntil(tester, () {
      final overrides = container.read(channelNotificationOverridesProvider);
      return overrides.settled &&
          (_muted.isEmpty || overrides.categoryParents.isNotEmpty);
    });
  }

  Future<http.Response> _answer(http.Request request) async {
    final path = request.url.path;
    if (request.method != 'GET') writes.add('${request.method} $path');
    if (path == '/read-states/read') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      markedRead.addAll((body['channel_ids'] as List).cast<String>());
    }
    if (path == '/notification-preferences/categories') {
      return _json([
        for (final id in _muted) {'category_id': id},
      ]);
    }
    if (path.startsWith('/notification-preferences/categories/')) {
      final id = path.split('/').last;
      if (request.method == 'DELETE') {
        _muted.remove(id);
        return http.Response('', 204);
      }
      _muted.add(id);
      return _json({'category_id': id});
    }
    return _json(const <Object>[]);
  }

  Future<void> openMenu(WidgetTester tester, String header) async {
    await tester.tapAt(
      tester.getCenter(find.text(header)),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await pumpFrames(tester);
  }
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets(
    'a member mutes a category, which quiets its rows and its header',
    (tester) async {
      final h = _Harness();
      await h.pump(tester, [_channel('a', 'cat', cursor: 3)]);
      expect(find.byIcon(AppIcons.notificationsOff), findsNothing);

      await h.openMenu(tester, 'Projects');
      expect(find.text('Mark all as read'), findsOneWidget);
      await tester.tap(find.text('Mute category'));
      await waitUntil(tester, () => h.writes.isNotEmpty);

      expect(h.writes, ['PUT /notification-preferences/categories/cat']);
      expect(find.byIcon(AppIcons.notificationsOff), findsNWidgets(2));

      await h.openMenu(tester, 'Projects');
      await tester.tap(find.text('Unmute category'));
      await waitUntil(tester, () => h.writes.length == 2);

      expect(h.writes.last, 'DELETE /notification-preferences/categories/cat');
      expect(find.byIcon(AppIcons.notificationsOff), findsNothing);
    },
  );

  testWidgets(
    'with nothing unread Mark all as read is shown but sends nothing',
    (tester) async {
      final h = _Harness();
      await h.pump(tester, [_channel('a', 'cat')]);

      await h.openMenu(tester, 'Projects');
      await tester.tap(find.text('Mark all as read'));
      await pumpFrames(tester);

      expect(h.writes, isEmpty);
      expect(find.text('Mute category'), findsOneWidget);
    },
  );

  testWidgets('a sub-category of a muted category says so', (tester) async {
    final h = _Harness(muted: {'cat'});
    await h.pump(tester, [_channel('a', 'cat'), _channel('b', 'sub')]);

    await h.openMenu(tester, 'Drafts');
    expect(find.text('Muted with Projects'), findsOneWidget);
    expect(find.text('Mute category'), findsNothing);
  });

  testWidgets('a manager gets the notification entries above a divider', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester, [_channel('a', 'cat')], canManage: true);

    await h.openMenu(tester, 'Projects');
    final mute = tester.getTopLeft(find.text('Mute category')).dy;
    final rename = tester.getTopLeft(find.text('Rename category...')).dy;
    expect(tester.getTopLeft(find.text('Mark all as read')).dy, lessThan(mute));
    expect(mute, lessThan(rename));
  });

  testWidgets('a muted category can still be marked read', (tester) async {
    final h = _Harness(muted: {'cat'});
    await h.pump(tester, [
      _channel('a', 'cat', cursor: 3),
      _channel('b', 'sub', cursor: 2),
      _channel('c', 'cat'),
    ]);

    await h.openMenu(tester, 'Projects');
    await tester.tap(find.text('Mark all as read'));
    await waitUntil(
      tester,
      () => h.markedRead.isNotEmpty,
      reason: 'Mark all as read sent nothing',
    );

    expect(h.markedRead, ['a', 'b']);
  });

  testWidgets('a channel quiet by its category says Muted in its row menu', (
    tester,
  ) async {
    final h = _Harness(muted: {'cat'});
    await h.pump(tester, [_channel('a', 'cat')]);

    await h.openMenu(tester, 'a');
    final entry = tester.widget<AppSubmenuItem>(
      find.byWidgetPredicate(
        (w) => w is AppSubmenuItem && w.label == 'Notifications',
      ),
    );
    expect(entry.leading, AppIcons.notificationsOff);
    expect(find.text('Muted'), findsOneWidget);
    expect(find.text('Default'), findsNothing);
  });

  testWidgets('the header glyph is sized to the header label', (tester) async {
    final h = _Harness(muted: {'cat'});
    await h.pump(tester, [_channel('a', 'cat')]);

    final glyph = find.descendant(
      of: find.ancestor(
        of: find.text('Projects'),
        matching: find.byWidgetPredicate((w) => w is Row),
      ),
      matching: find.byIcon(AppIcons.notificationsOff),
    );
    expect(tester.getSize(glyph.first), const Size.square(AppSizes.icon12));
  });
}
