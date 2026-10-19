// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picking, staging and the actions sheet for one composer.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../messages/widgets/attachment_picker.dart';
import '../../modules/widgets/app_launcher_sheet.dart';
import 'composer_attachments.dart';
import 'composer_clipboard_paste.dart';
import 'composer_extras.dart';
import 'composer_photo_strip.dart';
import 'gif_picker.dart' as gif;
import 'poll_composer_sheet.dart';

class ComposerAttachmentActions {
  ComposerAttachmentActions({
    required this.ref,
    required this.context,
    required this.focus,
    required this.attachments,
    required this.setError,
    required this.isMounted,
  });

  final WidgetRef ref;
  final BuildContext Function() context;
  final FocusNode focus;

  /// A callback because the staging swaps when the channel does.
  final AttachmentStagingController Function() attachments;
  final void Function(String?) setError;
  final bool Function() isMounted;

  void openActions({
    required String channelId,
    required bool gifSearchEnabled,
    required List<App> apps,
    required VoidCallback onInsertCode,
    required void Function(String) onCommandError,
  }) {
    final context = this.context();
    unawaited(
      showComposerActionsSheet(
        context,
        onPhotoLibrary: () => openPhotoStripOr(
          context,
          ref,
          channelId,
          fallback: () =>
              unawaited(pickAttachment(AttachmentSource.photoLibrary)),
        ),
        onBrowseFiles: () =>
            unawaited(pickAttachment(AttachmentSource.fileBrowser)),
        canPasteImage: composerClipboardPasteAvailable(
          platform: Theme.of(context).platform,
        ),
        onPasteImage: () =>
            unawaited(pasteClipboardImage(stageAttachment, setError)),
        onPoll: () => showPollComposerSheet(context, channelId),
        onCode: onInsertCode,
        onGif: gifSearchEnabled ? pickGif : null,
        // Only when there is something to launch; an empty menu entry would dead-end.
        onApps: apps.isEmpty
            ? null
            : () => unawaited(
                showAppLauncherSheet(
                  context,
                  ref,
                  channelId,
                  onError: onCommandError,
                ),
              ),
      ),
    );
  }

  /// Touch density only: the flow is `gif_picker.dart`'s `pickGif`; desktop
  /// reaches [stageGif] through the same anchored panel as emoji.
  void pickGif() => unawaited(
    gif.pickGif(
      context: context(),
      ref: ref,
      attachments: attachments(),
      onError: setError,
    ),
  );

  /// Focus comes back to the field, so Enter sends the GIF without the mouse.
  Future<void> stageGif(Attachment attachment) async {
    focus.requestFocus();
    await gif.stageGif(
      context: context(),
      ref: ref,
      attachments: attachments(),
      onError: setError,
      attachment: attachment,
    );
    if (isMounted()) focus.requestFocus();
  }

  /// Desktop has no photo/files split, so one tap opens the document picker.
  void pickFileFromButton() =>
      unawaited(pickAttachment(AttachmentSource.fileBrowser));

  /// Cleared up front so a successful retry leaves no stale failure on screen.
  Future<void> pickAttachment(AttachmentSource source) {
    setError(null);
    return runAttachmentPick(
      pick: ref.read(attachmentPickerProvider(source)),
      focus: focus,
      isMounted: isMounted,
      onPickerFailed: () => setError('Could not open the file picker.'),
      stage: stageFile,
    );
  }

  /// Stages bytes from any source, visible at once while the upload runs in
  /// the background; the one way onto the send path.
  Future<void> stageAttachment(Uint8List bytes, String filename) =>
      attachments().stage(bytes, filename);

  /// A file from a picker or a drop; refused up front when over the limit.
  Future<void> stageFile(FileSource file) async {
    final refusal = await attachments().stageFile(file);
    if (refusal != null) setError(refusal);
  }

  /// A pasted image takes the same staging path as a picked file.
  void handlePastedImage(Uint8List bytes, String filename) =>
      unawaited(stageAttachment(bytes, filename));
}
