// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer and avatar attach actions' shared picker, proven at the
/// `file_picker` platform interface: nothing on this box can drive a real OS
/// picker, and `attachment_picker.dart`'s whole reason to exist is that the
/// two [AttachmentSource] routes must ask the plugin for different things.
///
/// Proves: [AttachmentSource.photoLibrary] requests `FileType.image`, which
/// is what selects the Photos-backed `PHPickerViewController` on iOS, and
/// [AttachmentSource.fileBrowser] requests the plugin's default (no `type:`
/// at all), which is what selects `UIDocumentPickerViewController` there
/// instead. Does not prove either OS actually shows a different picker for
/// that request, or that a file picked outside the camera roll decodes as a
/// usable image; neither is checkable without a phone.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/attachment_picker.dart';

import 'composer_harness.dart' show usePicker;

void main() {
  test('the photo library route asks the plugin for FileType.image', () async {
    // A null file is the shape a cancelled pick returns.
    final picker = usePicker(null);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final picked = await container.read(
      attachmentPickerProvider(AttachmentSource.photoLibrary),
    )();

    expect(picked, isNull);
    expect(picker.calls, 1);
    expect(picker.lastType, FileType.image);
  });

  test(
    'the file browser route asks the plugin for the default FileType.any',
    () async {
      final picker = usePicker(null);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final picked = await container.read(
        attachmentPickerProvider(AttachmentSource.fileBrowser),
      )();

      expect(picked, isNull);
      expect(picker.calls, 1);
      expect(
        picker.lastType,
        FileType.any,
        reason: 'the document browser opens with no type filter at all',
      );
    },
  );
}
