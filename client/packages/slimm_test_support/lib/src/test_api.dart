// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A [SlimmApi] wired to an in-memory HTTP client, with canned credentials.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';

/// The base URL every test api points at; nothing listens there.
final Uri fakeBaseUrl = Uri.parse('http://localhost:8080');

/// Credentials that stay valid for the length of any test.
const TokenPair fakeTokens = TokenPair(
  userId: 'u1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

/// A signed-in session holding [fakeTokens].
SessionStore fakeSession() => SessionStore(tokens: fakeTokens);

/// A [SlimmApi] whose requests are answered by [handler].
SlimmApi testApi(
  MockClientHandler handler, {
  SessionStore? session,
  Uri? baseUrl,
}) =>
    SlimmApi(
      baseUrl: baseUrl ?? fakeBaseUrl,
      session: session ?? fakeSession(),
      httpClient: MockClient(handler),
    );

/// A JSON response; a [String] body is sent as given.
http.Response jsonHttpResponse(Object? body, [int status = 200]) =>
    http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
