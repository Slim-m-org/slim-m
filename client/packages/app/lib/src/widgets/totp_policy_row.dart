// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What this deployment asks of a second factor: the operator's own choice,
/// beside [JoinPolicyRow] since both are `/space/settings` and both are one row
/// with no screen of their own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';
import 'join_policy_row.dart';
import 'run_guarded.dart';
import 'settings_select_row.dart';

/// `off` is worded as "nobody new" rather than "off", because it does not turn
/// an existing factor off and a label saying otherwise would be a lie an
/// operator acts on.
const _choices = [
  SettingsChoice(value: api.TotpPolicy.off, label: 'Nobody new can turn it on'),
  SettingsChoice(value: api.TotpPolicy.optional, label: 'Anyone who wants to'),
  SettingsChoice(
    value: api.TotpPolicy.requiredForElevated,
    label: 'Expected of admins and moderators',
  ),
];

String _labelFor(api.TotpPolicy policy) => _choices
    .firstWhere((choice) => choice.value == policy, orElse: () => _choices[1])
    .label;

class TotpPolicyRow extends ConsumerStatefulWidget {
  const TotpPolicyRow({super.key});

  @override
  ConsumerState<TotpPolicyRow> createState() => _TotpPolicyRowState();
}

class _TotpPolicyRowState extends ConsumerState<TotpPolicyRow>
    with GuardedActionState<TotpPolicyRow> {
  bool _saving = false;

  /// Only the second-factor field is sent, so this row cannot change the join
  /// policy even when its snapshot of it is stale.
  Future<void> _set(api.TotpPolicy policy) async {
    setState(() => _saving = true);
    final ok = await guard(
      whatFailed: 'change the two-factor policy',
      action: () => ref.read(apiProvider).setSpaceSettings(totpPolicy: policy),
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
            label: 'Two-factor authentication',
            leading: Icon(AppIcons.shield),
            meta: 'Loading…',
          ),
          // A fixed sentence, never the exception itself; see `JoinPolicyRow`.
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(AppSpacing.s8),
            child: AppErrorState(
              message: 'Could not load the two-factor policy.',
              onRetry: () => ref.invalidate(spaceSettingsProvider),
            ),
          ),
          data: (loaded) => AppListRow(
            label: 'Two-factor authentication',
            leading: const Icon(AppIcons.shield),
            meta: _labelFor(loaded.totpPolicy),
            semanticLabel:
                'Two-factor authentication, currently '
                '${_labelFor(loaded.totpPolicy)}',
            trailing: Icon(
              AppIcons.chevronRight,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
            onTap: _saving ? null : () => _open(context, loaded),
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

  Future<void> _open(BuildContext context, api.SpaceSettings current) async {
    final chosen = await SettingsSelectRow.pick<api.TotpPolicy>(
      context,
      title: 'Two-factor authentication',
      value: current.totpPolicy,
      choices: _choices,
    );
    if (chosen != null && chosen != current.totpPolicy) {
      await _set(chosen);
    }
  }
}
