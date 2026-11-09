// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ctrl+V in the composer when the clipboard carries a picture beside its text.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'composer_harness.dart';

const _imageChannel = MethodChannel('top.npcserver.slimm/clipboard_image');

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void _clipboard({required bool holdsText}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_imageChannel, (call) async {
    return call.method == 'hasImage' ? true : _png;
  });
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    return call.method == 'Clipboard.hasStrings'
        ? <String, Object?>{'value': holdsText}
        : null;
  });
}

Future<void> _pressPaste(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  late TextEditingController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
  });

  tearDown(() {
    controller.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_imageChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpFocused(WidgetTester tester) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: Sends(),
        platform: TargetPlatform.linux,
      ),
    );
    await tester.tap(find.byWidgetPredicate((w) => w is EditableText));
    await tester.pump();
  }

  testWidgets('a picture alone is staged by Ctrl+V', (tester) async {
    _clipboard(holdsText: false);
    await pumpFocused(tester);

    await _pressPaste(tester);

    expect(find.text('pasted-image.png'), findsOneWidget);
  });

  testWidgets('a picture beside text leaves Ctrl+V to the text', (
    tester,
  ) async {
    _clipboard(holdsText: true);
    await pumpFocused(tester);

    await _pressPaste(tester);

    expect(find.text('pasted-image.png'), findsNothing);
  });
}
