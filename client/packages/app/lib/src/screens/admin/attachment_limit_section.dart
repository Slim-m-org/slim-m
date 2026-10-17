// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The attachment size limit control on the Space performance screen. Split
/// from `performance_screen.dart`, which is at its file-size ceiling, the same
/// way `canvas_cap_section.dart` is.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show SlimmApiSpace;
import 'package:slimm_design_system/design_system.dart';

import '../../preset_options.dart';
import '../../providers/admin_providers.dart';
import '../../providers/providers.dart';
import '../../features/channels/widgets/channel_rail_frame.dart'
    show serverInfoProvider;
import '../../widgets/optimistic_setting_state.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_segmented_block.dart';

const _mib = 1024 * 1024;
const _gib = 1024 * _mib;

/// Limits offered, in bytes; those above the operator's ceiling are dropped.
const _attachmentLimitOptions = <(String, int)>[
  ('25 MB', 25 * _mib),
  ('100 MB', 100 * _mib),
  ('500 MB', 500 * _mib),
  ('1 GB', _gib),
  ('5 GB', 5 * _gib),
  ('10 GB', 10 * _gib),
];

String _sizeLabel(int bytes) {
  if (bytes >= _gib && bytes % _gib == 0) return '${bytes ~/ _gib} GB';
  if (bytes >= _gib) return '${(bytes / _gib).toStringAsFixed(1)} GB';
  return '${(bytes / _mib).round()} MB';
}

/// The presets that fit under [serverMax], [current] included when it is none
/// of them, and the no-admin-limit choice (0) last.
List<(String, int)> attachmentLimitChoices({
  required int serverMax,
  required int? current,
}) {
  final presets = [
    for (final o in _attachmentLimitOptions)
      if (o.$2 <= serverMax) o,
  ];
  final withCurrent = current == null || current == 0
      ? presets
      : presetsIncluding(presets, current, _sizeLabel);
  return [...withCurrent, ('Server maximum', 0)];
}

/// The largest file a member can upload. The operator's own ceiling still
/// applies above whatever is chosen here.
class AttachmentLimitSection extends ConsumerStatefulWidget {
  const AttachmentLimitSection({super.key});

  @override
  ConsumerState<AttachmentLimitSection> createState() =>
      _AttachmentLimitSectionState();
}

class _AttachmentLimitSectionState extends ConsumerState<AttachmentLimitSection>
    with
        GuardedActionState<AttachmentLimitSection>,
        OptimisticSettingState<AttachmentLimitSection, int> {
  Future<void> _setLimit(int maxBytes) => saveOptimistic(
    maxBytes,
    whatFailed: 'change the attachment size limit',
    action: () async {
      await ref.read(apiProvider).setSpaceAttachmentLimit(maxBytes);
      ref.invalidate(serverInfoProvider);
    },
    refresh: spaceAttachmentLimitProvider,
  );

  @override
  Widget build(BuildContext context) {
    final limit = ref.watch(spaceAttachmentLimitProvider);
    ref.listen(
      spaceAttachmentLimitProvider,
      (_, next) => retireOptimistic(next),
    );
    final served = limit.valueOrNull;
    final current = optimistic ?? served?.maxBytes;
    final options = served == null
        ? const <(String, int)>[]
        : attachmentLimitChoices(
            serverMax: served.serverMaxBytes,
            current: current,
          );
    final selectedIndex = options.indexWhere((o) => o.$2 == current);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Attachment size limit',
          description: 'Largest file a member can upload.',
          children: [
            if (options.isNotEmpty)
              SettingsSegmentedBlock(
                semanticLabel: 'Attachment size limit',
                labels: [for (final option in options) option.$1],
                selectedIndex: selectedIndex,
                disabled: saving,
                onSelected: (i) => _setLimit(options[i].$2),
              ),
            if (limit.hasError && served == null)
              SettingsCardBlock(
                children: [
                  AppErrorState(
                    message: 'Could not load the current limit.',
                    onRetry: () => ref.invalidate(spaceAttachmentLimitProvider),
                  ),
                ],
              ),
          ],
        ),
        SettingsSaveFeedback(
          tick: successTick,
          error: actionError,
          onDismissError: clearActionError,
        ),
      ],
    );
  }
}
