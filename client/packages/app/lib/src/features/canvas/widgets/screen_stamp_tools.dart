// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Stamp tool on one shared screen's tile (decision 0121): whether that
/// screen takes stamps, picking one, placing it, pasting or dropping a
/// picture, and the refusal a stamp the server turned down leaves on the tile.
library;

import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart' show DropItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/server_info.dart';
import '../../../widgets/status_banner.dart';
import '../../composer/widgets/composer_clipboard_paste.dart';
import '../../messages/widgets/image_drop_zone.dart'
    show DroppedImage, RefusedDrop, readDroppedImage;
import '../../screen_overlay/providers/screen_annotation_consent.dart';
import '../../screen_overlay/providers/screen_annotation_feed.dart';
import '../../screen_overlay/providers/screen_stamp_sender.dart';
import '../../screen_overlay/providers/screen_stamp_timing.dart';
import '../../screen_overlay/providers/stamp_actions.dart';
import '../../screen_overlay/providers/stamp_content.dart';
import '../../screen_overlay/providers/stamp_picture_upload.dart';
import '../../voice/providers/voice_flags.dart';
import '../providers/armed_stamp.dart';
import 'stamp_picker.dart';

class ScreenStampTools {
  ScreenStampTools({
    required this.ref,
    required this.sharerId,
    required this.feed,
    required this.onRefusal,
  });

  final WidgetRef ref;
  final String sharerId;
  final ScreenAnnotationFeed feed;

  /// Says why a stamp or a paste was refused, or clears it with null.
  final ValueChanged<String?> onRefusal;

  /// Stamps reach this screen only when the server takes them and the sharer's client shows them; watched, so call it from build.
  bool takes(SharerConsent? consent) =>
      consent != null &&
      consent.stamps &&
      ref.watch(
        serverInfoProvider.select(
          (info) => info.valueOrNull?.supportsScreenStamps ?? false,
        ),
      );

  /// Opens the picker beside [anchor]; [onPicked] runs once something is armed.
  void choose(BuildContext anchor, {required VoidCallback onPicked}) =>
      showStampPicker(
        anchor,
        channelId: ref.read(voiceFlagsProvider).channelId,
        onPicked: (_) => onPicked(),
      );

  /// A sender for stamps on this screen, or null outside a call.
  ScreenStampSender? _sender() {
    final channel = ref.read(voiceFlagsProvider).channelId;
    final self = ref
        .read(voiceParticipantsProvider)
        .where((p) => p.isLocal)
        .firstOrNull;
    if (channel == null || self == null) return null;
    return ref
        .read(stampActionsProvider)
        .sender(
          channelId: channel,
          sharerId: sharerId,
          selfId: self.identity,
          feed: feed,
        );
  }

  /// Places the armed stamp centred at [centre], 0 to 1 across the screen.
  Future<void> place(Offset centre, double size) async {
    final armed = ref.read(armedStampProvider).content;
    final sender = _sender();
    if (armed == null || sender == null) return;
    onRefusal(await sender.place(armed, centre, size));
  }

  /// Stamps a picture file dropped at [centre] at the default size, uploaded and checked as a picked one is, and arms it.
  Future<void> drop(List<DropItem> items, Offset centre) async {
    final sender = _sender();
    final upload = _uploader();
    if (sender == null) return;
    switch (await readDroppedImage(
      items,
      extensions: stampPictureExtensions,
      refusal: 'Drop one PNG, JPEG, GIF or WebP picture.',
    )) {
      case RefusedDrop(:final message):
        onRefusal(message);
      case DroppedImage(:final bytes, :final name):
        final picture = await upload(bytes, name);
        if (picture != null) {
          onRefusal(await sender.place(picture, centre, stampDefaultSize));
        }
    }
  }

  /// Arms the picture on the clipboard; nothing reaches the sharer before a tap.
  Future<void> paste() {
    final upload = _uploader();
    return pasteClipboardImage(upload, (message) {
      if (message != null) onRefusal(message);
    });
  }

  /// Uploads and arms a picture, read from [ref] now so it still works once the tile has gone.
  Future<PictureStamp?> Function(Uint8List bytes, String filename) _uploader() {
    final actions = ref.read(stampActionsProvider);
    final armed = ref.read(armedStampProvider.notifier);
    final channelId = ref.read(voiceFlagsProvider).channelId;
    return (bytes, filename) async {
      try {
        final picture = await actions.uploadPicture(
          bytes,
          filename: filename,
          channelId: channelId,
        );
        armed.arm(picture);
        return picture;
      } on StampPictureRefused catch (refused) {
        onRefusal(refused.message);
        return null;
      }
    };
  }
}

/// A refused stamp's reason across the top of the tile (rule 6), gone after a while.
class ScreenStampRefusal extends StatelessWidget {
  const ScreenStampRefusal({
    super.key,
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Positioned(
    top: AppSpacing.s8,
    left: AppSpacing.s8,
    right: AppSpacing.s8,
    child: Center(
      child: StatusBanner(
        key: ValueKey(message),
        message: message,
        severity: BannerSeverity.warning,
        onDismiss: onDismiss,
      ),
    ),
  );
}
