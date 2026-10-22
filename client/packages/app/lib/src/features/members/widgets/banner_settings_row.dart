// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Identity card's banner row: an image tile at the head of the profile
/// colours, wearing the same selection ring, so an image and a colour read as
/// two choices of the same thing. A gif goes up as picked; a still is cropped to the
/// banner shape first.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api show Me;
import 'package:slimm_api/api.dart' show SlimmApiUsers;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../../widgets/run_guarded.dart';
import '../../messages/providers/attachment_preview_bytes.dart'
    show looksAnimated;
import '../../messages/widgets/attachment_picker.dart';
import '../../messages/widgets/image_downscale.dart';
import 'avatar_crop_sheet.dart';
import '../../../widgets/color_swatch_row.dart';
import '../../settings/widgets/settings_section_header.dart';
import 'identity_row.dart';
import 'profile_banner.dart';
import 'profile_colour_field.dart';

/// Width over height of the banner on a profile card.
const double kProfileBannerAspect = 3;

/// The server's cap on a profile picture, less room for the encoder's overhead.
const int _maxBytes = 2 * 1024 * 1024 - 64 * 1024;

const int _maxEdge = 1280;

/// The image tile's thumbnail, the diameter inside the selection ring.
const double _thumb = 24;

/// The image tile, the six presets and the custom swatch.
const int _tiles = 8;

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

  Widget _imageTile(api.Me me, bool isSet, bool enabled) => SwatchTile(
    key: const Key('banner-image-tile'),
    label: 'Profile banner: ${isSet ? 'Change image' : 'Use an image'}',
    selected: isSet,
    icon: AppIcons.image,
    onTap: enabled ? () => unawaited(_choose()) : null,
    child: isSet
        ? ProfileBanner(
            userId: me.id,
            bannerUpdatedAt: me.bannerUpdatedAt,
            colour: null,
            height: _thumb,
          )
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider).valueOrNull;
    final isSet = me?.bannerUpdatedAt != null;
    final enabled = me != null && !_busy;
    final inset = SettingsRowMetrics.of(context).inset;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IdentityRow(
          title: isSet ? 'Image' : 'Colour',
          caption: 'Banner',
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
          ],
        ),
        LayoutBuilder(
          builder: (context, box) {
            // Eight touch tiles do not fit inside the row inset on a phone, so the row uses the card's full width.
            final spare =
                (box.maxWidth - ColorSwatchRow.widthOf(context, _tiles)) / 2;
            return Padding(
              padding: EdgeInsets.fromLTRB(
                spare.clamp(0, inset),
                0,
                spare.clamp(0, inset),
                AppSpacing.s12,
              ),
              child: ProfileColourField(
                imageSet: isSet,
                leading: me == null ? null : _imageTile(me, isSet, enabled),
              ),
            );
          },
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
