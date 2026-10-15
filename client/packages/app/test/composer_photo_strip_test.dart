// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone composer's photo strip: opened from the Photo library entry,
/// docked under the field where the keyboard sits, attaching through the same
/// staging path as the system picker, and never a blank panel or a SnackBar.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/composer_photo_strip.dart';
import 'package:slimm_app/src/widgets/photo_library.dart';
import 'package:slimm_app/src/widgets/staged_attachment_tile.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

class _FakeLibrary implements PhotoLibrary {
  _FakeLibrary(this.access, {this.throws = false, this.total = 2});

  final bool throws;

  /// How many photos the camera roll holds.
  final int total;
  final requests = <int>[];

  PhotoAccess access;
  int manageCalls = 0;

  @override
  Future<PhotoAccess> requestAccess() async {
    if (throws) throw StateError('plugin missing');
    return access;
  }

  @override
  Future<List<RecentPhoto>> recent(int n) async {
    requests.add(n);
    return [for (var i = 0; i < n && i < total; i++) RecentPhoto('p$i')];
  }

  @override
  Future<Uint8List?> thumbnail(String id, int pixels) async => _png;

  @override
  Future<PhotoOriginal?> original(String id) async =>
      (bytes: _png, name: '$id.png');

  @override
  Future<void> manageLimited() async => manageCalls += 1;
}

Future<void> _openStrip(WidgetTester tester) async {
  await tester.tap(moreActionsButton);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Photo library'));
  await tester.pumpAndSettle();
}

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    controller = TextEditingController();
    sends = Sends();
  });
  tearDown(() => controller.dispose());

  Future<FakePicker> pump(WidgetTester tester, _FakeLibrary library) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final picker = usePicker(pickedFile());
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
        extraOverrides: [photoLibraryProvider.overrideWithValue(library)],
      ),
    );
    return picker;
  }

  testWidgets('Photo library docks a strip under the field and attaches both '
      'photos tapped', (tester) async {
    final picker = await pump(tester, _FakeLibrary(PhotoAccess.full));
    await _openStrip(tester);

    expect(picker.calls, 0, reason: 'the strip replaces the system picker');
    final tiles = find.bySemanticsLabel('Attach photo');
    expect(tiles, findsNWidgets(2));
    final tile = tester.getSize(tiles.first);
    expect(tile.width, tile.height, reason: 'square tiles');
    expect(tile.width, lessThanOrEqualTo(140));
    final field = tester.getRect(find.byType(TextField));
    expect(
      tester.getRect(tiles.first).top,
      greaterThan(field.bottom),
      reason: 'the strip sits below the field, where the keyboard would be',
    );
    expect(find.text('All photos'), findsOneWidget);

    await tester.tap(tiles.at(0));
    await tester.pumpAndSettle();
    await tester.tap(tiles.at(1));
    await tester.pumpAndSettle();

    expect(find.byType(StagedAttachmentTile), findsNWidgets(2));
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the All photos tile opens the full system picker', (
    tester,
  ) async {
    final picker = await pump(tester, _FakeLibrary(PhotoAccess.full));
    await _openStrip(tester);

    await tester.tap(find.text('All photos'));
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    expect(picker.lastType, FileType.image);
  });

  testWidgets('denied access says so inline and offers the system picker', (
    tester,
  ) async {
    final picker = await pump(tester, _FakeLibrary(PhotoAccess.denied));
    await _openStrip(tester);

    expect(find.textContaining('cannot see your photos'), findsOneWidget);
    expect(find.bySemanticsLabel('Attach photo'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);

    await tester.tap(find.text('Browse photos'));
    await tester.pumpAndSettle();

    expect(picker.lastType, FileType.image);
  });

  testWidgets('a plugin that throws lands on the inline fallback', (
    tester,
  ) async {
    final picker = await pump(
      tester,
      _FakeLibrary(PhotoAccess.full, throws: true),
    );
    await _openStrip(tester);

    expect(find.textContaining('cannot see your photos'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.text('Browse photos'));
    await tester.pumpAndSettle();
    expect(picker.lastType, FileType.image);
  });

  testWidgets('limited access labels the strip and can widen the grant', (
    tester,
  ) async {
    final library = _FakeLibrary(PhotoAccess.limited);
    await pump(tester, library);
    await _openStrip(tester);

    expect(find.text('Showing the photos you allowed'), findsOneWidget);
    expect(find.bySemanticsLabel('Attach photo'), findsNWidgets(2));

    await tester.tap(find.text('Allow more'));
    await tester.pumpAndSettle();

    expect(library.manageCalls, 1);
  });

  testWidgets('tapping the handle removes the strip', (tester) async {
    await pump(tester, _FakeLibrary(PhotoAccess.full));
    await _openStrip(tester);

    await tester.tap(find.bySemanticsLabel('Close photo strip'));
    await tester.pumpAndSettle();

    expect(find.byType(ComposerPhotoStrip), findsNothing);
  });

  testWidgets('without a photo library the entry still opens the picker', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final picker = usePicker(null);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
      ),
    );
    await _openStrip(tester);

    expect(find.byType(ComposerPhotoStrip), findsNothing);
    expect(picker.lastType, FileType.image);
  });

  testWidgets('at expanded width the strip draws nothing', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ComposerPhotoStrip(
              onAttach: (_) async {},
              onBrowse: () {},
              onClose: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Text), findsNothing);
    expect(tester.getSize(find.byType(ComposerPhotoStrip)), Size.zero);
  });

  testWidgets('the panel is a three column grid that scrolls down and loads '
      'more near the end', (tester) async {
    final library = _FakeLibrary(PhotoAccess.full, total: 200);
    await pump(tester, library);
    await _openStrip(tester);

    final tiles = find.bySemanticsLabel('Attach photo');
    final all = tester.getRect(
      find
          .ancestor(
            of: find.text('All photos'),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final first = tester.getRect(tiles.at(0));
    final second = tester.getRect(tiles.at(1));
    final third = tester.getRect(tiles.at(2));
    expect(first.top, all.top, reason: 'All photos leads the first row');
    expect(second.top, first.top);
    expect(third.top, greaterThan(first.bottom), reason: 'three per row');
    expect(library.requests, [60]);

    await tester.drag(find.byType(GridView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(library.requests.last, greaterThan(60));
    expect(find.byType(ComposerPhotoStrip), findsOneWidget);
  });

  testWidgets('swiping the handle down closes the panel', (tester) async {
    await pump(tester, _FakeLibrary(PhotoAccess.full));
    await _openStrip(tester);

    await tester.drag(find.bySemanticsLabel('Close photo strip'), const Offset(0, 160));
    await tester.pumpAndSettle();

    expect(find.byType(ComposerPhotoStrip), findsNothing);
  });

  testWidgets('a short pull springs back instead of closing', (tester) async {
    await pump(tester, _FakeLibrary(PhotoAccess.full));
    await _openStrip(tester);
    final before = tester.getRect(find.bySemanticsLabel('Close photo strip'));

    await tester.timedDrag(
      find.bySemanticsLabel('Close photo strip'),
      const Offset(0, 30),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ComposerPhotoStrip), findsOneWidget);
    expect(tester.getRect(find.bySemanticsLabel('Close photo strip')), before);
  });

  testWidgets('pulling down from the top of the grid closes the panel', (
    tester,
  ) async {
    await pump(tester, _FakeLibrary(PhotoAccess.full, total: 200));
    await _openStrip(tester);

    await tester.drag(find.byType(GridView), const Offset(0, 200));
    await tester.pumpAndSettle();

    expect(find.byType(ComposerPhotoStrip), findsNothing);
  });
}
