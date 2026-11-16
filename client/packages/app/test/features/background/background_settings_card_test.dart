// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Background card: choosing a picture, removing it, its controls, the
/// preview beside them in the control column, the note while a theme's
/// settings are in use, and the note shown while high contrast keeps panes
/// plain.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/background/providers/app_background_controller.dart';
import 'package:slimm_app/src/features/background/providers/background_image_store.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_picker.dart';
import 'package:slimm_app/src/providers/providers.dart'
    show preferencesProvider;
import 'package:slimm_app/src/features/settings/providers/background_from_theme.dart';
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/features/settings/widgets/background_preview.dart';
import 'package:slimm_app/src/features/settings/widgets/background_settings_card.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_control_column.dart';
import 'package:slimm_design_system/design_system.dart';

import '../composer/composer_harness.dart' show FakePlatformFile;

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  double width = 900,
  PlatformFile? picked,
  Object? failure,
  bool column = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      backgroundImageStoreProvider.overrideWithValue(
        MemoryBackgroundImageStore(),
      ),
      for (final source in AttachmentSource.values)
        attachmentPickerProvider(source).overrideWithValue(() async {
          if (failure != null) throw failure;
          return picked;
        }),
    ],
  );
  addTearDown(container.dispose);
  await tester.runAsync(() => container.read(preferencesProvider.future));
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: column
                ? const SettingsControlColumn(child: BackgroundSettingsCard())
                : const BackgroundSettingsCard(),
          ),
        ),
      ),
    ),
  );
  return container;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

final _forest = File('test/fixtures/background_forest.png').readAsBytesSync();

Future<void> _withPicture(WidgetTester tester, ProviderContainer c) async {
  await tester.runAsync(
    () =>
        c.read(appBackgroundControllerProvider.notifier).importPicture(_forest),
  );
  await tester.runAsync(() => c.read(backgroundPictureProvider.future));
  await tester.pump();
}

