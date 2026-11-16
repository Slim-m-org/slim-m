// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// + then Photo library opens the phone photo strip whatever the channel saw
/// first, not only as the first thing done in it (tester report 2026-11-11).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/photo_library.dart';
import 'package:slimm_app/src/features/composer/widgets/staged_attachment_model.dart';

import '../../support/mid_flight_capture.dart';
import 'composer_harness.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

class _Library implements PhotoLibrary {
  @override
  Future<PhotoAccess> requestAccess() async => PhotoAccess.full;

  @override
  Future<List<RecentPhoto>> recent(int n) async => const [
    RecentPhoto('a'),
    RecentPhoto('b'),
  ];

  @override
  Future<Uint8List?> thumbnail(String id, int pixels) async => _png;

  @override
  Future<FileSource?> original(String id) async =>
      MemoryFile('$id.png', _png).source;

  @override
  Future<void> manageLimited() async {}
}

final _field = find.byWidgetPredicate((w) => w is EditableText);
final _photoTiles = find.bySemanticsLabel('Attach photo');

void main() {
  late TextEditingController controller;
  late Sends sends;
  final library = _Library();

  setUp(() {
    controller = TextEditingController();
    sends = Sends();
  });
  tearDown(() => controller.dispose());

  /// Long enough for a sheet to finish opening or closing.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pump(WidgetTester tester, {String channelId = 'c1'}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.android,
        channelId: channelId,
        extraOverrides: [photoLibraryProvider.overrideWithValue(library)],
      ),
    );
  }

  Future<void> pick(WidgetTester tester, String entry) async {
    await tester.tap(moreActionsButton);
    await settle(tester);
    await tester.tap(find.text(entry));
    await settle(tester);
  }

  Future<void> expectStripOpen(WidgetTester tester, String name) async {
    await expectSettled(tester, name);
    expect(_photoTiles, findsNWidgets(2), reason: 'the strip is open');
    expect(
      tester.testTextInput.isVisible,
      isFalse,
      reason: 'the strip sits where the keyboard was',
    );
  }

  testWidgets('opens again after the field took the keyboard back from it', (
    tester,
  ) async {
    await pump(tester);
    await pick(tester, 'Photo library');
    await expectStripOpen(tester, 'first open');

    await tester.tap(_field);
    await settle(tester);
    expect(_photoTiles, findsNothing);
    expect(tester.testTextInput.isVisible, isTrue);

    await pick(tester, 'Photo library');
    await expectStripOpen(tester, 'second open');
  });

  testWidgets('opens after a message was typed and the field kept focus', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(_field);
    await tester.enterText(_field, 'hello');
    await settle(tester);

    await pick(tester, 'Photo library');

    await expectStripOpen(tester, 'after typing');
    expect(controller.text, 'hello');
  });

  testWidgets('opens again after the handle closed it', (tester) async {
    await pump(tester);
    await pick(tester, 'Photo library');
    await tester.tap(find.bySemanticsLabel('Close photo strip'));
    await settle(tester);
    expect(_photoTiles, findsNothing);

    await pick(tester, 'Photo library');
    await expectStripOpen(tester, 'reopened');
  });

  testWidgets('opens after another entry of the same sheet ran first', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(_field);
    await settle(tester);
    await pick(tester, 'Create a poll');
    expect(find.text('Ranked choice'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await settle(tester);
    expect(tester.testTextInput.isVisible, isTrue);

    await pick(tester, 'Photo library');
    await expectStripOpen(tester, 'after a poll');
  });

  testWidgets('opens after switching to another channel and back', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(_field);
    await settle(tester);
    await pump(tester, channelId: 'c2');
    await settle(tester);
    await pump(tester);
    await settle(tester);

    await pick(tester, 'Photo library');
    await expectStripOpen(tester, 'after a channel switch');
  });
}
