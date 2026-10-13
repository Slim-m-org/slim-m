// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Linking and unlinking a Spotify account from the one Settings switch
/// (decisions 0044 and 0056).
///
/// The switch is the link: turning it on sends the person to Spotify and
/// only lands on when the redirect has been exchanged for tokens, turning it
/// off deletes what is stored on this device. The redirect is handled by the
/// deep-link controller, not by a future waiting in this process, so it
/// finishes the same way after a cold start. Spotify has no revoke call, so
/// Settings points at spotify.com/account/apps for removing slim-m there.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_platform/platform.dart';

import '../providers/activity_sharing_settings.dart';
import '../providers/providers.dart';
import 'spotify_client.dart';
import 'spotify_config.dart';
import 'spotify_launch.dart';
import 'spotify_link_status.dart';
import 'spotify_pkce.dart';
import 'spotify_source.dart';
import 'spotify_token_store.dart';

const shareSpotifyKey = 'slimm.presence.share_spotify';
const _exchangeTimeout = Duration(seconds: 20);

final spotifyTokenStoreProvider = Provider<SpotifyTokenStore>(
  (ref) => SpotifyTokenStore(ref.read(keyStoreProvider)),
);

final spotifyClientProvider = Provider<SpotifyClient>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return SpotifyClient(
    client: client,
    clientId: ref.read(spotifyClientIdProvider),
  );
});

final spotifySourceProvider = Provider<NowPlayingSource>(
  (ref) => SpotifyNowPlayingSource(
    client: ref.read(spotifyClientProvider),
    store: ref.read(spotifyTokenStoreProvider),
    onRevoked: () => ref.read(spotifyLinkerProvider).revoked(),
  ),
);

/// Opens Spotify's consent page, in the Spotify app when it claims the link.
/// Overridden in tests.
final spotifyLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) => openSpotifyAuthorize,
);

/// How long a started link stays valid, for the in-app wait and for a
/// redirect that arrives after a restart. Overridden in tests.
final spotifyLinkTimeoutProvider = Provider<Duration>(
  (ref) => const Duration(minutes: 10),
);

/// Shown in Settings under the Spotify switch. Starts from the stored link so
/// a restart still says who is connected.
final spotifyLinkStatusProvider =
    StateNotifierProvider<SpotifyLinkStatusController, SpotifyLinkStatus>((
      ref,
    ) {
      final controller = SpotifyLinkStatusController(const SpotifyUnlinked());
      final store = ref.read(spotifyTokenStoreProvider);
      unawaited(() async {
        if (await store.load() == null) return;
        controller.set(SpotifyConnected(await store.loadAccount()));
      }());
      return controller;
    });

class SpotifyLinker {
  SpotifyLinker(this._ref) {
    _ref.onDispose(() => _timer?.cancel());
  }

  final Ref _ref;
  Timer? _timer;

  SpotifyLinkStatusController get _status =>
      _ref.read(spotifyLinkStatusProvider.notifier);
  SpotifyTokenStore get _store => _ref.read(spotifyTokenStoreProvider);

  /// Sends the person to Spotify. Returns once the browser is open; the
  /// redirect finishes the link through [handleCallback].
  Future<void> begin() async {
    final clientId = _ref.read(spotifyClientIdProvider);
    if (clientId.isEmpty) return;
    final verifier = randomUrlSafe();
    final state = randomUrlSafe(32);
    _status.set(const SpotifyWaiting());
    await _store.savePending(
      SpotifyPendingLink(
        verifier: verifier,
        state: state,
        startedAt: DateTime.now(),
      ),
    );
    final uri = spotifyAuthorizeUri(
      clientId: clientId,
      challenge: await codeChallenge(verifier),
      state: state,
    );
    if (!await _launch(uri)) {
      await _store.clearPending();
      _fail('Could not open the browser to sign in to Spotify.');
      return;
    }
    _timer?.cancel();
    _timer = Timer(_ref.read(spotifyLinkTimeoutProvider), _expire);
  }

  Future<bool> _launch(Uri uri) async {
    try {
      return await _ref.read(spotifyLauncherProvider)(uri);
    } on Object {
      return false;
    }
  }