const _note = 'Dim, vignette and blur came with Pine at dusk.';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (width, beside) in [(900.0, true), (390.0, false)]) {
    testWidgets('at $width wide the preview is ${beside ? 'beside' : 'above'} '
        'the controls', (tester) async {
      final container = await _mount(tester, width: width, column: true);
      await _withPicture(tester, container);

      final preview = tester.getRect(find.byKey(BackgroundPreview.previewKey));
      final dim = tester.getRect(
        find.byKey(BackgroundSettingsCard.dimSliderKey),
      );
      if (beside) {
        expect(dim.left + AppSlider.trackInset - preview.right, 16);
        expect(preview.height, greaterThanOrEqualTo(BackgroundPreview.height));
      } else {
        expect(preview.bottom, lessThan(dim.top));
        expect(preview.width, width - 32);
        expect(preview.height, BackgroundPreview.height);
      }
    });
  }

  testWidgets('a theme\'s settings are noted until one is changed here', (
    tester,
  ) async {
    final container = await _mount(tester, column: true);
    await _withPicture(tester, container);
    await tester.runAsync(
      () => container
          .read(backgroundFromThemeProvider.notifier)
          .set('Pine at dusk'),
    );
    await tester.pump();
    expect(find.text(_note), findsOneWidget);

    await tester.drag(
      find.byKey(BackgroundSettingsCard.blurSliderKey),
      const Offset(60, 0),
    );
    await tester.pump();
    await _settle(tester);

    expect(find.text(_note), findsNothing);
    expect(container.read(backgroundFromThemeProvider), isNull);
  });

  testWidgets('turning the vignette off makes the settings the person\'s', (
    tester,
  ) async {
    final container = await _mount(tester);
    await _withPicture(tester, container);
    await tester.runAsync(
      () => container
          .read(backgroundFromThemeProvider.notifier)
          .set('Pine at dusk'),
    );
    await tester.pump();

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Vignette'),
          matching: find.byWidgetPredicate((w) => w is Row),
        ),
        matching: find.byWidgetPredicate((w) => w is AppToggle),
      ),
    );
    await _settle(tester);

    expect(container.read(backgroundFromThemeProvider), isNull);
  });

  testWidgets('on a phone the picture sheet says what it is for', (
    tester,
  ) async {
    await _mount(tester, width: 390);
    await tester.tap(find.byKey(BackgroundSettingsCard.pictureRowKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Background picture'), findsOneWidget);
    expect(find.text('Choose photo'), findsOneWidget);
  });

  testWidgets('beside the pointer the picture menu needs no title', (
    tester,
  ) async {
    await _mount(tester);
    await tester.tap(find.byKey(BackgroundSettingsCard.pictureRowKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Background picture'), findsNothing);
    expect(find.text('Choose photo'), findsOneWidget);
  });

  for (final (width, glyph) in [
    (900.0, AppIcons.chevronDown),
    (390.0, AppIcons.chevronRight),
  ]) {
    testWidgets('the picture row ends in a chevron that fits $width wide', (
      tester,
    ) async {
      await _mount(tester, width: width);
      expect(
        find.descendant(
          of: find.byKey(BackgroundSettingsCard.pictureRowKey),
          matching: find.byIcon(glyph),
        ),
        findsOneWidget,
      );
    });
  }

  testWidgets('starts at None with no controls', (tester) async {
    await _mount(tester);
    expect(find.text('None'), findsOneWidget);
    expect(find.byKey(BackgroundSettingsCard.dimSliderKey), findsNothing);
    expect(find.byKey(BackgroundSettingsCard.pictureRowKey), findsOneWidget);
  });

  testWidgets('choosing a photo sets it and shows the controls', (
    tester,
  ) async {
    final container = await _mount(
      tester,
      picked: FakePlatformFile('f.png', _forest),
    );
    await tester.runAsync(
      () => container
          .read(backgroundFromThemeProvider.notifier)
          .set('Pine at dusk'),
    );
    await tester.tap(find.byKey(BackgroundSettingsCard.pictureRowKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Choose photo'));
    await tester.pump();
    await _settle(tester);
    expect(container.read(appBackgroundControllerProvider).hasImage, isTrue);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.byKey(BackgroundSettingsCard.dimSliderKey), findsOneWidget);
    expect(find.text('Vignette'), findsOneWidget);
    expect(find.byKey(BackgroundSettingsCard.blurSliderKey), findsOneWidget);
    expect(
      container.read(backgroundFromThemeProvider),
      isNull,
      reason: 'a picture chosen here is the person\'s own',
    );
  });

  testWidgets('None removes the picture again', (tester) async {
    final container = await _mount(tester);
    await tester.runAsync(
      () => container
          .read(appBackgroundControllerProvider.notifier)
          .importPicture(
            File('test/fixtures/background_forest.png').readAsBytesSync(),
          ),
    );
    await tester.runAsync(
      () => container.read(backgroundPictureProvider.future),
    );
    await tester.pump();
    await tester.tap(find.byKey(BackgroundSettingsCard.pictureRowKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('None'));
    await tester.pump();
    await _settle(tester);
    expect(container.read(appBackgroundControllerProvider).hasImage, isFalse);
    expect(find.byKey(BackgroundSettingsCard.dimSliderKey), findsNothing);
  });

  testWidgets('the X on the picture row removes it in one tap', (tester) async {
    final container = await _mount(tester);
    expect(find.byKey(BackgroundSettingsCard.removeKey), findsNothing);
    await tester.runAsync(
      () => container
          .read(appBackgroundControllerProvider.notifier)
          .importPicture(
            File('test/fixtures/background_forest.png').readAsBytesSync(),
          ),
    );
    await tester.runAsync(
      () => container.read(backgroundPictureProvider.future),
    );
    await tester.pump();
    await tester.runAsync(
      () => container
          .read(backgroundFromThemeProvider.notifier)
          .set('Pine at dusk'),
    );
    await tester.tap(find.byKey(BackgroundSettingsCard.removeKey));
    await tester.pump();
    await _settle(tester);
    expect(container.read(appBackgroundControllerProvider).hasImage, isFalse);
    expect(container.read(backgroundFromThemeProvider), isNull);
    expect(find.text('Choose photo'), findsNothing);
    expect(find.byKey(BackgroundSettingsCard.removeKey), findsNothing);
  });

  testWidgets('a file that is not a picture shows a persistent error', (
    tester,
  ) async {
    final junk = List<int>.filled(32, 7);
    final container = await _mount(
      tester,
      picked: FakePlatformFile('x.png', Uint8List.fromList(junk)),
    );
    await tester.tap(find.byKey(BackgroundSettingsCard.pictureRowKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Browse files'));
    await tester.pump();
    await _settle(tester);
    expect(find.textContaining('could not be used'), findsOneWidget);
    expect(container.read(appBackgroundControllerProvider).hasImage, isFalse);
  });

  testWidgets('high contrast hides the controls and says why', (tester) async {
    final container = await _mount(tester);
    await tester.runAsync(() async {
      await container
          .read(appBackgroundControllerProvider.notifier)
          .importPicture(
            File('test/fixtures/background_forest.png').readAsBytesSync(),
          );
      await container
          .read(highContrastControllerProvider.notifier)
          .select(true);
    });
    await tester.runAsync(
      () => container.read(backgroundPictureProvider.future),
    );
    await tester.pump();
    expect(find.text('Off while high contrast is on.'), findsOneWidget);
    expect(find.byKey(BackgroundSettingsCard.dimSliderKey), findsNothing);
  });
}
