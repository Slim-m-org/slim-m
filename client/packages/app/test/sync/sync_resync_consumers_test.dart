// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a reconnect may have missed is read again by the consumers that hold it, off one signal.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/admin_alerts/providers/admin_alerts.dart';
import 'package:slimm_app/src/features/channels/providers/group_dm.dart';
import 'package:slimm_app/src/features/channels/providers/threads.dart';
import 'package:slimm_app/src/features/favorites/providers/favorites_controller.dart';
import 'package:slimm_app/src/features/members/providers/moderation_history_controller.dart';
import 'package:slimm_app/src/features/members/providers/reports_controller.dart';
import 'package:slimm_app/src/features/modules/providers/module_display_settings.dart';
import 'package:slimm_app/src/features/voice/providers/voice_call_history.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/sync/providers/sync_status.dart';
import 'package:slimm_platform/testing.dart';

import '../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _manageServer = 1 << 15;

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late Map<String, int> hits;
  late ProviderContainer container;

  setUp(() {
    hits = {};
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        meProvider.overrideWith(
          (ref) async => const api.Me(
            id: 'admin',
            username: 'admin',
            displayName: 'Admin',
            createdAt: 0,
            permissions: _manageServer,
          ),
        ),
        mockApiOverride((request) async {
          hits.update(request.url.path, (n) => n + 1, ifAbsent: () => 1);
          return http.Response('', 500);
        }),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> expectRefetched(
    String path,
    ProviderListenable<Object?> provider,
  ) async {
    container.listen(provider, (_, _) {});
    await _settle();
    final before = hits[path] ?? 0;
    expect(before, greaterThan(0), reason: '$path is read when first watched');

    container.read(syncResyncProvider.notifier).state++;
    await _settle();

    expect(hits[path], greaterThan(before), reason: '$path is read again');
  }

  test('module display settings', () {
    return expectRefetched('/version', moduleDisplayProvider);
  });

  test('call history', () {
    return expectRefetched(
      '/channels/v1/voice/calls',
      voiceCallHistoryProvider('v1'),
    );
  });

  test('admin alerts', () {
    return expectRefetched('/space/alerts', adminAlertsProvider);
  });

  test('favorites', () {
    return expectRefetched('/favorites', favoritesProvider);
  });

  test('custom emoji', () {
    return expectRefetched('/emoji', customEmojiProvider);
  });

  test('moderation queue', () {
    return expectRefetched('/reports', reportsControllerProvider);
  });

  test('moderation history', () {
    return expectRefetched(
      '/reports/history',
      moderationHistoryControllerProvider,
    );
  });

  test('group roster', () {
    return expectRefetched('/dms', groupDmProvider('g1'));
  });

  test('thread parent', () {
    return expectRefetched(
      '/channels/t1/thread-parent',
      threadParentProvider('t1'),
    );
  });
}
