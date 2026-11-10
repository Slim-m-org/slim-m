// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A photo from the phone strip takes the picked-file path: refused up front
/// when over the server's limit, and streamed rather than held when large.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_app/src/features/composer/widgets/photo_library.dart';
import 'package:slimm_app/src/features/composer/widgets/staged_attachment_tile.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import 'composer_harness.dart';

const _mib = 1024 * 1024;

class _OnePhoto implements PhotoLibrary {
  _OnePhoto(this.photo);

  final MemoryFile photo;

  @override
  Future<PhotoAccess> requestAccess() async => PhotoAccess.full;

  @override
  Future<List<RecentPhoto>> recent(int n) async => [const RecentPhoto('p')];

  @override
  Future<Uint8List?> thumbnail(String id, int pixels) async => null;

  @override
  Future<FileSource?> original(String id) async => photo.source;

  @override
  Future<void> manageLimited() async {}
}

/// Answers `/version` with [maxBytes], and holds an upload until [gate].
api.SlimmApi Function(Ref) _server(int maxBytes, Completer<void> gate) =>
    (ref) => testApi((request) async {
      if (request.url.path == '/version') {
        return http.Response(
          jsonEncode({
            'name': 'slim-m',
            'version': '1.0.0',
            'protocol': 1,
            'max_attachment_bytes': maxBytes,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'POST' && request.url.path == '/attachments') {
        await gate.future;
      }
      return http.Response('{}', 404);
    }, session: ref.watch(sessionProvider));

final _tile = find.byWidgetPredicate((w) => w is StagedAttachmentTile);

void main() {
  late TextEditingController controller;

  setUp(() => controller = TextEditingController());
  tearDown(() => controller.dispose());

  Future<void> tapPhoto(
    WidgetTester tester,
    MemoryFile photo, {
    required int maxBytes,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: Sends(),
        platform: TargetPlatform.iOS,
        apiBuilder: _server(maxBytes, gate),
        extraOverrides: [
          photoLibraryProvider.overrideWithValue(_OnePhoto(photo)),
        ],
      ),
    );
    await tester.tap(moreActionsButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Photo library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.bySemanticsLabel('Attach photo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('a photo over the server limit is refused before it is read', (
    tester,
  ) async {
    final photo = MemoryFile('IMG_1.heic', Uint8List(4), length: 40 * _mib);
    await tapPhoto(tester, photo, maxBytes: 25 * _mib);

    expect(find.textContaining('over this server'), findsOneWidget);
    expect(_tile, findsNothing);
    expect(photo.wholeReads, 0);
    expect(photo.streamReads, 0);
  });

  testWidgets('a large photo streams instead of sitting in memory', (
    tester,
  ) async {
    final photo = MemoryFile('IMG_2.heic', Uint8List(4), length: 20 * _mib);
    await tapPhoto(tester, photo, maxBytes: 100 * _mib);

    expect(_tile, findsOneWidget);
    expect(photo.wholeReads, 0, reason: 'the original is never held whole');
    final container = ProviderScope.containerOf(
      tester.element(find.byWidgetPredicate((w) => w is Composer)),
    );
    final staged = container.read(attachmentStagingProvider('c1')).items;
    expect(staged.single.body.bytes, isNull);
    expect(staged.single.body.length, 20 * _mib);
  });
}
