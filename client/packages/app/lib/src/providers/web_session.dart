// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a browser tab keeps its sign-in (decision 0141): the server's HttpOnly cookie, never storage.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import 'providers.dart';

/// How this run keeps its session.
enum WebSessionMode {
  /// Desktop and phones: the pair in the platform key store, as always.
  native,

  /// A browser on its own server over a secure context: the refresh token is an HttpOnly cookie and only the account id is stored.
  cookie,

  /// Any other browser case (a plain-http address, another origin): nothing is stored, so a reload signs in again.
  memory,
}

/// The mode for a client reaching [server] from a page at [page].
///
/// A SameSite=Strict cookie only travels to the page's own origin, and a browser only keeps a Secure one over https.
WebSessionMode webSessionModeFor(Uri server, {bool isWeb = kIsWeb, Uri? page}) {
  if (!isWeb) return WebSessionMode.native;
  final at = page ?? Uri.base;
  final sameOrigin =
      server.scheme == at.scheme &&
      server.host == at.host &&
      server.port == at.port;
  return sameOrigin && _isSecureContext(at)
      ? WebSessionMode.cookie
      : WebSessionMode.memory;
}

/// https only: Safari does not keep a Secure cookie from http://localhost, so loopback falls back to [WebSessionMode.memory].
bool _isSecureContext(Uri page) => page.scheme == 'https';

final webSessionModeProvider = Provider<WebSessionMode>(
  (ref) => webSessionModeFor(ref.watch(serverUrlProvider)),
);

/// What goes under a session's key-store handle, or null when nothing may.
String? sessionToStore(WebSessionMode mode, TokenPair tokens) => switch (mode) {
  WebSessionMode.native => jsonEncode(tokens.toJson()),
  WebSessionMode.cookie => jsonEncode(tokens.toHintJson()),
  WebSessionMode.memory => null,
};

/// The session to resume from [stored], or null when this mode keeps none and [stored] is a leftover to delete.
TokenPair? sessionFromStored(WebSessionMode mode, String stored) {
  if (mode == WebSessionMode.memory) return null;
  return TokenPair.fromStoredJson(jsonDecode(stored) as Map<String, dynamic>);
}

/// Moves a pair stored before the cookie existed into the cookie, by spending its refresh token once.
///
/// The set that restored it already replaced the stored pair with the account id alone.
void moveStoredPairToCookie(ProviderContainer container, TokenPair restored) {
  if (container.read(webSessionModeProvider) != WebSessionMode.cookie) return;
  if (!restored.carriesRefreshToken) return;
  unawaited(
    container.read(apiProvider).refresh().then((_) {}, onError: (Object _) {}),
  );
}
