// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone composer's recent-photos panel: a grab handle, then a three
/// column grid led by All photos, in both themes. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise this asserts a clean layout.
library;

import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_photo_strip.dart';
import 'package:slimm_app/src/widgets/photo_library.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

/// Flat colour tiles, so the snapshot shows the grid and not photo content.
class _SwatchLibrary implements PhotoLibrary {
  _SwatchLibrary(this.swatches);
  final List<Uint8List> swatches;

  @override
  Future<PhotoAccess> requestAccess() async => PhotoAccess.full;
  @override
  Future<List<RecentPhoto>> recent(int n) async => [
    for (var i = 0; i < 30; i++) RecentPhoto('$i'),
  ];
  @override
  Future<Uint8List?> thumbnail(String id, int pixels) async =>
      swatches[int.parse(id) % swatches.length];
  @override
  Future<PhotoOriginal?> original(String id) async => null;
  @override
  Future<void> manageLimited() async {}
}

Future<Uint8List> _swatch(Color color) async {
  final recorder = PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  final image = await recorder.endRecording().toImage(8, 8);
  final bytes = await image.toByteData(format: ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

void main() {
  setUpAll(loadRealFonts);
  for (final theme in const ['dark', 'light']) {
    testWidgets('photo panel phone ($theme)', (tester) async {
      tester.view.physicalSize = const Size(390, 520);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final swatches = await tester.runAsync(
        () => Future.wait([
          for (final c in const [
            Color(0xFF6B8E9E),
            Color(0xFFB07D62),
            Color(0xFF7A9A6B),
            Color(0xFF9C7AA8),
          ])
            _swatch(c),
        ]),
      );
      final dark = theme == 'dark';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            photoLibraryProvider.overrideWithValue(_SwatchLibrary(swatches!)),
          ],
          child: RepaintBoundary(
            key: snapshotBoundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(
                dark ? Brightness.dark : Brightness.light,
                dark ? AppTokens.dark : AppTokens.light,
              ),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.s16),
                    child: ComposerPhotoStrip(
                      onAttach: (_) async {},
                      onBrowse: () {},
                      onClose: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('All photos'), findsOneWidget);
      await writeSnapshot(tester, 'photo-panel-phone-$theme');
    });
  }
}
