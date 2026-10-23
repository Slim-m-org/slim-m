// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the Spotify tokens live: this device's key store, never the
/// server, so slim-m's server holds no third-party credential (decision 0044).
///
/// Beside the tokens sit the display name shown as "Connected as", and the
/// pending link (verifier and state), so a redirect that arrives after the
/// app was killed in the browser can still finish the sign-in.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show PlatformException;
import 'package:slimm_platform/platform.dart';

import 'spotify_client.dart';
import 'package:slimm_api/api.dart' show LogTag, reportFailure;

const spotifyTokensHandle = 'slimm.spotify.tokens';
const spotifyBackgroundTokensHandle = 'slimm.spotify.tokens.bg';
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

/// iOS refuses a keychain read while the phone is locked (-25308).
bool isKeychainLocked(Object error) =>
    error is PlatformException &&
    (error.message?.contains('-25308') == true ||
        error.message?.contains('User interaction is not allowed') == true ||
        error.code.contains('-25308'));

class SpotifyTokenStore {
  /// [background], when given, holds the tokens readable after first unlock;
  /// tokens an earlier build left in [_keys] move there on the first read.
  SpotifyTokenStore(this._keys, {KeyStore? background})
    : _background = background == null || identical(background, _keys)
          ? null
          : background;

  final KeyStore _keys;
  final KeyStore? _background;

  KeyStore get _tokenStore => _background ?? _keys;
  String get _tokensHandle =>
      _background == null ? spotifyTokensHandle : spotifyBackgroundTokensHandle;

  Future<String?> _readTokens() async {
    final raw = await _tokenStore.read(_tokensHandle);
    if (raw != null || _background == null) return raw;
    final legacy = await _keys.read(spotifyTokensHandle);
    if (legacy == null) return null;
    await _background.put(_tokensHandle, legacy);
    await _keys.delete(spotifyTokensHandle);
    return legacy;
  }

  Future<SpotifyTokens?> load() async {
    final raw = await _readTokens();
    if (raw == null) return null;
    try {
      return SpotifyTokens.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object catch (error, stack) {
      reportFailure(
        LogTag.data,
        'read the saved Spotify sign-in',
        error,
        stack,
      );
      await clear();
      return null;
    }
  }

  Future<void> save(SpotifyTokens tokens) =>
      _tokenStore.put(_tokensHandle, jsonEncode(tokens.toJson()));

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
      reportFailure(LogTag.data, 'read the pending Spotify link', error, stack);
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
    await _background?.delete(spotifyBackgroundTokensHandle);
    await _keys.delete(spotifyAccountHandle);
    await clearPending();
  }
}
