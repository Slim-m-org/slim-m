// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The media and cache pane: the local dials for what media does on its own.
///
/// Auto-download decides whether images fetch on sight (data); autoplay decides
/// whether gifs animate on sight (battery/CPU); preview quality decides how
/// sharply each inline preview decodes (memory); and the image-cache cap bounds
/// how much decoded-image memory is kept for reuse (memory). The four are
/// paired on purpose - a data-saver preview and a large cache together hold far
/// more attachments ready to scroll back to than either does alone, since each
/// one resident costs a fraction as much. App behaviour lives in
/// [GeneralSettingsSection].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/attachment_preview_quality.dart';
import '../providers/image_cache_preference.dart';
import '../providers/media_preferences.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';

class PerformanceSettingsSection extends ConsumerWidget {
  const PerformanceSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionCard(
          title: 'Media',
          description: 'What loads and plays on its own.',
          children: [
            SettingsSelectRow<MediaAutoDownload>(
              label: 'Auto-download media',
              sheetTitle: 'Auto-download media',
              value: ref.watch(mediaAutoDownloadControllerProvider),
              choices: [
                for (final value in MediaAutoDownload.values)
                  SettingsChoice(value: value, label: value.label),
              ],
              sheetFootnote:
                  'Whether images load as you scroll or wait for a tap.',
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
          ],
        ),
        SettingsSectionCard(
          title: 'Storage',
          description: 'How much this device keeps around.',
          children: [
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
              description: 'How much memory recent images may use.',
              onChanged: (next) => ref
                  .read(imageCacheLimitControllerProvider.notifier)
                  .select(next),
            ),
          ],
        ),
      ],
    );
  }
}
