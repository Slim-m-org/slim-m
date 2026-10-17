// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the composer's send paths.
///
/// The defect these pin: the composer's only send trigger was a hardware
/// Enter key, which a soft keyboard cannot produce, so the app could not send
/// a message on a phone at all. Two paths now exist, and the desktop
/// shift+enter contract has to survive both.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_extras.dart';
import 'package:slimm_design_system/design_system.dart';

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

  testWidgets('a tap on the send button sends what was typed', (tester) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
      ),
    );

    await tester.enterText(find.byType(TextField), 'hello there');
    await tester.pump();
    await tester.tap(sendButton);
    await tester.pump();

    expect(sends.count, 1);
    expect(sends.ids, isEmpty);
  });

  testWidgets('the send button is disabled until there is something to send', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
      ),
    );

    expect(tester.widget<AppIconButton>(sendButton).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(tester.widget<AppIconButton>(sendButton).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    expect(tester.widget<AppIconButton>(sendButton).onPressed, isNotNull);
  });

  testWidgets(
    'on a touch platform the field asks the engine to send, not to insert '
    'a newline',
    (tester) async {
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.iOS,
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(
        tester.testTextInput.setClientArgs!['inputAction'],
        'TextInputAction.send',
      );
    },
  );

  testWidgets(
    "the soft keyboard's send action sends and leaves the keyboard up",
    (tester) async {
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.iOS,
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'hello there');
      await tester.pump();

      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();

      expect(sends.count, 1);
      expect(tester.testTextInput.isRegistered, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
    },
  );

  // An iPad is a soft-keyboard platform with a real Enter key, and one press
  // arrives twice: the engine performs the send action, the framework the key.
  testWidgets('a hardware return on a touch platform sends exactly once', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'hello there');
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      sends.count,
      1,
      reason:
          'the shortcut and the send action must not both be live on '
          'one platform',
    );
  });

  testWidgets(
    'on desktop the field keeps the newline action and its shortcut',
    (tester) async {
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'hello there');
      await tester.pump();

      expect(
        tester.testTextInput.setClientArgs!['inputAction'],
        'TextInputAction.newline',
      );

      // The framework half only: the newline INSERTION is the engine's work
      // (services/raw_keyboard.dart), so a widget test cannot observe it.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(sends.count, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sends.count, 1);
    },
  );

  testWidgets(
    'the shift + enter hint is gone on both touch and desktop, and the '
    'shortcut it used to describe still sends',
    (tester) async {
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.iOS,
        ),
      );
      expect(find.text('shift + enter for newline'), findsNothing);

      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
        ),
      );
      // MaterialApp lerps its theme, and ThemeData.lerp switches `platform` at
      // the halfway point, so the new value is not readable in the same frame.
      await tester.pump(kThemeAnimationDuration);
      expect(find.text('shift + enter for newline'), findsNothing);

      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'hello there');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(
        sends.count,
        0,
        reason: 'shift+enter must still insert a newline, not send',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        sends.count,
        1,
        reason: 'a bare enter must still send, hint or not',
      );
    },
  );

  group('touch density', () {
    testWidgets('a phone gets 44pt controls and keeps a usable field', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.iOS,
        ),
      );

      // Three at phone density, not the desktop test's five: poll and code
      // fold into the "+" sheet here. Without this the loop can walk nothing.
      expect(find.byType(AppIconButton), findsNWidgets(3));
      for (final element in find.byType(AppIconButton).evaluate()) {
        expect(
          tester.getSize(find.byWidget(element.widget)).shortestSide,
          greaterThanOrEqualTo(AppSizes.rowTouch),
        );
      }
      // Five 44pt controls would leave 90, measured. Nothing about the touch
      // pass is worth a composer you cannot read what you typed in.
      expect(
        tester.getSize(find.byType(ComposerField)).width,
        greaterThan(160.0),
      );
    });

    testWidgets('what leaves the row is still reachable from it', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.iOS,
        ),
      );

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is AppIconButton && w.semanticLabel == 'More actions',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Photo library'), findsOneWidget);
      expect(find.text('Browse files'), findsOneWidget);
      expect(find.text('Create a poll'), findsOneWidget);
      expect(find.text('Insert code'), findsOneWidget);
    });

    testWidgets('a desktop window keeps every control on the row at 30pt', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
        ),
      );

      expect(find.byType(AppIconButton), findsNWidgets(5));
      for (final element in find.byType(AppIconButton).evaluate()) {
        expect(
          tester.getSize(find.byWidget(element.widget)).shortestSide,
          AppSizes.rowPointer,
        );
      }
    });
  });
}
