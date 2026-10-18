// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the Spotify tokens live: this device's key store, never the
/// server, so slim-m's server holds no third-party credential (decision 0044).
///
/// Beside the tokens sit the display name shown as "Connected as", and the
/// pending link (verifier and state), so a redirect that arrives after the
/// app was killed in the browser can still finish the sign-in.
library;

import 'dart:convert';

import 'package:slimm_platform/platform.dart';

import 'spotify_client.dart';
import 'package:slimm_api/api.dart' show LogTag, reportFailure;

const spotifyTokensHandle = 'slimm.spotify.tokens';
const spotifyAccountHandle = 'slimm.spotify.account';
const spotifyPendingHandle = 'slimm.spotify.pending';

/// A link started but not yet finished by its redirect.
class SpotifyPendingLink {
  const SpotifyPendingLink({
    required this.verifier,
    required this.state,
    required this.startedAt,
  });

  factory SpotifyPendingLink.fromJson(Map<String, dynamic> json) =>
      SpotifyPendingLink(
        verifier: json['verifier'] as String,
        state: json['state'] as String,
        startedAt: DateTime.fromMillisecondsSinceEpoch(json['at'] as int),
      );

  final String verifier;
  final String state;
  final DateTime startedAt;

  Map<String, dynamic> toJson() => {
    'verifier': verifier,
    'state': state,
    'at': startedAt.millisecondsSinceEpoch,
  };
}

class SpotifyTokenStore {
  SpotifyTokenStore(this._keys);

  final KeyStore _keys;

  Future<SpotifyTokens?> load() async {
    final raw = await _keys.read(spotifyTokensHandle);
    if (raw == null) return null;
    try {
      return SpotifyTokens.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object catch (error, stack) {
      reportFailure(LogTag.data, 'load', error, stack);
      await clear();
      return null;
    }
  }

  Future<void> save(SpotifyTokens tokens) =>
      _keys.put(spotifyTokensHandle, jsonEncode(tokens.toJson()));

  Future<String?> loadAccount() => _keys.read(spotifyAccountHandle);

  Future<void> saveAccount(String name) =>
      _keys.put(spotifyAccountHandle, name);

  Future<SpotifyPendingLink?> loadPending() async {
    final raw = await _keys.read(spotifyPendingHandle);
    if (raw == null) return null;
    try {
      return SpotifyPendingLink.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on Object catch (error, stack) {
      reportFailure(LogTag.data, 'load pending', error, stack);
      await clearPending();
      return null;
    }
  }

  Future<void> savePending(SpotifyPendingLink pending) =>
      _keys.put(spotifyPendingHandle, jsonEncode(pending.toJson()));

  Future<void> clearPending() => _keys.delete(spotifyPendingHandle);

  /// Forgets the link entirely: tokens, name and any attempt in flight.
  Future<void> clear() async {
    await _keys.delete(spotifyTokensHandle);
    await _keys.delete(spotifyAccountHandle);
    await clearPending();
  }
}
