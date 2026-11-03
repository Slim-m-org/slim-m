// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Background card: choosing a picture, removing it, its controls, and
/// the note shown while high contrast keeps panes plain.
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
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/features/settings/widgets/background_settings_card.dart';
import 'package:slimm_design_system/design_system.dart';

import '../composer/composer_harness.dart' show FakePlatformFile;

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  PlatformFile? picked,
  Object? failure,
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
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: SingleChildScrollView(child: BackgroundSettingsCard()),
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('starts at None with no controls', (tester) async {
    await _mount(tester);
    expect(find.text('None'), findsOneWidget);
    expect(find.byKey(BackgroundSettingsCard.dimSliderKey), findsNothing);
    expect(find.byKey(BackgroundSettingsCard.pictureRowKey), findsOneWidget);
  });

  testWidgets('choosing a photo sets it and shows the controls', (
    tester,
  ) async {
    final bytes = File('test/fixtures/background_forest.png').readAsBytesSync();
    final container = await _mount(
      tester,
      picked: FakePlatformFile('f.png', bytes),
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
