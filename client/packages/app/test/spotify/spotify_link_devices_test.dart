// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Spotify link belongs to the device, not to one account's container: its
/// status follows it everywhere, a redirect meant for another attempt cannot
/// spend the one in flight, and a key store that will not take the attempt
/// says so instead of waiting forever.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/spotify/spotify_link.dart';
import 'package:slimm_app/src/spotify/spotify_link_status.dart';
import 'package:slimm_app/src/spotify/spotify_token_store.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

import 'spotify_rig.dart';

class _PendingRefused extends InMemoryKeyStore {
  @override
  Future<KeyHandle> put(String name, String secret) {
    if (name == spotifyPendingHandle) throw StateError('keychain locked');
    return super.put(name, secret);
  }
}

SpotifyLinkStatus _status(SpotifyRig rig) =>
    rig.container.read(spotifyLinkStatusProvider);

Future<void> _begin(SpotifyRig rig) async {
  await rig.container.read(shareSpotifyProvider.notifier).connect();
  await rig.settle();
}

void main() {
  group('a redirect for another attempt', () {
    test(
      'leaves the attempt in flight, which the real redirect then finishes',
      () async {
        final rig = SpotifyRig();
        addTearDown(rig.dispose);
        await rig.start();
        await _begin(rig);

        final spent = await rig.linker.handleCallback(
          rig.redirect(state: 'forged'),
        );

        expect(spent, isFalse);
        expect(_status(rig), isA<SpotifyWaiting>());
        final store = rig.container.read(spotifyTokenStoreProvider);
        expect(await store.loadPending(), isNotNull);
        expect(await rig.linker.handleCallback(rig.redirect()), isTrue);
        expect(_status(rig), isA<SpotifyConnected>());
      },
    );

    test('does not stop the wait from timing out', () async {
      final rig = SpotifyRig(linkTimeout: const Duration(milliseconds: 60));
      addTearDown(rig.dispose);
      await rig.start();
      await _begin(rig);

      await rig.linker.handleCallback(rig.redirect(state: 'forged'));
      expect(_status(rig), isA<SpotifyWaiting>());
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect((_status(rig) as SpotifyFailed).message, contains('timed out'));
    });
  });

  group('a key store that will not take the attempt', () {
    test('fails in place and lets the person try again', () async {
      final rig = SpotifyRig(keys: _PendingRefused());
      addTearDown(rig.dispose);
      await rig.start();

      await _begin(rig);

      expect(_status(rig), isA<SpotifyFailed>());
      expect(rig.launched, isEmpty);
      await _begin(rig);
      expect(
        _status(rig),
        isA<SpotifyFailed>(),
        reason: 'asked again, not stuck',
      );
    });
  });

  group('two containers on one device', () {
    late SpotifyRig first;
    late SpotifyRig second;

    setUp(() async {
      first = SpotifyRig();
      second = SpotifyRig(keys: first.keys);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.start();
      await second.start();
      first.container.read(spotifyLinkStatusProvider);
      second.container.read(spotifyLinkStatusProvider);
    });

    test('a link finished in one is shown by the other', () async {
      await _begin(first);
      expect(_status(second), isA<SpotifyWaiting>());

      await first.linker.handleCallback(first.redirect());

      expect(_status(second), isA<SpotifyConnected>());
    });

    test(
      'a link started in one and finished in the other ends the wait in both',
      () async {
        await _begin(second);

        await first.linker.handleCallback(second.redirect());

        expect(_status(second), isA<SpotifyConnected>());
        expect(_status(first), isA<SpotifyConnected>());
      },
    );

    test('unlinking in one is shown by the other', () async {
      await _begin(first);
      await first.linker.handleCallback(first.redirect());
      expect(_status(second), isA<SpotifyConnected>());

      await first.linker.unlink();

      expect(_status(second), isA<SpotifyUnlinked>());
    });

    test('dismissing an error in one clears it in the other', () async {
      await _begin(first);
      await first.linker.handleCallback(first.redirect(code: null));
      expect(_status(second), isA<SpotifyFailed>());

      await second.linker.dismissFailure();

      expect(_status(first), isA<SpotifyUnlinked>());
      expect(_status(second), isA<SpotifyUnlinked>());
    });
  });
}
