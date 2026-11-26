// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two browser tabs of one cookie session pass the access token a rotation minted over a BroadcastChannel.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/tab_peer_tokens.dart';
import 'package:slimm_platform/platform.dart';

/// Both ends of one channel: each end hears what the other posts, never its own.
class _Line {
  final _a = StreamController<String>.broadcast(sync: true);
  final _b = StreamController<String>.broadcast(sync: true);
  late final TabChannel first = _End(_a, _b);
  late final TabChannel second = _End(_b, _a);
}

class _End implements TabChannel {
  _End(this._hears, this._says);

  final StreamController<String> _hears;
  final StreamController<String> _says;

  @override
  Stream<String> get messages => _hears.stream;

  @override
  void post(String message) => _says.add(message);
}

final _soon = DateTime.now().millisecondsSinceEpoch + 600000;

TokenPair _pair(String access, {int? expires}) => TokenPair(
  userId: 'u1',
  accessToken: access,
  refreshToken: '',
  accessExpiresAt: expires ?? _soon,
);

({TabPeerTokens peers, SessionStore store}) _tab(
  TabChannel channel,
  TokenPair held, {
  bool active = true,
}) {
  late SessionStore store;
  final peers = TabPeerTokens(
    channel,
    held: () => store.tokens,
    onAnnounced: (pair) => store.takeUpPeerToken(pair),
    isActive: () => active,
    anotherTabOpen: () async => true,
    wait: const Duration(milliseconds: 50),
  );
  store = SessionStore(tokens: held, peers: peers);
  return (peers: peers, store: store);
}

void main() {
  test('a rotation in one tab replaces the access token in the other', () {
    final line = _Line();
    final a = _tab(line.first, _pair('old', expires: 1));
    final b = _tab(line.second, _pair('old', expires: 1));

    a.peers.announce(_pair('fresh'));

    expect(b.peers.newest?.accessToken, 'fresh');
    expect(b.store.tokens?.accessToken, 'fresh');
    expect(a.store.tokens?.accessToken, 'old', reason: 'A set its own');
  });

  test('a tab with no live token is answered by a tab that has one', () async {
    final line = _Line();
    _tab(line.first, _pair('live'));
    final fresh = _tab(line.second, TokenPair.signedInHint('u1'));

    final answer = await fresh.peers.ask();

    expect(answer?.accessToken, 'live');
  });

  test('asking with nobody there gives up quickly', () async {
    final line = _Line();
    final lone = _tab(line.second, TokenPair.signedInHint('u1'));

    expect(await lone.peers.ask(), isNull);
  });

  test('an announcement for another account is not taken up', () {
    final line = _Line();
    final a = _tab(line.first, _pair('x'));
    final b = _tab(line.second, _pair('old', expires: 1));

    a.peers.announce(
      TokenPair(
        userId: 'u2',
        accessToken: 'theirs',
        refreshToken: '',
        accessExpiresAt: _soon,
      ),
    );

    expect(b.store.tokens?.accessToken, 'old');
  });

  test('outside cookie mode nothing is announced, heard or answered', () async {
    final line = _Line();
    final a = _tab(line.first, _pair('x'), active: false);
    final b = _tab(line.second, _pair('old', expires: 1), active: false);

    a.peers.announce(_pair('fresh'));

    expect(b.peers.newest, isNull);
    expect(b.store.tokens?.accessToken, 'old');
    expect(await b.peers.ask(), isNull);
  });

  test('an inactive tab announces nothing to an active one', () {
    final line = _Line();
    final quiet = _tab(line.first, _pair('x'), active: false);
    final listening = _tab(line.second, _pair('old', expires: 1));

    quiet.peers.announce(_pair('fresh'));

    expect(listening.store.tokens?.accessToken, 'old');
  });

  test('a refresh token smuggled into a message is dropped', () {
    final line = _Line();
    final b = _tab(line.second, _pair('old', expires: 1));

    line.first.post(
      '{"t":"token","user_id":"u1","access_token":"fresh",'
      '"access_expires_at":$_soon,"refresh_token":"stolen"}',
    );

    expect(b.store.tokens?.accessToken, 'fresh');
    expect(b.store.tokens?.carriesRefreshToken, isFalse);
    expect(b.peers.newest?.carriesRefreshToken, isFalse);
  });

  test(
    'asks and answers name the account, and another account is ignored',
    () async {
      final line = _Line();
      final other = _tab(
        line.first,
        TokenPair(
          userId: 'u2',
          accessToken: 'theirs',
          refreshToken: '',
          accessExpiresAt: _soon,
        ),
      );
      final mine = _tab(line.second, TokenPair.signedInHint('u1'));
      final answers = <String>[];
      final listening = line.second.messages.listen(answers.add);
      addTearDown(listening.cancel);

      expect(
        await mine.peers.ask(),
        isNull,
        reason: 'u2 does not answer for u1',
      );
      expect(answers, isEmpty, reason: 'nothing was posted back at all');
      other.peers.announce(
        TokenPair(
          userId: 'u2',
          accessToken: 'theirs-2',
          refreshToken: '',
          accessExpiresAt: _soon,
        ),
      );
      expect(mine.peers.newest, isNull);
    },
  );

  test('a lone tab asks nobody and does not wait', () async {
    final line = _Line();
    final posted = <String>[];
    final listening = line.second.messages.listen(posted.add);
    addTearDown(listening.cancel);
    final peers = TabPeerTokens(
      line.first,
      held: () => TokenPair.signedInHint('u1'),
      onAnnounced: (_) {},
      isActive: () => true,
      anotherTabOpen: () async => false,
      wait: const Duration(seconds: 30),
    );
    addTearDown(peers.dispose);

    expect(await peers.ask(), isNull);
    expect(posted, isEmpty);
  });

  test('a garbled message from another tab is ignored', () {
    final line = _Line();
    final b = _tab(line.second, _pair('old', expires: 1));

    line.first.post('not json');

    expect(b.store.tokens?.accessToken, 'old');
  });
}
