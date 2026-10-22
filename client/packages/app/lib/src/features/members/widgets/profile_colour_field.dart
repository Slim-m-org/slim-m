// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile colour swatches: `PATCH /me` with the preset index, or with the
/// rgb a custom pick adds. A swatch saves the moment it is tapped; the Custom
/// swatch saves once its picker does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../../widgets/color_swatch_row.dart';
import 'profile_colour.dart';

/// Spoken names for [AppCanvasColors.cursors], in the same order.
const _colourNames = ['Pink', 'Purple', 'Blue', 'Orange', 'Green', 'Magenta'];

class ProfileColourField extends ConsumerStatefulWidget {
  const ProfileColourField({super.key, this.leading, this.imageSet = false});

  /// A tile ahead of the colours for the banner image.
  final Widget? leading;

  /// A banner image is showing, so no colour is the current choice, and picking one swaps the image out.
  final bool imageSet;

  @override
  ConsumerState<ProfileColourField> createState() => _ProfileColourFieldState();
}

class _ProfileColourFieldState extends ConsumerState<ProfileColourField> {
  String? _error;

  /// A preset sends only the index, which clears any custom colour server-side.
  Future<void> _setColor(int index) =>
      _save(() => ref.read(apiProvider).updateMe(profileColor: index));

  /// The nearest preset rides along so older clients still draw something close.
  Future<void> _setCustom(Color colour) => _save(
    () => ref
        .read(apiProvider)
        .updateMe(
          profileColor: nearestColourIndex(colour, AppCanvasColors.cursors),
          profileColorRgb: rgbOf(colour),
        ),
  );

  Future<void> _pickCustom(api.Me me) async {
    final colour = await showAppColourPicker(
      context,
      initial:
          profileColourOf(index: me.profileColor, rgb: me.profileColorRgb) ??
          AppCanvasColors.cursors.first,
    );
    if (colour != null) await _setCustom(colour);
  }

  Future<void> _save(Future<Object?> Function() save) async {
    setState(() => _error = null);
    try {
      if (widget.imageSet) await ref.read(apiProvider).deleteBanner();
      await save();
      ref.invalidate(meProvider);
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'save the profile colour', e, stack);
      if (mounted) setState(() => _error = 'Not saved: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider).valueOrNull;
    final custom = me?.profileColorRgb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ColorSwatchRow(
          label: 'Profile colour',
          colors: AppCanvasColors.cursors,
          names: _colourNames,
          selected: custom == null && !widget.imageSet
              ? me?.profileColor
              : null,
          onSelect: me == null ? null : _setColor,
          leading: widget.leading,
          custom: CustomSwatch(
            label: 'Custom',
            colour: custom == null || widget.imageSet
                ? null
                : profileColourOf(rgb: custom),
            onTap: me == null ? null : () => _pickCustom(me),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(
            message: _error!,
            onDismiss: () => setState(() => _error = null),
          ),
        ],
      ],
    );
  }
}
