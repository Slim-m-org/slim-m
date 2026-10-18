// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the linked Spotify account is playing, on any device, as a
/// [NowPlayingSource]. Polled only while someone listens, so a switched-off
/// or hidden device makes no Spotify request at all.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:slimm_platform/platform.dart';

import 'spotify_client.dart';
import 'spotify_token_store.dart';
import 'package:slimm_api/api.dart' show LogTag, reportFailure;

const _defaultPollInterval = Duration(seconds: 10);
const _refreshMargin = Duration(seconds: 60);

class SpotifyNowPlayingSource implements NowPlayingSource {
  SpotifyNowPlayingSource({
    required SpotifyClient client,
    required SpotifyTokenStore store,
    Duration pollInterval = _defaultPollInterval,
    DateTime Function()? now,
    Future<void> Function()? onRevoked,
  }) : _client = client,
       _store = store,
       _onRevoked = onRevoked,
       _pollInterval = pollInterval,
       _now = now ?? DateTime.now;

  final SpotifyClient _client;
  final SpotifyTokenStore _store;
  final Duration _pollInterval;
  final DateTime Function() _now;
  final Future<void> Function()? _onRevoked;
  DateTime? _backoffUntil;

  @override
  Stream<NowPlaying?> watch() =>
      polledStream<NowPlaying>(interval: _pollInterval, read: _read);

  Future<NowPlaying?> _read() async {
    final until = _backoffUntil;
    if (until != null && _now().isBefore(until)) throw const PollSkip();
    try {
      return await _readPlayback();
    } on http.ClientException {
      throw const PollSkip();
    } on TimeoutException {
      throw const PollSkip();
    }
  }

  Future<NowPlaying?> _readPlayback() async {
    var tokens = await _store.load();
    if (tokens == null) return null;
    if (tokens.expiresWithin(_refreshMargin, _now())) {
      tokens = await _refresh(tokens);
      if (tokens == null) return null;
    }
    var playback = await _client.currentlyPlaying(tokens.accessToken);
    if (playback is SpotifyUnauthorized) {
      tokens = await _refresh(tokens);
      if (tokens == null) return null;
      playback = await _client.currentlyPlaying(tokens.accessToken);
    }
    switch (playback) {
      case SpotifyPlaying(:final title, :final artist, :final artUrl):
        return NowPlaying(
          title: title,
          artist: artist,
          source: 'Spotify',
          artUrl: artUrl,
        );
      case SpotifyRateLimited(:final retryAfter):
        _backoffUntil = _now().add(retryAfter);
        throw const PollSkip();
      case SpotifyIdle() || SpotifyUnauthorized():
        return null;
    }
  }

  /// A refused refresh means the link was revoked, so the token is dropped
  /// rather than retried forever.
  Future<SpotifyTokens?> _refresh(SpotifyTokens tokens) async {
    try {
      final fresh = await _client.refresh(tokens.refreshToken);
      await _store.save(fresh);
      return fresh;
    } on SpotifyAuthException catch (error, stack) {
      reportFailure(LogTag.ui, 'refresh', error, stack);
      await _store.clear();
      await _onRevoked?.call();
      return null;
    }
  }
}
