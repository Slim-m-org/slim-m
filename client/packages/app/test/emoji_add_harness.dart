// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared setup for the emoji add card tests: a mock transport that records
/// every emoji request and a picker the test can hand any set of files.
library;

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
import 'package:slimm_app/src/screens/admin/emoji_add_card.dart';
import 'package:slimm_app/src/screens/admin/emoji_intake.dart';
import 'package:slimm_design_system/design_system.dart';

const emojiTestTokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final emojiTestPng = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

List<int> buildEmojiZip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(
      ArchiveFile(e.key, e.value.length, Uint8List.fromList(e.value)),
    );
  }
  return ZipEncoder().encodeBytes(archive);
}

EmojiPick emojiPick(String name, [List<int>? bytes]) =>
    EmojiPick(fileName: name, bytes: bytes ?? emojiTestPng);

http.Response emojiJson(Object value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> emojiRow(String name, {String? sameImageAs}) => {
  'id': 'e-$name',
  'name': name,
  'uploader_id': 'admin',
  'created_at': 0,
  'same_image_as': ?sameImageAs,
};

/// Names a `POST /emoji/bulk` body asked for, in order.
List<String> bulkNames(http.Request request) => [
  for (final i in (jsonDecode(request.body) as Map)['images'] as List)
    (i as Map)['name'] as String,
];

typedef EmojiHandler = http.Response Function(http.Request request);

class EmojiHarness {
  EmojiHarness({
    this.existing = const [],
    this.onSingle,
    this.onBulk,
    this.picks = const [],
    this.pickerThrows = false,
  });

  final List<api.CustomEmoji> existing;
  final EmojiHandler? onSingle;
  final EmojiHandler? onBulk;
  List<EmojiPick> picks;
  final bool pickerThrows;
  final requests = <http.Request>[];

  /// Awaited before a bulk response, so a test can hold a request open.
  Future<void> Function(http.Request)? holdBulk;
  int listFetches = 0;

  Iterable<http.Request> get singles =>
      requests.where((r) => r.method == 'POST' && r.url.path == '/emoji');
  Iterable<http.Request> get bulks =>
      requests.where((r) => r.url.path == '/emoji/bulk');

  Future<ProviderContainer> pump(WidgetTester tester, {Size? size}) async {
    tester.view.physicalSize = size ?? const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        customEmojiProvider.overrideWith((ref) async {
          listFetches++;
          return existing;
        }),
        emojiFilesPickerProvider.overrideWithValue(() async {
          if (pickerThrows) throw StateError('no portal');
          return picks;
        }),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: api.SessionStore(tokens: emojiTestTokens),
            httpClient: MockClient((request) async {
              requests.add(request);
              if (request.url.path == '/emoji/bulk') {
                await holdBulk?.call(request);
                return onBulk!(request);
              }
              if (request.method == 'POST' && request.url.path == '/emoji') {
                return onSingle!(request);
              }
              return emojiJson(const {});
            }),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: SingleChildScrollView(child: EmojiAddCard()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> choose(WidgetTester tester) async {
    await tester.tap(find.text('Choose files'));
    await tester.pumpAndSettle();
  }
}
