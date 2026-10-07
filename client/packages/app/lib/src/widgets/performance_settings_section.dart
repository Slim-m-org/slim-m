// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The performance pane: the local dials for what media does on its own, plus
/// how much history a scroll-back fetches.
///
/// Auto-download decides whether images fetch on sight (data); autoplay decides
/// whether gifs animate on sight (battery/CPU); preview quality decides how
/// sharply each inline preview decodes (memory); and the image-cache cap bounds
/// how much decoded-image memory is kept for reuse (memory). The media four are
/// paired on purpose - a data-saver preview and a large cache together hold far
/// more attachments ready to scroll back to than either does alone, since each
/// one resident costs a fraction as much. Message page size is the odd one out:
/// a network lever, how many older messages one backwards page asks for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart' show isDesktopHost;

import '../providers/attachment_preview_quality.dart';
import '../providers/desktop_splash_preference.dart';
import '../providers/image_cache_preference.dart';
import '../providers/media_preferences.dart';
import '../providers/message_page_size.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';
import 'start_on_login_row.dart';

class PerformanceSettingsSection extends ConsumerWidget {
  const PerformanceSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsSectionCard(
      divided: true,
      children: [
        SettingsSelectRow<MediaAutoDownload>(
          label: 'Auto-download media',
          sheetTitle: 'Auto-download media',
          value: ref.watch(mediaAutoDownloadControllerProvider),
          choices: [
            for (final value in MediaAutoDownload.values)
              SettingsChoice(value: value, label: value.label),
          ],
          sheetFootnote: 'Whether images load as you scroll or wait for a tap.',
          onChanged: (next) => ref
              .read(mediaAutoDownloadControllerProvider.notifier)
              .select(next),
        ),
        SettingsSelectRow<GifAutoplay>(
          label: 'Autoplay GIFs',
          sheetTitle: 'Autoplay GIFs',
          value: ref.watch(gifAutoplayControllerProvider),
          choices: [
            for (final value in GifAutoplay.values)
              SettingsChoice(value: value, label: value.label),
          ],
          sheetFootnote: 'Whether gifs move on their own.',
          onChanged: (next) =>
              ref.read(gifAutoplayControllerProvider.notifier).select(next),
        ),
        SettingsSelectRow<AttachmentPreviewQuality>(
          label: 'Attachment preview quality',
          sheetTitle: 'Attachment preview quality',
          value: ref.watch(attachmentPreviewQualityControllerProvider),
          choices: [
            for (final quality in AttachmentPreviewQuality.values)
              SettingsChoice(value: quality, label: quality.label),
          ],
          sheetFootnote: 'How sharply attachments are drawn in messages.',
          onChanged: (next) => ref
              .read(attachmentPreviewQualityControllerProvider.notifier)
              .select(next),
        ),
        SettingsSelectRow<int>(
          label: 'Image cache',
          sheetTitle: 'Image cache limit',
          value: ref.watch(imageCacheLimitControllerProvider),
          choices: [
            for (final mb in imageCacheLimitChoicesMb)
              SettingsChoice(
                value: mb,
                label: mb == defaultImageCacheLimitMb
                    ? '$mb MB (default)'
                    : '$mb MB',
              ),
          ],
          sheetFootnote: 'How much memory recent images may use.',
          onChanged: (next) =>
              ref.read(imageCacheLimitControllerProvider.notifier).select(next),
        ),
        SettingsSelectRow<MessagePageSize>(
          label: 'Message page size',
          sheetTitle: 'Message page size',
          value: ref.watch(messagePageSizeControllerProvider),
          choices: [
            for (final value in MessagePageSize.values)
              SettingsChoice(value: value, label: value.label),
          ],
          sheetFootnote: 'How many messages load when you scroll back.',
          onChanged: (next) =>
              ref.read(messagePageSizeControllerProvider.notifier).select(next),
        ),
        if (isDesktopHost) ..._splashRows(ref),
      ],
    );
  }

  /// Absent on a phone or the web, where it does nothing: the splash this
  /// pref governs only ever runs on the desktop window shell. One row rather
  /// than a separate on/off toggle - Disabled is just the first duration
  /// choice, so off and how-long are the same control.
  List<Widget> _splashRows(WidgetRef ref) {
    return [
      const StartOnLoginRow(),
      SettingsSelectRow<SplashDuration>(
        label: 'Startup splash',
        sheetTitle: 'Startup splash',
        value: ref.watch(splashDurationControllerProvider),
        choices: [
          for (final value in SplashDuration.values)
            SettingsChoice(value: value, label: value.label),
        ],
        sheetFootnote: 'The shortest time the splash stays up at startup.',
        onChanged: (next) =>
            ref.read(splashDurationControllerProvider.notifier).select(next),
      ),
    ];
  }
}
