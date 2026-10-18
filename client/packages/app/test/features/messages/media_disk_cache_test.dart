// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Avatars and attachment originals survive eviction and a restart through the
/// disk cache, and signing an account out drops its files.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/avatar_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/providers/disk_byte_cache.dart';
import 'package:slimm_app/src/providers/media_disk_caches.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../../support/fake_api.dart';

class _MemoryCache implements ByteCache {
  final entries = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, Uint8List bytes) async => entries[key] = bytes;

  @override
  Future<void> removeWithPrefix(String prefix) async =>
      entries.removeWhere((key, _) => key.startsWith(prefix));
}

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container(
  _MemoryCache avatars,
  _MemoryCache originals,
  List<Uri> requests,
) {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      avatarCacheProvider.overrideWithValue(avatars),
      attachmentOriginalCacheProvider.overrideWithValue(originals),
      mockApiOverride((request) async {
        requests.add(request.url);
        return http.Response.bytes([1, 2, 3, 4], 200);
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('an avatar is fetched once across launches, per updatedAt', () async {
    final avatars = _MemoryCache();
    final originals = _MemoryCache();
    final first = <Uri>[];
    await _container(
      avatars,
      originals,
      first,
    ).read(avatarBytesProvider((userId: 'u1', updatedAt: 5)).future);
    await Future<void>.delayed(Duration.zero);

    final second = <Uri>[];
    final again = _container(avatars, originals, second);
    final bytes = await again.read(
      avatarBytesProvider((userId: 'u1', updatedAt: 5)).future,
    );
    expect(first, hasLength(1));
    expect(second, isEmpty);
    expect(bytes, [1, 2, 3, 4]);

    await again.read(avatarBytesProvider((userId: 'u1', updatedAt: 6)).future);
    expect(second, hasLength(1), reason: 'a new upload is a new key');
  });

  test('an attachment original is fetched once across launches', () async {
    final avatars = _MemoryCache();
    final originals = _MemoryCache();
    final first = <Uri>[];
    await _container(
      avatars,
      originals,
      first,
    ).read(attachmentBytesProvider('gif1').future);
    await Future<void>.delayed(Duration.zero);

    final second = <Uri>[];
    final bytes = await _container(
      avatars,
      originals,
      second,
    ).read(attachmentBytesProvider('gif1').future);
    expect(first, hasLength(1));
    expect(second, isEmpty);
    expect(bytes, [1, 2, 3, 4]);
  });

  test('clearing an account drops its cached files only', () async {
    final avatars = _MemoryCache();
    final originals = _MemoryCache();
    final mine = Uri.parse('http://localhost:8080');
    final other = Uri.parse('http://other.example');
    for (final server in [mine, other]) {
      avatars.entries[serverScopedKey(server, 'u1-1')] = Uint8List(1);
      originals.entries[serverScopedKey(server, 'a1')] = Uint8List(1);
    }
    await clearMediaDiskCaches(mine, avatars: avatars, originals: originals);
    expect(avatars.entries.keys, [serverScopedKey(other, 'u1-1')]);
    expect(originals.entries.keys, [serverScopedKey(other, 'a1')]);
  });
}
