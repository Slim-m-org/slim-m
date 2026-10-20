// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Voice tokens minted ahead of the click, so a join does not wait for the
/// server round trip.
///
/// A token is held for [ttl] and handed out once. The server's own token
/// lives four times longer; the short hold bounds how stale the permissions it
/// carries can be, and keeps the client clock out of the question.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

typedef VoiceTokenFetch = Future<api.VoiceToken> Function(String channelId);

class _Held {
  _Held(this.mintedAt, this.token) {
    token.then<void>((_) {}, onError: (_) => failed = true);
  }

  final DateTime mintedAt;
  final Future<api.VoiceToken> token;
  bool failed = false;
}

class VoiceTokenPrefetch {
  VoiceTokenPrefetch(
    this._fetch, {
    DateTime Function()? now,
    this.ttl = const Duration(seconds: 30),
  }) : _now = now ?? DateTime.now;

  static const _capacity = 3;

  final VoiceTokenFetch _fetch;
  final DateTime Function() _now;

  /// How long a minted token may wait for its click.
  final Duration ttl;

  final _held = <String, _Held>{};

  /// Starts minting a token for [channelId] unless one is held or on its way.
  /// A refusal is remembered for [ttl] too, so a hover over a channel the
  /// member cannot join does not ask again on every pass.
  void prefetch(String channelId) {
    final held = _held[channelId];
    if (held != null && !_stale(held)) return;
    _held.remove(channelId);
    while (_held.length >= _capacity) {
      _held.remove(_held.keys.first);
    }
    _held[channelId] = _Held(_now(), _fetch(channelId));
  }

  /// The token for a join: the prefetched one when it is still good, else a
  /// fresh request, which is also where a refusal reports itself.
  Future<api.VoiceToken> claim(String channelId) async {
    final held = _held.remove(channelId);
    if (held != null && !held.failed && !_stale(held)) {
      try {
        return await held.token;
      } on Object catch (error, stack) {
        api.AppLog.swallowed(
          api.LogTag.voice,
          'Prefetched voice token failed; asking again',
          error,
          stack,
        );
      }
    }
    return _fetch(channelId);
  }

  bool _stale(_Held held) => _now().difference(held.mintedAt) > ttl;
}

final voiceTokenPrefetchProvider = Provider<VoiceTokenPrefetch>((ref) {
  final api = ref.watch(apiProvider);
  return VoiceTokenPrefetch(api.voiceToken);
});
