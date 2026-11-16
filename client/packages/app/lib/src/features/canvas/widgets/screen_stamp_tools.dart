// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Stamp tool on one shared screen's tile (decision 0121): whether that
/// screen takes stamps, picking one, placing it, pasting a picture, and the
/// refusal a stamp the server turned down leaves on the tile.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/server_info.dart';
import '../../../widgets/status_banner.dart';
import '../../composer/widgets/composer_clipboard_paste.dart';
import '../../screen_overlay/providers/screen_annotation_consent.dart';
import '../../screen_overlay/providers/screen_annotation_feed.dart';
import '../../screen_overlay/providers/stamp_actions.dart';
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

  /// Places the armed stamp centred at [centre], 0 to 1 across the screen.
  Future<void> place(Offset centre, double size) async {
    final armed = ref.read(armedStampProvider).content;
    final channel = ref.read(voiceFlagsProvider).channelId;
    final self = ref
        .read(voiceParticipantsProvider)
        .where((p) => p.isLocal)
        .firstOrNull;
    if (armed == null || channel == null || self == null) return;
    onRefusal(
      await ref
          .read(stampActionsProvider)
          .sender(
            channelId: channel,
            sharerId: sharerId,
            selfId: self.identity,
            feed: feed,
          )
          .place(armed, centre, size),
    );
  }

  /// Arms the picture on the clipboard; nothing reaches the sharer before a tap.
  Future<void> paste() => pasteClipboardImage(
    (bytes, filename) async {
      try {
        final picture = await ref
            .read(stampActionsProvider)
            .uploadPicture(
              bytes,
              filename: filename,
              channelId: ref.read(voiceFlagsProvider).channelId,
            );
        ref.read(armedStampProvider.notifier).arm(picture);
      } on StampPictureRefused catch (refused) {
        onRefusal(refused.message);
      }
    },
    (message) {
      if (message != null) onRefusal(message);
    },
  );
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
