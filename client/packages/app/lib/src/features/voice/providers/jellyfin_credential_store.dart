// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a viewer's Jellyfin direct-play logins are kept: one entry per slim-m
/// account and media server, so another account on the device never sees them.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart' show KeyStore;

import 'jellyfin_direct_client.dart';

class JellyfinCredentialStore {
  const JellyfinCredentialStore(this._keys);

  final KeyStore _keys;

  static String _handle(String userId, String baseUrl) =>
      'jellyfin_direct:${Uri.encodeComponent(userId)}:${Uri.encodeComponent(baseUrl)}';

  static String _indexHandle(String userId) =>
      'jellyfin_direct_urls:${Uri.encodeComponent(userId)}';

  Future<JellyfinSession?> load(String userId, String baseUrl) async {
    if (userId.isEmpty) return null;
    final stored = await _keys.read(_handle(userId, baseUrl));
    final at = stored?.indexOf('|') ?? -1;
    if (stored == null || at < 1) return null;
    return JellyfinSession(
      token: stored.substring(0, at),
      userId: stored.substring(at + 1),
    );
  }

  Future<void> save(
    String userId,
    String baseUrl,
    JellyfinSession session,
  ) async {
    if (userId.isEmpty) return;
    await _keys.put(
      _handle(userId, baseUrl),
      '${session.token}|${session.userId}',
    );
    final urls = await _urls(userId);
    if (!urls.contains(baseUrl)) {
      await _keys.put(_indexHandle(userId), jsonEncode([...urls, baseUrl]));
    }
  }

  Future<void> forget(String userId, String baseUrl) async {
    if (userId.isEmpty) return;
    await _keys.delete(_handle(userId, baseUrl));
  }

  /// Deletes every login this account stored; a failure is logged and never blocks a sign out.
  Future<void> forgetAll(String? userId) async {
    if (userId == null || userId.isEmpty) return;
    try {
      for (final url in await _urls(userId)) {
        await _keys.delete(_handle(userId, url));
      }
      await _keys.delete(_indexHandle(userId));
    } on Object catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.auth,
        'Could not delete the Jellyfin direct-play logins of a signed-out account',
        error,
        stack,
      );
    }
  }

  Future<List<String>> _urls(String userId) async {
    final raw = await _keys.read(_indexHandle(userId));
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } on Object catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.auth,
        'The stored Jellyfin server list was unreadable; treated as empty',
        error,
        stack,
      );
      return const [];
    }
  }
}
