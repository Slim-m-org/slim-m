// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer field's context-menu fix: forcing the iOS 16+ system menu
/// to offer Paste for an image.
///
/// [systemContextMenuItemsWithForcedPaste] is pure, so its two cases (adds
/// the item, never duplicates it) need no platform channel and no device.
/// [ClipboardImageStatusNotifier] is proven at the same
/// `top.npcserver.slimm/clipboard_image` channel `composer_clipboard_image_
/// test.dart` already drives, with one property load-bearing enough to name
/// as its own test: it must never call the prompting `readImage`, only the
/// metadata-only `hasImage` - see `composer_context_menu.dart`'s doc comment
/// for why that distinction is the whole point of this fix.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_context_menu.dart';

import 'composer_harness.dart';

const _channel = MethodChannel('top.npcserver.slimm/clipboard_image');

void _mock(Future<Object?> Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, handler);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('systemContextMenuItemsWithForcedPaste', () {
    test('adds the system Paste item when the clipboard holds an image', () {
      final items = systemContextMenuItemsWithForcedPaste(
        const [],
        clipboardHasImage: true,
      );
      expect(items, [isA<IOSSystemContextMenuItemPaste>()]);
    });

    test('adds nothing when the clipboard holds no image', () {
      final items = systemContextMenuItemsWithForcedPaste(
        const [],
        clipboardHasImage: false,
      );
      expect(items, isEmpty);
    });

    test('never duplicates a Paste item the defaults already offered', () {
      final items = systemContextMenuItemsWithForcedPaste(const [
        IOSSystemContextMenuItemPaste(),
      ], clipboardHasImage: true);
      expect(items, [isA<IOSSystemContextMenuItemPaste>()]);
    });

    test('leaves unrelated default items untouched', () {
      final items = systemContextMenuItemsWithForcedPaste(const [
        IOSSystemContextMenuItemCopy(),
      ], clipboardHasImage: true);
      expect(items, [
        isA<IOSSystemContextMenuItemCopy>(),
        isA<IOSSystemContextMenuItemPaste>(),
      ]);
    });
  });

  group('systemContextMenuItemsWithoutScanText', () {
    test('drops the Live Text (scan text) item', () {
      final items = systemContextMenuItemsWithoutScanText(const [
        IOSSystemContextMenuItemCopy(),
        IOSSystemContextMenuItemLiveText(),
        IOSSystemContextMenuItemPaste(),
      ]);
      expect(items, [
        isA<IOSSystemContextMenuItemCopy>(),
        isA<IOSSystemContextMenuItemPaste>(),
      ]);
    });

    test('leaves the list untouched when Live Text is not offered', () {
      final items = systemContextMenuItemsWithoutScanText(const [
        IOSSystemContextMenuItemCopy(),
      ]);
      expect(items, [isA<IOSSystemContextMenuItemCopy>()]);
    });

    test(
      'composes with forced paste: scan text stays gone, paste is added',
      () {
        final items = systemContextMenuItemsWithForcedPaste(
          systemContextMenuItemsWithoutScanText(const [
            IOSSystemContextMenuItemLiveText(),
          ]),
          clipboardHasImage: true,
        );
        expect(items, [isA<IOSSystemContextMenuItemPaste>()]);
      },
    );
  });

  group('contextMenuButtonItemsWithoutScanText', () {
    test('drops the liveTextInput button', () {
      final items = contextMenuButtonItemsWithoutScanText([
        const ContextMenuButtonItem(
          onPressed: null,
          type: ContextMenuButtonType.copy,
        ),
        const ContextMenuButtonItem(
          onPressed: null,
          type: ContextMenuButtonType.liveTextInput,
        ),
      ]);
      expect(items, [
        isA<ContextMenuButtonItem>().having(
          (item) => item.type,
          'type',
          ContextMenuButtonType.copy,
        ),
      ]);
    });

    test('leaves the list untouched when liveTextInput is not offered', () {
      final items = contextMenuButtonItemsWithoutScanText([
        const ContextMenuButtonItem(
          onPressed: null,
          type: ContextMenuButtonType.paste,
        ),
      ]);
      expect(items, hasLength(1));
      expect(items.single.type, ContextMenuButtonType.paste);
    });
  });

  group('ClipboardImageStatusNotifier', () {
    late List<String> calledMethods;

    setUp(() {
      calledMethods = [];
      _mock((call) async {
        calledMethods.add(call.method);
        return call.method == 'hasImage';
      });
    });

    tearDown(() => _mock(null));

    test('picks up the clipboard state on construction', () async {
      final notifier = ClipboardImageStatusNotifier();
      addTearDown(notifier.dispose);

      await Future<void>.delayed(Duration.zero);
      expect(notifier.value, isTrue);
    });

    test('update never calls the prompting readImage, only the metadata-only '
        'hasImage (regression guard: this is the whole reason nothing here '
        'raises "Allow Paste?" on its own)', () async {
      final notifier = ClipboardImageStatusNotifier();
      addTearDown(notifier.dispose);

      await notifier.update();

      expect(calledMethods, everyElement('hasImage'));
      expect(calledMethods, isNot(contains('readImage')));
    });

    test('refreshes when the app resumes', () async {
      final notifier = ClipboardImageStatusNotifier();
      addTearDown(notifier.dispose);
      await Future<void>.delayed(Duration.zero);
      calledMethods.clear();

      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await Future<void>.delayed(Duration.zero);

      expect(calledMethods, ['hasImage']);
    });

    test('a disposed notifier ignores an in-flight update', () async {
      final notifier = ClipboardImageStatusNotifier();
      final update = notifier.update();
      notifier.dispose();

      await update;
      // Not throwing is the assertion: a disposed ValueNotifier raises on set.
    });
  });

  group('composerContextMenuBuilder formatting actions', () {
    Future<EditableTextState> pumpField(
      WidgetTester tester,
      TextEditingController controller,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Material(child: TextField(controller: controller)),
        ),
      );
      return tester.state<EditableTextState>(find.byType(EditableText));
    }

    List<ContextMenuButtonItem> buttonItemsFor(
      WidgetTester tester,
      EditableTextState state, {
      required bool offerFormatting,
    }) {
      final widget = composerContextMenuBuilder(
        tester.element(find.byType(EditableText)),
        state,
        clipboardHasImage: false,
        offerFormatting: offerFormatting,
      );
      return (widget as AdaptiveTextSelectionToolbar).buttonItems!;
    }

    testWidgets(
      'offers Bold, Italic, Strikethrough and Code over a real selection '
      'at touch density',
      (tester) async {
        final controller = TextEditingController(text: 'hello world');
        addTearDown(controller.dispose);
        controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        final state = await pumpField(tester, controller);

        final labels = buttonItemsFor(
          tester,
          state,
          offerFormatting: true,
        ).map((item) => item.label);

        expect(
          labels,
          containsAll(['Bold', 'Italic', 'Strikethrough', 'Code']),
        );
      },
    );

    testWidgets(
      'offers nothing extra when offerFormatting is false (desktop width, '
      'where the keyboard shortcut already reaches this)',
      (tester) async {
        final controller = TextEditingController(text: 'hello world');
        addTearDown(controller.dispose);
        controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        final state = await pumpField(tester, controller);

        final labels = buttonItemsFor(
          tester,
          state,
          offerFormatting: false,
        ).map((item) => item.label);

        expect(labels, isNot(contains('Bold')));
      },
    );

    testWidgets(
      'offers nothing extra over a collapsed caret: there is no selection '
      'to wrap',
      (tester) async {
        final controller = TextEditingController(text: 'hello world');
        addTearDown(controller.dispose);
        controller.selection = const TextSelection.collapsed(offset: 3);
        final state = await pumpField(tester, controller);

        final labels = buttonItemsFor(
          tester,
          state,
          offerFormatting: true,
        ).map((item) => item.label);

        expect(labels, isNot(contains('Bold')));
      },
    );

    testWidgets('tapping Bold wraps the selection exactly as Ctrl/Cmd+B does', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      final state = await pumpField(tester, controller);

      final bold = buttonItemsFor(
        tester,
        state,
        offerFormatting: true,
      ).firstWhere((item) => item.label == 'Bold');
      bold.onPressed!();

      expect(controller.text, '**hello** world');
    });
  });

  group('wired into the composer field', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(() => _mock(null));

    testWidgets('the field offers its own formatting items in the menu', (
      tester,
    ) async {
      _mock((call) async => call.method == 'hasImage');
      final controller = TextEditingController(text: 'hello');
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: Sends(),
          platform: TargetPlatform.iOS,
        ),
      );
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.pump();

      final state = tester.state<EditableTextState>(find.byType(EditableText));
      final builder = tester
          .widget<TextField>(find.byType(TextField))
          .contextMenuBuilder!;
      final menu =
          builder(state.context, state) as AdaptiveTextSelectionToolbar;

      expect(
        menu.buttonItems!.map((item) => item.label),
        containsAll(['Bold', 'Italic']),
      );
    });
  });
}
