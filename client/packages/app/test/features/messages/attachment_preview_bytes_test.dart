// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inline preview asks the server for a bounded size, keeps what comes
/// back on disk, and reads it from there on the next view or launch.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/providers/disk_byte_cache.dart';
import 'package:slimm_app/src/providers/providers.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

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

final _png = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3];
final _local = attachmentPreviewScope(Uri.parse('http://localhost:8080'));

ProviderContainer _container(
  ByteCache cache,
  List<Uri> requests, {
  List<int>? body,
  Uri? server,
}) {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      attachmentPreviewCacheProvider.overrideWithValue(cache),
      if (server != null) serverUrlProvider.overrideWithValue(server),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            requests.add(request.url);
            return http.Response.bytes(body ?? _png, 200);
          }),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<Uint8List> _read(ProviderContainer c, String id, int bucket) =>
    c.read(attachmentPreviewBytesProvider((id: id, bucket: bucket)).future);

void main() {
  test('a width rounds up to the server bucket that covers it', () {
    expect(attachmentPreviewBucket(1), 320);
    expect(attachmentPreviewBucket(320), 320);
    expect(attachmentPreviewBucket(321), 640);
    expect(attachmentPreviewBucket(1281), 1280);
  });

  test('a miss asks the server for the bucket and stores the answer', () async {
    final requests = <Uri>[];
    final cache = _MemoryCache();

    final bytes = await _read(_container(cache, requests), 'img', 640);

    expect(bytes, _png);
    expect(requests.single.path, '/attachments/img');
    expect(requests.single.queryParameters, {'w': '640'});
    await Future<void>.delayed(Duration.zero);
    expect(cache.entries['$_local-img-640'], _png);
  });

  test('a second launch over the same cache makes no request', () async {
    final cache = _MemoryCache();
    final first = <Uri>[];
    await _read(_container(cache, first), 'img', 640);
    await Future<void>.delayed(Duration.zero);

    final second = <Uri>[];
    final bytes = await _read(_container(cache, second), 'img', 640);

    expect(first, hasLength(1));
    expect(second, isEmpty);
    expect(bytes, _png);
  });

  test('a different bucket is a different entry', () async {
    final cache = _MemoryCache();
    final requests = <Uri>[];
    final container = _container(cache, requests);

    await _read(container, 'img', 320);
    await _read(container, 'img', 1280);

    expect(requests.map((u) => u.queryParameters['w']), ['320', '1280']);
  });

  test('another server never reads this one\'s cached preview', () async {
    final cache = _MemoryCache();
    await _read(_container(cache, []), 'img', 640);
    await Future<void>.delayed(Duration.zero);

    final other = <Uri>[];
    await _read(
      _container(cache, other, server: Uri.parse('https://evil.example')),
      'img',
      640,
    );

    expect(other, hasLength(1));
    expect(cache.entries, hasLength(2));
  });

  test('bytes that are not an image are shown but never cached', () async {
    final cache = _MemoryCache();
    await _read(_container(cache, [], body: [1, 2, 3]), 'img', 640);
    await Future<void>.delayed(Duration.zero);
    expect(cache.entries, isEmpty);
  });

  test('a poisoned cache entry is refetched', () async {
    final cache = _MemoryCache()
      ..entries['$_local-img-640'] = Uint8List.fromList([9, 9, 9]);
    final requests = <Uri>[];
    final bytes = await _read(_container(cache, requests), 'img', 640);
    expect(bytes, _png);
    expect(requests, hasLength(1));
  });

  test('clearing a server drops only its previews', () async {
    final cache = _MemoryCache();
    final server = Uri.parse('http://localhost:8080');
    cache.entries['$_local-a-320'] = Uint8List(1);
    cache.entries['other-a-320'] = Uint8List(1);
    await clearAttachmentPreviews(cache, server);
    expect(cache.entries.keys, ['other-a-320']);
  });

  group('DiskByteCache', () {
    test('removeWithPrefix deletes matching files only', () async {
      final d = Directory.systemTemp.createTempSync('byte-cache-p-');
      addTearDown(() => d.deleteSync(recursive: true));
      final cache = DiskByteCache(
        dirName: 'c',
        ceilingBytes: 999,
        directory: d,
      );
      await cache.write('aa-1', Uint8List(1));
      await cache.write('bb-1', Uint8List(1));
      await cache.removeWithPrefix('aa-');
      expect(await cache.read('aa-1'), isNull);
      expect(await cache.read('bb-1'), isNotNull);
    });

    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('byte-cache-'));
    tearDown(() => dir.deleteSync(recursive: true));

    int sizeOnDisk() => dir
        .listSync(recursive: true)
        .whereType<File>()
        .fold(0, (sum, f) => sum + f.lengthSync());

    test(
      'stays under its ceiling and drops the stalest entries first',
      () async {
        final cache = DiskByteCache(
          dirName: 'c',
          ceilingBytes: 250,
          directory: dir,
        );

        for (var i = 0; i < 6; i++) {
          await cache.write('k$i', Uint8List(100));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(sizeOnDisk(), lessThanOrEqualTo(250));
        expect(await cache.read('k5'), isNotNull);
        expect(await cache.read('k0'), isNull);
      },
    );

    test('a batched trim overshoots by at most the batch', () async {
      final cache = DiskByteCache(
        dirName: 'c',
        ceilingBytes: 300,
        trimEveryWrites: 4,
        directory: dir,
      );

      for (var i = 0; i < 12; i++) {
        await cache.write('k$i', Uint8List(100));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(sizeOnDisk(), lessThanOrEqualTo(300 + 3 * 100));
    });
  });
}
