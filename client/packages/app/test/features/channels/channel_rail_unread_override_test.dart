// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel narrowed to mentions only lit an unread dot for every ordinary
/// message anyway: every rail surface derived unread straight from
/// `cursor > lastReadSeq` and never asked
/// `channelNotificationOverridesProvider` anything.
/// `docs/decisions/0049-per-channel-notification-behaviour.md` is the rule
/// these pin, in the owner's own words: mentions-only shows nothing until a
/// mention, muted shows nothing at all.
///
/// Driven through the real [ChannelNotificationOverridesController] against a
/// mocked `GET /notification-preferences/channels` rather than a stubbed
/// state, so a row that reads the override through some other accessor is
/// still covered.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

Channel _channel(
  String id,
  String name, {
  String kind = 'text',
  int cursor = 0,
  int lastReadSeq = 0,
  int mentionedSeq = 0,
  bool manuallyUnread = false,
}) => Channel(
  id: id,
  name: name,
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: cursor,
  lastReadSeq: lastReadSeq,
  mentionedSeq: mentionedSeq,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  manuallyUnread: manuallyUnread,
);

/// The rail with one category-less channel, and whatever `overrides` names
/// already answered for by the server.
Widget _harness(Channel channel, {Map<String, String> overrides = const {}}) =>
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          if (request.url.path.endsWith('/notification-preferences/channels')) {
            return http.Response(
              jsonEncode([
                for (final entry in overrides.entries)
                  {'channel_id': entry.key, 'preference': entry.value},
              ]),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('', 404);
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ChannelCategorySections(
            channels: [channel],
            categories: const [],
            selectedId: null,
            canManage: false,
            onReorder: (_) {},
          ),
        ),
      ),
    );

void main() {
  testWidgets('an ordinary message lights the dot with no override at all', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(_channel('c1', 'general', cursor: 4)));
    await tester.pumpAndSettle();

    expect(find.byKey(AppListRow.unreadDotKey), findsOneWidget);
  });

  testWidgets('a mentions-only channel shows nothing for an ordinary message', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        _channel('c1', 'general', cursor: 4),
        overrides: const {'c1': 'mentions'},
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(AppListRow.unreadDotKey),
      findsNothing,
      reason: 'the owner asked for nothing at all until a mention',
    );
    expect(find.byKey(AppListRow.mentionDotKey), findsNothing);
  });

  testWidgets('a real mention in a mentions-only channel still shows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        _channel('c1', 'general', cursor: 4, mentionedSeq: 4),
        overrides: const {'c1': 'mentions'},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(AppListRow.mentionDotKey), findsOneWidget);
  });

  testWidgets('a muted channel shows nothing, a mention in it included', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        _channel('c1', 'general', cursor: 4, mentionedSeq: 4),
        overrides: const {'c1': 'nothing'},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(AppListRow.unreadDotKey), findsNothing);
    expect(
      find.byKey(AppListRow.mentionDotKey),
      findsNothing,
      reason: 'mute is nothing at all, unlike mentions-only',
    );
    expect(
      tester.widget<AppListRow>(find.byType(AppListRow)).mentioned,
      isFalse,
      reason: 'the label lift and the "mentioned" announcement leaked too',
    );
  });

  testWidgets('the reader own hand-mark still shows through a mute', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        // What `markUnread` leaves behind: the marker does not move.
        _channel(
          'c1',
          'general',
          cursor: 4,
          lastReadSeq: 4,
          manuallyUnread: true,
        ),
        overrides: const {'c1': 'nothing'},
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<AppListRow>(find.byType(AppListRow)).unread,
      isTrue,
      reason: 'marking a channel unread by hand is not a notification',
    );
  });

  testWidgets('a hand-mark alone lights the dot on an ordinary channel', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        _channel(
          'c1',
          'general',
          cursor: 4,
          lastReadSeq: 4,
          manuallyUnread: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(AppListRow.unreadDotKey),
      findsOneWidget,
      reason: 'the rows read only cursor/lastReadSeq, so this drew nothing',
    );
  });
}
