// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An in-memory slim-m server that answers by method and path.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';

import 'test_api.dart';

/// A request the fake server received, with its route parameters bound.
class FakeRequest {
  FakeRequest(this.method, this.url, this.params, this.body);

  final String method;
  final Uri url;

  /// Values bound by `:name` segments of the matched route.
  final Map<String, String> params;
  final String body;

  String get path => url.path;

  /// The body decoded as JSON, or null when there is none.
  Object? get json => body.isEmpty ? null : jsonDecode(body);
}

/// What a route answers with.
class FakeReply {
  FakeReply.json(Object? body, {this.status = 200})
      : body = body is String ? body : jsonEncode(body);

  FakeReply.status(this.status) : body = '';

  final int status;
  final String body;
}

typedef FakeHandler = FutureOr<FakeReply> Function(FakeRequest request);

class _Route {
  _Route(this.method, this.segments, this.handler);

  final String method;
  final List<String> segments;
  final FakeHandler handler;

  Map<String, String>? match(String requestMethod, List<String> requested) {
    if (requestMethod != method || requested.length != segments.length) {
      return null;
    }
    final params = <String, String>{};
    for (var i = 0; i < segments.length; i++) {
      final want = segments[i];
      if (want.startsWith(':')) {
        params[want.substring(1)] = requested[i];
      } else if (want != requested[i]) {
        return null;
      }
    }
    return params;
  }
}

/// Routes `METHOD /path/:param` to JSON fixtures or handlers.
///
/// A request no route matches is recorded in [unmatched] and answered 404, so
/// a test can assert nothing unexpected was called. The newest route wins, so
/// a test can override a default set up by a shared fixture.
class FakeSlimmServer {
  final List<_Route> _routes = [];

  /// Every request received, in order.
  final List<FakeRequest> requests = [];

  /// The requests no route answered.
  final List<FakeRequest> unmatched = [];

  void on(String method, String path, FakeHandler handler) {
    _routes.insert(0, _Route(method.toUpperCase(), _split(path), handler));
  }

  /// Answers `[method] [path]` with the fixed JSON [body].
  void respond(String method, String path, Object? body, {int status = 200}) =>
      on(method, path, (_) => FakeReply.json(body, status: status));

  /// The requests received for `[method] [path]`; `:name` matches any segment.
  List<FakeRequest> requestsTo(String method, String path) {
    final route = _Route(
        method.toUpperCase(), _split(path), (_) => FakeReply.status(200));
    return [
      for (final request in requests)
        if (route.match(request.method, _split(request.path)) != null) request,
    ];
  }

  http.Client get client => MockClient(_answer);

  /// A [SlimmApi] backed by this server.
  SlimmApi api({SessionStore? session, Uri? baseUrl}) => SlimmApi(
        baseUrl: baseUrl ?? fakeBaseUrl,
        session: session ?? fakeSession(),
        httpClient: client,
      );

  Future<http.Response> _answer(http.Request request) async {
    final segments = _split(request.url.path);
    for (final route in _routes) {
      final params = route.match(request.method, segments);
      if (params == null) continue;
      final seen =
          FakeRequest(request.method, request.url, params, request.body);
      requests.add(seen);
      final reply = await route.handler(seen);
      return http.Response(
        reply.body,
        reply.status,
        headers: {'content-type': 'application/json'},
      );
    }
    final seen =
        FakeRequest(request.method, request.url, const {}, request.body);
    requests.add(seen);
    unmatched.add(seen);
    return jsonHttpResponse(
        {'error': 'no fake route for ${request.method} ${request.url.path}'},
        404);
  }

  static List<String> _split(String path) =>
      path.split('/').where((segment) => segment.isNotEmpty).toList();
}
