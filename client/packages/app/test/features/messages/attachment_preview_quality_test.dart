// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The attachment-preview-quality setting: the default is Sharp (the
/// full-resolution decode this app has always done), a choice persists and
/// restores, an unknown stored value degrades to the default, and each level
/// carries the decode scale and label the picker draws.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_quality.dart';
import 'package:slimm_app/src/providers/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('the default is Sharp, so the setting is opt-in', () {
    final c = container();
    expect(
      c.read(attachmentPreviewQualityControllerProvider),
      AttachmentPreviewQuality.sharp,
    );
  });

  test('Sharp decodes at full size; data saver at a quarter of its memory', () {
    // Memory falls with the square of the edge, so 0.5 is a quarter the RAM.
    expect(AttachmentPreviewQuality.sharp.decodeScale, 1.0);
    expect(AttachmentPreviewQuality.dataSaver.decodeScale, lessThan(0.6));
    expect(
      AttachmentPreviewQuality.balanced.decodeScale,
      inInclusiveRange(0.6, 0.9),
    );
    // Only the default names itself so, matching the image-cache row.
    expect(AttachmentPreviewQuality.sharp.label, contains('(default)'));
    expect(AttachmentPreviewQuality.dataSaver.label, isNot(contains('(')));
  });

  test('selecting a level persists it', () async {
    final c = container();
    await c
        .read(attachmentPreviewQualityControllerProvider.notifier)
        .select(AttachmentPreviewQuality.dataSaver);

    expect(
      c.read(attachmentPreviewQualityControllerProvider),
      AttachmentPreviewQuality.dataSaver,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(attachmentPreviewQualityKey), 'dataSaver');
  });

  test('restore reads a persisted level', () async {
    SharedPreferences.setMockInitialValues({
      attachmentPreviewQualityKey: 'balanced',
    });
    final c = container();
    await c.read(attachmentPreviewQualityControllerProvider.notifier).restore();

    expect(
      c.read(attachmentPreviewQualityControllerProvider),
      AttachmentPreviewQuality.balanced,
    );
  });

  test('an unknown persisted value degrades to the default', () async {
    SharedPreferences.setMockInitialValues({
      attachmentPreviewQualityKey: 'ultra',
    });
    final c = container();
    await c.read(attachmentPreviewQualityControllerProvider.notifier).restore();

    expect(
      c.read(attachmentPreviewQualityControllerProvider),
      AttachmentPreviewQuality.sharp,
    );
  });
}
