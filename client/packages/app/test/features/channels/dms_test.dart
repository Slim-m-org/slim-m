// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for `providers/dms.dart`: turning a DM listing into the same
/// `Channel` shape every other channel arrives as, and getting a freshly
/// opened DM into the local store immediately rather than waiting on the
/// next reconnect's channel refresh.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

void main() {
  test('channelFromDm carries the other user\'s name as the channel name', () {
    const dm = api.DmConversation(
      channelId: 'dm-1',
      user: api.UserProfile(
        id: 'user-2',
        username: 'priya',
        displayName: 'Priya',
        createdAt: 0,
      ),
      unread: 3,
      createdAt: 1000,
    );

    final channel = channelFromDm(dm, selfId: 'self');

    expect(channel.id, 'dm-1');
    expect(channel.name, 'Priya');
    expect(channel.kind, dmChannelKind);
    expect(channel.createdAt, 1000);
    expect(
      channel.isPersonalSpace,
      isFalse,
      reason: 'the other participant is not the caller',
    );
  });

  test('channelFromDm names a personal space distinctly rather than with the '
      'caller\'s own display name', () {
    const dm = api.DmConversation(
      channelId: 'dm-self',
      user: api.UserProfile(
        id: 'self',
        username: 'nick',
        displayName: 'Nick',
        createdAt: 0,
      ),
      unread: 0,
      createdAt: 1000,
    );

    final channel = channelFromDm(dm, selfId: 'self');

    expect(
      channel.name,
      personalSpaceName,
      reason:
          'a personal space labelled with your own name would read as a '
          'DM with yourself rather than what it is',
    );
    expect(
      channel.isPersonalSpace,
      isTrue,
      reason: 'this is the one signal the rail may use to identify it',
    );
  });

  test('a DM whose other participant chose the sentinel as their own display '
      'name is not marked as the personal space', () {
    const dm = api.DmConversation(
      channelId: 'dm-imposter',
      user: api.UserProfile(
        id: 'user-2',
        username: 'imposter',
        displayName: personalSpaceName,
        createdAt: 0,
      ),
      unread: 0,
      createdAt: 1000,
    );

    final channel = channelFromDm(dm, selfId: 'self');

    expect(
      channel.isPersonalSpace,
      isFalse,
      reason:
          'the other participant is not the caller, whatever their '
          'display name says',
    );
    expect(
      channel.name,
      personalSpaceName,
      reason:
          'the label collides - that is the point of this test - but '
          'identity must not be read off it',
    );
  });

  test(
    'openDirectMessage upserts the opened channel into the local store',
    () async {
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      const tokens = api.TokenPair(
        userId: 'self',
        accessToken: 'access',
        refreshToken: 'refresh',
        accessExpiresAt: 0,
      );

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
          databaseProvider.overrideWith((ref) async => db),
          mockApiOverride((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/dms/user-2');
            return http.Response(
              jsonEncode({
                'channel_id': 'dm-1',
                'user': {
                  'id': 'user-2',
                  'username': 'priya',
                  'display_name': 'Priya',
                  'created_at': 0,
                },
                'unread': 0,
                'created_at': 500,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ],
      );
      addTearDown(container.dispose);

      final channelId = await openDirectMessage(container, 'user-2');
      expect(channelId, 'dm-1');

      final store = await container.read(storeProvider.future);
      final channels = await store.watchChannels().first;
      expect(channels.single.id, 'dm-1');
      expect(channels.single.name, 'Priya');
      expect(channels.single.kind, dmChannelKind);
      expect(channels.single.isPersonalSpace, isFalse);
    },
  );

  test('opening your own personal space stores it under the personal space '
      'name, not your own display name', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    const tokens = api.TokenPair(
      userId: 'self',
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: 0,
    );

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
        databaseProvider.overrideWith((ref) async => db),
        mockApiOverride((request) async {
          expect(request.url.path, '/dms/self');
          return http.Response(
            jsonEncode({
              'channel_id': 'dm-self',
              'user': {
                'id': 'self',
                'username': 'nick',
                'display_name': 'Nick',
                'created_at': 0,
              },
              'unread': 0,
              'created_at': 500,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    final channelId = await openDirectMessage(container, 'self');
    expect(channelId, 'dm-self');

    final store = await container.read(storeProvider.future);
    final channels = await store.watchChannels().first;
    expect(channels.single.name, personalSpaceName);
    expect(
      channels.single.isPersonalSpace,
      isTrue,
      reason: 'the persisted marker, not just the display name, must be set',
    );
  });
}
