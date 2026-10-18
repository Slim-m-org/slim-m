// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The transport's deadline, and that both entry points share it.
///
/// There was none anywhere: `http.Client` sets no timeout on either backend,
/// so a server that accepts a connection and never answers hung its caller for
/// the life of the process. The reachable case is a mobile network transition,
/// and the visible one is a spinner whose `finally` never runs.
///
/// `_fetchBytes` gets its own case rather than being taken on trust, because it
/// was a hand-copy of `_send`'s transport and a deadline added to one would
/// have left the three byte-fetching routes unbounded with nothing failing to
/// say so.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A client that accepts the request and never answers, which is the shape
/// this exists for: not a refused connection, which already failed fast.
SlimmApi _neverAnswers() => testApi((_) => Completer<http.Response>().future,
    session: SessionStore(tokens: _tokens));

void main() {
  test('a request that is never answered gives up rather than hanging', () {
    fakeAsync((async) {
      Object? thrown;
      unawaited(
        _neverAnswers().listChannels().catchError((Object e) {
          thrown = e;
          return const <Channel>[];
        }),
      );

      async.elapse(const Duration(seconds: 44));
      expect(thrown, isNull, reason: 'it must wait rather than fail eagerly');

      async.elapse(const Duration(seconds: 2));
      expect(thrown, isA<TransportException>());
      expect((thrown! as ApiException).message, contains('no answer'));
    });
  });

  test('a byte fetch is bounded too, on its own longer budget', () {
    fakeAsync((async) {
      Object? thrown;
      unawaited(
        _neverAnswers().fetchAttachment('a' * 64).catchError((Object e) {
          thrown = e;
          return FetchedBytes(bytes: Uint8List(0), contentType: '');
        }),
      );

      async.elapse(const Duration(seconds: 46));
      expect(
        thrown,
        isNull,
        reason: 'a transfer gets longer than an ordinary request, on purpose',
      );

      async.elapse(const Duration(minutes: 3));
      expect(thrown, isA<TransportException>());
    });
  });
}
