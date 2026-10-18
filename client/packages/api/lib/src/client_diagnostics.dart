// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

const _diagnosticsChunk = 64 * 1024;
const _diagnosticsDeadline = Duration(minutes: 2);

/// The connection test's view of this server: the routes a device can take.
extension SlimmApiDiagnostics on SlimmApi {
  /// One probe per route to measure: the server's own network when it
  /// advertised an address, and the internet. Each owns a connection the
  /// caller closes through [ConnectionProbe.close].
  List<(ConnectionRoute, ConnectionProbe)> connectionProbes() {
    final route = _route;
    final lan = route?.pinnedClient(direct: true);
    final internet = route?.pinnedClient(direct: false);
    return [
      if (lan != null) (ConnectionRoute.lan, _ApiProbe(this, lan)),
      (
        ConnectionRoute.internet,
        _ApiProbe(this, internet ?? _http, owns: internet != null),
      ),
    ];
  }
}

class _ApiProbe implements ConnectionProbe {
  _ApiProbe(this._api, this._client, {this.owns = true});

  final SlimmApi _api;
  final http.Client _client;
  final bool owns;

  @override
  bool viaCloudflare = false;

  final Uint8List _block = _filler();

  static Uint8List _filler() {
    final random = math.Random(7);
    return Uint8List.fromList(
      List<int>.generate(_diagnosticsChunk, (_) => random.nextInt(256)),
    );
  }

  @override
  Future<Duration> ping({UploadCancelToken? cancel}) async {
    cancel?.throwIfCancelled();
    final clock = Stopwatch()..start();
    await _api._send(
      'GET',
      '/diagnostics/ping',
      over: _client,
      onHeaders: (headers) {
        if (headers.containsKey('cf-ray')) viaCloudflare = true;
      },
    );
    return clock.elapsed;
  }

  @override
  Future<ProbeTransfer> download(
    int bytes, {
    UploadCancelToken? cancel,
    void Function(int done)? onProgress,
  }) async {
    final request = _api._diagnosticsRequest(
      'GET',
      '/diagnostics/download',
      query: {'bytes': '$bytes'},
    );
    final response = await _api._diagnosticsSend(_client, request);
    if (response.headers.containsKey('cf-ray')) viaCloudflare = true;
    if (response.statusCode != 200) {
      throw _api._errorFor(await http.Response.fromStream(response));
    }
    final clock = Stopwatch()..start();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        cancel?.throwIfCancelled();
        received += chunk.length;
        onProgress?.call(received);
      }
    } on UploadCancelled {
      rethrow;
    } catch (e) {
      throw TransportException('GET /diagnostics/download failed: $e');
    }
    return ProbeTransfer(received, clock.elapsed);
  }

  @override
  Future<ProbeTransfer> upload(
    int bytes, {
    UploadCancelToken? cancel,
    void Function(int done)? onProgress,
  }) async {
    final request = _api._diagnosticsRequest('POST', '/diagnostics/upload')
        as http.StreamedRequest;
    request.contentLength = bytes;
    final clock = Stopwatch()..start();
    unawaited(
      request.sink
          .addStream(_body(bytes, cancel, onProgress))
          .then((_) => request.sink.close())
          .catchError((Object e, StackTrace st) {
        request.sink.addError(e, st);
        request.sink.close();
      }),
    );
    final response = await _api._diagnosticsSend(_client, request);
    if (response.headers.containsKey('cf-ray')) viaCloudflare = true;
    final full = await http.Response.fromStream(response);
    if (full.statusCode != 200) throw _api._errorFor(full);
    return ProbeTransfer(bytes, clock.elapsed);
  }

  Stream<List<int>> _body(
    int bytes,
    UploadCancelToken? cancel,
    void Function(int done)? onProgress,
  ) async* {
    var sent = 0;
    while (sent < bytes) {
      cancel?.throwIfCancelled();
      final take = math.min(_block.length, bytes - sent);
      sent += take;
      onProgress?.call(sent);
      yield Uint8List.sublistView(_block, 0, take);
    }
  }

  @override
  void close() {
    if (owns) _client.close();
  }
}

extension on SlimmApi {
  http.BaseRequest _diagnosticsRequest(
    String method,
    String path, {
    Map<String, String>? query,
  }) {
    final token = session.tokens?.accessToken;
    if (token == null) throw const UnauthorizedException('not signed in');
    final uri = _requestUri(path, query);
    final request = method == 'POST'
        ? http.StreamedRequest(method, uri)
        : http.Request(method, uri);
    request.headers['authorization'] = 'Bearer $token';
    if (method == 'POST') {
      request.headers['content-type'] = 'application/octet-stream';
    }
    return request;
  }

  Future<http.StreamedResponse> _diagnosticsSend(
    http.Client client,
    http.BaseRequest request,
  ) async {
    try {
      return await client.send(request).timeout(_diagnosticsDeadline);
    } on TimeoutException {
      throw TransportException(
          '${request.method} ${request.url.path} got no answer');
    } catch (e) {
      throw TransportException(
          '${request.method} ${request.url.path} failed: $e');
    }
  }
}
