// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The screen-share resolution ceiling control on the Space performance
/// screen. Split from `performance_screen.dart`, which is at its file-size
/// ceiling; the two share the screen but not a file, the same split
/// `canvas_cap_section.dart` already uses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show ScreenShareQuality;

import '../../preset_options.dart';
import '../../providers/admin_providers.dart';
import '../../providers/providers.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/success_flash.dart';

/// The screen-share resolution ceiling; index-matched to the segmented
/// options below. All lie inside the server's settable range (360 to 2160),
/// and 2160 is the default a deployment keeps until an admin sets one.
const _screenShareCapOptions = <(String, int)>[
  ('720p', 720),
  ('1080p', 1080),
  ('1440p', 1440),
  ('Source', 2160),
];

/// What choosing [maxHeight] actually bounds, grounded in
/// [ScreenShareQuality] (the real per-tier bitrate ceilings a sharer's own
/// quality choice already carries) and `screen_share_control.dart`'s own
/// doc: this setting scales the captured dimensions down, but leaves a
/// tier's bitrate ceiling alone - only the pixels that ceiling has to cover
/// change.
String screenShareCapConsequence(int maxHeight) {
  final tier = ScreenShareQuality.values.cast<ScreenShareQuality?>().firstWhere(
    (q) => q!.height == maxHeight,
    orElse: () => null,
  );
  if (tier != null) {
    final mbps = (tier.maxBitrate / 1000000).toStringAsFixed(1);
    return 'Shares are capped at ${tier.width}x${tier.height}, up to $mbps Mbps.';
  }
  final maxTierHeight = ScreenShareQuality.values
      .map((q) => q.height)
      .reduce((a, b) => a > b ? a : b);
  if (maxHeight < maxTierHeight) return 'Shares are capped at ${maxHeight}p.';
  return 'No cap: every quality tier already tops out at ${maxTierHeight}p.';
}

/// The screen-share resolution ceiling: client-advertised, so this is the
/// only enforcement there is - a client reads it and caps its own capture
/// parameters before starting a share, rather than the server inspecting
/// published tracks. Applies to every client, independent of the analytics
/// toggle above, so it stays visible and usable whether or not Space
/// analytics recording is on.
class ScreenShareCapSection extends ConsumerStatefulWidget {
  const ScreenShareCapSection({super.key});

  @override
  ConsumerState<ScreenShareCapSection> createState() =>
      _ScreenShareCapSectionState();
}

class _ScreenShareCapSectionState extends ConsumerState<ScreenShareCapSection>
    with GuardedActionState<ScreenShareCapSection> {
  bool _saving = false;
  int? _optimisticMaxHeight;

  Future<void> _setMaxHeight(int maxHeight) async {
    setState(() {
      _saving = true;
      _optimisticMaxHeight = maxHeight;
    });
    final ok = await guard(
      whatFailed: 'change the screen-share resolution ceiling',
      action: () =>
          ref.read(apiProvider).setSpaceScreenShareMaxHeight(maxHeight),
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!ok) _optimisticMaxHeight = null;
    });
    if (ok) ref.invalidate(spaceScreenShareCeilingProvider);
  }

  @override
  Widget build(BuildContext context) {
    final ceiling = ref.watch(spaceScreenShareCeilingProvider);
    ref.listen(spaceScreenShareCeilingProvider, (previous, next) {
      if (next.hasValue && !next.isLoading && _optimisticMaxHeight != null) {
        setState(() => _optimisticMaxHeight = null);
      }
    });
    // Null until the server has answered: an unknown ceiling selects nothing rather than posing as the default.
    final current = _optimisticMaxHeight ?? ceiling.valueOrNull;
    final options = current == null
        ? _screenShareCapOptions
        : presetsIncluding(_screenShareCapOptions, current, (h) => '${h}p');
    final selectedIndex = options.indexWhere((o) => o.$2 == current);

    return SettingsSectionCard(
      title: 'Screen share quality',
      description: 'The tallest resolution a share may use.',
      children: [
        AppSegmentedControl.inline(
          semanticLabel: 'Screen share resolution ceiling',
          options: [
            for (final option in options)
              AppSegmentedOption(label: option.$1, disabled: _saving),
          ],
          selectedIndex: selectedIndex,
          onSegmentSelected: (i) => _setMaxHeight(options[i].$2),
        ),
        if (current != null) ...[
          const SizedBox(height: AppSpacing.s12),
          AppCallout(
            tone: AppCalloutTone.info,
            child: Text(screenShareCapConsequence(current)),
          ),
        ],
        if (ceiling.hasError && current == null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(
            message: 'Could not load the current ceiling.',
            onRetry: () => ref.invalidate(spaceScreenShareCeilingProvider),
          ),
        ],
        SuccessFlash(tick: successTick),
        if (actionError != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(message: actionError!, onDismiss: clearActionError),
        ],
      ],
    );
  }
}
