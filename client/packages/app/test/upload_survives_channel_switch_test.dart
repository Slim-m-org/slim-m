// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An upload keeps running when the user opens another channel (owner report:
/// "an upload also breaks if i switch channels while it uploads").
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/composer_attachments.dart';

const _tokens = TokenPair(
  userId: 'u1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  test(
    'switching to another channel does not cancel or drop an upload',
    () async {
      final reply = Completer<void>();
      final api = SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: SessionStore(tokens: _tokens),
        httpClient: MockClient.streaming((request, body) async {
          await body.drain<void>();
          if (request.method == 'GET') {
            return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
          }
          await reply.future;
          final json = jsonEncode({
            'id': 'att1',
            'filename': 'a.bin',
            'content_type': 'application/octet-stream',
            'size': 4,
          });
          return http.StreamedResponse(Stream.value(utf8.encode(json)), 200);
        }),
      );
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          apiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);

      final first = container.read(attachmentStagingProvider('c1'));
      await first.stage(Uint8List(4), 'a.bin');
      expect(first.items.single, isA<UploadingAttachment>());

      container.read(attachmentStagingProvider('c2'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        identical(container.read(attachmentStagingProvider('c1')), first),
        isTrue,
      );
      expect(first.items.single, isA<UploadingAttachment>());

      reply.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(first.items.single, isA<UploadedAttachment>());
    },
  );
}
