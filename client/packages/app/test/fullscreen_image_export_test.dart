// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Share and Save in the fullscreen viewer's header.
///
/// `flutter test` on Linux reports a desktop host for every run, so the phone
/// branch is driven through a fake [ImageExporter] with a phone's capabilities,
/// and the real [PlatformImageExporter] is pinned separately by overriding the
/// target platform.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/features/messages/widgets/fullscreen_image_viewer.dart';
import 'package:slimm_app/src/features/messages/widgets/image_export.dart';
import 'package:slimm_design_system/design_system.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkA'
  'AAgEsAtmMCMaywi+hcEKLNP1WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE'
  'BAQEBAQEBAQEBAQEBAQEBAQELguFPsFaQDQP9QAAAABJRU5ErkJggg==',
);

const _images = [
  api.Attachment(
    id: 'a1',
    filename: 'first.png',
    contentType: 'image/png',
    size: 2048,
  ),
  api.Attachment(
    id: 'a2',
    filename: 'second.png',
    contentType: 'image/png',
    size: 2048,
  ),
];

class _FakeExporter implements ImageExporter {
  _FakeExporter({required this.phone, this.saveError});

  final bool phone;
  final Object? saveError;

  final shared = <(String, Uint8List)>[];
  final saved = <(String, Uint8List)>[];

  @override
  bool get canShare => phone;

  @override
  bool get savesToLibrary => phone;

  @override
  Future<void> share(
    Uint8List bytes, {
    required String filename,
    required String contentType,
    Rect? origin,
  }) async {
    shared.add((filename, bytes));
  }

  @override
  Future<bool> save(Uint8List bytes, {required String filename}) async {
    if (saveError != null) throw saveError!;
    saved.add((filename, bytes));
    return true;
  }
}

final _secondBytes = Uint8List.fromList(const [9, 9, 9]);

Future<ProviderContainer> _open(
  WidgetTester tester,
  _FakeExporter exporter, {
  Size size = const Size(390, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      imageExporterProvider.overrideWithValue(exporter),
      attachmentBytesProvider('a2').overrideWith((ref) async => _secondBytes),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: FullscreenImageViewer(images: _images, index: 0, bytes: _png),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void _clearToasts(ProviderContainer container) {
  final notifier = container.read(toastsProvider.notifier);
  for (final toast in container.read(toastsProvider)) {
    notifier.dismiss(toast.id);
  }
}

void main() {
  testWidgets('a phone offers Share and Save to photos', (tester) async {
    await _open(tester, _FakeExporter(phone: true));
    expect(find.bySemanticsLabel('Share image'), findsOneWidget);
    expect(find.bySemanticsLabel('Save image to photos'), findsOneWidget);
  });

  testWidgets('a desktop offers Save as and no Share control', (tester) async {
    await _open(
      tester,
      _FakeExporter(phone: false),
      size: const Size(1400, 900),
    );
    expect(find.bySemanticsLabel('Share image'), findsNothing);
    expect(find.bySemanticsLabel('Save image as'), findsOneWidget);
  });

  testWidgets('the real exporter follows the platform, not the window', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(const PlatformImageExporter().canShare, isTrue);
    expect(const PlatformImageExporter().savesToLibrary, isTrue);

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(const PlatformImageExporter().canShare, isFalse);
    expect(const PlatformImageExporter().savesToLibrary, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Share hands the tapped image full bytes to the sheet', (
    tester,
  ) async {
    final exporter = _FakeExporter(phone: true);
    await _open(tester, exporter);
    await tester.tap(find.bySemanticsLabel('Share image'));
    await tester.pump();
    expect(exporter.shared, [('first.png', _png)]);
  });

  testWidgets('Save writes the bytes and confirms with a toast', (
    tester,
  ) async {
    final exporter = _FakeExporter(phone: true);
    final container = await _open(tester, exporter);
    await tester.tap(find.bySemanticsLabel('Save image to photos'));
    await tester.pump();
    expect(exporter.saved, [('first.png', _png)]);
    final toasts = container.read(toastsProvider);
    expect(toasts.single.message, 'Saved to photos.');
    expect(find.byType(AppErrorState), findsNothing);
    _clearToasts(container);
  });

  testWidgets('a sibling page saves its own fetched bytes', (tester) async {
    final exporter = _FakeExporter(phone: true);
    final container = await _open(tester, exporter);
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Save image to photos'));
    await tester.pump();
    expect(exporter.saved, [('second.png', _secondBytes)]);
    _clearToasts(container);
  });

  testWidgets('a refused photo permission is an error state, not a no-op', (
    tester,
  ) async {
    final exporter = _FakeExporter(
      phone: true,
      saveError: const PhotoLibraryDenied(),
    );
    final container = await _open(tester, exporter);
    await tester.tap(find.bySemanticsLabel('Save image to photos'));
    await tester.pump();
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.textContaining('allow photo access'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(container.read(toastsProvider), isEmpty);
  });
}
