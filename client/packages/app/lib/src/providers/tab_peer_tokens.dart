// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shares a cookie session's access token between browser tabs over a BroadcastChannel (decision 0141).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_platform/platform.dart';

/// The line every tab of this profile talks on.
final tabChannelProvider = Provider<TabChannel>(
  (ref) => TabChannel('slimm.session'),
);

class TabPeerTokens implements PeerTokens {
  TabPeerTokens(
    this._channel, {
    required this.held,
    required this.onAnnounced,
    required this.isActive,
    required this.anotherTabOpen,
    this.wait = const Duration(milliseconds: 400),
  }) {
    _hearing = _channel.messages.listen(_hear);
  }

  final TabChannel _channel;

  /// This tab's own pair, to answer a peer that asks.
  final TokenPair? Function() held;

  /// Called with each pair a peer announces, so the store can take it up.
  final void Function(TokenPair announced) onAnnounced;

  /// False outside the cookie mode, where a peer's access token says nothing about this tab's session.
  final bool Function() isActive;

  /// Whether any other tab is open to answer, so a lone tab never waits for nobody.
  final Future<bool> Function() anotherTabOpen;

  final Duration wait;
  late final StreamSubscription<String> _hearing;
  TokenPair? _newest;
  Completer<TokenPair?>? _asking;

  @override
  TokenPair? get newest => isActive() ? _newest : null;

  @override
  void announce(TokenPair tokens) {
    if (isActive()) _channel.post(_encode('token', tokens));
  }

  @override
  Future<TokenPair?> ask() async {
    final own = held();
    if (!isActive() || own == null || !await anotherTabOpen()) return null;
    final asking = _asking ??= Completer<TokenPair?>();
    _channel.post(jsonEncode({'t': 'ask', 'user_id': own.userId}));
    final answer = await asking.future.timeout(wait, onTimeout: () => null);
    _asking = null;
    return answer;
  }

  Future<void> dispose() => _hearing.cancel();

  void _hear(String raw) {
    if (!isActive()) return;
    try {
      final message = jsonDecode(raw) as Map<String, dynamic>;
      switch (message['t']) {
        case 'ask':
          final own = held();
          if (own != null &&
              own.hasAccessToken &&
              message['user_id'] == own.userId) {
            _channel.post(_encode('token', own));
          }
        case 'token':
          final pair = TokenPair.fromAccessJson(message);
          if (pair.userId != held()?.userId) return;
          _newest = pair;
          _asking?.complete(pair);
          onAnnounced(pair);
      }
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.auth,
        'Ignored an unreadable message from another tab',
        error,
        stack,
      );
    }
  }

  String _encode(String kind, TokenPair pair) =>
      jsonEncode({'t': kind, ...pair.toAccessJson()});
}
