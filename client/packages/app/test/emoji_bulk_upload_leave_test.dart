// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Leaving the emoji screen mid-import: the remaining chunks still upload and
/// the cached emoji list is refreshed, because the writes outlive the card.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/emoji_bulk_upload_card.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

List<int> _buildZip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(
      ArchiveFile(
        entry.key,
        entry.value.length,
        Uint8List.fromList(entry.value),
      ),
    );
  }
  return ZipEncoder().encodeBytes(archive);
}

http.Response _json(Object value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

/// The names a `POST /emoji/bulk` request asked for, in order.
List<String> _requestedNames(http.Request request) {
  final decoded = jsonDecode(request.body) as Map<String, dynamic>;
  final images = decoded['images'] as List<dynamic>;
  return images
      .map((e) => (e as Map<String, dynamic>)['name'] as String)
      .toList();
}

http.Response _bulkCreated(List<String> names) => _json([
  for (final name in names)
    {'id': 'e-$name', 'name': name, 'uploader_id': 'admin', 'created_at': 0},
], status: 201);

void main() {
  testWidgets(
    'leaving mid-import finishes every chunk and refreshes the list',
    (tester) async {
      final zip = _buildZip({
        for (var i = 0; i < 120; i++) 'e$i.png': [i, i, i],
      });
      var emojiBuilds = 0;
      final gates = <Completer<void>>[];
      var bulkCalls = 0;
      final container = ProviderContainer(
        overrides: [
          customEmojiProvider.overrideWith((ref) async {
            emojiBuilds++;
            return <api.CustomEmoji>[];
          }),
          emojiZipPickerProvider.overrideWithValue(() async => zip),
          apiProvider.overrideWith((ref) {
            final client = api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: api.SessionStore(tokens: _tokens),
              httpClient: MockClient((request) async {
                if (request.url.path == '/emoji/bulk') {
                  bulkCalls++;
                  final gate = Completer<void>();
                  gates.add(gate);
                  await gate.future;
                  return _bulkCreated(_requestedNames(request));
                }
                return _json(const {});
              }),
            );
            ref.onDispose(client.close);
            return client;
          }),
        ],
      );
      addTearDown(container.dispose);
      // The composer keeps the provider alive, as the finding describes.
      final sub = container.listen(customEmojiProvider, (_, _) {});
      addTearDown(sub.close);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: EmojiBulkUploadCard()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final buildsBefore = emojiBuilds;

      await tester.tap(find.text('Choose a zip file'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(bulkCalls, 1);

      // The admin navigates away while chunk 1 of 3 is in flight.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const SizedBox(),
          ),
        ),
      );
      for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (gates.length > i) gates[i].complete();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 50));

    expect(bulkCalls, 3, reason: 'every chunk is still sent after leaving');
      expect(
        emojiBuilds,
        greaterThan(buildsBefore),
        reason: 'chunks landed on the server, so the cached list is stale',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
