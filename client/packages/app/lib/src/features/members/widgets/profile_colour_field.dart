// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile colour swatches: `PATCH /me` with the preset index, or with the
/// rgb a custom pick adds. A swatch saves the moment it is tapped; the Custom
/// swatch saves once its picker does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import '../../../providers/providers.dart';
import '../../../widgets/color_swatch_row.dart';
import 'profile_colour.dart';
import '../providers/member_actions.dart';

typedef _Save = Future<Object?> Function(MemberActions actions);

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

  /// The preset just picked, shown at once while its save and the refetch after it land.
  int? _shown;

  /// A save waiting behind the one in flight; a newer pick replaces it, so rapid picks end on the last.
  _Save? _queued;
  bool _saving = false;

  /// A preset sends only the index, which clears any custom colour server-side.
  Future<void> _setColor(int index) =>
      _save((actions) => actions.updateMe(profileColor: index), shown: index);

  /// The nearest preset rides along so older clients still draw something close.
  Future<void> _setCustom(Color colour) => _save(
    (actions) => actions.updateMe(
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
    if (colour != null && mounted) await _setCustom(colour);
  }

  Future<void> _save(_Save save, {int? shown}) async {
    setState(() {
      _error = null;
      _shown = shown;
    });
    _queued = save;
    if (_saving) return;
    _saving = true;
    final container = ProviderScope.containerOf(context, listen: false);
    String? failure;
    var reread = false;
    try {
      // A pick made during the re-read saves too, so only the last run's outcome ever shows.
      while (_queued != null) {
        for (var next = _queued; next != null; next = _queued) {
          _queued = null;
          failure = await _send(container, next);
        }
        reread = await _reread(container);
      }
    } finally {
      _saving = false;
    }
    // Unknown truth after a failed save: drop the guess. After a good one, the guess is what the server took.
    if (!mounted || (!reread && failure == null)) return;
    setState(() {
      _shown = null;
      _error = failure;
    });
  }

  /// Re-reads the profile after the saves; false when that failed.
  Future<bool> _reread(ProviderContainer container) async {
    try {
      await container.refresh(meProvider.future);
      return true;
    } on Object catch (e, stack) {
      api.AppLog.swallowed(api.LogTag.ui, 'Re-read the profile', e, stack);
      return false;
    }
  }

  /// Runs one save; the sentence saying why it failed, or null.
  Future<String?> _send(ProviderContainer container, _Save save) async {
    final actions = container.read(memberActionsProvider);
    var whatFailed = 'save the profile colour';
    try {
      await save(actions);
      // The image goes only after the colour is safe, so a failed save loses neither.
      if (widget.imageSet) {
        whatFailed = 'remove the banner image';
        await actions.deleteBanner();
      }
      return null;
    } on api.ApiException catch (e, stack) {
      return reportFailureSentence(api.LogTag.ui, whatFailed, e, stack);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A guess kept past a failed re-read gives way to the next profile the server sends.
    ref.listen(meProvider, (_, next) {
      if (_saving || _shown == null || next is! AsyncData<api.Me>) return;
      setState(() => _shown = null);
    });
    final me = ref.watch(meProvider).valueOrNull;
    final custom = me?.profileColorRgb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ColorSwatchRow(
          label: 'Profile colour',
          colors: AppCanvasColors.cursors,
          names: _colourNames,
          selected:
              _shown ??
              (custom == null && !widget.imageSet ? me?.profileColor : null),
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
