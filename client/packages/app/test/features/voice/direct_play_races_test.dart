// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Direct play when the room, the sign-in sheet or the device changes under a
/// pending connect, and when the stored login stops working. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/direct_play_controller.dart';

import 'direct_play_fakes.dart';

DirectPlayController _controller(Rig rig, {bool enabled = true}) =>
    DirectPlayController(rig.env(), 'call-1', enabled: enabled);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('a pending connect', () {
    test('the room ending leaves no player and no held share', () async {
      final rig = Rig()..canSeeGate = Completer<void>();
      final c = _controller(rig);
      final started = c.onRoom(room(rig));
      await _settle();
      await c.onRoom(null);
      rig.canSeeGate!.complete();
      await started;
      await _settle();
      expect(rig.players, isEmpty);
      expect(rig.events, isNot(contains('hold:jelly')));
      expect(c.current.active, isFalse);
      expect(c.current.phase, DirectPlayPhase.off);
    });

    test('another title is not played, the new one is', () async {
      final rig = Rig()..canSeeGate = Completer<void>();
      final c = _controller(rig);
      final started = c.onRoom(room(rig));
      await _settle();
      final second = c.onRoom(room(rig, itemId: 'item-2'));
      rig.canSeeGate!.complete();
      await Future.wait([started, second]);
      await _settle();
      expect(rig.players, hasLength(1));
      expect(rig.player.openedUrl, contains('/Videos/item-2/'));
      expect(c.current.phase, DirectPlayPhase.playing);
    });

    test('disposing the controller leaves no player', () async {
      final rig = Rig()..canSeeGate = Completer<void>();
      final c = _controller(rig);
      final started = c.onRoom(room(rig));
      await _settle();
      c.dispose();
      rig.canSeeGate!.complete();
      await started;
      await _settle();
      expect(rig.players, isEmpty);
      expect(rig.events, isNot(contains('hold:jelly')));
    });

    test('a player opened as the controller goes is disposed', () async {
      final rig = Rig();
      final c = _controller(rig);
      final started = c.onRoom(room(rig));
      await _settle();
      c.dispose();
      await started;
      await _settle();
      for (final p in rig.players) {
        expect(p.disposed, isTrue);
      }
    });
  });

  group('the stored login', () {
    test('a refused token asks for a sign in and is forgotten', () async {
      final rig = Rig()..unauthorized = true;
      final c = _controller(rig);
      await c.onRoom(room(rig));
      await _settle();
      expect(c.current.phase, DirectPlayPhase.signIn);
      expect(c.current.notice, contains('sign-in expired'));
      expect(rig.forgotten, isTrue);
      expect(rig.players, isEmpty);
      expect(rig.events, isNot(contains('hold:jelly')));
    });

    test(
      'a signed-out viewer is not read from the key store per tick',
      () async {
        final rig = Rig(credential: false);
        final c = _controller(rig);
        await c.onRoom(room(rig));
        expect(c.current.phase, DirectPlayPhase.signIn);
        for (var i = 0; i < 5; i++) {
          await c.onRoom(room(rig));
        }
        expect(rig.credentialLoads, 1);
      },
    );

    test('a key store that throws falls back instead of throwing', () async {
      final rig = Rig()..loadError = StateError('locked');
      final c = _controller(rig);
      await c.onRoom(room(rig));
      expect(c.current.phase, DirectPlayPhase.off);
      expect(c.current.notice, contains('Back on the shared stream'));
      expect(rig.players, isEmpty);
    });
  });

  group('the sign-in sheet', () {
    test('a sheet dismissed mid-request does not start playing', () async {
      final rig = Rig(credential: false)..signInGate = Completer<void>();
      final c = _controller(rig, enabled: false);
      await c.onRoom(room(rig));
      await c.enable();
      expect(c.current.phase, DirectPlayPhase.signIn);
      final signing = c.signIn('nick', 'right');
      await _settle();
      c.cancelSignIn();
      rig.signInGate!.complete();
      await signing;
      await _settle();
      expect(rig.players, isEmpty);
      expect(rig.saved, isNull);
      expect(c.current.enabled, isFalse);
      expect(c.current.phase, DirectPlayPhase.off);
    });
  });

  group('while playing', () {
    Future<(Rig, DirectPlayController)> playing() async {
      final rig = Rig();
      final c = _controller(rig);
      await c.onRoom(room(rig));
      await _settle();
      return (rig, c);
    }

    test('a player that throws on every poll falls back after a few', () async {
      final (rig, c) = await playing();
      rig.player.position = const Duration(minutes: 5);
      rig.player.throwOnSeek = true;
      for (var i = 0; i < kDirectPlayStepFailures; i++) {
        await c.debugStep();
      }
      expect(c.current.phase, DirectPlayPhase.off);
      expect(c.current.notice, contains('Back on the shared stream'));
    });

    test('a slow poll is not overlapped by the next', () async {
      final (rig, c) = await playing();
      rig.player.position = const Duration(minutes: 5);
      rig.player.seekGate = Completer<void>();
      final first = c.debugStep();
      await _settle();
      await c.debugStep();
      rig.player.seekGate!.complete();
      await first;
      expect(rig.player.seeks, hasLength(1));
    });

    test(
      'the call ending stops the player and keeps the saved choice',
      () async {
        final (rig, c) = await playing();
        rig.enabledSaved = true;
        await c.stopForCallEnd();
        expect(rig.player.disposed, isTrue);
        expect(rig.events.last, 'release:jelly');
        expect(c.current.enabled, isTrue);
        expect(rig.enabledSaved, isTrue);
      },
    );
  });
}
