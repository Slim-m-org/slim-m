// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Stamp picker's Picture tab (decision 0121): a file of your own, the
/// picture on the clipboard, or one picked earlier this session.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../composer/widgets/composer_clipboard_paste.dart';
import '../../messages/widgets/attachment_picker.dart';
import '../../screen_overlay/providers/stamp_content.dart';
import '../../screen_overlay/providers/stamp_actions.dart';
import '../../screen_overlay/providers/stamp_picture_upload.dart';
import '../providers/armed_stamp.dart';
import 'stamp_view.dart';

/// A recent picture's square, in logical pixels.
const _recentSide = AppSizes.controlLg;

class StampPictureTab extends ConsumerStatefulWidget {
  const StampPictureTab({super.key, required this.onPicked, this.channelId});

  final ValueChanged<StampContent> onPicked;
  final String? channelId;

  @override
  ConsumerState<StampPictureTab> createState() => _StampPictureTabState();
}

class _StampPictureTabState extends ConsumerState<StampPictureTab> {
  bool _busy = false;
  String? _error;

  Future<void> _choose() async {
    try {
      final file = await ref.read(
        attachmentPickerProvider(AttachmentSource.photoLibrary),
      )();
      if (file == null || !mounted) return;
      await _stage(await file.readAsBytes(), file.name);
    } on Object catch (error, stack) {
      api.reportFailure(api.LogTag.media, 'pick a stamp picture', error, stack);
      if (mounted) setState(() => _error = 'The file picker could not open.');
    }
  }

  Future<void> _paste() =>
      pasteClipboardImage(_stage, (message) => _setError(message));

  void _setError(String? message) {
    if (mounted) setState(() => _error = message);
  }

  Future<void> _stage(Uint8List bytes, String filename) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final stamp = await ref
          .read(stampActionsProvider)
          .uploadPicture(
            bytes,
            filename: filename,
            channelId: widget.channelId,
          );
      if (mounted) widget.onPicked(stamp);
    } on StampPictureRefused catch (refused) {
      _setError(refused.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final recent = ref.watch(armedStampProvider).recentPictures;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Open file',
                  semanticLabel: 'Choose a picture file',
                  icon: AppIcons.image,
                  full: true,
                  busy: _busy,
                  onPressed: _busy ? null : _choose,
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: AppButton(
                  label: 'Paste',
                  icon: AppIcons.clipboardPaste,
                  full: true,
                  disabled: _busy,
                  semanticLabel: 'Paste a picture',
                  onPressed: _busy ? null : _paste,
                ),
              ),
            ],
          ),
          if (_error case final message?)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8),
              child: Text(
                message,
                style: AppText.caption.copyWith(color: tokens.dangerText),
              ),
            ),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s12),
            Text(
              'Recent',
              style: AppText.label.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s4),
            Wrap(
              spacing: AppSpacing.s4,
              runSpacing: AppSpacing.s4,
              children: [
                for (final picture in recent)
                  _RecentPicture(
                    picture: picture,
                    onTap: () => widget.onPicked(picture),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.s8),
          Text(
            'Pictures fade from their screen after a few seconds. '
            'They can report one for a day.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _RecentPicture extends StatelessWidget {
  const _RecentPicture({required this.picture, required this.onTap});

  final PictureStamp picture;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: 'Stamp this picture again',
      child: Material(
        color: tokens.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadii.control),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(
            dimension: _recentSide,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s4),
              child: StampView(content: picture),
            ),
          ),
        ),
      ),
    );
  }
}
