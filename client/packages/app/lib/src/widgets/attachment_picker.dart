// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two native pickers an attachment action can open, and the seam that
/// makes the choice between them testable.
///
/// `file_picker`'s `type:` decides which OS picker a request opens, and the
/// two do not reach the same files. On iOS `FileType.image` opens the
/// Photos-backed `PHPickerViewController`, which cannot see a file that
/// arrived by download, Files, or a messaging app; no filter opens
/// `UIDocumentPickerViewController` instead, which reaches those but not the
/// camera roll. `emoji_upload_card.dart`'s `_pickImageBytes` documented this
/// first; the composer calling `pickFiles()` with no `type:` at all (so it
/// only ever opened the document picker) was the second time it bit, and the
/// reason a phone could never attach a photo straight from the camera roll.
/// Desktop has no such split, one dialog reaches everything, so a desktop
/// caller uses [AttachmentSource.fileBrowser] directly instead of offering a
/// choice with only one real answer.
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which native picker a request should open.
enum AttachmentSource {
  /// Photos-backed: `PHPickerViewController` on iOS, the media-only picker
  /// on Android.
  photoLibrary,

  /// The general document browser: `UIDocumentPickerViewController` on iOS,
  /// the SAF browser on Android, the one dialog every desktop platform has.
  fileBrowser,
}

/// Runs one pick and answers what was chosen, or null if nothing was.
typedef AttachmentPicker = Future<PlatformFile?> Function();

Future<PlatformFile?> _pickPhotoLibrary() =>
    FilePicker.pickFile(type: FileType.image);

Future<PlatformFile?> _pickFileBrowser() => FilePicker.pickFile();

/// The picker each [AttachmentSource] runs, injectable because `file_picker`
/// has no platform implementation under test: without this seam a widget
/// test can tap a picker action and never get past it, the same gap
/// `emojiImagePickerProvider` closes for the emoji upload card.
final attachmentPickerProvider =
    Provider.family<AttachmentPicker, AttachmentSource>(
      (ref, source) => switch (source) {
        AttachmentSource.photoLibrary => _pickPhotoLibrary,
        AttachmentSource.fileBrowser => _pickFileBrowser,
      },
    );

/// Runs [pick], stages whatever it returns, and re-focuses [focus] on every
/// exit including a cancelled or failed pick - the native picker takes focus
/// with it, and without this the caret never comes back and typing goes
/// nowhere.
///
/// [isMounted] is read after every await, since the widget that started this
/// can be gone by the time either the picker or the stage resolves. Split out
/// of `composer.dart`, which had no line budget left for it.
Future<void> runAttachmentPick({
  required AttachmentPicker pick,
  required FocusNode focus,
  required bool Function() isMounted,
  required VoidCallback onPickerFailed,
  required Future<void> Function(Uint8List bytes, String filename) stage,
}) async {
  final PlatformFile? file;
  try {
    file = await pick();
  } catch (e) {
    if (!isMounted()) return;
    focus.requestFocus();
    onPickerFailed();
    return;
  }
  if (!isMounted()) return;
  focus.requestFocus();
  if (file == null) return;
  // readAsBytes streams from disk; eager PlatformFile.bytes OOMs on a large pick.
  await stage(await file.readAsBytes(), file.name);
}
