// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A photo strip whose list shifts keeps each tile's thumbnail with its own photo.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_photo_strip.dart';
import 'package:slimm_app/src/features/composer/widgets/photo_library.dart';
import 'package:slimm_design_system/design_system.dart';

/// One-pixel PNGs, a different colour per photo so a tile's picture names its photo.
final _pixels = <String, Uint8List>{
  'red': base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC',
  ),
  'green': base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNg+M8AAAICAQB7CYF4AAAAAElFTkSuQmCC',
  ),
  'blue': base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC',
  ),
};

class _ShiftingLibrary implements PhotoLibrary {
  List<String> ids = ['red', 'green'];

  /// What "Allow more" leaves in the library.
  List<String> afterManage = ['blue', 'red', 'green'];

  @override
  Future<PhotoAccess> requestAccess() async => PhotoAccess.limited;

  @override
  Future<List<RecentPhoto>> recent(int n) async => [
    for (final id in ids) RecentPhoto(id),
  ];

  @override
  Future<Uint8List?> thumbnail(String id, int pixels) async => _pixels[id];

  @override
  Future<PhotoOriginal?> original(String id) async =>
      (bytes: _pixels[id]!, name: id);

  @override
  Future<void> manageLimited() async => ids = afterManage;
}

Uint8List _thumbOf(WidgetTester tester, Finder tile) {
  final image = tester.widget<Image>(
    find.descendant(
      of: tile,
      matching: find.byWidgetPredicate((w) => w is Image),
    ),
  );
  return (image.image as MemoryImage).bytes;
}

void main() {
  testWidgets('a shifted list keeps each thumbnail on its own photo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final library = _ShiftingLibrary();
    final attached = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [photoLibraryProvider.overrideWithValue(library)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ComposerPhotoStrip(
              onAttach: (photo) async => attached.add(photo.name),
              onBrowse: () {},
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Allow more'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    final tiles = find.bySemanticsLabel('Attach photo');
    expect(tiles, findsNWidgets(3));
    expect(_thumbOf(tester, tiles.at(0)), _pixels['blue']);
    expect(_thumbOf(tester, tiles.at(1)), _pixels['red']);
    expect(_thumbOf(tester, tiles.at(2)), _pixels['green']);

    await tester.tap(tiles.at(0));
    await tester.pump(const Duration(milliseconds: 50));
    expect(attached, ['blue']);
  });
}
