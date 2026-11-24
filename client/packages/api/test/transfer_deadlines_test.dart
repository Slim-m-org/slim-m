// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Long transfers stop when they stall or are cancelled, and big JSON bodies
/// get the transfer deadline rather than the ordinary one.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

SlimmApi _api(http.Client client) => SlimmApi(
      baseUrl: _base,
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: client,
    );

const _stall = Duration(milliseconds: 60);

/// A server that takes the request and never answers; [aborted] says whether the client hung up.
class _Silent {
  final aborted = Completer<void>();

  late final client = MockClient.streaming((request, body) {
    if (request is http.Abortable) {
      request.abortTrigger?.then((_) => aborted.complete());
    }
    return Completer<http.StreamedResponse>().future;
  });
}

const _attachment = {
  'id': 'att1',
  'filename': 'a.bin',
  'content_type': 'application/octet-stream',
  'size': 4,
};

void main() {
  group('a plain upload', () {
    test('that stops moving fails with a TransportException and hangs up',
        () async {
      final silent = _Silent();
      await expectLater(
        _api(silent.client).uploadAttachmentStream(
          () => Stream.value([1, 2, 3, 4]),
          length: 4,
          stallDeadline: _stall,
        ),
        throwsA(isA<TransportException>()),
      );
      expect(silent.aborted.isCompleted, isTrue);
    });

    test('that keeps moving is not a stall however long it takes', () async {
      final api = _api(MockClient.streaming((request, body) async {
        await body.drain<void>();
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(_attachment))),
          201,
          headers: {'content-type': 'application/json'},
        );
      }));
      Stream<List<int>> slow() async* {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 35));
          yield [i];
        }
      }

      final done = await api.uploadAttachmentStream(
        slow,
        length: 6,
        stallDeadline: _stall,
      );
      expect(done.id, 'att1');
    });

    test('stops at once when its token is cancelled, even with no bytes moving',
        () async {
      final silent = _Silent();
      final cancel = UploadCancelToken();
      final result = _api(silent.client).uploadAttachmentAuto(
        UploadSource(open: () => Stream.value([1, 2, 3, 4])),
        length: 4,
        capabilities: const [],
        cancel: cancel,
      );
      unawaited(Future<void>.delayed(
        const Duration(milliseconds: 20),
        cancel.cancel,
      ));
      await expectLater(result, throwsA(isA<UploadCancelled>()));
      expect(silent.aborted.isCompleted, isTrue);
    });
  });

  group('the connection trace', () {
    test('gives up on an answer that never comes', () async {
      final silent = _Silent();
      await expectLater(
        _api(silent.client).cloudflareTrace(deadline: _stall),
        throwsA(isA<TransportException>()),
      );
    });
  });

  group('a large JSON body', () {
    // Past the 45 second ordinary deadline, inside the 3 minute transfer one.
    const slowServer = Duration(seconds: 60);

    SlimmApi slowRefusing() => _api(MockClient((request) async {
          await Future<void>.delayed(slowServer);
          return http.Response(
            jsonEncode({'error': 'refused'}),
            400,
            headers: {'content-type': 'application/json'},
          );
        }));

    /// What [call] threw once [slowServer] has passed, which is the server's own answer if the client waited.
    Object? outcome(Future<Object?> Function(SlimmApi api) call) {
      Object? error;
      fakeAsync((async) {
        call(slowRefusing()).then<void>((_) {}, onError: (Object e) {
          error = e;
        });
        async.elapse(slowServer + const Duration(seconds: 1));
        async.flushMicrotasks();
      });
      return error;
    }

    test('bulk emoji upload waits out a slow server', () {
      expect(
        outcome((api) => api.bulkUploadCustomEmoji(const [
              EmojiBulkImage(name: 'a', bytes: [1])
            ])),
        isA<BadRequestException>(),
      );
    });

    test('a module package preview waits out a slow server', () {
      expect(
        outcome((api) => api.previewDockPackage({'x': 1})),
        isA<BadRequestException>(),
      );
    });

    test('a module package install waits out a slow server', () {
      expect(
        outcome((api) =>
            api.installDockPackage(package: {'x': 1}, version: '1.0.0')),
        isA<BadRequestException>(),
      );
    });

    test('publishing a theme waits out a slow server', () {
      expect(
        outcome((api) => api.publishSpaceTheme({'x': 1})),
        isA<BadRequestException>(),
      );
    });

    test('an ordinary JSON call still gives up at the ordinary deadline', () {
      expect(
        outcome((api) => api.listCustomEmoji()),
        isA<TransportException>(),
      );
    });
  });

  test(
      'finishing an upload session waits out a server that hashes the file (all bytes already held)',
      () {
    const hashing = Duration(minutes: 5);
    final session = {
      'id': 'up1',
      'size': 4,
      'offset': 4,
      'part_max_bytes': 64,
      'expires_at': 0,
    };
    final api = _api(MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith("/complete")) {
        await Future<void>.delayed(hashing);
        return http.Response(jsonEncode(_attachment), 201,
            headers: {'content-type': 'application/json'});
      }
      return http.Response(
        jsonEncode(session),
        request.method == 'POST' ? 201 : 200,
        headers: {'content-type': 'application/json'},
      );
    }));
    Attachment? done;
    Object? error;
    fakeAsync((async) {
      api
          .uploadAttachmentAuto(
        UploadSource(open: Stream<List<int>>.empty),
        length: 4,
        capabilities: const ['upload_sessions'],
        sessionThreshold: 0,
      )
          .then<void>((a) => done = a, onError: (Object e) {
        error = e;
      });
      async.flushMicrotasks();
      async.elapse(hashing + const Duration(seconds: 1));
      async.flushMicrotasks();
    });
    expect(error, isNull);
    expect(done?.id, 'att1');
  });
}
