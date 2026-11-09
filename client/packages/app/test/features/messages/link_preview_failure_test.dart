// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A link preview or embed image that failed to load must not stay failed:
/// transient refusals are retried, and one that outlasts the retries is not
/// held for the next view of the same link.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart'
    show serverInfoProvider;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/link_preview.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _url = 'https://example.com';
const _token = 'tok';

const _tokens = TokenPair(
  userId: 'u1',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

http.Response _preview() => http.Response(
  jsonEncode({
    'url': _url,
    'title': 'An example',
    'description': null,
    'site_name': null,
    'image_token': null,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _error(int status) => http.Response(
  jsonEncode({'error': 'nope'}),
  status,
  headers: {'content-type': 'application/json'},
);

/// Answers each request from [answers] in turn, repeating the last one.
class _Server {
  _Server(this.answers);

  final List<http.Response Function()> answers;
  int requests = 0;

  Future<http.Response> handle(http.Request _) async {
    final at = requests < answers.length ? requests : answers.length - 1;
    requests++;
    return answers[at]();
  }
}

ProviderContainer _container(_Server server) {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      attachmentRetryDelaysProvider.overrideWithValue(const [
        Duration.zero,
        Duration.zero,
      ]),
      serverInfoProvider.overrideWith(
        (ref) => Future.value(
          Version(
            name: 'slim-m',
            version: '0.30.0',
            protocol: 1,
            linkPreviewsEnabled: true,
          ),
        ),
      ),
      apiProvider.overrideWith(
        (ref) => testApi(server.handle, session: ref.watch(sessionProvider)),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a transient server error is retried and the preview arrives', () async {
    final server = _Server([() => _error(503), _preview]);
    final container = _container(server);

    container.listen(linkPreviewProvider(_url), (_, _) {});
    final preview = await container.read(linkPreviewProvider(_url).future);

    expect(preview?.title, 'An example');
    expect(server.requests, 2);
  });

  test('a rate limit is waited out and the preview arrives', () async {
    final server = _Server([() => _error(429), _preview]);
    final container = _container(server);

    container.listen(linkPreviewProvider(_url), (_, _) {});
    final preview = await container.read(linkPreviewProvider(_url).future);

    expect(preview?.title, 'An example');
  });

  test(
    'a failure that outlasts the retries is not kept for the next view',
    () async {
      final server = _Server([() => _error(500), () => _error(500)]);
      final container = _container(server);

      final first = container.listen(linkPreviewProvider(_url), (_, _) {});
      await expectLater(
        container.read(linkPreviewProvider(_url).future),
        throwsA(isA<ServerException>()),
      );
      final afterFirstView = server.requests;
      first.close();
      await container.pump();

      container.listen(linkPreviewProvider(_url), (_, _) {});
      await expectLater(
        container.read(linkPreviewProvider(_url).future),
        throwsA(isA<ServerException>()),
      );

      expect(server.requests, greaterThan(afterFirstView));
    },
  );

  test('a transient failure fetching an image is retried', () async {
    final server = _Server([
      () => _error(503),
      () => http.Response.bytes(Uint8List.fromList([1, 2, 3]), 200),
    ]);
    final container = _container(server);

    container.listen(linkPreviewImageBytesProvider(_token), (_, _) {});
    final bytes = await container.read(
      linkPreviewImageBytesProvider(_token).future,
    );

    expect(bytes, [1, 2, 3]);
  });

  test('an image failure that outlasts the retries is not kept', () async {
    final server = _Server([() => _error(500)]);
    final container = _container(server);

    final first = container.listen(
      linkPreviewImageBytesProvider(_token),
      (_, _) {},
    );
    await expectLater(
      container.read(linkPreviewImageBytesProvider(_token).future),
      throwsA(isA<ServerException>()),
    );
    final afterFirstView = server.requests;
    first.close();
    await container.pump();

    container.listen(linkPreviewImageBytesProvider(_token), (_, _) {});
    await expectLater(
      container.read(linkPreviewImageBytesProvider(_token).future),
      throwsA(isA<ServerException>()),
    );

    expect(server.requests, greaterThan(afterFirstView));
  });

  test('a stale image token still resolves to null without a retry', () async {
    final server = _Server([() => _error(404)]);
    final container = _container(server);

    container.listen(linkPreviewImageBytesProvider(_token), (_, _) {});
    final bytes = await container.read(
      linkPreviewImageBytesProvider(_token).future,
    );

    expect(bytes, isNull);
    expect(server.requests, 1);
  });

  test('the stale-token refetch memory starts over with a new session', () {
    final container = _container(_Server([_preview]));
    container.read(refreshedStalePreviewsProvider).add(_url);

    container.invalidate(apiProvider);

    expect(container.read(refreshedStalePreviewsProvider), isEmpty);
  });
}
