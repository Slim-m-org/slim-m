// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who can join this Space: the one Space setting with no screen of its own.
///
/// [AppListRow], matching every row either side of it on
/// [SpaceSettingsScreen] since 2026-08-03 (`space_settings_section.dart` was
/// bare [ListTile]s until then, whose type did not match the rest of the
/// app - this row was written to match its siblings and had to change with
/// them). The current value still shows, as [AppListRow.meta], since seeing
/// it without opening the row is the point.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../../widgets/run_guarded.dart';
import 'settings_select_row.dart';

const _rowLabel = 'Who can join';

/// One read for the whole `/space/settings` object, shared with
/// [TotpPolicyRow], so two rows on the same screen do not each fetch it.
final spaceSettingsProvider = FutureProvider.autoDispose<api.SpaceSettings>(
  (ref) => ref.watch(apiProvider).spaceSettings(),
);

const _choices = [
  SettingsChoice(value: api.JoinPolicy.invite, label: 'People with an invite'),
  SettingsChoice(value: api.JoinPolicy.open, label: 'Anyone with the address'),
];

String _labelFor(api.JoinPolicy policy) => _choices
    .firstWhere(
      (choice) => choice.value == policy,
      orElse: () => _choices.first,
    )
    .label;

class JoinPolicyRow extends ConsumerStatefulWidget {
  const JoinPolicyRow({super.key});

  @override
  ConsumerState<JoinPolicyRow> createState() => _JoinPolicyRowState();
}

class _JoinPolicyRowState extends ConsumerState<JoinPolicyRow>
    with GuardedActionState<JoinPolicyRow> {
  bool _saving = false;

  Future<void> _set(api.JoinPolicy policy) async {
    setState(() => _saving = true);
    final ok = await guard(
      whatFailed: 'change who can join',
      action: () => ref
          .read(apiProvider)
          .setSpaceSettings(api.SpaceSettingsUpdate(joinPolicy: policy)),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) ref.invalidate(spaceSettingsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final settings = ref.watch(spaceSettingsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settings.when(
          loading: () => const AppListRow(
            label: _rowLabel,
            leading: Icon(AppIcons.members),
            meta: 'Loading…',
          ),
          // A fixed sentence, never the exception itself: a raw parse error
          // was rendering Dart type names into this row, which reads as a
          // crash and tells nobody anything actionable.
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(AppSpacing.s8),
            child: AppErrorState(
              message: 'Could not load who can join.',
              onRetry: () => ref.invalidate(spaceSettingsProvider),
            ),
          ),
          data: (loaded) => AppListRow(
            label: _rowLabel,
            leading: const Icon(AppIcons.members),
            meta: _labelFor(loaded.joinPolicy),
            semanticLabel:
                'Who can join, currently ${_labelFor(loaded.joinPolicy)}',
            trailing: Icon(
              AppIcons.chevronRight,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
            onTap: _saving ? null : () => _open(context, loaded.joinPolicy),
          ),
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

  Future<void> _open(BuildContext context, api.JoinPolicy current) async {
    final chosen = await SettingsSelectRow.pick<api.JoinPolicy>(
      context,
      title: _rowLabel,
      value: current,
      choices: _choices,
    );
    if (chosen != null && chosen != current) await _set(chosen);
  }
}
