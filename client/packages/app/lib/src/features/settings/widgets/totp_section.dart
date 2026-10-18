// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two-factor authentication, under Account & devices: turn it on, replace the
/// recovery codes, turn it off.
///
/// Absent entirely when the operator has set the policy to `off` and the member
/// has no factor, for the reason `AppLockSection` hides itself off
/// `supportsBiometricLock`: a control that can do nothing is worse than no
/// control. A member who *does* have one still sees the section, because `off`
/// deliberately keeps enforcing an existing factor and turning it off has to
/// stay possible (decision 0048).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import 'settings_detail_row.dart';
import 'settings_notice.dart';
import 'settings_section_header.dart';
import 'totp_code_sheet.dart';
import 'totp_enrol_sheet.dart';
import 'totp_failures.dart';
import 'totp_recovery_codes.dart';

final totpStatusProvider = FutureProvider.autoDispose<api.TotpStatus>(
  (ref) => ref.watch(apiProvider).totpStatus(),
);

/// Whether the section has nothing to offer, so a card around it can skip it.
bool totpSectionHidden(api.TotpStatus status) =>
    status.policy == api.TotpPolicy.off && !status.enabled;

/// Below this, the section says so rather than only showing the number: a
/// count nobody reads as low is not a warning.
const _lowRecoveryCodes = 3;

/// The two-factor rows of the Sign-in card: a state badge and description,
/// with the recovery and turn-off actions as sub rows once it is on.
class TotpSection extends ConsumerWidget {
  const TotpSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(totpStatusProvider);
    return status.when(
      loading: () =>
          const AppListRow(label: 'Two-factor authentication', meta: 'Loading'),
      // A fixed sentence, never the exception itself; see `JoinPolicyRow`.
      error: (e, _) => SettingsCardBlock(
        children: [
          AppErrorState(
            message: 'Could not load your two-factor settings.',
            onRetry: () => ref.invalidate(totpStatusProvider),
          ),
        ],
      ),
      data: (loaded) => totpSectionHidden(loaded)
          ? const SizedBox.shrink()
          : _TotpRows(status: loaded),
    );
  }
}

String _description(api.TotpStatus status) {
  if (status.pending) return _pendingNote;
  if (status.enabled) {
    return 'New devices ask for a code as well as your password.';
  }
  if (status.policy == api.TotpPolicy.requiredForElevated) {
    return 'Required here for anyone who moderates or administers.';
  }
  return 'Asks for an authenticator code on new-device sign-in.';
}

/// An enrolment was started and never confirmed. Worth saying, because the
/// offer is "finish this" rather than "start something".
const _pendingNote =
    'You started setting this up and did not finish, so it is not on '
    'yet. Starting again gives you a fresh key.';

class _TotpRows extends ConsumerWidget {
  const _TotpRows({required this.status});

  final api.TotpStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = status.recoveryCodesRemaining;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (status.enabled && remaining <= _lowRecoveryCodes)
          _LowCodesNotice(remaining: remaining),
        SettingsDetailRow(
          icon: AppIcons.shield,
          title: 'Two-factor authentication',
          badge: AppBadge(
            variant: status.enabled
                ? AppBadgeVariant.role
                : AppBadgeVariant.warn,
            label: status.enabled ? 'On' : 'Off',
          ),
          detail: _description(status),
          trailing: status.enabled
              ? null
              : AppButton(
                  label: status.pending ? 'Finish' : 'Turn on',
                  size: AppButtonSize.sm,
                  semanticLabel: status.pending
                      ? 'Finish setting up two-factor authentication'
                      : 'Turn on two-factor authentication',
                  onPressed: () => _enrol(context, ref),
                ),
        ),
        if (status.enabled) ...[
          SettingsSubRow(
            label: 'Recovery codes, $remaining left',
            onTap: () => _reissue(context, ref),
            trailing: const Icon(AppIcons.resetCode, size: AppSizes.icon16),
          ),
          SettingsSubRow(
            label: 'Turn off two-factor authentication',
            onTap: () => _turnOff(context, ref),
            trailing: const Icon(AppIcons.shieldOff, size: AppSizes.icon16),
          ),
        ],
      ],
    );
  }
}

Future<void> _enrol(BuildContext context, WidgetRef ref) async {
  final done = await showTotpEnrolSheet(context, ref);
  if (done == true) ref.invalidate(totpStatusProvider);
}

/// Replacing the set needs a current code, and the sheet that asks for one
/// hands back the new codes through a second sheet rather than a toast: they
/// are shown once, so they need somewhere they can be read and copied.
Future<void> _reissue(BuildContext context, WidgetRef ref) async {
  List<String>? fresh;
  await showTotpCodeSheet(
    context,
    title: 'New recovery codes',
    description: 'Enter a code; your current recovery codes will stop working.',
    submitLabel: 'Replace codes',
    onSubmit: (code) async {
      try {
        fresh = await ref.read(apiProvider).reissueTotpRecoveryCodes(code);
        return null;
      } on api.ApiException catch (e, stack) {
        api.reportFailure(
          api.LogTag.auth,
          'reissue two-factor recovery codes',
          e,
          stack,
        );
        return totpCodeFailure(e);
      }
    },
  );
  final codes = fresh;
  if (codes == null || !context.mounted) return;
  ref.invalidate(totpStatusProvider);
  await showAppSheet<void>(
    context,
    builder: (context) => TotpRecoveryCodesView(
      codes: codes,
      headline: 'Your new recovery codes',
      onDone: () => Navigator.of(context).pop(),
    ),
  );
}

Future<void> _turnOff(BuildContext context, WidgetRef ref) async {
  final done = await showTotpCodeSheet(
    context,
    title: 'Turn off two-factor authentication',
    description: 'Enter a code from your authenticator, or a recovery code.',
    submitLabel: 'Turn off',
    dangerous: true,
    onSubmit: (code) async {
      try {
        await ref.read(apiProvider).disableTotp(code);
        return null;
      } on api.ApiException catch (e, stack) {
        api.reportFailure(
          api.LogTag.auth,
          'turn off two-factor sign-in',
          e,
          stack,
        );
        return totpCodeFailure(e);
      }
    },
  );
  if (done == true) ref.invalidate(totpStatusProvider);
}

class _LowCodesNotice extends StatelessWidget {
  const _LowCodesNotice({required this.remaining});

  final int remaining;

  @override
  Widget build(BuildContext context) => SettingsNotice(
    message: remaining == 0
        ? 'You have no recovery codes left. Without one, losing your '
              'authenticator means asking an administrator to turn this off '
              'for you. Replace them below.'
        : 'Only $remaining recovery code${remaining == 1 ? '' : 's'} left. '
              'Replace them below while you still can.',
  );
}