  /// Finishes the link from Spotify's redirect, whatever state the app is in.
  /// True when a link was completed.
  Future<bool> handleCallback(Uri uri) async {
    _timer?.cancel();
    final pending = await _store.loadPending();
    if (pending == null) return _strayCallback();
    await _store.clearPending();
    final timeout = _ref.read(spotifyLinkTimeoutProvider);
    if (DateTime.now().difference(pending.startedAt) > timeout) {
      _fail(_expired);
      return false;
    }
    final params = uri.queryParameters;
    if (params['state'] != pending.state) {
      _fail('That Spotify sign-in did not match this device. Try again.');
      return false;
    }
    if (params.containsKey('error')) {
      _fail('Spotify sign-in was declined. Try again if that was a slip.');
      return false;
    }
    final code = params['code'];
    if (code == null || code.isEmpty) {
      _fail('Spotify did not send a sign-in code. Try again.');
      return false;
    }
    return _complete(code, pending.verifier);
  }

  static const _expired = 'That Spotify sign-in expired. Try again.';

  /// A redirect nobody here asked for. Harmless while linked; otherwise the
  /// person is told why nothing happened.
  Future<bool> _strayCallback() async {
    if (await _store.load() != null) return false;
    _fail(_expired);
    return false;
  }

  Future<bool> _complete(String code, String verifier) async {
    _status.set(const SpotifyConnecting());
    try {
      final client = _ref.read(spotifyClientProvider);
      final tokens = await client
          .exchangeCode(code, verifier)
          .timeout(_exchangeTimeout);
      await _store.save(tokens);
      final name = await _profileName(client, tokens.accessToken);
      if (name != null) await _store.saveAccount(name);
      _status.set(SpotifyConnected(name));
      await _ref.read(shareSpotifyProvider.notifier).markLinked();
      return true;
    } on SpotifyAuthException catch (e) {
      _fail('Spotify did not link: ${e.message}.');
    } on TimeoutException {
      _fail('Spotify took too long to answer. Try again.');
    } on http.ClientException {
      _fail('Could not reach Spotify. Check the connection and retry.');
    } on Object {
      _fail('Spotify sent a reply this app could not read. Try again.');
    }
    return false;
  }

  Future<String?> _profileName(SpotifyClient client, String token) async {
    try {
      return await client.profileName(token).timeout(_exchangeTimeout);
    } on Object {
      return null;
    }
  }

  Future<void> _expire() async {
    if (_ref.read(spotifyLinkStatusProvider) is! SpotifyWaiting) return;
    await _store.clearPending();
    _fail('Spotify sign-in timed out. Try again.');
  }

  void _fail(String message) {
    _status.set(SpotifyFailed(message));
  }

  /// Gives up on a link that is waiting for the browser.
  Future<void> cancel() async {
    _timer?.cancel();
    await _store.clearPending();
    _status.set(const SpotifyUnlinked());
  }

  Future<void> unlink() async {
    _timer?.cancel();
    await _store.clear();
    _status.set(const SpotifyUnlinked());
  }

  /// Spotify refused the stored grant: the person removed slim-m there.
  Future<void> revoked() async {
    await _ref.read(shareSpotifyProvider.notifier).markUnlinked();
    _fail('Spotify no longer lets slim-m read your track. Link it again.');
  }

  /// Clears an error and returns to what is true without it.
  Future<void> dismissFailure() async {
    final linked = await _store.load() != null;
    _status.dismissFailure(linked: linked, name: await _store.loadAccount());
  }
}

final spotifyLinkerProvider = Provider<SpotifyLinker>(SpotifyLinker.new);

class SpotifySwitchController extends ActivitySwitchController {
  SpotifySwitchController(this._ref) : super(_ref, shareSpotifyKey);

  final Ref _ref;

  /// On starts the browser step and stays off until the redirect has been
  /// exchanged; [markLinked] is what turns it on.
  @override
  Future<void> setEnabled(bool enabled) async {
    final linker = _ref.read(spotifyLinkerProvider);
    if (enabled) {
      final status = _ref.read(spotifyLinkStatusProvider);
      if (status is SpotifyWaiting || status is SpotifyConnecting) return;
      await linker.begin();
      return;
    }
    await linker.unlink();
    await super.setEnabled(false);
  }

  Future<void> markLinked() => super.setEnabled(true);

  /// Off without touching the stored link, for a grant Spotify withdrew.
  Future<void> markUnlinked() async {
    await _ref.read(spotifyTokenStoreProvider).clear();
    await super.setEnabled(false);
  }
}

final shareSpotifyProvider =
    StateNotifierProvider<SpotifySwitchController, bool>(
      SpotifySwitchController.new,
    );
