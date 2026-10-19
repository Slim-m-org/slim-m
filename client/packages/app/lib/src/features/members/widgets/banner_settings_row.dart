// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Identity card's banner row: the image drawn behind your profile card,
/// instead of your profile colour. A gif goes up as picked; a still is cropped
/// to the banner shape first.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show SlimmApiUsers;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../../widgets/run_guarded.dart';
import '../../messages/providers/attachment_preview_bytes.dart'
    show looksAnimated;
import '../../messages/widgets/attachment_picker.dart';
import '../../messages/widgets/image_downscale.dart';
import 'avatar_crop_sheet.dart';
import 'identity_row.dart';

/// Width over height of the banner on a profile card.
const double kProfileBannerAspect = 3;

/// The server's cap on a profile picture, less room for the encoder's overhead.
const int _maxBytes = 2 * 1024 * 1024 - 64 * 1024;

const int _maxEdge = 1280;

class BannerSettingsRow extends ConsumerStatefulWidget {
  const BannerSettingsRow({super.key});

  @override
  ConsumerState<BannerSettingsRow> createState() => _BannerSettingsRowState();
}

class _BannerSettingsRowState extends ConsumerState<BannerSettingsRow>
    with GuardedActionState<BannerSettingsRow> {
  bool _busy = false;

  Future<void> _choose() async {
    final file = await ref.read(
      attachmentPickerProvider(AttachmentSource.photoLibrary),
    )();
    if (file == null || !mounted) return;
    var bytes = await file.readAsBytes();
    if (!looksAnimated(bytes)) {
      if (!mounted) return;
      final cropped = await showAvatarCropSheet(
        context,
        bytes,
        circular: false,
        aspect: kProfileBannerAspect,
      );
      if (cropped == null || !mounted) return;
      bytes = cropped;
    }
    final fitted = await downscaledToFit(
      bytes,
      maxEdge: _maxEdge,
      maxBytes: _maxBytes,
    );
    await _run(
      'upload the banner',
      () => ref.read(apiProvider).uploadBanner(fitted),
    );
  }

  Future<void> _run(
    String whatFailed,
    Future<Object?> Function() action,
  ) async {
    clearActionError();
    setState(() => _busy = true);
    final ok = await guard(whatFailed: whatFailed, action: action);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(meProvider);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider).valueOrNull;
    final isSet = me?.bannerUpdatedAt != null;
    final enabled = me != null && !_busy;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IdentityRow(
          caption: 'Banner',
          title: isSet ? 'Custom image' : 'Profile colour',
          trailing: [
            if (isSet)
              AppButton(
                label: 'Remove',
                variant: AppButtonVariant.ghost,
                semanticLabel: 'Remove profile banner',
                onPressed: enabled
                    ? () => unawaited(
                        _run(
                          'remove the banner',
                          () => ref.read(apiProvider).deleteBanner(),
                        ),
                      )
                    : null,
              ),
            AppButton(
              label: 'Change',
              semanticLabel: 'Change profile banner',
              onPressed: enabled ? () => unawaited(_choose()) : null,
            ),
          ],
        ),
        if (actionError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s8,
            ),
            child: AppErrorState(
              message: actionError!,
              onDismiss: clearActionError,
            ),
          ),
      ],
    );
  }
}
