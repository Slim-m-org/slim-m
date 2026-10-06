// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The emoji upload card's default picker, proven at the `file_picker`
/// platform interface: nothing on this box can drive a real OS picker.
///
/// Proves: the plugin request now asks for `FileType.custom` with an
/// extension filter, not `FileType.image`, which is what selects
/// `UIDocumentPickerViewController` over `PHPickerViewController` on iOS
/// (`IOSFilePickerHandler.swift`) and the full SAF browser over a media-only
/// one on Android. Does not prove either OS actually shows a different
/// picker for that request, or that a document picked outside the camera
/// roll decodes as a usable image; neither is checkable without a phone.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/admin/emoji_upload_card.dart';

import 'composer_harness.dart' show usePicker;

void main() {
  test('the picker asks the plugin for FileType.custom with an extension '
      'filter, not FileType.image', () async {
    // A null file is the shape a cancelled pick returns.
    final picker = usePicker(null);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final picked = await container.read(emojiImagePickerProvider)();

    expect(picked, isNull);
    expect(picker.calls, 1);
    expect(
      picker.lastType,
      FileType.custom,
      reason: 'FileType.image would select the Photos-backed picker on iOS',
    );
    expect(picker.lastAllowedExtensions, acceptedEmojiExtensions);
  });
}
