// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/slow_mode_controller.dart';

import 'composer_harness.dart';

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });
  tearDown(() => controller.dispose());

  testWidgets('Enter with a file still uploading must not send', (t) async {
    final gate = Completer<void>();
    usePicker(pickedFile());
    await t.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: gatedUploadApi(gate),
      ),
    );
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(attachButton);
    await t.pump();
    await t.pump();
    expect(find.text('Uploading...'), findsOneWidget);
    await t.tap(find.byType(TextField));
    await t.enterText(find.byType(TextField), 'hi');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(sends.count, 0, reason: 'send must be refused while uploading');
    expect(find.text('holiday.png'), findsOneWidget);
    gate.complete();
    await t.pumpAndSettle();
  });

  testWidgets('Enter over the character limit must not send', (t) async {
    await t.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
      ),
    );
    await t.tap(find.byType(TextField));
    await t.enterText(find.byType(TextField), 'a' * 4005);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(sends.count, 0);
  });

  testWidgets('Enter during slow mode must not send', (t) async {
    await t.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        extraOverrides: [
          slowModeRemainingSecondsProvider.overrideWith((ref, c) => 4),
        ],
      ),
    );
    await t.tap(find.byType(TextField));
    await t.enterText(find.byType(TextField), 'hello');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(sends.count, 0);
  });

  testWidgets('Enter with plain text sends it once', (t) async {
    await t.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
      ),
    );
    await t.tap(find.byType(TextField));
    await t.enterText(find.byType(TextField), 'hello');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(sends.count, 1);
  });
}
