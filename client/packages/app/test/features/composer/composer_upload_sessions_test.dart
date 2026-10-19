// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which upload route a staged file takes, through the real staging provider:
/// one request for small files and servers without sessions, resumable parts
/// for a big file when the server advertises them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _mib = 1024 * 1024;

http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

class _Server {
  _Server({required this.capabilities});

  final List<String> capabilities;
  final calls = <String>[];
  var held = 0;
  var size = 0;

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    calls.add('${request.method} $path');
    Map<String, dynamic> session() => {
      'id': 'up1',
      'size': size,
      'offset': held,
      'part_max_bytes': 64 * _mib,
      'expires_at': 0,
    };
    if (path == '/version') {
      return _json({
        'name': 's',
        'version': '1.0.0',
        'protocol': 1,
        'capabilities': capabilities,
      });
    }
    if (path == '/attachments/uploads') {
      size = (jsonDecode(request.body) as Map)['size'] as int;
      return _json(session(), 201);
    }
    if (request.method == 'PUT') {
      held += request.bodyBytes.length;
      return _json(session());
    }
    return _json({
      'id': 'att',
      'filename': 'big.iso',
      'content_type': 'application/octet-stream',
      'size': size,
    }, 201);
  }
}

AttachmentStagingController _staging(_Server server) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'u',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      ),
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  return container.read(attachmentStagingProvider('c1'));
}

FileSource _file(int length) => FileSource(
  name: 'big.iso',
  length: () async => length,
  readAll: () async => Uint8List(length),
  openRead: () async* {
    for (var left = length; left > 0; left -= _mib) {
      yield Uint8List(left < _mib ? left : _mib);
    }
  },
);

Future<void> _settled(AttachmentStagingController staging) async {
  while (staging.items.any((a) => a is UploadingAttachment)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('a big file goes in parts when the server has sessions', () async {
    final server = _Server(capabilities: ['upload_sessions']);
    final staging = _staging(server);
    await staging.stageFile(_file(40 * _mib));
    await _settled(staging);

    expect(staging.items.single, isA<UploadedAttachment>());
    expect(server.calls.first, 'GET /version');
    expect(server.calls, contains('POST /attachments/uploads'));
    expect(server.calls.where((c) => c.startsWith('PUT ')).length, 3);
    expect(server.calls.last, 'POST /attachments/uploads/up1/complete');
    expect(server.held, 40 * _mib);
  });

  test('a big file stays one request without sessions', () async {
    final server = _Server(capabilities: const []);
    final staging = _staging(server);
    await staging.stageFile(_file(40 * _mib));
    await _settled(staging);

    expect(staging.items.single, isA<UploadedAttachment>());
    expect(server.calls.last, 'POST /attachments');
    expect(server.calls.where((c) => c.startsWith('PUT ')), isEmpty);
  });

  test('a file under the threshold never asks for capabilities', () async {
    final server = _Server(capabilities: ['upload_sessions']);
    final staging = _staging(server);
    await staging.stageFile(_file(20 * _mib));
    await _settled(staging);

    expect(server.calls.where((c) => c == 'POST /attachments').length, 1);
    expect(server.calls, isNot(contains('POST /attachments/uploads')));
  });

  test('removing an uploading tile cancels its upload', () async {
    final gate = Completer<void>();
    final staging = AttachmentStagingController(
      upload: (body, filename, onProgress) async {
        await gate.future;
        body.cancel.throwIfCancelled();
        throw StateError('should have been cancelled');
      },
    );
    addTearDown(staging.dispose);
    await staging.stageBody(
      AttachmentBody.stream(length: 100, open: () => const Stream.empty()),
      'big.iso',
    );
    final body = staging.items.single.body;

    staging.remove(staging.items.single.localId);
    expect(body.cancel.isCancelled, isTrue);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(staging.items, isEmpty);
  });
}
