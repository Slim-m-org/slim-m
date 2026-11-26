// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a web client keeps its sign-in in an HttpOnly cookie: naming the flow, and refreshing through it (decision 0141).
library;

import 'package:http/http.dart' as http;

import 'client.dart';
import 'exceptions.dart';

/// Set to `cookie` by a web client whose refresh token lives in an HttpOnly cookie.
const _webSessionHeader = 'x-slimm-web-session';

/// Names the account whose cookie a web client's refresh reads.
const _webAccountHeader = 'x-slimm-account';

extension SlimmApiWebSession on SlimmApi {
  /// Rotates the session for a 401 on a call sent with [sentWith], unless another call already did.
  ///
  /// Rotating again would void the token that call minted, so a late 401 only replays.
  ///
  /// Throws [UnauthorizedException] when the session now belongs to an account other than [sentBy], so a call
  /// issued by one account is never replayed, or its refresh spent, under another's.
  Future<void> refreshUnlessRotated(String? sentWith, {String? sentBy}) async {
    requireSameAccount(sentBy);
    if (session.tokens?.accessToken == sentWith) await refresh();
    requireSameAccount(sentBy);
  }

  /// Refreshes through the cookie before the first call of a web tab that holds only its sign-in hint.
  ///
  /// Every caller waits on the one refresh in flight, so a cold load spends no 401 finding out the token is missing.
  /// Null when nothing is needed, so a caller does not give up a turn of the event loop on every request.
  Future<void>? ensureAccessToken() {
    final held = session.tokens;
    if (!webSession || held == null || held.hasAccessToken) return null;
    return _refreshForHint(held.userId);
  }

  Future<void> _refreshForHint(String userId) async {
    await awaitTrust();
    await refresh();
    requireSameAccount(userId);
  }

  /// Fails when the session now belongs to an account other than [sentBy].
  void requireSameAccount(String? sentBy) {
    if (session.tokens?.userId != sentBy) {
      throw const UnauthorizedException('the signed-in account changed');
    }
  }

  /// Tells the server this tab is on the cookie flow, and which account's cookie a refresh reads.
  void nameCookieFlow(http.Request request) {
    request.headers[_webSessionHeader] = 'cookie';
    if (request.url.path != '/auth/refresh') return;
    if (session.tokens?.userId case final account?) {
      request.headers[_webAccountHeader] = account;
    }
  }
}
