// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Coverage for `forwardTargetsProvider`: which channels and DMs a forward
/// may actually go to.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/messages/providers/forward_targets.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _channelJson({
  required String id,
  required String name,
  int permissions = 0,
}) => {
  'id': id,
  'name': name,
  'kind': 'text',
  'created_at': 0,
  'permissions': permissions,
};

Map<String, dynamic> _userJson(
  String id,
  String displayName, {
  String? username,
}) => {
  'id': id,
  'username': username ?? id,
  'display_name': displayName,
  'created_at': 0,
};

Map<String, dynamic> _dmJson({
  required String channelId,
  required String userId,
  required String displayName,
  String? username,
}) => {
  'channel_id': channelId,
  'user': _userJson(userId, displayName, username: username),
  'unread': 0,
  'created_at': 0,
};

ProviderContainer _containerWith({
  required List<Map<String, dynamic>> channels,
  required List<Map<String, dynamic>> dms,
  List<String> blocked = const [],
}) {
  final client = MockClient((request) async {
    if (request.url.path == '/channels') {
      return http.Response(jsonEncode(channels), 200);
    }
    if (request.url.path == '/dms') {
      return http.Response(jsonEncode(dms), 200);
    }
    if (request.url.path == '/blocks') {
      return http.Response(jsonEncode(blocked), 200);
    }
    return http.Response('{}', 404);
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final slimmApi = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: client,
        );
        ref.onDispose(slimmApi.close);
        return slimmApi;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('offers a channel the caller may send in, and excludes one they '
      'may not', () async {
    final container = _containerWith(
      channels: [
        _channelJson(id: 'c1', name: 'general', permissions: Perm.sendMessages),
        _channelJson(id: 'c2', name: 'announcements', permissions: 0),
      ],
      dms: const [],
    );

    final targets = await container.read(
      forwardTargetsProvider((
        excludeChannelId: 'nowhere',
        hasAttachments: false,
      )).future,
    );

    expect(targets.map((t) => t.channelId), ['c1']);
    expect(targets.single.label, 'general');
  });

  test('a message with attachments excludes a channel that can send but '
      'not attach', () async {
    final container = _containerWith(
      channels: [
        _channelJson(id: 'c1', name: 'general', permissions: Perm.sendMessages),
        _channelJson(
          id: 'c2',
          name: 'announcements',
          permissions: Perm.sendMessages | Perm.attachFiles,
        ),
      ],
      dms: const [],
    );

    final targets = await container.read(
      forwardTargetsProvider((
        excludeChannelId: 'nowhere',
        hasAttachments: true,
      )).future,
    );

    expect(targets.map((t) => t.channelId), ['c2']);
  });

  test('excludes the channel the message already sits in', () async {
    final container = _containerWith(
      channels: [
        _channelJson(id: 'c1', name: 'general', permissions: Perm.sendMessages),
      ],
      dms: const [],
    );

    final targets = await container.read(
      forwardTargetsProvider((
        excludeChannelId: 'c1',
        hasAttachments: false,
      )).future,
    );

    expect(targets, isEmpty);
  });

  test('offers a DM, labelled with the other participant\'s name', () async {
    final container = _containerWith(
      channels: const [],
      dms: [_dmJson(channelId: 'dm1', userId: 'u-priya', displayName: 'Priya')],
    );

    final targets = await container.read(
      forwardTargetsProvider((
        excludeChannelId: 'nowhere',
        hasAttachments: false,
      )).future,
    );

    expect(targets.single.channelId, 'dm1');
    expect(targets.single.label, 'Priya');
    expect(
      targets.single.userId,
      'u-priya',
      reason:
          'a DM is a person, and the picker draws their face from this - '
          'without it every DM row shared one generic glyph',
    );
  });

  test('a channel carries no user identity, having none', () async {
    final container = _containerWith(
      channels: [
        _channelJson(id: 'c1', name: 'general', permissions: Perm.sendMessages),
      ],
      dms: const [],
    );

    final targets = await container.read(
      forwardTargetsProvider((
        excludeChannelId: 'nowhere',
        hasAttachments: false,
      )).future,
    );

    expect(targets.single.userId, isNull);
  });

  test('a DM with a blocked party is never offered', () async {
    final container = _containerWith(
      channels: const [],
      dms: [_dmJson(channelId: 'dm1', userId: 'u-priya', displayName: 'Priya')],
      blocked: ['u-priya'],
    );
    // Forced here the way the shell forces it in production (`blocksProvider`'s own doc comment), so this is not a race.
    await container.read(blocksProvider.notifier).refresh();

    final targets = await container.read(
      forwardTargetsProvider((
        excludeChannelId: 'nowhere',
        hasAttachments: false,
      )).future,
    );

    expect(targets, isEmpty);
  });

  test('the caller\'s own personal space is labelled "Notes"', () async {
    final container = _containerWith(
      channels: const [],
      dms: [_dmJson(channelId: 'dm-self', userId: 'self', displayName: 'Self')],
    );

    final targets = await container.read(
      forwardTargetsProvider((
        excludeChannelId: 'nowhere',
        hasAttachments: false,
      )).future,
    );

    expect(targets.single.label, 'Notes');
  });

  test(
    'a DM target carries the partner\'s username, so it can be searched',
    () async {
      final container = _containerWith(
        channels: const [],
        dms: [
          _dmJson(
            channelId: 'dm1',
            userId: 'u-priya',
            displayName: 'Priya',
            username: 'lovelace',
          ),
        ],
      );

      final targets = await container.read(
        forwardTargetsProvider((
          excludeChannelId: 'nowhere',
          hasAttachments: false,
        )).future,
      );

      expect(targets.single.username, 'lovelace');
    },
  );

  group('matching a typed query', () {
    const dm = ForwardTarget(
      channelId: 'dm1',
      label: 'Priya',
      isDm: true,
      userId: 'u-priya',
      // Shares no substring with the display name, or matching the label alone would satisfy the test.
      username: 'lovelace',
    );
    const channel = ForwardTarget(
      channelId: 'c1',
      label: 'general',
      isDm: false,
    );

    test('a display name still matches, as it always did', () {
      expect(dm.matches('priy'), isTrue);
    });

    test('the username matches too, which is the whole point', () {
      expect(
        dm.matches('lovel'),
        isTrue,
        reason:
            'somebody who remembers the @name and not the display name '
            'was told "No matches", which reads as a broken search field',
      );
    });

    test('an unrelated query matches neither', () {
      expect(dm.matches('kess'), isFalse);
    });

    test('a channel has no username and is matched on its name alone', () {
      expect(channel.username, isNull);
      expect(channel.matches('gene'), isTrue);
      expect(channel.matches('c1'), isFalse);
    });
  });
}
