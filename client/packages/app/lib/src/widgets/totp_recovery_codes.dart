// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Showing a fresh set of recovery codes, once.
///
/// Shared by enrolment and by reissuing, because the thing that matters is the
/// same in both places and it is not the layout: these are shown exactly once.
/// The server keeps only their hashes, so there is nothing to re-read, and a
/// person who closes this without keeping them has to reissue.
///
/// The "Done" button is deliberately the only way out and is not disabled: a
/// dialog somebody cannot dismiss is worse than one they dismiss too early, and
/// reissuing is always available. What the copy does instead is say plainly what
/// closing costs.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/toasts.dart';

class TotpRecoveryCodesView extends ConsumerWidget {
  const TotpRecoveryCodesView({
    super.key,
    required this.codes,
    required this.headline,
    required this.onDone,
  });

  final List<String> codes;
  final String headline;
  final VoidCallback onDone;

  /// One per line, which is what somebody pasting into a password manager or a
  /// notes app wants, and what a printed sheet looks like.
  String get _asText => codes.join('\n');

  void _copy(WidgetRef ref) {
    Clipboard.setData(ClipboardData(text: _asText));
    ref
        .read(toastsProvider.notifier)
        .show('Recovery codes copied.', severity: AppToastSeverity.success);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              headline,
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              'Keep these somewhere other than the phone with your '
              'authenticator on it. Each one works once, and they are the way '
              'back in if you lose that phone. They are shown now and never '
              'again - closing this means asking for a new set.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s12),
            _CodeList(codes: codes),
            const SizedBox(height: AppSpacing.s12),
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: 'Done',
                    variant: AppButtonVariant.ghost,
                    onPressed: onDone,
                  ),
                ),
                const SizedBox(width: AppSpacing.s8),
                Expanded(
                  child: AppButton(
                    label: 'Copy all',
                    variant: AppButtonVariant.primary,
                    onPressed: () => _copy(ref),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The codes themselves, selectable so they can be copied one at a time or read
/// off onto paper.
class _CodeList extends StatelessWidget {
  const _CodeList({required this.codes});

  final List<String> codes;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: tokens.surfaceBase,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      padding: const EdgeInsets.all(AppSpacing.s12),
      child: SelectableText(
        codes.join('\n'),
        style: AppText.code.copyWith(color: tokens.textPrimary, height: 1.7),
      ),
    );
  }
}
