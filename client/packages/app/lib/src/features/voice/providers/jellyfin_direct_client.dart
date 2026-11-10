// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// This device's own conversation with the media server for direct play: can
/// it be reached, who is the viewer there, and can they see the title.
///
/// The bot never hands out a credential (decision 0050 section 4 kept the
/// admin key on the bot host), so the viewer signs in with their own account
/// and the token stays on this device. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Thrown when the media server turns down a sign-in.
class JellyfinSignInRefused implements Exception {
  const JellyfinSignInRefused();
}

class JellyfinSession {
  const JellyfinSession({required this.token, required this.userId});

  final String token;
  final String userId;
}

class JellyfinDirectClient {
  JellyfinDirectClient(this._http, {required this.deviceId});

  final http.Client _http;
  final String deviceId;

  static const Duration _timeout = Duration(seconds: 4);

  String _auth([String? token]) =>
      'MediaBrowser ${token == null ? '' : 'Token="$token", '}'
      'Client="slim-m", Device="slim-m", DeviceId="$deviceId", Version="1"';

  /// Whether the media server answers at [baseUrl] from this device.
  Future<bool> reachable(String baseUrl) async {
    try {
      final response = await _http
          .get(Uri.parse('$baseUrl/System/Info/Public'))
          .timeout(_timeout);
      return response.statusCode == 200;
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'The media server did not answer; treated as unreachable',
        error,
        stack,
      );
      return false;
    }
  }

  Future<JellyfinSession> signIn(
    String baseUrl, {
    required String username,
    required String password,
  }) async {
    final response = await _http
        .post(
          Uri.parse('$baseUrl/Users/AuthenticateByName'),
          headers: {
            'authorization': _auth(),
            'content-type': 'application/json',
          },
          body: jsonEncode({'Username': username, 'Pw': password}),
        )
        .timeout(_timeout);
    if (response.statusCode == 401 || response.statusCode == 400) {
      throw const JellyfinSignInRefused();
    }
    if (response.statusCode != 200) {
      throw http.ClientException(
        'The media server answered ${response.statusCode}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return JellyfinSession(
      token: json['AccessToken'] as String,
      userId: (json['User'] as Map<String, dynamic>)['Id'] as String,
    );
  }

  /// Whether the signed-in account's library holds [itemId]; false on a 404, an error otherwise.
  Future<bool> canSee(
    String baseUrl,
    JellyfinSession session,
    String itemId,
  ) async {
    final response = await _http
        .get(
          Uri.parse('$baseUrl/Users/${session.userId}/Items/$itemId'),
          headers: {'authorization': _auth(session.token)},
        )
        .timeout(_timeout);
    if (response.statusCode == 200) return true;
    if (response.statusCode == 404) return false;
    throw http.ClientException(
      'The media server answered ${response.statusCode}',
    );
  }

  /// The original file, untranscoded, and the header that authorises it.
  ({String url, Map<String, String> headers}) original(
    String baseUrl,
    JellyfinSession session,
    String itemId,
  ) => (
    url: '$baseUrl/Videos/$itemId/stream?static=true',
    headers: {'authorization': _auth(session.token)},
  );
}
