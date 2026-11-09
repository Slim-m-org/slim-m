// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A picture that failed to load once is asked for again, instead of staying
/// blank until enough other pictures evict it from the keep-alive cache.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/avatar_bytes.dart';
import 'package:slimm_app/src/features/members/providers/banner_bytes.dart';
import 'package:slimm_app/src/features/members/providers/linked_avatar_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = TokenPair(
  userId: 'u1',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

final _picture = utf8.encode('png-bytes');

/// One provider under test: where its bytes come from and how to read them.
class _Case {
  const _Case(this.name, this.suffix, this.future);

  final String name;
  final String suffix;
  final Future<Uint8List?> Function(ProviderContainer container) future;
}

final _cases = [
  _Case(
    'avatar',
    '/avatar',
    (c) => c.read(avatarBytesProvider((userId: 'u2', updatedAt: 1)).future),
  ),
  _Case(
    'banner',
    '/banner',
    (c) => c.read(bannerBytesProvider((userId: 'u2', updatedAt: 1)).future),
  ),
  _Case(
    'linked picture',
    '/links/discord/avatar',
    (c) =>
        c.read(linkedAvatarBytesProvider((userId: 'u2', updatedAt: 1)).future),
  ),
];

/// A container whose server answers each request for a path ending in
/// [suffix] from [replies] in turn, counting them in [asked].
class _Rig {
  _Rig(String suffix, List<http.Response> replies) {
    container = _container(suffix, replies, () => asked++);
  }

  late final ProviderContainer container;
  int asked = 0;
}

ProviderContainer _container(
  String suffix,
  List<http.Response> replies,
  int Function() onAsked,
) {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      attachmentRetryDelaysProvider.overrideWithValue(
        List.filled(3, Duration.zero),
      ),
      apiProvider.overrideWith((ref) {
        return testApi((request) async {
          if (!request.url.path.endsWith(suffix)) {
            return http.Response('', 404);
          }
          final asked = onAsked();
          return replies[asked < replies.length ? asked : replies.length - 1];
        }, session: ref.watch(sessionProvider));
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

http.Response _ok() =>
    http.Response.bytes(_picture, 200, headers: {'content-type': 'image/png'});

http.Response _down() => http.Response('', 503);

http.Response _noPicture() => http.Response(
  jsonEncode({'error': 'user has no avatar'}),
  404,
  headers: {'content-type': 'application/json'},
);

void main() {
  for (final c in _cases) {
    group(c.name, () {
      test('a transient failure is retried and the picture appears', () async {
        final rig = _Rig(c.suffix, [_down(), _down(), _ok()]);

        expect(await c.future(rig.container), _picture);
        expect(rig.asked, 3);
      });

      test('a failure that outlasts the retries is not pinned for later '
          'views', () async {
        final rig = _Rig(c.suffix, [..._retriesExhausted(), _ok()]);

        await expectLater(
          c.future(rig.container),
          throwsA(isA<ApiException>()),
        );
        // Nothing is watching now, which is what a remounted avatar looks like.
        await Future<void>.delayed(Duration.zero);

        expect(await c.future(rig.container), _picture);
      });

      test(
        'a 404 is the server saying there is none: null, no retry',
        () async {
          final rig = _Rig(c.suffix, [_noPicture()]);

          expect(await c.future(rig.container), isNull);
          expect(rig.asked, 1);
        },
      );

      test('a 404 with no reason may be a proxy mid-restart: it is retried '
          'and the picture appears', () async {
        final rig = _Rig(c.suffix, [http.Response('not found', 404), _ok()]);

        expect(await c.future(rig.container), _picture);
        expect(rig.asked, 2);
      });
    });
  }
}

/// The first attempt plus one per retry delay.
List<http.Response> _retriesExhausted() => List.generate(4, (_) => _down());
