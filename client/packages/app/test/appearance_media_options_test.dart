// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Operates the Appearance density row and every Media and cache row through
/// the pane, and asserts the controller each one writes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_quality.dart';
import 'package:slimm_app/src/features/settings/providers/display_density.dart';
import 'package:slimm_app/src/features/messages/providers/image_cache_preference.dart';
import 'package:slimm_app/src/features/messages/providers/media_preferences.dart';
import 'package:slimm_app/src/features/settings/widgets/appearance_settings_section.dart';
import 'package:slimm_app/src/features/settings/widgets/performance_settings_section.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_design_system/design_system.dart';

Future<ProviderContainer> _pump(WidgetTester tester, Widget pane) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: SingleChildScrollView(child: pane)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _choose<T>(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.byType(SettingsSelectRow<T>));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(SettingsSelectRow<T>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('each Density segment sets the message density', (tester) async {
    final c = await _pump(tester, const AppearanceSettingsSection());
    expect(c.read(messageDensityControllerProvider), AppDensity.normal);

    await tester.tap(find.text('Compact'));
    await tester.pumpAndSettle();
    expect(c.read(messageDensityControllerProvider), AppDensity.compact);

    await tester.tap(find.text('Spacious'));
    await tester.pumpAndSettle();
    expect(c.read(messageDensityControllerProvider), AppDensity.spacious);

    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    expect(c.read(messageDensityControllerProvider), AppDensity.normal);
  });

  group('Media and cache', () {
    testWidgets('Auto-download media writes the controller and storage', (
      tester,
    ) async {
      final c = await _pump(tester, const PerformanceSettingsSection());
      await _choose<MediaAutoDownload>(tester, 'Only when I tap');
      expect(
        c.read(mediaAutoDownloadControllerProvider),
        MediaAutoDownload.manual,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(mediaAutoDownloadKey), 'manual');
    });

    testWidgets('Autoplay GIFs writes the controller and storage', (
      tester,
    ) async {
      final c = await _pump(tester, const PerformanceSettingsSection());
      await _choose<GifAutoplay>(tester, 'Always');
      expect(c.read(gifAutoplayControllerProvider), GifAutoplay.autoplay);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(gifAutoplayKey), 'autoplay');
    });

    testWidgets('Attachment preview quality writes the controller', (
      tester,
    ) async {
      final c = await _pump(tester, const PerformanceSettingsSection());
      await _choose<AttachmentPreviewQuality>(
        tester,
        AttachmentPreviewQuality.dataSaver.label,
      );
      expect(
        c.read(attachmentPreviewQualityControllerProvider),
        AttachmentPreviewQuality.dataSaver,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(attachmentPreviewQualityKey), isNotNull);
    });

    testWidgets('Image cache writes the chosen limit', (tester) async {
      final c = await _pump(tester, const PerformanceSettingsSection());
      await _choose<int>(tester, '200 MB');
      expect(c.read(imageCacheLimitControllerProvider), 200);
    });
  });
}
