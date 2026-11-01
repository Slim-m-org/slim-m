// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `KeepAliveCache` is the count-bounded window behind every autoDispose byte
/// cache in the app (avatars, attachments, gif previews). Its whole reason to
/// exist is evicting the least-recently-held entry once capacity is passed, so
/// a long member list or an image-heavy channel cannot hold every byte it ever
/// fetched for the life of the process.
///
/// Nothing else reached that eviction path: `avatar_cache_test` only ever
/// holds one key, so it proves the keep-alive window but never the bound that
/// makes the window safe on a phone. These drive several keys through one
/// cache and watch the oldest fall out.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/cache_for.dart';

class _Recorder {
  final disposed = <int>[];
}

final _recorderProvider = Provider<_Recorder>((ref) => _Recorder());
final _cacheProvider = Provider<KeepAliveCache>((ref) => KeepAliveCache(2));

/// A stand-in for a byte provider: it holds its key in the cache and records
/// the moment it finally disposes, which is what eviction looks like from
/// outside once nothing is watching.
final _probe = Provider.autoDispose.family<int, int>((ref, key) {
  ref.read(_cacheProvider).hold(ref, key);
  final recorder = ref.read(_recorderProvider);
  ref.onDispose(() => recorder.disposed.add(key));
  return key;
});

/// Builds the provider for [key] the way a mounted widget would, then drops
/// its only watcher so nothing but the cache keeps it alive - the exact state
/// a face has after its channel is left.
Future<void> _holdThenRelease(ProviderContainer container, int key) async {
  container.listen(_probe(key), (_, _) {}).close();
  await Future<void>.delayed(Duration.zero);
}

ProviderContainer _containerOf(int capacity) {
  final container = ProviderContainer(
    overrides: [_cacheProvider.overrideWithValue(KeepAliveCache(capacity))],
  );
  return container;
}

void main() {
  test(
    'holding past capacity evicts the least recently held, and only it',
    () async {
      final container = _containerOf(2);
      addTearDown(container.dispose);

      await _holdThenRelease(container, 1);
      await _holdThenRelease(container, 2);
      expect(
        container.read(_recorderProvider).disposed,
        isEmpty,
        reason: 'at capacity, both are still held, so neither is dropped yet',
      );

      await _holdThenRelease(container, 3);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(_recorderProvider).disposed,
        [1],
        reason: 'the third arrival evicts the oldest, and leaves 2 and 3 held',
      );
    },
  );

  test('each further arrival drops the next-oldest, in order', () async {
    final container = _containerOf(2);
    addTearDown(container.dispose);

    for (final key in [1, 2, 3, 4]) {
      await _holdThenRelease(container, key);
    }
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(_recorderProvider).disposed,
      [1, 2],
      reason: 'eviction is oldest-first as the window slides, sparing 3 and 4',
    );
  });
}
