// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The per-channel canvas object cap control, on the Space performance
/// screen. Split from `performance_screen.dart`, which is at its file-size
/// ceiling; the two share the screen but not a file, the same split
/// `screen_share_cap_section.dart` already uses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/admin_providers.dart';
import '../../providers/providers.dart';
import '../../widgets/canvas_memory_estimate.dart';
import '../../widgets/optimistic_setting_state.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/success_flash.dart';

/// The per-channel canvas object cap; index-matched to the segmented options
/// below. All lie inside the server's settable range (100 to 100000), and
/// 20000 is the default a deployment keeps until an admin sets one.
const _canvasCapOptions = <(String, int)>[
  ('5,000', 5000),
  ('10,000', 10000),
  ('20,000', 20000),
  ('50,000', 50000),
];

String _formatCount(int n) {
  final digits = n.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// What raising or lowering [cap] actually costs, in the one real memory
/// measurement this can be grounded in.
///
/// Says the number and how much to trust it, and nothing else. Where the
/// number comes from - two measured points, the report they are from, and the
/// roughly 65% run-to-run swing that is why this is an estimate at all - is
/// documented in `canvas_memory_estimate.dart`, which is where somebody
/// deciding whether to believe it should be reading. It was previously all
/// recited here, which on a phone is a paragraph between the reader and the
/// control.
String canvasCapConsequence(int cap) {
  final estimate = estimateCanvasMemoryMb(cap).toStringAsFixed(1);
  final trust = canvasMemoryEstimateIsExtrapolated(cap)
      ? 'Past what was measured, so treat it as an order of magnitude.'
      : 'An estimate, not a guarantee.';
  return 'About $estimate MB of memory per client that opens a channel with '
      '${_formatCount(cap)} objects. $trust';
}

/// The per-channel canvas object cap: a client-performance control that
/// applies to every viewer, independent of the analytics toggle, so it stays
/// visible and usable whether or not Space analytics recording is on.
class CanvasCapSection extends ConsumerStatefulWidget {
  const CanvasCapSection({super.key});

  @override
  ConsumerState<CanvasCapSection> createState() => _CanvasCapSectionState();
}

class _CanvasCapSectionState extends ConsumerState<CanvasCapSection>
    with
        GuardedActionState<CanvasCapSection>,
        OptimisticSettingState<CanvasCapSection, int> {
  Future<void> _setCap(int cap) => saveOptimistic(
    cap,
    whatFailed: 'change the canvas object cap',
    action: () => ref.read(apiProvider).setSpaceCanvasObjectCap(cap),
    refresh: spaceCanvasCapProvider,
  );

  @override
  Widget build(BuildContext context) {
    final cap = ref.watch(spaceCanvasCapProvider);
    ref.listen(spaceCanvasCapProvider, (_, next) => retireOptimistic(next));
    final current = shown(cap.valueOrNull, 20000);
    final selectedIndex = _canvasCapOptions.indexWhere((o) => o.$2 == current);

    return SettingsSectionCard(
      title: 'Canvas object cap',
      description: 'The most objects one channel canvas can hold.',
      children: [
        AppSegmentedControl.inline(
          semanticLabel: 'Canvas object cap',
          options: [
            for (final option in _canvasCapOptions)
              AppSegmentedOption(label: option.$1, disabled: saving),
          ],
          selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
          onSegmentSelected: (i) => _setCap(_canvasCapOptions[i].$2),
        ),
        const SizedBox(height: AppSpacing.s12),
        AppCallout(
          tone: AppCalloutTone.info,
          child: Text(canvasCapConsequence(current)),
        ),
        SuccessFlash(tick: successTick),
        if (actionError != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(message: actionError!, onDismiss: clearActionError),
        ],
      ],
    );
  }
}
