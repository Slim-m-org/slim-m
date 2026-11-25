// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The photo strip while a tapped photo's original is being read: a slow one
/// shows progress and attaches once, an unreadable one says so inline, and a
/// video is told apart from a picture.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_photo_strip.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_app/src/features/composer/widgets/photo_library.dart';
import 'package:slimm_app/src/features/composer/widgets/staged_attachment_model.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart' show MemoryFile;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

class _Library implements PhotoLibrary {
  _Library(this._original);

  final Future<FileSource?> Function(String id) _original;
  final opened = <String>[];
  int? videoBytes;

  @override
  Future<PhotoAccess> requestAccess() async => PhotoAccess.full;

  @override
  Future<List<RecentPhoto>> recent(int count) async => [
    const RecentPhoto('p0'),
    RecentPhoto('v1', isVideo: true, bytes: videoBytes),
  ];

  @override
  Future<Uint8List?> thumbnail(String id, int pixels) async => _png;

  @override
  Future<FileSource?> original(String id) {
    opened.add(id);
    return _original(id);
  }

  @override
  Future<void> clearCache() async {}

  @override
  Future<void> manageLimited() async {}
}

final spinner = find.byWidgetPredicate((w) => w is AppSpinner);

void main() {
  late List<FileSource> attached;

  setUp(() => attached = []);

  Future<void> pump(
    WidgetTester tester,
    PhotoLibrary library, {
    Future<void> Function(FileSource file)? onAttach,
    int? limit,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          photoLibraryProvider.overrideWithValue(library),
          serverInfoProvider.overrideWith(
            (ref) async => api.Version.fromJson({
              'name': 'slim-m',
              'version': '0.130.0',
              'protocol': 1,
              if (limit != null) 'max_attachment_bytes': limit,
            }),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ComposerPhotoStrip(
              onAttach: onAttach ?? (file) async => attached.add(file),
              onBrowse: () {},
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a second tap while the original loads attaches it once', (
    tester,
  ) async {
    final gate = Completer<FileSource?>();
    final library = _Library((_) => gate.future);
    await pump(tester, library);

    await tester.tap(find.bySemanticsLabel('Attach photo'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Attach photo'));
    await tester.pump();

    expect(library.opened, ['p0'], reason: 'the repeat tap is ignored');
    expect(spinner, findsOneWidget);

    gate.complete(MemoryFile('p0.png', _png).source);
    await tester.pump();
    await tester.pump();

    expect(attached, hasLength(1));
    expect(spinner, findsNothing);
  });

  testWidgets('a photo whose original throws shows the read failure', (
    tester,
  ) async {
    final library = _Library((_) async => throw StateError('icloud'));
    await pump(tester, library);

    await tester.tap(find.bySemanticsLabel('Attach photo'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not read that photo.'), findsOneWidget);
    expect(attached, isEmpty);
    expect(spinner, findsNothing);
  });

  testWidgets('a failed read can be retried by tapping again', (tester) async {
    var calls = 0;
    final library = _Library((_) async {
      calls += 1;
      return calls == 1 ? null : MemoryFile('p0.png', _png).source;
    });
    await pump(tester, library);

    await tester.tap(find.bySemanticsLabel('Attach photo'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Could not read that photo.'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Attach photo'));
    await tester.pump();
    await tester.pump();

    expect(attached, hasLength(1));
    expect(find.text('Could not read that photo.'), findsNothing);
  });

  testWidgets('a video tile is labelled as a video and attaches', (
    tester,
  ) async {
    final library = _Library((id) async => MemoryFile('$id.mp4', _png).source);
    await pump(tester, library);

    await tester.tap(find.bySemanticsLabel('Attach video'));
    await tester.pump();
    await tester.pump();

    expect(library.opened, ['v1']);
    expect(attached.single.name, 'v1.mp4');
  });

  testWidgets(
    'a tap while the composer is still staging the file attaches once',
    (tester) async {
      final staging = Completer<void>();
      final library = _Library(
        (id) async => MemoryFile('$id.png', _png).source,
      );
      await pump(
        tester,
        library,
        onAttach: (file) {
          attached.add(file);
          return staging.future;
        },
      );

      await tester.tap(find.bySemanticsLabel('Attach photo'));
      await tester.pump();
      await tester.pump();
      expect(spinner, findsOneWidget, reason: 'busy until staging is done');
      await tester.tap(find.bySemanticsLabel('Attach photo'));
      await tester.pump();

      expect(attached, hasLength(1));

      staging.complete();
      await tester.pump();
      expect(spinner, findsNothing);
    },
  );

  testWidgets(
    'a video over the server limit is refused without downloading it',
    (tester) async {
      final library = _Library((id) async => MemoryFile('$id.mp4', _png).source)
        ..videoBytes = 3 * 1024 * 1024;
      await pump(tester, library, limit: 1024 * 1024);

      await tester.tap(find.bySemanticsLabel('Attach video'));
      await tester.pump();
      await tester.pump();

      expect(library.opened, isEmpty);
      expect(attached, isEmpty);
      expect(find.textContaining('over this server'), findsOneWidget);
    },
  );
}
