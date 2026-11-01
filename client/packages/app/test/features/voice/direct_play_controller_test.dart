// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A viewer's direct play from offer to fall back: who is told what, that the
/// bot's share is never held and played at once, and what a failure does. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/direct_play_controller.dart';
import 'package:slimm_app/src/features/voice/providers/direct_play_eligibility.dart';

import 'direct_play_fakes.dart';

Future<DirectPlayController> _controller(
  Rig rig, {
  bool enabled = false,
  bool supported = true,
}) async => DirectPlayController(
  rig.env(supported: supported),
  'call-1',
  enabled: enabled,
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('an ineligible viewer stays on the shared stream and is told why', () {
    Future<DirectPlayController> viewer(
      Rig rig,
      api.WatchDirectPlay offer, {
      bool supported = true,
    }) async {
      final c = await _controller(rig, enabled: true, supported: supported);
      await c.onRoom(room(rig, offer: offer));
      return c;
    }

    void expectUntouched(Rig rig, DirectPlayController c, DirectPlayBlock why) {
      expect(c.current.block, why);
      expect(c.current.active, isFalse);
      expect(rig.players, isEmpty);
      expect(rig.events.where((e) => e.startsWith('hold')), isEmpty);
      expect(rig.reports, isEmpty);
    }

    test('no link', () async {
      final rig = Rig();
      final c = await viewer(rig, const api.WatchDirectPlay(baseUrl: jellyUrl));
      expectUntouched(rig, c, DirectPlayBlock.noLink);
      expect(
        directPlayBlockLine(DirectPlayBlock.noLink),
        'Watching the shared stream. Link a Jellyfin account to watch at source quality.',
      );
    });

    test('a link that is not verified', () async {
      final rig = Rig();
      final c = await viewer(
        rig,
        const api.WatchDirectPlay(baseUrl: jellyUrl, unverifiedUserIds: ['me']),
      );
      expectUntouched(rig, c, DirectPlayBlock.unverifiedLink);
      expect(rig.mediaCalls, isEmpty);
    });

    test('a device that cannot reach Jellyfin', () async {
      final rig = Rig(reachable: false);
      final c = await viewer(
        rig,
        const api.WatchDirectPlay(baseUrl: jellyUrl, verifiedUserIds: ['me']),
      );
      expectUntouched(rig, c, DirectPlayBlock.unreachable);
    });

    test(
      'a browser never tries, because it cannot play the original',
      () async {
        final rig = Rig();
        final c = await viewer(
          rig,
          const api.WatchDirectPlay(baseUrl: jellyUrl, verifiedUserIds: ['me']),
          supported: false,
        );
        expectUntouched(rig, c, DirectPlayBlock.unreachable);
        expect(rig.mediaCalls, isEmpty);
      },
    );

    test('an account that cannot see the title', () async {
      final rig = Rig(canSee: false);
      final c = await _controller(rig, enabled: true);
      await c.onRoom(room(rig));
      expect(rig.players, isEmpty);
      expect(c.current.block, DirectPlayBlock.cannotSee);
      expect(c.current.phase, DirectPlayPhase.off);
      expect(rig.events.where((e) => e.startsWith('hold')), isEmpty);
    });

    test(
      'a room that offers nothing shows nothing and plays nothing',
      () async {
        final rig = Rig();
        final c = await _controller(rig, enabled: true);
        await c.onRoom(room(rig, offer: null));
        expect(c.current.block, isNull);
        expect(rig.players, isEmpty);
      },
    );
  });

  group('an eligible viewer', () {
    test('is not started until they turn it on', () async {
      final rig = Rig();
      final c = await _controller(rig);
      await c.onRoom(room(rig));
      expect(c.current.enabled, isFalse);
      expect(rig.players, isEmpty);
    });

    test(
      'plays the original at the room position, holds the share first, and says so',
      () async {
        final rig = Rig();
        final c = await _controller(rig);
        await c.onRoom(room(rig, positionMs: 90000));
        await c.enable();
        await _settle();
        expect(c.current.phase, DirectPlayPhase.playing);
        expect(rig.events, ['hold:jelly', 'player']);
        expect(
          rig.player.openedUrl,
          '$jellyUrl/Videos/item-1/stream?static=true',
        );
        expect(
          rig.player.openedHeaders!['authorization'],
          contains('Token="tok"'),
        );
        expect(rig.player.openedAt, const Duration(seconds: 90));
        expect(rig.player.isPlaying, isTrue);
        expect(rig.reports, [true]);
        expect(rig.enabledSaved, isTrue);
      },
    );

    test('a sign in is asked for once and its token is kept', () async {
      final rig = Rig(credential: false);
      final c = await _controller(rig);
      await c.onRoom(room(rig));
      await c.enable();
      expect(c.current.phase, DirectPlayPhase.signIn);
      expect(rig.players, isEmpty);

      await c.signIn('nick', 'wrong');
      expect(c.signInError, isNotNull);
      expect(c.current.phase, DirectPlayPhase.signIn);

      await c.signIn('nick', 'right');
      await _settle();
      expect(rig.saved!.token, 'tok');
      expect(c.current.phase, DirectPlayPhase.playing);
    });

    test('turning it off hands the share back and tells the server', () async {
      final rig = Rig();
      final c = await _controller(rig);
      await c.onRoom(room(rig));
      await c.enable();
      await _settle();
      await c.disable();
      await _settle();
      expect(rig.events.last, 'release:jelly');
      expect(rig.player.disposed, isTrue);
      expect(rig.reports.last, isFalse);
      expect(c.current.active, isFalse);
    });

    test(
      'a player that cannot open falls back with a line and the share returns',
      () async {
        final rig = Rig()..openError = StateError('no codec');
        final c = await _controller(rig);
        await c.onRoom(room(rig));
        await c.enable();
        await _settle();
        expect(c.current.phase, DirectPlayPhase.off);
        expect(c.current.notice, contains('Back on the shared stream'));
        expect(rig.events.last, 'release:jelly');
        expect(rig.player.disposed, isTrue);
      },
    );

    test(
      'a fall back is not undone by the next tick, only by the viewer',
      () async {
        final rig = Rig()..openError = StateError('no codec');
        final c = await _controller(rig);
        await c.onRoom(room(rig));
        await c.enable();
        await _settle();
        rig.openError = null;
        await c.onRoom(room(rig));
        expect(rig.players, hasLength(1));
        await c.recheck();
        await _settle();
        expect(c.current.phase, DirectPlayPhase.playing);
      },
    );
  });

  group('while playing', () {
    Future<(Rig, DirectPlayController)> playing() async {
      final rig = Rig();
      final c = await _controller(rig);
      await c.onRoom(room(rig, positionMs: 600000));
      await c.enable();
      await _settle();
      return (rig, c);
    }

    test('a small drift changes the rate and a large one seeks', () async {
      final (rig, c) = await playing();
      rig.player.position = const Duration(seconds: 598);
      await c.debugStep();
      expect(rig.player.rate, closeTo(1.05, 1e-9));
      rig.now = rig.now.add(const Duration(seconds: 1));
      rig.player.position = const Duration(seconds: 500);
      await c.debugStep();
      expect(rig.player.seeks.last, greaterThan(const Duration(minutes: 10)));
    });

    test('a seek by the room follows at once', () async {
      final (rig, c) = await playing();
      await c.onRoom(room(rig, positionMs: 1800000, epoch: 2));
      rig.player.position = const Duration(minutes: 10);
      await c.debugStep();
      expect(rig.player.seeks.last, const Duration(minutes: 30));
    });

    test('a paused room pauses the player', () async {
      final (rig, c) = await playing();
      await c.onRoom(room(rig, playing: false, positionMs: 600000));
      rig.player.position = const Duration(minutes: 10);
      await c.debugStep();
      expect(rig.player.isPlaying, isFalse);
    });

    test(
      'three seeks in a minute drop the viewer back to the shared stream',
      () async {
        final (rig, c) = await playing();
        for (var i = 0; i < 3; i++) {
          rig.player.position = Duration(seconds: i);
          await c.debugStep();
          rig.now = rig.now.add(const Duration(seconds: 15));
        }
        await _settle();
        expect(c.current.phase, DirectPlayPhase.off);
        expect(c.current.notice, contains('could not stay with the room'));
        expect(rig.events.last, 'release:jelly');
        expect(rig.reports.last, isFalse);
      },
    );

    test('a stall over ten seconds drops the viewer back', () async {
      final (rig, c) = await playing();
      rig.player.isBuffering = true;
      for (var i = 0; i < 12; i++) {
        rig.now = rig.now.add(const Duration(seconds: 1));
        rig.player.position = const Duration(minutes: 10);
        await c.debugStep();
      }
      expect(c.current.phase, DirectPlayPhase.off);
      expect(c.current.notice, contains('stalled'));
      expect(rig.events.last, 'release:jelly');
    });

    test(
      'a local pause is local, says where the room is, and rejoins',
      () async {
        final (rig, c) = await playing();
        await c.pauseLocally();
        expect(rig.player.isPlaying, isFalse);
        expect(c.current.localPause, const Duration(minutes: 10));
        rig.now = rig.now.add(const Duration(seconds: 20));
        await c.debugStep();
        expect(c.current.localPause, const Duration(minutes: 10, seconds: 20));
        expect(
          directPlayPauseLine(c.current.localPause!),
          'You are paused, the room is at 10:20',
        );
        expect(rig.player.seeks, isEmpty);
        await c.rejoin();
        expect(
          rig.player.seeks.single,
          const Duration(minutes: 10, seconds: 20),
        );
        expect(rig.player.isPlaying, isTrue);
        expect(c.current.localPause, isNull);
      },
    );

    test(
      'the room ending, or another title, stops the player and returns the share',
      () async {
        final (rig, c) = await playing();
        await c.onRoom(room(rig, itemId: 'item-2'));
        expect(rig.events.last, anyOf('release:jelly', 'hold:jelly', 'player'));
        expect(rig.players.first.disposed, isTrue);
        expect(rig.events, contains('release:jelly'));
        await c.onRoom(null);
        expect(c.current.active, isFalse);
      },
    );

    test(
      'never plays and holds the share at the same moment it is released',
      () async {
        final (rig, c) = await playing();
        await c.disable();
        final firstHold = rig.events.indexOf('hold:jelly');
        final firstPlayer = rig.events.indexOf('player');
        expect(firstHold, lessThan(firstPlayer));
      },
    );
  });
}
