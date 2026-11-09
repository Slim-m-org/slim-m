// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call backdrop's blurred canvas picture is native memory, so it is freed
/// with the provider that painted it.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/lounge_canvas_glow.dart';
import 'package:slimm_app/src/providers/providers.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Client _canvasWithOneStroke() => MockClient(
  (request) async => http.Response(
    jsonEncode({
      'objects': [
        {
          'id': 's1',
          'kind': 'stroke',
          'z_index': 1,
          'x': 400,
          'y': 300,
          'w': 800,
          'h': 400,
          'props': {
            'points': [0, 0, 400, 200, 800, 400],
            'width': 40,
          },
          'seq': 1,
          'created_at': 0,
        },
      ],
      'has_more': false,
      'latest_seq': 1,
    }),
    200,
    headers: {'content-type': 'application/json'},
  ),
);

void main() {
  test('the painted glow is freed when its provider goes', () async {
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWith(
          (ref) => SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: SessionStore(tokens: _tokens),
            httpClient: _canvasWithOneStroke(),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final provider = loungeCanvasGlowProvider('c1');
    final hold = container.listen(provider, (_, _) {});

    final glow = await container.read(provider.future);
    expect(glow, isNotNull);
    expect(glow!.debugDisposed, isFalse);

    hold.close();
    await container.pump();
    expect(glow.debugDisposed, isTrue);
  });
}
